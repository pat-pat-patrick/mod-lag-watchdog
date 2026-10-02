"""Mod Lag Watchdog comes back after losing its update link, even when
Application.main_world is called rarely.

The game itself never calls main_world - only other mods do (proven twice:
BSL + SmoothBoot + Watchdog made no calls, 2026-09-30; BSL + Helmet Headlamp
made none, 2026-10-01). The Watchdog notices a lost update link only from
inside its main_world wrapper, so how fast it comes back depends on how busy
the player's other mods are.

v0.16.1 and earlier needed 200 calls on top of 0.5 s with no tick: tens of
seconds to minutes with few callers, the Watchdog dead all that while (no
table on Home, no alerts). v0.16.2 adds 3 s with no tick as enough on its
own, as Helmet Headlamp 1.2.1 did.

Each case swaps the update chain away (FAKE.transition, as a mod that drops
its previous link or the game would) with main_world called every N frames
and nothing else, and requires the Watchdog back on _G.update within a
bound. v0.16.1 runs as the negative control at one call per 10 frames and
must be slower than 30 s, or the scenario no longer reaches the rule.

With no main_world calls at all the Watchdog cannot notice; that case is not
tested here.

    python test_mod_lag_finder_rearm_runtime.py [--backend luajit21]
"""

import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from hd2fake import Session                      # noqa: E402
from hd2fake.sources import lua_from_release     # noqa: E402
import modpaths                                  # noqa: E402

CURRENT = "Mod Lag Watchdog v0.18.0"
CONTROL = "Mod Lag Watchdog v0.16.1"
FOLDER = "Mod Lag Watchdog"
NAME = "mods/patpatpatrick/mod_lag_finder"
BACKEND = "luajit21" if "--backend" in sys.argv and "luajit21" in sys.argv \
    else "game"

# (call main_world every N frames, must be back within S seconds). At one
# call a second the bound includes the main_world watchdog's skip ceiling of
# 8 calls (Helmet Headlamp 1.2.1 measured the same 10 s).
CASES = [(1, 4.0), (10, 4.5), (60, 12.0)]

STORY = r"""
EVERY = %d
FAKE.before_frame = function(f)
  if f %% EVERY == 0 then stingray.Application.main_world() end
end
FAKE.frames(240)
local t0 = FAKE.time
-- Something replaced the chain (a re-arm test; hd2fake keeps it by default).
FAKE.transition({ gap = 0, replace_update = true })
local after = rawget(_G, "update")
local n = 0
while rawget(_G, "update") == after and n < 36000 do
  FAKE.frames(1)
  n = n + 1
end
BACK = (rawget(_G, "update") ~= after)
SECONDS = FAKE.time - t0
"""


# Long frames must not re-arm it (the 09-29 escalation: two 0.5 s-only
# watchdogs re-armed over each other, chain 33 -> 37). Twelve mods below call
# main_world twice a tick after their previous (the gate's fillers); a mod
# at the bottom holds some frames 4 s from inside update (in game single mods
# held a frame 5-7 s: Casemate Turrets, WMS, Super Beacon); between some
# frames the engine stalls 4 s (8-32 s outside update in the log); above us
# sit Helmet Headlamp 1.2.1 (the same 3 s cap) and a lid that calls
# main_world twice before its previous. Afterwards a quiet stretch: nothing
# may re-arm in it.
STALLER = r"""
STALL_AT = {}
local previous = rawget(_G, "update")
rawset(_G, "update", function(...)
  local results = { n = select("#", ...), previous(...) }
  if STALL_AT[FAKE.frame] then FAKE.time = FAKE.time + 4 end
  return unpack(results, 1, results.n)
end)
"""
EARLY_LID = r"""
local previous = rawget(_G, "update")
LID = function(...)
  stingray.Application.main_world()
  stingray.Application.main_world()
  return previous(...)
end
rawset(_G, "update", LID)
"""
GAPS = r"""
GAP_AT = {}
FAKE.before_frame = function(f)
  if GAP_AT[f] then FAKE.time = FAKE.time + 4 end
end
"""
HEADLAMP = "Helmet Headlamp v1.2.1.zip"


def stalls(source):
    from hd2fake.gate import KNOWN_TEMPLATES, REARM_FILLER
    lamp = lua_from_release(modpaths.find(HEADLAMP), "Headlamp Extension")
    with Session(backend=BACKEND, units_by_resource="exact",
                 engine_main_world_calls=0) as s:
        for res, (nodes, lights) in KNOWN_TEMPLATES.items():
            s.template(res, nodes=nodes, lights=lights)
        s.lua("FAKE.mission()")
        s.lua(GAPS)
        ok = s.load_mod(source=STALLER, name="mods/test/staller")
        for k in range(12):
            ok = s.load_mod(source=REARM_FILLER, name="mods/test/below_%d" % k) and ok
        s.lua("__mlf_test_flush = true")
        ok = s.load_mod(source=source, name=NAME) and ok
        ok = s.load_mod(source=lamp, name="Headlamp_Extension") and ok
        ok = s.load_mod(source=EARLY_LID, name="mods/test/lid") and ok
        s.frames(300)
        s.lua("G0 = __helmet_headlamp_state.generation")
        s.lua("for k = 1, 3 do STALL_AT[FAKE.frame + k * 100] = true end")
        s.lua("for k = 1, 3 do GAP_AT[FAKE.frame + 350 + k * 100] = true end")
        s.frames(800)
        mid = len(re.findall(r"update armed generation",
                             s.file("mod_lag_finder.log", "") or ""))
        s.frames(600)
        r = s.report()
        armed = len(re.findall(r"update armed generation",
                               s.file("mod_lag_finder.log", "") or ""))
        lamp_rearms = int(s.eval("__helmet_headlamp_state.generation - G0"))
        clean = ok and r["dead"] is None and not r["uncaught"]
        return clean, armed, mid, lamp_rearms


def run(source, every):
    with Session(backend=BACKEND, engine_main_world_calls=0) as s:
        s.lua("FAKE.mission()")
        loaded = s.load_mod(source=source, name=NAME)
        s.lua(STORY % every)
        r = s.report()
        back = s.eval("BACK") in (True, "true")
        return loaded and r["dead"] is None and not r["uncaught"], back, \
            float(s.eval("SECONDS"))


def main():
    current = lua_from_release(modpaths.find(CURRENT), FOLDER)
    control = lua_from_release(modpaths.find(CONTROL), FOLDER)
    failures = []
    print("current: %s" % CURRENT)
    for every, bound in CASES:
        clean, back, seconds = run(current, every)
        ok = clean and back and seconds <= bound
        print("  main_world every %2d frames: back after %5.1f s (bound %.1f) %s"
              % (every, seconds, bound, "ok" if ok else "FAIL"))
        if not ok:
            failures.append("every %d frames: %s after %.1f s%s"
                            % (every, "back" if back else "NOT back", seconds,
                               "" if clean else " (not clean)"))
    clean, back, seconds = run(control, 10)
    print("negative control %s, every 10 frames: back after %.1f s "
          "(must be > 30)" % (CONTROL, seconds))
    if not (clean and seconds > 30):
        failures.append("negative control: %s came back in %.1f s, so the "
                        "scenario does not reach the 200-call rule"
                        % (CONTROL, seconds))
    clean, armed, mid, lamp_rearms = stalls(current)
    ok = clean and armed == 1
    print("  3 stalls of 4 s inside update + 3 gaps of 4 s between frames: "
          "armed %d time(s) (%d in the quiet tail); Helmet Headlamp 1.2.1 "
          "re-armed %d (its own documented cost) %s"
          % (armed, armed - mid, lamp_rearms, "ok" if ok else "FAIL"))
    if not ok:
        failures.append("long frames: the Watchdog armed %d times%s"
                        % (armed, "" if clean else " (not clean)"))
    # Negative control: the bare 3 s cap (Headlamp 1.2.1's form) without the
    # two guards must re-arm here, or the scenario no longer reaches them.
    guard = "if (installed.depth or 0) > 0 and (at - seen) < 60 then return true end"
    bare = current.replace(guard, "")
    bare = bare.replace("(at - seen) >= 3.0 and calls >= 3", "(at - seen) >= 3.0")
    clean, armed, mid, lamp_rearms = stalls(bare)
    print("negative control, the bare 3 s cap: armed %d time(s) (must be > 1)" % armed)
    if not (clean and armed > 1 and bare != current):
        failures.append("negative control: the bare 3 s cap armed %d times, so "
                        "the long frames no longer reach the guards" % armed)
    if failures:
        print()
        for f in failures:
            print("FAIL: " + f)
        sys.exit(1)
    print("all checks passed")


if __name__ == "__main__":
    main()
