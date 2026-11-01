# shellcheck shell=bash
# Tier 1: static checks. No Wine, no app, nothing installed is changed: the patchers
# run on copies in $WORK. Sourced by scripts/test.sh.

GAMES="$RGM_PREFIX/drive_c/ProgramData/Rapsodo/SuperApp/games"
# Where 47-install-mediamtx.sh puts MediaMTX (the app's userData folder).
MTX_EXE="$RGM_PREFIX/drive_c/users/$(id -un)/AppData/Roaming/super-app-clm/mediamtx/mediamtx.exe"
MINGW="x86_64-w64-mingw32-gcc"

t1_shellcheck() {
  if ! have shellcheck; then skip "shellcheck" "not installed: brew install shellcheck"; return; fi
  local log="$WORK/shellcheck.log" n
  n=$(cd "$RGM_REPO" && printf '%s\n' scripts/*.sh tests/*.sh | wc -l | tr -d ' ')
  if (cd "$RGM_REPO" && shellcheck -x -e SC1091 scripts/*.sh tests/*.sh) >"$log" 2>&1; then
    pass "shellcheck -x -e SC1091 scripts/*.sh tests/*.sh" "$n files"
  else
    fail "shellcheck -x -e SC1091 scripts/*.sh tests/*.sh" "$n files"
    show "$log"
  fi
}

# Byte-compile in memory (no __pycache__) with every Python a user may run: the one on
# PATH and macOS's /usr/bin/python3 (3.9 with the Command Line Tools), which is what
# python3 is in the iTerm window for users without Homebrew's Python.
t1_python() {
  local py ver log="$WORK/python.log" files=("$RGM_REPO"/scripts/*.py "$RGM_REPO"/tests/*.py) seen=""
  for py in "$(command -v python3)" /usr/bin/python3; do
    [ -x "$py" ] || continue
    # /usr/bin/python3 without the Command Line Tools opens an install dialog instead.
    [ "$py" != /usr/bin/python3 ] || xcode-select -p >/dev/null 2>&1 || continue
    ver="$("$py" -I -c 'import sys; print("%d.%d" % sys.version_info[:2])' 2>/dev/null)" || continue
    case " $seen " in *" $ver "*) continue ;; esac
    seen="$seen $ver"
    if "$py" -I -c '
import sys
for p in sys.argv[1:]:
    compile(open(p, "rb").read(), p, "exec")
' "${files[@]}" >"$log" 2>&1; then
      pass "Python syntax with $py ($ver)" "${#files[@]} files"
    else
      fail "Python syntax with $py ($ver)" "${#files[@]} files"
      show "$log"
    fi
  done
  [ -n "$seen" ] || fail "Python syntax" "no python3 found"
}

t1_node() {
  if ! have node; then skip "node --check (DevTools helpers)" "node not installed"; return; fi
  local f bad=0 log="$WORK/node.log" n=0
  : >"$log"
  for f in "$RGM_REPO"/scripts/debug/*.mjs "$RGM_REPO"/tests/app/*.mjs; do
    [ -f "$f" ] || continue
    n=$((n + 1))
    node --check "$f" >>"$log" 2>&1 || bad=1
  done
  if [ "$bad" = 0 ]; then pass "node --check (DevTools helpers)" "$n files"; else fail "node --check (DevTools helpers)"; show "$log"; fi
}

t1_patchers() {
  local log="$WORK/patchers.log" rc=0
  python3 -I "$TESTS/patchers.py" --scripts "$RGM_REPO/scripts" --work "$WORK/patchers" \
    --libs "$RGM_LIBS_DIR" --asar "$RGM_APP_DIR/resources/app.asar" --games "$GAMES" \
    --mediamtx "$MTX_EXE" --mingw "$(command -v "$MINGW" || true)" >"$log" 2>&1 || rc=$?
  relay <"$log"
  [ "$rc" = 0 ] || fail "patchers.py" "exited with status $rc"
  rm -rf "$WORK/patchers"
}

# update.sh ships every change to every user, so run it for real in a sandbox: a fake
# install, a fake "GitHub" (file:// URLs) and a stub install.sh in the new version.
t1_update() {
  local sb="$WORK/update" sha1 sha2 out rc
  sha1=$(printf 'a%.0s' {1..40})
  sha2=$(printf 'b%.0s' {1..40})
  mkdir -p "$sb/inst/scripts" "$sb/home" "$sb/new/rgm-$sha2/scripts" "$sb/srv"
  cp "$RGM_REPO/scripts/env.sh" "$RGM_REPO/scripts/update.sh" "$sb/inst/scripts/"
  echo "$sha1" >"$sb/inst/.rgm-version"
  echo 'RGM_GEO_ALT=1  # the user'"'"'s own settings' >"$sb/inst/scripts/env.local.sh"
  echo "old" >"$sb/inst/stale-file"
  # The new version: same env.sh/update.sh, a new file, and an install.sh stub.
  cp "$RGM_REPO/scripts/env.sh" "$RGM_REPO/scripts/update.sh" "$sb/new/rgm-$sha2/scripts/"
  printf '#!/bin/sh\nexit 0\n' >"$sb/new/rgm-$sha2/scripts/play.sh"
  # shellcheck disable=SC2016  # expanded by the stub, not here
  printf '#!/bin/sh\ntouch "$RGM_REPO/install-ran"\nexit "${STUB_INSTALL_RC:-0}"\n' >"$sb/new/rgm-$sha2/scripts/install.sh"
  echo "new" >"$sb/new/rgm-$sha2/new-file"
  chmod +x "$sb/new/rgm-$sha2/scripts/"*.sh
  (cd "$sb/new" && tar -czf "$sb/srv/good.tar.gz" "rgm-$sha2")
  head -c 200 "$sb/srv/good.tar.gz" >"$sb/srv/cut.tar.gz"
  printf '%s' "$sha2" >"$sb/srv/sha"
  printf '%s' "$sha1" >"$sb/srv/sha-same"

  # upd SHA_FILE TARBALL [VAR=value...]: run the sandboxed update.sh with a clean
  # environment (system PATH, so macOS's bash 3.2) and a 30 s timeout.
  upd() {
    local s=$1 tb=$2
    shift 2
    env -i HOME="$sb/home" PATH=/usr/bin:/bin:/usr/sbin:/sbin "$@" \
      RGM_UPDATE_SHA_URL="file://$sb/srv/$s" RGM_TARBALL_URL="file://$sb/srv/$tb" \
      perl -e 'alarm shift; exec @ARGV' 30 "$sb/inst/scripts/update.sh" >"$sb/out" 2>&1
  }
  local problems=""
  p() { problems="$problems; $*"; }

  upd sha-same good.tar.gz; rc=$?
  [ "$rc" = 0 ] && [ ! -s "$sb/out" ] || p "same version: expected silent exit 0 (got $rc)"
  upd missing good.tar.gz; rc=$?
  [ "$rc" = 0 ] && [ "$(cat "$sb/inst/.rgm-version")" = "$sha1" ] || p "offline: expected exit 0, no change (got $rc)"
  upd sha good.tar.gz RGM_AUTO_UPDATE=0; rc=$?
  [ "$rc" = 0 ] && [ ! -e "$sb/inst/new-file" ] || p "RGM_AUTO_UPDATE=0: expected no update"
  upd sha cut.tar.gz; rc=$?
  if ! { [ "$rc" = 0 ] && [ ! -e "$sb/inst/new-file" ] && [ "$(cat "$sb/inst/.rgm-version")" = "$sha1" ] &&
    grep -q "couldn't download" "$sb/out"; }; then
    p "cut-off download: expected exit 0 with a warning and nothing swapped in (got $rc)"
  fi
  upd sha good.tar.gz STUB_INSTALL_RC=1; rc=$?
  [ "$rc" = 3 ] && [ "$(cat "$sb/inst/.rgm-version")" = "$sha1" ] && [ -e "$sb/inst/install-ran" ] ||
    p "failing install.sh: expected exit 3 and the old version recorded (got $rc)"
  rm -f "$sb/inst/new-file" "$sb/inst/install-ran"
  upd sha good.tar.gz; rc=$?
  out="$(cat "$sb/out")"
  [ "$rc" = 3 ] || p "update: expected exit 3 (play.sh restarts on it), got $rc"
  [ "$(cat "$sb/inst/new-file" 2>/dev/null)" = new ] || p "update: new file not swapped in"
  [ -e "$sb/inst/install-ran" ] || p "update: install.sh not run"
  [ "$(cat "$sb/inst/.rgm-version")" = "$sha2" ] || p "update: new version not recorded"
  grep -q "the user's own settings" "$sb/inst/scripts/env.local.sh" || p "update: env.local.sh not kept"
  [ -e "$sb/inst/stale-file" ] || p "update: deleted a file (stale files must stay)"
  case "$out" in *"Updated to ${sha2:0:7}"*) ;; *) p "update: no 'Updated to' message" ;; esac
  mkdir "$sb/inst/.git"
  upd sha good.tar.gz; rc=$?
  [ "$rc" = 0 ] && [ ! -s "$sb/out" ] || p "git checkout: expected skip (exit 0), got $rc"
  if [ -z "$problems" ]; then
    pass "update.sh in a sandbox" "update, same version, offline, cut-off download, failed install, opt-out, git checkout"
  else
    fail "update.sh in a sandbox" "${problems#; }"
    show "$sb/out"
  fi
  # play.sh must keep restarting itself on exit 3 (installed copies run their own update.sh).
  # shellcheck disable=SC2016  # literal text of play.sh
  if grep -q '\[ "$rc" = 3 \] && RGM_UPDATED=1 exec "$d/play.sh"' "$RGM_REPO/scripts/play.sh"; then
    pass "play.sh restarts after an update (exit 3)"
  else
    fail "play.sh restarts after an update (exit 3)" "the update.sh exit-3 contract changed"
  fi
}

# Compile what install.sh / play.sh compile, with their flags, plus the tier 2 test
# programs. Outputs go to $WORK/bin for tier 2.
t1_compile() {
  local log="$WORK/compile.log"
  mkdir -p "$WORK/bin"
  if have clang; then
    if clang -O2 -Wall -o "$WORK/bin/launch" "$RGM_REPO/scripts/launcher.c" -DRGM_WINE="\"/nonexistent/wine\"" \
      -DRGM_PREFIX="\"/nonexistent/prefix\"" -DRGM_APP_DIR="\"/nonexistent/app\"" -DRGM_LOG="\"/dev/null\"" \
      -DRGM_APPNAME_DYLIB="\"/nonexistent/rgm-appname.dylib\"" >"$log" 2>&1; then
      pass "launcher.c compiles (50-make-launcher.sh flags)"
    else
      fail "launcher.c compiles (50-make-launcher.sh flags)"
      show "$log"
    fi
    if [ ! -f "$RGM_REPO/scripts/appname.c" ]; then
      :
    elif clang -O2 -Wall -arch x86_64 -arch arm64 -dynamiclib -framework CoreFoundation \
      -o "$WORK/bin/rgm-appname.dylib" "$RGM_REPO/scripts/appname.c" >"$log" 2>&1; then
      pass "appname.c compiles (50-make-launcher.sh flags)"
    else
      fail "appname.c compiles (50-make-launcher.sh flags)"
      show "$log"
    fi
  else
    skip "launcher.c and appname.c compile" "no clang (xcode-select --install)"
  fi
  if ! have "$MINGW"; then
    skip "Windows sources compile" "no $MINGW (brew install mingw-w64)"
    return
  fi
  if "$MINGW" -shared -O2 -s -o "$WORK/bin/GeolocationPlugin.dll" "$RGM_REPO/scripts/geolocation_stub.c" >"$log" 2>&1; then
    pass "geolocation_stub.c compiles (40-apply-patches.sh flags)"
  else
    fail "geolocation_stub.c compiles (40-apply-patches.sh flags)"
    show "$log"
  fi
  if "$MINGW" -municode -O2 -s -o "$WORK/bin/rgm-display-fix.exe" "$RGM_REPO/scripts/display_fix.c" \
    -luser32 -ladvapi32 -lntdll >"$log" 2>&1; then
    pass "display_fix.c compiles (48-build-display-fix.sh flags)"
  else
    fail "display_fix.c compiles (48-build-display-fix.sh flags)"
    show "$log"
  fi
  build_win_tests "$log"
}

# Repo hygiene: no Rapsodo binaries, installers, patched copies or videos; no personal
# data; scripts that are run directly stay executable.
t1_repo() {
  if ! git -C "$RGM_REPO" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    skip "repo hygiene" "not a git checkout"
    return
  fi
  local log="$WORK/repo.log"
  if (cd "$RGM_REPO" && git ls-files -z | python3 -I -c '
import sys
bad = []
for name in sys.stdin.buffer.read().split(b"\0"):
    if not name:
        continue
    n = name.decode("utf-8", "replace")
    low = n.lower()
    if low.endswith((".exe", ".dll", ".zip", ".7z", ".asar", ".mp4", ".mov", ".m4v", ".dxvk-cache", ".orig")) or ".tar." in low:
        bad.append(n + " (file type)")
        continue
    try:
        head = open(name, "rb").read(6)
    except OSError:
        continue
    if head[:2] == b"MZ" or head[:4] == b"PK\x03\x04" or head == b"7z\xbc\xaf\x27\x1c" or head[:2] == b"\x1f\x8b":
        bad.append(n + " (binary or archive)")
print("\n".join(bad))
sys.exit(1 if bad else 0)
') >"$log" 2>&1; then
    pass "no binaries, archives or videos tracked"
  else
    fail "no binaries, archives or videos tracked"
    show "$log"
  fi
  # Monitor serials (MLM2-<serial>), account ids from logs, home folders with a real name.
  # shellcheck disable=SC2016  # literal $USER placeholder
  if (cd "$RGM_REPO" && git grep -n -I -E 'M2P[0-9]{5,}|"user_id": ?"[0-9]+"|/Users/[A-Za-z0-9_.-]+/' -- . |
    grep -v -E '/Users/(<you>|you|USER|\$USER|\.\.\.)/') >"$log" 2>&1; then
    fail "no personal data (serials, account ids, home folders)"
    show "$log"
  else
    pass "no personal data (serials, account ids, home folders)"
  fi
  local mode f bad=""
  while read -r mode _ _ f; do
    [ "$f" = scripts/env.sh ] || [ "$mode" = 100755 ] || bad="$bad $f"
  done < <(cd "$RGM_REPO" && git ls-files -s -- 'scripts/*.sh' 'bootstrap.sh')
  if [ -z "$bad" ]; then pass "scripts are executable"; else fail "scripts are executable" "not executable:$bad"; fi
}

tier1() {
  t1_shellcheck
  t1_python
  t1_node
  t1_patchers
  t1_update
  t1_compile
  t1_repo
}
