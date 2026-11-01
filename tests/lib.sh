# shellcheck shell=bash
# Shared helpers for scripts/test.sh and the tier files in tests/. Sourced, not run.
# Bash 3.2 compatible (macOS /bin/bash): no associative arrays, no mapfile.

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_PASS=$'\033[32m' C_FAIL=$'\033[31m' C_SKIP=$'\033[33m' C_DIM=$'\033[2m' C_OFF=$'\033[0m'
else
  C_PASS="" C_FAIL="" C_SKIP="" C_DIM="" C_OFF=""
fi

# report STATUS NAME [DETAIL...]: one result line, also appended to $RESULTS.
report() {
  local status=$1 name=$2 color
  shift 2
  case "$status" in PASS) color=$C_PASS ;; FAIL) color=$C_FAIL ;; *) color=$C_SKIP ;; esac
  printf '%s\t%s\t%s\n' "$status" "$TIER" "$name" >>"$RESULTS"
  printf '%s%-4s%s  %s%s\n' "$color" "$status" "$C_OFF" "$name" "${1:+  ${C_DIM}($*)${C_OFF}}"
}
pass() { report PASS "$@"; }
fail() { report FAIL "$@"; }
skip() { report SKIP "$@"; }

# Indent command output under a result line. With -v (RGM_TEST_VERBOSE=1) or on
# failure the caller prints it; otherwise it stays in $WORK for a look afterwards.
indent() { sed 's/^/        /'; }
show() { indent <"$1"; }

# Read results that a helper (tests/patchers.py) printed as "STATUS<TAB>name<TAB>detail"
# lines; other lines are detail and are indented (shown only for failures and -v).
relay() {
  local line status name detail buf=""
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      PASS$'\t'* | FAIL$'\t'* | SKIP$'\t'*)
        status=${line%%$'\t'*}
        name=${line#*$'\t'}
        detail=""
        case "$name" in *$'\t'*) detail=${name#*$'\t'} name=${name%%$'\t'*} ;; esac
        report "$status" "$name" "$detail"
        if [ -n "$buf" ] && { [ "$status" = FAIL ] || [ -n "${RGM_TEST_VERBOSE:-}" ]; }; then
          printf '%s' "$buf" | indent
        fi
        buf=""
        ;;
      *) buf="$buf$line"$'\n' ;;
    esac
  done
  [ -z "$buf" ] || printf '%s' "$buf" | indent
}

# have CMD: is it on PATH?
have() { command -v "$1" >/dev/null 2>&1; }

# Run a command with a timeout in seconds (macOS has no `timeout`). Exit status
# 142 means it was killed by the alarm.
with_timeout() {
  local t=$1
  shift
  perl -e 'alarm shift; exec @ARGV or exit 127' "$t" "$@"
}

# Every process of this Wine install maps its locale.nls (as in play.sh).
wine_pids() { lsof -t "$RGM_WINE_BIN/../share/wine/nls/locale.nls" 2>/dev/null || true; }

# Unix path -> Windows path for Wine: C:\ inside the prefix, Z:\ elsewhere.
winpath() {
  local p=$1
  case "$p" in
    "$RGM_PREFIX/drive_c/"*) p="C:/${p#"$RGM_PREFIX/drive_c/"}" ;;
    /*) p="Z:$p" ;;
  esac
  printf '%s' "${p//\//\\}"
}

# wine_run SECONDS EXE [ARGS...]: run a Windows program under the installed Wine the
# way the app's games run (launcher.c environment), with DXVK forced on for it.
wine_run() {
  local t=$1
  shift
  WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all WINEDLLOVERRIDES="d3d11,d3d10core=n,b" \
    MVK_CONFIG_LOG_LEVEL=1 DXVK_LOG_LEVEL=none DXVK_STATE_CACHE=0 \
    GST_PLUGIN_FEATURE_RANK="vtdec:NONE,vtdec_hw:NONE,avfassetsrc:NONE" \
    with_timeout "$t" "$RGM_WINE_BIN/wine" "$@"
}

# Value after key K in the "summary: k v k v ..." line of a test program's output
# (Windows programs end lines with CRLF).
summary_field() {
  awk -v k="$2" '{ sub(/\r$/, "") } /^summary:/ { for (i = 2; i < NF; i++) if ($i == k) v = $(i + 1) } END { print v }' "$1"
}
