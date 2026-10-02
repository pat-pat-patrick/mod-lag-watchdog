-- HD2-Addon: mods/patpatpatrick/mod_lag_finder
-- Mod Lag Watchdog v0.19.0 (was Mod Lag Finder; the addon, log and window
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

local MARKER = "mod-lag-finder-v0.19.0"

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
local MAX_LINKS = 64
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

local function write_raw(text, mode)
  if log_path == nil then return end
  local ok_t, t0 = pcall(timer_now)
  local file = io.open(log_path, mode)
  if file == nil then return end
  file:write(text)
  file:close()
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
local function make_shim(link, target, handler, counter)
  local function finish(t0, ...)
    local took = timer_now() - t0
    link.prev_incl, link.prev_frame = link.last_incl, link.last_frame
    link.last_incl, link.last_frame = took, counter.frame_id
    return ...
  end
  local shim
  if handler == nil then
    shim = function(...)
      return finish(timer_now(), target(...))
    end
  else
    local function settle_up(t0, ok, ...)
      local took = timer_now() - t0
      link.prev_incl, link.prev_frame = link.last_incl, link.last_frame
      link.last_incl, link.last_frame = took, counter.frame_id
      if ok then return ... end
      error((...), 0)
    end
    shim = function(...)
      return settle_up(timer_now(), xpcall(target, handler, ...))
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
  if #mapping.links >= MAX_LINKS then return finish_mapping("link limit") end
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
  our_index = nil
  runtime_index = nil
  for index, link in ipairs(links) do
    if link.fn == installed.wrapper then our_index = index end
    if link.source == MDL_SOURCE and runtime_index == nil then runtime_index = index end
  end
  local copies = {}
  for _, link in ipairs(links) do
    if link.bottom ~= "game" then copies[link.source] = (copies[link.source] or 0) + 1 end
  end
  local repeated = {}
  for source, n in pairs(copies) do
    if n >= 2 then repeated[#repeated + 1] = { source = source, n = n } end
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

local function selfs()
  local out = {}
  local n = #links
  for index = n, 2, -1 do
    local link = links[index]
    local incl = settled_incl(index, link)
    local below = index < n and settled_incl(index + 1, links[index + 1]) or 0
    local own = incl - below
    if own < 0 then own = 0 end
    out[index] = { link = link, own = own, incl = incl }
  end
  return out
end

-- The bottom link's time includes everything below it: the game when the
-- walk reached it, otherwise whatever the walk could not see past.
local function owner(link)
  if link.bottom == "game" then return "(the game)" end
  if link.boot_patch then return link.source .. " (boot patch)" end
  if link.bottom ~= nil then return link.source .. " (+ all below it)" end
  return link.source
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
  for _, entry in pairs(frame_selfs) do
    local key = owner(entry.link)
    charge_row(window.mods, key, entry.own)
    if live.bucket ~= nil then charge_row(live.bucket.mods, key, entry.own) end
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

read_names = function()
  -- The enabled mods and how each runs, for "copy mod list" (v0.17.1).
  installed.mod_list, installed.mod_list_why = nil, "no Arsenal mod list was read"
  local listed_mods = {}
  local ok_env, localappdata = pcall(os.getenv, "LOCALAPPDATA")
  if not ok_env or type(localappdata) ~= "string" then return "no LOCALAPPDATA" end
  local text = read_all(localappdata .. "\\hd2arsenal\\hd2a_data.json")
  if text == nil then return "no Arsenal mod list" end
  local data, why = json_decode(text)
  if type(data) ~= "table" then return "Arsenal mod list unreadable: " .. tostring(why or "not an object") end
  local profile = type(data.modsList) == "table" and data.modsList[data.selectedProfile or "default"]
  if type(profile) ~= "table" or type(profile.mods) ~= "table" then return "no active Arsenal profile" end
  local seen, archives = {}, 0
  local hashes, readable, owner_of = {}, {}, {}
  local claims, claim_order = {}, {}     -- row hash -> { [mod index] = claim }, rows in order
  local shared, shared_rows = {}, {}
  installed.shared, installed.shared_rows, installed.shared_seen = shared, shared_rows, {}
  for mod_index, mod in ipairs(profile.mods) do
    if type(mod) == "table" and mod.enabled == true and type(mod.path) == "string" then
      local listed = { label = plain_label(mod.label), keys = {}, lua = 0, scripts = 0 }
      listed_mods[#listed_mods + 1] = listed
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
      -- Which options each resource of this mod comes from.
      local by_addon, order, lua_folders = {}, {}, 0
      for _, folder in ipairs(folders) do
        local path = mod.path .. (folder.dir ~= "" and ("\\" .. folder.dir) or "") .. "\\" .. LUA_ARCHIVE
        local addons = archive_addons(path)
        if addons ~= nil then archives = archives + 1 end
        if addons ~= nil and #addons > 0 then lua_folders = lua_folders + 1 end
        -- The mod list sees every patch index of the folder.
        local every = {}
        for _, entry in ipairs(addons or {}) do every[#every + 1] = entry end
        for patch = 1, 15 do
          local more = archive_addons((string.gsub(path, "patch_0$", "patch_" .. patch)))
          for _, entry in ipairs(more or {}) do
            every[#every + 1] = entry
            hashes[entry.key], hashes[entry.row] = true, true
          end
        end
        for _, entry in ipairs(every) do
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
  return string.format("%d addons named from Arsenal (%d Lua archives read)", count, archives)
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
  local x, top, shown, alerts = string.match(text or "", "^%s*(%-?%d+)%s+(%-?%d+)%s*(%d?)%s*(%d?)")
  if x ~= nil then ui.place = { x = tonumber(x), top = tonumber(top) } end
  if shown == "1" then ui.panel = true end
  if alerts == "0" then ui.alerts_off = true end
end

local function save_place()
  if place_path == nil then return end
  local file = io.open(place_path, "w")
  if file == nil then return end
  file:write(string.format("%d %d %d %d", ui.place.x, ui.place.top, ui.panel and 1 or 0,
                           ui.alerts_off and 0 or 1) .. NL)
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

local function mem_process(job, obj, owner)
  local bytes
  if type(obj) == "table" then
    local entries, strings = 0, 0
    for key, value in next, obj do
      entries = entries + 1
      if type(key) == "string" then strings = strings + #key else mem_visit(job, key, owner) end
      if type(value) == "string" then strings = strings + #value else mem_visit(job, value, owner) end
    end
    if getmeta ~= nil then mem_visit(job, getmeta(obj), owner) end
    bytes = 64 + 40 * entries + strings
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
end

kb_text = function(kb)
  if kb >= 1024 then return string.format("%.1f MB", kb / 1024) end
  return string.format("%.0f KB", kb)
end

local function mem_finish(job, at)
  mem.job = nil
  mem.next_at = at + MEM_EVERY_S
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
      history[#history + 1] = { kb = kb, world = job.world }
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
  say(string.format("memory: %d objects in %d frames (%.1f ms); world #%d; Lua heap %s; shared ~%s; %s",
                    job.objects, job.frames, job.spent * 1000, job.world,
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
      local found = { kb = history[count].kb, growth = growth, minutes = FLAG_SPAN * MEM_EVERY_S / 60 }
      if grows and crossed and growth >= FLAG_MIN_KB then leak = found end
      if grows and growth >= SCREEN_MIN_KB then fast = found end
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
    for _, link in ipairs(links) do
      local mod = type(link.fn) == "function" and mod_of(link.fn) or nil
      if mod ~= nil then mem_add_root(job, link.fn, mod) end
    end
    mem.job = job
  end
  local started = timer_now()
  local steps = 0
  while steps < MEM_STEPS do
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
      job.q[head], job.qo[head] = nil, nil
      job.head = head + 1
      mem_process(job, obj, owner)
    end
    steps = steps + 1
    if steps % 32 == 0 and timer_now() - started >= MEM_BUDGET_S then break end
  end
  job.frames = job.frames + 1
  job.spent = job.spent + (timer_now() - started)
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
    string.format("Mod Lag Watchdog mod list (%s, game build %s)", version,
                  native.stamp and string.format("%08X", native.stamp) or "unknown"),
    string.format("Session: %.0f min, %.0f FPS average; \"(the game)\" %.1f ms/s average",
                  seconds / 60, seconds > 0 and frames / seconds or 0, game),
  }
  if installed.mod_list == nil then
    lines[#lines + 1] = "No Arsenal mod list: " .. tostring(installed.mod_list_why)
  else
    lines[#lines + 1] = string.format("Enabled in Arsenal: %d mods", #installed.mod_list)
  end
  local groups = by_how_it_runs()
  for _, group in ipairs({
      { groups.timed, "Timed one by one (hook the game's update)" },
      { groups.scripts, "Replace the game's own scripts (their cost shows as \"(the game)\")" },
      { groups.other, "Lua that is not in the update" },
      { groups.none, "No Lua (models, textures, sounds)" },
      { groups.loose, "In the update but not in Arsenal" },
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
      last = "Mods that replace game scripts: unknown (no Arsenal mod list)"
    elseif #scripts == 0 then
      last = "Mods that replace game scripts (counted here): none in Arsenal"
    else
      last = "Mods that replace game scripts (counted here): " .. table.concat(scripts, ", ")
    end
  end
  local lines = {
    string.format("Mod Lag Watchdog report: %s (%s)", name, key),
    string.format("Game build %s, Watchdog %s, %d mods hook the update",
                  native.stamp and string.format("%08X", native.stamp) or "unknown", version, chain),
    string.format("Session: %.0f min, %.0f FPS average, %d world changes", seconds / 60,
                  seconds > 0 and frames / seconds or 0, units.world_changes or 0),
    string.format("Cost: %.1f ms/s average, %.1f ms/s in the worst minute, worst frame %s ms",
                  seconds > 0 and time * 1000 / seconds or 0, peak, ms(worst)),
    stall_text,
    memory_text,
    units_text,
    last,
  }
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
  for key, row in pairs(merged) do rows[#rows + 1] = { key = key, row = row } end
  table.sort(rows, function(a, b) return a.row.time > b.row.time end)

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
      local per_second = r.row.time * 1000 / math.max(seconds, 0.001)
      if not all and per_second < QUIET_MSS and r.row.worst * 1000 < QUIET_WORST_MS then
        quiet = quiet + 1
      elseif shown >= PANEL_ROWS then
        more = more + 1
      else
        if shown == 0 then
          out[#out + 1] = { string.format("%-28s %8s %9s", "mod", "ms/s", "worst"), GREY }
        end
        shown = shown + 1
        local tint = (r.row.worst * 1000 >= TOAST_MS or per_second >= AMBER_MSS) and AMBER or WHITE
        if all and tint == WHITE and per_second < QUIET_MSS then tint = GREY end
        out[#out + 1] = { string.format("%-28s %8.1f %6s ms", string.sub(short_name(r.key), 1, 28),
                                        per_second, ms(r.row.worst)), tint, r.key }
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
                                    last_stall.who and ("in " .. last_stall.who) or "outside every mod",
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
  local lines = window_shown and panel_lines(at) or {}
  local g = geometry(#lines + (ui.in_menu and 5 or 1))
  ui.geometry = g
  local s = g.s
  if window_shown and ui.in_menu then
    -- On the menu: a window to drag, with a background and a title bar.
    list[#list + 1] = { rect = true, x = g.x, y = g.top - g.h, w = g.w, h = g.h, z = 90, c = BACK }
    list[#list + 1] = { rect = true, x = g.x, y = g.top - HEADER * s, w = g.w, h = HEADER * s,
                        z = 91, c = BAND }
    list[#list + 1] = { text = "MOD LAG WATCHDOG", x = g.x + PAD * s,
                        y = g.top - HEADER * s + 8 * s, size = TITLE_SIZE * s, c = WHITE }
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
    list[#list + 1] = { text = "click a mod: copy its report",
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

-- On the menu: drag by the title bar, right-click it for the default place.
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
          if row.key == SWITCH then
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
  if mouse_clicked("left") then
    ui.moving = { mx = mx, my = my, px = ui.place.x, ptop = ui.place.top }
  elseif mouse_clicked("right") then
    ui.place = { x = DEFAULT_X, top = DEFAULT_TOP }
    save_place()
    ui.dirty = true
    say("window back to its default place")
  end
end

local function display(at)
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
    local text = string.sub(note.key, 1, 1) == "(" and "LAST CRASH: a Lua error outside every mod"
                 or ("LAST CRASH: " .. (note.name or short_name(note.key)) .. " raised a Lua error")
    if ui.alert({ text = text, until_at = at + 12, colour = AMBER, keep = true, always = true }) then
      ui.crash_note = nil
      say("last crash shown: " .. text)
    end
  end
  if key_pressed() then
    ui.panel = not ui.panel
    ui.dirty = true
    save_place()
    say(ui.panel and "panel opened" or "panel closed")
  end
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
  if not (in_menu or ui.panel or (toast ~= nil and (not ui.alerts_off or toast.always))) then
    if ui.gui ~= nil then drop_gui() end
    ui.dirty = false
    return
  end
  if ui.dirty or at >= ui.next_refresh then
    ui.dirty = false
    ui.next_refresh = at + REFRESH_S
    draw(items(at))
  end
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
  if type(name) ~= "string" or name == "" or string.find(name, "[^\32-\126]") then
    name = tostring(rawget(record, "id") or "?")
    name = string.gsub(name, "^(arsenal:%x%x%x%x%x%x%x%x).*$", "%1")
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

  if hitch.interval * 1000 >= TOAST_MS then
    local first = sorted[1]
    local at = now()
    if first ~= nil and first.entry.own >= hitch.interval * TOAST_SHARE then
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
    parts[#parts + 1] = owner(s.entry.link) .. " " .. ms(s.entry.own)
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
local function tick(failed)
  local at = now()
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
  if top ~= mapped_top then
    if mapped_top ~= nil and (last_change_note == nil or at - last_change_note > 10) then
      last_change_note = at
      say("update chain changed; mapping again")
    end
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
    walk(start_mapping, top)
  elseif mapping ~= nil and not failed then
    walk(step_mapping)
  end

  local heap = heap_kb()
  local mapped = mapping == nil and #links > 0
  local frame_selfs = nil
  if mapped then
    if installed.settling > 0 then
      installed.settling = installed.settling - 1
    else
      frame_selfs = selfs()
    end
  end
  add_mdl(frame_selfs)

  if pending ~= nil then
    report(pending, pending.mapped and mapped and frame_selfs or nil)
    pending = nil
  end
  if frame_selfs ~= nil then charge(frame_selfs) end

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
                  mapped = mapped, mine = installed.tick_cost or 0 }
    end
  end
  last_tick_time = at
  last_heap = heap

  do
    local ok, err = pcall(units.tick, at)
    if not ok and not units.failed then
      units.failed = true
      say("units: check failed: " .. tostring(err))
    end
  end
  if mapping == nil and #links > 0 then
    local ok, err = pcall(mem_step, at)
    if not ok then
      mem.failed, mem.job = true, nil
      say("memory: walk failed, off for this session: " .. tostring(err))
    end
  end

  do
    local ok, err = pcall(gpu.tick, at)
    if not ok and not gpu.failed then
      gpu.failed, gpu.read = true, nil
      say("vram: read failed, off for this session: " .. tostring(err))
    end
  end
  if at - window.started >= SUMMARY_S then write_summary(at) end
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
      local started = now()
      local ok_tick, err = pcall(tick, failed)
      installed.tick_cost = now() - started
      if not ok_tick and not installed.told_tick then
        installed.told_tick = true
        say("tick error: " .. tostring(err))
      end
    end
    local function after(ok, ...)
      installed.depth = 0
      if installed.generation == generation then run_tick(not ok or installed.frame_failed) end
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
      frame_dt = (...)
      frame_argc = select("#", ...)
      if installed.crash_pending ~= nil then pcall(survived) end
      installed.last_err, installed.frame_failed = nil, false
      installed.frame_id = installed.frame_id + 1
      installed.last_tick_at = clock()
      installed.tick_calls = installed.mw_calls
      installed.depth = 1
      if installed.xpcall_args then
        return after(xpcall(previous_update, on_error, ...))
      end
      local n, args = select("#", ...), { ... }
      return after(xpcall(function() return previous_update(unpack_fn(args, 1, n)) end, on_error))
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
    say("update armed generation=" .. installed.generation)
  end
  local current_shutdown = rawget(_G, "shutdown")
  -- Wrapped once a session (v0.12.7: every re-arm stacked another wrapper
  -- when a mod had wrapped shutdown over ours, and the summary ran k+1
  -- times at exit); the flag keeps any copy from doing it twice.
  if type(current_shutdown) == "function" and installed.shutdown_wrapper == nil then
    local previous_shutdown = current_shutdown
    local wrapper = function(...)
      if installed.shutdown_done then return previous_shutdown(...) end
      installed.shutdown_done = true
      pcall(function()
        if installed.clear_crash then installed.clear_crash() end
        write_summary(now())
        say(session_line("game over"))
        say("shutdown")
        flush_log()
      end)
      return previous_shutdown(...)
    end
    installed.shutdown_wrapper = wrapper
    rawset(_G, "shutdown", wrapper)
  end
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
  write_raw(NL .. "== " .. MARKER .. " session " ..
            (ok and tostring(date) or "?") .. " ==" .. NL, "a")
  if type(getupvalue) ~= "function" or type(setupvalue) ~= "function" or
     type(getinfo) ~= "function" or type(os_clock) ~= "function" then
    say(string.format("cannot work here: debug.getupvalue=%s setupvalue=%s getinfo=%s os.clock=%s",
                      type(getupvalue), type(setupvalue), type(getinfo), type(os_clock)))
    return
  end
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
  local ok_gpu, gpu_told = pcall(gpu.open)
  if not ok_gpu then gpu.read = nil end
  say("vram: " .. (ok_gpu and tostring(gpu_told) or ("off (" .. tostring(gpu_told) .. ")")))
  pcall(units.install)
  say(units.installed and "units: counting the helper units each mod spawns"
                      or "units: off (World.spawn_unit / destroy_unit not found)")
  say("installed; frames of " .. HITCH_MS .. " ms or more are broken down by mod")
end

local main_ok, main_err = pcall(main)
pcall(flush_log)
if not main_ok then
  write_raw("main chunk failed: " .. tostring(main_err) .. NL, "a")
end

return { name = MARKER }
