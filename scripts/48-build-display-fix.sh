#!/usr/bin/env bash
# Builds rgm-display-fix.exe (display_fix.c). Wine keeps a stale display layout
# after a monitor is plugged in or unplugged while it runs; fullscreen games then
# use the wrong screen size and the cursor can't reach part of the screen.
# play.sh runs the helper's watcher next to the app, which repairs the layout after
# each change. Rebuilds only when the source changed (by content, not mtime: an
# auto-update can install a changed source with an older mtime than the build).
set -euo pipefail
. "$(dirname "$0")/env.sh"

src="$(dirname "$0")/display_fix.c"
exe="$RGM_BUILD/rgm-display-fix.exe"
want="$(shasum -a 256 "$src" | cut -d' ' -f1)"
if [ ! -f "$exe" ] || [ "$(cat "$exe.src.sha256" 2>/dev/null)" != "$want" ]; then
  command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "brew install mingw-w64" >&2; exit 1; }
  mkdir -p "$RGM_BUILD"
  x86_64-w64-mingw32-gcc -municode -O2 -s -o "$exe.tmp" "$src" -luser32 -ladvapi32 -lntdll
  mv -f "$exe.tmp" "$exe"
  echo "$want" >"$exe.src.sha256"
fi
echo "display fix ready: $exe"
