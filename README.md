# Mod Lag Watchdog

A Helldivers 2 Lua mod that shows **which mod makes your game stutter**. It times every Lua mod, every frame, and tells you which one to look at.

- **Download (players):** [Nexus Mods page](NEXUS_URL) (or the zips under [Releases](../../releases)).
- **Needs:** Bingus Shared Loader v15 or later.
- **Mod managers:** works with any. With **Arsenal** or **Echelon** (0.36.2+), mods are shown under their names in the manager.

## What you see

- **A one-line alert** when one mod causes a stall of 150 ms or more, e.g. `LAG 303 ms - Where's My Shit?`.
- **A cost table** on the pause menu, and in missions if you turn it on (Home):
  - **ms/s**: how much of each second a mod takes. Under 10 is nothing; 50 or more is heavy.
  - **worst**: its longest single frame in the last 30 s.
  - Click a column header to sort by it.
  - Click a mod to copy a short report for its author.
- **Warnings:**
  - **REHOOK**: mods hooking over each other.
  - **MEM**: a Lua memory leak.
  - **UNITS**: piled-up helper units.
  - **VRAM**: over the video memory budget.
  - **ERROR**: a mod that keeps raising Lua errors.
- **LAST CRASH** on the ship after a crash, naming the mod when this can be shown:
  - a mod's Lua error;
  - a crash while mods were loading;
  - a crash in play on the thread the mods run on, inside a mod's update. A small mapped-memory "black box" records this at no disk cost.
- **Render time:** a mod that works in the game's render step, not only in its update, is timed there too, and its row shows both.

## What it reads, and what it does not do

To check this, read `mod_lag_finder_src/mod_lag_finder.lua`. The Watchdog does the following, all read-only:
- times each mod with Windows' high-resolution timer;
- reads a few bytes of the game's own memory to see the pause menu (`ReadProcessMemory`);
- asks Windows (DXGI) about video memory;
- reads Lua's own garbage-collector counters;
- reads the mod manager's mod list (Arsenal's `hd2a_data.json`, Echelon's `library.json`);
- reads the header of the newest crash dump after a crash.

It writes only these files in `%APPDATA%\Arrowhead\Helldivers2\`:
- its log, `mod_lag_finder.log`;
- its window settings;
- the crash record and black box, `mod_lag_finder_crash.txt` and `mod_lag_finder_box.bin`;
- the results file `mod_lag_watchdog.json`, described below.

It does not:
- write to game memory;
- change any mod's behaviour (errors from other mods reach the game unchanged);
- use the network.

## Official builds

Every copy shows a **build id**, a fingerprint of the code that is actually running. It appears in the log's `build:` line, in every copied report and in the mod list. A copy that was changed shows a different id.

| Version | Build id |
|---|---|
| 0.41.0 | `51f7bbb1c3e0` |
| 0.40.1 | `e833638944fd` |
| 0.40.0 | `82d49ba8403f` |
| 0.39.0 | `ea0297414737` |

If your id is not in this table, your copy is not an official build. Please report problems with such a copy to whoever made it.

## For mod managers and tools

Mod managers are welcome to integrate the Watchdog. The intended way needs no change to its code:

1. **Install the official zip** from Releases or Nexus as an ordinary mod. Compare its SHA-256 with the one listed on the release.
2. **Read its results** from `%APPDATA%\Arrowhead\Helldivers2\mod_lag_watchdog.json`. This file is written when the game closes, and at the next launch after a crash. It holds every mod's cost, its stalls, the warnings and the crash verdict. The format is documented in [DATA_JSON.md](DATA_JSON.md).
3. **Give it names:** if your manager keeps a public list of the user's mods, the Watchdog can show your names in game. Echelon's `library.json` is read today. Open an issue to add another format.

If you need something the file does not give you, please open an issue rather than changing the Watchdog. That way every copy stays the same and keeps a matching build id.

## Licence and name

- **The code:** Mozilla Public License 2.0 (see [LICENSE](LICENSE)).
  - You may use, change and redistribute it, including inside a mod manager.
  - Files of this project that you change must stay under the MPL, with their source available.
- **The name:**
  - Unchanged official builds may be passed on and bundled under the name "Mod Lag Watchdog".
  - A changed copy must not be called "Mod Lag Watchdog" and must not present itself as an official build. Give it another name and say it is based on this project.

## Reporting a problem

Open an issue. Please include:
- the **build id** from the log's `build:` line;
- what happened, and roughly when;
- the matching lines of `%APPDATA%\Arrowhead\Helldivers2\mod_lag_finder.log`, or `mod_lag_watchdog.json`;
- your mod manager (Arsenal, Echelon, other).

## About this repository

This repository holds the mod's source (`mod_lag_finder_src/mod_lag_finder.lua`), its packaging script and its tests. The tests and the packaging script run on the author's own test harness, which is not published yet, so they will not run from this repository alone. The released zips are on the Releases page and Nexus.
