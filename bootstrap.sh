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
[ "$(uname -m)" = arm64 ] || { echo "This needs a Mac with Apple Silicon (M1 or later)." >&2; exit 1; }

# Rapsodo's installer: newest RapsodoGolfSetup*.zip (browsers add " (1)" to
# repeat downloads) or "Rapsodo Golf-Windows-*-Setup.exe". Only the first install
# needs it; install.sh says what to do if it's missing.
installer="${RGM_INSTALLER:-}"
if [ -z "$installer" ]; then
  # shellcheck disable=SC2012  # ls -t for newest-first; these names have no newlines
  installer="$(ls -t "$downloads"/RapsodoGolfSetup*.zip "$downloads"/Rapsodo\ Golf-Windows-*-Setup.exe 2>/dev/null | head -1 || true)"
fi

if [ -d "$dir/.git" ]; then
  echo "Updating $dir (git)..."
  git -C "$dir" pull --ff-only
else
  echo "Downloading rapsodo-golf-on-mac to $dir..."
  mkdir -p "$dir"
  # Pin the exact commit, so the app's auto-update (scripts/update.sh) knows what
  # is installed. If GitHub's API doesn't answer, install the branch instead; the
  # first launch then updates once.
  sha="$(curl -fsS --max-time 10 -H 'Accept: application/vnd.github.sha' \
    "https://api.github.com/repos/wtabor/rapsodo-golf-on-mac/commits/$ref" 2>/dev/null)" || sha=""
  [[ "$sha" =~ ^[0-9a-f]{40}$ ]] || sha=""
  # Overwrites the project's own files only; scripts/env.local.sh is kept.
  curl -fsSL "${RGM_TARBALL_URL:-https://github.com/wtabor/rapsodo-golf-on-mac/archive/${sha:-$ref}.tar.gz}" |
    tar -xz --strip-components 1 -C "$dir"
  # Auto-update follows the same branch or tag (RGM_REF), not always main.
  echo "$ref" >"$dir/.rgm-ref"
fi

"$dir/scripts/install.sh" ${installer:+"$installer"}
if [ -n "${sha:-}" ]; then echo "$sha" >"$dir/.rgm-version"; fi
