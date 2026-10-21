#!/usr/bin/env bash
# Silently install the Rapsodo Golf Windows app into the prefix.
# Usage: 20-install-rapsodo.sh <RapsodoGolfSetup.zip | Rapsodo Golf-Windows-*-Setup.exe>
set -euo pipefail
. "$(dirname "$0")/env.sh"

src="${1:?pass the RapsodoGolfSetup.zip or the Setup .exe}"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

case "$src" in
  *.zip) unzip -q -o "$src" -d "$work"; exe="$(find "$work" -maxdepth 1 -name '*Setup.exe' | head -1)" ;;
  *.exe) exe="$src" ;;
  *) echo "unrecognized installer: $src" >&2; exit 1 ;;
esac
[ -f "$exe" ] || { echo "no Setup.exe found in $src" >&2; exit 1; }

echo "Installing $(basename "$exe")..."
WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all "$RGM_WINE_BIN/wine" "$exe" /S >/dev/null 2>&1
WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -w
[ -f "$RGM_APP_DIR/RapsodoGolf.exe" ] || { echo "install failed: $RGM_APP_DIR/RapsodoGolf.exe missing" >&2; exit 1; }
echo "Installed to $RGM_APP_DIR"
