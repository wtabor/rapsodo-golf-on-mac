#!/usr/bin/env bash
# One-shot setup. Usage: scripts/install.sh ~/Downloads/RapsodoGolfSetup.zip
set -euo pipefail
d="$(dirname "$0")"
[ -f "${1:-}" ] || { echo "Pass the Rapsodo installer, e.g. $0 ~/Downloads/RapsodoGolfSetup.zip" >&2; exit 1; }
"$d/00-prereqs.sh"
# A Homebrew installed just now isn't on this shell's PATH yet.
command -v brew >/dev/null || eval "$(/opt/homebrew/bin/brew shellenv)"
"$d/10-install-wine.sh"
"$d/20-install-rapsodo.sh" "$1"
"$d/30-build-libzmq.sh"
"$d/40-apply-patches.sh"
"$d/45-install-dxvk.sh"
"$d/50-make-launcher.sh"
"$d/build-tetherkit.sh"
echo
echo "Done. Optional, so play.sh never asks for a password:"
echo "  sudo \"$d/60-install-usb-daemon.sh\""
echo "To play: plug in the MLM2PRO (USB-C), power it on, then"
echo "  open \"/Applications/Rapsodo Golf (Mac Port).app\"   # runs play.sh in iTerm"
