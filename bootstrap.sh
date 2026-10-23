#!/usr/bin/env bash
# One-line install (or update):
#   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/wtabor/rapsodo-golf-on-mac/main/bootstrap.sh)"
# Downloads this project to ~/rapsodo-golf-on-mac, finds Rapsodo's installer in
# ~/Downloads, and runs scripts/install.sh. Safe to run again: it updates the
# project and re-applies everything.
#
# Overrides: RGM_DIR (project folder), RGM_INSTALLER (path to the Rapsodo
# .zip or Setup .exe), RGM_DOWNLOADS (where to look for it), RGM_REF (branch or tag).
set -euo pipefail

dir="${RGM_DIR:-$HOME/rapsodo-golf-on-mac}"
downloads="${RGM_DOWNLOADS:-$HOME/Downloads}"
ref="${RGM_REF:-main}"
url="${RGM_TARBALL_URL:-https://github.com/wtabor/rapsodo-golf-on-mac/archive/$ref.tar.gz}"
rapsodo_page="https://rapsodo.com/pages/rapsodo-studios-for-pc"

[ "$(uname -m)" = arm64 ] || { echo "This needs a Mac with Apple Silicon (M1 or later)." >&2; exit 1; }

# Rapsodo's installer: newest RapsodoGolfSetup*.zip (browsers add " (1)" to
# repeat downloads) or "Rapsodo Golf-Windows-*-Setup.exe".
installer="${RGM_INSTALLER:-}"
if [ -z "$installer" ]; then
  # shellcheck disable=SC2012  # ls -t for newest-first; these names have no newlines
  installer="$(ls -t "$downloads"/RapsodoGolfSetup*.zip "$downloads"/Rapsodo\ Golf-Windows-*-Setup.exe 2>/dev/null | head -1 || true)"
fi
if [ ! -f "$installer" ]; then
  echo "Rapsodo's installer isn't in $downloads yet." >&2
  echo "Opening $rapsodo_page: click Download PC App, then run this command again." >&2
  open "$rapsodo_page" 2>/dev/null || true
  exit 1
fi
echo "Rapsodo installer: $installer"

if [ -d "$dir/.git" ]; then
  echo "Updating $dir (git)..."
  git -C "$dir" pull --ff-only
else
  echo "Downloading rapsodo-golf-on-mac to $dir..."
  mkdir -p "$dir"
  # Overwrites the project's own files only; scripts/env.local.sh is kept.
  curl -fsSL "$url" | tar -xz --strip-components 1 -C "$dir"
fi

exec "$dir/scripts/install.sh" "$installer"
