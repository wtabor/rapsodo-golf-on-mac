#!/usr/bin/env bash
# Builds rgm-display-fix.exe (display_fix.c). Wine keeps a stale display layout
# after a monitor is plugged in or unplugged while it runs; fullscreen games then
# use the wrong screen size and the cursor can't reach part of the screen.
# play.sh runs the helper's watcher next to the app, which repairs the layout after
# each change. Rebuilds only when the source is newer.
set -euo pipefail
. "$(dirname "$0")/env.sh"

src="$(dirname "$0")/display_fix.c"
exe="$RGM_BUILD/rgm-display-fix.exe"
if [ ! -f "$exe" ] || [ "$src" -nt "$exe" ]; then
  command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "brew install mingw-w64" >&2; exit 1; }
  mkdir -p "$RGM_BUILD"
  x86_64-w64-mingw32-gcc -municode -O2 -s -o "$exe.tmp" "$src" -luser32 -ladvapi32 -lntdll
  mv -f "$exe.tmp" "$exe"
fi
echo "display fix ready: $exe"
