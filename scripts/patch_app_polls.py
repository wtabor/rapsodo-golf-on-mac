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

Usage: patch_app_polls.py [--revert] <app.asar>
"""

import mmap
import sys
from pathlib import Path

EDITS = [
    ("game check", b"Pae = 1e3, Bae = () => {", b"Pae = 6e4, Bae = () => {"),
    ("Wi-Fi poll", b"WIFI_INTERVAL_TIME=15e3,", b"WIFI_INTERVAL_TIME=36e5,"),
]


def main() -> int:
    revert = sys.argv[1:2] == ["--revert"]
    asar = Path(sys.argv[-1])
    rc = 0
    with open(asar, "r+b") as f, mmap.mmap(f.fileno(), 0) as m:
        for name, orig, new in EDITS:
            find, put = (new, orig) if revert else (orig, new)
            if m.find(put) >= 0 and m.find(find) < 0:
                print(f"{name}: already {'reverted' if revert else 'patched'}")
                continue
            pos = m.find(find)
            if pos < 0 or m.find(find, pos + 1) >= 0:
                print(f"{name}: not found exactly once in {asar}; skipped", file=sys.stderr)
                rc = 1
                continue
            m[pos : pos + len(put)] = put
            print(f"{name}: {'reverted' if revert else 'patched'} at offset {pos}")
        m.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main())
