#!/usr/bin/env bash
# Auto-update: play.sh runs this at each launch. Asks GitHub for the newest commit
# on main, or on the branch/tag bootstrap.sh installed from (.rgm-ref), in one
# small request with a 5 s timeout. If it isn't the installed one
# (.rgm-version), downloads that commit, swaps the project files in and re-runs
# install.sh, just like running the install command again.
#
# Exit status: 3 = updated (play.sh then restarts itself), 0 = nothing to do.
# Never fails the launch: offline, GitHub down or any error just keeps the
# installed version, and the next launch tries again.
#
# Skipped for git checkouts (update those with git) and when RGM_AUTO_UPDATE=0
# (e.g. in scripts/env.local.sh). Overrides: RGM_GITHUB_REPO, RGM_REF (branch or
# tag), RGM_UPDATE_SHA_URL, RGM_TARBALL_URL.
set -uo pipefail
. "$(dirname "$0")/env.sh"

repo="${RGM_GITHUB_REPO:-wtabor/rapsodo-golf-on-mac}"
ref="${RGM_REF:-$(cat "$RGM_REPO/.rgm-ref" 2>/dev/null)}"
ref="${ref:-main}"
version_file="$RGM_REPO/.rgm-version"
log="$RGM_USER_HOME/Library/Logs/RapsodoGolf-update.log"

[ "${RGM_AUTO_UPDATE:-1}" = 0 ] && exit 0
[ -e "$RGM_REPO/.git" ] && exit 0

# -L: GitHub answers a renamed or moved repo with a redirect.
sha="$(curl -fsSL --max-time 5 -H 'Accept: application/vnd.github.sha' \
  "${RGM_UPDATE_SHA_URL:-https://api.github.com/repos/$repo/commits/$ref}" 2>/dev/null)" || exit 0
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || exit 0
[ "$sha" = "$(cat "$version_file" 2>/dev/null)" ] && exit 0

echo "Updating rapsodo-golf-on-mac to ${sha:0:7} (log: ~/Library/Logs/RapsodoGolf-update.log)..."
mkdir -p "$(dirname "$log")"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# A download cut off partway can still extract play.sh and install.sh, with
# NUL-padded or missing files after them: require curl and tar to both succeed.
if ! {
  echo "$(date '+%m/%d/%Y %T') updating $(cat "$version_file" 2>/dev/null || echo unknown) -> $sha"
  curl -fsSL --max-time 300 "${RGM_TARBALL_URL:-https://github.com/$repo/archive/$sha.tar.gz}" |
    tar -xz --strip-components 1 -C "$tmp"
} >"$log" 2>&1 || [ ! -f "$tmp/scripts/play.sh" ] || [ ! -f "$tmp/scripts/install.sh" ]; then
  echo "warning: couldn't download the update; starting the installed version." >&2
  exit 0
fi

# Swap each file in by rename, never by rewriting it: bash reads a running script
# (this one, play.sh, usb-link.sh) from the open file as it goes. Your
# scripts/env.local.sh isn't in the download, so it's kept.
if ! (cd "$tmp" && find . -type f) | while IFS= read -r f; do
  mkdir -p "$RGM_REPO/$(dirname "$f")" &&
    cp -p "$tmp/$f" "$RGM_REPO/$f.rgm-new" &&
    mv -f "$RGM_REPO/$f.rgm-new" "$RGM_REPO/$f" || exit 1
done; then
  echo "warning: couldn't write the update into $RGM_REPO; it will retry next launch." >&2
  exit 0
fi

# Re-apply everything with the new scripts. Rapsodo's app isn't reinstalled.
# Record the version only on success, so a failed install is retried next launch.
if "$RGM_REPO/scripts/install.sh" >>"$log" 2>&1; then
  echo "$sha" >"$version_file"
  echo "Updated to ${sha:0:7}."
else
  echo "warning: the update's install step failed; it will retry next launch. See $log" >&2
fi
exit 3
