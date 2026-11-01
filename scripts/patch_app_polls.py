#!/usr/bin/env python3
"""Patch app.asar so the app starts far fewer Windows processes.

Each Windows process Wine starts is a few Rosetta processes, and macOS's
ecosystemd analyzes every one (about 15 code-signature/Rosetta checks per process
start, ~20-25 per second at most). The app starts processes on two timers:

- While a game runs it polls `cmd /c tasklist` every 1 s to see whether the game is
  still up (cmd + conhost + tasklist = 3 processes per second). That outran
  ecosystemd: it kept a core busy for minutes after a game. The poll is only a
  fallback; the app already learns the game closed when the `cmd /c` child that
  started it exits. 1 s -> 60 s.
- The device popup polls `cmd /c netsh wlan show interfaces` every 15 s for the
  Wi-Fi name and signal. Under Wine there is no Wi-Fi data (the monitor is on USB),
  so it always comes back empty. 15 s -> 1 h (it still reads once when shown).

Both edits are the same length, so the asar index stays valid (the asar integrity
fuse is off in this build). Each edit is applied or reverted on its own; one that
isn't found exactly once is skipped with a warning (exit status 1).

The game check's timer is a minified variable (`Pae` in 1.0.0, `due` in the 0.6.0 test
build, where the surrounding code changed too), so it is found by structure: the
`setInterval(..., <var>)` right after the app's only "DEBUG: game is running" log, then
that variable's one `<var> = 1e3,` shortly before it.

Usage: patch_app_polls.py [--revert] <app.asar>
"""

import mmap
import re
import sys
from pathlib import Path

GAME_LOG = b"DEBUG: game is running"
GAME_ORIG, GAME_NEW = b"1e3", b"6e4"
WIFI_ORIG, WIFI_NEW = b"WIFI_INTERVAL_TIME=15e3,", b"WIFI_INTERVAL_TIME=36e5,"


def game_check_sites(m) -> dict:
    """Offsets of the game-check timer's value: {b"1e3": [...], b"6e4": [...]}."""
    sites = {GAME_ORIG: [], GAME_NEW: []}
    log = m.find(GAME_LOG)
    if log < 0 or m.find(GAME_LOG, log + 1) >= 0:
        return sites
    use = re.compile(rb"\}, ([\w$]+)\);").search(m, log, log + 1000)
    if not use:
        return sites
    for value in sites:
        decl = re.compile(rb"(?<![\w$.])" + re.escape(use.group(1)) + rb" = " + value + rb",")
        sites[value] = [d.end() - len(value) - 1 for d in decl.finditer(m, max(0, log - 20000), log)]
    return sites


def main() -> int:
    args = sys.argv[1:]
    revert = args[:1] == ["--revert"]
    if revert:
        args = args[1:]
    if len(args) != 1:
        # A missing path must not make sys.argv[-1] this script itself.
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    asar = Path(args[0])
    rc = 0
    with open(asar, "r+b") as f, mmap.mmap(f.fileno(), 0) as m:
        # (name, offsets of the text to replace, offsets already replaced, replacement)
        sites = game_check_sites(m)
        wifi = {v: [i.start() for i in re.finditer(re.escape(v), m)] for v in (WIFI_ORIG, WIFI_NEW)}
        edits = [
            ("game check", sites[GAME_NEW], sites[GAME_ORIG], GAME_ORIG) if revert
            else ("game check", sites[GAME_ORIG], sites[GAME_NEW], GAME_NEW),
            ("Wi-Fi poll", wifi[WIFI_NEW], wifi[WIFI_ORIG], WIFI_ORIG) if revert
            else ("Wi-Fi poll", wifi[WIFI_ORIG], wifi[WIFI_NEW], WIFI_NEW),
        ]
        for name, find, done, put in edits:
            if done and not find:
                print(f"{name}: already {'reverted' if revert else 'patched'}")
                continue
            if len(find) != 1:
                print(f"{name}: not found exactly once in {asar}; skipped", file=sys.stderr)
                rc = 1
                continue
            m[find[0] : find[0] + len(put)] = put
            print(f"{name}: {'reverted' if revert else 'patched'} at offset {find[0]}")
        m.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main())
