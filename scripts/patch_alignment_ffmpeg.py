#!/usr/bin/env python3
"""Patch app.asar so the alignment camera view plays at full frame rate.

For alignment the app re-encodes each monitor camera with ffmpeg (libx264,
"-tune zerolatency") and plays it over WebRTC. zerolatency turns on x264's
sliced threads: one slice per core, so 10 slices per frame on an M-series Mac.
The app's Chromium (Electron 30, Chrome 124, under Wine) only assembles the
keyframes of such a stream, so the live view shows about 1 fps (-g 30). Native
Chromium plays the same stream at 30 fps. This adds
"-x264-params sliced-threads=0:threads=4" (one slice, 4 frame threads), which
plays at about 29 fps in the app. The edit is the same length (whitespace absorbs
the difference), so the asar index stays valid; Electron's asar integrity fuse is
off in this build.

Usage: patch_alignment_ffmpeg.py [--revert] <app.asar>
"""

import mmap
import sys
from pathlib import Path

ORIG = (
    b'"-c:v",\n    "libx264",\n    "-preset",\n    "ultrafast",\n    "-tune",\n'
    b'    "zerolatency",\n    "-g",\n    "30",\n    "-an",\n    "-f",\n    "rtsp",'
)
NEW = (
    b'"-c:v","libx264","-preset","ultrafast","-tune","zerolatency",'
    b'"-x264-params","sliced-threads=0:threads=4","-g","30","-an","-f","rtsp",'
)
NEW = NEW.ljust(len(ORIG))


def main() -> int:
    revert = sys.argv[1:2] == ["--revert"]
    asar = Path(sys.argv[-1])
    find, put = (NEW, ORIG) if revert else (ORIG, NEW)
    with open(asar, "r+b") as f, mmap.mmap(f.fileno(), 0) as m:
        if m.find(put) >= 0 and m.find(find) < 0:
            print(f"already {'reverted' if revert else 'patched'}: {asar}")
            return 0
        pos = m.find(find)
        if pos < 0 or m.find(find, pos + 1) >= 0:
            print(f"ffmpeg arguments not found exactly once in {asar}; not patching", file=sys.stderr)
            return 1
        m[pos : pos + len(put)] = put
        m.flush()
    print(f"{'reverted' if revert else 'patched'} {asar} at offset {pos}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
