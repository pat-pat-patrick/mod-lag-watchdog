-- HD2-Addon: mods/patpatpatrick/mod_lag_finder
-- Mod Lag Watchdog. Copyright (c) 2026 patpatpatrick.
-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at https://mozilla.org/MPL/2.0/.
-- Mod Lag Watchdog v0.20.0 (was Mod Lag Finder; the addon, log and window
-- file keep that name so an update finds them)
--
-- Native calls, all through LuaJIT's ffi, each bound once at load:
--   * kernel32's QueryPerformanceCounter, the timer (v0.8.0; see "timer");
--   * ReadProcessMemory on this process only, 2 reads of a few bytes a frame
--     (5 while the escape menu is up) of the game's UI state, to see the
--     escape menu (below);
--   * once a second, dxgi's QueryVideoMemoryInfo: this process's video memory
--     and the budget Windows gives it (v0.12.1);
--   * only when the player clicks a mod's row or "copy mod list": user32's
--     clipboard calls (OpenClipboard, EmptyClipboard, SetClipboardData,
--     CloseClipboard), kernel32's MultiByteToWideChar (v0.17.1: the text goes
--     as Unicode, so Chinese mod names survive) and
--     kernel32's GlobalAlloc/GlobalLock/GlobalUnlock/GlobalFree for the text
--     handed to the clipboard (v0.11.0; see "report").
-- The first three only read. None of them writes to the game's memory.
-- (Up to v0.7.1 this line said "makes no native call", which
-- was wrong since the menu window came in v0.3.0.) It times how long each mod's update
-- takes every frame and writes %APPDATA%\Arrowhead\Helldivers2\
-- mod_lag_finder.log (appended across sessions, started afresh above 4 MB).
-- Log lines are kept in memory and written together every 10 s (v0.6.0),
-- so a crash loses up to the last 10 s of the log.
--
-- On screen (nothing at all unless one of these is due):
--   * a stall of 150 ms or more that one mod caused (60 % of the frame or
--     more) shows one line for 5 s: "LAG 303 ms - wheres_my_shit". Stalls
--     outside every mod are logged but not shown.
--   * one mod hooked into the update chain 3 times or more (mods that keep
--     re-arming above each other) shows an amber line for 8 s:
--     "REHOOK stratagem_hotkeys x4, mod_lag_finder x4 (chain 37)" (v0.3.2)
--   * scripts MDL runs live (MDL 1.0.5-p11+, MDL.perf == 1) get rows of their
--     own, "mdl: <name>", out of MDL's row (v0.3.4)
--   * which game since the last Arsenal deploy this is, and when that deploy
--     was (v0.3.6): logged at the start, shown in the window, and every game
--     ends with its stall totals
--   * each mod under its name in the mod manager (Arsenal, v0.7.1; see
--     "names"), else the last part of its addon name
--   * a mod whose Lua memory only grows (a leak): counted once a minute,
--     flagged after 10 minutes without a drop (v0.9.0; see "memory")
--   * a mod whose helper units only pile up in one world (v0.10.0; by
--     units alive 10 minutes or more since v0.12.3; see "units"), and Lua memory growth a player would feel, 10 MB in 10
--     minutes, on screen; smaller leaks in the log only
--   * a click on a mod's row in the escape-menu window copies that mod's
--     8-line report to the clipboard (v0.11.0; see "report")
--   * video memory over the budget Windows gives the game (v0.12.1; see
--     "vram"): "VRAM 15.6 / 14.9 GB - over budget", amber, 8 s, at most once
--     a minute, and an amber window line while it lasts. Nothing otherwise;
--     each 60 s summary logs a "vram:" line. (v0.12.0, never released, also
--     showed how busy the card was; the user dropped it: driver overlays
--     already show that.)
--   * two switches in the escape-menu window (v0.12.2): "show table in
--     missions" (the same as Home) and "show alerts in missions" (the LAG,
--     REHOOK, MEM, UNITS and VRAM lines); both off = nothing drawn in a
--     mission, all still logged. Saved as the 4th number of the window file.
--   * on the escape menu every mod is listed, those under 10 ms/s in grey
--     (v0.12.2); in missions they are only counted
--   * a Lua error from a mod below this module (v0.15.0; see "errors"): the
--     game closes on it as it would without the Watchdog, but the mod, the
--     line and the message are logged first, and the next launch shows
--     "LAST CRASH: <name> raised a Lua error" once on the ship. A mod whose
--     errors another mod catches -- above this module or, since v0.16.0,
--     below it too -- is named in the log every minute (with the full stack
--     of its first error), an amber "ERROR <name> N frames/min" window line,
--     and once per mod an alert in missions (v0.14.0)
--   * the slowest log write of the last 30 s, in the window and in the 60 s
--     summary (v0.4.1; GameGuard's CPU, shown next to it in v0.4.1, was
--     taken out in v0.5.0)
--   * a window: each mod's cost over the last 30 s in ms per second (only
--     mods at 10 ms/s or more, v0.8.1) and its
--     worst frame, the mod on top of the chain (whose own time cannot be
--     measured), and the last stall. On the escape menu (GAME tab) it is
--     shown and can be dragged by its title bar; in play Home opens and
--     closes it, at the place it was dragged to, as shadowed text only (no
--     background or title bar, v0.3.3), and the stall line shows there too. (v0.3.0; v0.2.0 had the panel on Home only, at a fixed place.)
-- Text is drawn the way ESC Squad Ping 0.2.3 draws it (seen working in
-- game): a screen GUI on a world other than the main one, font
-- core/performance_hud/debug, Latin text only. Every GUI call is made only
-- after Application.worlds() has shown that world is still there.
--
-- How: every mod hooks the frame the same way, rawset(_G, "update",
-- wrapper), where the wrapper calls the update it found (its "previous").
-- The frame is a chain of closures, top = _G.update, bottom = the game's own.
-- This module walks that chain with the debug library, one link at a time:
--
--   1. For link L, every Lua function held in L's upvalues gets a pass-
--      through spy (a tail call: it adds no stack frame). The one called
--      once a frame with the same first argument (dt) as the frame's update
--      is L's previous. Several matches -> the upvalue name decides (previous,
--      original, ...), then the one that takes longest over 16 frames (the
--      previous holds the whole rest of the frame). No upvalue matches -> the
--      same test over the functions in L's plain table upvalues (a mod that
--      keeps its previous in a table); still none -> L is the bottom.
--   2. The chosen slot keeps a timing shim for good; every other spy is
--      removed. The next link is examined on the next frames.
--   3. The walk stops at the first link whose source is not "mods/..." once
--      a "mods/..." link has been seen: that is the game, which is timed as a
--      whole and never looked into.
--
-- Nothing is replaced but upvalue slots and table fields that held a Lua
-- function, always with a function that calls the original with the same
-- arguments and returns its results unchanged. _G.update is never written
-- except to arm this module's own wrapper, which re-arms only on a stale
-- heartbeat (hd2-update-chain-escalation). When _G.update changes, every
-- slot still holding a shim gets its original back and the walk starts over.
--
-- Time per link = its shim's duration minus the next link's ("self"). The
-- top link has no shim above it, so its own time is not measured; the log
-- says which mod is on top. A frame of 50 ms or more is reported one frame
-- later, when every link's share of it is known, with the three largest
-- shares, what the chain does not explain, the engine's dt of that frame and
-- the next, and the Lua heap (a drop means a garbage collection ran).
-- Every 60 s: each mod's cost in ms per second and per frame, and its worst frame.
-- os.clock has 1 ms resolution here: single small numbers are coarse, sums
-- and big stalls are not.
--
-- v0.2.0 also: when several upvalues pass the dt test and none is named like
-- a previous, one from ANOTHER source than the link wins before time is
-- compared. v0.1.0 in game (09-29) once followed a stripped mod's own helper
-- down three links of the same file, because both candidates timed at 0 ms.

local MARKER = "mod-lag-finder-v0.45.0"

if rawget(_G, "__mlf_marker") == MARKER then return { name = MARKER } end
rawset(_G, "__mlf_marker", MARKER)

local sr = rawget(_G, "stingray")
local App = sr and rawget(sr, "Application") or nil
local dbg = rawget(_G, "debug")
local getupvalue = dbg and rawget(dbg, "getupvalue") or nil
local setupvalue = dbg and rawget(dbg, "setupvalue") or nil
local getinfo = dbg and rawget(dbg, "getinfo") or nil
local collect = rawget(_G, "collectgarbage")
local os_clock = os.clock

-- ------------------------------------------------------------ timer

-- os.clock counts whole milliseconds on Windows: fine for averages over many
-- frames, useless for one small mod's single frame (a 0.02 ms update reads 0
-- or 1 ms). In game the timer is QueryPerformanceCounter (0.1 us), bound once;
-- it writes into a two-word buffer so a reading allocates nothing. A test
-- (the __hd2_native_test seam) or a VM without ffi keeps os.clock.
local timer_kind = "os.clock (1 ms steps)"
local timer_now = os_clock
do
  local loader = rawget(_G, "require")
  if rawget(_G, "__hd2_native_test") == nil and type(loader) == "function" then
    local ok, ffi = pcall(loader, "ffi")
    if ok and type(ffi) == "table" then
      pcall(function()
        pcall(ffi.cdef, "int QueryPerformanceCounter(int64_t *count);")
        pcall(ffi.cdef, "int QueryPerformanceFrequency(int64_t *frequency);")
        local kernel = ffi.load("kernel32")
        local qpc = ffi.cast("int (*)(void *)", kernel.QueryPerformanceCounter)
        local qpf = ffi.cast("int (*)(void *)", kernel.QueryPerformanceFrequency)
        local words = ffi.new("uint32_t[2]")
        if qpf(words) == 0 then return end
        local per_tick = 1 / (words[1] * 4294967296 + words[0])
        if qpc(words) == 0 then return end
        local origin = words[1] * 4294967296 + words[0]
        local clock_origin = os_clock()
        timer_now = function()
          qpc(words)
          return (words[1] * 4294967296 + words[0] - origin) * per_tick + clock_origin
        end
        timer_kind = string.format("QueryPerformanceCounter (%.2f us steps)", per_tick * 1e6)
      end)
    end
  end
end

local NL = string.char(10)

local HITCH_MS = 50
local HITCH_LINES = 600
local SUMMARY_S = 60
local SUMMARY_ROWS = 10
local SPY_FRAMES = 8          -- frames a link's upvalues are watched
local SPY_NEED = 6            -- of those, frames the previous must match
local TIE_FRAMES = 16         -- frames timing the candidates when several match
-- v0.37.0 (a Nexus player, 2026-10-13: past 64 Lua mods the 64th was blamed
-- for every mod after it): the walk stopped at 64 links and the last one
-- counted everything below. 256 now; a chain that still reaches it says so
-- in the log and the window.
local MAX_LINKS = 256
local TABLE_FIELDS_MAX = 64
local MAP_LOGS = 40           -- chain maps written per session
local LOG_LIMIT = 4 * 1024 * 1024
local SESSION_LINES = 5000

local World = sr and rawget(sr, "World") or nil
local Gui = sr and rawget(sr, "Gui") or nil
local Keyboard = sr and rawget(sr, "Keyboard") or nil
local V3 = sr and rawget(sr, "Vector3") or nil
local Color = sr and rawget(sr, "Color") or nil
local original_main_world = App and rawget(App, "main_world") or nil

local FONT = "core/performance_hud/debug"
local PANEL_KEY = "home"
local TOAST_MS = 150          -- a stall this long ...
local TOAST_SHARE = 0.6       -- ... mostly in one mod shows a line
local TOAST_S = 5
local WINDOW_S = 30           -- the panel's rolling window
local PANEL_ROWS = 8
-- The window shows ms per second, as the first release did (v0.8.1, the user: rows of
-- 0.0x ms/frame cannot be told apart at a glance; the first release already
-- said only 50 ms/s and up is worth a look). It is for the obvious cases: a
-- mod is listed only at QUIET_MSS or more, or when it froze a frame for
-- QUIET_WORST_MS or more; the rest are counted on one line. AMBER_MSS and up
-- is amber. The log keeps every mod, in ms/s and ms/frame.
local QUIET_MSS = 10
local AMBER_MSS = 50
-- Video memory (v0.12.1), read every GPU_SAMPLE_S. Over the budget Windows
-- gives the process, it shows in play at most once every GPU_ALERT_QUIET_S.
local GPU_SAMPLE_S = 1
local GPU_ALERT_QUIET_S = 60
-- A mod that raised a Lua error in this many frames within one summary
-- minute gets its alert in missions, once a session (v0.14.0).
local ERROR_ALERT_FRAMES = 60
local gpu = { read = nil, last = nil, next_at = 0, alerted = nil, minute = nil, libraries = {} }
local QUIET_WORST_MS = 10
local REFRESH_S = 1
-- Log lines are written in one go every FLUSH_S seconds, or sooner once
-- FLUSH_LINES are waiting. Evidence (proven offline, likely in game): when a
-- write blocks (0.4-2 s on 2026-09-29), writing each line at once made the
-- stall's own line cause the next stall -- 60 stalls in 30 s in the test.
local FLUSH_S = 10
local FLUSH_LINES = 200

-- ------------------------------------------------------------------- log

local log_path = nil
do
  local ok, directory = pcall(os.getenv, "APPDATA")
  if ok and type(directory) == "string" then
    log_path = directory .. "\\Arrowhead\\Helldivers2\\mod_lag_finder.log"
  end
end

local function now()
  if type(timer_now) ~= "function" then return 0 end
  local ok, value = pcall(timer_now)
  if ok and type(value) == "number" then return value end
  return 0
end

local started_at = now()
local lines = 0

-- How long each log write took (open, append, close), kept for 30 s. On
-- 2026-09-29 a single appended line took 0.4-2 s in the stutter minutes,
-- and every stall pinned on Truth Whip's APW port fell on its heartbeat write.
local writes = {}

-- v0.24.0: the log stays open (writes.file) and each write is flushed.
-- Opening, appending and closing every 10 s cost a frame of 10 ms or more in
-- about half of all minutes in game (2026-10-03, ~1 MB log; a player saw
-- the 1% low frames drop with the Watchdog on). Measured on the same PC
-- (likely: an antivirus scan on close): open+append+close median 1.1 ms,
-- worst 7-15 ms; kept open, write+flush median 0.05 ms, worst 1.2 ms.
local function write_raw(text, mode)
  if log_path == nil then return end
  local ok_t, t0 = pcall(timer_now)
  if mode == "w" and writes.file ~= nil then
    pcall(writes.file.close, writes.file)
    writes.file = nil
  end
  if writes.file == nil then
    writes.file = io.open(log_path, mode)
    if writes.file == nil then return end
  end
  local file = writes.file
  local ok = pcall(function()
    file:write(text)
    file:flush()
  end)
  if not ok then
    pcall(file.close, file)
    writes.file = nil                       -- opened again on the next write
  end
  local ok_t1, t1 = pcall(timer_now)
  if ok_t and ok_t1 and type(t0) == "number" and type(t1) == "number" then
    writes[#writes + 1] = { at = t1, took = t1 - t0 }
    while #writes > 0 and t1 - writes[1].at > 30 do table.remove(writes, 1) end
  end
end

local unwritten, flushed_at = {}, started_at

local function flush_log()
  flushed_at = now()
  if #unwritten == 0 then return end
  local text = table.concat(unwritten)
  unwritten = {}
  write_raw(text, "a")
end

local function say(text)
  if lines >= SESSION_LINES then return end
  lines = lines + 1
  if lines == SESSION_LINES then text = "-- line budget spent for this session" end
  unwritten[#unwritten + 1] = string.format("t=%.2f %s", now() - started_at, text) .. NL
  -- __mlf_test_flush: only a test sets it, to read each line as it is said.
  if #unwritten >= FLUSH_LINES or rawget(_G, "__mlf_test_flush") then flush_log() end
end

local function file_size(path)
  local file = io.open(path, "rb")
  if file == nil then return nil end
  local ok, size = pcall(file.seek, file, "end")
  file:close()
  if ok and type(size) == "number" then return size end
  return nil
end

local function ms(seconds)
  return string.format("%.0f", seconds * 1000)
end

-- A mod's single worst frame, to 0.1 ms (the timer resolves it; os.clock
-- does not, which is why a small mod's worst showed 1 ms or more).
local function ms1(seconds)
  return string.format("%.1f", seconds * 1000)
end

-- ------------------------------------------------------------ deploys

-- Which game since the last Arsenal deploy this is. The user's experience
-- (2026-09-29): the first game after a (re)deploy is sometimes very laggy
-- and a restart fixes it; that day's logs agreed (all three bad games were
-- first games, no second game was bad). Arsenal writes the deploy time into
-- %LOCALAPPDATA%\hd2arsenal\deployment_snapshot.json ("timestamp", ms since
-- 1970); the count is kept in mod_lag_finder_state.txt. Read once, on the
-- first frame, not while the game loads.
local session = { deploy = nil, game_no = nil, started_os = nil,
                  stalls50 = 0, stalls200 = 0, frames = 0 }

local function read_all(path)
  local file = io.open(path, "rb")
  if file == nil then return nil end
  local ok, text = pcall(file.read, file, "*a")
  file:close()
  if ok and type(text) == "string" then return text end
  return nil
end

local function local_time(seconds)
  local ok, text = pcall(os.date, "%Y-%m-%d %H:%M:%S", seconds)
  if ok and type(text) == "string" then return text end
  return tostring(seconds)
end

local function note_deploy()
  local ok_now, now_s = pcall(os.time)
  session.started_os = ok_now and now_s or nil
  local ok_env, localappdata = pcall(os.getenv, "LOCALAPPDATA")
  if not ok_env or type(localappdata) ~= "string" then return end
  local snapshot = read_all(localappdata .. "\\hd2arsenal\\deployment_snapshot.json")
  local ms = snapshot and tonumber(string.match(snapshot, '"timestamp"%s*:%s*(%d+)')) or nil
  if ms == nil then
    say("deploy: no Arsenal deployment snapshot with a timestamp")
    return
  end
  local state_path = log_path and string.gsub(log_path, "mod_lag_finder%.log$",
                                              "mod_lag_finder_state.txt") or nil
  local last_ms, last_games = nil, 0
  local state = state_path and read_all(state_path) or nil
  if state ~= nil then
    last_ms = tonumber(string.match(state, "deploy=(%d+)"))
    last_games = tonumber(string.match(state, "games=(%d+)")) or 0
  end
  local games = (last_ms == ms) and (last_games + 1) or 1
  session.deploy, session.game_no = ms, games
  if state_path ~= nil then
    local file = io.open(state_path, "w")
    if file ~= nil then
      file:write(string.format("deploy=%.0f games=%d", ms, games) .. NL)
      file:close()
    end
  end
  local since = session.started_os and (session.started_os - ms / 1000) or nil
  say(string.format("deploy: Arsenal deployed at %s; this is game #%d since it%s",
                    local_time(ms / 1000), games,
                    since and string.format(", started %.1f min after it", since / 60) or ""))
end

local function session_line(kind)
  local played = 0
  local ok_now, now_s = pcall(os.time)
  if ok_now and session.started_os then played = (now_s - session.started_os) / 60 end
  return string.format("%s: game #%s since the deploy of %s, %.1f min played, " ..
                       "stalls >= 200 ms: %d (%.1f/min), >= 50 ms: %d",
                       kind, tostring(session.game_no or "?"),
                       session.deploy and local_time(session.deploy / 1000) or "?",
                       played, session.stalls200,
                       played > 0 and session.stalls200 / played or 0, session.stalls50)
end

-- ------------------------------------------------------------ inspection

local ours = setmetatable({}, { __mode = "k" })   -- our spies and shims -> what each passes to

local function source_of(fn)
  local ok, info = pcall(getinfo, fn, "S")
  if not ok or type(info) ~= "table" then return "?", 0, "?" end
  local source = tostring(info.source or "?")
  if string.sub(source, 1, 1) == "@" then source = string.sub(source, 2) end
  source = string.gsub(source, "%.lua$", "")
  return source, tonumber(info.linedefined) or 0, tostring(info.what or "?"),
         tonumber(info.lastlinedefined) or 0
end

-- A stale spy or shim of ours (a mod unhooked and left one in the chain, and
-- another mod stored it as its previous) stands for what it passes to
-- (v0.13.3, review [2]; v0.15.0 review [13]: one helper for the four places).
local function through_ours(value)
  for _ = 1, 8 do
    if type(ours[value]) ~= "function" then break end
    value = ours[value]
  end
  return value
end

local function is_lua_function(value)
  if type(value) ~= "function" or ours[value] then return false end
  local _, _, what = source_of(value)
  return what ~= "C"
end

local function is_mod_source(source)
  return string.find(source, "mods/", 1, true) ~= nil
end

-- Tables that belong to the game or are shared between mods: never touched.
local skip_table = setmetatable({}, { __mode = "k" })
do
  skip_table[_G] = true
  for _, value in pairs(_G) do
    if type(value) == "table" then skip_table[value] = true end
  end
  if type(sr) == "table" then
    for _, value in pairs(sr) do
      if type(value) == "table" then skip_table[value] = true end
    end
  end
end

-- slot: { kind = "uv" | "field", holder, key, name, original }
local function slot_get(slot)
  if slot.kind == "uv" then
    local _, value = getupvalue(slot.holder, slot.key)
    return value
  end
  return rawget(slot.holder, slot.key)
end

local function slot_set(slot, value)
  if slot.kind == "uv" then
    setupvalue(slot.holder, slot.key, value)
  else
    rawset(slot.holder, slot.key, value)
  end
end

local function upvalue_slots(fn, avoid)
  local out = {}
  for index = 1, 255 do
    local name, value = getupvalue(fn, index)
    if name == nil then break end
    value = through_ours(value)
    if not avoid[value] and is_lua_function(value) then
      out[#out + 1] = { kind = "uv", holder = fn, key = index, name = name,
                        original = value }
    end
  end
  return out
end

local function field_slots(fn, avoid)
  local out = {}
  for index = 1, 255 do
    local name, value = getupvalue(fn, index)
    if name == nil then break end
    if type(value) == "table" and not skip_table[value] and
       getmetatable(value) == nil then
      local count = 0
      for key, field in next, value do
        count = count + 1
        if count > TABLE_FIELDS_MAX then break end
        field = through_ours(field)
        if type(key) == "string" and not avoid[field] and is_lua_function(field) then
          out[#out + 1] = { kind = "field", holder = value, key = key,
                            name = name .. "." .. key, original = field }
        end
      end
    end
  end
  return out
end

-- ------------------------------------------------------------- the frame

local frame_dt, frame_argc = nil, 0

-- A pass-through spy: records its arguments, then tail-calls the original,
-- so it adds no stack frame and returns exactly what the original returns.
local function make_spy(rec, target)
  local spy = function(...)
    rec.calls = rec.calls + 1
    rec.argc = select("#", ...)
    rec.arg = (...)
    return target(...)
  end
  ours[spy] = target
  return spy
end

-- A timing spy for the tie-break; called once a frame, so not a tail call.
local function make_timer(rec, target)
  local function finish(t0, ...)
    rec.time = rec.time + (timer_now() - t0)
    return ...
  end
  local timer = function(...)
    rec.calls = rec.calls + 1
    rec.argc = select("#", ...)
    rec.arg = (...)
    return finish(timer_now(), target(...))
  end
  ours[timer] = target
  return timer
end

-- The shim a mapped link keeps: its duration, this frame and the last.
-- (v0.14.0 also stamped the frame each link was entered and left in, to
-- find where an error came from; v0.15.0 reads that off the stack.)
-- With a handler (v0.16.0, see "errors") the link runs under xpcall: an
-- error from it is noted while its stack is whole, then raised on unchanged,
-- so a mod above that catches it no longer hides it from this module. The
-- game sees the same as before. Without (a VM whose xpcall cannot pass
-- arguments on) it is v0.15.0's plain call.
--
-- Each run is stamped with the frame it finished in (counter.frame_id,
-- v0.16.1): a link a Lua error cut off did not run, and its time from an
-- older frame must not be read as this one's.
--
-- v0.21.0: with the GC probe on (counter.gcp, see "gc probe") each run also
-- keeps the collector's heap total and its mark (threshold * 8 + state) at
-- entry and exit: two uint32 reads and a byte, no allocation. Off, they are 0.
--
-- v0.33.0: with the black box on (counter.box, see "black box") each run
-- stores its mod's number in the box on entry and puts the outer one back
-- on exit: a read and two stores.
local function make_shim(link, target, handler, counter)
  local gcp = counter.gcp
  local P, B = gcp ~= nil and gcp.p32 or nil, gcp ~= nil and gcp.p8 or nil
  local W = counter.box
  local id = W ~= nil and counter.box_id(link.source) or 0
  local function gh() if P == nil then return 0 end return P[8] end
  local function gm() if P == nil then return 0 end return P[9] * 8 + B[41] end
  local function stamp(t0, h0, m0)
    local took = timer_now() - t0
    link.prev_incl, link.prev_frame = link.last_incl, link.last_frame
    link.last_incl, link.last_frame = took, counter.frame_id
    link.prev_eh, link.prev_em, link.prev_xh, link.prev_xm =
      link.last_eh, link.last_em, link.last_xh, link.last_xm
    link.last_eh, link.last_em, link.last_xh, link.last_xm = h0, m0, gh(), gm()
  end
  local function finish(outer, t0, h0, m0, ...)
    if W ~= nil then W[3] = outer end
    stamp(t0, h0, m0)
    return ...
  end
  local shim
  if handler == nil then
    shim = function(...)
      local outer = nil
      if W ~= nil then outer, W[3] = W[3], id end
      return finish(outer, timer_now(), gh(), gm(), target(...))
    end
  else
    local function settle_up(outer, t0, h0, m0, ok, ...)
      if W ~= nil then W[3] = outer end
      stamp(t0, h0, m0)
      if ok then return ... end
      error((...), 0)
    end
    shim = function(...)
      local outer = nil
      if W ~= nil then outer, W[3] = W[3], id end
      return settle_up(outer, timer_now(), gh(), gm(), xpcall(target, handler, ...))
    end
  end
  ours[shim] = target
  return shim
end

-- ------------------------------------------------------------ the chain

local installed = { wrapper = nil, generation = 0, last_tick_at = nil,
                    mw_calls = 0, tick_calls = 0,
                    shutdown_wrapper = nil, rearmed = false,
                    told_tick = false,
                    previous_slot = nil, bootstrap = nil, bootstrap_slot = nil,
                    settling = 0, shutdown_done = false,
                    -- v0.15.0 (see "errors"): our depth in the chain (a mod
                    -- below may call _G.update again), the mod whose error
                    -- went on to the game and whether the game lived, and
                    -- the file that tells the next launch.
                    depth = 0, crash_pending = nil, survives = {}, error_logged = {},
                    crash_path = nil, xpcall_args = nil,
                    -- v0.16.0: the error noted last this frame (each shim it
                    -- passes sees it again), whether one cut this frame short
                    -- anywhere, and the mod each message came from.
                    last_err = nil, frame_failed = false, culprit_cache = {}, culprit_cached = 0,
                    frame_id = 0,          -- v0.16.1: counts our wrapper's frames, for the shims' stamps
                    errors = {}, errors_session = {}, error_told = {},
                    -- v0.13.0: the resource-name hashes of every Lua resource
                    -- in the enabled mods' archives (nil when no Arsenal list
                    -- was read), and the pure-Lua murmur64 that matches them.
                    archive_hashes = nil, name_hash = nil, hash_of = nil }

-- Every timing shim runs its link under this handler (v0.16.0): arm() puts
-- the note-taker in installed.note.
installed.link_handler = function(err)
  local note = installed.note
  if note ~= nil then pcall(note, err) end
  return err
end

-- ------------------------------------------------------------ gc probe

-- v0.21.0, log only (the user, 2026-10-03). A player found that removing the
-- costliest mod made another one twice as costly, again and again. One
-- suspect is Lua's garbage collector: every mod shares one heap, and the
-- collector does its work inside whichever mod happens to allocate when a
-- step is due, so that mod is charged for garbage another made. This
-- measures, per minute in the log: how much of the mods' time was collector
-- steps, which mods those steps landed on, and which mods make the garbage.
--
-- The VM says none of this, so it is read from LuaJIT's own state.
-- Evidence: proven offline on the game's bin/lua51.dll (LuaJIT 2.1.0-alpha,
-- not GC64, 2026-10-03): a thread object's glref (uint32 at +8) is the
-- global_State; in it gc.total is the uint32 at +32 (follows
-- collectgarbage("count") * 1024), gc.threshold at +36, gc.state the byte at
-- +41 (0 pause, 1 propagate, 2 atomic, 3 sweepstring, 4 sweep, 5 finalize),
-- gc.estimate at +76, stepmul +80, pause +84. Every collector step moves the
-- threshold, so a changed mark means a step ran. Only the sweep phases free
-- memory, so a heap rise with no sweep is what was allocated.
-- The layout is checked through ReadProcessMemory before any direct read; a
-- build it does not match turns the probe off and says why. A test hands
-- the real ffi in __hd2_native_test.ffi (hd2fake with ffi allowed).
installed.gc_why = "no ffi"
do
  local seam = rawget(_G, "__hd2_native_test")
  local ffi = nil
  if type(seam) == "table" then
    ffi = seam.ffi
  else
    local loader = rawget(_G, "require")
    if type(loader) == "function" then
      local ok, lib = pcall(loader, "ffi")
      if ok and type(lib) == "table" then ffi = lib end
    end
  end
  if type(ffi) == "table" and type(collect) == "function" then
    local ok, err = pcall(function()
      if ffi.abi("gc64") or not ffi.abi("64bit") then
        installed.gc_why = "not the game's LuaJIT (GC64 or 32-bit)"
        return
      end
      for _, decl in ipairs({ "void *GetCurrentProcess(void);",
                              "int ReadProcessMemory(void *process, const void *address," ..
                                " void *buffer, size_t size, size_t *read);" }) do
        pcall(ffi.cdef, decl)
      end
      local kernel = ffi.load("kernel32")
      local rpm = ffi.cast("int (*)(void *, const void *, void *, size_t, size_t *)",
                           kernel.ReadProcessMemory)
      local process = kernel.GetCurrentProcess()
      local words, got = ffi.new("uint32_t[24]"), ffi.new("size_t[1]")
      local function safe(address, count)
        got[0] = 0
        local r = rpm(process, ffi.cast("const void *", address), words, count * 4, got)
        return r ~= 0 and tonumber(got[0]) == count * 4
      end
      -- string.format, not tostring: v0.21.0/v0.22.0 got no address in game
      -- on 2026-10-03 (offline it did), and a mod may replace the global
      -- tostring; LuaJIT's "%s" formats a thread itself. What it saw is
      -- logged, so a third miss says why.
      local co = coroutine.create(function() end)
      local text = string.format("%s", co)
      local hex = string.match(text, "0x(%x+)") or string.match(text, "(%x%x%x%x%x%x%x%x+)%s*$")
      local thread = hex and tonumber(hex, 16) or nil
      if thread == nil then
        installed.gc_why = string.format("no thread address in %q (tostring gives %q)",
                                         string.sub(text, 1, 40), string.sub(tostring(co), 1, 40))
        return
      end
      if not safe(thread, 4) then
        installed.gc_why = string.format("thread at %x not readable (%q)", thread, string.sub(text, 1, 40))
        return
      end
      local g = words[2]
      if g == 0 or not safe(g, 24) then
        installed.gc_why = "global state not readable"
        return
      end
      local total = words[8]
      local state, stepmul, pause = math.floor(words[10] / 256) % 256, words[20], words[21]
      local count = collect("count") * 1024
      if math.abs(total - count) > 65536 or state > 5 or stepmul < 10 or stepmul > 100000
         or pause < 10 or pause > 100000 then
        installed.gc_why = string.format("layout not recognised (total %d vs %d, state %d, " ..
                                         "stepmul %d, pause %d)", total, count, state, stepmul, pause)
        return
      end
      installed.gcp = { p32 = ffi.cast("uint32_t *", g), p8 = ffi.cast("uint8_t *", g),
                        ffi = ffi, keep = co }
      installed.gc_why = nil
    end)
    if not ok then installed.gc_why = "probe failed: " .. tostring(err) end
  end
end

local links = {}              -- mapped chain, top first
local our_index = nil         -- our wrapper's place in it
local mapped_top = nil
local mapping = nil
local maps_logged = 0
-- MDL runs the scripts it starts live inside its own link, so the chain
-- shows them as one row. MDL 1.0.5-p11 times each one itself and exposes it
-- (MDL.perf == 1; record.perf = { total, last, frames } on the records of
-- MDL.manager.mods). Their time is charged to their own rows and taken out
-- of MDL's. Reading the records is all this does: wrapping their update from
-- outside would make a self-re-arming script inside MDL's sandbox think it
-- had been displaced.
local MDL_SOURCE = "mods/mdl/runtime"
local runtime_index = nil-- Mods hooked into the chain more than once (a re-arm leaves the old wrapper
-- in place). Three or more of one mod means it keeps re-arming: the
-- escalation seen in game on 2026-09-29 10:36 had two mods at x4 each.
local REHOOK_COPIES, REHOOK_QUIET_S = 3, 60
local rehook = { repeated = {}, length = 0, fresh = false, last_alert = nil }
local shims = {}              -- slots holding a shim, to put back

-- LuaJIT can compile a never-reassigned upvalue into a trace as a constant
-- (lj_record.c, rec_upvalue_constify: likely, not seen in game), and a trace
-- made before a slot was swapped would then keep calling what was there.
-- So after every swap the compiled code of each function in the chain is
-- dropped -- per function (jit.flush(fn)), never the whole cache, which
-- the loader's LuaJIT cache watcher counts.
local jit_lib = rawget(_G, "jit")
local jit_flush = type(jit_lib) == "table" and rawget(jit_lib, "flush") or nil

local function settle(extra)
  if type(jit_flush) ~= "function" then return end
  local done = {}
  local function drop(fn)
    if type(fn) == "function" and not done[fn] then
      done[fn] = true
      pcall(jit_flush, fn)
    end
  end
  for _, link in ipairs(links) do drop(link.fn) end
  if mapping ~= nil then
    for _, link in ipairs(mapping.links) do drop(link.fn) end
  end
  drop(installed.wrapper)
  if extra ~= nil then drop(extra) end
end
local function restore_all()
  for _, slot in ipairs(shims) do
    if slot_get(slot) == slot.shim then slot_set(slot, slot.original) end
  end
  shims = {}
  if mapping ~= nil and mapping.slots ~= nil then
    for _, slot in ipairs(mapping.slots) do
      if slot.spy ~= nil and slot_get(slot) == slot.spy then
        slot_set(slot, slot.original)
      end
    end
  end
  settle()
  mapping = nil
  links, our_index = {}, nil
end

local function new_link(fn, slot)
  local source, line, _, last = source_of(fn)
  return { fn = fn, slot = slot, source = source, line = line, last = last,
           upname = slot and slot.name or "_G.update",
           last_incl = 0, prev_incl = 0 }
end

local function link_label(link)
  return link.source .. ":" .. link.line
end

local function spy_on(slots, maker)
  for _, slot in ipairs(slots) do
    slot.rec = { calls = 0, seen = 0, hits = 0, time = 0, argc = 0, arg = nil }
    slot.spy = maker(slot.rec, slot.original)
    slot_set(slot, slot.spy)
  end
  settle()
end

local function unspy(slots)
  for _, slot in ipairs(slots) do
    if slot.spy ~= nil and slot_get(slot) == slot.spy then
      slot_set(slot, slot.original)
    end
    slot.spy = nil
  end
  settle()
end

local function avoid_set()
  local avoid = {}
  -- Either can be nil (a game without shutdown): a nil key would raise, and
  -- the walk would stay half-built for the session (v0.12.7).
  local update, shutdown = rawget(_G, "update"), rawget(_G, "shutdown")
  if update ~= nil then avoid[update] = true end
  if shutdown ~= nil then avoid[shutdown] = true end
  for _, link in ipairs(mapping.links) do avoid[link.fn] = true end
  return avoid
end

local finish_mapping

local function name_score(name)
  local lower = string.lower(name or "")
  if string.find(lower, "tick", 1, true) then return 0 end
  for _, hint in ipairs({ "prev", "orig", "old", "base", "next", "chain",
                          "wrap", "inner", "upstream", "game", "update" }) do
    if string.find(lower, hint, 1, true) then return 1 end
  end
  return 0
end

-- The first link that is not "mods/..." is the game -- unless a mod ships a
-- Lua resource under that name (v0.13.0). A chunk's source name is its
-- resource name, and an archive's file table holds murmur64 of every
-- resource name (proven 2026-09-30: 58 of 58 HD2-Addon rows, and HD2 HUD+'s
-- "boot" f476df93691895fa and "mods/hd2_hud/product" ef0157640928609f).
-- HD2 HUD+ 0.1.12 hooks update from its own copy of "boot", so that link is
-- in HUD+'s archive: it is walked like any mod's link, with the usual dt test
-- on all its upvalues and fields. The game's own scripts are in no mod
-- archive (likely: archives carry only what a mod ships). A patch wraps the
-- game's script of the same name, so a second link of that name is the game
-- (likely; HUD+ loads the original boot as stripped bytecode under no name,
-- so there it never comes up). With no Arsenal list read (another manager,
-- a manual install), the v0.12.4 probe is kept: a link that is not "mods/"
-- is tested once, watching only upvalues named like a stored previous (the
-- game's own code is compiled with no names, so it is never spied on).
-- (The hint test lives inside begin_step: the main chunk is at Lua's
-- 200-locals limit.)
local function begin_step()
  local link = mapping.links[#mapping.links]
  if #mapping.links >= MAX_LINKS then
    if not installed.link_limit then
      installed.link_limit = true
      say(string.format("chain: more than %d hooks; the last one mapped counts every mod below it", MAX_LINKS))
    end
    return finish_mapping("link limit")
  end
  local known = installed.archive_hashes
  -- A patch link being retried stays a patch (v0.13.3, review [1]: the retry
  -- found its name already taken and called it the game). A name in no
  -- archive goes to the name-hint probe, as before v0.13.0 (review [3]: a
  -- boot patch installed by hand, or from another profile, was the game).
  local patch = link.patch
  if not patch and mapping.seen_mods and not is_mod_source(link.source) and known ~= nil
     and known[installed.hash_of(link.source)] and not mapping.patched[link.source] then
    mapping.patched[link.source] = true
    link.patch, patch = true, true
  end
  if not patch and mapping.seen_mods and not is_mod_source(link.source) then
    local named = {}
    for _, slot in ipairs(upvalue_slots(link.fn, avoid_set())) do
      local lower = string.lower(slot.name or "")
      -- v0.18.0 adds old/base/next/update (name_score's words): the game's
      -- own bottoms seen in logs (LJC:0, boot:0) are main chunks, which have
      -- no upvalues at all.
      for _, hint in ipairs({ "orig", "prev", "upstream", "chain", "wrapped", "old", "base", "next", "update" }) do
        if string.find(lower, hint, 1, true) then
          named[#named + 1] = slot
          break
        end
      end
    end
    if #named == 0 then
      link.bottom = "game"
      return finish_mapping("reached the game")
    end
    link.boot_probe = true
    mapping.slots, mapping.frames, mapping.phase = named, 0, "boot"
    spy_on(named, make_spy)
    return
  end
  if is_mod_source(link.source) then mapping.seen_mods = true end
  -- Our own wrapper: its previous is known, nothing to spy on.
  if link.fn == installed.wrapper and installed.previous_slot ~= nil then
    mapping.slots, mapping.phase = { installed.previous_slot }, "own"
    return
  end
  -- Our start-up hook (v0.12.5): the same, and it is not a mod of its own.
  if link.fn == installed.bootstrap and installed.bootstrap_slot ~= nil then
    link.bootstrap = true
    mapping.slots, mapping.phase = { installed.bootstrap_slot }, "own"
    return
  end
  local slots = upvalue_slots(link.fn, avoid_set())
  mapping.phase = "upvalues"
  if #slots == 0 and (is_mod_source(link.source) or link.patch) then
    slots = field_slots(link.fn, avoid_set())
    mapping.phase = "fields"
  end
  if #slots == 0 then
    link.bottom = "no function held"
    return finish_mapping("bottom")
  end
  mapping.slots, mapping.frames = slots, 0
  spy_on(slots, make_spy)
end

local function adopt(slot)
  local from = mapping.links[#mapping.links]
  if from ~= nil and from.boot_probe then
    from.boot_probe, from.boot_patch = nil, true
  end
  local link = new_link(slot.original, slot)
  link.tie = slot.tie
  slot.shim = make_shim(link, slot.original, installed.xpcall_args and installed.link_handler or nil, installed)
  slot_set(slot, slot.shim)
  shims[#shims + 1] = slot
  mapping.links[#mapping.links + 1] = link
  mapping.slots = nil
  mapping.retried = false
  settle()
  begin_step()
end

local function tally(slots)
  for _, slot in ipairs(slots) do
    local rec = slot.rec
    local delta = rec.calls - rec.seen
    rec.seen = rec.calls
    if delta == 1 and rec.argc == frame_argc and rawequal(rec.arg, frame_dt) then
      rec.hits = rec.hits + 1
    end
  end
end

local function step_mapping()
  if mapping.phase == "own" then
    return adopt(mapping.slots[1])
  end
  local slots = mapping.slots
  tally(slots)
  mapping.frames = mapping.frames + 1

  if mapping.phase == "tie" then
    if mapping.frames < TIE_FRAMES then return end
    local best = nil
    for _, slot in ipairs(slots) do
      if best == nil or slot.rec.time > best.rec.time then best = slot end
    end
    unspy(slots)
    best.tie = #slots
    return adopt(best)
  end

  if mapping.frames < SPY_FRAMES then return end
  local matched = {}
  local seen = {}
  for _, slot in ipairs(slots) do
    if slot.rec.hits >= SPY_NEED then matched[#matched + 1] = slot end
    seen[#seen + 1] = string.format("%s=%d/%d", slot.name == "" and "?" or slot.name,
                                    slot.rec.hits, slot.rec.calls)
  end
  mapping.watched = table.concat(seen, " ")
  unspy(slots)
  if #matched > 1 then
    local named = {}
    for _, slot in ipairs(matched) do
      if name_score(slot.name) > 0 then named[#named + 1] = slot end
    end
    if #named >= 1 then matched = named end
  end
  if #matched > 1 then
    -- A previous is another mod's wrapper or the game; a helper of the
    -- link's own file is not.
    local own_source = mapping.links[#mapping.links].source
    local foreign = {}
    for _, slot in ipairs(matched) do
      if source_of(slot.original) ~= own_source then foreign[#foreign + 1] = slot end
    end
    if #foreign >= 1 then matched = foreign end
  end
  if #matched == 1 then return adopt(matched[1]) end
  if #matched > 1 then
    mapping.phase, mapping.slots, mapping.frames = "tie", matched, 0
    spy_on(matched, make_timer)
    return
  end
  local link = mapping.links[#mapping.links]
  if link.boot_probe then                   -- nothing named like a previous was called with dt
    -- Something named like a stored previous is no game code (its bottoms
    -- have no upvalues): a mod's link whose previous we could not follow --
    -- shown under its own name with all below it, not as "(the game)"
    -- (v0.18.0: a player's "solo_bunker_probe" holds "previous" and
    -- "original_update", and read as "(the game)" at 150-550 ms/s in every
    -- game of his log, 2026-10-01).
    link.boot_probe = nil
    link.bottom = "nothing called with dt"
    say("bottom at " .. link_label(link) .. ": named like a mod's previous, but none was called with dt " ..
        tostring(mapping.watched))
    return finish_mapping("bottom")
  end
  if mapping.phase == "upvalues" and (is_mod_source(link.source) or link.patch) then
    local fields = field_slots(link.fn, avoid_set())
    if #fields > 0 then
      mapping.phase, mapping.slots, mapping.frames = "fields", fields, 0
      spy_on(fields, make_spy)
      return
    end
  end
  -- Once more before giving up on a mod's link: one watch can miss (a mod
  -- that skipped its previous for a frame).
  if (is_mod_source(link.source) or link.patch) and not mapping.retried then
    mapping.retried = true
    return begin_step()
  end
  link.bottom = "nothing called with dt"
  say("bottom at " .. link_label(link) .. ": watched " .. mapping.phase .. " (hits/calls) " ..
      tostring(mapping.watched))
  finish_mapping("bottom")
end

-- After the chain's links change: where this module and MDL sit, and which
-- mods are hooked more than once (shared by a full walk and a restack).
installed.relinked = function()
  our_index = nil
  runtime_index = nil
  for index, link in ipairs(links) do
    if link.fn == installed.wrapper then our_index = index end
    if link.source == MDL_SOURCE and runtime_index == nil then runtime_index = index end
  end
  -- v0.36.0: copies of the same function (source and line), not of the same
  -- file: Super Holo Kit hooks the update twice by design (its tick at load,
  -- and its own escape-menu tab, wrapped once on top when the menu first
  -- opens), and showed "hooked more than once" every game. A mod loaded
  -- twice, or one that wraps again and again, repeats the same function.
  local copies = {}
  for _, link in ipairs(links) do
    if link.bottom ~= "game" then
      local key = link.source .. ":" .. tostring(link.line or 0)
      local c = copies[key]
      if c == nil then
        c = { source = link.source, n = 0 }
        copies[key] = c
      end
      c.n = c.n + 1
    end
  end
  local repeated = {}
  for _, c in pairs(copies) do
    if c.n >= 2 then repeated[#repeated + 1] = { source = c.source, n = c.n } end
  end
  table.sort(repeated, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.source < b.source
  end)
  rehook.repeated, rehook.length, rehook.fresh = repeated, #links, true
  if #repeated > 0 and repeated[1].n >= REHOOK_COPIES then
    local parts = {}
    for _, r in ipairs(repeated) do parts[#parts + 1] = r.source .. " x" .. r.n end
    say(string.format("rehook: %d links, hooked more than once: %s", #links,
                      table.concat(parts, ", ")))
  end
end

finish_mapping = function(why)
  -- A link adopted this tick has no finished frame yet, and one adopted a
  -- tick ago has only one: until every shim has run twice, the link above
  -- the newest would be charged the whole frame below it (v0.12.7).
  installed.settling = 2
  -- Our start-up hook is walked through (its previous is timed by the shim
  -- in its slot) but kept out of the chain: the link above it then counts
  -- its few microseconds, and chains read as they did before v0.12.5.
  links = {}
  local carried = nil            -- the upvalue the hook was found in names the link below it
  for _, link in ipairs(mapping.links) do
    if link.bootstrap then
      carried = link.upname
    else
      if carried ~= nil then link.upname, carried = carried, nil end
      links[#links + 1] = link
    end
  end
  mapping = nil
  installed.relinked()
  installed.log_chain(why)
end

installed.log_chain = function(why)
  if maps_logged >= MAP_LOGS then return end
  maps_logged = maps_logged + 1
  say(string.format("chain mapped: %d links (%s); top is %s, its own time is not measured",
                    #links, why, link_label(links[1])))
  for index, link in ipairs(links) do
    local notes = {}
    if index == our_index then notes[#notes + 1] = "this module" end
    if link.tie then notes[#notes + 1] = "chosen of " .. link.tie .. " by time" end
    if link.bottom then notes[#notes + 1] = "bottom: " .. link.bottom end
    if link.boot_patch then notes[#notes + 1] = "boot patch: a mod in the game's boot script" end
    if link.patch then notes[#notes + 1] = "a mod's own copy of a game script (in its archive)" end
    say(string.format("  #%d %s via %s%s", index, link_label(link),
                      link.upname == "" and "(stripped)" or link.upname,
                      #notes > 0 and ("  [" .. table.concat(notes, "; ") .. "]") or ""))
  end
end

local function start_mapping(top)
  restore_all()
  mapped_top = top
  -- A mod that unhooks itself restores the previous it saved -- which may be
  -- one of our shims, put in its slot while it was mapped. _G.update then
  -- holds a stale shim of ours for good (it only passes on). The walk starts
  -- at what it passes to: counted as a link it read as this module hooked
  -- twice, on top, and kept the mod that left reachable to the memory walk
  -- through the shim's old slot (v0.13.2, found by the memory-leave test).
  local first = through_ours(top)
  mapping = { links = { new_link(first, nil) }, seen_mods = false, patched = {} }
  begin_step()
end

-- A hook that comes and goes on top (v0.29.0). HD2Runtime 0.20.1's
-- scheduler (the "scheduler" row a player's window showed, 2026-10-04)
-- puts a callback on _G.update while it has work and puts the update back
-- when it has none, every few seconds. Each change made a full walk start
-- again; 30 links take ~4 s to walk, so the walk never finished: the mods'
-- rows fell to near 0 and the walking itself was this module's cost (the
-- player saw it at 38.9 ms/s). Here the two shapes that change only the
-- top are taken as they are, with no walk:
--   on top: the new top holds the old top in one upvalue -> a shim goes in
--     that upvalue (the old top's link is reused) and the new top is
--     links[1];
--   off the top: the new top is links[2] (or our shim of it, which is what
--     the leaving hook restores) -> links[1] goes.
-- Anything else is a full walk, as before. Likely, measured in the fake.
-- LuaJIT code cache flushes, as Bingus Shared Loader v18+ counts them
-- (CowboyBingusModLoader.jit.flushes, its trace watcher; v19 starts the
-- cache at 64 MB). A flush throws away every mod's compiled code; the
-- frames after it run uncompiled until each trace is compiled again.
-- Likely, not measured in game: that is a stall no single mod causes.
installed.jit_minute = 0
installed.jit_watch = function(at)
  local loader = rawget(_G, "CowboyBingusModLoader")
  local cache = type(loader) == "table" and rawget(loader, "jit") or nil
  local flushes = type(cache) == "table" and rawget(cache, "flushes") or nil
  if type(flushes) ~= "number" then return end
  local seen = installed.jit_seen
  installed.jit_seen = flushes
  if seen == nil or flushes <= seen then return end
  installed.jit_flush_at = at
  installed.jit_minute = installed.jit_minute + (flushes - seen)
  say(string.format("jit: LuaJIT code cache flushed (%d this session; machine code %s KB, %s traces)",
                    flushes, tostring(rawget(cache, "mcode_kb") or "?"), tostring(rawget(cache, "traces") or "?")))
end

installed.restacks = 0
installed.restack_logged = {}
-- The chain is written the first time each hook comes on or leaves the top
-- (a scheduler that comes and goes every few seconds is written twice).
installed.restack_log = function(kind, link, why)
  local key = kind .. " " .. tostring(link.source)
  if installed.restack_logged[key] then return end
  installed.restack_logged[key] = true
  installed.log_chain(why)
end
installed.restack = function(top)
  if mapping ~= nil or #links < 2 or mapped_top == nil or installed.settling > 0 then return false end
  local first = links[1]
  if through_ours(top) == links[2].fn then
    table.remove(links, 1)
    local slot = links[1].slot
    if slot ~= nil and slot_get(slot) == slot.shim then slot_set(slot, slot.original) end
    for index = #shims, 1, -1 do
      if shims[index] == slot then table.remove(shims, index) end
    end
    links[1].slot, links[1].upname = nil, "_G.update"
    mapped_top = top
    -- No settling (v0.32.1): no shim is new, and the new top is not charged.
    -- With it, a stall in the two frames after the menu opened or closed
    -- (HD2 HUD+ 0.2.2 climbs on or off the top then) read "chain not
    -- mapped yet" in game (2026-10-07, six times in five minutes).
    installed.relinked()
    installed.restacks = installed.restacks + 1
    installed.restack_log("left", first, "a hook left the top, no new walk")
    return true
  end
  if type(top) ~= "function" or ours[top] ~= nil then return false end
  local found = nil
  for index = 1, 255 do
    local name, value = getupvalue(top, index)
    if name == nil then break end
    if value == mapped_top then
      if found ~= nil then return false end             -- two of them: walk
      found = { kind = "uv", holder = top, key = index, name = name }
    end
  end
  if found == nil then return false end
  if ours[mapped_top] ~= nil then
    -- Our shim of the old top, put back by a hook that left: it still times
    -- that link (the same link object), so it only gets its new slot.
    found.original, found.shim = ours[mapped_top], mapped_top
  else
    found.original = mapped_top
    found.shim = make_shim(first, mapped_top, installed.xpcall_args and installed.link_handler or nil, installed)
    slot_set(found, found.shim)
  end
  shims[#shims + 1] = found
  first.slot, first.upname = found, found.name
  local link = new_link(top, nil)
  table.insert(links, 1, link)
  mapped_top = top
  if type(jit_flush) == "function" then
    pcall(jit_flush, top)
    pcall(jit_flush, first.fn)
  end
  -- No settling (v0.32.1): the one new shim times the old top, now second;
  -- until it has run, its frame stamp makes it read 0 (settled_incl), and
  -- the only link above it is the new top, which is never charged.
  installed.relinked()
  installed.restacks = installed.restacks + 1
  installed.restack_log("came", link, "a hook came on top, no new walk")
  return true
end

-- ------------------------------------------------------------ log writes

-- The slowest log write of the last 30 s (see write_raw).
local function writes_worst()
  local worst = 0
  for _, w in ipairs(writes) do
    if w.took > worst then worst = w.took end
  end
  return worst
end

-- ------------------------------------------------------------- accounting

-- Each link's inclusive time for the frame that has just fully finished
-- (the one before the frame our tick runs in): links above this module
-- finish after our tick, so their last run is that frame; links below
-- finished inside this one, so theirs is the one before. By stamp since
-- v0.16.1: a link that did not run in that frame -- a Lua error cut it off
-- -- costs nothing in it. v0.16.0 charged nothing at all in a frame with an
-- error, so with a mod raising every frame the whole table fell to zero.
local function settled_incl(index, link)
  local frame = installed.frame_id - 1
  if link.last_frame == frame then return link.last_incl end
  if link.prev_frame == frame then return link.prev_incl end
  return 0
end

-- v0.43.0 (in game 2026-10-13, 30 links: this part of the tick took
-- ~2.5 ms/s, the largest of this module's own): each link keeps one entry
-- table, refilled every frame, where a new one was made for every link
-- every frame (~450 KB/s of garbage). Nothing keeps an entry past the tick.
local function selfs()
  local out = {}
  local n = #links
  for index = n, 2, -1 do
    local link = links[index]
    local incl = settled_incl(index, link)
    local below = index < n and settled_incl(index + 1, links[index + 1]) or 0
    local own = incl - below
    if own < 0 then own = 0 end
    local entry = link.self_entry
    if entry == nil then
      entry = { link = link }
      link.self_entry = entry
    end
    entry.own, entry.incl = own, incl
    out[index] = entry
  end
  return out
end

-- The bottom link's time includes everything below it: the game when the
-- walk reached it, otherwise whatever the walk could not see past.
local function owner(link)
  if link.bottom == "game" then return "(the game)" end
  if link.boot_patch or link.bottom ~= nil then
    -- v0.43.0: made once per link and kind, not every frame.
    local kind = link.boot_patch and " (boot patch)" or " (+ all below it)"
    if link.owner_kind ~= kind or link.owner_of ~= link.source then
      link.owner_kind, link.owner_of, link.owner_text = kind, link.source, link.source .. kind
    end
    return link.owner_text
  end
  return link.source
end

-- The GC probe's minute (v0.21.0, see "gc probe"). For each link, from its
-- shim's readings in the frame selfs() settled: the heap rise and whether a
-- collector step ran in its own part -- [entry, entry of the link below] and
-- [exit of the link below, exit] -- the same split as its own time. A step
-- in its own part makes that frame's time above the link's usual time (an
-- average over its frames with no step) collector time. Rises in frames
-- with no sweep are its garbage; the rest are estimated from those.
-- Likely: a mod's own time varies from frame to frame, so the split is
-- statistical, good over a minute, not for one frame.
installed.gcw = { rows = {}, chain = 0, frames = 0, chain_gc_frames = 0,
                  vm = { frames = 0, clean = 0, alloc = 0, stepped = 0, cycles = 0 },
                  worst_atomic = 0, worst_atomic_key = nil, note = nil,
                  outside = { plain = { n = 0 }, step = { n = 0 }, atomic = { n = 0 } } }

-- (In a block: the main chunk is at Lua's limit of 200 locals.)
do
local function gc_settled(link, frame)
  if link.last_frame == frame then return link.last_eh, link.last_em, link.last_xh, link.last_xm end
  if link.prev_frame == frame then return link.prev_eh, link.prev_em, link.prev_xh, link.prev_xm end
  return nil
end

-- A window from mark a to mark b: did a step run, did it sweep (free), did
-- it pass the atomic step (the one step that is not incremental).
local function gc_window(a, b)
  if a == b then return false, false, false end
  local sa, sb = a % 8, b % 8
  local wrap = sb < sa
  return true, wrap or sa >= 3 or sb >= 3, sa <= 2 and (sb >= 3 or wrap)
end

-- v0.43.0: the split runs in one frame of GC_EVERY and counts that frame
-- GC_EVERY times (it is statistical anyway: good over a minute, not for one
-- frame); a frame long enough to be a stall is always looked at, for its
-- line, and counted 0 times when it is not a sampled one. In game it was
-- part of this module's largest share (~2.5 ms/s with 30 links).
installed.gc_every = 4
installed.gc_frame = function(frame_selfs, weight)
  local w = installed.gcw
  w.note = nil
  if installed.gcp == nil or frame_selfs == nil then return end
  weight = weight or 1
  local frame = installed.frame_id - 1
  local n = #links
  local any, notes = false, nil
  for index = n, 2, -1 do
    local entry = frame_selfs[index]
    local link = links[index]
    local eh, em, xh, xm = gc_settled(link, frame)
    if entry ~= nil and eh ~= nil and em ~= 0 then
      local neh, nem, nxh, nxm = nil, nil, nil, nil
      if index < n then neh, nem, nxh, nxm = gc_settled(links[index + 1], frame) end
      local alloc, stepped, swept, atomic
      if neh ~= nil then
        alloc = (xh - eh) - (nxh - neh)
        local s1, w1, a1 = gc_window(em, nem)
        local s2, w2, a2 = gc_window(nxm, xm)
        stepped, swept, atomic = s1 or s2, w1 or w2, a1 or a2
      else
        alloc = xh - eh
        stepped, swept, atomic = gc_window(em, xm)
      end
      local key = owner(link)
      local row = w.rows[key]
      if row == nil then
        row = { frames = 0, clean = 0, alloc = 0, stepped = 0, gc = 0 }
        w.rows[key] = row
      end
      row.frames = row.frames + weight
      w.chain = w.chain + entry.own * weight
      if not swept then
        row.clean = row.clean + weight
        row.alloc = row.alloc + math.max(0, alloc) * weight
      end
      local base = link.gc_base
      if not stepped then
        if weight > 0 then link.gc_base = base == nil and entry.own or base + (entry.own - base) * 0.05 end
      else
        any = true
        row.stepped = row.stepped + weight
        local extra = math.max(0, entry.own - (base or entry.own))
        row.gc = row.gc + extra * weight
        if atomic and extra > w.worst_atomic then
          w.worst_atomic, w.worst_atomic_key = extra, key
        end
        if extra >= 0.001 then
          notes = (notes and notes .. ", " or "") .. string.format("%s +%s ms%s", key, ms(extra),
                                                                   atomic and " (atomic)" or "")
        end
      end
    end
  end
  w.frames = w.frames + weight
  if any then w.chain_gc_frames = w.chain_gc_frames + weight end
  if notes ~= nil then w.note, w.note_frame = "gc steps in " .. notes, frame end
end

-- Whole-VM readings once a frame, from tick: everything Lua did between two
-- ticks, the mods' update and all Lua outside it.
-- A step the engine runs and then stops the collector again leaves the
-- threshold where it was (v0.25.0: in the test, 3 of ~390 such steps were
-- seen by the mark alone). Every step moves at least one of the progress
-- fields -- sweepstr (+44), sweep (+52), gray (+56) -- so between frames
-- those are compared too (offline on the game's lua51.dll: 400 of 400
-- stepped-and-stopped steps changed them).
local function gc_progress(gcp)
  local p = gcp.p32
  return p[11] + p[13] * 4096 + p[14] * 67108864
end

installed.gc_tick = function()
  local gcp = installed.gcp
  if gcp == nil then return end
  local v = installed.gcw.vm
  local h, m, g = gcp.p32[8], gcp.p32[9] * 8 + gcp.p8[41], gc_progress(gcp)
  if v.h ~= nil then
    v.frames = v.frames + 1
    local stepped, swept, atomic = gc_window(v.m, m)
    if v.g ~= g then stepped = true end
    if stepped then v.stepped = v.stepped + 1 end
    if atomic then v.cycles = v.cycles + 1 end
    if not swept then
      v.clean = v.clean + 1
      v.alloc = v.alloc + math.max(0, h - v.h)
    end
  end
  v.h, v.m, v.g = h, m, g
end

installed.gc_summary = function(span)
  local gcp, w = installed.gcp, installed.gcw
  if gcp == nil then
    if not installed.gc_told then
      installed.gc_told = true
      say("  gc: probe off: " .. tostring(installed.gc_why))
    end
    return
  end
  local rows, gc_total, made = {}, 0, {}
  for key, row in pairs(w.rows) do
    gc_total = gc_total + row.gc
    local per_frame = row.clean > 0 and row.alloc / row.clean or 0
    rows[#rows + 1] = { key = key, gc = row.gc, kbs = per_frame * row.frames / 1024 / span }
  end
  local v = w.vm
  local vm_kbs = v.clean > 0 and (v.alloc / v.clean) * v.frames / 1024 / span or 0
  say(string.format("  gc: ~%.1f ms/s of the mods' %.1f ms/s (%.0f%%); steps in %d of %d frames " ..
                    "(inside mods in %d); %d cycles; heap %.1f MB, live after last cycle %.1f MB; " ..
                    "pause %d stepmul %d",
                    gc_total * 1000 / span, w.chain * 1000 / span,
                    w.chain > 0 and gc_total * 100 / w.chain or 0,
                    v.stepped, v.frames, w.chain_gc_frames, v.cycles,
                    gcp.p32[8] / 1048576, gcp.p32[19] / 1048576, gcp.p32[21], gcp.p32[20]))
  if w.worst_atomic_key ~= nil then
    say(string.format("  gc: worst atomic step %s ms, in %s", ms1(w.worst_atomic), w.worst_atomic_key))
  end
  table.sort(rows, function(a, b) return a.gc > b.gc end)
  local parts = {}
  for k = 1, math.min(8, #rows) do
    if rows[k].gc * 1000 / span >= 0.05 then
      parts[#parts + 1] = string.format("%s %.2f ms/s", rows[k].key, rows[k].gc * 1000 / span)
    end
  end
  -- In game the engine steps the collector between updates, so nothing
  -- lands on a mod (v0.24.0-v0.26.0: always "nothing measurable"); the line
  -- is only written when something did (v0.27.0).
  if #parts > 0 then say("  gc landed on: " .. table.concat(parts, ", ")) end
  table.sort(rows, function(a, b) return a.kbs > b.kbs end)
  parts = {}
  for k = 1, math.min(8, #rows) do
    if rows[k].kbs >= 1 then
      parts[#parts + 1] = string.format("%s %.0f KB/s", rows[k].key, rows[k].kbs)
    end
  end
  say(string.format("  garbage: whole Lua VM ~%.0f KB/s; mods: %s", vm_kbs,
                    #parts > 0 and table.concat(parts, ", ") or "none over 1 KB/s"))
  installed.gc_outside_line(span, w.outside)
  installed.gcw = { rows = {}, chain = 0, frames = 0, chain_gc_frames = 0,
                    vm = { frames = 0, clean = 0, alloc = 0, stepped = 0, cycles = 0, h = v.h, m = v.m, g = v.g },
                    worst_atomic = 0, worst_atomic_key = nil, note = nil,
                    outside = { plain = { n = 0 }, step = { n = 0 }, atomic = { n = 0 } } }
end

-- What the collector costs the game (v0.25.0, the user 2026-10-03). In
-- game the collector never ran inside a mod: 0 of ~700 frames with a step a
-- minute, stepmul 20 (not LuaJIT's 200), ~4 cycles a second with the heap
-- far below its pause threshold -- likely the engine steps it itself,
-- between update calls. So its cost is in the time between the end of one
-- frame of ours and the start of the next. That time is put in one of
-- three histograms (0.1 ms buckets: no sort, nearly no garbage) by what
-- the collector did in it: nothing, a step, a step that ended a cycle's
-- marking (atomic). The medians' differences, times how often each
-- happened, are its cost in ms/s. Likely, not proven: a frame with a step
-- may also differ in other ways; a frame waiting on the GPU hides the step.
installed.gc_frame_out = function()
  local gcp = installed.gcp
  installed.gc_out_t, installed.gc_out_m = timer_now(), gcp.p32[9] * 8 + gcp.p8[41]
  installed.gc_out_g = gc_progress(gcp)
end

installed.gc_frame_in = function()
  local gcp, last_t, last_m = installed.gcp, installed.gc_out_t, installed.gc_out_m
  if last_t == nil then return end
  installed.gc_out_t = nil
  local t, m = timer_now(), gcp.p32[9] * 8 + gcp.p8[41]
  local outside = t - last_t
  if outside < 0 or outside > 0.25 then return end      -- loading, menus, alt-tab
  local stepped, _, atomic = gc_window(last_m, m)
  if gc_progress(gcp) ~= installed.gc_out_g then stepped = true end
  local o = installed.gcw.outside
  local hist = atomic and o.atomic or (stepped and o.step or o.plain)
  local bucket = math.floor(outside * 10000)
  hist[bucket] = (hist[bucket] or 0) + 1
  hist.n = hist.n + 1
end

local function gc_median(hist)
  if hist.n == 0 then return nil end
  local seen = 0
  for bucket = 0, 2500 do
    seen = seen + (hist[bucket] or 0)
    if seen * 2 >= hist.n then return (bucket + 0.5) / 10 end
  end
  return nil
end

-- v0.27.0: in game (2026-10-03, 77 min) the engine stepped the collector
-- in ~98% of frames: ~90 frames a minute had no step, and the line read
-- 0.0-9.0 ms/s minute to minute -- one 0.1 ms bucket times ~5000 frames,
-- noise. When steps are in most frames, a step's own cost is in nearly
-- every frame and cannot be told apart; only the end of marking is
-- compared, against the frames with an ordinary step.
installed.gc_outside_line = function(span, o)
  local plain, step, atomic = gc_median(o.plain), gc_median(o.step), gc_median(o.atomic)
  local function shown(value) return value and string.format("%.1f ms", value) or "-" end
  if plain ~= nil and o.plain.n >= o.step.n then
    local cost = 0
    if step ~= nil then cost = cost + math.max(0, step - plain) * o.step.n end
    if atomic ~= nil then cost = cost + math.max(0, atomic - plain) * o.atomic.n end
    say(string.format("  gc between frames (median): no step %s (%d frames), a step %s (%d), " ..
                      "end of marking %s (%d) -> collector ~%.1f ms/s",
                      shown(plain), o.plain.n, shown(step), o.step.n, shown(atomic), o.atomic.n,
                      cost / span))
  elseif step ~= nil then
    local cost = atomic ~= nil and math.max(0, atomic - step) * o.atomic.n or 0
    say(string.format("  gc between frames (median): a step in most frames, %s (%d of %d; " ..
                      "a step's own cost is in nearly every frame and is not told apart), " ..
                      "no step %s (%d), end of marking %s (%d) -> end of marking ~%.1f ms/s",
                      shown(step), o.step.n, o.plain.n + o.step.n + o.atomic.n, shown(plain),
                      o.plain.n, shown(atomic), o.atomic.n, cost / span))
  end
end
end

local window = { mods = {}, started = nil, frames = 0, hitches = 0 }

-- The panel's rolling window: one bucket per second, the last WINDOW_S kept.
local live = { started = nil, bucket = nil, ring = {} }

local function new_bucket(at)
  return { at = at, mods = {}, frames = 0, time = 0, stalls = 0 }
end

local function charge_row(rows, key, own)
  local row = rows[key]
  if row == nil then
    row = { time = 0, worst = 0 }
    rows[key] = row
  end
  row.time = row.time + own
  if own > row.worst then row.worst = own end
end

local function charge(frame_selfs)
  -- v0.43.0: a counted loop over the links, then MDL's scripts at -1, -2, ...
  -- (add_mdl), where pairs() went over the table every frame.
  local rows, bucket = window.mods, live.bucket ~= nil and live.bucket.mods or nil
  local index = #links
  while true do
    local entry = frame_selfs[index]
    if entry ~= nil then
      local key = owner(entry.link)
      charge_row(rows, key, entry.own)
      if bucket ~= nil then charge_row(bucket, key, entry.own) end
    elseif index < 0 then
      break
    end
    index = index - 1
    if index == 1 then index = -1 end
  end
end

local function roll(at)
  if live.bucket == nil then
    live.bucket = new_bucket(at)
    return
  end
  if at - live.bucket.at < 1 then return end
  live.ring[#live.ring + 1] = live.bucket
  while #live.ring > WINDOW_S do table.remove(live.ring, 1) end
  live.bucket = new_bucket(at)
end

local function write_summary(at)
  local span = at - (window.started or at)
  if span <= 0 then return end
  local rows = {}
  for key, row in pairs(window.mods) do rows[#rows + 1] = { key = key, row = row } end
  table.sort(rows, function(a, b) return a.row.time > b.row.time end)
  say(string.format("summary %.0f s: frames=%d hitches=%d chain=%d links%s",
                    span, window.frames, window.hitches, #links,
                    #links > 0 and ("; top " .. links[1].source .. " not measured") or ""))
  for k = 1, math.min(SUMMARY_ROWS, #rows) do
    local r = rows[k]
    say(string.format("  %-48s %6.2f ms/s %7.3f ms/frame  worst frame %s ms",
                      r.key, r.row.time * 1000 / span,
                      r.row.time * 1000 / math.max(window.frames, 1), ms1(r.row.worst)))
  end
  say(string.format("  log write worst %.0f ms", writes_worst() * 1000))
  if (installed.jit_minute or 0) > 0 then
    say(string.format("  jit: %d LuaJIT code cache flush%s this minute", installed.jit_minute,
                      installed.jit_minute == 1 and "" or "es"))
    installed.jit_minute = 0
  end
  if (installed.restacks or 0) > (installed.restacks_told or 0) then
    say(string.format("  chain: %d hooks came onto or left the top so far, taken without a new walk",
                      installed.restacks))
    installed.restacks_told = installed.restacks
  end
  -- v0.24.0: what this module itself took, outside the shims (its tick: the
  -- walk, summaries, the window, log writes).
  pcall(installed.render_summary, span)
  do
    local parts, shown = installed.own_parts or {}, {}
    for _, part in ipairs({ "screen", "key", "menu", "draw", "times", "gc", "chain", "memory", "units", "vram",
                            "render", "log", "before", "call", "after" }) do
      local value = (parts[part] or 0) * 1000 / span
      if value >= 0.05 then shown[#shown + 1] = string.format("%s %.2f", part, value) end
    end
    -- v0.44.0: before, call and after are outside the tick: not in the
    -- first figure, which is the tick's own time.
    say(string.format("  this module: %.2f ms/s, worst frame %.1f ms%s",
                      (installed.own_time or 0) * 1000 / span, (installed.own_worst or 0) * 1000,
                      #shown > 0 and ("; parts (ms/s): " .. table.concat(shown, ", ")) or ""))
    installed.own_parts = {}
  end
  installed.own_time, installed.own_worst = 0, 0
  local raised = {}
  for key, n in pairs(installed.errors) do raised[#raised + 1] = { key = key, n = n } end
  table.sort(raised, function(a, b) return a.n > b.n end)
  for _, e in ipairs(raised) do
    say(string.format("  errors: %s raised a Lua error in %d frames", e.key, e.n))
  end
  installed.errors = {}
  local g = gpu.minute
  if g ~= nil and g.n > 0 then
    say(string.format("  vram: max %.2f of %.2f GB budget; read worst %.3f ms",
                      g.vram_max / 1073741824, g.budget / 1073741824, g.took * 1000))
  end
  gpu.minute = nil
  do
    local ok, err = pcall(installed.gc_summary, span)
    if not ok then say("  gc: summary failed: " .. tostring(err)) end
  end
  say(session_line("  so far"))
  -- For the report: the whole session, not only this minute.
  session.time = (session.time or 0) + span
  session.frames = (session.frames or 0) + window.frames
  session.mods = session.mods or {}
  for key, row in pairs(window.mods) do
    local total = session.mods[key]
    if total == nil then
      total = { time = 0, worst = 0, peak = 0 }
      session.mods[key] = total
    end
    total.time = total.time + row.time
    if row.worst > total.worst then total.worst = row.worst end
    total.peak = math.max(total.peak, row.time * 1000 / span)
  end
  if installed.data_snapshot ~= nil then pcall(installed.data_snapshot) end   -- v0.40.0
  window = { mods = {}, started = at, frames = 0, hitches = 0 }
end

-- ------------------------------------------------------------ names

-- The name each mod has in the mod manager (v0.7.1), shown in place of the
-- last part of its addon name. Read once while the game loads, from
-- Arsenal's own list (%LOCALAPPDATA%\hd2arsenal\hd2a_data.json): the active
-- profile's enabled mods, their enabled options' folders, and in each folder
-- the Lua archive 9ba626afa44a3aa3.patch_0, whose Lua resources start with
-- "-- HD2-Addon: <addon name>" (seen in every Lua mod the author runs,
-- 2026-09-29; a mod without that line keeps its short name). Only the
-- archive's file table and the first 160 bytes of each Lua resource are read.
-- A name with any character outside ASCII keeps the short name: the debug
-- font this module draws with has Latin letters only.
local names = {}
-- One Lua resource in two or more enabled mods (v0.19.0). Only one of them
-- runs: the game loads one copy of a resource. Bingus Shared Loader v18
-- requires a fixed list of names, so authors borrow one: Heavy Kill HUD,
-- HUD Ballistic Trajectory Overlay and Codex Module Bridge all ship
-- mods/codex/gun_calibration (2026-10-02). installed.shared[key] = the mods
-- whose copy has that key, each { plain, clean, listed, key, funcs, ends };
-- installed.shared_rows = one list of such mods per resource. (On installed:
-- the main chunk is at Lua's limit of 200 locals.)
installed.shared, installed.shared_rows, installed.shared_seen = {}, {}, {}
local read_names
do
local LUA_TYPE = "\226\023\209\044\250\141\078\161"   -- 0xA14E8DFA2CD117E2, little-endian
local LUA_ARCHIVE = "9ba626afa44a3aa3.patch_0"
-- Every Lua resource of the game and of every mod is in this archive; an
-- option may ship its Lua under a later patch index (HD2 HUD+ 0.1.13: its
-- squad fragment in patch_5). Those count for the mod list (v0.17.1) but
-- not for names, which go by patch_0 as before.

-- The mod manager's name as it is, for the mod list on the clipboard (any
-- characters; only the "<id> <version> <date>T..Z <tag>" tail some
-- downloads carry goes).
local function plain_label(label)
  if type(label) ~= "string" then return "?" end
  label = string.gsub(label, "%s+%d+%s+%S+%s+%d%d%d%d%-%d%d%-%d%dT.*$", "")
  label = string.match(label, "^%s*(.-)%s*$")
  if label == "" then return "?" end
  return label
end

-- Returns the value, or nil and why. Never raises: a broken list is an
-- ordinary answer, not an error.
local function json_decode(text)
  local pos, bad = 1, nil
  local escapes = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }
  local function fail(why)
    bad = bad or (why .. " at " .. pos)
  end
  local function skip()
    pos = string.find(text, "[^ \t\r\n]", pos) or (#text + 1)
  end
  local function utf8(code)
    if code < 0x80 then return string.char(code) end
    if code < 0x800 then
      return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    end
    if code < 0x10000 then
      return string.char(0xE0 + math.floor(code / 0x1000),
                         0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
    end
    return string.char(0xF0 + math.floor(code / 0x40000), 0x80 + math.floor(code / 0x1000) % 0x40,
                       0x80 + math.floor(code / 0x40) % 0x40, 0x80 + code % 0x40)
  end
  local function str()
    local out = {}
    pos = pos + 1
    while true do
      local at = string.find(text, '["\\]', pos)
      if at == nil then return fail("unterminated string") end
      out[#out + 1] = string.sub(text, pos, at - 1)
      if string.sub(text, at, at) == '"' then
        pos = at + 1
        return table.concat(out)
      end
      local c = string.sub(text, at + 1, at + 1)
      if c == "u" then
        local code = tonumber(string.sub(text, at + 2, at + 5), 16) or 63
        pos = at + 6
        if code >= 0xD800 and code <= 0xDBFF and string.sub(text, pos, pos + 1) == "\\u" then
          local low = tonumber(string.sub(text, pos + 2, pos + 5), 16)
          if low ~= nil then
            code = 0x10000 + (code - 0xD800) * 0x400 + (low - 0xDC00)
            pos = pos + 6
          end
        end
        out[#out + 1] = utf8(math.min(code, 0x10FFFF))
      else
        out[#out + 1] = escapes[c] or c
        pos = at + 2
      end
    end
  end
  local value
  value = function(depth)
    if depth > 64 then return fail("nested too deep") end
    skip()
    local c = string.sub(text, pos, pos)
    if c == "{" or c == "[" then
      local object, close = {}, (c == "{") and "}" or "]"
      pos = pos + 1
      skip()
      if string.sub(text, pos, pos) == close then
        pos = pos + 1
        return object
      end
      while bad == nil do
        if close == "}" then
          skip()
          if string.sub(text, pos, pos) ~= '"' then return fail("key expected") end
          local key = str()
          skip()
          if bad ~= nil or string.sub(text, pos, pos) ~= ":" then return fail("':' expected") end
          pos = pos + 1
          object[key] = value(depth + 1)
        else
          object[#object + 1] = value(depth + 1)
        end
        if bad ~= nil then return nil end
        skip()
        local d = string.sub(text, pos, pos)
        if d == close then
          pos = pos + 1
          return object
        end
        if d ~= "," then return fail("',' expected") end
        pos = pos + 1
      end
      return nil
    elseif c == '"' then
      return str()
    end
    local literal = string.match(text, "^[%w%.%+%-]+", pos)
    if literal == nil then return fail("value expected") end
    pos = pos + #literal
    if literal == "true" then return true end
    if literal == "false" then return false end
    if literal == "null" then return nil end
    local number = tonumber(literal)
    if number == nil then return fail("bad literal") end
    return number
  end
  local result = value(1)
  if bad ~= nil then return nil, bad end
  return result
end

local function le(bytes, at, size)
  local n = 0
  for k = size, 1, -1 do n = n * 256 + (string.byte(bytes, at + k - 1) or 0) end
  return n
end

-- MurmurHash64A, seed 0, as the game and the SDK hash resource names
-- (hashing.murmur64_hash in hd2_diag; the builders write it into every file
-- row). Pure Lua on four 16-bit limbs: no ffi, and bit.bxor only when there
-- is a bit library. It runs at load and once per chain source (cached).
local function murmur64(text)
  local bit_lib = rawget(_G, "bit")
  local bxor = type(bit_lib) == "table" and bit_lib.bxor or nil
  local function xor16(a, b)
    if bxor ~= nil then return bxor(a, b) end
    local r, p = 0, 1
    for _ = 1, 16 do
      local x, y = a % 2, b % 2
      if x ~= y then r = r + p end
      a, b, p = (a - x) / 2, (b - y) / 2, p * 2
    end
    return r
  end
  local function mul(a, b)
    local r0 = a[1] * b[1]
    local r1 = a[1] * b[2] + a[2] * b[1]
    local r2 = a[1] * b[3] + a[2] * b[2] + a[3] * b[1]
    local r3 = a[1] * b[4] + a[2] * b[3] + a[3] * b[2] + a[4] * b[1]
    local c = math.floor(r0 / 65536)
    r0 = r0 % 65536
    r1 = r1 + c
    c = math.floor(r1 / 65536)
    r1 = r1 % 65536
    r2 = r2 + c
    c = math.floor(r2 / 65536)
    r2 = r2 % 65536
    r3 = (r3 + c) % 65536
    return { r0, r1, r2, r3 }
  end
  local function xor64(a, b)
    return { xor16(a[1], b[1]), xor16(a[2], b[2]), xor16(a[3], b[3]), xor16(a[4], b[4]) }
  end
  local function shr47(a)
    return { math.floor(a[3] / 32768) + (a[4] % 32768) * 2, math.floor(a[4] / 32768), 0, 0 }
  end
  local M = { 0xe995, 0x5bd1, 0xa793, 0xc6a4 }          -- 0xc6a4a7935bd1e995
  local n = #text
  local h = mul(M, { n % 65536, math.floor(n / 65536) % 65536, 0, 0 })
  local blocks = n - n % 8
  for at = 1, blocks, 8 do
    local b1, b2, b3, b4, b5, b6, b7, b8 = string.byte(text, at, at + 7)
    local k = { b1 + b2 * 256, b3 + b4 * 256, b5 + b6 * 256, b7 + b8 * 256 }
    k = mul(k, M)
    k = xor64(k, shr47(k))
    k = mul(k, M)
    h = mul(xor64(h, k), M)
  end
  local tail = n % 8
  for i = tail - 1, 0, -1 do
    local limb = math.floor(i / 2) + 1
    local byte = string.byte(text, blocks + i + 1)
    h[limb] = xor16(h[limb], i % 2 == 1 and byte * 256 or byte)
  end
  if tail >= 1 then h = mul(h, M) end
  h = xor64(h, shr47(h))
  h = mul(h, M)
  h = xor64(h, shr47(h))
  return string.format("%04x%04x%04x%04x", h[4], h[3], h[2], h[1])
end
installed.name_hash = murmur64
local hash_cache = {}
installed.hash_of = function(text)
  local hash = hash_cache[text]
  if hash == nil then
    hash = murmur64(tostring(text))
    hash_cache[text] = hash
  end
  return hash
end
-- Only a test sets this, to check the hash against the SDK's.
if rawget(_G, "__mlf_test_hash") == true then rawset(_G, "__mlf_test_hash", murmur64) end

-- The Lua resources in one archive: { key = name hash, readable = addon
-- name or nil }. The key is murmur64 of the HD2-Addon name when the resource
-- declares one (the same value its file row holds, 58 of 58 on 2026-09-30),
-- else the row's own name hash (HD2 HUD+'s "boot" and "mods/hd2_hud/product"
-- have no such line). nil when there is no such file.
local function archive_addons(path)
  local file = io.open(path, "rb")
  if file == nil then return nil end
  local found = {}
  pcall(function()
    local head = file:read(0x48)
    if head == nil or #head < 0x48 then return end
    local types, files = le(head, 5, 4), le(head, 9, 4)
    if types > 64 or files > 20000 then return end
    local tables = file:read(types * 32 + files * 80)
    if tables == nil or #tables < types * 32 + files * 80 then return end
    for index = 0, files - 1 do
      local row = types * 32 + index * 80 + 1
      if string.sub(tables, row + 8, row + 15) == LUA_TYPE then
        local digits = {}
        for k = 7, 0, -1 do digits[#digits + 1] = string.format("%02x", string.byte(tables, row + k)) end
        local row_hash = table.concat(digits)
        file:seek("set", le(tables, row + 16, 8))
        local start = file:read(160) or ""
        local addon = string.match(start, "^........%-%- HD2%-Addon:%s*([%w_%-%./]+)")
        -- Compiled LuaJIT bytecode keeps the name it was compiled under, and
        -- that is the name its functions report, not the resource's (v0.18.0:
        -- Codex Module Bridge is "@module_bridge.lua" inside the resource of
        -- mods/codex/gun_calibration, 2026-10-02; a player's "solo_bunker_probe"
        -- hid as "(the game)" this way, likely). Header: ESC "LJ", version,
        -- uleb flags (2 = stripped: no name), then uleb length and the name.
        local chunk = nil
        if addon == nil and string.sub(start, 9, 11) == "\27LJ" then
          local at = 13
          local function uleb()
            local value, shift = 0, 0
            repeat
              local byte = string.byte(start, at)
              if byte == nil then return nil end
              at = at + 1
              value = value + (byte % 128) * 2 ^ shift
              shift = shift + 7
            until byte < 128 or shift > 28
            return value
          end
          local flags = uleb()
          if flags ~= nil and math.floor(flags / 2) % 2 == 0 then
            local length = uleb()
            if length ~= nil and length > 0 and length <= 120 then
              chunk = string.sub(start, at, at + length - 1)
              if #chunk ~= length then chunk = nil end
            end
          end
          if chunk ~= nil then
            if string.sub(chunk, 1, 1) == "@" then chunk = string.sub(chunk, 2) end   -- as source_of reads it
            chunk = string.gsub(chunk, "%.lua$", "")
          end
        end
        found[#found + 1] = { key = (addon and murmur64(addon)) or (chunk and murmur64(chunk)) or row_hash,
                              row = row_hash, readable = addon, offset = le(tables, row + 16, 8) }
      end
    end
  end)
  file:close()
  return found
end

-- "Where's My Shit?  v0.11.6" -> "Where's My Shit?"; nil when it has
-- characters the debug font cannot draw. Many authors' names are long, so
-- what is in brackets goes, and so does the "<id> <version> <date>T..Z <tag>"
-- tail some downloads carry ("Mecha girl 11334 1.1 2026-07-08T07-48Z
-- IzUPRhJPM"); a name still longer than NAME_MAX is cut at a word, with "..".
local NAME_MAX = 28              -- the window's name column

local function clean_label(label)
  if type(label) ~= "string" or string.find(label, "[\128-\255]") then return nil end
  label = string.gsub(label, "%b()", "")
  label = string.gsub(label, "%b[]", "")
  label = string.gsub(label, "%s+%d+%s+%S+%s+%d%d%d%d%-%d%d%-%d%dT.*$", "")
  label = string.gsub(label, "%s+", " ")
  label = string.gsub(label, "%s*%-?%s*[vV]%d[%w%.%-]*$", "")
  label = string.gsub(label, "%s+%d+%.%d[%w%.%-]*$", "")
  label = string.gsub(label, "%s+[%-%+&:,/]%s*$", "")
  label = string.gsub(label, "%s+([%-%+&:,/])%s+([%-%+&:,/])%s+", " %2 ")
  label = string.match(label, "^%s*(.-)%s*$")
  if #label > NAME_MAX then
    local cut = string.sub(label, 1, NAME_MAX - 2)
    if string.find(string.sub(label, NAME_MAX - 1, NAME_MAX - 1), "%w") then
      local word = string.match(cut, "^(.*%w)[^%w]+%w*$")    -- back to the last whole word
      if word ~= nil and #word >= 8 then cut = word end
    end
    label = string.gsub(cut, "[%s%-%+&:,/]+$", "") .. ".."
  end
  if label == "" or not string.find(label, "%w") then return nil end
  return label
end

-- Which lines of a Lua resource's text hold the word "function", and which
-- the word "end" (v0.19.0). A hook's first line (linedefined) holds the
-- first, its last line (lastlinedefined) the second: matched against the
-- copies of a shared resource, that tells which copy is running. Read once,
-- at load, only for resources two enabled mods ship as text.
local function line_marks(path, offset)
  local file = io.open(path, "rb")
  if file == nil then return nil end
  local funcs, ends = nil, nil
  pcall(function()
    file:seek("set", offset)
    local head = file:read(8)
    if head == nil or #head < 8 then return end
    local size = le(head, 1, 4)
    if size <= 0 or size > 16 * 1024 * 1024 then return end
    local text = file:read(size)
    if text == nil or #text < size then return end
    funcs, ends = {}, {}
    local n = 0
    for line in string.gmatch(text .. "\n", "([^\n]*)\n") do
      n = n + 1
      if string.find(line, "%f[%w_]function%f[^%w_]") then funcs[n] = true end
      if string.find(line, "%f[%w_]end%f[^%w_]") then ends[n] = true end
    end
  end)
  file:close()
  return funcs, ends
end

-- v0.38.0 (Echelon's author, 2026-10-13): Echelon, another HD2 mod manager,
-- keeps an open, read-only list at %APPDATA%\Echelon\library.json
-- (format "echelon-library", version 1, from Echelon 0.36.2). Each mod has
-- its name, whether it is on, its folder, and its patch sets: the files
-- relative to the folder, the main .patch_N first, and "deployed_as", the
-- name in the game's data folder, or null when not deployed. Options and
-- choices point at sets by index from 0. Read when there is no Arsenal list
-- (as its author suggested), into the shape the Arsenal reading builds:
-- each enabled mod with its Lua archives (the 9ba626afa44a3aa3 sets that are
-- deployed) and the option each came from.
-- A mod: { label, uuid, folder = relative folder, parts = { { file, option,
-- names } } }. names: the archive is a patch_0, which names go by.
installed.manager_mods = function()
  local LUA_HASH = "9ba626afa44a3aa3"
  local ok_local, localappdata = pcall(os.getenv, "LOCALAPPDATA")
  local text = type(localappdata) == "string" and read_all(localappdata .. "\\hd2arsenal\\hd2a_data.json") or nil
  if text ~= nil then
    local data, why = json_decode(text)
    if type(data) ~= "table" then return nil, "Arsenal mod list unreadable: " .. tostring(why or "not an object") end
    local profile = type(data.modsList) == "table" and data.modsList[data.selectedProfile or "default"]
    if type(profile) ~= "table" or type(profile.mods) ~= "table" then return nil, "no active Arsenal profile" end
    local mods = {}
    for _, mod in ipairs(profile.mods) do
      if type(mod) == "table" and mod.enabled == true and type(mod.path) == "string" then
        local folders = {}
        local function add(option)
          for _, include in ipairs(type(option.include) == "table" and option.include or {}) do
            if type(include) == "string" then
              folders[#folders + 1] = { dir = string.gsub(include, "/", "\\"), option = option.name }
            end
          end
        end
        local options = type(mod.options) == "table" and mod.options or {}
        if #options == 0 then folders[1] = { dir = "", option = nil } end
        for _, option in ipairs(options) do
          if type(option) == "table" and option.enabled == true then
            add(option)
            for _, sub in ipairs(type(option.suboptions) == "table" and option.suboptions or {}) do
              if type(sub) == "table" and sub.enabled == true then add(sub) end
            end
          end
        end
        local parts = {}
        for _, folder in ipairs(folders) do
          local base = mod.path .. (folder.dir ~= "" and ("\\" .. folder.dir) or "") .. "\\" .. LUA_HASH .. ".patch_"
          -- An option may ship its Lua under a later patch index (HD2 HUD+
          -- 0.1.13: its squad fragment in patch_5): those count for the mod
          -- list, not for names.
          for patch = 0, 15 do
            parts[#parts + 1] = { file = base .. patch, option = folder.option, names = patch == 0 }
          end
        end
        mods[#mods + 1] = { label = mod.label, uuid = mod.uuid, path = mod.path, parts = parts }
      end
    end
    return mods, nil, "Arsenal", data
  end
  local ok_roaming, appdata = pcall(os.getenv, "APPDATA")
  text = type(appdata) == "string" and read_all(appdata .. "\\Echelon\\library.json") or nil
  if text == nil then return nil, "no Arsenal or Echelon mod list" end
  local data, why = json_decode(text)
  if type(data) ~= "table" or data.format ~= "echelon-library" then
    return nil, "Echelon mod list unreadable: " .. tostring(why or "not an echelon-library")
  end
  if data.version ~= 1 then return nil, "Echelon mod list version " .. tostring(data.version) .. ", not 1" end
  local mods = {}
  for _, mod in ipairs(type(data.mods) == "table" and data.mods or {}) do
    if type(mod) == "table" and mod.enabled == true and type(mod.folder) == "string" and type(mod.sets) == "table" then
      -- The option (or choice) each set comes from, by index from 0.
      local from = {}
      for _, option in ipairs(type(mod.options) == "table" and mod.options or {}) do
        if type(option) == "table" and option.enabled == true then
          for _, index in ipairs(type(option.sets) == "table" and option.sets or {}) do
            if type(index) == "number" then from[index] = from[index] or option.name end
          end
          local choices = type(option.choices) == "table" and option.choices or {}
          local chosen = type(option.selected) == "number" and choices[option.selected + 1] or nil
          if type(chosen) == "table" then
            for _, index in ipairs(type(chosen.sets) == "table" and chosen.sets or {}) do
              if type(index) == "number" then from[index] = from[index] or chosen.name end
            end
          end
        end
      end
      local parts = {}
      for index, set in ipairs(mod.sets) do
        local first = type(set) == "table" and type(set.files) == "table" and set.files[1] or nil
        if type(first) == "string" and set.hash == LUA_HASH and type(set.deployed_as) == "string" then
          parts[#parts + 1] = { file = mod.folder .. "\\" .. string.gsub(first, "/", "\\"),
                                option = from[index - 1], names = string.match(first, "%.patch_0$") ~= nil }
        end
      end
      mods[#mods + 1] = { label = mod.name, uuid = nil, path = mod.folder, parts = parts }
    end
  end
  return mods, nil, "Echelon", nil
end

read_names = function()
  -- The enabled mods and how each runs, for "copy mod list" (v0.17.1).
  installed.mod_list, installed.mod_list_why = nil, "no mod manager list was read"
  local listed_mods = {}
  local mods_in, why, manager, data = installed.manager_mods()
  if mods_in == nil then
    installed.mod_list_why = why
    return why
  end
  installed.manager = manager
  data = data or {}
  local profile = type(data.modsList) == "table" and data.modsList[data.selectedProfile or "default"] or { mods = {} }
  -- Every mod's name by its Arsenal uuid, enabled or not: MDL starts mods
  -- from the library live and calls a legacy script "arsenal:<uuid>"
  -- (v0.19.1: the user saw "mdl: arsenal:c9bea282-ab42-" in the table).
  local by_uuid = {}
  for _, list in ipairs({ profile.mods, type(data.modsLibrary) == "table" and data.modsLibrary or {} }) do
    for _, mod in ipairs(list) do
      if type(mod) == "table" and type(mod.uuid) == "string" and by_uuid[string.lower(mod.uuid)] == nil then
        by_uuid[string.lower(mod.uuid)] = clean_label(mod.label) or false
      end
    end
  end
  installed.mdl_names = by_uuid
  -- The mod's folder for the report (v0.22.0): relative to Arsenal's mods
  -- folder, or its last part -- never the whole path, which can hold the
  -- Windows user name. Arsenal names folders after the download, Nexus id
  -- included ("Smarter Guard Dogs 4.0.0 16610 4.0.0 2026-09-29T02-49Z ...").
  local mods_dir = type(data.userModsDir) == "string"
                   and string.lower((string.gsub(data.userModsDir, "[\\/]+$", ""))) .. "\\" or nil
  local function relative_folder(path)
    path = string.gsub(path, "[\\/]+$", "")
    if mods_dir ~= nil and string.lower(string.sub(path, 1, #mods_dir)) == mods_dir then
      return string.sub(path, #mods_dir + 1)
    end
    return string.match(path, "([^\\/]+)$") or "?"
  end
  local seen, archives = {}, 0
  local hashes, readable, owner_of = {}, {}, {}
  local claims, claim_order = {}, {}     -- row hash -> { [mod index] = claim }, rows in order
  local shared, shared_rows = {}, {}
  installed.shared, installed.shared_rows, installed.shared_seen = shared, shared_rows, {}
  for mod_index, mod in ipairs(mods_in) do
    do
      local listed = { label = plain_label(mod.label), keys = {}, lua = 0, scripts = 0,
                       folder = relative_folder(mod.path) }
      listed_mods[#listed_mods + 1] = listed
      -- Which options each resource of this mod comes from.
      local by_addon, order, lua_folders = {}, {}, 0
      for _, folder in ipairs(mod.parts) do
        local path = folder.file
        local all = archive_addons(path)
        local addons = folder.names and all or nil
        if folder.names and all ~= nil then archives = archives + 1 end
        if addons ~= nil and #addons > 0 then lua_folders = lua_folders + 1 end
        -- The mod list sees every Lua archive of the mod.
        for _, entry in ipairs(all or {}) do
          hashes[entry.key], hashes[entry.row] = true, true
          listed.keys[entry.key], listed.keys[entry.row] = true, true
          listed.lua = listed.lua + 1
          if entry.readable == nil then listed.scripts = listed.scripts + 1 end
        end
        for _, entry in ipairs(addons or {}) do
          hashes[entry.key] = true
          hashes[entry.row] = true
          local claim = claims[entry.row]
          if claim == nil then
            claim = { list = {} }
            claims[entry.row], claim_order[#claim_order + 1] = claim, entry.row
          end
          if claim[mod_index] == nil then
            claim[mod_index] = { plain = listed.label, clean = clean_label(mod.label), listed = listed,
                                 key = entry.key, path = path, offset = entry.offset,
                                 text = entry.readable ~= nil, readable = entry.readable }
            claim.list[#claim.list + 1] = claim[mod_index]
          end
          if entry.readable ~= nil then readable[entry.key] = entry.readable end
          if by_addon[entry.key] == nil then
            by_addon[entry.key] = {}
            order[#order + 1] = entry.key
          end
          by_addon[entry.key][tostring(folder.option)] = folder.option
        end
      end
      -- The mod's name; when the mod's several resources come from different
      -- option folders, a resource found in only one of them takes that
      -- option's name (the Megapack's rows). One resource (Ammo Lamp,
      -- Helmet Headlamp), or several in a single folder (HD2 HUD+'s "boot"
      -- and "mods/hd2_hud/product" in COMMON, with 5 more options enabled),
      -- keep the mod's name. (v0.13.0 went by enabled folders alone and
      -- named HUD+ "Core" and Ammo Lamp "Shoulder ammo lamp" in game,
      -- 2026-09-30 20:06.)
      for _, key in ipairs(order) do
        local label = mod.label
        if #order > 1 and lua_folders > 1 then
          local only, count = nil, 0
          for _, option in pairs(by_addon[key]) do
            only, count = option, count + 1
          end
          if count == 1 and type(only) == "string" then label = only end
        end
        local clean = clean_label(label) or false
        if seen[key] == nil then
          seen[key], owner_of[key] = clean, mod_index
        elseif seen[key] ~= clean then
          seen[key] = false                -- two mods claim it: keep the short name
        end
      end
    end
  end
  installed.archive_hashes = hashes
  installed.mod_list, installed.mod_list_why = listed_mods, nil
  -- Resources two or more enabled mods ship: only one copy runs (v0.19.0).
  for _, row in ipairs(claim_order) do
    local list = claims[row].list
    if #list >= 2 then
      local labels = {}
      for _, claim in ipairs(list) do
        labels[#labels + 1] = claim.plain
        shared[claim.key] = shared[claim.key] or {}
        table.insert(shared[claim.key], claim)
      end
      shared_rows[#shared_rows + 1] = list
      say(string.format("shared: %s is in %s -- one Lua resource, only one of them runs",
                        list[1].readable or ("#" .. row), table.concat(labels, " and ")))
    end
  end
  for _, list in pairs(shared) do
    if #list >= 2 then
      for _, claim in ipairs(list) do
        if claim.text then claim.funcs, claim.ends = line_marks(claim.path, claim.offset) end
      end
    end
  end
  -- Two mods under the same name keep their short names; one mod's several
  -- resources may share its name.
  local uses = {}
  for key, label in pairs(seen) do
    if label then
      uses[label] = uses[label] or {}
      uses[label][owner_of[key]] = true
    end
  end
  local shown, count = {}, 0
  for key, label in pairs(seen) do
    local mods = 0
    for _ in pairs(label and uses[label] or {}) do mods = mods + 1 end
    if label and mods == 1 then
      shown[key] = label
      count = count + 1
    end
  end
  names = shown
  local keys = {}
  for key in pairs(seen) do keys[#keys + 1] = key end
  table.sort(keys, function(a, b) return (readable[a] or "#" .. a) < (readable[b] or "#" .. b) end)
  for _, key in ipairs(keys) do
    say(string.format("name: %s = %s", readable[key] or ("#" .. key), shown[key] or "(short name)"))
  end
  return string.format("%d addons named from %s (%d Lua archives read)", count, manager, archives)
end

end   -- names

-- Which mod's copy of a shared resource a link of the chain is (v0.19.0),
-- or nil when that cannot be told. One copy under the link's name: that one
-- (Codex Module Bridge's bytecode is named "module_bridge", not after its
-- resource). Several: the one whose text has "function" on the hook's first
-- line and "end" on its last; none or more than one of them: nil.
installed.shared_owner = function(link)
  local list = installed.shared[installed.hash_of(link.source)]
  if list == nil then return nil end
  if #list == 1 then return list[1] end
  local at = string.format("%s:%d-%d", link.source, link.line or 0, link.last or 0)
  local hit = installed.shared_seen[at]
  if hit == nil then
    local found = {}
    for _, claim in ipairs(list) do
      if claim.funcs and claim.funcs[link.line] and claim.ends[link.last] then found[#found + 1] = claim end
    end
    hit = #found == 1 and found[1] or false
    installed.shared_seen[at] = hit
    say(string.format("shared: %s is %s", at,
                      hit and hit.plain or "not told apart (its lines fit both copies or neither)"))
  end
  return hit or nil
end

-- "mods/patpatpatrick/wheres_my_shit" -> "wheres_my_shit"; a bottom that
-- holds everything below it gets a "+". A resource two mods ship goes by the
-- one whose copy is running, when that can be told (v0.19.0).
local function short_name(key)
  local plus = ""
  if string.find(key, " (+ all below it)", 1, true) then
    key = string.gsub(key, " %(%+ all below it%)$", "")
    plus = "+"
  end
  local hash = installed.hash_of(key)
  local name = names[hash]
  if name == nil and installed.shared[hash] ~= nil and #installed.shared[hash] >= 2 then
    for _, link in ipairs(links) do
      if link.source == key then
        local owner = installed.shared_owner(link)
        name = owner and owner.clean or nil
        break
      end
    end
  end
  return (name or string.match(key, "([^/]+)$") or key) .. plus
end


-- ------------------------------------------------------------ on screen

-- The window lives at one place, kept in 1080p reference pixels (top-left
-- corner; screen y grows upward) and saved to mod_lag_finder_window.txt.
-- On the escape menu's GAME tab it is shown and can be dragged by its title
-- bar (right-click the title bar: back to the default place). In play it is
-- shown at that same place when Home opens it, and a stall line appears
-- there too. Drawn like MDL's panel: the whole screen GUI is rebuilt when
-- what it shows changes, on a world other than the main one, and every GUI
-- call waits until Application.worlds() shows that world is still there.

local WIN_W, LINE, HEADER, PAD = 480, 22, 28, 8
local SWITCH = {}             -- the key of the menu window's table line
local ALERTS = {}             -- and of its alerts line
local TEXT_SIZE, TITLE_SIZE = 16, 18
local DEFAULT_X, DEFAULT_TOP = 1056, 620

local Mouse = sr and rawget(sr, "Mouse") or nil
local V2 = sr and rawget(sr, "Vector2") or nil

local ui = { gui = nil, world = nil, panel = false, key_id = nil,
             key_looked = false, next_refresh = 0, dirty = false,
             signature = nil, in_menu = false, moving = nil,
             place = { x = DEFAULT_X, top = DEFAULT_TOP }, geometry = nil,
             mouse_ids = {}, told = {} }
ui.sort_key = {}              -- the key of the table's header line (v0.30.0; on ui: 200-locals limit)
local toast = nil             -- { text, until_at, colour, keep, always }
local last_stall = nil        -- { ms, who, at }

-- An alert that is given once (ERROR, LAST CRASH: keep) is not replaced by
-- another before its time is up, and the caller marks it given only when this
-- says it is showing (v0.15.0, review [17]: a LAG line in the same tick took
-- an ERROR alert's place, and it never came again). "always" shows even with
-- the alerts switched off: the one LAST CRASH line on the ship.
function ui.alert(new)
  if toast ~= nil and toast.keep and now() < toast.until_at then return false end
  toast = new
  ui.dirty = true
  return true
end


local function tell_once(what, text)
  if ui.told[what] then return end
  ui.told[what] = true
  say(text)
end

local place_path = nil
if log_path ~= nil then
  place_path = string.gsub(log_path, "mod_lag_finder%.log$", "mod_lag_finder_window.txt")
end

local function load_place()
  if place_path == nil then return end
  local file = io.open(place_path, "r")
  if file == nil then return end
  local text = file:read("*l")
  file:close()
  local x, top, shown, alerts, folded, sort =
    string.match(text or "", "^%s*(%-?%d+)%s+(%-?%d+)%s*(%d?)%s*(%d?)%s*(%d?)%s*(%d?)")
  if x ~= nil then ui.place = { x = tonumber(x), top = tonumber(top) } end
  if shown == "1" then ui.panel = true end
  if alerts == "0" then ui.alerts_off = true end
  if folded == "1" then ui.folded = true end     -- v0.20.0; older files have no fifth field
  if sort == "1" then ui.sort_worst = true end   -- v0.30.0; older files have no sixth
end

local function save_place()
  if place_path == nil then return end
  local file = io.open(place_path, "w")
  if file == nil then return end
  file:write(string.format("%d %d %d %d %d %d", ui.place.x, ui.place.top, ui.panel and 1 or 0,
                           ui.alerts_off and 0 or 1, ui.folded and 1 or 0, ui.sort_worst and 1 or 0) .. NL)
  file:close()
end

-- ------------------------------------------------------------ the menu

-- Is the game's escape menu open on its GAME tab? Read from the game's UI
-- state exactly as MDL 1.0.5-p5 reads it (offsets from Mod Options Menu
-- v1.0.1 and ESC Squad Ping 0.2.3; proven in game on this build by MDL's
-- log, 2026-09-29: tab 0 GAME, 2 OPTIONS, 3 MODS). Only a GAME tab that has
-- read so for 3 frames counts: while a language is applied the tab is
-- unreadable for about a second. Pinned to game.dll stamp 0x6AB3B43F, image
-- 0x4744000: on any other build the window is never shown on the menu and
-- only Home shows it. ReadProcessMemory only; nothing is ever written.
local MENU = { STAMP = 0x6AB3B43F, IMAGE = 0x4744000,
               UI_STATE = 0x347CE28, STACK = 0x429C, ENTRIES = 5, ESCAPE = 1,
               MENU = 0x347CE38, SCREEN = 200, TAB = 1248 + 57452, GAME_TAB = 0,
               HOLD = 3 }

local native = { tried = false, read = nil, base = nil, run = 0 }

local function u32_at(bytes, at)
  local a, b, c, d = string.byte(bytes, at + 1, at + 4)
  return a + b * 256 + c * 65536 + d * 16777216
end

local function address_at(bytes)
  if bytes == nil or #bytes < 8 then return nil end
  local value = u32_at(bytes, 0) + u32_at(bytes, 4) * 4294967296
  if value < 0x10000 or value >= 0x800000000000 then return nil end
  return value
end

-- Test seam: a test sets __hd2_native_test = { base, read(addr, size) } and
-- no ffi is asked for. Without it, ReadProcessMemory on this process.
local function open_native()
  local seam = rawget(_G, "__hd2_native_test")
  if type(seam) == "table" then
    if type(seam.read) ~= "function" or type(seam.base) ~= "number" then
      return "test seam incomplete"
    end
    native.read, native.base = seam.read, seam.base
    return nil
  end
  local loader = rawget(_G, "require")
  if type(loader) ~= "function" then return "no require" end
  local ok, ffi = pcall(loader, "ffi")
  if not ok or type(ffi) ~= "table" then return "no ffi" end
  local ok_bind, why = pcall(function()
    -- Another mod may have declared these with its own types; a second,
    -- different cdef is ignored, so each is called through our own cast.
    for _, decl in ipairs({ "void *GetCurrentProcess(void);",
                            "void *GetModuleHandleA(const char *name);",
                            "int ReadProcessMemory(void *process, const void *address," ..
                              " void *buffer, size_t size, size_t *read);" }) do
      pcall(ffi.cdef, decl)
    end
    local kernel = ffi.load("kernel32")
    local rpm = ffi.cast("int (*)(void *, const void *, void *, size_t, size_t *)",
                         kernel.ReadProcessMemory)
    local process = kernel.GetCurrentProcess()
    local base = tonumber(ffi.cast("uintptr_t", kernel.GetModuleHandleA("game.dll")))
    local count = ffi.new("size_t[1]")
    local buffer = ffi.new("uint8_t[256]")
    native.base = base
    native.read = function(address, size)
      if size > 256 then return nil end
      count[0] = 0
      local ok_read, result = pcall(rpm, process, ffi.cast("const void *", address),
                                    buffer, size, count)
      if not ok_read or result == 0 or tonumber(count[0]) ~= size then return nil end
      return ffi.string(buffer, size)
    end
  end)
  if not ok_bind then return "bind: " .. tostring(why) end
  if native.base == nil or native.base == 0 then
    native.read = nil
    return "game.dll not found"
  end
  return nil
end

local function build_matches()
  local head = native.read(native.base, 64)
  if head == nil or string.sub(head, 1, 2) ~= "MZ" then return "game.dll header unreadable" end
  local nt = u32_at(head, 0x3C)
  local pe = native.read(native.base + nt, 0x58)
  if pe == nil or string.sub(pe, 1, 4) ~= "PE\0\0" then return "game.dll PE header not found" end
  local stamp, image = u32_at(pe, 8), u32_at(pe, 0x50)
  native.stamp = stamp
  if stamp ~= MENU.STAMP or image ~= MENU.IMAGE then
    return string.format("game.dll stamp 0x%X image 0x%X; the menu offsets are for 0x%X 0x%X",
                         stamp, image, MENU.STAMP, MENU.IMAGE)
  end
  return nil
end

local function menu_open_now()
  local read = native.read
  local state = address_at(read(native.base + MENU.UI_STATE, 8))
  if state == nil then return false end
  local raw = read(state + MENU.STACK, 4 * (MENU.ENTRIES + 1))
  if raw == nil then return false end
  local depth = u32_at(raw, 4 * MENU.ENTRIES)
  if depth == 0 or depth > MENU.ENTRIES then return false end
  if u32_at(raw, 4 * (depth - 1)) ~= MENU.ESCAPE then return false end
  local menu = address_at(read(native.base + MENU.MENU, 8))
  local screen = menu and address_at(read(menu + MENU.SCREEN, 8))
  if screen == nil or screen % 8 ~= 0 then return false end
  local tab = read(screen + MENU.TAB, 4)
  return tab ~= nil and u32_at(tab, 0) == MENU.GAME_TAB
end

local function menu_check()
  if not native.tried then
    native.tried = true
    local why = open_native()
    if why == nil then
      why = build_matches()
      if why ~= nil then native.read = nil end
    end
    if why ~= nil then
      say("escape menu window off (Home still works): " .. why)
    else
      say("escape menu window on: game.dll build matches")
    end
  end
  if native.read == nil then return false end
  -- v0.43.0: while the menu is shut it is read every third frame (two
  -- ReadProcessMemory calls and two strings each time; ~0.8 ms/s of this
  -- module's time in game went to the screen part). It still opens after
  -- MENU.HOLD readings in a row, ~0.1 s at 100 FPS; open, every frame.
  native.skip = (native.skip or 0) + 1
  if native.run == 0 and native.skip < 3 then return false end
  native.skip = 0
  local ok, open = pcall(menu_open_now)
  if ok and open == true then native.run = native.run + 1 else native.run = 0 end
  return native.run >= MENU.HOLD
end

-- ------------------------------------------------------------ input

local function key_pressed()
  if Keyboard == nil then return false end
  if not ui.key_looked then
    ui.key_looked = true
    local id_fn = rawget(Keyboard, "button_id")
    if type(id_fn) == "function" then
      local ok, id = pcall(id_fn, PANEL_KEY)
      if ok then ui.key_id = id end
    end
    if ui.key_id == nil then say("no key id for " .. PANEL_KEY .. "; the panel cannot open") end
  end
  if ui.key_id == nil then return false end
  local pressed_fn = rawget(Keyboard, "pressed")
  if type(pressed_fn) ~= "function" then return false end
  local ok, value = pcall(pressed_fn, ui.key_id)
  return ok and value == true
end

-- Mouse as MDL reads it; the cursor comes in GUI coordinates (origin bottom
-- left): MDL's panel is dragged in game with exactly this.
local function mouse_id(kind, name)
  local key = kind .. name
  if ui.mouse_ids[key] == nil then
    ui.mouse_ids[key] = false
    local fn = Mouse and rawget(Mouse, kind == "axis" and "axis_id" or "button_id")
    if type(fn) == "function" then
      local ok, id = pcall(fn, name)
      if ok and id ~= nil then ui.mouse_ids[key] = id end
    end
  end
  return ui.mouse_ids[key]
end

local function cursor()
  local id = mouse_id("axis", "cursor")
  local axis = Mouse and rawget(Mouse, "axis")
  if not id or type(axis) ~= "function" or V3 == nil then return nil end
  local ok, v = pcall(axis, id)
  if not ok or v == nil then return nil end
  local ok_x, x = pcall(rawget(V3, "x"), v)
  local ok_y, y = pcall(rawget(V3, "y"), v)
  if not ok_x or not ok_y or type(x) ~= "number" or type(y) ~= "number" then return nil end
  return x, y
end

local function mouse_clicked(button)
  local id = mouse_id("button", button)
  local fn = Mouse and rawget(Mouse, "pressed")
  if not id or type(fn) ~= "function" then return false end
  local ok, value = pcall(fn, id)
  return ok and value == true
end

local function mouse_held(button)
  local id = mouse_id("button", button)
  local fn = Mouse and rawget(Mouse, "button")
  if not id or type(fn) ~= "function" then return false end
  local ok, value = pcall(fn, id)
  return ok and type(value) == "number" and value > 0.5
end

-- ------------------------------------------------------------ drawing

local function world_live(world)
  if world == nil or App == nil then return false end
  local list_fn = rawget(App, "worlds")
  if type(list_fn) ~= "function" then return false end
  local ok, list = pcall(list_fn)
  if not ok or type(list) ~= "table" then return false end
  for _, w in ipairs(list) do
    if w == world then return true end
  end
  return false
end

-- A gone world takes its GUI with it: then the handle is only forgotten.
local function drop_gui()
  if ui.gui ~= nil and world_live(ui.world) then
    local destroy = World and rawget(World, "destroy_gui")
    if type(destroy) == "function" then pcall(destroy, ui.world, ui.gui) end
  end
  ui.gui, ui.world, ui.signature = nil, nil, nil
end

local function new_gui()
  if App == nil or World == nil then return nil end
  local list_fn, make = rawget(App, "worlds"), rawget(World, "create_screen_gui")
  if type(list_fn) ~= "function" or type(make) ~= "function" then return nil end
  local ok, list = pcall(list_fn)
  if not ok or type(list) ~= "table" then return nil end
  local main_now = nil
  if type(original_main_world) == "function" then
    local ok_main, value = pcall(original_main_world)
    if ok_main then main_now = value end
  end
  -- The main world's GUI is not composited over the menus; the other one is
  -- (ESC Squad Ping 0.2.3, MDL, DRIVER HUD).
  for _, world in ipairs(list) do
    if world ~= nil and world ~= main_now then
      local ok_make, gui = pcall(make, world, "scale", 1, 1)
      if ok_make and gui ~= nil then
        ui.gui, ui.world = gui, world
        tell_once("gui", "screen gui made on a non-main world")
        return gui
      end
    end
  end
  tell_once("no gui", "no screen gui: no other world, or create_screen_gui refused")
  return nil
end

-- Engine constructors are callable tables in game (Vector3, Matrix4x4:
-- metatable __call, seen 2026-09-22); anything else is not called at all.
local function callable(value)
  if type(value) == "function" then return true end
  if type(value) ~= "table" then return false end
  local meta = getmetatable(value)
  return type(meta) == "table" and meta.__call ~= nil
end

local function colour(argb)
  if not callable(Color) then return nil end
  local ok, value = pcall(Color, argb[1], argb[2], argb[3], argb[4])
  if ok then return value end
  return nil
end

local WHITE = { 255, 235, 240, 235 }
local GREY = { 255, 170, 175, 170 }
local AMBER = { 255, 255, 190, 90 }
local RED = { 255, 255, 120, 100 }
local BACK = { 200, 8, 10, 14 }
local BAND = { 235, 28, 32, 42 }

-- A top that keeps changing (v0.32.0). HD2 HUD+ 0.2.2 re-links itself on
-- top after every frame while the menu is open; with another mod that also
-- keeps itself on top the two stack a layer each over the other every
-- frame (in the fake: 3,000 layers and +14 ms a frame after 50 s, and they
-- stay after the menu closes). A walk never finished then, so v0.31.1 saw
-- nothing. Here every change of _G.update is counted by the source of the
-- new top, in 5 s windows: 25 or more (5 a second) is named, in the log and
-- as a REHOOK alert at most once a minute. While the top changes that
-- often, a full walk waits for a quiet second instead of starting again
-- every frame (each start flushes the compiled code of the whole chain).
-- Opening and closing the menu (HUD+ alone) or HD2Runtime's scheduler
-- change it every few seconds, far below this.
installed.churn_s, installed.churn_n = 5, 25    -- on installed: the main chunk's 200-locals limit
installed.churn_note = function(top, at)
  local c = installed.churn
  if c == nil then
    c = { start = at, n = 0, by = {}, under = {} }
    installed.churn = c
  end
  c.n = c.n + 1
  local fn = through_ours(top)
  local source = source_of(fn)
  c.by[source] = (c.by[source] or 0) + 1
  -- The layer under it: when two mods leapfrog inside one frame, only the
  -- last one is on top when this module looks; the other is right below.
  for index = 1, 32 do
    local name, value = getupvalue(fn, index)
    if name == nil then break end
    value = through_ours(value)
    if type(value) == "function" then
      local under = source_of(value)
      if under ~= source and under ~= "?" and under ~= "=[C]" then
        c.under[under] = (c.under[under] or 0) + 1
        break
      end
    end
  end
end

installed.churn_tick = function(at)
  local c = installed.churn
  if c == nil or at - c.start < installed.churn_s then return end
  installed.churn = nil
  if c.n < installed.churn_n then return end
  local order = {}
  for source, n in pairs(c.by) do order[#order + 1] = { source = source, n = n } end
  table.sort(order, function(a, b)
    if a.n ~= b.n then return a.n > b.n end
    return a.source < b.source
  end)
  local rate = c.n / (at - c.start)
  -- The mod most often right under the top, when it is another one.
  local partner, most = nil, 0
  for under, n in pairs(c.under) do
    if n > most and under ~= order[1].source then partner, most = under, n end
  end
  if order[2] == nil and partner ~= nil and most >= c.n / 2 then
    order[2] = { source = partner, n = most, under = true }
  end
  local text
  if order[2] ~= nil then
    text = string.format("REHOOK %s and %s keep hooking over each other (%.0f/s)",
                         short_name(order[1].source), short_name(order[2].source), rate)
  else
    text = string.format("REHOOK %s keeps hooking itself on top (%.0f/s)", short_name(order[1].source), rate)
  end
  installed.churn_line = { text = text, until_at = at + 15 }
  installed.churn_logged = (installed.churn_logged or 0) + 1
  if installed.churn_logged <= 20 then
    local parts = {}
    for _, o in ipairs(order) do parts[#parts + 1] = o.source .. (o.under and " (under it) " or " ") .. o.n end
    say(string.format("rehook: the top of the update changed %d times in %.0f s: %s",
                      c.n, at - c.start, table.concat(parts, ", ")))
  end
  if installed.churn_alerted == nil or at - installed.churn_alerted >= 60 then
    installed.churn_alerted = at
    ui.alert({ text = text, until_at = at + 8, colour = AMBER })
  end
end

-- Many changes lately and the last one under a second ago: wait to walk.
installed.churn_busy = function(at)
  local c = installed.churn
  return c ~= nil and c.n >= 10 and installed.top_changed_at ~= nil and at - installed.top_changed_at < 1
end

-- After a chain map: one mod hooked REHOOK_COPIES times or more shows an
-- amber line for 8 s (at most once a minute) and stays listed in the panel.
local function rehook_alert(at)
  if not rehook.fresh then return end
  rehook.fresh = false
  local first = rehook.repeated[1]
  if first == nil or first.n < REHOOK_COPIES then return end
  if rehook.last_alert ~= nil and at - rehook.last_alert < REHOOK_QUIET_S then return end
  rehook.last_alert = at
  local second = rehook.repeated[2]
  local text = string.format("REHOOK %s x%d", short_name(first.source), first.n)
  if second ~= nil and second.n >= 2 then
    text = text .. string.format(", %s x%d", short_name(second.source), second.n)
  end
  ui.alert({ text = text .. string.format(" (chain %d)", rehook.length),
             until_at = at + 8, colour = AMBER })
end

-- ------------------------------------------------------------ vram

-- Video memory against the budget Windows gives this process (v0.12.1; the
-- user: warn when video memory runs out -- past the budget, textures are
-- swapped in and out and the game stutters). dxgi's
-- IDXGIAdapter3::QueryVideoMemoryInfo(node 0, local memory): CurrentUsage
-- and Budget of this process, on the adapter where it uses the most (a PC
-- can list one card twice, plus an integrated one). 0.002 ms a call on the
-- author's PC (2026-09-30). Test seam: __hd2_native_test.gpu() returns usage
-- and budget in bytes; a seam without it switches this off.
do
function gpu.open()
  local seam = rawget(_G, "__hd2_native_test")
  if type(seam) == "table" then
    if type(seam.gpu) ~= "function" then return "off (the test seam has no gpu)" end
    gpu.read = function() return seam.gpu() end
    return "test seam"
  end
  local loader = rawget(_G, "require")
  if type(loader) ~= "function" then return "off (no require)" end
  local ok, ffi = pcall(loader, "ffi")
  if not ok or type(ffi) ~= "table" then return "off (no ffi)" end
  -- Our own type name; each function is called through our own cast, so
  -- another mod's declarations of the same names do not matter.
  pcall(ffi.cdef, "typedef struct { uint64_t budget, usage, available, reserved; } mlf_vram_info;")
  pcall(ffi.cdef, "long CreateDXGIFactory1(const void *iid, void **factory);")
  local function method(object, index, ctype)
    return ffi.cast(ctype, ffi.cast("void ***", object)[0][index])
  end
  -- Kept for the whole session: LuaJIT unloads a library when the namespace
  -- ffi.load returned is collected, and function pointers taken from it then
  -- point at nothing (proven offline 2026-09-30: v0.12.0's pdh.dll faulted at
  -- PdhCollectQueryData's own address after the first garbage collection).
  local dxgi = ffi.load("dxgi")
  gpu.libraries[#gpu.libraries + 1] = dxgi
  local create = ffi.cast("long (*)(const void *, void **)", dxgi.CreateDXGIFactory1)
  -- IID_IDXGIFactory1 770aae78-f26f-4dba-a829-253c83d1b387
  local factory_iid = ffi.new("uint8_t[16]", { 0x78, 0xae, 0x0a, 0x77, 0x6f, 0xf2, 0xba, 0x4d,
                                               0xa8, 0x29, 0x25, 0x3c, 0x83, 0xd1, 0xb3, 0x87 })
  -- IID_IDXGIAdapter3 645967a4-1392-4310-a798-8053ce3e93fd
  local adapter3_iid = ffi.new("uint8_t[16]", { 0xa4, 0x67, 0x59, 0x64, 0x92, 0x13, 0x10, 0x43,
                                                0xa7, 0x98, 0x80, 0x53, 0xce, 0x3e, 0x93, 0xfd })
  gpu.libraries[#gpu.libraries + 1] = factory_iid
  gpu.libraries[#gpu.libraries + 1] = adapter3_iid
  local out = ffi.new("void *[1]")
  if create(factory_iid, out) ~= 0 then return "off (CreateDXGIFactory1 failed)" end
  local factory = out[0]
  local enum = method(factory, 12, "long (*)(void *, unsigned int, void **)")     -- EnumAdapters1
  local adapters = {}
  for index = 0, 15 do
    if enum(factory, index, out) ~= 0 then break end
    local adapter = out[0]
    local wanted = ffi.new("void *[1]")
    local query_interface = method(adapter, 0, "long (*)(void *, const void *, void **)")
    if query_interface(adapter, adapter3_iid, wanted) == 0 then
      adapters[#adapters + 1] = {
        object = wanted[0],
        query = method(wanted[0], 14, "long (*)(void *, unsigned int, int, mlf_vram_info *)") }
    end
    method(adapter, 2, "unsigned long (*)(void *)")(adapter)                     -- Release
  end
  if #adapters == 0 then return "off (no adapter with QueryVideoMemoryInfo)" end
  local info = ffi.new("mlf_vram_info")
  gpu.read = function()
    local usage, budget = -1, nil
    for _, a in ipairs(adapters) do
      if a.query(a.object, 0, 0, info) == 0 then
        local used = tonumber(info.usage)
        if used > usage then usage, budget = used, tonumber(info.budget) end
      end
    end
    if budget == nil then return nil, nil end
    return usage, budget
  end
  return string.format("dxgi, %d adapters", #adapters)
end

function gpu.tick(at)
  if gpu.read == nil or at < gpu.next_at then return end
  gpu.next_at = at + GPU_SAMPLE_S
  local t0 = now()
  local usage, budget = gpu.read()
  local took = now() - t0
  if type(usage) ~= "number" or type(budget) ~= "number" or budget <= 0 then return end
  if gpu.last == nil then
    say(string.format("vram: first reading %.2f of %.2f GB budget", usage / 1073741824, budget / 1073741824))
  end
  local was_over = gpu.last ~= nil and gpu.last.usage > gpu.last.budget
  gpu.last = { usage = usage, budget = budget }
  if (usage > budget) ~= was_over then ui.dirty = true end
  local m = gpu.minute
  if m == nil then
    m = { n = 0, vram_max = 0, budget = 0, took = 0 }
    gpu.minute = m
  end
  m.n = m.n + 1
  if took > m.took then m.took = took end
  if usage > m.vram_max then m.vram_max = usage end
  m.budget = budget
  if usage > budget then
    local quiet = gpu.alerted ~= nil and at - gpu.alerted < GPU_ALERT_QUIET_S
    if not quiet and (toast == nil or at >= toast.until_at) then
      gpu.alerted = at
      local text = string.format("VRAM %.1f / %.1f GB - over budget", usage / 1073741824, budget / 1073741824)
      gpu.over_text = text
      ui.alert({ text = text, until_at = at + 8, colour = AMBER })
      say("vram: " .. text)
    end
  end
end

-- The window line, only while the latest reading is over budget.
function gpu.line()
  local last = gpu.last
  if last == nil or last.usage <= last.budget then return nil end
  return { string.format("VRAM %.1f / %.1f GB - over budget", last.usage / 1073741824, last.budget / 1073741824),
           AMBER }
end
end

-- ------------------------------------------------------------ memory

-- Which mod keeps growing its Lua memory (v0.9.0; a Nexus user asked for a
-- RAM tracker to find leaks). All mods share one Lua state, so nothing
-- reports memory per mod. Instead, once a minute, the objects each mod holds
-- are counted. A walk from _G (and the registry) marks what is shared: the
-- game's tables and anything a mod keeps in globals. Then a walk from each
-- mod's own functions -- a function knows the file it came from -- counts the
-- tables and strings reachable from them that are not shared; an object two
-- mods can reach goes to the first. Sizes are estimates, since LuaJIT does
-- not show them: 64 bytes a table, 40 an entry, 40 a function, plus the
-- length of each string. A leak only grows: a mod is flagged when its count
-- has not dropped over FLAG_SPAN walks (about 10 minutes), grew by
-- FLAG_MIN_KB or more in that time, and a world change (mission start or
-- end, back to the ship) fell inside that span: a mod's per-mission data
-- grows all mission long and is cleared when it ends; a leak is not
-- (v0.9.1). The main world is compared at the start of each walk. Out of reach: state a mod keeps in
-- globals (counted as shared) and engine objects (units, lights, effects),
-- which are not Lua memory at all. The walk is spread over frames, at most
-- MEM_BUDGET_S and MEM_STEPS objects a frame; its time is this module's own.
local mem = { job = nil, next_at = nil, history = {}, flagged = {}, logged = {}, told = {},
              failed = false, walks = 0, world = nil, worlds = 0, first = {}, dropped = {},
              missed = {} }
local kb_text, mem_step
do
local MEM_EVERY_S = 60
local MEM_BUDGET_S = 0.0003
local MEM_STEPS = 2000
-- v0.41.0 (the user's game, 2026-10-13: Super Holo Kit v1.10.4 held ~123 MB
-- of Lua; this module's own worst frame rose to 25-35 ms once a minute): one
-- table was walked whole in one step, however big. A table is now walked
-- MEM_SLICE entries at a time, the rest in the next steps and frames, and a
-- frame stops after MEM_ENTRIES entries whatever the clock says.
local MEM_SLICE = 512
local MEM_ENTRIES = 8192
-- v0.42.0 (the user, 2026-10-13: the Watchdog took ~11 ms/s in a mission
-- where Super Holo Kit held ~200 MB, about half of it this count; "a bit
-- much for a basic tool"). The next count waits at least MEM_COST_K times
-- what the last one took, so on average it costs at most 1 ms/s: a 340 ms
-- count waits ~6 minutes, a 20 ms one the usual minute. A leak is still
-- judged over FLAG_SPAN counts; its minutes are read from their times.
-- v0.44.0: 2000 (at most ~0.5 ms/s; in game 2026-10-13 a 170 ms count every
-- ~3 minutes was still ~1 ms/s, the minute it ran +3 ms/s).
local MEM_COST_K = 2000
local MEM_KEEP = 16
local FLAG_SPAN = 10
local FLAG_MIN_KB = 256
-- On screen only when it matters to a player (v0.10.0, the user): 10 MB in
-- 10 minutes is ~60 MB an hour, where the Lua collector's work starts to
-- show. At that rate no world change is needed: per-mission data growing that
-- fast is worth knowing about too. Smaller leaks are logged only.
local SCREEN_MIN_KB = 10 * 1024
local SHARED = "(shared)"

local getmeta = dbg and rawget(dbg, "getmetatable") or nil
local getregistry = dbg and rawget(dbg, "getregistry") or nil
local mod_cache = setmetatable({}, { __mode = "k" })

-- The mod a function belongs to ("mods/<author>/<name>"), or nil for the
-- game's own code.
local function mod_of(fn)
  local cached = mod_cache[fn]
  if cached ~= nil then return cached or nil end
  local owner = false
  if type(getinfo) == "function" then
    local ok, info = pcall(getinfo, fn, "S")
    local source = ok and type(info) == "table" and info.source or nil
    if type(source) == "string" then
      if string.sub(source, 1, 1) == "@" then source = string.sub(source, 2) end
      source = string.gsub(source, "%.lua$", "")
      if string.sub(source, 1, 5) == "mods/" then owner = source end
    end
  end
  mod_cache[fn] = owner
  return owner or nil
end

local function mem_new_job(at)
  local job = { phase = 1, q = {}, qo = {}, head = 1, tail = 0,
                seen = setmetatable({}, { __mode = "k" }),
                rooted = setmetatable({}, { __mode = "k" }),
                roots = {}, root_owner = {}, next_root = 1,
                size = {}, objects = 0, frames = 0, spent = 0, started = at }
  -- The walk's own bookkeeping is nobody's memory.
  for _, own in ipairs({ job, job.q, job.qo, job.seen, job.rooted, job.roots,
                         job.root_owner, job.size, mem, mod_cache }) do
    job.seen[own] = SHARED
  end
  return job
end

local function mem_add_root(job, fn, owner)
  if job.rooted[fn] then return end
  job.rooted[fn] = true
  job.roots[#job.roots + 1] = fn
  job.root_owner[#job.root_owner + 1] = owner
end

local function mem_visit(job, obj, owner)
  local kind = type(obj)
  if kind ~= "table" and kind ~= "function" then return end
  if job.seen[obj] ~= nil then return end
  -- Our spies and shims only pass on; what they pass to is walked from the
  -- chain. A stale one (a mod unhooked itself and put it back as _G.update)
  -- still holds the slot it sat in, inside the mod that left: walking it
  -- kept that mod counted and flagged (v0.13.2).
  if kind == "function" and ours[obj] ~= nil then
    job.seen[obj] = SHARED
    return
  end
  if kind == "function" then
    local mod = mod_of(obj)
    if mod ~= nil and mod ~= owner then
      mem_add_root(job, obj, mod)             -- walked later, as that mod's
      return
    end
    if mod == nil and owner ~= SHARED then
      job.seen[obj] = SHARED                  -- the game's code: not a mod's
      return
    end
  end
  job.seen[obj] = owner
  job.tail = job.tail + 1
  job.q[job.tail] = obj
  job.qo[job.tail] = owner
end

-- One step: a function, or up to MEM_SLICE entries of a table. Returns
-- whether the object is done, and how many entries this step took. A table
-- left half-walked goes on from its last key next step; a mod may change it
-- in between, and if next() refuses the old key, what was counted stands.
local function mem_process(job, obj, owner)
  local bytes
  if type(obj) == "table" then
    local key, entries, strings = nil, 0, 0
    local go_on = true
    if job.cont == obj then
      key, entries, strings = job.cont_key, job.cont_entries, job.cont_strings
      go_on = pcall(next, obj, key)
    end
    local taken = 0
    -- v0.42.0: one pcall(next) an entry took ~150 ns (offline, the game's
    -- lua51.dll, 5 M numbers in 0.74 s). Within one step nothing else runs,
    -- so the table cannot change under a plain loop; only the key carried
    -- over from the last step is checked, once.
    if go_on then
      for k, value in next, obj, key do
        entries = entries + 1
        local kind = type(k)
        if kind == "string" then
          strings = strings + #k
        elseif kind == "table" or kind == "function" then
          mem_visit(job, k, owner)
        end
        kind = type(value)
        if kind == "string" then
          strings = strings + #value
        elseif kind == "table" or kind == "function" then
          mem_visit(job, value, owner)
        end
        taken = taken + 1
        if taken >= MEM_SLICE then
          job.cont, job.cont_key, job.cont_entries, job.cont_strings = obj, k, entries, strings
          return false, taken
        end
      end
    end
    job.cont, job.cont_key = nil, nil
    if getmeta ~= nil then mem_visit(job, getmeta(obj), owner) end
    bytes = 64 + 40 * entries + strings
    job.size[owner] = (job.size[owner] or 0) + bytes
    job.objects = job.objects + 1
    return true, taken
  else
    bytes = 40
    for index = 1, 255 do
      local name, value = getupvalue(obj, index)
      if name == nil then break end
      if type(value) == "string" then bytes = bytes + #value else mem_visit(job, value, owner) end
    end
  end
  job.size[owner] = (job.size[owner] or 0) + bytes
  job.objects = job.objects + 1
  return true, 1
end

kb_text = function(kb)
  if kb >= 1024 then return string.format("%.1f MB", kb / 1024) end
  return string.format("%.0f KB", kb)
end

local function mem_finish(job, at)
  mem.job = nil
  mem.next_at = at + math.max(MEM_EVERY_S, job.spent * MEM_COST_K)
  mem.walks = mem.walks + 1
  local rows = {}
  for owner, bytes in pairs(job.size) do
    if owner ~= SHARED then
      local kb = bytes / 1024
      local history = mem.history[owner]
      if history == nil then
        history = {}
        mem.history[owner] = history
      end
      local before = history[#history]
      if mem.first[owner] == nil then mem.first[owner] = kb end
      if before ~= nil and kb < before.kb - 1 then mem.dropped[owner] = true end
      history[#history + 1] = { kb = kb, world = job.world, at = at }
      while #history > MEM_KEEP do table.remove(history, 1) end
      rows[#rows + 1] = { owner = owner, kb = kb, delta = before and (kb - before.kb) or nil }
    end
  end
  table.sort(rows, function(a, b) return a.kb > b.kb end)
  local parts = {}
  for index = 1, math.min(8, #rows) do
    local r = rows[index]
    parts[#parts + 1] = string.format("%s ~%s%s", short_name(r.owner), kb_text(r.kb),
                                      r.delta and string.format(" (%+.0f)", r.delta) or "")
  end
  local ok, heap = false, nil
  if type(collect) == "function" then ok, heap = pcall(collect, "count") end
  say(string.format("memory: %d objects in %d frames (%.1f ms, at most %.1f ms and %d entries a frame; " ..
                    "next in %.0f s); world #%d; Lua heap %s; shared ~%s; %s",
                    job.objects, job.frames, job.spent * 1000, (job.worst_frame or 0) * 1000,
                    job.most_entries or 0, mem.next_at - at, job.world,
                    (ok and type(heap) == "number") and kb_text(heap) or "?",
                    kb_text((job.size[SHARED] or 0) / 1024), table.concat(parts, ", ")))
  -- A leak only grows: no drop over the last FLAG_SPAN walks, grown by
  -- FLAG_MIN_KB or more, across a world change. A drop of up to 1 KB is
  -- noise, not a drop.
  for owner, history in pairs(mem.history) do
    -- An owner two walks in a row did not reach (its link left the chain,
    -- or MDL stopped the script) is judged no more (v0.13.2: its last flag
    -- used to stay on screen for the rest of the session). One miss is
    -- forgiven (v0.13.3, review [11]): a mod can be out of the chain for the
    -- few frames it takes to re-hook at a world change, and one walk
    -- starting then wiped the history a leak needs to cross that change.
    -- Two is the fewest that filters a one-off miss, and keeps a stale MEM
    -- line up at most about one extra minute.
    local missing = job.size[owner] == nil
    if missing then
      mem.missed[owner] = (mem.missed[owner] or 0) + 1
    else
      mem.missed[owner] = nil
    end
    if missing and mem.missed[owner] >= 2 then
      if mem.flagged[owner] ~= nil or mem.logged[owner] ~= nil then
        say(string.format("memory: %s is no longer walked; no longer flagged", owner))
      end
      mem.history[owner], mem.flagged[owner], mem.logged[owner], mem.missed[owner] = nil, nil, nil, nil
      history = {}
    elseif missing then
      history = {}                        -- nothing new to judge this walk; the flags stand
    end
    local count = #history
    local leak, fast = nil, nil
    if count >= FLAG_SPAN + 1 then
      local first = history[count - FLAG_SPAN]
      local grows = true
      for index = count - FLAG_SPAN + 1, count do
        if history[index].kb < history[index - 1].kb - 1 then
          grows = false
          break
        end
      end
      local growth = history[count].kb - first.kb
      local crossed = history[count].world ~= first.world
      -- v0.42.0: the minutes those counts spanned (10 at one a minute); a
      -- longer span asks for as much growth per 10 minutes.
      local minutes = math.floor((history[count].at - first.at) / 60 + 0.5)
      if minutes < FLAG_SPAN then minutes = FLAG_SPAN end
      local found = { kb = history[count].kb, growth = growth, minutes = minutes }
      if grows and crossed and growth >= FLAG_MIN_KB then leak = found end
      if grows and growth >= SCREEN_MIN_KB * minutes / FLAG_SPAN then fast = found end
    end
    -- The log: every leak, however small.
    if leak ~= nil and mem.logged[owner] == nil then
      say(string.format("memory: %s only grows: ~%s, %s more than %d walks ago",
                        owner, kb_text(leak.kb), kb_text(leak.growth), FLAG_SPAN))
    elseif leak == nil and mem.logged[owner] ~= nil and not missing then
      say(string.format("memory: %s dropped again; no longer flagged", owner))
    end
    if job.size[owner] ~= nil then mem.logged[owner] = leak end
    -- The screen: only growth a player would feel.
    if fast ~= nil and mem.flagged[owner] == nil then
      say(string.format("memory: %s grows fast: ~%s, +%s in %d min", owner, kb_text(fast.kb),
                        kb_text(fast.growth), fast.minutes))
      if not mem.told[owner] and ui.alert({ text = string.format("MEM %s +%s in %d min", short_name(owner),
                                                                 kb_text(fast.growth), fast.minutes),
                                            until_at = at + 8, colour = AMBER }) then
        mem.told[owner] = true
      end
    end
    if job.size[owner] ~= nil then mem.flagged[owner] = fast end
  end
  ui.dirty = true
end

-- One frame's share of the walk; starts a new walk once a minute.
mem_step = function(at)
  if mem.failed or type(getupvalue) ~= "function" or type(getinfo) ~= "function" then return end
  local job = mem.job
  if job == nil then
    if mem.next_at == nil then mem.next_at = at + MEM_EVERY_S end
    if at < mem.next_at then return end
    job = mem_new_job(at)
    if type(original_main_world) == "function" then
      local ok, world = pcall(original_main_world)
      if ok and world ~= nil and world ~= mem.world then
        mem.world, mem.worlds = world, mem.worlds + 1
      end
    end
    job.world = mem.worlds
    mem_visit(job, _G, SHARED)
    if type(getregistry) == "function" then
      local ok, registry = pcall(getregistry)
      if ok then mem_visit(job, registry, SHARED) end
    end
    -- v0.45.0: this module is walked last. An object goes to the first mod
    -- that reaches it, and this module holds other mods' tables: the slot a
    -- mod keeps its previous update or render in (a field of its own table).
    -- Walked first -- on top of the chain, as it usually is -- it took them:
    -- in game 2026-10-13 "Mod Lag Watchdog ~194 MB", Super Holo Kit's.
    local own = type(installed.wrapper) == "function" and mod_of(installed.wrapper) or nil
    for _, link in ipairs(links) do
      local mod = type(link.fn) == "function" and mod_of(link.fn) or nil
      if mod ~= nil and mod ~= own then mem_add_root(job, link.fn, mod) end
    end
    if own ~= nil then mem_add_root(job, installed.wrapper, own) end
    mem.job = job
  end
  local started = timer_now()
  local steps, entries = 0, 0
  while steps < MEM_STEPS and entries < MEM_ENTRIES do
    if job.head > job.tail then
      -- Everything shared is marked before any mod is walked.
      job.phase = 2
      local index = job.next_root
      if index > #job.roots then
        job.frames = job.frames + 1
        job.spent = job.spent + (timer_now() - started)
        mem_finish(job, at)
        return
      end
      job.next_root = index + 1
      local fn, owner = job.roots[index], job.root_owner[index]
      if job.seen[fn] == nil then
        job.seen[fn] = owner
        job.tail = job.tail + 1
        job.q[job.tail] = fn
        job.qo[job.tail] = owner
      end
    else
      local head = job.head
      local obj, owner = job.q[head], job.qo[head]
      local done, taken = mem_process(job, obj, owner)
      if done then
        job.q[head], job.qo[head] = nil, nil
        job.head = head + 1
      end
      entries = entries + taken
      if taken >= 64 and timer_now() - started >= MEM_BUDGET_S then
        steps = steps + 1
        break
      end
    end
    steps = steps + 1
    if steps % 32 == 0 and timer_now() - started >= MEM_BUDGET_S then break end
  end
  job.frames = job.frames + 1
  local took = timer_now() - started
  job.spent = job.spent + took
  if took > (job.worst_frame or 0) then job.worst_frame = took end
  if entries > (job.most_entries or 0) then job.most_entries = entries end
end
end   -- memory

-- ------------------------------------------------------------ units

-- Helper units a mod keeps alive (v0.10.0, the user). Lamp and beam mods
-- spawn a small unit to carry each light; a mod that loses track of them
-- leaves lights the GPU draws every frame, and nothing of that shows in Lua
-- memory (Ammo Lamp once kept 2 of every 3 on each unbind). So
-- World.spawn_unit and World.destroy_unit are wrapped: a spawn is charged to
-- the mod whose code called it (the first "mods/" source up the stack), and
-- a destroy is taken off whoever spawned that unit. A world change ends
-- every unit in it, so the counts start again at 0 with each main world.
-- A mod is flagged by its OLD units (v0.12.3): UNITS_MIN or more of its
-- units have been alive for UNITS_OLD_S or longer, and that number has only
-- risen over UNITS_SPAN checks (one a minute). v0.11.0 counted every live
-- unit and was wrong in game (2026-09-30 11:47): Super Laser Sights Plus
-- keeps 34 units per turret and was flagged at 136/170 while players put
-- down turrets one after another. Counting only the live number cannot tell
-- "more turrets" from "never destroyed" -- Ammo Lamp's old bug also went
-- down (a third of the lamps destroyed on each unbind) while it piled up.
-- A helper that follows its turret rarely lives 10 minutes; a leaked one
-- does, and leaks keep adding more. UNITS_MIN is 300 (v0.12.6, the user):
-- Guard Dogs live all mission, and four players' dogs plus a long-lived
-- turret each are 8 x 34 = 272 old Plus units, reached step by step as each
-- turns 10 minutes old; a leak has no ceiling and passes 300 sooner or later.
-- Pass-through:
-- same arguments, same results, errors not caught. Out of reach: a mod that
-- kept its own copy of spawn_unit before this module loaded.
local units = { alive = {}, owner = {}, born = {}, old = {}, history = {}, flagged = {}, told = {},
                world_of = {}, candidate = nil, candidate_at = nil,
                world = nil, installed = false, next_at = nil, max = {}, world_changes = 0 }
do
local UNITS_EVERY_S = 60
local UNITS_MIN = 300          -- old units
local UNITS_SPAN = 5
local UNITS_OLD_S = 600
-- A new main world counts once it has held for UNITS_SETTLE_S (v0.13.2):
-- during a transition the handle flips between worlds (A, B, A --
-- hd2-main-world-flickers), and each flip used to wipe every count.
local UNITS_SETTLE_S = 1

local function source_mod(info)
  local source = type(info) == "table" and info.source or nil
  if type(source) ~= "string" then return nil end
  if string.sub(source, 1, 1) == "@" then source = string.sub(source, 2) end
  source = string.gsub(source, "%.lua$", "")
  if string.sub(source, 1, 5) == "mods/" then return source end
  return nil
end

-- The first mod up the stack that is not this module (our wrappers, and the
-- shims the chain runs through, are ours). Frames of the game's own code
-- (and of a test harness) are passed over, not an answer: a mod's call can
-- reach spawn_unit through them. Spawns are rare, so the few getinfo calls
-- this costs do not matter; the walk stops after 10 levels.
local function caller()
  for level = 2, 11 do
    local ok, info = pcall(getinfo, level, "S")
    if not ok or type(info) ~= "table" then return nil end
    local mod = source_mod(info)
    if mod ~= nil and mod ~= units.own then return mod end
  end
  return nil
end

local function after_spawn(mod, world, ...)
  local unit = (...)
  if mod ~= nil and unit ~= nil and units.owner[unit] == nil then
    units.owner[unit] = mod
    units.world_of[unit] = world
    units.born[unit] = now()
    units.alive[mod] = (units.alive[mod] or 0) + 1
    units.max[mod] = math.max(units.max[mod] or 0, units.alive[mod])
  end
  return ...
end

function units.install()
  if units.installed or World == nil or type(getinfo) ~= "function" then return end
  units.own = source_mod(getinfo(1, "S"))
  local spawn, destroy = rawget(World, "spawn_unit"), rawget(World, "destroy_unit")
  if type(spawn) ~= "function" or type(destroy) ~= "function" then return end
  local spawn_wrapper = function(world, ...)
    return after_spawn(caller(), world, spawn(world, ...))
  end
  local destroy_wrapper = function(world, unit, ...)
    local mod = unit ~= nil and units.owner[unit] or nil
    if mod ~= nil then
      units.owner[unit] = nil
      units.born[unit] = nil
      units.world_of[unit] = nil
      units.alive[mod] = math.max(0, (units.alive[mod] or 1) - 1)
    end
    return destroy(world, unit, ...)
  end
  if pcall(rawset, World, "spawn_unit", spawn_wrapper) then
    if pcall(rawset, World, "destroy_unit", destroy_wrapper) then
      units.installed = true
    else
      pcall(rawset, World, "spawn_unit", spawn)
    end
  end
end

-- Every frame: a new main world, once it has held UNITS_SETTLE_S, ends the
-- units of the world before it (each unit's world is the one it was spawned
-- into) and starts the trends again; units already in the new world stay.
function units.tick(at)
  if not units.installed or type(original_main_world) ~= "function" then return end
  local ok, world = pcall(original_main_world)
  if ok and world ~= nil then
    if units.world == nil then
      units.world, units.world_since = world, at
    elseif world == units.world then
      units.candidate = nil
    elseif units.candidate ~= world then
      units.candidate, units.candidate_at = world, at
    elseif at - units.candidate_at >= UNITS_SETTLE_S then
      units.world_changes = units.world_changes + 1
      units.world, units.candidate, units.world_since = world, nil, at
      for unit, mod in pairs(units.owner) do
        if units.world_of[unit] ~= world then
          units.owner[unit], units.born[unit], units.world_of[unit] = nil, nil, nil
          units.alive[mod] = math.max(0, (units.alive[mod] or 1) - 1)
        end
      end
      units.old, units.history, units.flagged = {}, {}, {}
      say(string.format("units: main world changed (#%d)", units.world_changes))
    end
  end
  if units.next_at == nil then units.next_at = at + UNITS_EVERY_S end
  if at < units.next_at then return end
  units.next_at = at + UNITS_EVERY_S
  -- The table holds only live units, once a minute: cheap.
  local old = {}
  for unit, mod in pairs(units.owner) do
    local born = units.born[unit]
    if born ~= nil and at - born >= UNITS_OLD_S then old[mod] = (old[mod] or 0) + 1 end
  end
  units.old = old
  local rows = {}
  for mod, count in pairs(units.alive) do
    local aged = old[mod] or 0
    local history = units.history[mod]
    if history == nil then
      history = {}
      units.history[mod] = history
    end
    history[#history + 1] = aged
    while #history > UNITS_SPAN + 1 do table.remove(history, 1) end
    local rising = #history == UNITS_SPAN + 1 and aged > history[1]
    for index = 2, #history do
      if history[index] < history[index - 1] then rising = false end
    end
    local flag = (rising and aged >= UNITS_MIN) and { alive = count, old = aged } or nil
    if flag ~= nil and units.flagged[mod] == nil then
      say(string.format("units: %s has %d units older than 10 min and still rising", mod, aged))
      if not units.told[mod] and ui.alert({ text = string.format("UNITS %s %d old units, still rising",
                                                                   short_name(mod), aged),
                                             until_at = at + 8, colour = AMBER }) then
        units.told[mod] = true
      end
    end
    units.flagged[mod] = flag
    if count > 0 then rows[#rows + 1] = { mod = mod, count = count, old = aged } end
  end
  if #rows > 0 then
    table.sort(rows, function(a, b) return a.count > b.count end)
    local parts = {}
    for index = 1, math.min(8, #rows) do
      parts[#parts + 1] = string.format("%s %d (%d old)", short_name(rows[index].mod), rows[index].count,
                                        rows[index].old)
    end
    say("units: alive " .. table.concat(parts, ", "))
  end
  ui.dirty = true
end
end   -- units

-- ------------------------------------------------------------ report

-- One mod's diagnosis in 8 lines, for its author (v0.11.0, the user): a
-- click on the mod's row in the escape-menu window copies it to the
-- clipboard, to paste into a Nexus comment. The clipboard is Windows' own
-- (user32 / kernel32 through ffi), called on that click only; if it cannot be
-- used, the report is written to mod_lag_report_<mod>.txt next to the log.
-- No paths, user names or hardware in it; the other mods only as a count.
local export_report
do
local function copy_to_clipboard(text)
  local seam = rawget(_G, "__hd2_native_test")
  if type(seam) == "table" then
    if type(seam.clipboard) ~= "function" then return nil, "no clipboard in the test seam" end
    if seam.clipboard(text) == true then return true end
    return nil, "the test seam refused"
  end
  local loader = rawget(_G, "require")
  if type(loader) ~= "function" then return nil, "no require" end
  local ok, ffi = pcall(loader, "ffi")
  if not ok or type(ffi) ~= "table" then return nil, "no ffi" end
  local done, why = pcall(function()
    for _, decl in ipairs({ "int OpenClipboard(void *owner);", "int EmptyClipboard(void);",
                            "int CloseClipboard(void);",
                            "int MultiByteToWideChar(unsigned int page, unsigned long flags, " ..
                              "const char *text, int bytes, void *wide, int chars);",
                            "void *SetClipboardData(unsigned int format, void *memory);",
                            "void *GlobalAlloc(unsigned int flags, size_t bytes);",
                            "void *GlobalLock(void *memory);", "int GlobalUnlock(void *memory);",
                            "void *GlobalFree(void *memory);" }) do
      pcall(ffi.cdef, decl)
    end
    local user32, kernel32 = ffi.load("user32"), ffi.load("kernel32")
    local open = ffi.cast("int (*)(void *)", user32.OpenClipboard)
    local empty = ffi.cast("int (*)(void)", user32.EmptyClipboard)
    local close = ffi.cast("int (*)(void)", user32.CloseClipboard)
    local set = ffi.cast("void *(*)(unsigned int, void *)", user32.SetClipboardData)
    local alloc = ffi.cast("void *(*)(unsigned int, size_t)", kernel32.GlobalAlloc)
    local lock = ffi.cast("void *(*)(void *)", kernel32.GlobalLock)
    local unlock = ffi.cast("int (*)(void *)", kernel32.GlobalUnlock)
    local free = ffi.cast("void *(*)(void *)", kernel32.GlobalFree)
    local wide = ffi.cast("int (*)(unsigned int, unsigned long, const char *, int, void *, int)",
                          kernel32.MultiByteToWideChar)
    -- UTF-8 to UTF-16 (CF_UNICODETEXT, v0.17.1): CF_TEXT is read in the
    -- system's ANSI code page, which turned Chinese mod names into "?".
    local chars = wide(65001, 0, text, -1, nil, 0)           -- with its NUL
    if chars <= 0 then error("MultiByteToWideChar failed") end
    local memory = alloc(0x0002, chars * 2)                  -- GMEM_MOVEABLE
    if memory == nil then error("GlobalAlloc failed") end
    local target = lock(memory)
    if target == nil then
      free(memory)
      error("GlobalLock failed")
    end
    if wide(65001, 0, text, -1, target, chars) <= 0 then
      unlock(memory)
      free(memory)
      error("MultiByteToWideChar failed")
    end
    unlock(memory)
    if open(nil) == 0 then
      free(memory)
      error("the clipboard is busy")
    end
    empty()
    if set(13, memory) == nil then                           -- CF_UNICODETEXT; Windows owns it now
      free(memory)
      close()
      error("SetClipboardData failed")
    end
    close()
  end)
  if done then return true end
  return nil, tostring(why)
end

-- How each enabled mod runs (v0.17.1; a player whose "(the game)" read
-- 272.6 ms/s with only 4 mods in the update, 2026-10-01): a mod whose Lua
-- resource is a link of the update chain is timed one by one; one that only
-- ships Lua with no HD2-Addon line, none of it in the chain, replaces the
-- game's own scripts (likely: the game calls them, so their time is counted
-- as "(the game)"); Lua with that line but not in the chain runs some other
-- way; no Lua at all is models, textures and sounds.
local function by_how_it_runs()
  local chain = {}
  for _, link in ipairs(links) do
    if type(link.source) == "string" then chain[installed.hash_of(link.source)] = link end
  end
  local groups = { timed = {}, scripts = {}, other = {}, none = {}, loose = {}, shared = {} }
  -- A resource two mods ship (v0.19.0): the copy that runs is timed; the
  -- others are listed as replaced by it. When the running copy cannot be
  -- told, every one of them stays as it was and a line says so.
  local replaced, lost = {}, {}         -- mod -> who replaced it; mod -> { its keys that do not run }
  for _, list in ipairs(installed.shared_rows) do
    local winner, undecided = nil, false
    for _, claim in ipairs(list) do
      local link = chain[claim.key]
      if link ~= nil then
        local owner = installed.shared_owner(link)
        if owner ~= nil then winner = owner else undecided = true end
      end
    end
    if winner ~= nil then
      for _, claim in ipairs(list) do
        if claim ~= winner then
          replaced[claim.listed] = winner.plain
          lost[claim.listed] = lost[claim.listed] or {}
          lost[claim.listed][claim.key] = true
        end
      end
    elseif undecided then
      local labels = {}
      for _, claim in ipairs(list) do labels[#labels + 1] = claim.plain end
      groups.shared[#groups.shared + 1] = table.concat(labels, " / ") .. " (which one runs: unknown)"
    end
  end
  local claimed = {}
  for _, mod in ipairs(installed.mod_list or {}) do
    local timed = false
    for key in pairs(mod.keys) do
      if chain[key] ~= nil then
        claimed[key] = true
        if not (lost[mod] and lost[mod][key]) then timed = true end
      end
    end
    if timed then
      groups.timed[#groups.timed + 1] = mod.label
    elseif replaced[mod] ~= nil then
      groups.shared[#groups.shared + 1] = mod.label .. " (replaced by " .. replaced[mod] .. ")"
    elseif mod.lua == 0 then
      groups.none[#groups.none + 1] = mod.label
    elseif mod.scripts > 0 then
      groups.scripts[#groups.scripts + 1] = mod.label ..
        (mod.scripts == 1 and " (1 script)" or string.format(" (%d scripts)", mod.scripts))
    else
      groups.other[#groups.other + 1] = mod.label
    end
  end
  -- Links of the update no Arsenal mod ships (another manager, a manual install).
  for hash, link in pairs(chain) do
    if not claimed[hash] and link.bottom ~= "game" and link.fn ~= installed.wrapper and is_mod_source(link.source) then
      groups.loose[#groups.loose + 1] = short_name(link.source)
    end
  end
  for _, list in pairs(groups) do
    table.sort(list, function(a, b) return string.lower(a) < string.lower(b) end)
  end
  return groups
end

-- A key's cost so far: ms/s over the session, and the session's length.
local function session_cost(key, at)
  local partial = window.started and math.max(0, at - window.started) or 0
  local seconds = (session.time or 0) + partial
  local total = session.mods and session.mods[key] or nil
  local now_row = window.mods[key]
  local time = (total and total.time or 0) + (now_row and now_row.time or 0)
  local frames = (session.frames or 0) + window.frames
  return seconds > 0 and time * 1000 / seconds or 0, seconds, frames
end

-- Names joined with ", ", wrapped at about 100 characters, each line indented.
local function wrapped(list)
  local out, line = {}, ""
  for index, name in ipairs(list) do
    local piece = name .. (index < #list and "," or "")
    if line ~= "" and #line + 1 + #piece > 100 then
      out[#out + 1] = "  " .. line
      line = piece
    else
      line = line == "" and piece or (line .. " " .. piece)
    end
  end
  if line ~= "" then out[#out + 1] = "  " .. line end
  return out
end

local function mod_list_text(at)
  local version = string.match(MARKER, "(v[%d%.]+)$") or MARKER
  local game, seconds, frames = session_cost("(the game)", at)
  local lines = {
    string.format("Mod Lag Watchdog mod list (%s, game build %s), Watchdog build %s", version,
                  native.stamp and string.format("%08X", native.stamp) or "unknown", installed.build or "unknown"),
    string.format("Session: %.0f min, %.0f FPS average; \"(the game)\" %.1f ms/s average",
                  seconds / 60, seconds > 0 and frames / seconds or 0, game),
  }
  if installed.mod_list == nil then
    lines[#lines + 1] = "No mod manager list: " .. tostring(installed.mod_list_why)
  else
    lines[#lines + 1] = string.format("Enabled in %s: %d mods", installed.manager or "Arsenal", #installed.mod_list)
  end
  local groups = by_how_it_runs()
  for _, group in ipairs({
      { groups.timed, "Timed one by one (hook the game's update)" },
      { groups.scripts, "Replace the game's own scripts (their cost shows as \"(the game)\")" },
      { groups.other, "Lua that is not in the update" },
      { groups.none, "No Lua (models, textures, sounds)" },
      { groups.loose, "In the update but not in " .. (installed.manager or "Arsenal") },
      { groups.shared, "Ship the same Lua resource as another mod (only one runs)" } }) do
    if #group[1] > 0 or (group[1] ~= groups.loose and group[1] ~= groups.shared) then
      lines[#lines + 1] = string.format("%s: %d", group[2], #group[1])
      for _, line in ipairs(wrapped(group[1])) do lines[#lines + 1] = line end
    end
  end
  return table.concat(lines, "\r\n"), installed.mod_list and #installed.mod_list or 0
end

local function report_text(key, at)
  local name = short_name(key)
  local version = string.match(MARKER, "(v[%d%.]+)$") or MARKER
  local chain = 0
  for _, link in ipairs(links) do
    if string.sub(tostring(link.source), 1, 5) == "mods/" or link.patch or link.boot_patch then
      chain = chain + 1
    end
  end
  -- The session so far: the summaries written plus the minute under way.
  local partial = window.started and math.max(0, at - window.started) or 0
  local seconds = (session.time or 0) + partial
  local frames = (session.frames or 0) + window.frames
  local total = session.mods and session.mods[key] or nil
  local now_row = window.mods[key]
  local time = (total and total.time or 0) + (now_row and now_row.time or 0)
  local worst = math.max(total and total.worst or 0, now_row and now_row.worst or 0)
  local peak = total and total.peak or 0
  if now_row ~= nil and partial >= 10 then peak = math.max(peak, now_row.time * 1000 / partial) end
  local stalls = session.stalls and session.stalls[key] or nil
  local stall_text = "Stalls it caused (150 ms+): 0"
  if stalls ~= nil and stalls.count > 0 then
    local parts = {}
    for index = 1, math.min(3, #stalls.top) do parts[index] = ms(stalls.top[index]) end
    stall_text = string.format("Stalls it caused (150 ms+): %d (%s ms)", stalls.count,
                               table.concat(parts, ", "))
  end
  local history = mem.history[key]
  local memory_text = "Lua memory: not counted yet (once a minute)"
  if history ~= nil and #history > 0 then
    local first = mem.first[key] or history[1].kb
    local trend = mem.dropped[key] and "goes up and down" or "has only grown so far"
    memory_text = string.format("Lua memory: %s -> %s, %s", kb_text(first), kb_text(history[#history].kb),
                                trend)
  end
  local alive, most = units.alive[key] or 0, units.max[key] or 0
  local units_text = most > 0 and string.format("Helper units: %d alive (%d at most), %d older than 10 min",
                                                alive, most, units.old[key] or 0)
                               or "Helper units: none spawned"
  local copies = 1
  for _, r in ipairs(rehook.repeated) do
    if r.source == key then copies = r.n end
  end
  local on_top = #links > 0 and links[1].source == key and links[1].fn ~= installed.wrapper
  local last = string.format("Update hook: hooked %d time%s, %s%s", copies, copies == 1 and "" or "s",
                             on_top and "on top (its own time not measured)" or "not on top",
                             (installed.errors_session[key] or 0) > 0
                               and string.format("; Lua errors in %d frames", installed.errors_session[key]) or "")
  -- The game's own row has no hook of its own: the mods counted in it go
  -- there instead (v0.17.1).
  if key == "(the game)" then
    local scripts = by_how_it_runs().scripts
    if installed.mod_list == nil then
      last = "Mods that replace game scripts: unknown (no mod manager list)"
    elseif #scripts == 0 then
      last = "Mods that replace game scripts (counted here): none in " .. (installed.manager or "Arsenal")
    else
      last = "Mods that replace game scripts (counted here): " .. table.concat(scripts, ", ")
    end
  end
  -- Which mod in the mod manager this is (v0.22.0): a player who saw only a
  -- short or borrowed name could not tell. The name as Arsenal has it, in
  -- any language (the clipboard is Unicode; the screen font is not), and
  -- its folder relative to Arsenal's mods folder.
  -- v0.26.0: when several mods ship the script, each is marked running or
  -- not, from the same comparison of the running code with each copy that
  -- names the row (installed.shared_owner, v0.19.0); the first line alone
  -- said which, and a reader of the second could not tell.
  local manager = nil
  if key ~= "(the game)" and string.sub(key, 1, 5) ~= "mdl: " then
    local bare = string.gsub(key, " %(%+ all below it%)$", "")
    local hash = installed.hash_of(bare)
    if installed.mod_list == nil then
      manager = "Mod manager: unknown (no mod manager list)"
    else
      local found = {}
      for _, listed in ipairs(installed.mod_list) do
        if hash ~= nil and listed.keys[hash] then found[#found + 1] = listed end
      end
      local function folder(listed)
        return string.format("%s [folder: %s]", listed.label, listed.folder or "?")
      end
      if #found == 0 then
        manager = "Mod manager: not among the mods enabled in " .. (installed.manager or "Arsenal") .. " (installed another way?)"
      elseif #found == 1 then
        manager = "Mod manager: " .. folder(found[1])
      else
        local running = nil
        for _, link in ipairs(links) do
          if link.source == bare then
            local claim = installed.shared_owner(link)
            running = claim and claim.listed or nil
            break
          end
        end
        local parts = {}
        for _, listed in ipairs(found) do
          parts[#parts + 1] = folder(listed) ..
            (running == nil and "" or (listed == running and " (running)" or " (not running)"))
        end
        manager = string.format("Mod manager: %d mods ship this script%s: %s", #found,
                                running == nil and ", only one runs, not told which" or "",
                                table.concat(parts, "; "))
      end
    end
  end
  local lines = {
    string.format("Mod Lag Watchdog report: %s (%s)", name, key),
    string.format("Game build %s, Watchdog %s, %d mods hook the update; Watchdog build %s",
                  native.stamp and string.format("%08X", native.stamp) or "unknown", version, chain,
                  installed.build or "unknown"),
    string.format("Session: %.0f min, %.0f FPS average, %d world changes", seconds / 60,
                  seconds > 0 and frames / seconds or 0, units.world_changes or 0),
    string.format("Cost: %.1f ms/s average, %.1f ms/s in the worst minute, worst frame %s ms",
                  seconds > 0 and time * 1000 / seconds or 0, peak, ms(worst)),
    stall_text,
    memory_text,
    units_text,
    last,
  }
  if manager ~= nil then table.insert(lines, 2, manager) end
  return table.concat(lines, "\r\n")
end

export_report = function(key, at)
  local text = report_text(key, at)
  local name = short_name(key)
  local ok, why = copy_to_clipboard(text)
  if ok then
    say("report: copied for " .. key)
    toast = { text = "report copied: " .. name, until_at = at + 5, colour = WHITE }
  else
    local file_name = "mod_lag_report_" .. string.gsub(name, "[^%w]+", "_") .. ".txt"
    local path = log_path and string.gsub(log_path, "mod_lag_finder%.log$", file_name) or nil
    local file = path and io.open(path, "w") or nil
    if file ~= nil then
      file:write((string.gsub(text, "\r\n", NL)), NL)      -- text mode adds the \r itself
      file:close()
    end
    say(string.format("report: clipboard unavailable (%s); written to %s", tostring(why), file_name))
    toast = { text = "report saved: " .. file_name, until_at = at + 8, colour = AMBER }
  end
  ui.dirty = true
end

-- "copy mod list" in the escape-menu window (v0.17.1): every enabled mod,
-- by how it runs, for a bug report. Like the report, the clipboard is used
-- on the click only; without it the list goes to mod_lag_mod_list.txt.
installed.export_mod_list = function(at)
  local text, count = mod_list_text(at)
  local ok, why = copy_to_clipboard(text)
  if ok then
    say(string.format("mod list: copied (%d mods)", count))
    toast = { text = string.format("mod list copied (%d mods)", count), until_at = at + 5, colour = WHITE }
  else
    local path = log_path and string.gsub(log_path, "mod_lag_finder%.log$", "mod_lag_mod_list.txt") or nil
    local file = path and io.open(path, "w") or nil
    if file ~= nil then
      file:write((string.gsub(text, "\r\n", NL)), NL)
      file:close()
    end
    say(string.format("mod list: clipboard unavailable (%s); %s", tostring(why),
                      file ~= nil and "written to mod_lag_mod_list.txt" or "not written"))
    toast = { text = file ~= nil and "mod list saved: mod_lag_mod_list.txt" or "mod list: no clipboard",
              until_at = at + 8, colour = AMBER }
  end
  ui.dirty = true
end
end   -- report

local function panel_lines(at)
  local out = {}
  local rows, frames, time, stalls, seconds = {}, 0, 0, 0, 0
  local merged = {}
  local buckets = {}
  for _, bucket in ipairs(live.ring) do buckets[#buckets + 1] = bucket end
  if live.bucket ~= nil then
    buckets[#buckets + 1] = live.bucket          -- the second under way
  end
  -- The real time the buckets cover (v0.13.2): a bucket closes only when a
  -- tick comes, so one that held a 3 s frame spans 3 s, not 1 -- counting
  -- each as a second made every mod's ms/s read high after a stall.
  if #buckets > 0 then seconds = math.max(0, at - buckets[1].at) end
  for _, bucket in ipairs(buckets) do
    frames, time, stalls = frames + bucket.frames, time + bucket.time, stalls + bucket.stalls
    for key, row in pairs(bucket.mods) do
      local m = merged[key]
      if m == nil then
        m = { time = 0, worst = 0 }
        merged[key] = m
      end
      m.time = m.time + row.time
      if row.worst > m.worst then m.worst = row.worst end
    end
  end
  -- v0.32.0: the seconds a mod sat on top of the chain, where it is not
  -- measured, are left out of its average. HD2 HUD+ 0.2.2 climbs on top
  -- while the menu is open: its row fell to nothing on the menu and read
  -- low for 30 s after. Its row is now its average over the measured
  -- seconds, marked "(in play)" while it is on top.
  local unmeasured = {}
  for index, bucket in ipairs(buckets) do
    if bucket.tops ~= nil then
      local finish = buckets[index + 1] ~= nil and buckets[index + 1].at or at
      local span = math.max(0, finish - bucket.at)
      for key in pairs(bucket.tops) do unmeasured[key] = (unmeasured[key] or 0) + span end
    end
  end
  for key, row in pairs(merged) do
    local measured = seconds - (unmeasured[key] or 0)
    if measured >= 1 or unmeasured[key] == nil then
      rows[#rows + 1] = { key = key, row = row,
                          mss = row.time * 1000 / math.max(unmeasured[key] and measured or seconds, 0.001),
                          in_play = unmeasured[key] ~= nil and unmeasured[key] > 0 }
    end
  end
  -- v0.30.0 (a Nexus player: which mod had the worst frame in the window
  -- shows what goes with a stutter): click "ms/s" or "worst" to sort by it.
  if ui.sort_worst then
    table.sort(rows, function(a, b)
      if a.row.worst ~= b.row.worst then return a.row.worst > b.row.worst end
      return a.mss > b.mss
    end)
  else
    table.sort(rows, function(a, b) return a.mss > b.mss end)
  end

  if frames > 0 then
    out[#out + 1] = { string.format("last %.0f s: frame %.1f ms avg, stalls >= %d ms: %d",
                                    seconds, time * 1000 / frames, HITCH_MS, stalls), GREY }
  end
  local gpu_row = gpu.line()
  if gpu_row ~= nil then out[#out + 1] = gpu_row end
  local worst_write = writes_worst()
  out[#out + 1] = { string.format("slowest log write: %.0f ms", worst_write * 1000),
                    worst_write >= 0.1 and AMBER or GREY }
  if mapping ~= nil then
    out[#out + 1] = { "mapping the update chain ...", GREY }
  elseif seconds > 0 then
    -- In missions only the obvious cases are listed (under QUIET_MSS and
    -- QUIET_WORST_MS they are only counted). On the escape menu every mod
    -- is listed, the small ones in grey (v0.12.2, the user: a player who
    -- fixed a mod from 150 to 7 ms/s has to see the 7 to know it worked).
    local all = ui.in_menu
    local shown, quiet, more = 0, 0, 0
    for _, r in ipairs(rows) do
      local per_second = r.mss
      if not all and per_second < QUIET_MSS and r.row.worst * 1000 < QUIET_WORST_MS then
        quiet = quiet + 1
      elseif shown >= PANEL_ROWS then
        more = more + 1
      else
        if shown == 0 then
          -- The column it is sorted by carries a "v" in front (v0.31.1: after
          -- the label it pushed "ms/s" and "worst" two characters left of
          -- their numbers -- the user's screenshot); on the menu the line is
          -- clicked by column (handle_mouse).
          out[#out + 1] = { string.format("%-28s %8s %9s", "mod", ui.sort_worst and "ms/s" or "v ms/s",
                                          ui.sort_worst and "v worst" or "worst"), GREY,
                            all and ui.sort_key or nil }
        end
        shown = shown + 1
        local tint = (r.row.worst * 1000 >= TOAST_MS or per_second >= AMBER_MSS) and AMBER or WHITE
        if all and tint == WHITE and per_second < QUIET_MSS then tint = GREY end
        local label = r.in_play and (string.sub(short_name(r.key), 1, 18) .. " (in play)")
                      or string.sub(short_name(r.key), 1, 28)
        out[#out + 1] = { string.format("%-28s %8.1f %6s ms", label, per_second, ms(r.row.worst)), tint, r.key }
      end
    end
    if more > 0 then
      out[#out + 1] = { all and string.format("+ %d more", more)
                             or string.format("+ %d more at %d ms/s or more", more, QUIET_MSS), GREY }
    end
    if quiet > 0 then
      out[#out + 1] = { string.format("%s%d mod%s under %d ms/s", shown > 0 and "+ " or "all ",
                                      quiet, quiet == 1 and "" or "s", QUIET_MSS), GREY }
    end
  end
  if session.game_no ~= nil then
    local ok, hhmm = pcall(os.date, "%H:%M", session.deploy / 1000)
    out[#out + 1] = { string.format("game #%d after the %s deploy", session.game_no,
                                    ok and hhmm or "?"), GREY }
  end
  if #rehook.repeated > 0 then
    local parts = {}
    for k = 1, math.min(3, #rehook.repeated) do
      local r = rehook.repeated[k]
      parts[#parts + 1] = short_name(r.source) .. " x" .. r.n
    end
    out[#out + 1] = { "hooked more than once: " .. table.concat(parts, ", "),
                      rehook.repeated[1].n >= REHOOK_COPIES and AMBER or GREY }
  end
  if #links > 0 and links[1].fn ~= installed.wrapper then
    out[#out + 1] = { "on top, not measured: " .. short_name(links[1].source), GREY }
  end
  if installed.link_limit then
    out[#out + 1] = { string.format("more than %d hooks: the last row counts all below it", MAX_LINKS), AMBER }
  end
  if installed.churn_line ~= nil and at < installed.churn_line.until_at then
    out[#out + 1] = { installed.churn_line.text, AMBER }
  end
  for owner, flag in pairs(mem.flagged) do
    out[#out + 1] = { string.format("MEM %s ~%s, +%s in %d min", short_name(owner), kb_text(flag.kb),
                                    kb_text(flag.growth), flag.minutes), AMBER }
  end
  for mod, flag in pairs(units.flagged) do
    out[#out + 1] = { string.format("UNITS %s %d old units, still rising", short_name(mod), flag.old), AMBER }
  end
  local raised, order = {}, {}
  for _, bucket in ipairs(buckets) do
    for key, n in pairs(bucket.errors or {}) do
      if raised[key] == nil then order[#order + 1] = key end
      raised[key] = (raised[key] or 0) + n
    end
  end
  -- Most first, so two mods do not swap places between refreshes (review [15]).
  table.sort(order, function(a, b)
    if raised[a] ~= raised[b] then return raised[a] > raised[b] end
    return a < b
  end)
  for _, key in ipairs(order) do
    out[#out + 1] = { string.format("ERROR %s %.0f frames/min", short_name(key),
                                    raised[key] * 60 / math.max(seconds, 1)), AMBER }
  end
  if last_stall ~= nil then
    out[#out + 1] = { string.format("last stall %s ms %s, %.0f s ago", ms(last_stall.ms),
                                    last_stall.cause and ("in " .. last_stall.cause)
                                      or last_stall.who and ("in " .. last_stall.who) or "outside every mod",
                                    at - last_stall.at),
                      last_stall.who and RED or GREY }
  end
  return out
end

local function resolution()
  local fn = Gui and rawget(Gui, "resolution")
  if type(fn) == "function" then
    local ok, width, height = pcall(fn)
    if ok and type(width) == "number" and type(height) == "number" then return width, height end
  end
  return 1920, 1080
end

-- Where the window is on this screen, kept on it so it can always be
-- dragged back.
local function geometry(rows)
  local width, height = resolution()
  local s = math.min(width / 1920, height / 1080)
  local w = WIN_W * s
  local h = (HEADER + PAD * 2 + LINE * rows) * s
  local x = math.max(0, math.min(width - w, ui.place.x * s))
  local top = math.max(HEADER * s, math.min(height, ui.place.top * s))
  return { s = s, x = x, top = top, w = w, h = h, width = width, height = height }
end

-- Everything on screen as a list; its signature decides whether to rebuild.
local function items(at)
  local list = {}
  local window_shown = ui.in_menu or ui.panel
  -- On the menu the window can be folded to its title bar (v0.20.0, the
  -- user: some find it in the way); the table in play is not affected.
  local folded = ui.in_menu and ui.folded
  local lines = (window_shown and not folded) and panel_lines(at) or {}
  local g = geometry(folded and 0 or (#lines + (ui.in_menu and 5 or 1)))
  ui.geometry = g
  ui.button = nil
  local s = g.s
  -- The title carries the version (v0.28.0, the user): a screenshot says
  -- which build it is. ~24 characters at 8.4 px (1080p) end well before
  -- the [-] button.
  ui.title = ui.title or ("MOD LAG WATCHDOG " .. (string.match(MARKER, "(v[%d%.]+)$") or ""))
  if window_shown and folded then
    list[#list + 1] = { rect = true, x = g.x, y = g.top - HEADER * s, w = g.w, h = HEADER * s,
                        z = 91, c = BAND }
    list[#list + 1] = { text = ui.title, x = g.x + PAD * s,
                        y = g.top - HEADER * s + 8 * s, size = TITLE_SIZE * s, c = WHITE }
    list[#list + 1] = { text = "[+]", x = g.x + g.w - (PAD + 28) * s,
                        y = g.top - HEADER * s + 8 * s, size = TITLE_SIZE * s, c = WHITE }
    ui.button = g.x + g.w - (PAD + 36) * s
    ui.rows = {}
  elseif window_shown and ui.in_menu then
    -- On the menu: a window to drag, with a background and a title bar.
    list[#list + 1] = { rect = true, x = g.x, y = g.top - g.h, w = g.w, h = g.h, z = 90, c = BACK }
    list[#list + 1] = { rect = true, x = g.x, y = g.top - HEADER * s, w = g.w, h = HEADER * s,
                        z = 91, c = BAND }
    list[#list + 1] = { text = ui.title, x = g.x + PAD * s,
                        y = g.top - HEADER * s + 8 * s, size = TITLE_SIZE * s, c = WHITE }
    -- At the title bar's right end, like a window's minimize button.
    list[#list + 1] = { text = "[-]", x = g.x + g.w - (PAD + 28) * s,
                        y = g.top - HEADER * s + 8 * s, size = TITLE_SIZE * s, c = WHITE }
    ui.button = g.x + g.w - (PAD + 36) * s
    local y = g.top - HEADER * s - PAD * s - LINE * s + 6 * s
    ui.rows = {}
    for _, line in ipairs(lines) do
      list[#list + 1] = { text = line[1], x = g.x + PAD * s, y = y, size = TEXT_SIZE * s, c = line[2] }
      if line[3] ~= nil then
        ui.rows[#ui.rows + 1] = { key = line[3], bottom = y - 6 * s, top = y - 6 * s + LINE * s }
      end
      y = y - LINE * s
    end
    -- A switch for keyboards without Home (v0.11.0, players on Nexus): the
    -- same table in missions, on or off, remembered like the place.
    list[#list + 1] = { text = ui.panel and "show table in missions: ON  (click to turn off)"
                                         or "show table in missions: OFF (click to turn on)",
                        x = g.x + PAD * s, y = y, size = TEXT_SIZE * s, c = ui.panel and WHITE or GREY }
    ui.rows[#ui.rows + 1] = { key = SWITCH, bottom = y - 6 * s, top = y - 6 * s + LINE * s }
    y = y - LINE * s
    -- The pop-up lines (LAG, REHOOK, MEM, UNITS) can be turned off too
    -- (v0.12.2, the user): with both off nothing at all is drawn in a
    -- mission. Everything is still logged, and the menu window still shows
    -- the last stall.
    list[#list + 1] = { text = ui.alerts_off and "show alerts in missions: OFF (click to turn on)"
                                              or "show alerts in missions: ON  (click to turn off)",
                        x = g.x + PAD * s, y = y, size = TEXT_SIZE * s,
                        c = ui.alerts_off and GREY or WHITE }
    ui.rows[#ui.rows + 1] = { key = ALERTS, bottom = y - 6 * s, top = y - 6 * s + LINE * s }
    y = y - LINE * s
    -- Every enabled mod and how it runs, for a bug report (v0.17.1).
    list[#list + 1] = { text = "copy mod list (for a bug report)",
                        x = g.x + PAD * s, y = y, size = TEXT_SIZE * s, c = WHITE }
    ui.rows[#ui.rows + 1] = { key = "\0mod list", bottom = y - 6 * s, top = y - 6 * s + LINE * s }
    y = y - LINE * s
    list[#list + 1] = { text = "drag the title bar; right-click it: default place",
                        x = g.x + PAD * s, y = y, size = TEXT_SIZE * s, c = GREY }
    list[#list + 1] = { text = "click a mod: copy its report; ms/s or worst: sort",
                        x = g.x + PAD * s, y = y - LINE * s, size = TEXT_SIZE * s, c = GREY }
  elseif window_shown then
    -- In play: the lines alone, shadowed, at exactly the places they have in
    -- the menu's window -- no background, no title, nothing else in the way
    -- (user, 2026-09-29), and nothing moves when the menu closes (v0.3.5;
    -- v0.3.3 moved them up into the title bar's place).
    local y = g.top - HEADER * s - PAD * s - LINE * s + 6 * s
    for _, line in ipairs(lines) do
      list[#list + 1] = { text = line[1], x = g.x + PAD * s, y = y, size = TEXT_SIZE * s,
                          c = line[2], shadow = true }
      y = y - LINE * s
    end
  end
  if toast ~= nil and at < toast.until_at and (ui.in_menu or not ui.alerts_off or toast.always) then
    local y = window_shown and (g.top + 8 * s) or (g.top - HEADER * s + 8 * s)
    -- A window dragged to the top of the screen leaves no room above it: the
    -- line goes under the window instead (v0.16.0; it was drawn off screen).
    if window_shown and y + 24 * s > g.height then y = math.max(4 * s, g.top - g.h - 26 * s) end
    list[#list + 1] = { text = toast.text, x = g.x + PAD * s, y = y, size = 20 * s,
                        c = toast.colour or RED,
                        shadow = true }
  end
  return list
end

local function signature(list)
  local parts = {}
  for _, item in ipairs(list) do
    parts[#parts + 1] = string.format("%s@%.0f,%.0f", item.text or "#", item.x, item.y)
  end
  return table.concat(parts, "|")
end

local function draw(list)
  local key = signature(list)
  if ui.gui ~= nil and ui.signature == key and world_live(ui.world) then return end
  drop_gui()
  if #list == 0 then return end
  local gui = new_gui()
  if gui == nil then return end
  local rect, write = Gui and rawget(Gui, "rect"), Gui and rawget(Gui, "text")
  for _, item in ipairs(list) do
    if item.rect then
      if type(rect) == "function" and callable(V2) and callable(V3) then
        local ok_p, pos = pcall(V3, item.x, item.y, item.z)
        local ok_s, size = pcall(V2, item.w, item.h)
        if ok_p and ok_s then pcall(rect, gui, pos, size, colour(item.c)) end
      end
    elseif type(write) == "function" and callable(V3) then
      if item.shadow then
        local ok_sp, shadow_pos = pcall(V3, item.x + 1, item.y - 1, 99)
        if ok_sp then pcall(write, gui, item.text, FONT, item.size, FONT, shadow_pos,
                            colour({ 200, 0, 0, 0 })) end
      end
      local ok_p, pos = pcall(V3, item.x, item.y, 100)
      if ok_p then pcall(write, gui, item.text, FONT, item.size, FONT, pos, colour(item.c)) end
    end
  end
  ui.signature = key
end

-- On the menu: drag by the title bar, right-click it for the default place,
-- [-] / [+] at its right end folds and unfolds the window (v0.20.0).
local function handle_mouse()
  local g = ui.geometry
  if g == nil then return end
  local mx, my = cursor()
  if ui.moving ~= nil then
    if mx ~= nil and mouse_held("left") then
      local m = ui.moving
      ui.place = { x = math.floor(m.px + (mx - m.mx) / g.s + 0.5),
                   top = math.floor(m.ptop + (my - m.my) / g.s + 0.5) }
      local w_ref, h_ref = g.width / g.s, g.height / g.s
      ui.place.x = math.max(0, math.min(w_ref - WIN_W, ui.place.x))
      ui.place.top = math.max(HEADER, math.min(h_ref, ui.place.top))
      ui.dirty = true
    else
      ui.moving = nil
      save_place()
      say(string.format("window moved to %d,%d", ui.place.x, ui.place.top))
    end
    return
  end
  if mx == nil then return end
  local inside = mx >= g.x and mx <= g.x + g.w
  local on_title = inside and my <= g.top and my >= g.top - HEADER * g.s
  if not on_title then
    if inside and ui.rows ~= nil and mouse_clicked("left") then
      for _, row in ipairs(ui.rows) do
        if my >= row.bottom and my <= row.top then
          if row.key == ui.sort_key then
            -- The header is "%-28s %8s %9s" in the debug font, 7.5 px a
            -- character at 1080p (15 px at size 32, 3840x2160): "ms/s" ends
            -- at character 37, "worst" starts at 38.
            local column = (mx - (g.x + PAD * g.s)) / (TEXT_SIZE * g.s * 15 / 32)
            local worst = column >= 37
            if worst ~= (ui.sort_worst == true) then
              ui.sort_worst = worst
              ui.dirty = true
              save_place()
              say(worst and "table sorted by worst frame" or "table sorted by ms/s")
            end
          elseif row.key == SWITCH then
            ui.panel = not ui.panel
            ui.dirty = true
            save_place()
            say(ui.panel and "panel on in missions (menu switch)" or "panel off in missions (menu switch)")
          elseif row.key == ALERTS then
            ui.alerts_off = not ui.alerts_off
            ui.dirty = true
            save_place()
            say(ui.alerts_off and "alerts off in missions (menu switch)" or "alerts on in missions (menu switch)")
          elseif row.key == "\0mod list" then
            pcall(installed.export_mod_list, now())
          else
            pcall(export_report, row.key, now())
          end
          break
        end
      end
    end
    return
  end
  if mouse_clicked("left") and ui.button ~= nil and mx >= ui.button then
    ui.folded = not ui.folded
    ui.dirty = true
    save_place()
    say(ui.folded and "window folded" or "window unfolded")
  elseif mouse_clicked("left") then
    ui.moving = { mx = mx, my = my, px = ui.place.x, ptop = ui.place.top }
  elseif mouse_clicked("right") then
    ui.place = { x = DEFAULT_X, top = DEFAULT_TOP }
    save_place()
    ui.dirty = true
    say("window back to its default place")
  end
end

local function display(at)
  -- v0.44.0: the screen part split ("key", "menu", "draw"; the rest stays
  -- "screen"): in game it stayed at ~0.8 ms/s with the menu read every
  -- third frame (v0.43.0), so the reads were not what cost.
  local lap, mark = installed.lap, timer_now()
  rehook_alert(at)
  -- The last session's crash, once, on the ship (v0.15.0; the user chose the
  -- log and one line on the next launch). On the ship = 20 s after the first
  -- frame and the main world unchanged for 10 s (likely: the launch loads
  -- straight to the ship; the log's "last crash shown" line says when it
  -- came, to check in game).
  local note = ui.crash_note
  if note ~= nil and ui.first_tick ~= nil and at - ui.first_tick >= 20 and
     (not units.installed or (units.world ~= nil and units.candidate == nil and
                              at - (units.world_since or at) >= 10)) then
    local text = note.startup and ("LAST CRASH: the game closed while " .. short_name(note.key) .. " was loading")
                 or note.native and ("LAST CRASH: the game crashed while " .. short_name(note.key) .. " was running")
                 or string.sub(note.key, 1, 1) == "(" and "LAST CRASH: a Lua error outside every mod"
                 or ("LAST CRASH: " .. (note.name or short_name(note.key)) .. " raised a Lua error")
    if ui.alert({ text = text, until_at = at + 12, colour = AMBER, keep = true, always = true }) then
      ui.crash_note = nil
      say("last crash shown: " .. text)
    end
  end
  mark = lap("screen", mark)
  if key_pressed() then
    ui.panel = not ui.panel
    ui.dirty = true
    save_place()
    say(ui.panel and "panel opened" or "panel closed")
  end
  mark = lap("key", mark)
  if toast ~= nil and at >= toast.until_at then
    toast = nil
    ui.dirty = true
  end
  local in_menu = menu_check()
  if in_menu ~= ui.in_menu then
    ui.in_menu = in_menu
    ui.dirty = true
    if not in_menu and ui.moving ~= nil then
      ui.moving = nil
      save_place()
    end
  end
  if in_menu then handle_mouse() end
  mark = lap("menu", mark)
  if not (in_menu or ui.panel or (toast ~= nil and (not ui.alerts_off or toast.always))) then
    if ui.gui ~= nil then drop_gui() end
    ui.dirty = false
    lap("screen", mark)
    return
  end
  if ui.dirty or at >= ui.next_refresh then
    ui.dirty = false
    ui.next_refresh = at + REFRESH_S
    draw(items(at))
  end
  lap("draw", mark)
end

-- ------------------------------------------------------------------ tick

local last_tick_time = nil
local pending = nil
local hitch_lines = 0
local last_heap = nil
local last_change_note = nil

local function heap_kb()
  if type(collect) ~= "function" then return nil end
  local ok, value = pcall(collect, "count")
  if ok and type(value) == "number" then return value end
  return nil
end

-- A row name the debug font can draw: Latin text of at most 22 characters;
-- anything else falls back to the record's id ("arsenal:<uuid>" shortened).
local function mdl_label(record)
  local info = rawget(record, "info")
  local name = type(info) == "table" and rawget(info, "name") or nil
  local id = tostring(rawget(record, "id") or "?")
  -- A legacy script's info.name is its id, "arsenal:<uuid>": the mod
  -- manager's name for that uuid instead (v0.19.1).
  if type(name) ~= "string" or name == "" or name == id or string.find(name, "[^\32-\126]") then
    local uuid = string.match(id, "^arsenal:([%x%-]+)$")
    local named = uuid and type(installed.mdl_names) == "table" and installed.mdl_names[string.lower(uuid)] or nil
    name = named or (string.gsub(id, "^(arsenal:%x%x%x%x%x%x%x%x).*$", "%1"))
  end
  name = string.gsub(name, "/", "-")
  if #name > 22 then name = string.sub(name, 1, 22) end
  return name
end

local function read_mdl()
  local mdl = rawget(_G, "MDL")
  if type(mdl) ~= "table" or rawget(mdl, "perf") ~= 1 then return nil end
  local manager = rawget(mdl, "manager")
  local records = type(manager) == "table" and rawget(manager, "mods") or nil
  if type(records) ~= "table" then return nil end
  local out = {}
  for _, record in ipairs(records) do
    if type(record) == "table" then
      local perf = rawget(record, "perf")
      local last = type(perf) == "table" and rawget(perf, "last") or nil
      if type(last) == "number" and last > 0 then
        out[#out + 1] = { key = "mdl: " .. mdl_label(record), own = last }
      end
    end
  end
  return out
end

local mdl_last_reading = nil

-- The scripts' share of the frame the chain view is of: a runtime link
-- below this module finished inside the current frame, so its view is the
-- reading taken one tick ago; above (or on top), the reading now.
local function add_mdl(frame_selfs)
  local now_reading = read_mdl()
  local reading = now_reading
  if runtime_index ~= nil and our_index ~= nil and runtime_index > our_index then
    reading = mdl_last_reading
  end
  mdl_last_reading = now_reading
  if frame_selfs == nil or reading == nil or runtime_index == nil then return end
  local runtime = frame_selfs[runtime_index]
  local sum = 0
  for k, script in ipairs(reading) do
    sum = sum + script.own
    frame_selfs[-k] = { link = { source = script.key }, own = script.own, incl = script.own }
  end
  if runtime ~= nil then runtime.own = math.max(0, runtime.own - sum) end
end

local function ranked(frame_selfs)
  local sorted, explained = {}, 0
  for index, entry in pairs(frame_selfs) do
    sorted[#sorted + 1] = { index = index, entry = entry }
    explained = explained + entry.own
  end
  table.sort(sorted, function(a, b) return a.entry.own > b.entry.own end)
  return sorted, explained
end

local function report(hitch, frame_selfs)
  local sorted, explained = {}, 0
  if frame_selfs ~= nil then sorted, explained = ranked(frame_selfs) end
  -- v0.35.0: the render parts of this frame join the ranking (see "render").
  if hitch.render ~= nil then
    for k, part in ipairs(hitch.render) do
      sorted[#sorted + 1] = { index = -300 - k, entry = part }
      explained = explained + part.own
    end
    table.sort(sorted, function(a, b) return a.entry.own > b.entry.own end)
  end

  if hitch.interval * 1000 >= TOAST_MS then
    local first = sorted[1]
    local at = now()
    if hitch.jit_flush then
      -- v0.31.0: the loader saw LuaJIT flush its code cache in this frame or
      -- the second before; every mod runs uncompiled until it is compiled
      -- again. Not charged to the mod that happened to be running.
      last_stall = { ms = hitch.interval, cause = "a LuaJIT cache flush", at = at }
      ui.alert({ text = string.format("LAG %s ms - LuaJIT cache flush", ms(hitch.interval)),
                 until_at = at + TOAST_S })
    elseif first ~= nil and first.entry.own >= hitch.interval * TOAST_SHARE then
      local who = short_name(owner(first.entry.link))
      last_stall = { ms = hitch.interval, who = who, at = at }
      local key = owner(first.entry.link)
      session.stalls = session.stalls or {}
      local caused = session.stalls[key]
      if caused == nil then
        caused = { count = 0, top = {} }
        session.stalls[key] = caused
      end
      caused.count = caused.count + 1
      caused.top[#caused.top + 1] = hitch.interval
      table.sort(caused.top, function(a, b) return a > b end)
      while #caused.top > 3 do table.remove(caused.top) end
      ui.alert({ text = string.format("LAG %s ms - %s", ms(hitch.interval), who),
                 until_at = at + TOAST_S })
    else
      last_stall = { ms = hitch.interval, who = nil, at = at }
    end
  end

  if hitch_lines >= HITCH_LINES then return end
  hitch_lines = hitch_lines + 1
  local parts = {}
  for k = 1, math.min(3, #sorted) do
    local s = sorted[k]
    parts[#parts + 1] = owner(s.entry.link) .. (s.entry.link.render and " (render)" or "") .. " " .. ms(s.entry.own)
  end
  local heap = ""
  if hitch.heap ~= nil then
    heap = string.format(" heap %.0f KB", hitch.heap)
    if hitch.heap_drop ~= nil and hitch.heap_drop > 0 then
      heap = heap .. string.format(" (GC freed %.0f KB)", hitch.heap_drop)
    end
  end
  local body
  if frame_selfs == nil then
    body = "chain not mapped yet"
  else
    local mine = hitch.mine or 0
    local unmeasured_mine = (our_index == 1) and mine or 0
    body = table.concat(parts, ", ") ..
           string.format("; this module %s ms; not explained %s ms (top %s, outside update)",
                         ms(mine), ms(math.max(0, hitch.interval - explained - unmeasured_mine)),
                         links[1].source)
  end
  if frame_selfs ~= nil and installed.gcw.note ~= nil
     and installed.gcw.note_frame == installed.frame_id - 1 then
    body = body .. "; " .. installed.gcw.note    -- v0.21.0, the GC probe
  end
  if hitch.jit_flush then
    body = body .. "; LuaJIT code cache flushed in this frame or the second before"
  end
  say(string.format("hitch %s ms (dt %s, next %s ms)%s: %s", ms(hitch.interval),
                    hitch.dt and ms(hitch.dt) or "?", frame_dt and ms(frame_dt) or "?",
                    heap, body))
  if hitch_lines == HITCH_LINES then say("-- hitch lines spent; summaries keep counting") end
end

-- failed: a Lua error cut this frame short (v0.15.0). Its tick still runs
-- once, at its end, so Home, clicks and the window work whatever raises
-- (review [2]: v0.13.4's tick owed to the next frame ran twice there). The
-- walk does not count the frame (its spies below the error saw no call);
-- the time of each link that ran is charged as usual, and a link that did
-- not run costs nothing (settled_incl, v0.16.1; v0.15.0-v0.16.0 charged
-- nothing at all in such a frame -- review [1], [4], [6], [16]).
-- v0.42.0: this module's own time split by part, for the minute line
-- ("this module: ... ms/s; parts: ..."): the user found ~5 ms/s on the ship
-- and ~11 in a mission a bit much for a basic tool, and offline (no game GUI,
-- units or video memory) it is ~0.5. One timer reading a part.
installed.own_parts = {}
installed.lap = function(part, mark)
  local t = timer_now()
  local parts = installed.own_parts
  parts[part] = (parts[part] or 0) + (t - mark)
  return t
end

local function tick(failed)
  local at = now()
  local lap, mark = installed.lap, timer_now()
  if installed.rt ~= nil then pcall(installed.render_tick) end
  mark = lap("render", mark)
  if window.started == nil then
    window.started = at
    ui.first_tick = ui.first_tick or at
    pcall(note_deploy)
  end
  window.last_at = at
  roll(at)
  if at - flushed_at >= FLUSH_S then flush_log() end

  -- A walk that raises is undone and waits for the next chain change,
  -- rather than failing every frame half-built (v0.12.7).
  local function walk(fn, arg)
    local ok, err = pcall(fn, arg)
    if not ok then
      pcall(restore_all)
      say("chain walk failed, stopped until the chain changes: " .. tostring(err))
    end
  end
  local top = rawget(_G, "update")
  if top ~= installed.last_top then
    installed.last_top, installed.top_changed_at = top, at
    pcall(installed.churn_note, top, at)
  end
  pcall(installed.churn_tick, at)
  if top ~= mapped_top then
    -- A stall seen last tick is reported now, on the chain it happened in:
    -- its links still hold that frame's times (v0.12.7; it used to be
    -- dropped, no line, no count).
    if pending ~= nil then
      local hitch = pending
      pending = nil                       -- a raise below must not repeat it every tick
      local ok_report, err = pcall(function()
        local old = mapping == nil and #links > 0 and installed.settling <= 0
        local frame_selfs = hitch.mapped and old and selfs() or nil
        add_mdl(frame_selfs)              -- a stall in an MDL script goes to the script (review [12])
        report(hitch, frame_selfs)
      end)
      if not ok_report then say("stall report failed: " .. tostring(err)) end
    end
    local restacked = false
    do
      local ok_r, done = pcall(installed.restack, top)
      restacked = ok_r and done == true
    end
    if not restacked and not installed.churn_busy(at) then
      if mapped_top ~= nil and (last_change_note == nil or at - last_change_note > 10) then
        last_change_note = at
        say("update chain changed; mapping again")
      end
      walk(start_mapping, top)
    end
  elseif mapping ~= nil and not failed then
    walk(step_mapping)
  end
  mark = lap("chain", mark)

  local heap = heap_kb()
  pcall(installed.jit_watch, at)
  local mapped = mapping == nil and #links > 0
  local frame_selfs = nil
  if mapped then
    if installed.settling > 0 then
      installed.settling = installed.settling - 1
    else
      frame_selfs = selfs()
    end
  end
  mark = lap("times", mark)
  do
    local every = installed.gc_every
    local sampled = installed.frame_id % every == 0
    local long = last_tick_time ~= nil and (at - last_tick_time) * 1000 >= HITCH_MS
    local ok, err = true, nil
    if sampled or long then ok, err = pcall(installed.gc_frame, frame_selfs, sampled and every or 0) end
    if ok then ok, err = pcall(installed.gc_tick) end
    if not ok then
      installed.gcp = nil
      installed.gc_why = "failed: " .. tostring(err)
      say("gc: probe failed, off for this session: " .. tostring(err))
    end
  end
  mark = lap("gc", mark)
  add_mdl(frame_selfs)

  if pending ~= nil then
    report(pending, pending.mapped and mapped and frame_selfs or nil)
    pending = nil
  end
  if frame_selfs ~= nil then charge(frame_selfs) end
  -- v0.32.0: which mod sat on top (not measured) in this second. v0.36.0:
  -- not when a different hook of the same mod is timed further down. Super
  -- Holo Kit's escape-menu tab sits on top for the rest of the game while its
  -- tick is timed as usual; its row went missing from the table (every second
  -- left out, none left). HD2 HUD+ 0.2.2 puts a copy of the same hook on top
  -- (same line) and the one below passes through idle: still left out.
  if mapped and live.bucket ~= nil and links[1] ~= nil and links[1].fn ~= installed.wrapper then
    -- v0.43.0: worked out once per top hook (source and line) and chain
    -- length, not every frame. No reference to the link itself is kept: the
    -- memory walk would reach a mod that has left through it.
    local timed_below = false
    local top_link = links[1]
    if installed.tops_src == top_link.source and installed.tops_line == top_link.line
       and installed.tops_n == #links then
      timed_below = installed.tops_below
    else
      for k = 2, #links do
        if links[k].source == links[1].source and links[k].line ~= links[1].line then
          timed_below = true
          break
        end
      end
      installed.tops_src, installed.tops_line = top_link.source, top_link.line
      installed.tops_n, installed.tops_below = #links, timed_below
    end
    if not timed_below then
      local tops = live.bucket.tops
      if tops == nil then
        tops = {}
        live.bucket.tops = tops
      end
      tops[owner(links[1])] = true
    end
  end
  -- v0.33.0: and for the black box, the mod on top that no shim times.
  if installed.box ~= nil then
    local top = links[1]
    installed.box[7] = (mapped and top ~= nil and top.fn ~= installed.wrapper) and installed.box_id(top.source) or 0
  end

  if last_tick_time ~= nil then
    local interval = at - last_tick_time
    window.frames = window.frames + 1
    live.bucket.frames = live.bucket.frames + 1
    live.bucket.time = live.bucket.time + interval
    if interval * 1000 >= HITCH_MS then
      session.stalls50 = session.stalls50 + 1
      if interval >= 0.2 then session.stalls200 = session.stalls200 + 1 end
      window.hitches = window.hitches + 1
      live.bucket.stalls = live.bucket.stalls + 1
      local drop = (last_heap ~= nil and heap ~= nil) and (last_heap - heap) or nil
      -- The tick that ended the last frame lies inside this interval: its
      -- cost is this module's own share (unmeasured when it is the top link).
      pending = { interval = interval, dt = frame_dt, heap = heap, heap_drop = drop,
                  jit_flush = installed.jit_flush_at ~= nil and at - installed.jit_flush_at <= 1.0,
                  mapped = mapped, mine = installed.tick_cost or 0,
                  render = installed.rt ~= nil and installed.render_parts() or nil }
    end
  end
  last_tick_time = at
  last_heap = heap
  mark = lap("times", mark)

  do
    local ok, err = pcall(units.tick, at)
    if not ok and not units.failed then
      units.failed = true
      say("units: check failed: " .. tostring(err))
    end
  end
  mark = lap("units", mark)
  if mapping == nil and #links > 0 then
    local ok, err = pcall(mem_step, at)
    if not ok then
      mem.failed, mem.job = true, nil
      say("memory: walk failed, off for this session: " .. tostring(err))
    end
  end
  mark = lap("memory", mark)

  do
    local ok, err = pcall(gpu.tick, at)
    if not ok and not gpu.failed then
      gpu.failed, gpu.read = true, nil
      say("vram: read failed, off for this session: " .. tostring(err))
    end
  end
  mark = lap("vram", mark)
  if at - window.started >= SUMMARY_S then write_summary(at) end
  lap("log", mark)
  display(at)
end

-- ------------------------------------------------------------ update hook

local function clock()
  if App == nil or type(rawget(App, "time_since_launch")) ~= "function" then
    return nil
  end
  local ok, value = pcall(rawget(App, "time_since_launch"))
  if ok and type(value) == "number" then return value end
  return nil
end

-- Out of the chain = no tick for 0.5 s AND for STALE_CALLS main_world calls.
-- Time alone is not enough: v0.2.0 in game (2026-09-29 10:36) took a single
-- 590 ms frame, then a 1389 ms one, for having fallen out, re-armed above
-- Speed Dial, which did the same for the same reason -- generations 3, 4
-- and 5 in 12 s, the chain 33 -> 35 -> 37 links, the two of them alternating
-- on top (hd2-update-chain-escalation). One long frame has only a few
-- main_world calls in it; a chain the game replaced goes on calling
-- main_world frame after frame without us. Likely: 200 calls is at least
-- 100 frames at the engine's rate in the fake (2 a frame); the game's rate
-- is not measured, so the re-arm after a world change may take longer.
-- v0.16.2: and 3 s with no tick is enough on its own. The game never calls
-- main_world, only mods do (proven twice: BSL + SmoothBoot + Watchdog made
-- no calls, 09-30; BSL + Helmet Headlamp made none, 10-01 --
-- hd2-game-never-calls-main-world), so with few callers 200 calls took
-- 35 s at one call per 10 frames and 208 s at one a second, the Watchdog
-- dead all that while. Helmet Headlamp 1.2.1 measured the cost of the cap:
-- stalls of 0.6-2.5 s add no hook, 3.5-8 s add one, which then stays on
-- top. Here two guards keep long frames from re-arming us at all: inside
-- our own frame (installed.depth > 0) a link below is just slow -- in game
-- single mods held a frame 5-7 s (Casemate Turrets 6.7 s, WMS 6.3 s, Super
-- Beacon 5.1 s); and a long gap between frames (8-32 s in the log, outside
-- update) is followed by at most a call or two from a mod above us before
-- we are entered again, so the cap also wants 3 calls. Likely, measured in
-- the fake (test_mod_lag_finder_rearm_runtime.py), not yet in game.
-- (No new local: the main chunk is at Lua's 200-locals limit.)
local STALE_S, STALE_CALLS = 0.5, 200

local function update_is_live()
  if type(installed.wrapper) ~= "function" then return false end
  local at, seen = clock(), installed.last_tick_at
  if at == nil or type(seen) ~= "number" then
    return rawget(_G, "update") == installed.wrapper
  end
  if (at - seen) <= STALE_S then return true end
  if (installed.depth or 0) > 0 and (at - seen) < 60 then return true end
  local calls = installed.mw_calls - (installed.tick_calls or 0)
  if (at - seen) >= 3.0 and calls >= 3 then return false end
  return calls < STALE_CALLS
end

local function arm()
  installed.rearmed = false
  local current = rawget(_G, "update")
  if type(current) == "function" and current ~= installed.wrapper and
     not update_is_live() then
    local previous_update = current
    installed.generation = installed.generation + 1
    local generation = installed.generation
    -- "errors" (v0.15.0). A Lua error that reaches the engine from update
    -- closes the game (proven 2026-10-01: Lua Error Probe v1, one error()
    -- from the top of _G.update on the ship; a ~0.5 s hitch, then the game
    -- was gone; crash dump 0xC0000005 at lua51.dll+0x4a050 with the message
    -- in its heap). The release game writes no log a player can read, so
    -- nobody can tell which mod it was. The frame below runs under xpcall:
    -- before the stack unwinds, the handler finds the mod, logs it with the
    -- message, flushes the log and writes mod_lag_finder_crash.txt; the
    -- error then goes on to the game unchanged (error(err, 0)), and the game
    -- closes exactly as it would without this module (the user, 2026-10-01:
    -- pass it on, do not catch it). The next launch reads that file, logs it
    -- and shows "LAST CRASH: <name> raised a Lua error" once. When the next
    -- frame comes after all, a mod above us caught the error: the file is
    -- emptied, that mod's errors are only counted from then on (the v0.14.0
    -- log line, ERROR window line and one alert in missions).
    --
    -- Which mod: the position at the start of the message when it is a
    -- mods/ script (what error() and the runtime put there; it survives a
    -- mod that catches and re-raises with level 0), else the first mods/
    -- function on the stack between the raise and this wrapper. Neither =
    -- "(game script <name>)", or "(the game)" when no script is on it
    -- either (review [18]: v0.14.0 put a mod's error in a function the game
    -- calls on the game).
    --
    -- v0.16.0: every timing shim runs its link under xpcall too (see
    -- make_shim), so an error is noted at the shim nearest to it, whole, even
    -- when a mod between that link and this wrapper catches it (Lua Error
    -- Probe v2 in game, 2026-10-01: Speed Dial's pcall dropped it and nothing
    -- was logged). Each shim on the way up sees the same error again: it is
    -- noted once. A frame where one was raised charges nothing, as a frame
    -- cut short. The first error of each mod is logged with its full stack:
    -- the game and the mods above now see a stack that starts here, and this
    -- log is where the rest of it is kept (the user, 2026-10-01).
    local wrapper, on_error
    local own_source = source_of(arm)
    local function key_of(source)
      source = tostring(source or "?")
      local first = string.sub(source, 1, 1)
      if first == "@" or first == "=" then source = string.sub(source, 2) end
      return (string.gsub(source, "%.lua$", ""))
    end
    -- The mod, and the stack from the raise when that mod has not been logged
    -- yet. A message seen before goes by its first answer (no walk).
    local function culprit(err)
      local key = nil
      if type(err) == "string" then
        key = installed.culprit_cache[err]
        if key ~= nil then return key, nil end
        local chunk = string.match(err, "^([^:\n]+):%d+:")
        if chunk ~= nil then
          chunk = key_of(chunk)
          if is_mod_source(chunk) and chunk ~= own_source then key = chunk end
        end
      end
      -- The stack from the raise outward: the frames above the handler
      -- (this function, its pcall) are skipped; the raise path ends at the
      -- first frame of ours (the shim the link ran in, or our wrapper).
      local game, found, start = nil, nil, nil
      for level = 1, 120 do
        local info = getinfo(level, "Sf")
        if type(info) ~= "table" or info.func == wrapper then break end
        if start == nil then
          if info.func == on_error or info.func == installed.link_handler then start = level + 1 end
        elseif info.what ~= "C" then
          local source = key_of(info.source)
          if source == own_source then break end
          if is_mod_source(source) then
            found = found or source
          else
            game = game or source
          end
        end
      end
      key = key or found or (game and ("(game script " .. game .. ")")) or "(the game)"
      if type(err) == "string" and installed.culprit_cached < 64 then
        installed.culprit_cache[err] = key
        installed.culprit_cached = installed.culprit_cached + 1
      end
      local trace = nil
      local traceback = rawget(dbg, "traceback")
      if start ~= nil and not installed.error_logged[key] and type(traceback) == "function" then
        trace = traceback("", start)
      end
      return key, trace
    end
    local function write_crash(text)
      if installed.crash_path == nil then return end
      local file = io.open(installed.crash_path, "w")
      if file == nil then return end
      file:write(text)
      file:close()
    end
    local function note_error(err)
      if installed.last_err ~= nil and rawequal(installed.last_err, err) then return end
      installed.last_err = err
      installed.frame_failed = true
      local key, trace = culprit(err)
      local text = string.gsub(string.sub(tostring(err), 1, 300), "[%c]+", " ")
      installed.errors[key] = (installed.errors[key] or 0) + 1
      installed.errors_session[key] = (installed.errors_session[key] or 0) + 1
      if live.bucket ~= nil then
        live.bucket.errors = live.bucket.errors or {}
        live.bucket.errors[key] = (live.bucket.errors[key] or 0) + 1
      end
      if not installed.error_logged[key] then
        installed.error_logged[key] = true
        say("error: " .. key .. " raised a Lua error: " .. text)
        if trace ~= nil then
          local shown = 0
          for line in string.gmatch(trace, "[^\n]+") do
            if not string.find(line, "^stack traceback") then
              shown = shown + 1
              if shown > 24 then
                say("    ...")
                break
              end
              say("    " .. string.gsub(line, "^%s+", ""))
            end
          end
        end
      end
      if not installed.survives[key] then
        -- On disk before the error goes on: the game may be about to close.
        -- The name is kept as the mod manager shows it now: the player may
        -- have removed the mod by the next launch (v0.16.0).
        installed.crash_pending = key
        write_crash(string.format("date=%s%skey=%s%sname=%s%smessage=%s%s", local_time(os.time()), NL,
                                  key, NL, short_name(key), NL, text, NL))
        say("error: passed on to the game, which closes on it unless another mod catches it")
        flush_log()
      end
      if installed.errors[key] >= ERROR_ALERT_FRAMES and not installed.error_told[key] and
         ui.alert({ text = string.format("ERROR %s keeps raising Lua errors", short_name(key)),
                    until_at = now() + 8, colour = AMBER, keep = true }) then
        installed.error_told[key] = true
        say("errors: " .. key .. " keeps raising Lua errors")
      end
    end
    on_error = function(err)
      pcall(note_error, err)
      return err
    end
    installed.note = note_error
    -- The game lived through the error after all: a mod above caught it.
    local function survived()
      local key = installed.crash_pending
      installed.crash_pending = nil
      installed.survives[key] = true
      write_crash("")
      say("error: the game went on after " .. key .. "'s error (another mod caught it); counted from now on")
    end
    installed.clear_crash = function()
      if installed.crash_pending ~= nil then
        installed.crash_pending = nil
        write_crash("")
      end
    end
    local function run_tick(failed)
      local W = installed.box
      local outer = nil
      if W ~= nil then
        outer, W[3] = W[3], installed.box_self or 2
        if installed.box_thread ~= nil then W[6] = installed.box_thread() end
      end
      local started = now()
      local ok_tick, err = pcall(tick, failed)
      installed.tick_cost = now() - started
      -- v0.24.0: this module's own time, for the summary.
      installed.own_time = (installed.own_time or 0) + installed.tick_cost
      if installed.tick_cost > (installed.own_worst or 0) then installed.own_worst = installed.tick_cost end
      if not ok_tick and not installed.told_tick then
        installed.told_tick = true
        say("tick error: " .. tostring(err))
      end
      if W ~= nil then W[3] = outer end
    end
    local function after(outer, ok, ...)
      local back = timer_now()
      installed.depth = 0
      do
        local called, below = installed.called_at, our_index and links[our_index + 1] or nil
        if called ~= nil then
          -- Only when the link below timed this frame (v0.45.0: while the
          -- chain was still being mapped, the whole chain counted as "call").
          local inside = -1
          if below ~= nil and below.last_frame == installed.frame_id then inside = back - called - below.last_incl end
          if inside > 0 then
            local parts = installed.own_parts
            parts.call = (parts.call or 0) + inside
          end
        end
      end
      if installed.box ~= nil then installed.box[3] = outer end
      local ticked = installed.generation == generation
      if ticked then run_tick(not ok or installed.frame_failed) end
      if installed.gcp ~= nil then pcall(installed.gc_frame_out) end
      installed.lap("after", back + (ticked and installed.tick_cost or 0))
      if ok then return ... end
      error((...), 0)
    end
    -- xpcall passes the arguments on in LuaJIT (the game's VM); a VM whose
    -- xpcall does not gets them through a closure.
    if installed.xpcall_args == nil then
      local ok_args, got = xpcall(function(a) return a end, function(e) return e end, 1)
      installed.xpcall_args = ok_args and got == 1
    end
    local unpack_fn = rawget(_G, "unpack")
    wrapper = function(...)
      -- A mod below that calls _G.update again inside the frame (a substep)
      -- comes back here: passed on as it is (review [7]).
      if installed.depth > 0 or installed.generation ~= generation then
        return previous_update(...)
      end
      local entered = timer_now()
      frame_dt = (...)
      frame_argc = select("#", ...)
      if installed.crash_pending ~= nil then pcall(survived) end
      installed.last_err, installed.frame_failed = nil, false
      installed.frame_id = installed.frame_id + 1
      installed.last_tick_at = clock()
      installed.tick_calls = installed.mw_calls
      installed.depth = 1
      -- v0.33.0: in the update, in no timed mod until a shim says which.
      local W, outer = installed.box, nil
      if W ~= nil then
        outer, W[3] = W[3], 2
        W[4] = installed.frame_id % 4294967296
      end
      if installed.gcp ~= nil then pcall(installed.gc_frame_in) end
      -- v0.44.0: this module's time outside its tick (log only), in three
      -- parts: "before" the chain, the "call" into it (the frame's time in
      -- the chain less what the link below us measured: the xpcall and the
      -- shim's own work), and "after" it, less the tick (own_time).
      installed.called_at = installed.lap("before", entered)
      if installed.xpcall_args then
        return after(outer, xpcall(previous_update, on_error, ...))
      end
      local n, args = select("#", ...), { ... }
      return after(outer, xpcall(function() return previous_update(unpack_fn(args, 1, n)) end, on_error))
    end
    -- The slot our own previous lives in, found by name in our own closure.
    installed.previous_slot = nil
    for index = 1, 255 do
      local name, value = getupvalue(wrapper, index)
      if name == nil then break end
      if name == "previous_update" then
        local target = through_ours(value)
        if target ~= value then setupvalue(wrapper, index, target) end
        installed.previous_slot = { kind = "uv", holder = wrapper, key = index,
                                    name = name, original = target }
      end
    end
    installed.wrapper = wrapper
    installed.last_tick_at = clock()
    installed.rearmed = true
    -- The time spent out of the chain is no frame (v0.12.7: the first tick
    -- after a re-arm counted the whole gap as a stall), and not part of the
    -- window either (v0.13.3, review [4]: its span covered the gap, so every
    -- mod's ms/s read low -- about half after a 30 s gap).
    last_tick_time, pending = nil, nil
    installed.depth = 0
    if installed.generation > 1 then
      live.bucket, live.ring = nil, {}
      -- The minute so far goes into the log and the session first (review
      -- [5]: it was dropped, with its error counts). With no tick yet the
      -- window stays unstarted, so the first tick still notes the deploy
      -- (review [20]).
      if window.started ~= nil then
        if window.last_at ~= nil then write_summary(window.last_at) end
        window = { mods = {}, started = now(), frames = 0, hitches = 0 }
      end
    end
    rawset(_G, "update", wrapper)
    -- v0.34.0: the render chain, once (see "render").
    if not installed.render_tried then
      installed.render_tried = true
      local ok_render, told = pcall(installed.render_setup)
      if not ok_render or told ~= nil then
        say("render: " .. (ok_render and tostring(told) or ("failed: " .. tostring(told))))
      end
    end
    say("update armed generation=" .. installed.generation)
  end
  local current_shutdown = rawget(_G, "shutdown")
  -- Wrapped once a session (v0.12.7: every re-arm stacked another wrapper
  -- when a mod had wrapped shutdown over ours, and the summary ran k+1
  -- times at exit); the flag keeps any copy from doing it twice.
  if type(current_shutdown) == "function" and installed.shutdown_wrapper == nil then
    local previous_shutdown = current_shutdown
    -- v0.33.0: the black box says closing, then closed once the game's own
    -- shutdown (and every mod's) has returned.
    local function closed(...)
      if installed.box ~= nil then installed.box[2] = 2 end
      return ...
    end
    local wrapper = function(...)
      if installed.shutdown_done then return previous_shutdown(...) end
      installed.shutdown_done = true
      if installed.box ~= nil then installed.box[2] = 3 end
      pcall(function()
        if installed.clear_crash then installed.clear_crash() end
        write_summary(now())
        if installed.data_write_live ~= nil then
          local ok_data, err = pcall(installed.data_write_live, now())
          if not ok_data then say("data file: failed: " .. tostring(err)) end
        end
        say(session_line("game over"))
        say("shutdown")
        flush_log()
      end)
      return closed(previous_shutdown(...))
    end
    installed.shutdown_wrapper = wrapper
    rawset(_G, "shutdown", wrapper)
  end
end

-- ------------------------------------------------------------ render

-- v0.34.0 (the user, 2026-10-10). HUD Ballistic Trajectory Overlay (BTO) v9
-- does its trajectory work in _G.render, where no shim timed anything, so its
-- row showed only the 3-5 ms/s of its update part. v0.34.0 timed the render
-- chain as one row. The first game with it showed two mods there, ActionCam
-- and BTO, cut to "render+game: ActionCam, Over" (28 characters), with the
-- game's own render mixed in because BTO hooked render before this module
-- loaded.
--
-- v0.35.0 (the user: all three) maps the render chain link by link, the way
-- the update walk does. Each step:
--   1. Spy on every function the last link holds (upvalues, and functions
--      in tables it holds).
--   2. Let one render call pass.
--   3. The link below is the spy called with the same arguments as render.
--      Where several are (ActionCam pcalls two helpers with no arguments,
--      as render has none), prefer in order: a function that was _G.render
--      at some time, then a name like "previous" or "original_render", then
--      the one called last (both mods end with "return previous(...)").
--   4. The same answer three times gives the link a timing shim, and the
--      next step starts.
-- A link that is not a mod's script is the game's own render: the chain
-- ends there, and it is timed apart in any load order.
-- A link's own time is its time minus the link below. It goes to the mod's
-- own row, so a mod's row is its update and render together. The stall lines
-- show the render part, marked "(render)", when it is 1 ms or more.
-- A hook that comes above ours (ActionCam hooks render from its first update)
-- and holds our top shim becomes the new top, up to 3 times a session, so
-- two hooks that each want the top cannot escalate.
-- While a render hook runs, the black box holds that mod's number; inside
-- the game's own render it holds 0.
installed.render_setup = function()
  if installed.rt ~= nil then return nil end
  local first = rawget(_G, "render")
  if type(first) ~= "function" then return "off (no render function)" end
  local rt = { links = {}, calls = 0, order = 0, argc = 0, rewraps = 0, minute = {},
               state = "mapping", seen = installed.render_seen or {} }
  installed.rt = rt
  rt.seen[first] = true
  local link = installed.render_link(first, nil)
  rt.links[1] = link
  rawset(_G, "render", link.shim)
  installed.render_step(link)
  return "on; mapping the render chain from " .. link.key
end

-- A link of the render chain and the shim that times it (its time includes
-- every link below). The outermost one counts the render calls and, after
-- each, lets the walk take a step.
installed.render_link = function(fn, slot)
  local rt = installed.rt
  local key = source_of(fn)
  local link = { fn = fn, key = key, slot = slot, pending = 0, ran = 0, last_own = 0,
                 game = not is_mod_source(key) }
  local W = installed.box
  local id = W ~= nil and (link.game and 0 or installed.box_id(key)) or 0
  local function done(t0, outer, top, ...)
    link.pending = link.pending + (timer_now() - t0)
    if W ~= nil then W[3] = outer end
    if top then rt.in_render = false end
    if top and rt.step ~= nil then pcall(installed.render_advance) end
    return ...
  end
  link.shim = function(...)
    local top = link == rt.links[1]
    if top then
      rt.calls = rt.calls + 1
      rt.argc, rt.arg1 = select("#", ...), (...)
      rt.in_render = true
    end
    link.ran = rt.calls
    local outer = nil
    if W ~= nil then outer, W[3] = W[3], id end
    return done(timer_now(), outer, top, fn(...))
  end
  ours[link.shim] = fn
  return link
end

-- Spy on everything the link holds, for the next render calls.
installed.render_step = function(link)
  local rt = installed.rt
  rt.step = nil
  if link.game then
    rt.state = string.format("mapped, %d links", #rt.links)
    say("render chain: " .. rt.state .. ", down to the game's own render (" .. link.key .. ")")
    return
  end
  local avoid = {}
  for _, l in ipairs(rt.links) do avoid[l.fn] = true end
  local update = rawget(_G, "update")
  if update ~= nil then avoid[update] = true end
  local slots = upvalue_slots(link.fn, avoid)
  -- v0.36.0: the functions in tables it holds. In a big one only the first
  -- TABLE_FIELDS_MAX were looked at, and Super Holo Kit keeps the render
  -- below in MZ.prev_render among some thousands of fields: there, a former
  -- _G.render and names like prev/orig/render are always taken.
  for index = 1, 255 do
    local name, value = getupvalue(link.fn, index)
    if name == nil then break end
    if type(value) == "table" and not skip_table[value] and getmetatable(value) == nil then
      local plain, count = 0, 0
      for key, field in next, value do
        count = count + 1
        if count > 20000 then break end
        field = through_ours(field)
        if type(key) == "string" and not avoid[field] and is_lua_function(field) then
          local hinted = rt.seen[field] or name_score(key) > 0 or string.find(string.lower(key), "render", 1, true)
          if hinted or plain < TABLE_FIELDS_MAX then
            if not hinted then plain = plain + 1 end
            slots[#slots + 1] = { kind = "field", holder = value, key = key,
                                  name = name .. "." .. key, original = field }
          end
        end
      end
    end
  end
  if #slots == 0 then
    link.bottom = true
    rt.state = "stopped at " .. link.key .. " (it holds no function)"
    say("render chain: " .. rt.state)
    return
  end
  for _, slot in ipairs(slots) do
    local rec, target = { calls = 0, argc = 0, arg = nil, last = 0 }, slot.original
    slot.rec = rec
    slot.spy = function(...)
      if rt.in_render then
        rec.calls = rec.calls + 1
        rec.argc, rec.arg = select("#", ...), (...)
        rt.order = rt.order + 1
        rec.last = rt.order
      end
      return target(...)
    end
    ours[slot.spy] = target
    slot_set(slot, slot.spy)
  end
  rt.step = { link = link, slots = slots, best = nil, streak = 0, misses = 0 }
end

-- After a render call: which spy is the link below?
installed.render_advance = function()
  local rt = installed.rt
  local st = rt.step
  local link = st.link
  local function unspy(keep)
    for _, slot in ipairs(st.slots) do
      if slot ~= keep and slot_get(slot) == slot.spy then slot_set(slot, slot.original) end
    end
  end
  if link.ran ~= rt.calls then
    st.misses = st.misses + 1
  else
    local matches, last = {}, nil
    for _, slot in ipairs(st.slots) do
      local rec = slot.rec
      if rec.calls > 0 and rec.argc == rt.argc and (rt.argc == 0 or rawequal(rec.arg, rt.arg1)) then
        matches[#matches + 1] = slot
        if last == nil or rec.last > last.rec.last then last = slot end
      end
    end
    local best, best_score, tied = nil, -1, false
    for _, slot in ipairs(matches) do
      local score = (rt.seen[slot.original] and 4 or 0) + name_score(slot.name) * 2 + (slot == last and 1 or 0)
      if score > best_score then
        best, best_score, tied = slot, score, false
      elseif score == best_score then
        tied = true
      end
    end
    if tied then best = nil end
    if best ~= nil and best == st.best then
      st.streak = st.streak + 1
    elseif best ~= nil then
      st.best, st.streak = best, 1
    else
      st.misses = st.misses + 1
    end
    if best ~= nil and st.streak >= 3 then
      unspy(best)
      local below = installed.render_link(best.original, best)
      slot_set(best, below.shim)
      rt.links[#rt.links + 1] = below
      say(string.format("render chain: #%d %s calls %s (via %s)", #rt.links - 1, link.key, below.key, best.name))
      installed.render_step(below)
      return
    end
  end
  for _, slot in ipairs(st.slots) do slot.rec.calls = 0 end
  if st.misses >= 120 then
    unspy(nil)
    rt.step = nil
    link.bottom = true
    rt.state = "stopped below " .. link.key .. " (the link below it was not found)"
    say("render chain: " .. rt.state .. "; its time counts everything below it")
  end
end

-- Each tick: each link's own render time since the last tick (the render
-- after the last update), into its mod's row.
installed.render_tick = function()
  local rt = installed.rt
  if rt == nil then return end
  local links = rt.links
  rt.in_render = false                 -- a render call an error cut short
  for index, link in ipairs(links) do
    local below = links[index + 1]
    local own = math.max(0, link.pending - (below ~= nil and below.pending or 0))
    link.last_own = own
    if own > 0 then
      -- While the walk is still under way (a few frames) the last link keeps
      -- its own name; one the walk gave up below counts everything below it.
      local key = link.game and "(the game)" or (link.bottom and (link.key .. " (+ all below)") or link.key)
      link.row_key = key
      charge_row(window.mods, key, own)
      if live.bucket ~= nil then charge_row(live.bucket.mods, key, own) end
      rt.session = rt.session or {}                  -- v0.40.0, for the data file
      rt.session[key] = (rt.session[key] or 0) + own
      local m = rt.minute[key]
      if m == nil then
        m = { time = 0, worst = 0 }
        rt.minute[key] = m
      end
      m.time = m.time + own
      if own > m.worst then m.worst = own end
    end
  end
  for _, link in ipairs(links) do link.pending = 0 end
  -- A hook above ours: when it holds our top shim, it becomes the new top.
  local top = rawget(_G, "render")
  if top ~= links[1].shim and not rt.above_told and type(top) == "function" then
    local holds = false
    for index = 1, 255 do
      local name, value = getupvalue(top, index)
      if name == nil then break end
      if value == links[1].shim then holds = true break end
    end
    if holds and rt.rewraps < 3 then
      rt.rewraps = rt.rewraps + 1
      local link = installed.render_link(top, nil)
      table.insert(links, 1, link)
      rawset(_G, "render", link.shim)
      if string.sub(rt.state, 1, 6) == "mapped" then rt.state = string.format("mapped, %d links", #links) end
      say("render chain: " .. link.key .. " hooked render above this module; timed as the new top")
    else
      rt.above_told = true
      say("render chain: " .. tostring(source_of(top)) .. " hooked render above this module; not timed")
    end
  end
end

-- A stall's render part: the links that took 1 ms or more in it.
installed.render_parts = function()
  local rt = installed.rt
  local parts = nil
  for _, link in ipairs(rt.links) do
    if link.last_own >= 0.001 then
      parts = parts or {}
      parts[#parts + 1] = { own = link.last_own,
                            link = { source = link.row_key or link.key, render = true,
                                     bottom = link.game and "game" or nil } }
    end
  end
  return parts
end

-- The minute's line.
installed.render_summary = function(span)
  local rt = installed.rt
  if rt == nil or span <= 0 then return end
  local rows = {}
  for key, m in pairs(rt.minute) do rows[#rows + 1] = { key = key, m = m } end
  table.sort(rows, function(a, b) return a.m.time > b.m.time end)
  local parts = {}
  for _, r in ipairs(rows) do
    parts[#parts + 1] = string.format("%s %.2f ms/s (worst %.1f ms)", r.key, r.m.time * 1000 / span,
                                      r.m.worst * 1000)
  end
  say("  render: " .. (#parts > 0 and table.concat(parts, ", ") or "nothing") .. "; " .. rt.state)
  rt.minute = {}
end

-- ------------------------------------------------------------ build id

-- v0.39.0 (the user, 2026-10-13, before opening the source: a copy someone
-- changed and passed on must not be taken for this one). A fingerprint of
-- the code that is actually running: the game's own LuaJIT dumps this
-- chunk's bytecode without debug information (so the chunk name and the
-- loader do not matter), and two 32-bit running sums over its bytes make
-- 12 hex digits. Any change to the code changes it; the official builds'
-- ids are listed with each release. It is in the log, the copied report and
-- the mod list. It proves nothing against someone who fakes the line on
-- purpose, only against an honest changed copy. One pass at load, a few ms.
installed.build_id = function()
  if installed.build ~= nil then return installed.build end
  installed.build = "unknown"
  local dump, fn = rawget(string, "dump"), installed.self_fn
  if type(dump) ~= "function" or type(fn) ~= "function" then return installed.build end
  local ok, code = pcall(dump, fn, true)
  if not ok or type(code) ~= "string" or #code == 0 then return installed.build end
  local a, b, byte, n = 5381, 0, string.byte, #code
  for i = 1, n, 64 do
    local chunk = { byte(code, i, math.min(i + 63, n)) }
    for k = 1, #chunk do
      a = (a * 33 + chunk[k]) % 4294967296
      b = (b * 65599 + chunk[k]) % 4294967296
    end
  end
  installed.build = string.sub(string.format("%08x%08x", a, b), 1, 12)
  return installed.build
end

-- ------------------------------------------------------------ data file

-- v0.40.0 (the user, 2026-10-13: mod managers that want the Watchdog's
-- numbers in their own window should not have to change its code). One
-- documented, read-only JSON file next to the log, mod_lag_watchdog.json
-- (format "mod-lag-watchdog", version 1; DATA_JSON.md has every field).
-- Written whole at two moments only, never in play:
--   * when the game closes: the whole session;
--   * at the next launch, while it loads, when the last session never
--     closed: what the black box kept -- the crash verdict and the numbers
--     of the last minute summary (see "black box": once a minute the 20
--     costliest mods go into the mapped memory, a few stores, no disk).
-- No paths, user names or player names: a mod's folder is its own name only.
installed.data_file = function()
  local DATA_SNAP, SNAP_ROWS, SNAP_WORDS = 7300, 20, 8
  installed.DATA_SNAP = DATA_SNAP
  local function jstr(v)
    v = string.gsub(tostring(v), '[%c"\\]', function(c)
      if c == '"' then return '\\"' elseif c == "\\" then return "\\\\"
      elseif c == "\n" then return "\\n" elseif c == "\r" then return "\\r" elseif c == "\t" then return "\\t" end
      return string.format("\\u%04x", string.byte(c))
    end)
    return '"' .. v .. '"'
  end
  local function jnum(v)
    if type(v) ~= "number" or v ~= v then return "null" end
    if v == math.floor(v) and math.abs(v) < 9007199254740992 then return string.format("%d", v) end
    return (string.gsub(string.format("%.2f", v), "%.?0+$", ""))
  end
  local function jval(v)
    if v == nil then return "null" end
    if type(v) == "boolean" then return v and "true" or "false" end
    if type(v) == "number" then return jnum(v) end
    if type(v) == "table" then return v.json end
    return jstr(v)
  end
  -- An object from ordered pairs, an array from a list; both carry .json.
  -- (Values may be nil: counted with select, not #, which stops at a hole.)
  local function obj(...)
    local n, list, parts = select("#", ...), { ... }, {}
    for k = 1, n, 2 do parts[#parts + 1] = jstr(list[k]) .. ": " .. jval(list[k + 1]) end
    return { json = "{" .. table.concat(parts, ", ") .. "}" }
  end
  -- A record built field by field: push(r, key, value), then done(r).
  local function push(r, key, value)
    r.n = (r.n or 0) + 2
    r[r.n - 1], r[r.n] = key, value
  end
  local function done(r)
    local parts = {}
    for k = 1, r.n or 0, 2 do parts[#parts + 1] = jstr(r[k]) .. ": " .. jval(r[k + 1]) end
    return { json = "{" .. table.concat(parts, ", ") .. "}" }
  end
  local function arr(items)
    local parts = {}
    for _, item in ipairs(items) do parts[#parts + 1] = jval(item) end
    return { json = "[" .. table.concat(parts, ", ") .. "]" }
  end
  local function path()
    if log_path == nil then return nil end
    return (string.gsub(log_path, "mod_lag_finder%.log$", "mod_lag_watchdog.json"))
  end
  local function write(record)
    local file_path = path()
    if file_path == nil then return false end
    local temp = file_path .. ".tmp"
    local file = io.open(temp, "wb")
    if file == nil then return false end
    file:write(record.json, "\n")
    file:close()
    pcall(os.remove, file_path)
    local ok = pcall(os.rename, temp, file_path)
    return ok
  end
  -- The mod manager's entry for a key: its name there and its folder.
  local function manager_of(key)
    if installed.mod_list == nil or type(installed.hash_of) ~= "function" then return nil, false end
    local bare = string.gsub(key, " %(%+ all below it%)$", "")
    local ok, hash = pcall(installed.hash_of, bare)
    if not ok or hash == nil then return nil, false end
    local found = nil
    for _, listed in ipairs(installed.mod_list) do
      if listed.keys[hash] then
        if found ~= nil then return nil, true end      -- two mods ship it
        found = listed
      end
    end
    return found, false
  end
  local function version()
    return (string.match(MARKER, "v([%d%.]+)$") or MARKER)
  end
  local function head(how, started, ended, minutes, fps, stalls50, stalls200)
    local r = {}
    push(r, "format", "mod-lag-watchdog")
    push(r, "version", 1)
    push(r, "watchdog", obj("version", version(), "build", installed.build or "unknown"))
    push(r, "manager", installed.manager)
    push(r, "session", obj("started", started, "ended", ended, "ended_how", how,
                           "minutes_played", minutes, "fps_average", fps,
                           "game_build", native.stamp and string.format("%08X", native.stamp) or nil,
                           "stalls_50ms", stalls50, "stalls_200ms", stalls200))
    return r
  end
  local function mod_obj(row)
    local listed, shared = manager_of(row.key)
    return obj("key", row.key, "name", short_name(row.key),
               "manager_name", listed and listed.label or nil, "folder", listed and listed.folder or nil,
               "ms_per_s", row.mss, "worst_minute_ms_per_s", row.peak, "worst_frame_ms", row.worst,
               "render_ms_per_s", row.render, "stalls_caused", row.stalls, "worst_stall_ms", row.worst_stall,
               "lua_errors", row.errors, "lua_memory_kb", row.memory,
               "helper_units", row.units, "flags", arr(row.flags or {}),
               "shared_script", shared)
  end

  -- The whole session, when the game closes.
  installed.data_write_live = function(at)
    local partial = window.started and math.max(0, at - window.started) or 0
    local seconds = (session.time or 0) + partial
    local frames = (session.frames or 0) + window.frames
    local keys = {}
    for key in pairs(session.mods or {}) do keys[key] = true end
    for key in pairs(window.mods) do keys[key] = true end
    local render = installed.rt ~= nil and installed.rt.session or {}
    local rows = {}
    for key in pairs(keys) do
      local total, now_row = session.mods and session.mods[key] or nil, window.mods[key]
      local time = (total and total.time or 0) + (now_row and now_row.time or 0)
      local peak = total and total.peak or 0
      if now_row ~= nil and partial >= 10 then peak = math.max(peak, now_row.time * 1000 / partial) end
      local stalls = session.stalls and session.stalls[key] or nil
      local history = mem.history[key]
      local flags = {}
      if #links > 0 and links[1].source == key and links[1].fn ~= installed.wrapper then
        flags[#flags + 1] = "on_top_not_timed"
      end
      for _, r in ipairs(rehook.repeated) do
        if r.source == key then flags[#flags + 1] = "hooked_" .. r.n .. "_times" end
      end
      if seconds > 0 then
        rows[#rows + 1] = {
          key = key, mss = time * 1000 / seconds, peak = peak,
          worst = math.max(total and total.worst or 0, now_row and now_row.worst or 0) * 1000,
          render = (render[key] or 0) * 1000 / seconds,
          stalls = stalls and stalls.count or 0, worst_stall = stalls and stalls.top[1] and stalls.top[1] * 1000 or 0,
          errors = installed.errors_session[key] or 0,
          memory = history and #history > 0 and history[#history].kb or nil,
          units = (units.max[key] or 0) > 0 and obj("alive", units.alive[key] or 0, "most", units.max[key],
                                                    "older_than_10_min", units.old[key] or 0) or nil,
          flags = flags }
      end
    end
    table.sort(rows, function(a, b) return a.mss > b.mss end)
    local mods = {}
    for _, row in ipairs(rows) do mods[#mods + 1] = mod_obj(row) end
    local warnings = {}
    local function warn(kind, key, text)
      warnings[#warnings + 1] = obj("type", kind, "key", key, "text", text)
    end
    for owner, flag in pairs(mem.flagged) do
      warn("MEM", owner, string.format("MEM %s ~%s, +%s in %d min", short_name(owner), kb_text(flag.kb),
                                       kb_text(flag.growth), flag.minutes))
    end
    for mod, flag in pairs(units.flagged) do
      warn("UNITS", mod, string.format("UNITS %s %d old units, still rising", short_name(mod), flag.old))
    end
    if rehook.repeated[1] ~= nil and rehook.repeated[1].n >= REHOOK_COPIES then
      warn("REHOOK", rehook.repeated[1].source,
           string.format("REHOOK %s x%d", short_name(rehook.repeated[1].source), rehook.repeated[1].n))
    end
    if (installed.churn_logged or 0) > 0 and installed.churn_line ~= nil then
      warn("REHOOK", nil, installed.churn_line.text)
    end
    for key in pairs(installed.error_told or {}) do
      warn("LUA_ERRORS", key, short_name(key) .. " keeps raising Lua errors")
    end
    if gpu.over_text ~= nil then warn("VRAM", nil, gpu.over_text) end
    local ok_date, ended = pcall(os.date, "%Y-%m-%d %H:%M:%S")
    local r = head("closed", installed.session_date, ok_date and ended or nil,
                   seconds / 60, seconds > 0 and frames / seconds or nil,
                   session.stalls50, session.stalls200)
    push(r, "mods", arr(mods))
    push(r, "warnings", arr(warnings))
    push(r, "crash", nil)
    local ok = write(done(r))
    say("data file: " .. (ok and "written" or "not written") .. " (mod_lag_watchdog.json, " .. #mods .. " mods)")
  end

  -- Once a minute, the 20 costliest mods into the black box (no disk).
  installed.data_snapshot = function()
    local W = installed.box
    if W == nil or (session.time or 0) <= 0 then return end
    local render = installed.rt ~= nil and installed.rt.session or {}
    local rows = {}
    for key, total in pairs(session.mods or {}) do rows[#rows + 1] = { key = key, total = total } end
    table.sort(rows, function(a, b) return a.total.time > b.total.time end)
    local n = math.min(SNAP_ROWS, #rows)
    W[DATA_SNAP] = 0                                        -- not readable while it changes
    W[DATA_SNAP + 1] = math.floor(session.time)
    W[DATA_SNAP + 2] = (session.frames or 0) % 4294967296
    W[DATA_SNAP + 3] = session.stalls50 or 0
    W[DATA_SNAP + 4] = session.stalls200 or 0
    for i = 1, n do
      local r, o = rows[i], DATA_SNAP + 6 + (i - 1) * SNAP_WORDS
      local stalls = session.stalls and session.stalls[r.key] or nil
      W[o] = installed.box_id(r.key)
      W[o + 1] = math.floor(r.total.time * 1000 / session.time * 100)
      W[o + 2] = math.floor(r.total.peak * 100)
      W[o + 3] = math.floor(r.total.worst * 100000)
      W[o + 4] = math.floor((render[r.key] or 0) * 1000 / session.time * 100)
      W[o + 5] = stalls and stalls.count or 0
      W[o + 6] = stalls and stalls.top[1] and math.floor(stalls.top[1] * 1000) or 0
      W[o + 7] = installed.errors_session[r.key] or 0
    end
    W[DATA_SNAP + 5] = n
    W[DATA_SNAP] = 1
  end

  -- At the next launch: the session that never closed, from its box.
  installed.data_write_crash = function(prev, how, crash, ended)
    local snap = prev.snap
    local mods = {}
    for _, row in ipairs(snap and snap.rows or {}) do
      mods[#mods + 1] = mod_obj({ key = row.key, mss = row.mss, peak = row.peak, worst = row.worst,
                                  render = row.render, stalls = row.stalls, worst_stall = row.worst_stall,
                                  errors = row.errors, flags = { "until_the_last_minute" } })
    end
    local r = head(how, local_time(prev.start), ended,
                   snap and snap.seconds / 60 or nil,
                   snap and snap.seconds > 0 and snap.frames / snap.seconds or nil,
                   snap and snap.stalls50 or nil, snap and snap.stalls200 or nil)
    push(r, "mods", arr(mods))
    push(r, "warnings", arr({}))
    push(r, "crash", crash)
    local ok = write(done(r))
    say("data file: " .. (ok and "written" or "not written") .. " for the last session (" .. how .. ")")
  end
  installed.data_obj = obj
end

-- ------------------------------------------------------------ black box

-- v0.33.0 (the user, 2026-10-09: name the mod behind a crash in play, not
-- only behind a Lua error). A native crash -- the engine reading a bad
-- pointer a mod's call handed it -- ends the process at once: no Lua runs
-- and nothing is written. So this module keeps, at every moment, which
-- mod's update runs, in 8 KB of memory mapped from mod_lag_finder_box.bin.
-- A store there is the file's content, and Windows writes it to disk even
-- when the process dies, since the pages belong to the file, not the process
-- (proven offline 2026-10-09, watchdog_box_crash_check.py: a process that
-- stores and then fails fast, no handler running, leaves the words in the
-- file). Each timing shim stores its mod's number on entry and puts the
-- outer one back on exit: no allocation, no file I/O.
--
-- Words (uint32; 8 KB until v0.36.0, 32 KB since v0.37.0): 0 magic, 1 layout, 2 state (1 running, 2 closed, 3
-- closing), 3 who runs (0 not in the update, 2 in the update but in no timed
-- mod, 3 and up a mod; this module's own tick is its own number), 4 frame,
-- 5 start (os.time), 6 the thread the mods run on, 7 the mod on top that no
-- shim times (0 none), 8 how many names; from word 64, 24 words a name: its
-- length, then its bytes, 4 a word. A name is written before the count that
-- makes it readable.
--
-- The next launch reads the file before mapping it again. A session that
-- never closed, with a crash dump written after it started, crashed. The
-- dump's exception stream says on which thread: only a crash on the thread
-- the mods run on, inside a timed mod, names that mod. A crash on any other
-- thread happened while the main thread was wherever it was, and naming the
-- mod there would be a guess (proven on the 103 dumps of 2026-10-04..09: the
-- 14 with Lua on the faulting thread were all on the first thread, the 74
-- render crashes at +0x626296 all on another). In game the thread is
-- GetCurrentThreadId on every tick: the thread every mod's update runs on.
-- (Inside a function: the main chunk is at Lua's 200-locals limit.)
installed.box_setup = function(log_file)
  -- v0.37.0: room for 300 names (32 KB), as the walk now goes past 64 mods.
  local BOX_WORDS, NAMES, SLOT, MAX_NAMES, MAGIC = 8192, 64, 24, 300, 0x584F424D
  local box_path = string.gsub(log_file, "mod_lag_finder%.log$", "mod_lag_finder_box.bin")
  local dumps = string.gsub(log_file, "\\mod_lag_finder%.log$", "\\dumps")
  local function word(bytes, index)
    if type(bytes) ~= "string" then return nil end
    local a, b, c, d = string.byte(bytes, index * 4 + 1, index * 4 + 4)
    if d == nil then return nil end
    return a + b * 256 + c * 65536 + d * 16777216
  end

  -- The last session's box, read before this one maps the file again.
  local before = read_all(box_path)
  if before ~= nil and #before >= NAMES * 4 and word(before, 0) == MAGIC and word(before, 1) == 1 then
    local prev = { state = word(before, 2), who = word(before, 3), frame = word(before, 4),
                   start = word(before, 5), thread = word(before, 6), top = word(before, 7), names = {} }
    for n = 1, math.min(word(before, 8) or 0, MAX_NAMES) do
      local base = NAMES + (n - 1) * SLOT
      local length = word(before, base)
      if length == nil or length > (SLOT - 1) * 4 then break end
      prev.names[n + 2] = string.sub(before, (base + 1) * 4 + 1, (base + 1) * 4 + length)
    end
    -- v0.40.0: the last minute summary the session put in its box (see
    -- "data file"): word 7300 is 1 when it is whole.
    local SNAP = 7300
    if word(before, SNAP) == 1 then
      local snap = { seconds = word(before, SNAP + 1), frames = word(before, SNAP + 2),
                     stalls50 = word(before, SNAP + 3), stalls200 = word(before, SNAP + 4), rows = {} }
      for i = 1, math.min(word(before, SNAP + 5) or 0, 20) do
        local o = SNAP + 6 + (i - 1) * 8
        local key = prev.names[word(before, o) or 0]
        if key ~= nil then
          snap.rows[#snap.rows + 1] = { key = key, mss = word(before, o + 1) / 100, peak = word(before, o + 2) / 100,
                                        worst = word(before, o + 3) / 100, render = word(before, o + 4) / 100,
                                        stalls = word(before, o + 5), worst_stall = word(before, o + 6),
                                        errors = word(before, o + 7) }
        end
      end
      prev.snap = snap
    end
    installed.box_prev = prev
  end

  -- The memory: a test hands a table (the __hd2_native_test seam, as for
  -- the timer); the game maps the file.
  local W, thread, ffi, kernel
  local seam = rawget(_G, "__hd2_native_test")
  if type(seam) == "table" then
    if type(seam.box) ~= "table" then return "off (a test without a box)" end
    W, thread = seam.box, tonumber(seam.box_thread) or 0
  else
    local loader = rawget(_G, "require")
    if type(loader) ~= "function" then return "off (no require)" end
    local ok, lib = pcall(loader, "ffi")
    if not ok or type(lib) ~= "table" then return "off (no ffi)" end
    ffi = lib
    for _, decl in ipairs({
        "void *CreateFileA(const char *name, uint32_t access, uint32_t share, void *security," ..
          " uint32_t disposition, uint32_t flags, void *template);",
        "void *CreateFileMappingA(void *file, void *security, uint32_t protect, uint32_t high," ..
          " uint32_t low, const char *name);",
        "void *MapViewOfFile(void *mapping, uint32_t access, uint32_t high, uint32_t low, size_t size);",
        "uint32_t GetCurrentThreadId(void);",
        "void *FindFirstFileA(const char *pattern, void *data);",
        "int FindNextFileA(void *find, void *data);",
        "int FindClose(void *find);" }) do
      pcall(ffi.cdef, decl)
    end
    kernel = ffi.load("kernel32")
    local create = ffi.cast("void *(*)(const char *, uint32_t, uint32_t, void *, uint32_t, uint32_t, void *)",
                            kernel.CreateFileA)
    local mapping_of = ffi.cast("void *(*)(void *, void *, uint32_t, uint32_t, uint32_t, const char *)",
                                kernel.CreateFileMappingA)
    local view_of = ffi.cast("void *(*)(void *, uint32_t, uint32_t, uint32_t, size_t)", kernel.MapViewOfFile)
    -- Read and write, shared, opened or created; PAGE_READWRITE; FILE_MAP_WRITE.
    local file = create(box_path, 0xC0000000, 3, nil, 4, 0x80, nil)
    if file == nil or tonumber(ffi.cast("intptr_t", file)) == -1 then return "off (the file did not open)" end
    local mapping = mapping_of(file, nil, 4, 0, BOX_WORDS * 4, nil)
    if mapping == nil then return "off (no mapping)" end
    local view = view_of(mapping, 2, 0, 0, BOX_WORDS * 4)
    if view == nil then return "off (no view)" end
    -- Kept for the whole session: a collected ffi.load unloads the DLL, and
    -- the handles stay open until the process ends.
    installed.box_keep = { ffi = ffi, kernel = kernel, file = file, mapping = mapping, view = view }
    W = ffi.cast("uint32_t *", view)
    -- Taken again on every tick (a read of the thread block, no system
    -- call): the thread the mods' updates run on, not the one that loaded us.
    local current = ffi.cast("uint32_t (*)(void)", kernel.GetCurrentThreadId)
    installed.box_keep.thread = current
    installed.box_thread = function() return current() end
    thread = tonumber(current())
  end
  local ok_now, started = pcall(os.time)
  W[8], W[7], W[4], W[3], W[2], W[1] = 0, 0, 0, 0, 1, 1
  W[7300] = 0                -- v0.40.0: no snapshot yet (installed.DATA_SNAP, see "data file")
  W[5], W[6] = ok_now and tonumber(started) or 0, thread
  W[0] = MAGIC

  local ids, count = {}, 0
  installed.box_id = function(key)
    key = tostring(key or "?")
    local id = ids[key]
    if id ~= nil then return id end
    if count >= MAX_NAMES then return 2 end
    local text = string.sub(key, 1, (SLOT - 1) * 4)
    local base = NAMES + count * SLOT
    for index = 0, SLOT - 2 do
      local a, b, c, d = string.byte(text, index * 4 + 1, index * 4 + 4)
      W[base + 1 + index] = (a or 0) + (b or 0) * 256 + (c or 0) * 65536 + (d or 0) * 16777216
    end
    W[base] = #text
    count = count + 1
    W[8] = count
    id = count + 2
    ids[key] = id
    return id
  end
  installed.box = W

  -- The newest crash dump (dump-<process start>-....dmp sorts by time).
  local function newest_dump()
    local names = {}
    if type(seam) == "table" then
      if type(seam.dump_names) == "function" then names = seam.dump_names() or {} end
    else
      local first = ffi.cast("void *(*)(const char *, void *)", kernel.FindFirstFileA)
      local next_file = ffi.cast("int (*)(void *, void *)", kernel.FindNextFileA)
      local close = ffi.cast("int (*)(void *)", kernel.FindClose)
      local data = ffi.new("uint8_t[640]")          -- WIN32_FIND_DATAA (320 bytes); the name at +44
      local find = first(dumps .. "\\dump-*.dmp", data)
      if find == nil or tonumber(ffi.cast("intptr_t", find)) == -1 then return nil end
      repeat
        names[#names + 1] = ffi.string(data + 44)
      until #names >= 5000 or next_file(find, data) == 0
      close(find)
    end
    local best = nil
    for _, name in ipairs(names) do
      if type(name) == "string" and (best == nil or name > best) then best = name end
    end
    return best
  end

  -- From a minidump: when it was written (header), the exception's thread,
  -- code and address, and the module and offset the address is in.
  local function read_dump(path)
    local file = io.open(path, "rb")
    if file == nil then return nil end
    local function at(offset, size)
      file:seek("set", offset)
      return file:read(size)
    end
    local ok, dump = pcall(function()
      local head = at(0, 32)
      if type(head) ~= "string" or string.sub(head, 1, 4) ~= "MDMP" then return nil end
      local streams, directory = word(head, 2), word(head, 3)
      local found = { written = word(head, 5) }
      local list = at(directory, streams * 12)
      local exception, modules
      for index = 0, streams - 1 do
        local kind, where = word(list, index * 3), word(list, index * 3 + 2)
        if kind == 6 then exception = where elseif kind == 4 then modules = where end
      end
      if exception == nil then return nil end
      local record = at(exception, 32)
      found.thread, found.code = word(record, 0), word(record, 2)
      found.address = word(record, 6) + word(record, 7) * 4294967296
      if modules ~= nil then
        for index = 0, math.min(word(at(modules, 4), 0) or 0, 2000) - 1 do
          local entry = at(modules + 4 + index * 108, 24)
          local base = word(entry, 0) + word(entry, 1) * 4294967296
          if found.address >= base and found.address < base + word(entry, 2) then
            local name_at = word(entry, 5)
            local wide = at(name_at + 4, math.min(word(at(name_at, 4), 0) or 0, 520)) or ""
            local name = string.gsub(wide, "%z", "")
            found.module = string.match(name, "([^\\/]+)$") or name
            found.offset = found.address - base
            break
          end
        end
      end
      return found
    end)
    file:close()
    if ok then return dump end
    return nil
  end

  -- Called once the Lua-error file and the loader's loading crash have had
  -- their say: either one names the last crash better.
  installed.box_judge = function()
    local prev = installed.box_prev
    installed.box_prev = nil
    if prev == nil or prev.state == 2 then return end
    local started = local_time(prev.start)
    if prev.frame == 0 then
      say(string.format("last crash: the previous session (%s) ended before its first frame (see the loader's log)",
                        started))
      return
    end
    local function name(id)
      return prev.names[id] or (id == 2 and "(the update, in no timed mod)") or (id == 0 and "(no mod)")
             or ("#" .. tostring(id))
    end
    local doing = string.format("%s, frame %d, %s", started, prev.frame,
                                prev.state == 3 and "while closing" or ("running " .. name(prev.who)))
    local newest = newest_dump()
    local dump = newest ~= nil and read_dump(dumps .. "\\" .. newest) or nil
    local function record(how, crash, ended)
      if prev.state ~= 3 and installed.data_write_crash ~= nil then
        pcall(installed.data_write_crash, prev, how, crash, ended)
      end
    end
    if dump == nil or dump.written == nil or dump.written < prev.start then
      say(string.format("last crash: the previous session (%s) never closed, and no crash dump was written " ..
                        "after it began (closed by force?): not shown", doing))
      record("unknown", nil, nil)
      return
    end
    local where = dump.module ~= nil and string.format("%s+0x%X", dump.module, dump.offset)
                  or string.format("0x%X", dump.address or 0)
    local text = string.format("the previous session (%s) crashed: dump %s at %s, exception 0x%08X at %s, thread %d",
                               doing, newest, local_time(dump.written), dump.code or 0, where, dump.thread or 0)
    local named = nil
    if dump.thread ~= prev.thread then
      say("last crash: " .. text .. "; the mods run on thread " .. tostring(prev.thread) ..
          ", so no mod's update was running in it: not shown")
    elseif prev.state ~= 3 and prev.who >= 3 and prev.names[prev.who] ~= nil and
           not is_mod_source(prev.names[prev.who]) then
      -- The bottom link: the game's own update script, not a mod.
      say("last crash: " .. text .. ", on the mods' thread, in the game's own update (" ..
          prev.names[prev.who] .. "): not shown")
    elseif prev.state ~= 3 and prev.who >= 3 and prev.names[prev.who] ~= nil then
      say("last crash: " .. text .. ", on the mods' thread, in " .. prev.names[prev.who])
      ui.crash_note = { key = prev.names[prev.who], native = true }
      named = prev.names[prev.who]
    else
      say("last crash: " .. text .. ", on the mods' thread but in no timed mod" ..
          (prev.top >= 3 and ("; on top, not timed: " .. name(prev.top)) or "") .. ": not shown")
    end
    local obj = installed.data_obj
    if obj ~= nil then
      record("crashed", obj("key", named, "name", named and short_name(named) or nil, "dump", newest,
                            "exception", string.format("0x%08X", dump.code or 0), "where", where,
                            "on_mods_thread", dump.thread == prev.thread, "shown", named ~= nil),
             local_time(dump.written))
    end
  end
  return "on (mod_lag_finder_box.bin)"
end

local function main()
  pcall(load_place)
  if log_path ~= nil then
    local size = file_size(log_path)
    if size ~= nil and size > LOG_LIMIT then
      write_raw("-- log restarted above " .. LOG_LIMIT .. " bytes" .. NL, "w")
    end
  end
  local ok, date = pcall(os.date, "%Y-%m-%d %H:%M:%S")
  installed.session_date = ok and date or nil
  write_raw(NL .. "== " .. MARKER .. " session " ..
            (ok and tostring(date) or "?") .. " ==" .. NL, "a")
  do
    local ok_id, id = pcall(installed.build_id)
    say("build: " .. (ok_id and tostring(id) or "unknown") ..
        " (this copy's code; the official builds are listed with each release)")
  end
  if type(getupvalue) ~= "function" or type(setupvalue) ~= "function" or
     type(getinfo) ~= "function" or type(os_clock) ~= "function" then
    say(string.format("cannot work here: debug.getupvalue=%s setupvalue=%s getinfo=%s os.clock=%s",
                      type(getupvalue), type(setupvalue), type(getinfo), type(os_clock)))
    return
  end
  if log_path ~= nil then
    local ok_box, told = pcall(installed.box_setup, log_path)
    if not ok_box then installed.box = nil end
    if installed.box ~= nil then installed.box_self = installed.box_id(source_of(main)) end
    say("black box: " .. (ok_box and tostring(told) or ("off (" .. tostring(told) .. ")")))
  end
  pcall(installed.data_file)
  -- v0.35.0: what render was at load, for the render walk (see "render").
  installed.render_seen = {}
  if type(rawget(_G, "render")) == "function" then installed.render_seen[rawget(_G, "render")] = true end
  -- Not armed here: the first main_world call or the first frame arms it,
  -- above every mod that hooked update while loading. The top link's own
  -- time cannot be measured, so the top is best kept for this module.

  if type(original_main_world) == "function" then
    local busy, seen, skipped = false, nil, 0
    local function watchdog_check()
      if installed.last_tick_at == seen then
        if skipped < 8 then
          skipped = skipped + 1
          return
        end
      else
        seen = installed.last_tick_at
      end
      skipped = 0
      arm()
    end
    local watchdog = function(...)
      installed.mw_calls = installed.mw_calls + 1
      if not busy then
        busy = true
        pcall(watchdog_check)
        busy = false
      end
      return original_main_world(...)
    end
    if not pcall(rawset, App, "main_world", watchdog) then arm() end
  else
    arm()
  end
  -- The first frame arms us from update too (v0.12.5). Arming waited for
  -- some mod to call Application.main_world; with none that does (the
  -- user's test profile 2026-09-30 16:59: Bingus Shared Loader, SmoothBoot
  -- and this module), the Watchdog never started. This hook only arms us
  -- once and passes every call on unchanged (a tail call); the chain walk
  -- knows it and neither times it nor counts it as a second hook of ours.
  -- Whichever comes first, main_world or update, arms; re-arming stays as
  -- it was (a stale heartbeat seen from main_world).
  local boot_previous = rawget(_G, "update")
  if installed.wrapper == nil and type(boot_previous) == "function" then
    local bootstrap = function(...)
      if installed.wrapper == nil then pcall(arm) end
      return boot_previous(...)
    end
    for index = 1, 255 do
      local name = getupvalue(bootstrap, index)
      if name == nil then break end
      if name == "boot_previous" then
        installed.bootstrap_slot = { kind = "uv", holder = bootstrap, key = index,
                                     name = name, original = boot_previous }
      end
    end
    installed.bootstrap = bootstrap
    rawset(_G, "update", bootstrap)
  end
  local named_at = now()
  local ok_names, told = pcall(read_names)
  say(string.format("names: %s (%.0f ms)", ok_names and tostring(told) or ("failed: " .. tostring(told)),
                    (now() - named_at) * 1000))
  say("timer: " .. timer_kind)
  -- v0.43.0: whether LuaJIT compiles at all here (its interpreter is many
  -- times slower: this module's own time in game is ~10x that offline).
  do
    local jit_lib = rawget(_G, "jit")
    local status = type(jit_lib) == "table" and rawget(jit_lib, "status") or nil
    if type(status) == "function" then
      local ok_status, on = pcall(status)
      say("jit: " .. (ok_status and (on and "on" or "off") or "status failed") ..
          " (" .. tostring(rawget(jit_lib, "version")) .. ")")
    else
      say("jit: no jit library")
    end
  end
  if log_path ~= nil then
    installed.crash_path = string.gsub(log_path, "mod_lag_finder%.log$", "mod_lag_finder_crash.txt")
    local last = read_all(installed.crash_path)
    local key = last and string.match(last, "key=([^\r\n]*)") or nil
    if key ~= nil and key ~= "" then
      say(string.format("last crash: the game closed on a Lua error from %s (%s): %s", key,
                        string.match(last, "date=([^\r\n]*)") or "?", string.match(last, "message=([^\r\n]*)") or "?"))
      local name = string.match(last, "name=([^\r\n]*)")
      ui.crash_note = { key = key, name = (name ~= nil and name ~= "") and name or nil }
      local file = io.open(installed.crash_path, "w")
      if file ~= nil then file:close() end
    end
  end
  -- v0.31.0: a launch that closed while the mods were still loading, before
  -- this module could see anything. Bingus Shared Loader v19 reads its own
  -- previous log at start ("Previous session: started <t> (...); its log
  -- ended while loading <module>") and the dump folder ("Newest crash dump:
  -- <t>, exception ..."). Shown only when a dump was written after that
  -- launch began: a log that ends while loading may also be a player who
  -- closed the game. Times are "YYYY-MM-DD HH:MM:SS", local, so they compare
  -- as text.
  if ui.crash_note == nil then
    pcall(function()
      local loader = rawget(_G, "CowboyBingusModLoader")
      local health = type(loader) == "table" and rawget(loader, "health") or nil
      local header = type(health) == "table" and rawget(health, "header") or nil
      if type(header) ~= "table" then return end
      local started, loading, dump_at
      for _, line in ipairs(header) do
        if type(line) == "string" then
          local s_at, rest = string.match(line, "^Previous session: started (%d+%-%d+%-%d+ %d+:%d+:%d+)(.*)$")
          if s_at ~= nil then
            started = s_at
            loading = string.match(rest, "its log ended while loading (%S+)$")
          end
          dump_at = dump_at or string.match(line, "^Newest crash dump: (%d+%-%d+%-%d+ %d+:%d+:%d+)")
        end
      end
      if loading == nil then return end
      if dump_at ~= nil and dump_at >= started then
        say(string.format("last crash: the previous launch (%s) closed while %s was loading; crash dump %s",
                          started, loading, dump_at))
        ui.crash_note = { key = loading, startup = true }
      else
        say(string.format("last crash: the previous launch (%s) ended while %s was loading, with no crash dump " ..
                          "after it began: not shown", started, loading))
      end
    end)
  end
  -- v0.33.0: a crash in play, from the black box.
  if installed.box_judge ~= nil then
    if ui.crash_note == nil then
      local ok_judge, err = pcall(installed.box_judge)
      if not ok_judge then say("last crash: the black box could not be read: " .. tostring(err)) end
    else
      installed.box_prev = nil
    end
  end
  local ok_gpu, gpu_told = pcall(gpu.open)
  if not ok_gpu then gpu.read = nil end
  say("vram: " .. (ok_gpu and tostring(gpu_told) or ("off (" .. tostring(gpu_told) .. ")")))
  pcall(units.install)
  say(units.installed and "units: counting the helper units each mod spawns"
                      or "units: off (World.spawn_unit / destroy_unit not found)")
  say("installed; frames of " .. HITCH_MS .. " ms or more are broken down by mod")
end

installed.self_fn = type(getinfo) == "function" and getinfo(1, "f").func or nil
local main_ok, main_err = pcall(main)
pcall(flush_log)
if not main_ok then
  write_raw("main chunk failed: " .. tostring(main_err) .. NL, "a")
end

return { name = MARKER }
