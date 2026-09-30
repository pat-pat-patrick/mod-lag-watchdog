"""Mod Lag Finder through the strict fake engine, from the shipped bytes.

The clock is the scenario's: os.clock is replaced before any mod loads, the
frame advances it by 16 ms outside update, and the mods below spend time by
advancing it inside theirs. Each synthetic mod hooks update in one of the
ways the installed mods do (2026-09-29):

  heavy      named local previous; spends 5 ms a frame (stands in for work)
  std        like this project's mods: previous_update through pcall, plus a
             tick(dt) helper that is ALSO called once a frame with dt
  stripped   stripped bytecode (names gone), a helper called with dt too:
             only the time tie-break can tell previous from helper
  maelstrom  a global `function update(...)`, pcall(tick) with no arguments
  field      keeps its previous in a table field
  slow       spends 400 ms every 300th frame

  map        loaded heavy, std, stripped, finder, maelstrom, field: the finder
             arms on the first frame, so it is the top; every link below is
             found, in order, each by the right rule, down to the game's own
             update
  retry      hiccup skips its previous for 10 frames once the finder is above it:
             the first watch of it fails, the second finds heavy below it
             (v0.2.0 stopped there, calling hiccup the bottom)
  stall      three 1.5 s engine stalls, 20 main_world calls a frame, a mod with
             the old 0.5 s heartbeat hooked above: nobody re-arms. v0.3.0
             escalates here (chain 4 -> 10) as v0.2.0 did with Speed Dial in
             game, 2026-09-29 10:36
  rehook     Mortar Impact Light and Shader Cache Hint Probe as shipped (both on
             the 0.5 s-only rule) fight over the top during engine stalls: the
             finder never joins in, logs both with their copy counts, shows an
             amber REHOOK line and lists them in the window
  mdl        a stand-in for MDL 1.0.5-p11 (MDL.perf == 1, record.perf) runs three
             live scripts in its own link: each gets its own row, MDL's row
             keeps only its own 1 ms, a non-Latin name falls back to the id,
             and a 400 ms stall inside the C4 script is named by it
  names      each mod under its Arsenal name, matched by the HD2-Addon line of
             each Lua resource; cleaned, cut to the column; Chinese, disabled,
             shared and broken-list cases keep the short name
  deploy     Arsenal's deployment_snapshot.json timestamp: two games after one
             deploy are #1 and #2, a new deploy restarts at #1, a missing
             snapshot is said once; each game ends with its stall totals,
             and the window shows the game number
  writes     log lines wait and are written every 10 s: with 500 ms writes the
             stalls stay a handful instead of a chain; the slowest write shows
             in the window and the 60 s summary; no process list is read
  memory     a mod whose Lua memory only grows is flagged after 10 walks (one
             a minute); a steady mod, one that grows and clears, the finder
             and a mod leaking into a global are not
  alerts     the alerts switch turns the pop-up lines off in missions: a
             stall draws nothing, is still logged and shown on the menu
  switch     a click on the menu window's switch line shows the table in
             missions without a Home key; saved for the next game; Home
             still works
  report     a click on a mod row copies its 8-line report to the clipboard;
             with no clipboard it is written to mod_lag_report_<mod>.txt
  units      spawns charged to the calling mod, destroys to the spawner; a mod
             whose helper units only rise past 50 is named; a new world
             starts the counts again
  timer      with ffi the timer is QueryPerformanceCounter: a real 0.3 ms mod
             reads its true share, a mod doing nothing is counted, not listed
  top        slow hooking after the finder armed (as a re-arm does) is the
             top link: its stall is reported as not explained, naming it as
             the unmeasured top
  inside     slow below the finder: its 400 ms is charged to it by name in
             the hitch line and it heads the summary
  same       every mod's own work runs exactly as often with the finder as
             without it, and update's return values pass through
  restore    a world change replaces update: the old chain's slots hold their
             originals again, and the new chain is mapped
  real       Mortar Impact Light and Shader Cache Hint Probe as shipped:
             both mapped by source, nothing dies
  screen     nothing is drawn while nothing is due; a 400 ms stall in slow shows
             "LAG 4xx ms - slow" for 5 s; Home opens the panel (costs, last
             stall) and closes it; the UI world going away gets no GUI call, and
             a new one gets a new GUI
  quiet      a stall in no measured mod (slow on top) is logged, never drawn
  menu       with the game's UI state laid out in fake memory: the window shows
             by itself on the escape menu's GAME tab only (held 3 frames),
             is dragged by its title bar, saved when let go, shown at that
             place by Home in play and in the next game; right-click resets
  patched    another game.dll build: the menu shows nothing, Home still works
  native     the real ReadProcessMemory path on this process, with a system
             DLL loaded as game.dll: refused as another build, nothing dies
  static     the finder never asks for ffi, spawns nothing, touches no unit

    python test_mod_lag_finder.py [--backend luajit21] [--source]
"""

import os
import re
import time
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import modpaths  # noqa: E402
from hd2fake import Session, lua_literal  # noqa: E402
from hd2fake.gate import FFI_DOORS  # noqa: E402
from hashing import murmur64_hash  # noqa: E402
from hd2fake.sources import lua_from_release  # noqa: E402

RELEASE = "Mod Lag Watchdog v0.13.0"
FOLDER = "Mod Lag Watchdog"
LOG = "mod_lag_finder.log"
SOURCE = None
BACKEND = "game"
FAILURES = []

CLOCK = r"""
-- The fake drives frames from a Lua loop (FAKE.frames); the game calls
-- update from C. LuaJIT can root a trace in that loop, inline the whole
-- chain and bake each never-reassigned "previous" upvalue in as a constant:
-- the finder's swaps are then invisible (logged as "previous=0/0"), and its
-- per-function jit.flush cannot reach a trace rooted outside the chain.
-- Seen on lupa luajit21 in about 1 run in 8 (2026-09-29); 0 in 40 with this
-- line. In game no Lua loop sits above the chain, so the flush covers it.
if jit and jit.off then jit.off(FAKE.frames, true) end
CLOCK = 100
os.clock = function() return CLOCK end
FAKE.before_frame = function() CLOCK = CLOCK + 0.016 end
COUNTS = {}
T = {}
local function count(k) COUNTS[k] = (COUNTS[k] or 0) + 1 end
COUNT = count
function UV(fn, wanted)
  for i = 1, 255 do
    local name, value = debug.getupvalue(fn, i)
    if name == nil then return nil end
    if name == wanted then return value end
  end
end
"""

MODS = {
    "heavy": r"""
local previous = rawget(_G, "update")
T.heavy = { prev = previous }
rawset(_G, "update", function(...)
  COUNT("heavy")
  CLOCK = CLOCK + 0.005
  return previous(...)
end)
""",
    "std": r"""
local unpack_fn = unpack
local previous_update = rawget(_G, "update")
local function tick(dt) COUNT("std") end
local function pack(...) return { n = select("#", ...), ... } end
local wrapper = function(...)
  local results = pack(pcall(previous_update, ...))
  pcall(tick, (...))
  if results[1] and results.n > 1 then return unpack_fn(results, 2, results.n) end
end
T.std = { wrapper = wrapper, prev = previous_update }
rawset(_G, "update", wrapper)
""",
    "stripped": r"""
local factory = function(previous, helper)
  return function(...)
    helper((...))
    return previous(...)
  end
end
local make = loadstring(string.dump(factory, true), "@mods/test/stripped")
local wrapper = make(rawget(_G, "update"), function(dt) COUNT("stripped") end)
rawset(_G, "update", wrapper)
""",
    "stripped_lib": r"""
local factory = function(previous, helper)
  return function(...)
    helper((...))
    return previous(...)
  end
end
local make = loadstring(string.dump(factory, true), "@mods/test/stripped_lib")
local helper = loadstring("return function(dt) COUNT('stripped_lib') end",
                          "@mods/test/helper_lib")()
rawset(_G, "update", make(rawget(_G, "update"), helper))
""",
    "maelstrom": r"""
local original_update = rawget(_G, "update")
local function tick() COUNT("maelstrom") end
function update(...)
  pcall(tick)
  return original_update(...)
end
""",
    "field": r"""
local M = { prev = rawget(_G, "update"), note = "x" }
rawset(_G, "update", function(...)
  COUNT("field")
  return M.prev(...)
end)
""",
    "hiccup": r"""
local previous = rawget(_G, "update")
local mine, k = nil, 0
mine = function(...)
  COUNT("hiccup")
  -- Skips the rest of the frame for the first 10 frames after something
  -- hooked above it: exactly when the finder first watches it.
  if rawget(_G, "update") ~= mine then
    k = k + 1
    if k <= 10 then return end
  end
  return previous(...)
end
rawset(_G, "update", mine)
""",
    "slow": r"""
local previous = rawget(_G, "update")
local n = 0
rawset(_G, "update", function(...)
  n = n + 1
  COUNT("slow")
  if n % 300 == 0 then CLOCK = CLOCK + 0.4 end
  return previous(...)
end)
""",
}


def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok:
        FAILURES.append(what)


def finder_source():
    if SOURCE:
        return open(SOURCE, encoding="utf-8").read()
    return lua_from_release(modpaths.find(RELEASE), FOLDER)


def session():
    s = Session(backend=BACKEND)
    s.lua(CLOCK)
    s.lua("FAKE.mission()")
    return s


def load(s, names, flush=True):
    # flush: the finder writes each log line at once (v0.5.0 and before) so a
    # case can read it on the next frame; without it lines wait up to 10 s.
    if flush:
        s.lua("__mlf_test_flush = true")
    for name in names:
        if name == "finder":
            ok = s.load_mod(source=finder_source(),
                            name="mods/patpatpatrick/mod_lag_finder")
        else:
            ok = s.load_mod(source=MODS[name], name="mods/test/" + name)
        check(ok, "%s loads" % name)


def log_lines(s, pattern):
    return [l for l in (s.file(LOG, "") or "").splitlines() if re.search(pattern, l)]


def clean(s, label):
    r = s.report()
    # A refused ffi is the no-native path (the gate treats it the same way).
    policy = [p for p in r["policy"] if p["what"] not in FFI_DOORS]
    errors = [e for e in r["errors"] if "ffi is blocked" not in e["error"]]
    check(not r["dead"] and not r["uncaught"] and not r["nonexistent"]
          and not policy and not errors,
          "%s: nothing dies, escapes or is swallowed (%s)"
          % (label, s.explain(r).replace("\n", " | ")))


def chain(s):
    """The last chain map in the log, as [(index, label, via, notes)]."""
    text = (s.file(LOG, "") or "").splitlines()
    start = max((i for i, l in enumerate(text) if "chain mapped:" in l), default=None)
    if start is None:
        return []
    out = []
    for line in text[start + 1:]:
        m = re.match(r"t=\S+\s+#(\d+) (\S+) via (\S+)(?:\s+\[(.*)\])?$", line)
        if not m:
            break
        out.append((int(m.group(1)), m.group(2), m.group(3), m.group(4) or ""))
    return out


def map_case():
    print("map")
    with session() as s:
        load(s, ["heavy", "std", "stripped_lib", "stripped", "finder", "maelstrom",
                 "field"])
        s.frames(600)
        links = chain(s)
        labels = [l[1].split(":")[0] for l in links]
        check(labels == ["mods/patpatpatrick/mod_lag_finder", "mods/test/field",
                         "mods/test/maelstrom", "mods/test/stripped",
                         "mods/test/stripped_lib", "mods/test/std", "mods/test/heavy",
                         "hd2fake/engine"],
              "every link in order: %r" % labels)
        by = {l[1].split(":")[0]: l for l in links}
        none = (0, "", "", "")
        check(by.get("mods/test/maelstrom", none)[2] == "M.prev",
              "field's previous found in its table: %r" % (by.get("mods/test/maelstrom"),))
        check(by.get("mods/test/stripped", none)[2] == "original_update",
              "maelstrom's previous by its upvalue: %r" % (by.get("mods/test/stripped"),))
        check(by.get("mods/patpatpatrick/mod_lag_finder", none)[2] == "_G.update",
              "armed on the first frame, above every mod that hooked while loading")
        check(by.get("mods/test/stripped_lib", none)[2] == "(stripped)"
              and "by time" not in by.get("mods/test/stripped_lib", none)[3],
              "stripped's previous (no names) chosen over its own-file helper by "
              "source, no timing needed: %r" % (by.get("mods/test/stripped_lib"),))
        check(by.get("mods/test/std", none)[2] == "(stripped)"
              and "chosen of 2 by time" in by.get("mods/test/std", none)[3],
              "stripped_lib's previous (no names, helper from another file) chosen "
              "by time: %r" % (by.get("mods/test/std"),))
        check(by.get("mods/test/heavy", none)[2] == "previous_update"
              and "by time" not in by.get("mods/test/heavy", none)[3],
              "std's previous_update chosen over its tick(dt) by name: %r"
              % (by.get("mods/test/heavy"),))
        check("bottom: game" in by.get("hd2fake/engine", none)[3],
              "stops at the game: %r" % (by.get("hd2fake/engine"),))
        check("this module" in by.get("mods/patpatpatrick/mod_lag_finder", none)[3],
              "knows which link is itself")
        s.frames(2400)                         # past the first 60 s summary
        summary = log_lines(s, r"^t=\S+\s+mods/test/heavy\s")
        cost = float(re.search(r"(\d+\.\d+) ms/s", summary[0]).group(1)) if summary else -1
        check(200 <= cost <= 280, "heavy costs 5 ms of a 21 ms frame (~238 ms/s): %r"
              % summary[:1])
        clean(s, "map")


def retry_case():
    print("retry")
    with session() as s:
        load(s, ["heavy", "hiccup", "finder"])
        s.frames(200)
        labels = [l[1].split(":")[0] for l in chain(s)]
        check(labels == ["mods/patpatpatrick/mod_lag_finder", "mods/test/hiccup",
                         "mods/test/heavy", "hd2fake/engine"],
              "a link whose first watch fails is watched once more: %r" % labels)
        clean(s, "retry")


def stall_case():
    """In game (v0.2.0, 2026-09-29 10:36) a 590 ms and a 1389 ms stall
    outside Lua each made the finder AND Speed Dial think they had fallen
    out of the chain (0.5 s heartbeat): they re-armed above each other and
    the chain grew by two links a stall. Reproduced here as it happened:
    the stall is before the frame (the engine's), main_world is called 20
    times a frame (30-odd mods call it in game; the fake's default is 2,
    too few for the 8-call wait to run out inside one frame), and Shader
    Cache Hint Probe v1, as shipped, has the same 0.5 s rule and hooks after
    the finder, as Speed Dial's re-arm did."""
    print("stall")
    probe = lua_from_release(modpaths.find("Shader Cache Hint Probe v1"),
                             "Shader Cache Hint Probe")
    with Session(backend=BACKEND, engine_main_world_calls=20) as s:
        s.lua(CLOCK)
        s.lua("FREEZE_AT = {}\n"
              "FAKE.before_frame = function(frame)\n"
              "  CLOCK = CLOCK + 0.016\n"
              "  if FREEZE_AT[frame] then CLOCK = CLOCK + 1.5; FAKE.time = FAKE.time + 1.5 end\n"
              "end")
        s.lua("FAKE.mission()")
        load(s, ["heavy", "finder"])
        s.frames(40)
        s.load_mod(source=probe, name="mods/patpatpatrick/shader_cache_probe")
        s.frames(60)
        before = chain(s)
        s.lua("FREEZE_AT[FAKE.frame + 10] = true FREEZE_AT[FAKE.frame + 110] = true "
              "FREEZE_AT[FAKE.frame + 210] = true")
        s.frames(300)
        arms = log_lines(s, "update armed generation")
        after = chain(s)
        check(len(arms) == 1, "three 1.5 s stalls re-arm nothing: %r" % arms)
        check(len(after) == len(before) == 4,
              "the chain stays %d links: %d" % (len(before), len(after)))
        probe_arms = [l for l in (s.file("shader_cache_probe.log", "") or "").splitlines()
                      if "update armed" in l]
        check(len(probe_arms) == 1, "and the other mod has no reason to either: %r" % probe_arms)
        check(log_lines(s, "rehook:") == [], "no re-hook to report")
        clean(s, "stall")


def rehook_case():
    """Two mods of someone else's (here: two of ours as shipped, both still
    on the 0.5 s-only rule) fight over the top during engine stalls. The
    finder does not join in, sees them hooked 3+ times and says so."""
    print("rehook")
    mortar = lua_from_release(modpaths.find("Mortar Impact Light v0.1.15"),
                              "Mortar Impact Light")
    probe = lua_from_release(modpaths.find("Shader Cache Hint Probe v1"),
                             "Shader Cache Hint Probe")
    with Session(backend=BACKEND, engine_main_world_calls=20) as s:
        s.lua(CLOCK)
        s.lua("FREEZE_AT = {}\n"
              "FAKE.before_frame = function(frame)\n"
              "  CLOCK = CLOCK + 0.016\n"
              "  if FREEZE_AT[frame] then CLOCK = CLOCK + 1.5; FAKE.time = FAKE.time + 1.5 end\n"
              "end")
        s.lua("FAKE.mission()")
        s.lua(GUI_STUB)
        s.load_mod(source=mortar, name="mods/patpatpatrick/mortar_impact_light")
        s.load_mod(source=probe, name="mods/patpatpatrick/shader_cache_probe")
        load(s, ["finder"])
        s.frames(120)
        check(log_lines(s, "rehook:") == [] and s.eval("SHOWN()") == "",
              "one hook each: nothing to report")
        s.lua("for k = 1, 4 do FREEZE_AT[FAKE.frame + k * 150] = true end")
        found = None
        for _ in range(12):
            s.frames(50)
            shown = s.eval("SHOWN()")
            if "REHOOK" in shown:
                found = shown
                break
        lines = log_lines(s, "rehook:")
        check(bool(lines) and "mortar_impact_light x" in lines[0]
              and "shader_cache_probe x" in lines[0],
              "the log names both mods and how often each is hooked: %r" % lines[:1])
        check(found is not None and re.search(r"REHOOK (mortar_impact_light|shader_cache_probe) x\d, "
                                              r"(mortar_impact_light|shader_cache_probe) x\d \(chain \d+\)",
                                              found) is not None,
              "an amber line on screen names them: %r" % found)
        arms = log_lines(s, "update armed generation")
        check(len(arms) == 1, "the finder itself never joins in: %r" % arms)
        s.lua("FAKE.press('home')")
        s.frames(3)
        check("hooked more than once: " in s.eval("SHOWN()"),
              "the window lists them too: %r" % s.eval("SHOWN()"))
        check(s.eval("GUI_BAD") == "0", "never a GUI call into a gone world")
        clean(s, "rehook")

MDL_STUB = r"""
-- MDL 1.0.5-p11's contract as its session shipped it: MDL.perf == 1; each
-- record of MDL.manager.mods that runs gets perf = { total, last, frames };
-- last is reset every manager.frame for records that have perf, then set if
-- the record ran. This stand-in runs its records inside its own link as MDL
-- does, and spends 1 ms of its own.
MDL = { perf = 1, manager = { mods = {
  { id = "arsenal:b0aa8e22-956d-4c7d-973c-937085f9c0d8",
    info = { name = "HD2 C4 Quick Actions 1.11" }, cost = 0.004 },
  { id = "loose_cn", info = { name = "\228\184\173\230\150\135" }, cost = 0.002 },
  { id = "idle", info = { name = "Idle" } },
} } }
"""

MDL_RUNTIME = r"""
local previous = rawget(_G, "update")
local n = 0
rawset(_G, "update", function(...)
  n = n + 1
  CLOCK = CLOCK + 0.001
  for _, r in ipairs(MDL.manager.mods) do
    if r.perf then r.perf.last = 0 end
    if r.cost then
      r.perf = r.perf or { total = 0, last = 0, frames = 0 }
      local spend = r.cost
      if r.stall_at == n then spend = spend + 0.4 end
      CLOCK = CLOCK + spend
      r.perf.last = spend
      r.perf.total = r.perf.total + spend
      r.perf.frames = r.perf.frames + 1
    end
  end
  return previous(...)
end)
"""


def lua_archive(sources, names=None):
    """A Lua archive as the builders write one: header, type table, file
    table (name, type, offset ... size at +56), then each payload with its
    8-byte length/flag prefix. With names, each row's name is
    murmur64(name) as in a real archive; without, a placeholder."""
    import struct
    lua_t = 0xA14E8DFA2CD117E2
    types, files = 1, len(sources)
    head = bytearray(0x48 + types * 32 + files * 80)
    struct.pack_into("<III", head, 0, 0xF0000011, types, files)
    struct.pack_into("<Q", head, 0x48 + 8, lua_t)
    body = bytearray()
    for index, source in enumerate(sources):
        payload = struct.pack("<2I", len(source), 2) + source.encode("utf-8")
        row = 0x48 + types * 32 + index * 80
        fid = murmur64_hash(names[index].encode("utf-8")) if names else 0x1000 + index
        struct.pack_into("<3Q", head, row, fid, lua_t, len(head) + len(body))
        struct.pack_into("<I", head, row + 56, len(payload))
        body += payload
    return bytes(head + body)


def names_case():
    """Each mod under its name in Arsenal: the active profile's enabled mods
    and options, matched through the "-- HD2-Addon:" line of each Lua
    resource. Versions, brackets and download tails are dropped, long names
    are cut to the window's column, a non-ASCII name keeps the short name
    (the debug font is Latin only), and so do disabled mods and options, two
    addons that would share a name, and anything when Arsenal's list is bad."""
    import json
    print("names")
    scratch = tempfile.mkdtemp(prefix="mlf_names_")
    root = os.path.join(scratch, "Arsenal Mods")
    arsenal = os.path.join(scratch, "hd2arsenal")
    os.makedirs(arsenal)

    def archive(folder, *addons):
        os.makedirs(folder, exist_ok=True)
        with open(os.path.join(folder, "9ba626afa44a3aa3.patch_0"), "wb") as f:
            f.write(lua_archive(["-- HD2-Addon: %s\nreturn {}\n" % a for a in addons]))

    def mod(label, folder, options, enabled=True):
        return {"label": label, "path": os.path.join(root, folder), "enabled": enabled,
                "options": [{"name": n, "enabled": e, "include": [inc], "suboptions": []}
                            for n, e, inc in options]}

    archive(os.path.join(root, "WMS_AR1", "Beacon"), "mods/test/slow")
    archive(os.path.join(root, "Whip_AR2", "Whip"), "mods/test/heavy")
    archive(os.path.join(root, "Off_AR3", "Main"), "mods/test/std")
    archive(os.path.join(root, "Pack_AR4", "options", "RowA"), "mods/test/pack", "mods/test/row_a")
    archive(os.path.join(root, "Pack_AR4", "options", "RowB"), "mods/test/pack", "mods/test/row_b")
    archive(os.path.join(root, "Pack_AR4", "options", "RowC"), "mods/test/pack", "mods/test/row_c")
    archive(os.path.join(root, "Long_AR5", "Addon"), "mods/test/long")
    archive(os.path.join(root, "Twin_AR6", "A"), "mods/test/twin_a")
    archive(os.path.join(root, "Twin2_AR7", "A"), "mods/test/twin_b")
    profile = {"label": "Test", "imagePath": None, "mods": [
        mod("Where's My Shit?  v0.11.6", "WMS_AR1", [("Beacon", True, "Beacon")]),
        mod("\u771f\u7406\u90e8\u4e4b\u97ad v0.3.0", "Whip_AR2", [("Whip", True, "Whip")]),
        mod("Off Mod", "Off_AR3", [("Main", True, "Main")], enabled=False),
        mod("Vanilla Plus Megapack Rows - v34", "Pack_AR4",
            [("Enemy Collision Synchronized", True, "options/RowA"),
             ("Know Your Constellation Rows", True, "options/RowB"),
             ("Row C", False, "options/RowC")]),
        mod("Tesla Tower & Lightning Spire Range Indicator 14815 1 2026-07-27T07-01Z QX",
            "Long_AR5", [("Addon", True, "Addon")]),
        mod("Twin 1.0", "Twin_AR6", [("A", True, "A")]),
        mod("Twin 2.0", "Twin2_AR7", [("A", True, "A")]),
    ]}
    data = {"selectedProfile": "p1", "modsList": {"default": {"label": "Default", "mods": []},
                                                  "p1": profile}}
    with open(os.path.join(arsenal, "hd2a_data.json"), "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)          # \u escapes for the Chinese label

    def game(frames=40, home=False):
        with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
            s.lua(CLOCK)
            s.lua("FAKE.mission()")
            s.lua(GUI_STUB)
            load(s, ["slow", "heavy", "std", "finder"])
            s.frames(frames)
            shown = ""
            if home:
                s.lua("FAKE.press('home')")
                s.frames(3)
                shown = s.eval("SHOWN()")
            text = (s.file(LOG, "") or "").split("== mod-lag-finder")[-1]
            clean(s, "names")
        return text, shown

    try:
        text, shown = game(frames=320, home=True)
        said = dict(re.findall(r"name: (\S+) = (.+)", text))
        want = {"mods/test/slow": "Where's My Shit?",
                "mods/test/heavy": "(short name)",
                "mods/test/pack": "Vanilla Plus Megapack Rows",
                "mods/test/row_a": "Enemy Collision Synchronized",
                "mods/test/row_b": "Know Your Constellation Rows",
                "mods/test/long": "Tesla Tower & Lightning..",
                "mods/test/twin_a": "(short name)",
                "mods/test/twin_b": "(short name)"}
        for addon, label in want.items():
            check(said.get(addon) == label, "%s is named %r: %r" % (addon, label, said.get(addon)))
        check("mods/test/std" not in said and "mods/test/row_c" not in said,
              "a disabled mod or option names nothing: %r" % sorted(said))
        check(re.search(r"names: 5 addons named from Arsenal \(7 Lua archives read\)", text) is not None,
              "the count is logged: %r" % [l for l in text.splitlines() if "names:" in l])
        check(re.search(r"LAG 4\d\d ms - Where's My Shit\?", shown) is not None,
              "the stall line names the mod as the manager does: %r" % shown)
        check(re.search(r"Where's My Shit\? +\d", shown) is not None and
              re.search(r"\|heavy +\d", shown) is not None,
              "the window too; the Chinese name keeps its short name: %r" % shown)
        check(re.search(r"\|std +\d", shown) is None and "+ 2 mods under 10 ms/s" in shown,
              "a mod under 10 ms/s is not listed, only counted (v0.8.1): %r" % shown)
        check(re.search(r"hitch 4\d\d ms.*mods/test/slow 400", text) is not None,
              "the log keeps the addon names: %r" % [l for l in text.splitlines() if "hitch" in l][:1])
        with open(os.path.join(arsenal, "hd2a_data.json"), "w", encoding="utf-8") as f:
            f.write('{"selectedProfile": "p1", "modsList": {"p1": {"mods": [')
        text, shown = game(frames=320, home=True)
        check(re.search(r"names: Arsenal mod list unreadable", text) is not None,
              "a broken list is said: %r" % [l for l in text.splitlines() if "names:" in l])
        check(re.search(r"LAG 4\d\d ms - slow", shown) is not None, "and short names are used: %r" % shown)
        os.remove(os.path.join(arsenal, "hd2a_data.json"))
        text, _ = game()
        check("names: no Arsenal mod list" in text, "no list: said, nothing else changes")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def mdl_case():
    """Scripts MDL runs live get their own rows, their time comes out of
    MDL's row, and a stall inside one is named by that script."""
    print("mdl")
    with session() as s:
        s.lua(GUI_STUB)
        s.lua(MDL_STUB)
        s.lua("MDL.manager.mods[1].stall_at = 300")
        s.load_mod(source=MDL_RUNTIME, name="mods/mdl/runtime")
        load(s, ["heavy", "finder"])
        s.frames(302)
        shown = s.eval("SHOWN()")
        check(re.search(r"LAG 4\d\d ms - mdl: HD2 C4 Quick Actions 1\b", shown) is not None,
              "a stall inside a live script names that script, not MDL: %r" % shown)
        hitch = log_lines(s, r"hitch 4\d\d ms")
        check(bool(hitch) and "mdl: HD2 C4 Quick Actions 1 4" in hitch[0],
              "and so does the log: %r" % hitch[:1])
        s.frames(2700)                       # past the 60 s summary
        rows = {m.group(1).strip(): float(m.group(2)) for m in
                (re.match(r"^t=\S+\s+(.+?)\s+(\d+\.\d+) ms/s", l)
                 for l in log_lines(s, r"ms/s")) if m}
        c4 = rows.get("mdl: HD2 C4 Quick Actions 1", -1)
        cn = rows.get("mdl: loose_cn", -1)
        runtime = rows.get("mods/mdl/runtime", -1)
        check(125 <= c4 <= 165, "the C4 script costs 4 ms of a 28 ms frame (~143 ms/s): %s" % c4)
        check(55 <= cn <= 85, "a name the font cannot draw falls back to the id (~71 ms/s): %s %r"
              % (cn, sorted(rows)))
        check(0 <= runtime <= 50, "MDL's own row keeps only its 1 ms (~36 ms/s): %s" % runtime)
        check("mdl: Idle" not in rows, "a script that never ran has no row")
        clean(s, "mdl")


def deploy_case():
    """Which game since the last Arsenal deploy: read from Arsenal's
    deployment_snapshot.json "timestamp", counted in mod_lag_finder_state.txt;
    each game ends with its stall totals."""
    import datetime
    print("deploy")
    scratch = tempfile.mkdtemp(prefix="mlf_deploy_")
    arsenal = os.path.join(scratch, "hd2arsenal")
    os.makedirs(arsenal)

    def snapshot(ms):
        with open(os.path.join(arsenal, "deployment_snapshot.json"), "w") as f:
            f.write('{"timestamp":%d,"deployedMods":[],"deployedFiles":[]}' % ms)

    def game(frames=40, mods=("finder",), home=False):
        with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
            s.lua(CLOCK)
            s.lua("FAKE.mission()")
            s.lua(GUI_STUB)
            load(s, list(mods))
            s.frames(frames)
            shown = ""
            if home:
                s.lua("FAKE.press('home')")
                s.frames(3)
                shown = s.eval("SHOWN()")
            s.lua("FAKE.shutdown()")
            text = s.file(LOG, "") or ""
            clean(s, "deploy game")
        session = text.split("== mod-lag-finder")[-1]
        return session, shown

    try:
        first_ms = 1790648025264
        when = datetime.datetime.fromtimestamp(first_ms / 1000).strftime("%Y-%m-%d %H:%M:%S")
        snapshot(first_ms)
        one, _ = game()
        check(("deploy: Arsenal deployed at %s; this is game #1 since it" % when) in one,
              "the first game after a deploy is #1, with the deploy's local time: %r"
              % [l for l in one.splitlines() if "deploy" in l])
        two, shown = game(mods=("slow", "finder"), frames=700, home=True)
        check("this is game #2 since it" in two, "the next game after the same deploy is #2")
        check(re.search(r"game #2 after the \d\d:\d\d deploy", shown) is not None,
              "the window says it too: %r" % shown)
        over = [l for l in two.splitlines() if "game over:" in l]
        check(len(over) == 1 and "game #2 since the deploy of %s" % when in over[0]
              and "stalls >= 200 ms: 2 (" in over[0],
              "the game ends with its number and its stalls: %r" % over)
        snapshot(first_ms + 3600 * 1000)
        three, _ = game()
        check("this is game #1 since it" in three, "a new deploy starts again at #1")
        os.remove(os.path.join(arsenal, "deployment_snapshot.json"))
        four, _ = game()
        check("deploy: no Arsenal deployment snapshot" in four,
              "no snapshot: said once, nothing else breaks")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


WRITE_STUB = r"""
-- A log write that takes 500 ms when SLOW_WRITE is set. A process list is
-- offered through the seam only to see that it is never asked for.
PROCESSES_ASKED = 0
__hd2_native_test = { cores = 16, pid = 4968, processes = function()
  PROCESSES_ASKED = PROCESSES_ASKED + 1
  return {}
end }
local open = io.open
io.open = function(path, mode)
  if SLOW_WRITE and string.find(path, "mod_lag_finder.log", 1, true) then
    CLOCK = CLOCK + SLOW_WRITE
  end
  return open(path, mode)
end
"""


def writes_case():
    """Log lines wait in memory and are written together every 10 s, so a
    slow write stalls one frame every 10 s instead of making each stall's
    own line cause the next one (v0.5.0: 60 stalls in 30 s here). The
    slowest write shows in the window and the 60 s summary. No process list
    is read and nothing about GameGuard is said."""
    print("writes")
    with session() as s:
        s.lua(GUI_STUB)
        s.lua(WRITE_STUB)
        load(s, ["slow", "finder"], flush=False)
        check(bool(log_lines(s, "installed; frames of")), "the lines said while loading are written at once")
        s.frames(320)                       # slow stalls at 300, t ~ 5 s
        check(not log_lines(s, r"hitch 4\d\d ms"), "a stall's line waits in memory")
        s.frames(400)                       # t ~ 12 s
        stall = log_lines(s, r"hitch 4\d\d ms")
        check(bool(stall), "and is written within 10 s")
        check(bool(stall) and "GameGuard" not in stall[0],
              "a stall line says nothing about GameGuard: %r" % stall[:1])
        s.lua("FAKE.press('home')")
        s.frames(3)
        shown = s.eval("SHOWN()")
        check("slowest log write: 0 ms" in shown, "the window shows the slowest log write: %r" % shown)
        check("GameGuard" not in shown, "and nothing about GameGuard: %r" % shown)
        s.frames(1500)                      # t ~ 36 s
        s.lua("SLOW_WRITE = 0.5")           # every write takes 500 ms from here
        s.frames(1250)                      # ~ 20 s of frames
        shown = s.eval("SHOWN()")
        check(re.search(r"slowest log write: 5\d\d ms", shown) is not None,
              "a 500 ms log write shows: %r" % shown)
        stalls = int(re.search(r"stalls >= \d+ ms: (\d+)", shown).group(1))
        check(stalls <= 8, "30 s of 500 ms writes: the slow mod's stalls plus one "
                           "write every 10 s, not a chain (%d stalls): %r" % (stalls, shown))
        s.lua("SLOW_WRITE = nil")
        s.frames(600)                       # past the 60 s summary
        worst = log_lines(s, r"log write worst 5\d\d ms")
        check(bool(worst), "the summary has the slowest log write: %r" % log_lines(s, "log write worst")[:2])
        check(s.eval("tostring(PROCESSES_ASKED)") == "0", "no process list is read")
        check(not log_lines(s, "anti-cheat|GameGuard"), "nothing about the anti-cheat is logged")
        clean(s, "writes")


def top_case():
    print("top")
    with session() as s:
        load(s, ["heavy", "std", "finder"])
        s.frames(30)
        load(s, ["slow"])                      # hooks later, as a re-arm does
        s.frames(700)
        hitches = log_lines(s, r"hitch 4\d\d ms")
        check(len(hitches) == 2, "two 400 ms frames reported: %r" % hitches)
        check(bool(hitches) and re.search(r"not explained 4\d\d ms \(top mods/test/slow", hitches[-1]),
              "the stall is not explained and the top is named: %r" % hitches[-1:])
        clean(s, "top")


def inside_case():
    print("inside")
    with session() as s:
        load(s, ["slow", "finder", "std"])
        s.frames(3700)
        hitches = log_lines(s, r"hitch 4\d\d ms")
        check(len(hitches) >= 10, "the 400 ms frames are reported: %d" % len(hitches))
        attributed = [h for h in hitches if re.search(r": mods/test/slow 4\d\d,", h)]
        check(len(attributed) == len(hitches) and hitches,
              "each is charged to slow by name: %r" % hitches[:2])
        rows = log_lines(s, r"^t=\S+\s+(mods/|\(the game\))")
        check(bool(rows) and rows[0].split()[1] == "mods/test/slow",
              "slow heads the summary: %r" % rows[:3])
        clean(s, "inside")


def same_case():
    print("same")
    counts = {}
    for with_finder in (False, True):
        with session() as s:
            names = ["heavy", "std", "stripped_lib", "stripped", "maelstrom", "field"]
            if with_finder:
                names.insert(3, "finder")
            load(s, names)
            s.frames(500)
            s.lua("RET = { update(0.016) }; RET_N = #RET")
            counts[with_finder] = s.eval(
                "string.format('%d %d %d %d %d %d', COUNTS.heavy, COUNTS.std, "
                "COUNTS.stripped_lib, COUNTS.stripped, COUNTS.maelstrom, COUNTS.field)")
            check(s.eval("RET_N") == "0", "update returns what the game's returns")
            clean(s, "same finder=%s" % with_finder)
    check(counts[False] == counts[True],
          "every mod's work ran as often with the finder as without: %r" % counts)


def restore_case():
    print("restore")
    with session() as s:
        load(s, ["heavy", "std", "finder"])
        s.frames(200)
        before = chain(s)
        check(len(before) == 4, "mapped before: %r %r" % (before, log_lines(s, "bottom at")))
        check(s.eval("tostring(UV(T.std.wrapper, 'previous_update') ~= T.std.prev)")
              == "true", "std's previous slot holds a shim while mapped")
        s.lua("FAKE.transition({ gap = 120 })")
        s.frames(300)
        check(s.eval("tostring(UV(T.std.wrapper, 'previous_update') == T.std.prev)")
              == "true", "the old chain's slot has its original back")
        after = chain(s)
        check([l[1].split(":")[0] for l in after] ==
              ["mods/patpatpatrick/mod_lag_finder", "hd2fake/engine"],
              "the new chain is mapped: %r" % after)
        clean(s, "restore")


def real_case():
    print("real")
    with session() as s:
        s.load_mod(source=lua_from_release(modpaths.find("Mortar Impact Light v0.1.15"),
                                           "Mortar Impact Light"),
                   name="mods/patpatpatrick/mortar_impact_light")
        s.lua("__mlf_test_flush = true")
        s.load_mod(source=finder_source(), name="mods/patpatpatrick/mod_lag_finder")
        s.load_mod(source=lua_from_release(modpaths.find("Shader Cache Hint Probe v1"),
                                           "Shader Cache Hint Probe"),
                   name="mods/patpatpatrick/shader_cache_probe")
        s.frames(600)
        labels = [l[1].split(":")[0] for l in chain(s)]
        check(labels == ["mods/patpatpatrick/mod_lag_finder",
                         "mods/patpatpatrick/shader_cache_probe",
                         "mods/patpatpatrick/mortar_impact_light", "hd2fake/engine"],
              "both mapped by source: %r" % labels)
        r = s.report()
        check(not r["dead"] and not r["uncaught"], "nothing dies (%s)"
              % s.explain(r).replace("\n", " | "))


GUI_STUB = r"""
-- The fake does not model screen GUIs or the mouse (as in test_mdl_runtime.py):
-- these stand-ins keep what is on screen per GUI, and count any call into a
-- world that Application.worlds() no longer lists -- in game that is the crash.
UIW = FAKE.add_world("ui", false)
GUIS, GUI_MADE, GUI_BAD, GUI_CALLS = {}, 0, 0, 0
local V3 = stingray.Vector3
local function alive(w)
  for _, x in ipairs(stingray.Application.worlds()) do if x == w then return true end end
  return false
end
local function touch(w)
  GUI_CALLS = GUI_CALLS + 1
  if not alive(w) then GUI_BAD = GUI_BAD + 1 end
end
stingray.World.create_screen_gui = function(w, ...)
  touch(w)
  GUI_MADE = GUI_MADE + 1
  local g = { world = w, texts = {}, rects = 0 }
  GUIS[#GUIS + 1] = g
  return g
end
stingray.World.destroy_gui = function(w, g) touch(w); g.dead = true end
stingray.Gui.text = function(g, text, font, size, material, pos, col)
  touch(g.world)
  g.texts[#g.texts + 1] = { text = text, x = V3.x(pos), y = V3.y(pos) }
  return #g.texts
end
stingray.Gui.rect = function(g, pos, size, col) touch(g.world); g.rects = g.rects + 1 end
stingray.Gui.resolution = function() return 1920, 1080 end
local function live_guis()
  local out = {}
  for _, g in ipairs(GUIS) do
    if not g.dead and alive(g.world) then out[#out + 1] = g end
  end
  return out
end
function SHOWN()
  local seen, out = {}, {}
  for _, g in ipairs(live_guis()) do
    for _, t in ipairs(g.texts) do
      if not seen[t.text] then seen[t.text] = true; out[#out + 1] = t.text end
    end
  end
  table.sort(out)
  return table.concat(out, "|")
end
-- The last match: a shadowed line is drawn twice, the shadow (+1,-1) first.
function POS(prefix)
  local found = "none"
  for _, g in ipairs(live_guis()) do
    for _, t in ipairs(g.texts) do
      if string.sub(t.text, 1, #prefix) == prefix then
        found = string.format("%.0f,%.0f", t.x, t.y)
      end
    end
  end
  return found
end
function LIVE_COUNT() return #live_guis() end
function RECTS()
  local n = 0
  for _, g in ipairs(live_guis()) do n = n + g.rects end
  return n
end
function DROP_UI()
  for i, w in ipairs(FAKE.worlds) do
    if w == UIW then table.remove(FAKE.worlds, i); break end
  end
end
MOUSE = { x = 0, y = 0, held = {}, at = {} }
stingray.Mouse.axis_id = function(name) if name == "cursor" then return 1 end end
stingray.Mouse.button_id = function(name)
  if name == "left" then return 1 elseif name == "right" then return 2 end
end
stingray.Mouse.axis = function(id) return V3(MOUSE.x, MOUSE.y, 0) end
stingray.Mouse.pressed = function(id) return MOUSE.at[id] == FAKE.frame end
stingray.Mouse.button = function(id) return MOUSE.held[id] and 1 or 0 end
function PRESS(id) MOUSE.at[id] = FAKE.frame + 1; MOUSE.held[id] = true end
function RELEASE(id) MOUSE.held[id] = false end
"""

# The game's UI state as MDL reads it on this build (offsets are the mod's
# own, so they are not tested here -- only the game can): *(game+0x347ce28)
# -> five u32 screen types at +0x429c and their count; escape menu = 1;
# *(*(game+0x347ce38)+200) -> the escape screen, its tab at +1248+57452.
MENU_STUB = r"""
local N = FAKE.native
BASE = 0x7FF600000000
N.module("game.dll", BASE, { stamp = %(stamp)s, image_size = 0x4744000 })
N.map(BASE + 0x347C000, 0x2000)
UI_STATE, MENU_OBJ, SCREEN = 0x20000000, 0x21000000, 0x22000000
N.map(UI_STATE, 0x5000); N.map(MENU_OBJ, 0x1000); N.map(SCREEN, 0x10000)
N.write(BASE + 0x347CE28, N.u64(UI_STATE))
N.write(BASE + 0x347CE38, N.u64(MENU_OBJ))
N.write(MENU_OBJ + 200, N.u64(SCREEN))
function MENU_STATE(top, tab)
  local words = {}
  for i = 1, 5 do words[i] = N.u32(i == 2 and top or 9) end
  N.write(UI_STATE + 0x429C, table.concat(words) .. N.u32(2))
  N.write(SCREEN + 1248 + 57452, N.u32(tab))
end
MENU_STATE(4, 0)                     -- in play: the escape menu is not on top
__hd2_native_test = N.seam()
"""


def menu_stub(stamp="0x6AB3B43F"):
    return MENU_STUB % {"stamp": stamp}


def screen_case():
    print("screen")
    with session() as s:
        s.lua(GUI_STUB)
        load(s, ["slow", "heavy", "finder"])
        s.frames(290)
        check(s.eval("GUI_CALLS") == "0", "nothing drawn and no GUI made while nothing is due")
        s.frames(15)                          # slow's first stall, reported a frame later
        shown = s.eval("SHOWN()")
        check(re.search(r"LAG 4\d\d ms - slow", shown) is not None,
              "a stall in one mod shows its line: %r" % shown)
        s.frames(260)                         # > 5 s later, before the next stall
        check(s.eval("SHOWN()") == "", "the line goes after 5 s: %r" % s.eval("SHOWN()"))

        s.lua("FAKE.press('home')")
        s.frames(3)
        shown = s.eval("SHOWN()")
        check("MOD LAG WATCHDOG" not in shown and s.eval("RECTS()") == "0"
              and re.search(r"heavy\s+\d+\.\d\s+\d+ ms", shown)
              and re.search(r"slow\s+\d+\.\d\s+4\d\d ms", shown)
              and "last stall 4" in shown and "in slow" in shown and "[Home] close" not in shown,
              "in play Home shows the lines alone (no title, no background, no footer): "
              "each mod's cost and the last stall: %r" % shown)

        s.lua("DROP_UI()")                    # the UI world goes away
        s.frames(120)
        check(s.eval("GUI_BAD") == "0", "no GUI call into the world that went")
        s.lua("UIW = FAKE.add_world('ui2', false)")
        s.frames(90)
        check("ms/s" in s.eval("SHOWN()"),
              "a new UI world gets a new GUI and the lines again")
        check(s.eval("LIVE_COUNT()") == "1", "one GUI at a time: %s" % s.eval("LIVE_COUNT()"))

        s.lua("FAKE.press('home')")
        s.frames(3)
        check("ms/s" not in s.eval("SHOWN()"),
              "Home again closes the window (a stall line may still be up): %r"
              % s.eval("SHOWN()"))
        check(s.eval("GUI_BAD") == "0", "never a GUI call into a gone world")
        check(bool(log_lines(s, r"escape menu window off \(Home still works\)")),
              "without the native layer the menu window is off, and says so")
        clean(s, "screen")


def quiet_case():
    print("quiet")
    with session() as s:
        s.lua(GUI_STUB)
        load(s, ["heavy", "std", "finder"])
        s.frames(30)
        load(s, ["slow"])                     # on top: its stalls are in no measured mod
        s.frames(700)
        check(s.eval("GUI_CALLS") == "0",
              "a stall outside every measured mod shows nothing (%s GUI calls)"
              % s.eval("GUI_CALLS"))
        check(bool(log_lines(s, r"hitch 4\d\d ms")), "but it is logged")
        clean(s, "quiet")


def menu_case():
    print("menu")
    scratch = tempfile.mkdtemp(prefix="mlf_menu_")
    try:
        with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
            s.lua(CLOCK)
            s.lua("FAKE.mission()")
            s.lua(GUI_STUB)
            s.lua(menu_stub())
            load(s, ["heavy", "finder"])
            s.frames(120)
            check(bool(log_lines(s, "escape menu window on: game.dll build matches")),
                  "the build pin matches")
            check(s.eval("GUI_CALLS") == "0", "in play with nothing due: nothing drawn")

            s.lua("MENU_STATE(1, 2)")          # escape menu, OPTIONS tab
            s.frames(10)
            check(s.eval("SHOWN()") == "", "not on another tab of the menu")
            s.lua("MENU_STATE(1, 0)")          # GAME tab
            s.frames(2)
            check(s.eval("SHOWN()") == "", "not before the GAME tab has held 3 frames")
            s.frames(3)
            shown = s.eval("SHOWN()")
            check("MOD LAG WATCHDOG" in shown and "drag the title bar" in shown,
                  "on the GAME tab the window shows by itself: %r" % shown)
            title = s.eval("POS('MOD LAG WATCHDOG')")
            check(title == "1064,600", "at the default place (1056,620; title 8 px in, 8 px up from the bar's bottom): %s" % title)

            # Drag the title bar 200 px left and 100 px down.
            s.lua("MOUSE.x, MOUSE.y = 1100, 605; PRESS(1)")
            s.frames(2)
            s.lua("MOUSE.x, MOUSE.y = 1000, 555")
            s.frames(2)
            s.lua("MOUSE.x, MOUSE.y = 900, 505")
            s.frames(2)
            check(s.eval("POS('MOD LAG WATCHDOG')") == "864,500",
                  "the window follows the mouse: %s" % s.eval("POS('MOD LAG WATCHDOG')"))
            s.lua("RELEASE(1)")
            s.frames(2)
            check((s.file("mod_lag_finder_window.txt") or "").strip() == "856 520 0 1",
                  "the place is saved when the button is let go: %r"
                  % s.file("mod_lag_finder_window.txt"))

            s.lua("MOUSE.x, MOUSE.y = 100, 100; PRESS(1)")   # a click elsewhere
            s.frames(2)
            s.lua("MOUSE.x, MOUSE.y = 300, 300")
            s.frames(2)
            s.lua("RELEASE(1)")
            s.frames(2)
            check(s.eval("POS('MOD LAG WATCHDOG')") == "864,500",
                  "a drag that does not start on the title bar moves nothing")

            menu_line = s.eval("POS('last ')")    # the first line, on the menu
            s.lua("MENU_STATE(4, 0)")          # back to play
            s.frames(3)
            check(s.eval("SHOWN()") == "", "leaving the menu hides it")
            s.lua("FAKE.press('home')")
            s.frames(3)
            check(s.eval("POS('last ')") == menu_line != "none" and s.eval("RECTS()") == "0"
                  and "MOD LAG WATCHDOG" not in s.eval("SHOWN()"),
                  "in play Home shows the lines exactly where they were on the menu "
                  "(%s), without title or background: %s" % (menu_line, s.eval("POS('last ')")))
            s.lua("FAKE.press('home')")
            s.frames(3)
            check(s.eval("GUI_BAD") == "0", "never a GUI call into a gone world")
            clean(s, "menu")

        # A new game: the place comes back from the file.
        with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
            s.lua(CLOCK)
            s.lua("FAKE.mission()")
            s.lua(GUI_STUB)
            s.lua(menu_stub())
            load(s, ["finder"])
            s.frames(60)
            s.lua("MENU_STATE(1, 0)")
            s.frames(6)
            check(s.eval("POS('MOD LAG WATCHDOG')") == "864,500",
                  "the next game opens it at the saved place: %s"
                  % s.eval("POS('MOD LAG WATCHDOG')"))
            s.lua("MOUSE.x, MOUSE.y = 900, 505; PRESS(2)")   # right-click the title
            s.frames(3)
            check(s.eval("POS('MOD LAG WATCHDOG')") == "1064,600"
                  and (s.file("mod_lag_finder_window.txt") or "").strip().startswith("1056 620"),
                  "right-clicking the title bar puts it back: %s"
                  % s.eval("POS('MOD LAG WATCHDOG')"))
            clean(s, "menu reload")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def patched_case():
    print("patched")
    with session() as s:
        s.lua(GUI_STUB)
        s.lua(menu_stub(stamp="0x6AB4B43F"))      # another game.dll build
        load(s, ["heavy", "finder"])
        s.frames(60)
        s.lua("MENU_STATE(1, 0)")
        s.frames(10)
        check(s.eval("SHOWN()") == "", "on another build the menu shows nothing")
        check(bool(log_lines(s, r"escape menu window off \(Home still works\): game\.dll stamp")),
              "and the log says why")
        s.lua("FAKE.press('home')")
        s.frames(3)
        check("ms/s" in s.eval("SHOWN()"), "Home still works")
        clean(s, "patched")


NATIVE_STAND_IN = r"""
local ffi = require("ffi")
local kernel = ffi.load("kernel32")
pcall(ffi.cdef, "void *LoadLibraryA(const char *name);")
STAND_IN = kernel.LoadLibraryA(%s)
assert(STAND_IN ~= nil, "the stand-in game.dll did not load")
"""


SPIN = r"""
-- Real work: each frame spins for 0.3 ms of real time (read with its own
-- QueryPerformanceCounter), so the finder's timer has something true to find.
local ffi = require("ffi")
pcall(ffi.cdef, "int QueryPerformanceCounter(int64_t *count);")
pcall(ffi.cdef, "int QueryPerformanceFrequency(int64_t *frequency);")
local kernel = ffi.load("kernel32")
local qpc = ffi.cast("int (*)(void *)", kernel.QueryPerformanceCounter)
local qpf = ffi.cast("int (*)(void *)", kernel.QueryPerformanceFrequency)
local w = ffi.new("uint32_t[2]")
qpf(w)
local frequency = w[1] * 4294967296 + w[0]
local function seconds() qpc(w) return (w[1] * 4294967296 + w[0]) / frequency end
local previous = rawget(_G, "update")
rawset(_G, "update", function(...)
  local stop = seconds() + 0.0003
  while seconds() < stop do end
  return previous(...)
end)
"""


MEM_MODS = {
    # Two 100-byte strings a frame into a table it never clears: a leak.
    "leaky": r"""
local previous = rawget(_G, "update")
local store, n = {}, 0
rawset(_G, "update", function(...)
  n = n + 1
  store[n] = string.rep("x", 100) .. n
  n = n + 1
  store[n] = string.rep("y", 100) .. n
  return previous(...)
end)
""",
    # A big table that stays the same size: busy, but no leak.
    "steady": r"""
local previous = rawget(_G, "update")
local store, k = {}, 0
for i = 1, 3000 do store[i] = i end
rawset(_G, "update", function(...)
  k = k % 3000 + 1
  store[k] = store[k] + 1
  return previous(...)
end)
""",
    # Grows fast for 5 minutes, then clears: grows a lot, but not only grows.
    "wave": r"""
local previous = rawget(_G, "update")
local store, n = {}, 0
rawset(_G, "update", function(...)
  n = n + 1
  for i = 1, 8 do store[#store + 1] = n end
  if n % 1200 == 0 then store = {} end
  return previous(...)
end)
""",
    # Per-mission data, like Where's My Shit? in game (v0.9.0, 2026-09-30):
    # grows all mission long and is cleared when the world changes.
    "mission": r"""
local previous = rawget(_G, "update")
local store, world = {}, nil
rawset(_G, "update", function(...)
  local now = stingray.Application.main_world()
  if now ~= world then world, store = now, {} end
  for i = 1, 4 do store[#store + 1] = i end
  return previous(...)
end)
""",
    # Hooks a game function: the original is then reachable only through
    # this mod, and the game's state behind it must not be counted as its.
    "hooker": r"""
local game_fn = loadstring("local big = {} for i = 1, 5000 do big[i] = i end " ..
                           "return function() return #big end", "=game code")()
local previous = rawget(_G, "update")
rawset(_G, "update", function(...)
  game_fn()
  return previous(...)
end)
""",
    # A leak a player would feel: forty 100-byte strings a frame, ~14 MB in
    # 10 minutes at 4 frames a second.
    "runaway": r"""
local previous = rawget(_G, "update")
local store, n = {}, 0
rawset(_G, "update", function(...)
  for i = 1, 40 do
    n = n + 1
    store[n] = string.rep("r", 100) .. n
  end
  return previous(...)
end)
""",
    # Leaks into a global: counted as shared, and blamed on nobody.
    "global": r"""
local previous = rawget(_G, "update")
GLOBAL_CACHE = {}
local n = 0
rawset(_G, "update", function(...)
  n = n + 1
  GLOBAL_CACHE[n] = string.rep("z", 100) .. n
  return previous(...)
end)
""",
}


def memory_case():
    """Which mod's Lua memory only grows (v0.9.0-v0.10.0): counted once a
    minute by walking from each mod's own functions, after marking
    everything reachable from _G as shared. The log names every leak: no
    drop over 10 walks, 256 KB or more, across a world change. The screen
    names only growth a player would feel: 10 MB or more in those 10 walks,
    world change or not. 12 minutes in one world: the runaway mod is on
    screen, the small leak and the per-mission mod nowhere. After a world
    change the log adds the small leak; the per-mission mod, which cleared,
    stays out. A steady mod, a mod that grows and clears, the finder, a mod
    leaking into a global and a mod that hooks a game function are never
    named; owner names lose ".lua" as the chain's names do."""
    print("memory")
    with session() as s:
        s.lua(GUI_STUB)
        s.lua("FAKE.before_frame = function() CLOCK = CLOCK + 0.25 end")   # 4 frames a second
        for name, source in MEM_MODS.items():
            chunk = "mods/test/" + name + (".lua" if name == "leaky" else "")
            check(s.load_mod(source=source, name=chunk), "%s loads" % name)
        load(s, ["finder"])
        s.frames(2950)                              # ~12 minutes in one world
        walks = log_lines(s, r"memory: \d+ objects")
        check(len(walks) >= 11, "a walk a minute: %d" % len(walks))
        first = walks[0] if walks else ""
        check("leaky" in first and "steady" in first and "leaky.lua" not in first,
              "each mod's share is logged, without .lua: %r" % first[:300])
        mission = [float(m.group(1)) for m in (re.search(r"mission ~(\d+) KB", w) for w in walks) if m]
        check(len(mission) >= 11 and mission[-1] - mission[0] >= 256,
              "the per-mission mod grew 256 KB or more in one world: %r" % (mission[:3] + mission[-1:]))
        check(not log_lines(s, r"only grows"),
              "12 minutes in one world: no leak in the log yet: %r" % log_lines(s, r"only grows"))
        fast = log_lines(s, r"memory: (\S+) grows fast")
        who = sorted(set(re.search(r"memory: (\S+) grows fast", l).group(1) for l in fast))
        check(who == ["mods/test/runaway"], "10 MB in 10 minutes is named at once: %r" % who)
        s.lua("FAKE.transition({ replace_update = false })")
        s.frames(700)                               # ~3 more minutes
        walks = log_lines(s, r"memory: \d+ objects")
        steady = [float(m.group(1)) for m in (re.search(r"steady ~(\d+) KB", w) for w in walks) if m]
        check(len(steady) >= 13 and max(steady) - min(steady) <= 2 and 100 <= steady[0] <= 200,
              "a steady 3000-entry table reads about the same every minute (~120 KB): %r" % steady[:4])
        hooker = [float(m.group(1)) for m in (re.search(r"hooker ~(\d+) KB", w) for w in walks) if m]
        check(all(v < 5 for v in hooker),
              "a mod that hooks a game function is not charged the game's state: %r" % hooker[:4])
        check(re.search(r"world #2", walks[-1] if walks else "") is not None,
              "the world change is seen: %r" % (walks[-1][:120] if walks else ""))
        leaks = log_lines(s, r"memory: (\S+) only grows")
        who = sorted(set(re.search(r"memory: (\S+) only grows", l).group(1) for l in leaks))
        check(who == ["mods/test/leaky", "mods/test/runaway"],
              "after a world change the log names both leaks, not the per-mission mod: %r" % who)
        s.lua("FAKE.press('home')")
        s.frames(3)
        shown = s.eval("SHOWN()")
        check(re.search(r"MEM runaway ~[\d.]+ MB, \+[\d.]+ MB in 10 min", shown) is not None,
              "the window names the runaway: %r" % shown)
        check(re.search(r"MEM (leaky|steady|wave|mission|global|hooker|mod_lag_finder)", shown) is None,
              "and nothing else: a 700 KB leak stays in the log: %r" % shown)
        clean(s, "memory")


UNIT_MODS = {
    # Spawns three helper units every 15 frames and destroys only one
    # (through pcall, as the lamp mods do): they pile up.
    "piling": r"""
local previous = rawget(_G, "update")
local World = stingray.World
local kept, n, seen = {}, 0, nil
rawset(_G, "update", function(...)
  n = n + 1
  local world = stingray.Application.main_world()
  if world ~= seen then seen, kept = world, {} end      -- the old world took its units
  if n % 15 == 0 then
    for i = 1, 3 do kept[#kept + 1] = World.spawn_unit(world, "units/test/helper") end
    local oldest = table.remove(kept, 1)
    pcall(rawget(World, "destroy_unit"), world, oldest)
  end
  return previous(...)
end)
""",
    # Super Laser Sights Plus in game (2026-09-30): 34 units per turret,
    # destroyed with the turret. Turrets go down 2 minutes apart, 1 -> 4 at
    # once (136 units, rising 6 minutes on end), then all go at minute 8.5
    # and the round starts again. Nothing lives 10 minutes: never flagged.
    # v0.12.2 and before flagged it (live count >= 50, only rising).
    "turrets": r"""
local previous = rawget(_G, "update")
local World = stingray.World
local batches, n, seen = {}, 0, nil
rawset(_G, "update", function(...)
  n = n + 1
  local world = stingray.Application.main_world()
  if world ~= seen then seen, batches = world, {} end
  local r = n % 2040                                     -- an 8.5 minute round at 4 frames a second
  if r % 480 == 1 and r < 1920 then                      -- minutes 0, 2, 4, 6 of the round
    local batch = {}
    for i = 1, 34 do batch[i] = World.spawn_unit(world, "units/test/beam") end
    batches[#batches + 1] = batch
  end
  if r == 0 then
    for _, batch in ipairs(batches) do
      for _, unit in ipairs(batch) do pcall(World.destroy_unit, world, unit) end
    end
    batches = {}
  end
  return previous(...)
end)
""",
    # Four players' Guard Dogs and a long-lived turret each under Super Laser
    # Sights Plus: 8 groups of 34, one every 3 minutes, never destroyed. Old
    # units climb 34 -> 272 one step at a time: never flagged (v0.12.6);
    # v0.12.5's threshold of 100 flagged it.
    "dogs": r"""
local previous = rawget(_G, "update")
local World = stingray.World
local n, groups, seen = 0, 0, nil
rawset(_G, "update", function(...)
  n = n + 1
  local world = stingray.Application.main_world()
  if world ~= seen then seen, groups = world, 0 end
  if n % 720 == 20 and groups < 8 then                   -- every 3 minutes at 4 frames a second
    groups = groups + 1
    for i = 1, 34 do World.spawn_unit(world, "units/test/beam") end
  end
  return previous(...)
end)
""",
    # Ammo Lamp and the headlamp: a fixed set, spawned once, never destroyed.
    "steady": r"""
local previous = rawget(_G, "update")
local World = stingray.World
local seen, n = nil, 0
rawset(_G, "update", function(...)
  n = n + 1
  local world = stingray.Application.main_world()
  if world ~= seen and n > 10 then                       -- bound a moment after the world starts
    seen = world
    for i = 1, 12 do World.spawn_unit(world, "units/test/lamp") end
  end
  return previous(...)
end)
""",
    # Keeps two, replacing both every 60 frames: busy, but never piles up.
    "tidy": r"""
local previous = rawget(_G, "update")
local World = stingray.World
local kept, n, seen = {}, 0, nil
rawset(_G, "update", function(...)
  n = n + 1
  local world = stingray.Application.main_world()
  if world ~= seen then seen, kept = world, {} end
  if n % 60 == 1 then
    for _, unit in ipairs(kept) do pcall(World.destroy_unit, world, unit) end
    kept = { World.spawn_unit(world, "units/test/helper"), World.spawn_unit(world, "units/test/helper") }
  end
  return previous(...)
end)
""",
}


def switch_case():
    """Keyboards without Home (v0.11.0): the escape-menu window has a line
    that turns the table on in missions; a click turns it on, it stays up
    after the menu closes, and the next game starts with it on. Home still
    works, and a second click turns it off."""
    print("switch")
    scratch = tempfile.mkdtemp(prefix="mlf_switch_")
    try:
        def game(first):
            with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
                s.lua(CLOCK)
                s.lua("FAKE.mission()")
                s.lua(GUI_STUB)
                s.lua(menu_stub())
                load(s, ["heavy", "finder"])
                s.frames(120)
                if first:
                    s.lua("MENU_STATE(1, 0)")
                    s.frames(6)
                    shown = s.eval("SHOWN()")
                    check("show table in missions: OFF" in shown, "the switch starts off: %r" % shown)
                    pos = s.eval("POS('show table in missions')")
                    x, y = (int(v) for v in pos.split(",")) if pos != "none" else (0, 0)
                    s.lua("MOUSE.x, MOUSE.y = %d, %d; PRESS(1)" % (x + 20, y + 4))
                    s.frames(2)
                    s.lua("RELEASE(1)")
                    s.frames(2)
                    check("show table in missions: ON" in s.eval("SHOWN()"), "a click turns it on")
                    s.lua("MENU_STATE(4, 0)")          # back to play
                    s.frames(3)
                    shown = s.eval("SHOWN()")
                    check(re.search(r"heavy\s+\d+\.\d", shown) is not None and "in missions" not in shown,
                          "in the mission the table stays up, without the switch line: %r" % shown)
                    check((s.file("mod_lag_finder_window.txt") or "").strip().endswith(" 1 1"),
                          "and it is saved: %r" % s.file("mod_lag_finder_window.txt"))
                else:
                    shown = s.eval("SHOWN()")
                    check(re.search(r"heavy\s+\d+\.\d", shown) is not None,
                          "the next game starts with the table up: %r" % shown)
                    s.lua("FAKE.press('home')")
                    s.frames(3)
                    check(s.eval("SHOWN()") == "", "Home still turns it off: %r" % s.eval("SHOWN()"))
                    check((s.file("mod_lag_finder_window.txt") or "").strip().endswith(" 0 1"),
                          "and that is saved too")
                clean(s, "switch")
        game(True)
        game(False)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def alerts_case():
    """The pop-up lines can be turned off for missions (v0.12.2): with the
    alerts switch off a stall draws nothing in play, while it is still
    logged and the menu window still shows the last stall; the next game
    keeps it off, and the switch turns it back on."""
    print("alerts")
    scratch = tempfile.mkdtemp(prefix="mlf_alerts_")
    try:
        def click(s, prefix):
            pos = s.eval("POS('%s')" % prefix)
            x, y = (int(v) for v in pos.split(",")) if pos != "none" else (0, 0)
            s.lua("MOUSE.x, MOUSE.y = %d, %d; PRESS(1)" % (x + 20, y + 4))
            s.frames(2)
            s.lua("RELEASE(1)")
            s.frames(2)

        def game(first):
            with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
                s.lua(CLOCK)
                s.lua("FAKE.mission()")
                s.lua(GUI_STUB)
                s.lua(menu_stub())
                load(s, ["slow", "finder"])
                s.frames(120)
                if first:
                    s.lua("MENU_STATE(1, 0)")
                    s.frames(6)
                    check("show alerts in missions: ON" in s.eval("SHOWN()"), "alerts start on")
                    click(s, "show alerts in missions")
                    check("show alerts in missions: OFF" in s.eval("SHOWN()"), "a click turns them off")
                    s.lua("MENU_STATE(4, 0)")
                    s.frames(3)                             # the menu window goes
                s.lua("CALLS_BEFORE = GUI_CALLS")
                s.frames(300)                               # slow stalls in play
                check(s.eval("SHOWN()") == "" and s.eval("GUI_CALLS == CALLS_BEFORE") == "true",
                      "a stall draws nothing in a mission (no GUI call either): %r, %s -> %s"
                      % (s.eval("SHOWN()"), s.eval("CALLS_BEFORE"), s.eval("GUI_CALLS")))
                check(bool(log_lines(s, r"hitch 4\d\d ms")), "but it is logged")
                if first:
                    s.lua("MENU_STATE(1, 0)")
                    s.frames(6)
                    check("last stall 4" in s.eval("SHOWN()"), "and the menu window shows it")
                    check((s.file("mod_lag_finder_window.txt") or "").strip().endswith(" 0 0"),
                          "saved: %r" % s.file("mod_lag_finder_window.txt"))
                else:
                    check(s.eval("SHOWN()") == "", "the next game keeps them off: %r" % s.eval("SHOWN()"))
                    s.lua("MENU_STATE(1, 0)")
                    s.frames(6)
                    click(s, "show alerts in missions")
                    s.lua("MENU_STATE(4, 0)")
                    s.frames(310)                           # the next stall
                    check(re.search(r"LAG 4\d\d ms - slow", s.eval("SHOWN()")) is not None,
                          "turned on again, a stall shows its line: %r" % s.eval("SHOWN()"))
                clean(s, "alerts")
        game(True)
        game(False)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def small_case():
    """On the escape menu every mod is listed, the ones under 10 ms/s in grey
    (v0.12.2); in a mission they are only counted, as before."""
    print("small")
    with session() as s:
        s.lua("stingray.Color = function(a, r, g, b) return { a, r, g, b } end")
        s.lua(GUI_STUB)
        s.lua("""
local text = stingray.Gui.text
stingray.Gui.text = function(g, t, font, size, material, pos, col)
  COLOURS = COLOURS or {}
  if type(col) == "table" and col[1] == 255 then COLOURS[t] = table.concat(col, ",", 2) end
  return text(g, t, font, size, material, pos, col)
end
function COLOUR_OF(prefix)
  for t, c in pairs(COLOURS or {}) do
    if string.sub(t, 1, #prefix) == prefix then return c end
  end
  return "none"
end""")
        s.lua(menu_stub())
        load(s, ["std", "heavy", "finder"])
        s.frames(600)
        s.lua("FAKE.press('home')")                     # in a mission
        s.frames(3)
        shown = s.eval("SHOWN()")
        check(re.search(r"\|heavy\s+\d+\.\d", shown) is not None and re.search(r"\|std\s", shown) is None
              and "under 10 ms/s" in shown,
              "in a mission a mod under 10 ms/s is only counted: %r" % shown)
        s.lua("FAKE.press('home')")
        s.lua("MENU_STATE(1, 0)")                       # the escape menu
        s.frames(6)
        shown = s.eval("SHOWN()")
        check(re.search(r"\|std\s+\d+\.\d\s+\d+ ms", shown) is not None and "under 10 ms/s" not in shown,
              "on the menu it is listed: %r" % shown)
        check(s.eval("COLOUR_OF('std ')") == "170,175,170", "in grey: %s" % s.eval("COLOUR_OF('std ')"))
        check(s.eval("COLOUR_OF('heavy ')") in ("235,240,235", "255,190,90"),
              "a mod at 10 ms/s or more is not grey: %s" % s.eval("COLOUR_OF('heavy ')"))
        clean(s, "small")


# HD2 HUD+ as shipped: 0.1.12 replaces the game's boot script and hooks
# update from there (chunk "boot", previous in an upvalue named "original");
# 0.1.13's boot patch only requires its module, "mods/hd2_hud/product",
# which hooks update like any mod but has no HD2-Addon line.
HUD_BOOT_012 = r"""
local original = rawget(_G, "update")
local worker = { update = function() CLOCK = CLOCK + 0.004 end }
rawset(_G, "update", function(...)
  worker:update()
  return original(...)
end)
"""
HUD_PRODUCT_013 = HUD_BOOT_012
HUD_BOOT_PATCH = ('local __original_boot = "' + "\\027LJ" + "x" * 1300 + '"\n'
                  "local __load = rawget(_G, \"loadstring\")\n"
                  "-- the game's own boot runs first\n"
                  "local __product_name = \"mods/hd2_hud/product\"\n"
                  "pcall(rawget(_G, \"require\"), __product_name)\n")


def boot_case():
    """A mod that replaced the game's boot script (v0.12.4): HUD+ 0.1.12
    hooks update as "boot", under every mod; the walk must time it as its
    own row, named as in the mod manager, and stop at the real game below
    it. HUD+ 0.1.13 runs as "mods/hd2_hud/product" with no HD2-Addon line;
    the name comes from the "mods/..." strings in its boot patch."""
    import json
    print("boot")
    scratch = tempfile.mkdtemp(prefix="mlf_boot_")
    root = os.path.join(scratch, "Arsenal Mods")
    arsenal = os.path.join(scratch, "hd2arsenal")
    os.makedirs(arsenal)
    folder = os.path.join(root, "HD2 HUD Plus 0.1.13_AR9", "COMMON")
    os.makedirs(folder)
    with open(os.path.join(folder, "9ba626afa44a3aa3.patch_0"), "wb") as f:
        f.write(lua_archive([HUD_BOOT_PATCH, HUD_PRODUCT_013], names=["boot", "mods/hd2_hud/product"]))
    wms = os.path.join(root, "WMS_AR1", "Beacon")
    os.makedirs(wms)
    with open(os.path.join(wms, "9ba626afa44a3aa3.patch_0"), "wb") as f:
        f.write(lua_archive(["-- HD2-Addon: mods/test/slow\nreturn {}\n"]))
    profile = {"label": "Test", "mods": [
        {"label": "HD2 HUD+", "path": os.path.join(root, "HD2 HUD Plus 0.1.13_AR9"), "enabled": True,
         "options": [{"name": "COMMON", "enabled": True, "include": ["COMMON"], "suboptions": []}]},
        {"label": "Where's My Shit?", "path": os.path.join(root, "WMS_AR1"), "enabled": True,
         "options": [{"name": "Beacon", "enabled": True, "include": ["Beacon"], "suboptions": []}]}]}
    with open(os.path.join(arsenal, "hd2a_data.json"), "w", encoding="utf-8") as f:
        json.dump({"selectedProfile": "p1", "modsList": {"p1": profile}}, f)

    def game(hud_name, hud_source):
        with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
            s.lua(CLOCK)
            s.lua("FAKE.mission()")
            s.lua(GUI_STUB)
            check(s.load_mod(source=hud_source, name=hud_name), "%s loads" % hud_name)
            load(s, ["slow", "std", "finder"])
            s.frames(320)
            s.lua("FAKE.press('home')")
            s.frames(3)
            shown = s.eval("SHOWN()")
            text = (s.file(LOG, "") or "").split("== mod-lag-finder")[-1]
            clean(s, "boot")
        return text, shown

    try:
        text, shown = game("boot", HUD_BOOT_012)
        check(re.search(r"name: #f476df93691895fa = HD2 HUD\+", text) is not None,
              "HUD+'s \"boot\" is named by its archive's name hash: %r" % re.findall(r"name: .*", text))
        chain = [l for l in text.splitlines() if re.search(r"#\d+ ", l)]
        check(any("boot:" in l and "own copy of a game script" in l for l in chain)
              and any("bottom: game" in l for l in chain),
              "the chain walks HUD+'s boot as a mod, then the game below it: %r" % chain)
        hud = re.search(r"\|HD2 HUD\+ +(\d+\.\d) ", shown)
        game_row = re.search(r"\|\(the game\) +(\d+\.\d) ", shown)
        check(hud is not None and float(hud.group(1)) > 150,
              "HUD+ is its own row, under its name (~240 ms/s): %r" % shown)
        check(game_row is None or float(game_row.group(1)) < 50,
              "and (the game) keeps only the game: %r" % shown)
        for base, _dirs, files in os.walk(scratch):         # game one saved the table as open
            if "mod_lag_finder_window.txt" in files:
                os.remove(os.path.join(base, "mod_lag_finder_window.txt"))
        text, shown = game("mods/hd2_hud/product", HUD_PRODUCT_013)
        check(re.search(r"name: #ef0157640928609f = HD2 HUD\+", text) is not None,
              "0.1.13's module is named by its archive's name hash: %r" % re.findall(r"name: .*", text))
        check(re.search(r"\|HD2 HUD\+ +\d+\.\d ", shown) is not None and "|product " not in shown,
              "it shows as HD2 HUD+, not product: %r" % shown)
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def bootstrap_case():
    """No mod calls Application.main_world (v0.12.5; the user's profile of
    Bingus Shared Loader + SmoothBoot + the Watchdog never started on
    2026-09-30): the first frame arms it through its start-up hook on
    update, the chain is mapped through that hook (a mod loaded after the
    Watchdog wraps it), every mod gets its row and a stall its line, and the
    hook is neither a row nor a second hook of this module."""
    print("bootstrap")
    with Session(backend=BACKEND, engine_main_world_calls=0) as s:
        s.lua(CLOCK)
        s.lua("FAKE.mission()")
        s.lua(GUI_STUB)
        load(s, ["slow", "finder", "heavy"])          # heavy hooks after us: it wraps the start-up hook
        s.frames(600)
        check(bool(log_lines(s, r"update armed generation=1")), "armed on the first frame: %r"
              % log_lines(s, "armed|installed"))
        chain = log_lines(s, r"#\d+ ")
        order = [re.search(r"#\d+ (\S+):", l).group(1) for l in chain]
        check(order == ["mods/patpatpatrick/mod_lag_finder", "mods/test/heavy", "mods/test/slow",
                        "hd2fake/engine"] and "bottom: game" in chain[-1],
              "mapped through the start-up hook, which is no link of its own: %r" % chain)
        check(not log_lines(s, r"rehook:"), "not a re-hook: %r" % log_lines(s, "rehook"))
        s.lua("FAKE.press('home')")
        s.frames(3)
        shown = s.eval("SHOWN()")
        check(re.search(r"\|heavy +\d+\.\d", shown) is not None and re.search(r"\|slow +\d+\.\d", shown) is not None,
              "both mods have their rows: %r" % shown)
        check("mod_lag_finder" not in shown and "hooked more than once" not in shown,
              "the hook is no row and no second hook: %r" % shown)
        check(re.search(r"LAG 4\d\d ms - slow", shown) is not None or bool(log_lines(s, r"hitch 4\d\d ms.*slow")),
              "slow's stalls are put on slow: %r" % log_lines(s, "hitch")[:1])
        clean(s, "bootstrap")


# v0.12.7: the six findings of the 2026-09-30 code review, one scenario
# each. Every one of them fails on v0.12.6.
REVIEW_THROWER = r"""
local previous = rawget(_G, "update")
rawset(_G, "update", function(...)
  COUNT("thrower")
  if THROW then error("thrower broke", 0) end
  return previous(...)
end)
"""
# Not a mod ("engine_cost"): the game's own update taking 10 ms a frame.
REVIEW_ENGINE_COST = r"""
local engine_step = rawget(_G, "update")
rawset(_G, "update", function(...)
  CLOCK = CLOCK + 0.010
  return engine_step(...)
end)
"""
REVIEW_STALL_THEN_HOOK = r"""
local previous = rawget(_G, "update")
local n = 0
rawset(_G, "update", function(...)
  n = n + 1
  if n == STALL_AT then CLOCK = CLOCK + 0.4 end
  if n == STALL_AT + 1 then                     -- the next frame, something re-hooks on top
    local top = rawget(_G, "update")
    rawset(_G, "update", function(...) return top(...) end)
  end
  return previous(...)
end)
"""


def review_errors_case():
    """1. An error from a mod below the Watchdog reaches the engine every
    frame, as it would without the Watchdog; the Watchdog's own tick still
    runs. v0.12.6 swallowed it (logged once) and the engine never saw it."""
    print("review: errors from below")
    with session() as s:
        check(s.load_mod(source=REVIEW_THROWER, name="mods/test/thrower"), "thrower loads")
        load(s, ["finder"])
        s.frames(60)
        s.lua("THROW = true")
        s.frames(3800)
        r = s.report()
        thrown = [u for u in r["uncaught"] if "thrower broke" in u["error"]]
        check(len(thrown) >= 3700, "every frame's error reaches the engine: %d of 3800" % len(thrown))
        check(bool(log_lines(s, r"raised an error \(passed on\): thrower broke")), "and is logged once")
        check(bool(log_lines(s, r"summary 60 s: frames=\d{4}")), "the Watchdog keeps ticking: %r"
              % log_lines(s, "summary")[:1])


def review_remap_case():
    """2. Right after a (re)map the newest link has no finished frame yet:
    nothing is charged until every shim has run twice. v0.12.6 charged the
    game's 10 ms frame to heavy, the mod above it, at every remap."""
    print("review: remap charge")
    with session() as s:
        check(s.load_mod(source=REVIEW_ENGINE_COST, name="engine_cost"), "engine cost loads")
        load(s, ["heavy", "finder"])
        check(s.load_mod(source=REARMER, name="mods/test/rearmer"), "rearmer loads")
        s.frames(300)
        for _ in range(6):
            s.lua("REARM()")
            s.frames(300)
        s.frames(2400)
        worst = [float(v) for v in re.findall(
            r"mods/test/heavy\s+[\d.]+ ms/s\s+[\d.]+ ms/frame\s+worst frame ([\d.]+) ms",
            s.file(LOG, "") or "")]
        maps = log_lines(s, r"chain mapped")
        check(len(maps) >= 4, "it was remapped: %d maps" % len(maps))
        check(bool(worst) and max(worst) < 9, "heavy's worst frame stays its own 5 ms: %r" % worst)
        clean(s, "remap")


def review_no_shutdown_case():
    """3. A game with no _G.shutdown: the walk still maps the chain. v0.12.6
    raised "table index is nil" in avoid_set and stayed half-built."""
    print("review: no shutdown")
    with session() as s:
        load(s, ["heavy"])
        s.lua("rawset(_G, 'shutdown', nil)")
        load(s, ["finder"])
        s.frames(300)
        check(bool(log_lines(s, r"chain mapped")), "the chain is mapped: %r" % log_lines(s, "chain|error|failed"))
        check(not log_lines(s, r"tick error|walk failed"), "no error: %r" % log_lines(s, "error|failed"))


def review_rearm_gap_case():
    """4. The time out of the chain before a re-arm is no frame: no stall is
    counted for it. v0.12.6 logged the whole gap as a hitch."""
    print("review: re-arm gap")
    with session() as s:
        s.lua("GAME_UP = rawget(_G, 'update')")
        load(s, ["heavy", "finder"])
        s.frames(200)
        s.lua("rawset(_G, 'update', GAME_UP)")         # the chain is cut: the Watchdog is out
        s.frames(400)
        s.frames(100)
        check(bool(log_lines(s, r"update armed generation=2")), "re-armed: %r" % log_lines(s, "armed"))
        hitches = [int(v) for v in re.findall(r"hitch (\d+) ms", s.file(LOG, "") or "")]
        check(not [h for h in hitches if h >= 500], "no stall for the gap: %r" % hitches)


def review_pending_case():
    """5. A stall followed on the next frame by a chain change is still
    reported, on the mod that caused it. v0.12.6 dropped it: no line."""
    print("review: stall before a chain change")
    with session() as s:
        s.lua("STALL_AT = 300")
        check(s.load_mod(source=REVIEW_STALL_THEN_HOOK, name="mods/test/stallhook"), "stallhook loads")
        load(s, ["finder"])
        s.frames(400)
        hitch = log_lines(s, r"hitch 4\d\d ms")
        check(bool(hitch), "the stall is reported: %r" % log_lines(s, "hitch|changed"))
        check(any(re.search(r"mods/test/stallhook 4\d\d", l) for l in hitch),
              "and put on the mod that caused it: %r" % hitch)


def review_shutdown_once_case():
    """6. Shutdown is wrapped once a session: with a mod's shutdown wrapper
    over ours and two re-arms, the exit summary runs once. v0.12.6 stacked a
    wrapper per re-arm and wrote "game over" three times."""
    print("review: shutdown once")
    with session() as s:
        s.lua("GAME_UP = rawget(_G, 'update')")
        load(s, ["heavy", "finder"])
        s.frames(100)
        s.lua("local p = rawget(_G, 'shutdown')\n"
              "rawset(_G, 'shutdown', function(...) SHUT_TOP = (SHUT_TOP or 0) + 1 return p(...) end)")
        for _ in range(2):
            s.lua("rawset(_G, 'update', GAME_UP)")
            s.frames(400)
        check(bool(log_lines(s, r"update armed generation=3")), "re-armed twice: %r" % log_lines(s, "armed"))
        s.lua("FAKE.shutdown()")
        over = log_lines(s, r"game over")
        check(len(over) == 1, "the exit summary runs once: %r" % over)
        check(s.eval("SHUT_TOP") == "1", "and the mod's own shutdown still runs once: %s" % s.eval("SHUT_TOP"))


HASH_NAMES = ["boot", "mods/hd2_hud/product", "core/wwise/lua/wwise_flow_callbacks",
               "mods/patpatpatrick/mod_lag_finder", "", "a", "abcdefg", "abcdefgh", "abcdefghi",
               "mods/cowboybingus/vanilla_plus_megapack/enemy_collision_synchronized"]


def hash_case():
    """The Watchdog's pure-Lua murmur64 (v0.13.0) gives what the SDK's
    hashing.murmur64_hash gives, with LuaJIT's bit library and without it."""
    print("hash")
    for without_bit in (False, True):
        with session() as s:
            if without_bit:
                s.lua("bit = nil")
            s.lua("__mlf_test_hash = true")
            load(s, ["finder"])
            for name in HASH_NAMES:
                want = "%016x" % murmur64_hash(name.encode("utf-8"))
                got = s.eval("__mlf_test_hash(%s)" % lua_literal(name))
                check(got == want, "%s%r: %s (want %s)" % ("no bit: " if without_bit else "", name, got, want))


# v0.13.0: links found through their archive's name hash. Each fails on v0.12.7.
PATCH_OLD_UPDATE = r"""
local old_update = rawget(_G, "update")
rawset(_G, "update", function(...)
  CLOCK = CLOCK + 0.004
  return old_update(...)
end)
"""
PATCH_STRIPPED = r"""
local factory = function(original)
  return function(...)
    CLOCK = CLOCK + 0.004
    return original(...)
  end
end
local make = loadstring(string.dump(factory, true), "@boot")
rawset(_G, "update", make(rawget(_G, "update")))
"""
PATCH_SUBMODULE = r"""
local down = rawget(_G, "update")
rawset(_G, "update", function(...)
  CLOCK = CLOCK + 0.004
  return down(...)
end)
"""


def patch_case():
    """A mod's update found through its archive (v0.13.0), not through its
    shape: a boot patch whose previous is in "old_update", one with stripped
    upvalue names, and an update hook in a submodule with no HD2-Addon line
    and no "mods/" name. Each gets its own row under its mod's name, the
    mods below it stay visible, and "(the game)" keeps only the game."""
    import json
    print("patch")
    scratch = tempfile.mkdtemp(prefix="mlf_patch_")
    root = os.path.join(scratch, "Arsenal Mods")
    arsenal = os.path.join(scratch, "hd2arsenal")
    os.makedirs(arsenal)

    def mod_folder(folder, rows):
        path = os.path.join(root, folder, "Main")
        os.makedirs(path)
        with open(os.path.join(path, "9ba626afa44a3aa3.patch_0"), "wb") as f:
            f.write(lua_archive([source for _, source in rows], names=[name for name, _ in rows]))

    mod_folder("Boot Mod_AR11", [("boot", "return {}")])
    mod_folder("Sub Mod_AR12", [("sub_core/update", "return {}"), ("mods/sub/main", "return {}")])
    mod_folder("WMS_AR1", [("mods/test/slow", "-- HD2-Addon: mods/test/slow\nreturn {}\n")])
    profile = {"label": "Test", "mods": [
        {"label": label, "path": os.path.join(root, folder), "enabled": True,
         "options": [{"name": "Main", "enabled": True, "include": ["Main"], "suboptions": []}]}
        for label, folder in (("Boot Mod", "Boot Mod_AR11"), ("Sub Mod", "Sub Mod_AR12"),
                              ("Where's My Shit?", "WMS_AR1"))]}
    with open(os.path.join(arsenal, "hd2a_data.json"), "w", encoding="utf-8") as f:
        json.dump({"selectedProfile": "p1", "modsList": {"p1": profile}}, f)

    def game(chunk, source, label):
        for base, _dirs, files in os.walk(scratch):
            if "mod_lag_finder_window.txt" in files:
                os.remove(os.path.join(base, "mod_lag_finder_window.txt"))
        with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
            s.lua(CLOCK)
            s.lua("FAKE.mission()")
            s.lua(GUI_STUB)
            load(s, ["heavy"])                          # below the patch
            check(s.load_mod(source=source, name=chunk), "%s loads" % label)
            load(s, ["slow", "finder"])
            s.frames(320)
            s.lua("FAKE.press('home')")
            s.frames(3)
            shown = s.eval("SHOWN()")
            row = re.search(r"\|%s +(\d+\.\d) " % re.escape(label), shown)
            check(row is not None and float(row.group(1)) > 100,
                  "%s: its own row under its mod's name (4 ms a frame, ~140 ms/s here): %r" % (label, shown))
            check(re.search(r"\|heavy +\d+\.\d", shown) is not None,
                  "%s: the mod below it stays visible: %r" % (label, shown))
            game_row = re.search(r"\|\(the game\) +(\d+\.\d) ", shown)
            check(game_row is None or float(game_row.group(1)) < 50,
                  "%s: (the game) keeps only the game: %r" % (label, shown))
            clean(s, "patch")

    try:
        game("boot", PATCH_OLD_UPDATE, "Boot Mod")         # previous in "old_update"
        game("boot", PATCH_STRIPPED, "Boot Mod")           # stripped: no upvalue names at all
        game("sub_core/update", PATCH_SUBMODULE, "Sub Mod")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def report_case():
    """A click on a mod's row in the escape-menu window copies that mod's
    8-line report (v0.11.0): its name, the game build and the Watchdog
    version, the session, its cost, the stalls it caused, its Lua memory,
    its helper units and its update hook. No path or user name in it. With
    no clipboard the report goes to mod_lag_report_<mod>.txt instead."""
    print("report")
    scratch = tempfile.mkdtemp(prefix="mlf_report_")
    try:
        with Session(backend=BACKEND, scratch=scratch, keep_scratch=True) as s:
            s.lua(CLOCK)
            s.lua("FAKE.mission()")
            s.lua(GUI_STUB)
            s.lua(menu_stub())
            s.lua("__hd2_native_test.clipboard = function(text) CLIP = text return true end")
            load(s, ["slow", "heavy", "finder"])
            s.frames(3800)                              # past a 60 s summary, a few stalls
            s.lua("MENU_STATE(1, 0)")                   # escape menu, GAME tab
            s.frames(6)
            shown = s.eval("SHOWN()")
            check("click a mod: copy its report" in shown, "the window says rows can be clicked: %r" % shown)
            pos = s.eval("POS('slow ')")
            check(pos != "none", "slow has a row: %r" % shown)
            x, y = (int(v) for v in pos.split(",")) if pos != "none" else (0, 0)
            s.lua("MOUSE.x, MOUSE.y = %d, %d; PRESS(1)" % (x + 20, y + 4))
            s.frames(2)
            s.lua("RELEASE(1)")
            s.frames(2)
            clip = s.eval("CLIP") or ""
            lines = clip.split("\r\n")
            check(len(lines) == 8, "8 lines: %r" % clip)
            check(lines[0] == "Mod Lag Watchdog report: slow (mods/test/slow)", "who: %r" % lines[:1])
            check(re.match(r"Game build 6AB3B43F, Watchdog v0\.13\.0, 3 mods hook the update", lines[1] if len(lines) > 1 else "")
                  is not None, "build, version, chain: %r" % lines[1:2])
            check(re.match(r"Session: 1 min, \d+ FPS average, 0 world changes", lines[2] if len(lines) > 2 else "")
                  is not None, "the session: %r" % lines[2:3])
            check(re.match(r"Cost: \d+\.\d ms/s average, \d+\.\d ms/s in the worst minute, worst frame 4\d\d ms",
                           lines[3] if len(lines) > 3 else "") is not None, "its cost: %r" % lines[3:4])
            check(re.match(r"Stalls it caused \(150 ms\+\): \d+ \(4\d\d, 4\d\d, 4\d\d ms\)", lines[4] if len(lines) > 4 else "")
                  is not None, "its stalls, worst three: %r" % lines[4:5])
            check((lines[5] if len(lines) > 5 else "").startswith("Lua memory: "), "its memory: %r" % lines[5:6])
            check((lines[6] if len(lines) > 6 else "") == "Helper units: none spawned", "its units: %r" % lines[6:7])
            check(re.match(r"Update hook: hooked 1 time, (not on top|on top)", lines[7] if len(lines) > 7 else "")
                  is not None, "its hook: %r" % lines[7:8])
            check(scratch.replace("\\", "/") not in clip.replace("\\", "/") and "Users" not in clip,
                  "no path in it")
            check("report copied: slow" in s.eval("SHOWN()"), "and says so: %r" % s.eval("SHOWN()"))
            check(bool(log_lines(s, r"report: copied for mods/test/slow")), "logged")

            s.lua("__hd2_native_test.clipboard = nil")  # no clipboard: a file instead
            s.frames(200)
            pos = s.eval("POS('heavy ')")
            x, y = (int(v) for v in pos.split(",")) if pos != "none" else (0, 0)
            s.lua("MOUSE.x, MOUSE.y = %d, %d; PRESS(1)" % (x + 20, y + 4))
            s.frames(2)
            s.lua("RELEASE(1)")
            s.frames(2)
            saved = s.file("mod_lag_report_heavy.txt") or ""
            check(saved.startswith("Mod Lag Watchdog report: heavy (mods/test/heavy)")
                  and len(saved.strip().splitlines()) == 8,
                  "no clipboard: the 8 lines are written to a file: %r" % saved[:120])
            check("report saved: mod_lag_report_heavy.txt" in s.eval("SHOWN()"), "and says where")
            clean(s, "report")
    finally:
        shutil.rmtree(scratch, ignore_errors=True)


def units_case():
    """Helper units each mod keeps alive (v0.10.0, judged by old units since
    v0.12.3): spawns are charged to the calling mod, destroys to the
    spawner, and a new main world starts the counts again. A mod with 300 or
    more units alive 10 minutes or longer (100 in v0.12.3-v0.12.5), a number
    that only rose over 5 checks, is named in the log, the window and a
    one-time line. Not named: turrets that come and go (136 alive at the
    peak, rising for 6 minutes, none 10 minutes old), four players' dogs and
    turrets that stay (272 old, reached step by step), a fixed set of 12, and
    a mod that replaces its two units all the time. spawn_unit and destroy_unit pass arguments and
    results through unchanged."""
    print("units")
    with session() as s:
        s.lua(GUI_STUB)
        s.lua("FAKE.before_frame = function() CLOCK = CLOCK + 0.25 end")   # 4 frames a second
        for name, source in UNIT_MODS.items():
            check(s.load_mod(source=source, name="mods/test/" + name), "%s loads" % name)
        load(s, ["finder"])
        check(bool(log_lines(s, "units: counting")), "the counting is on: %r" % log_lines(s, "units:"))
        s.frames(8400)                              # 35 minutes: piling passes 300 old units
        counts = log_lines(s, r"units: alive")
        check(len(counts) >= 20, "a count a minute: %r" % counts[-2:])
        last = counts[-1] if counts else ""
        piling = re.search(r"piling (\d+) \((\d+) old\)", last)
        tidy = re.search(r"tidy (\d+) \((\d+) old\)", last)
        steady = re.search(r"steady (\d+) \((\d+) old\)", last)
        check(piling is not None and int(piling.group(1)) >= 500 and int(piling.group(2)) >= 300,
              "piling keeps 2 of every 3, and they grow old: %r" % last)
        dogs = re.search(r"dogs (\d+) \((\d+) old\)", last)
        check(dogs is not None and dogs.groups() == ("272", "272"),
              "dogs: 8 groups of 34, all old by now: %r" % last)
        check(tidy is not None and tidy.groups() == ("2", "0"), "tidy keeps 2, none old: %r" % last)
        check(steady is not None and steady.groups() == ("12", "12"), "steady keeps 12, all old: %r" % last)
        peak = max((int(m.group(1)) for m in (re.search(r"turrets (\d+)", l) for l in counts) if m), default=0)
        check(peak >= 136, "turrets reach 136 alive: %d" % peak)
        check(not any(re.search(r"turrets \d+ \([1-9]", l) for l in counts), "and none of them grows old")
        flagged = log_lines(s, r"units: (\S+) has \d+ units older than 10 min and still rising")
        who = sorted(set(re.search(r"units: (\S+) has", l).group(1) for l in flagged))
        check(who == ["mods/test/piling"], "only the piling mod is named: %r" % who)
        s.lua("FAKE.press('home')")
        s.frames(3)
        shown = s.eval("SHOWN()")
        check(re.search(r"UNITS piling \d+ old units, still rising", shown) is not None
              and "UNITS tidy" not in shown and "UNITS turrets" not in shown,
              "the window names it: %r" % shown)
        s.lua("FAKE.transition({ replace_update = false })")
        s.frames(300)
        counts = log_lines(s, r"units: alive")
        after = re.search(r"piling (\d+) \((\d+) old\)", counts[-1] if counts else "")
        check(after is not None and int(after.group(1)) < 100 and after.group(2) == "0",
              "a new world starts the count again: %r" % (counts[-1] if counts else ""))
        clean(s, "units")


REARMER = r"""
-- Re-hooks update on top whenever the test says so, the way Helmet Headlamp
-- 1.0 re-arms after a long stall; only its newest copy does its work.
local generation = 0
function REARM()
  generation = generation + 1
  local mine = generation
  local previous = rawget(_G, "update")
  rawset(_G, "update", function(...)
    if mine == generation then COUNT("rearmer") end
    return previous(...)
  end)
end
REARM()
"""


def soak_case(seed=20260930, chunks=200):
    """Long and disordered (v0.12.6, the user: a tool like this must be very
    stable). About 17 simulated minutes at 20 frames a second with, at
    random but reproducible moments: world changes, a mod re-hooking on top,
    engine stalls of 0.5-3 s, the escape menu opened with clicks on the
    switches and on mod rows, Home, and the UI world going away and coming
    back. Mods: a boot patch below everything (HUD+ 0.1.12 style), eight
    that call main_world every tick (the gate's fillers), heavy,
    std, slow, a steady memory holder, a unit keeper and the re-hooker.
    Afterwards nothing may have died, escaped or been swallowed; the finder
    armed exactly once and kept writing its summaries; every mod did its
    work on every frame; the finder's own memory did not grow; no GUI call
    went into a gone world; the unit keeper still has 2 units."""
    import random
    print("soak (seed %d)" % seed)
    rng = random.Random(seed)
    with session() as s:
        s.lua(GUI_STUB)
        s.lua(menu_stub())
        s.lua("__hd2_native_test.clipboard = function(text) CLIP = text return true end")
        s.lua("FAKE.before_frame = function() CLOCK = CLOCK + 0.05 end")   # 20 frames a second
        check(s.load_mod(source=HUD_BOOT_012, name="boot"), "boot patch loads")
        from hd2fake.gate import REARM_FILLER
        for k in range(8):
            check(s.load_mod(source=REARM_FILLER, name="mods/test/filler_%d" % k), "filler %d loads" % k)
        load(s, ["heavy", "std", "slow"])
        check(s.load_mod(source=MEM_MODS["steady"], name="mods/test/steady"), "steady loads")
        check(s.load_mod(source=UNIT_MODS["tidy"], name="mods/test/tidy"), "tidy loads")
        check(s.load_mod(source=REARMER, name="mods/test/rearmer"), "rearmer loads")
        load(s, ["finder"])
        frames = 0
        events = {"world": 0, "rehook": 0, "stall": 0, "menu": 0, "click": 0, "home": 0, "ui gone": 0}
        ui_gone = False
        for chunk in range(chunks):
            roll = rng.random()
            if ui_gone:
                s.lua("UIW = FAKE.add_world('ui%d', false)" % chunk)
                ui_gone = False
            elif roll < 0.08:
                s.lua("FAKE.transition({ replace_update = false })")
                events["world"] += 1
            elif roll < 0.14:
                s.lua("REARM()")
                events["rehook"] += 1
            elif roll < 0.24:
                stall = rng.uniform(0.5, 3.0)
                s.lua("CLOCK = CLOCK + %.3f; FAKE.time = FAKE.time + %.3f" % (stall, stall))
                events["stall"] += 1
            elif roll < 0.36:
                events["menu"] += 1
                s.lua("MENU_STATE(1, 0)")
                s.frames(8)
                frames += 8
                target = rng.choice(["show table in missions", "show alerts in missions", "std ", "heavy ",
                                     "slow ", "MOD LAG WATCHDOG"])
                pos = s.eval("POS('%s')" % target)
                if pos not in ("none", None, ""):
                    x, y = (int(v) for v in pos.split(","))
                    s.lua("MOUSE.x, MOUSE.y = %d, %d; PRESS(1)" % (x + 20, y + 4))
                    s.frames(2)
                    s.lua("RELEASE(1)")
                    frames += 2
                    events["click"] += 1
                s.frames(4)
                frames += 4
                s.lua("MENU_STATE(4, 0)")
            elif roll < 0.41:
                s.lua("FAKE.press('home')")
                events["home"] += 1
            elif roll < 0.45:
                s.lua("DROP_UI()")
                ui_gone = True
                events["ui gone"] += 1
            s.frames(100)
            frames += 100
        # Mapping a chain of ~30 links takes ~240 frames (12 s here, 3-4 s at
        # a real frame rate): leave 30 s after the last event for it (seed 4
        # re-hooks in the last chunk).
        s.frames(600)
        frames += 600
        text = (s.file(LOG, "") or "").split("== mod-lag-finder")[-1]
        print("  events: %r, %d frames" % (events, frames))

        armed = [l for l in text.splitlines() if "update armed generation" in l]
        check(len(armed) == 1, "armed exactly once through every event: %r" % armed)
        summaries = re.findall(r"t=([\d.]+) summary", text)
        last = float(summaries[-1]) if summaries else 0
        check(len(summaries) >= 14 and last >= 900,
              "a summary every minute to the end (%d, last at %.0f s)" % (len(summaries), last))
        changed = [i for i, l in enumerate(text.splitlines()) if "update chain changed" in l]
        mapped = [i for i, l in enumerate(text.splitlines()) if "chain mapped" in l]
        check(bool(mapped) and (not changed or mapped[-1] > changed[-1]),
              "every change of the chain was mapped again (%d changes, %d maps)" % (len(changed), len(mapped)))
        counts = s.eval("string.format('%d %d %d', COUNTS.std or 0, COUNTS.heavy or 0, COUNTS.rearmer or 0)")
        std, heavy, rearmer = (int(v) for v in counts.split())
        check(std == frames and heavy == frames and rearmer == frames,
              "every mod did its work on every frame (%d frames): std %d, heavy %d, rearmer %d"
              % (frames, std, heavy, rearmer))
        own = [float(v) for v in re.findall(r"mod_lag_finder ~([\d.]+) KB", text)]
        check(len(own) >= 10 and max(own) - min(own) < 200,
              "the finder's own memory stays put: %r" % (own[:3] + own[-3:]))
        self_hooks = [l for l in text.splitlines() if re.search(r"(rehook|more than once).*mod_lag_finder", l)]
        check(not self_hooks, "the finder never counts itself as hooked twice: %r" % self_hooks[:2])
        failures = [l for l in text.splitlines()
                    if re.search(r"tick error|walk failed|check failed|raised an error", l)]
        check(not failures, "no internal failure logged: %r" % failures[:3])
        check(s.eval("GUI_BAD") == "0", "never a GUI call into a gone world")
        check(int(s.eval("LIVE_COUNT()")) <= 1, "one GUI at a time: %s" % s.eval("LIVE_COUNT()"))
        units = log_lines(s, r"units: alive")
        check(bool(units) and re.search(r"tidy 2\b", units[-1]) is not None,
              "the unit keeper still has its 2 units: %r" % units[-1:])
        s.lua("MENU_STATE(1, 0)")
        s.frames(8)
        check("ms/s" in s.eval("SHOWN()"), "the window still works at the end: %r" % s.eval("SHOWN()")[:200])
        clean(s, "soak")


def timer_case():
    """In game the timer is QueryPerformanceCounter, not os.clock's whole
    milliseconds (v0.8.0): with ffi allowed and no test seam, a mod that
    really spends 0.3 ms a frame is shown at 0.3 ms over the frame time, and
    a mod that spends nothing is not listed but counted. Without ffi the
    finder says it is on os.clock."""
    print("timer")
    with Session(backend=BACKEND, ffi="allow") as s:
        s.lua(CLOCK)
        s.lua("FAKE.mission()")
        s.lua(GUI_STUB)
        load(s, ["std"])
        check(s.load_mod(source=SPIN, name="mods/test/spin"), "spin loads")
        load(s, ["finder"])
        s.frames(3000)
        s.lua("FAKE.press('home')")
        s.frames(3)
        shown = s.eval("SHOWN()")
        timer = log_lines(s, r"timer: ")
        check(bool(timer) and "QueryPerformanceCounter" in timer[0],
              "the timer is QueryPerformanceCounter: %r" % timer)
        # The fake runs frames back to back, so the frame is the spin plus
        # a little: the share must be 0.3 ms over the average frame.
        m = re.search(r"\|spin +(\d+\.\d) +(\d+) ms", shown)
        got = float(m.group(1)) if m else -1
        f = re.search(r"frame (\d+\.\d) ms avg", shown)
        want = 0.3 / float(f.group(1)) * 1000 if f and float(f.group(1)) > 0 else -1
        check(want > 0 and abs(got - want) <= 0.35 * want,
              "a real 0.3 ms mod reads 0.3 ms over the frame (%.0f ms/s expected): %r" % (want, shown))
        # Frames here are ~0.4 ms of real time, so even an empty mod's few
        # microseconds can reach 10 ms/s: compare with the spinning mod.
        e = re.search(r"\|std +(\d+\.\d)", shown)
        check(e is None or (got > 0 and float(e.group(1)) < got / 20),
              "a mod that does nothing reads next to nothing: %r" % shown)
    with session() as s:
        load(s, ["finder"])
        s.frames(5)
        timer = log_lines(s, r"timer: ")
        check(bool(timer) and "os.clock" in timer[0], "without ffi: os.clock, and says so: %r" % timer)


def native_case():
    """The real ReadProcessMemory path, on this test process's own memory.

    The seam replaces every native read, so nothing above reaches the ffi
    code (Carpet Bomb Probe v1 passed every seam test and died on its first
    real read). Here ffi is allowed and a copy of a harmless system DLL is
    loaded as game.dll: the finder must read its MZ and PE headers for real
    and switch the menu window off because the build is not the pinned one.
    Without any game.dll it must say so and carry on.
    """
    print("native")
    system = os.environ.get("SystemRoot", r"C:\Windows")
    # First: once loaded, a DLL stays in this process for good.
    with Session(backend=BACKEND, ffi="allow") as s:
        s.lua(CLOCK)
        s.lua("FAKE.mission()")
        load(s, ["finder"])
        s.frames(60)
        check(bool(log_lines(s, r"escape menu window off \(Home still works\): game\.dll not found")),
              "no game.dll in the process: off, and says so: %r" % log_lines(s, "escape menu"))
        check(not log_lines(s, "anti-cheat|GameGuard"),
              "no process list is read: %r" % log_lines(s, "anti-cheat|GameGuard"))
        r = s.report()
        check(not r["dead"] and not r["uncaught"], "nothing dies without game.dll")
    with Session(backend=BACKEND, ffi="allow") as s:
        stand_in = os.path.join(s.scratch, "game.dll")
        shutil.copyfile(os.path.join(system, "System32", "version.dll"), stand_in)
        s.lua(NATIVE_STAND_IN % lua_literal(stand_in))
        s.lua(CLOCK)
        s.lua("FAKE.mission()")
        load(s, ["finder"])
        s.frames(60)
        line = log_lines(s, "escape menu window")
        check(len(line) == 1 and re.search(r"off \(Home still works\): game\.dll stamp 0x[0-9A-F]+ "
                                           r"image 0x[0-9A-F]+; the menu offsets are for "
                                           r"0x6AB3B43F 0x4744000", line[0]) is not None,
              "real reads of the stand-in's headers, refused as another build: %r" % line)
        r = s.report()
        check(not r["dead"] and not r["uncaught"], "nothing dies (%s)"
              % s.explain(r).replace("\n", " | "))


GIB = 1073741824


def gpu_case():
    """Video memory over budget (v0.12.1), through the test seam's gpu():
    nothing on screen or in the window while under budget; over budget an
    amber line in play for 8 s, at most once a minute, and a window line
    while it lasts; every 60 s summary logs a "vram:" line; a seam without
    gpu() switches it off and says so."""
    print("vram")
    with session() as s:
        s.lua(GUI_STUB)
        s.lua(menu_stub())
        s.lua("GPU = { usage = 8 * 2^30, budget = 14 * 2^30 }\n"
              "__hd2_native_test.gpu = function() return GPU.usage, GPU.budget end")
        load(s, ["std", "finder"])
        check(bool(log_lines(s, r"vram: test seam")), "the seam's gpu is used: %r" % log_lines(s, "vram:"))
        s.frames(600)                                   # ~10 s in play
        check(s.eval("GUI_CALLS") == "0", "in play, under budget: nothing drawn (%s GUI calls)"
              % s.eval("GUI_CALLS"))
        check(bool(log_lines(s, r"vram: first reading 8\.00 of 14\.00 GB budget")),
              "the first reading is logged: %r" % log_lines(s, "vram:"))
        s.lua("MENU_STATE(1, 0)")                       # escape menu, GAME tab
        s.frames(6)
        shown = s.eval("SHOWN()")
        check("VRAM" not in shown and "GPU" not in shown and "MOD LAG WATCHDOG" in shown,
              "under budget the window has no video memory line: %r" % shown)
        s.lua("MENU_STATE(4, 0)")                       # back in play
        s.frames(6)
        s.lua("GPU.usage = 15 * 2^30")
        s.frames(90)
        shown = s.eval("SHOWN()")
        check("VRAM 15.0 / 14.0 GB - over budget" in shown, "over budget shows in play: %r" % shown)
        s.lua("MENU_STATE(1, 0)")
        s.frames(6)
        shown = s.eval("SHOWN()")
        check("VRAM 15.0 / 14.0 GB - over budget" in shown and "MOD LAG WATCHDOG" in shown,
              "and in the window while it lasts: %r" % shown)
        s.lua("MENU_STATE(4, 0)")
        s.frames(60 * 20)
        check(len(log_lines(s, r"vram: VRAM .* over budget")) == 1,
              "still over 20 s later: no second alert yet: %r" % log_lines(s, "over budget"))
        s.frames(60 * 45)
        check(len(log_lines(s, r"vram: VRAM .* over budget")) == 2,
              "a minute on: alerted again: %r" % log_lines(s, "over budget"))
        s.lua("GPU.usage = 8 * 2^30")
        s.frames(60 * 70)
        check(len(log_lines(s, r"vram: VRAM .* over budget")) == 2, "back under budget: no more alerts")
        s.lua("MENU_STATE(1, 0)")
        s.frames(6)
        check("VRAM" not in s.eval("SHOWN()"), "and the window line is gone: %r" % s.eval("SHOWN()"))
        summary = log_lines(s, r"^t=[\d.]+\s+vram: max [\d.]+ of 14\.00 GB budget; read worst")
        check(len(summary) >= 2 and any("max 15.00" in l for l in summary),
              "each 60 s summary has a vram line: %r" % summary[:3])
        check(not log_lines(s, r"GPU \d+%|busy"), "no GPU busy anywhere in the log")
        clean(s, "vram")
    with session() as s:
        s.lua(menu_stub())                              # a seam without gpu()
        load(s, ["finder"])
        s.frames(120)
        check(bool(log_lines(s, r"vram: off \(the test seam has no gpu\)")), "no gpu in the seam: off, and says so")
        s.frames(3800)
        check(bool(log_lines(s, r"summary 60 s")) and not log_lines(s, r"vram: max"), "and no vram summary line")


def gpu_native_case():
    """The real dxgi call, in this test process (ffi allowed, no seam): the
    adapters are found and readings are taken, across a garbage collection,
    without an error. This process draws nothing, so its usage is ~0; the
    numbers are not checked, the calls are."""
    print("vram native")
    with Session(backend=BACKEND, ffi="allow") as s:
        s.lua(CLOCK)
        s.lua("FAKE.mission()")
        s.lua(GUI_STUB)
        load(s, ["finder"])
        told = log_lines(s, r"vram: ")
        check(bool(told) and re.search(r"vram: dxgi, \d+ adapters", told[0]) is not None,
              "real dxgi set up: %r" % told[:1])
        s.frames(3000)
        # LuaJIT unloads a library when its ffi.load namespace is collected;
        # a reading after that calls into nothing (v0.12.0's pdh.dll crashed
        # the process here). Collect, then keep reading for real seconds.
        s.lua("collectgarbage('collect'); collectgarbage('collect')")
        started = time.time()
        while time.time() - started < 2.5:            # readings are once a real second
            s.frames(200)
            time.sleep(0.05)
        first = log_lines(s, r"vram: first reading [\d.]+ of [\d.]+ GB budget")
        check(len(first) == 1, "readings were taken: %r" % log_lines(s, "vram:"))
        check(not log_lines(s, r"vram: read failed"), "no read failed: %r" % log_lines(s, "vram: read"))
        r = s.report()
        check(not r["dead"] and not r["uncaught"], "nothing dies (%s)" % s.explain(r).replace("\n", " | "))


def static():
    print("static")
    src = finder_source()
    for word in ("popen", "execute", "Unit.", "GameSession", "_G.update =",
                 "World.units", "link_particles", "WriteProcessMemory",
                 "VirtualProtect", "VirtualAlloc", "NtQuerySystemInformation"):
        check(word not in src, "source does not use %s" % word)
    check(src.startswith("-- HD2-Addon: mods/patpatpatrick/mod_lag_finder\n"),
          "declared for loader discovery")


def main():
    global BACKEND, SOURCE
    if "--backend" in sys.argv:
        BACKEND = sys.argv[sys.argv.index("--backend") + 1]
    if "--source" in sys.argv:
        SOURCE = os.path.join(HERE, "mod_lag_finder_src", "mod_lag_finder.lua")
    static()
    map_case()
    retry_case()
    stall_case()
    rehook_case()
    mdl_case()
    names_case()
    deploy_case()
    writes_case()
    top_case()
    inside_case()
    same_case()
    restore_case()
    screen_case()
    quiet_case()
    menu_case()
    patched_case()
    memory_case()
    units_case()
    report_case()
    switch_case()
    alerts_case()
    small_case()
    boot_case()
    bootstrap_case()
    hash_case()
    patch_case()
    review_errors_case()
    review_remap_case()
    review_no_shutdown_case()
    review_rearm_gap_case()
    review_pending_case()
    review_shutdown_once_case()
    soak_case()
    timer_case()
    gpu_case()
    gpu_native_case()
    native_case()
    real_case()
    if FAILURES:
        print("FAILED %d:" % len(FAILURES))
        for f in FAILURES:
            print("  " + f)
        sys.exit(1)
    print("all mod lag finder cases pass")


if __name__ == "__main__":
    main()
