#!/usr/bin/env bash
# Regression tests. Every push to main reaches every user at their next launch
# (update.sh), so run this before pushing; scripts/install-test-hook.sh makes
# `git push` to main run it for you.
#
# Usage: scripts/test.sh [-v] [TIER...]   TIER: 1 2 3 4, or all (default: 1 2)
#   1  static: shellcheck, Python syntax, the binary patchers on copies of your
#      installed files, update.sh in a sandbox, C sources compile, repo hygiene
#   2  Wine, no monitor: small Windows test programs under the installed Wine
#      (D3D11 through DXVK, Media Foundation video reads, libzmq, MediaMTX, ...)
#   3  app, no monitor: starts Rapsodo's app with a DevTools port, checks the page,
#      starts and closes each installed game, quits the app. Needs the app (and every
#      Wine program of this install) closed first; puts game windows on screen.
#   4  monitor: only when 192.168.36.1 answers. With tier 3: connection, sign-in to
#      the monitor and the alignment camera streams. Without: reads the log of the
#      app you started yourself. Prints a checklist for what only a person can check.
# Each check prints PASS, FAIL or SKIP (a missing prerequisite is a SKIP, not a
# FAIL). Exit status: 0 no failures, 1 failures, 2 usage error.
#
# Environment: RGM_TEST_VERBOSE=1 (same as -v: show output of passing checks too),
# RGM_TEST_KEEP=1 (keep the work folder), RGM_TEST_GAMES="driving-range studios"
# (tier 3: only these game ids), RGM_TEST_PORT (tier 3 DevTools port, default 9222).
set -uo pipefail
d="$(cd "$(dirname "$0")" && pwd)"
. "$d/env.sh"
TESTS="$RGM_REPO/tests"
. "$TESTS/lib.sh"

tiers=""
for a in "$@"; do
  case "$a" in
    -v | --verbose) RGM_TEST_VERBOSE=1 ;;
    -h | --help) sed -n '2,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
    all) tiers="1 2 3 4" ;;
    1 | 2 | 3 | 4) tiers="$tiers $a" ;;
    *) echo "usage: scripts/test.sh [-v] [1|2|3|4|all]..." >&2; exit 2 ;;
  esac
done
# shellcheck disable=SC2086  # one tier per word
tiers="$(printf '%s\n' ${tiers:-1 2} | sort -u | tr '\n' ' ')"
export RGM_TEST_VERBOSE="${RGM_TEST_VERBOSE:-}"
# Tier 3 runs tier 4's live checks while its app is up. TIER labels each result.
# shellcheck disable=SC2034  # both read in tests/
case " $tiers " in *" 4 "*) T4_WANTED=1 ;; *) T4_WANTED=0 ;; esac

WORK="$(mktemp -d "${TMPDIR:-/tmp}/rgm-test.XXXXXX")"
RESULTS="$WORK/results.tsv"
: >"$RESULTS"
cleanup() {
  # Tier 3 registers its own cleanup (closing the app it started) first.
  [ -z "${TIER3_CLEANUP:-}" ] || "$TIER3_CLEANUP"
  if [ -n "${RGM_TEST_KEEP:-}" ]; then echo "work folder kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT
trap 'exit 130' INT TERM

. "$TESTS/tier1.sh"
. "$TESTS/tier2.sh"
. "$TESTS/tier3.sh"
. "$TESTS/tier4.sh"

start_all=$SECONDS
durations=""
for t in $tiers; do
  # shellcheck disable=SC2034  # read by report() in tests/lib.sh
  TIER=$t
  case $t in
    1) title="static" ;; 2) title="Wine, no monitor" ;; 3) title="app, no monitor" ;; 4) title="monitor" ;;
  esac
  echo
  echo "== Tier $t: $title"
  s=$SECONDS
  "tier$t"
  durations="$durations$t:$((SECONDS - s)) "
done

echo
echo "== Summary"
fails=0
for t in $tiers; do
  p=$(awk -F'\t' -v t="$t" '$2 == t && $1 == "PASS"' "$RESULTS" | wc -l | tr -d ' ')
  f=$(awk -F'\t' -v t="$t" '$2 == t && $1 == "FAIL"' "$RESULTS" | wc -l | tr -d ' ')
  k=$(awk -F'\t' -v t="$t" '$2 == t && $1 == "SKIP"' "$RESULTS" | wc -l | tr -d ' ')
  # shellcheck disable=SC2086  # one tier:seconds per word
  secs=$(printf '%s\n' $durations | awk -F: -v t="$t" '$1 == t { print $2 }')
  printf 'Tier %s: %s passed, %s failed, %s skipped (%ss)\n' "$t" "$p" "$f" "$k" "$secs"
  fails=$((fails + f))
done
awk -F'\t' '$1 == "FAIL" { print "  FAIL (tier " $2 "): " $3 }' "$RESULTS"
printf 'Total time: %ss\n' "$((SECONDS - start_all))"
[ "$fails" = 0 ]
