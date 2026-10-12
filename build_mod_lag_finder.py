"""Package Mod Lag Watchdog (was Mod Lag Finder) as a loader-v15 addon.

Times each mod's share of every frame by walking the _G.update chain (see
the header of mod_lag_finder.lua), logs every frame of 50 ms or more by mod,
shows a one-line alert when one mod causes a stall and a panel on Home.
"""

import json
import os
import shutil
import struct
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from hashing import murmur64_hash  # noqa: E402
import modpaths  # noqa: E402
import spawn  # noqa: E402
from hd2fake.gate import gate_release  # noqa: E402

SOURCE = os.path.join(HERE, "mod_lag_finder_src", "mod_lag_finder.lua")
TEMPLATE = os.path.join(HERE, "lua_archive_template.bin")
ADDON = "mods/patpatpatrick/mod_lag_finder"
LUA_T = 0xA14E8DFA2CD117E2
PAYLOAD_FLAG = 2
VERSION = "v0.39.0"
MOD = "Mod Lag Watchdog"
# A build is a local test build unless the user says it goes to Nexus (the
# user, 2026-09-30): then the release name has no "Nexus" and the manifest
# Name carries the version, so the mod manager shows which build is in.
# For a Nexus upload set True: the manager shows Nexus's version, so the
# Name is the plain mod name (the user, 2026-09-28).
NEXUS = False
RELEASE = MOD + " " + VERSION + (" Nexus" if NEXUS else "")
FOLDER = "Mod Lag Watchdog"
BUILD_MARKER = "mod-lag-finder-" + VERSION

MANIFEST = {
    "Version": 1,
    "Guid": "083f13c2-b41a-47c1-8a87-b3c9fa6be83d",
    "Name": MOD if NEXUS else RELEASE,
    "Description": "Shows which Lua mod makes your game stutter: an alert names "
                   "the mod behind a stall, and a cost table sits on the pause "
                   "menu (Home in play).",
    "Options": [{
        "Name": "Mod Lag Watchdog",
        "Description": "The only option.",
        "Include": [FOLDER],
    }],
}

README = """Mod Lag Watchdog
================

Shows which Lua mod is making your game stutter.

- When one mod causes a long stall, a line names it for a few seconds.
- Open the pause menu (GAME tab) for a table of each mod's cost. Drag it by
  its title bar; right-click the title bar to put it back. Click [-] on the
  title bar to fold it away, [+] to open it again.
- Two switches in that window: "show table in missions" (or press Home)
  and "show alerts in missions". With both off nothing is drawn in a mission.
- In the pause menu every mod is listed; those under 10 ms/s in grey.
- Click a mod in that window to copy a short report for its author.
- If the game uses more video memory than Windows gives it (which causes
  stutter), a line says so.
- If a mod's Lua error closes the game, the log names the mod first, and
  the next launch shows it once on the ship.
- If a mod keeps raising Lua errors that another mod hides, a line names it.

The pause-menu window needs the game version this release was made for.
After a game update, Home still works.

Requires Bingus Shared Loader v15 or later.
"""

def write_module(out_dir, resource_name, source):
    template = open(TEMPLATE, "rb").read()
    ntypes, nfiles = struct.unpack_from("<II", template, 4)
    if (ntypes, nfiles) != (1, 1) or len(template) != 0x48 + 32 + 80:
        raise SystemExit("archive template is not a single-resource scaffold")
    encoded = source.encode("utf-8")
    payload = struct.pack("<2I", len(encoded), PAYLOAD_FLAG) + encoded
    out = bytearray(template)
    row = 0x48 + ntypes * 32
    struct.pack_into("<3Q", out, row,
                     murmur64_hash(resource_name.encode("utf-8")),
                     LUA_T, len(template))
    struct.pack_into("<I", out, row + 56, len(payload))
    os.makedirs(out_dir, exist_ok=True)
    path = os.path.join(out_dir, "9ba626afa44a3aa3.patch_0")
    open(path, "wb").write(bytes(out) + payload)
    open(path + ".gpu_resources", "wb").close()
    open(path + ".stream", "wb").close()


def run_check(script, why):
    check = spawn.run([sys.executable, os.path.join(HERE, script), SOURCE],
                           capture_output=True, text=True)
    sys.stdout.write(check.stdout)
    if check.returncode != 0:
        sys.stdout.write(check.stderr)
        raise SystemExit(why)


def build_id(source):
    """The build id the Watchdog logs at load (v0.39.0): run the released Lua
    once in hd2fake, on the game's own lua51.dll, and read its "build:" line.
    The same bytecode the game makes, so the id matches the one in game."""
    import re
    from hd2fake import Session
    with Session() as s:
        s.lua("FAKE.mission()")
        s.load_mod(source=source, name=ADDON)
        s.frames(2)
        log = s.file("mod_lag_finder.log", "") or ""
    m = re.search(r"build: ([0-9a-f]{12}) ", log)
    return m.group(1) if m else None


def build():
    source = open(SOURCE, encoding="utf-8").read()
    run_check("check_lua51_syntax.py", "probe Lua does not parse -- refusing to package")
    run_check("check_lua_locals.py",
              "a file-scope local is used above its declaration -- that reads a "
              "nil global at runtime and says nothing until it is indexed")

    declaration = "-- HD2-Addon: " + ADDON + "\n"
    if source.encode("utf-8")[:3] == b"\xef\xbb\xbf":
        raise SystemExit("probe Lua starts with a BOM")
    if not source.startswith(declaration):
        raise SystemExit("probe Lua does not open with %r" % declaration)
    if NEXUS and (VERSION in MANIFEST["Name"] or MANIFEST["Name"] != MOD):
        raise SystemExit("a Nexus build's Name is the plain mod name")
    if ('local MARKER = "%s"' % BUILD_MARKER) not in source:
        raise SystemExit("probe Lua does not carry the build marker %s" % BUILD_MARKER)
    for banned in ("popen", "execute", "WriteProcessMemory", "VirtualProtect", "NtQuerySystemInformation",
                   "VirtualAlloc"):
        if banned in source:
            raise SystemExit("Lua mentions %r; it only ever reads memory" % banned)

    OUT, zip_path = modpaths.out_paths(MOD, RELEASE)
    os.makedirs(OUT)
    # No ungated or half-written folder may stay behind for modpaths.find to
    # pick up, or block the next build of this version (v0.13.3, review [15];
    # v0.15.0, review [10]: from the first write on, and on any exit).
    try:
        write_module(os.path.join(OUT, FOLDER), ADDON, source)
        with open(os.path.join(OUT, "manifest.json"), "w", encoding="utf-8") as out:
            json.dump(MANIFEST, out, indent=2, ensure_ascii=False)
            out.write("\n")
        with open(os.path.join(OUT, "README.txt"), "w", encoding="utf-8",
                  newline="\r\n") as out:
            out.write(README)
        gate_release(OUT)      # raises GateFailed: do not zip
    except BaseException:
        shutil.rmtree(OUT, ignore_errors=True)
        raise

    count = 0
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as bundle:
        for base, _dirs, files in os.walk(OUT):
            for name in sorted(files):
                full = os.path.join(base, name)
                bundle.write(full, os.path.relpath(full, OUT))
                count += 1
    print("lua bytes %d -> %s" % (len(source.encode("utf-8")), ADDON))
    # The official build ids, one line a release (v0.39.0): a changed copy
    # someone passes on shows another id in its log and reports.
    from hd2fake.sources import lua_from_release
    ident = build_id(lua_from_release(OUT, FOLDER))      # the bytes that ship
    if ident is None:
        raise SystemExit("the released Lua logs no build id")
    builds = os.path.join(os.path.dirname(os.path.dirname(OUT)), "builds.txt")
    with open(builds, "a", encoding="utf-8") as out:
        out.write("%s\t%s\n" % (RELEASE, ident))
    print("build id %s (listed in %s)" % (ident, builds))
    print("wrote %s (%d files, %d bytes)"
          % (zip_path, count, os.path.getsize(zip_path)))


if __name__ == "__main__":
    build()
