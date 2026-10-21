#!/usr/bin/env bash
# Download Gcenx's wine-staging build (unsigned; Homebrew disabled its casks on
# 09/01/2026 for failing Gatekeeper) into $RGM_HOME and create a fresh prefix.
set -euo pipefail
. "$(dirname "$0")/env.sh"

mkdir -p "$RGM_HOME"
if [ ! -x "$RGM_WINE_BIN/wine" ]; then
  echo "Downloading wine-staging $RGM_WINE_VERSION..."
  curl -fL --progress-bar -o "$RGM_HOME/wine.tar.xz" "$RGM_WINE_URL"
  tar -xf "$RGM_HOME/wine.tar.xz" -C "$RGM_HOME"
  rm -f "$RGM_HOME/wine.tar.xz"
fi
"$RGM_WINE_BIN/wine" --version

if [ ! -f "$RGM_PREFIX/system.reg" ]; then
  echo "Creating Wine prefix at $RGM_PREFIX..."
  WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all "$RGM_WINE_BIN/wineboot" --init >/dev/null 2>&1
  WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -w
fi
echo "Wine ready."
