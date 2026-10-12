# mod_lag_watchdog.json

Mod Lag Watchdog writes this file so that mod managers and other tools can show what it measured. They do not need to read its log or change its code. The format is open, and any tool may read the file. Only the Watchdog writes it.

## Where and when

- **Path:** `%APPDATA%\Arrowhead\Helldivers2\mod_lag_watchdog.json`, next to `mod_lag_finder.log`. The file exists from Watchdog 0.40.0.
- **Encoding:** UTF-8 JSON, one object. Names from a mod manager keep their own characters.
- **Written whole, at two moments only, never during play:**
  1. **When the game closes normally:** the whole session. `session.ended_how` is `"closed"`.
  2. **At the next launch, while the game loads,** if the previous session never closed (a crash or a forced close). The record holds what the Watchdog's black box kept: the numbers of the last minute summary before the end, and the crash verdict when a crash dump proves a crash.
- The Watchdog writes `mod_lag_watchdog.json.tmp` first and then renames it, so a reader never sees half a file. Between the old file's removal and the rename, the file can briefly be missing; read it again a moment later.
- There are no full paths, Windows user names or player names in it. A mod's `folder` is the name of its own folder only.

## Top level

| Field | Type | Meaning |
|---|---|---|
| `format` | string | Always `"mod-lag-watchdog"`. |
| `version` | number | `1` for this layout. A change that breaks readers will raise it. New fields may be added without raising it. |
| `watchdog` | object | `version`, e.g. `"0.40.0"`. `build` is a 12-hex-digit fingerprint of the running code. The ids of official builds are listed with each release; a different id means the copy was changed. |
| `manager` | string or null | The mod manager whose list named the mods: `"Arsenal"` or `"Echelon"`. Null if neither list was found. |
| `session` | object | See below. |
| `mods` | array | One entry for each mod with measured time, costliest first. See below. |
| `warnings` | array | The warnings the Watchdog gave during the session. See below. |
| `crash` | object or null | Only when the session crashed. See below. |

## `session`

| Field | Type | Meaning |
|---|---|---|
| `started`, `ended` | string or null | Local time, `"YYYY-MM-DD HH:MM:SS"`. For a crash, `ended` is the crash dump's time. It is null when unknown. |
| `ended_how` | string | `"closed"` (normal exit), `"crashed"` (a crash dump written after the session began), or `"unknown"` (the session never closed and there is no crash dump, e.g. a forced close). |
| `minutes_played` | number | Minutes that were measured. After a crash, this counts up to the last minute summary. |
| `fps_average` | number | Frames per second over those minutes. |
| `game_build` | string or null | The game build the Watchdog checked, e.g. `"6AB3B43F"`. |
| `stalls_50ms`, `stalls_200ms` | number | Frames that took 50 ms or more, and 200 ms or more. |

## `mods[]`

| Field | Type | Meaning |
|---|---|---|
| `key` | string | The script's own name, e.g. `"mods/codex/gun_calibration"`. `"(the game)"` is the game's own update and the scripts that replace the game's own scripts. A key ending in `" (+ all below)"` counts every mod below it in the chain. |
| `name` | string | The name the Watchdog's table shows. It is ASCII, because the in-game font has Latin letters only. |
| `manager_name` | string or null | The mod's name in the mod manager, in any characters. Null when no manager list names it. |
| `folder` | string or null | The mod's folder name in the mod manager, never a full path. |
| `ms_per_s` | number | Milliseconds of each second the mod took, averaged over the session. This is the table's main number: 10 or more is worth a look, 50 or more is heavy. |
| `worst_minute_ms_per_s` | number | The highest one-minute average. |
| `worst_frame_ms` | number | The longest single frame of the mod. |
| `render_ms_per_s` | number | The part of `ms_per_s` the mod spent in the game's render step. Most mods have 0. |
| `stalls_caused`, `worst_stall_ms` | number | Stalls of 150 ms or more that were put on this mod, and the longest one. |
| `lua_errors` | number | Frames in which the mod raised a Lua error. |
| `lua_memory_kb` | number or null | The Lua memory the mod held at the last count. Null after a crash. |
| `helper_units` | object or null | `alive`, `most` and `older_than_10_min` count the units the mod spawned (lamps, beams, ...). Null if it spawned none. |
| `flags` | array of strings | `"on_top_not_timed"`: the mod's outermost hook was above the Watchdog, so that layer's own time is not counted. `"hooked_N_times"`: the same function was hooked N times. `"until_the_last_minute"`: the record was rebuilt after a crash, so the numbers stop at the last minute summary. |
| `shared_script` | boolean | `true` if two enabled mods ship this script. Only one of them runs, so `manager_name` is left out. |

After a crash, `mods` holds the 20 costliest mods of the last minute summary. Fields the black box does not keep are null.

## `warnings[]`

Each entry has three fields:
- `type`: `"MEM"`, `"UNITS"`, `"REHOOK"`, `"LUA_ERRORS"` or `"VRAM"`;
- `key`: the mod's key, or null;
- `text`: the line the player saw.

## `crash`

| Field | Type | Meaning |
|---|---|---|
| `key`, `name` | string or null | The mod whose update was running when the game crashed. Null when no mod is named. |
| `shown` | boolean | Whether the next launch showed "LAST CRASH: the game crashed while <mod> was running". That line appears only when the crash was on the thread the mods run on, inside a timed mod's update. |
| `on_mods_thread` | boolean | Whether the crash happened on that thread. Crashes on other threads (render, exit) name no mod. |
| `dump` | string | The crash dump's file name in `%APPDATA%\Arrowhead\Helldivers2\dumps`. |
| `exception`, `where` | string | The exception code, e.g. `"0xC0000005"`, and the module plus offset, e.g. `"helldivers2.exe+0x438087"`. |

## Example (closed session, shortened)

```json
{"format": "mod-lag-watchdog", "version": 1,
 "watchdog": {"version": "0.40.0", "build": "82d49ba8403f"},
 "manager": "Arsenal",
 "session": {"started": "2026-10-13 20:01:12", "ended": "2026-10-13 20:44:03", "ended_how": "closed",
             "minutes_played": 42.8, "fps_average": 88.4, "game_build": "6AB3B43F",
             "stalls_50ms": 31, "stalls_200ms": 4},
 "mods": [
  {"key": "mods/codex/gun_calibration", "name": "Overlay",
   "manager_name": "HUD Ballistic Trajectory Overlay", "folder": "HUD Ballistic Trajectory Overlay 15842 9",
   "ms_per_s": 34.2, "worst_minute_ms_per_s": 66.3, "worst_frame_ms": 6.4, "render_ms_per_s": 30.1,
   "stalls_caused": 0, "worst_stall_ms": 0, "lua_errors": 0, "lua_memory_kb": 1830,
   "helper_units": null, "flags": [], "shared_script": false}
 ],
 "warnings": [],
 "crash": null}
```

## Questions

Ask on the Watchdog's Nexus page. Format changes will be announced there first.
