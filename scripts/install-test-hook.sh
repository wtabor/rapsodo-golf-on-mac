#!/usr/bin/env bash
# Opt-in git pre-push hook: before anything is pushed to main, run scripts/test.sh
# (tiers 1 and 2) on the exact commit being pushed, in a temporary checkout, and block
# the push if a check fails. Every push to main reaches every user at their next
# launch (update.sh), so main should only get tested changes. Pushes to other
# branches aren't tested.
#
# Usage: scripts/install-test-hook.sh [--uninstall]
# Skip the tests once:  RGM_SKIP_TESTS=1 git push   (git push --no-verify also works)
# Other tiers:          RGM_PUSH_TEST_TIERS="1 2 3" git push
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"
hooks="$(cd "$repo" && git rev-parse --git-path hooks)"
case "$hooks" in /*) ;; *) hooks="$repo/$hooks" ;; esac
hook="$hooks/pre-push"
marker="# rapsodo-golf-on-mac test hook"

if [ "${1:-}" = --uninstall ]; then
  if [ -f "$hook" ] && grep -qF "$marker" "$hook"; then
    rm -f "$hook"
    echo "removed $hook"
  else
    echo "no rapsodo-golf-on-mac pre-push hook installed"
  fi
  exit 0
fi
if [ -e "$hook" ] && ! grep -qF "$marker" "$hook"; then
  echo "error: $hook already exists and isn't this project's; not replacing it." >&2
  echo "Add this line to it instead:  \"$repo/scripts/test.sh\" </dev/null || exit 1" >&2
  exit 1
fi
mkdir -p "$hooks"
cat >"$hook.tmp" <<'EOF'
#!/usr/bin/env bash
# rapsodo-golf-on-mac test hook (installed by scripts/install-test-hook.sh; remove with
# scripts/install-test-hook.sh --uninstall). Runs scripts/test.sh on each commit pushed
# to main, in a temporary checkout of that commit, and blocks the push on a failure.
# Skip once: RGM_SKIP_TESTS=1 git push. Tiers: RGM_PUSH_TEST_TIERS (default "1 2").
z=0000000000000000000000000000000000000000
shas=""
while read -r _ lsha rref _; do
  [ "$rref" = refs/heads/main ] && [ "$lsha" != "$z" ] && shas="$shas $lsha"
done
[ -n "$shas" ] || exit 0
if [ "${RGM_SKIP_TESTS:-0}" = 1 ]; then
  echo "pre-push: RGM_SKIP_TESTS=1, pushing to main without running the tests" >&2
  exit 0
fi
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
top="$(git rev-parse --show-toplevel)" || exit 1
for sha in $shas; do
  tmp="$(mktemp -d "${TMPDIR:-/tmp}/rgm-push-test.XXXXXX")"
  if ! git worktree add --detach --quiet "$tmp/tree" "$sha"; then
    rm -rf "$tmp"
    echo "pre-push: couldn't check out $sha to test it; push blocked" >&2
    exit 1
  fi
  # Personal settings (RGM_HOME etc.) aren't in git; the tests need the same paths.
  [ ! -f "$top/scripts/env.local.sh" ] || cp "$top/scripts/env.local.sh" "$tmp/tree/scripts/"
  rc=0
  if [ -x "$tmp/tree/scripts/test.sh" ]; then
    echo "pre-push: testing ${sha:0:7}, which main is about to get (scripts/test.sh ${RGM_PUSH_TEST_TIERS:-1 2})" >&2
    # shellcheck disable=SC2086  # one tier per word
    "$tmp/tree/scripts/test.sh" ${RGM_PUSH_TEST_TIERS:-1 2} </dev/null >&2 || rc=$?
  else
    echo "pre-push: ${sha:0:7} has no scripts/test.sh; not tested" >&2
  fi
  git worktree remove --force "$tmp/tree" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  if [ "$rc" != 0 ]; then
    echo "pre-push: tests failed; push to main blocked. Fix them, or push anyway once with:" >&2
    echo "  RGM_SKIP_TESTS=1 git push" >&2
    exit 1
  fi
done
exit 0
EOF
chmod +x "$hook.tmp"
mv -f "$hook.tmp" "$hook"
echo "installed $hook: pushes to main now run scripts/test.sh first (skip once: RGM_SKIP_TESTS=1 git push)"
