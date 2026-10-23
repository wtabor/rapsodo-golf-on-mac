#!/usr/bin/env bash
# Set up or update everything. Usage: scripts/install.sh [RapsodoGolfSetup.zip]
# The installer is only needed the first time: once Rapsodo's app is installed it
# updates itself, so it isn't reinstalled (an older zip would downgrade it).
# RGM_REINSTALL=1 reinstalls it from the given installer anyway.
set -euo pipefail
d="$(dirname "$0")"
. "$d/env.sh"
rapsodo_page="https://rapsodo.com/pages/rapsodo-studios-for-pc"

installer="${1:-}"
if [ -f "$RGM_APP_DIR/RapsodoGolf.exe" ] && [ -z "${RGM_REINSTALL:-}" ]; then
  installer=""
elif [ ! -f "$installer" ]; then
  echo "Rapsodo's installer wasn't found. On $rapsodo_page click" >&2
  echo "Download PC App, then run this again (it looks in ~/Downloads)." >&2
  open "$rapsodo_page" 2>/dev/null || true
  exit 1
fi

"$d/00-prereqs.sh"
# A Homebrew installed just now isn't on this shell's PATH yet.
command -v brew >/dev/null || eval "$(/opt/homebrew/bin/brew shellenv)"
"$d/10-install-wine.sh"
if [ -n "$installer" ]; then
  "$d/20-install-rapsodo.sh" "$installer"
else
  echo "Rapsodo Golf is already installed (it updates itself); not reinstalling."
fi
"$d/30-build-libzmq.sh"
"$d/40-apply-patches.sh"
"$d/45-install-dxvk.sh"
"$d/50-make-launcher.sh"
"$d/build-tetherkit.sh"
echo
echo "Done. Optional, so play.sh never asks for a password:"
echo "  sudo \"$d/60-install-usb-daemon.sh\""
echo "To play: plug in the MLM2PRO (USB-C), power it on, then"
echo "  open \"$RGM_APP_BUNDLE\"   # runs play.sh in iTerm"
