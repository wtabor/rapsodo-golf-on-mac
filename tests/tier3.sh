# shellcheck shell=bash
# $1/$2 in sh -c snippets and the JavaScript are meant for sh and the page, not here:
# shellcheck disable=SC2016
# TIER, T4_DONE and TIER3_CLEANUP are read by scripts/test.sh and tests/tier4.sh:
# shellcheck disable=SC2034
# Tier 3: Rapsodo's app under Wine, no monitor needed. Builds scripts/launcher.c with
# its log in $WORK (your ~/Library/Logs/RapsodoGolf-Wine.log is left alone), starts the
# app with a DevTools port (RGM_REMOTE_DEBUGGING_PORT), checks the page, starts and
# closes each installed game, then quits the app. It shares your Wine prefix, so it
# only runs when nothing of this Wine install is running. With tier 4 requested and the
# monitor reachable, tier 4's live checks run here too, while the app is up.
# Sourced by scripts/test.sh.

T3_PORT="${RGM_TEST_PORT:-9222}"
T3_DIR="$WORK/t3"
T3_LOG="$T3_DIR/app.log"
T3_PID=""
# Out of the way by default: windows of the test copy of the app and of its games are
# minimized (inside Wine) and hidden (macOS) as they appear, and games start in a
# 640x360 window. Each game's saved settings (its HKCU\Software\<company>\<product> key,
# where Unity keeps the window size) are put back afterwards. RGM_TEST_SHOW=1 shows
# everything as a user would see it.
T3_SHOW="${RGM_TEST_SHOW:-0}"
T3_GAME_WINDOW="-screen-fullscreen 0 -screen-width 640 -screen-height 360"
T3_GUARD_PIDS=""
# Unity crash / startup failure markers in Player.log.
T3_CRASH='Crash!!!|Failed to initialize player|Fatal error|Failed to create D3D11|Unity Player has crashed|DirectX 11 not supported'

cdp() { with_timeout "${CDP_TIMEOUT:-40}" node "$TESTS/app/cdp.mjs" --port "$T3_PORT" --timeout "${CDP_TIMEOUT:-30}" "$@"; }

# wait_for SECONDS COMMAND...: poll once a second until COMMAND succeeds.
wait_for() {
  local end=$((SECONDS + $1))
  shift
  while [ "$SECONDS" -lt "$end" ]; do
    "$@" && return 0
    sleep 1
  done
  "$@"
}
app_alive() { [ -n "$T3_PID" ] && kill -0 "$T3_PID" 2>/dev/null; }
# log_after LINE REGEX: REGEX appears in the app log after line LINE.
# Not `grep -q`: it stops at the first match, tail dies of SIGPIPE, and pipefail (set by
# scripts/test.sh) then reports the match as a failure.
log_after() { tail -n +"$(($1 + 1))" "$T3_LOG" 2>/dev/null | grep -E "$2" >/dev/null; }
log_lines() { if [ -f "$T3_LOG" ]; then wc -l <"$T3_LOG" | tr -d ' '; else echo 0; fi; }
nothing_running() { [ -z "$(wine_pids)" ]; }

# Start/stop the two watchers that keep the test's windows out of sight.
t3_guard_start() {
  [ "$T3_SHOW" != 1 ] || return 0
  local exes="RapsodoGolf.exe" exe
  for exe in "$GAMES"/*/*/*.exe; do
    [ -d "${exe%.exe}_Data" ] && exes="$exes $(basename "$exe")"
  done
  if "$MINGW" -O2 -Wall -municode -o "$T3_DIR/winctl.exe" "$TESTS/wine/winctl.c" >>"$T3_DIR/build.log" 2>&1; then
    # shellcheck disable=SC2086  # one argument per program
    (cd "$T3_DIR" && exec env WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all "$RGM_WINE_BIN/wine" winctl.exe $exes) \
      >"$T3_DIR/winctl.log" 2>&1 &
    T3_GUARD_PIDS="$!"
  fi
  if swiftc -O -o "$T3_DIR/focusguard" "$TESTS/app/focusguard.swift" >>"$T3_DIR/build.log" 2>&1; then
    "$T3_DIR/focusguard" "$(cd "$RGM_WINE_BIN/.." && pwd -P)" >"$T3_DIR/focusguard.log" 2>&1 &
    T3_GUARD_PIDS="$T3_GUARD_PIDS $!"
  fi
}
t3_guard_stop() {
  local pid
  for pid in $T3_GUARD_PIDS; do kill "$pid" 2>/dev/null || true; done
  for pid in $T3_GUARD_PIDS; do wait "$pid" 2>/dev/null || true; done
  T3_GUARD_PIDS=""
}

# Close the app this tier started, however the run ends (Ctrl-C included). Only Wine
# processes of this install can be running then (checked before starting).
t3_cleanup() {
  t3_guard_stop
  if [ -n "$T3_SAVED_KEY" ]; then
    echo "putting back the saved settings of $T3_SAVED_KEY..." >&2
    WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -k 2>/dev/null || true
    t3_restore_settings || echo "couldn't: they're in $T3_SAVED_FILE (wine reg import)" >&2
  fi
  app_alive || return 0
  echo "closing the test copy of the app..." >&2
  WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -k 2>/dev/null || true
  wait "$T3_PID" 2>/dev/null || true
  T3_PID=""
}

# Windows path (C:\...) -> path on the Mac.
unixpath() {
  local p=${1//\\//}
  case "$p" in [Cc]:/*) p="$RGM_PREFIX/drive_c/${p#??/}" ;; esac
  printf '%s' "$p"
}

t3_start() {
  mkdir -p "$T3_DIR"
  # Built like 50-make-launcher.sh does, from this checkout: the naming library
  # (appname.c, if present) and the launcher, with the log in $WORK.
  local names="$T3_DIR/rgm-appname.dylib"
  if [ -f "$RGM_REPO/scripts/appname.c" ] && ! { clang -O2 -Wall -arch x86_64 -arch arm64 -dynamiclib \
    -framework CoreFoundation -o "$names" "$RGM_REPO/scripts/appname.c" >"$T3_DIR/build.log" 2>&1 &&
    codesign --force --sign - "$names" >/dev/null 2>&1; }; then
    rm -f "$names" # the launcher only loads it if it's there
  fi
  if ! clang -O2 -Wall -o "$T3_DIR/launch" "$RGM_REPO/scripts/launcher.c" -DRGM_WINE="\"$RGM_WINE_BIN/wine\"" \
    -DRGM_PREFIX="\"$RGM_PREFIX\"" -DRGM_APP_DIR="\"$RGM_APP_DIR\"" -DRGM_LOG="\"$T3_LOG\"" \
    -DRGM_APPNAME_DYLIB="\"$names\"" >>"$T3_DIR/build.log" 2>&1; then
    fail "build launcher.c for the test"
    show "$T3_DIR/build.log"
    return 1
  fi
  TIER3_CLEANUP=t3_cleanup
  t3_guard_start
  RGM_REMOTE_DEBUGGING_PORT="$T3_PORT" "$T3_DIR/launch" &
  T3_PID=$!
  local s=$SECONDS
  # Like play.sh: the device manager's start line, or its failure.
  wait_for 150 sh -c 'grep -q -E "DEBUG: start device manager|device manager server start failed" "$1" || ! kill -0 "$2" 2>/dev/null' _ "$T3_LOG" "$T3_PID"
  if grep -q "DEBUG: start device manager" "$T3_LOG" 2>/dev/null; then
    pass "app starts, device manager up" "$((SECONDS - s))s"
  else
    fail "app starts, device manager up" "$(grep -q 'start failed' "$T3_LOG" 2>/dev/null && echo 'device manager server start failed' || echo "no start line after $((SECONDS - s))s")"
    tail -n 30 "$T3_LOG" 2>/dev/null | indent
    return 1
  fi
}

t3_page() {
  local out
  if ! out="$(CDP_TIMEOUT=90 cdp wait 2>&1)"; then
    fail "renderer page loads (DevTools port $T3_PORT)" "$out"
    return 1
  fi
  # Loaded, the app's preload bridge is there, Vue mounted something, the device
  # manager client has its services.
  local expr='(async () => {
    for (let i = 0; i < 60 && document.readyState !== "complete"; i++) await new Promise(r => setTimeout(r, 500));
    const app = document.querySelector("#app");
    return {
      ready: document.readyState,
      electronAPI: typeof window.electronAPI?.runGame === "function",
      mounted: !!(app && app.children.length),
      services: Object.keys(window.deviceManager?.client?.rdc ?? {}).sort(),
      text: (document.body?.innerText ?? "").trim().length,
    };
  })()'
  out="$(cdp eval "$expr" 2>&1)" || true
  if printf '%s' "$out" | grep -q '"ready":"complete","electronAPI":true,"mounted":true' &&
    printf '%s' "$out" | grep -q 'DiscoveryAndConnectionService' && printf '%s' "$out" | grep -q 'CommandService'; then
    pass "renderer page loads (DevTools port $T3_PORT)" "Vue app mounted, electronAPI and deviceManager.client.rdc present"
  else
    fail "renderer page loads (DevTools port $T3_PORT)" "$out"
    return 1
  fi
  # The renderer talks to deviceManagerServer.exe: list the downloaded games through it.
  if out="$(cdp eval 'window.deviceManager.client.game.findAllGames().then(r => (r.gamesList || []).length)' 2>&1)"; then
    pass "renderer -> device manager call (game.findAllGames)" "$out game(s)"
  elif printf '%s' "$out" | grep -q UNAUTHENTICATED; then
    skip "renderer -> device manager call (game.findAllGames)" "not signed in to the app"
  else
    fail "renderer -> device manager call (game.findAllGames)" "$out"
  fi
}

# Games the app knows (device manager), else the folders on disk. One line per game:
# slug<TAB>version<TAB>Windows directory<TAB>exe<TAB>arguments
t3_games() {
  local js='(async () => {
    const games = (await window.deviceManager.client.game.findAllGames()).gamesList || [];
    let apps = [];
    try { apps = (await window.deviceManager.client.strapi.strapiMiniAppService.findMiniApps()).dataList || []; } catch {}
    apps.sort((a, b) => (a.order ?? 0) - (b.order ?? 0));
    return games.map(g => {
      const app = apps.find(a => a.slug === g.slug);
      const args = [...(app?.programargumentsList ?? []), "-language=en"].join(" ");
      return [g.slug, g.version, g.directory, g.runnerfilename, args].join("\t");
    }).join("\n");
  })()'
  local out
  if out="$(cdp eval "$js" 2>/dev/null)" && [ "$out" != '""' ]; then
    printf '%s' "$out" | python3 -I -c 'import json, sys; print(json.load(sys.stdin))'
    return
  fi
  local exe dir
  for exe in "$GAMES"/*/*/*.exe; do
    dir="$(dirname "$exe")"
    [ -d "${exe%.exe}_Data" ] || continue
    printf '%s\t%s\t%s\t%s\t%s\n' "$(basename "$(dirname "$dir")")" "$(basename "$dir")" "$(winpath "$dir")" \
      "$(basename "$exe")" "-language=en"
  done
}

game_pid() { pgrep -f "SuperApp.games.*$1" | head -1; }

# Put back a game's saved settings (its HKCU\Software\<company>\<product> key) as they
# were before the test: Unity saves the window size there when it quits, and the test's
# 640x360 window must not become the next real game's. Called after the game is closed,
# and from t3_cleanup if the run is cut short.
T3_SAVED_KEY="" T3_SAVED_FILE="" T3_SAVED_HAD=0
t3_save_settings() {
  T3_SAVED_KEY=$1 T3_SAVED_FILE=$2 T3_SAVED_HAD=0
  rm -f "$T3_SAVED_FILE"
  WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 30 "$RGM_WINE_BIN/wine" reg export "$T3_SAVED_KEY" \
    "$(winpath "$T3_SAVED_FILE")" /y >/dev/null 2>&1 && [ -s "$T3_SAVED_FILE" ] && T3_SAVED_HAD=1
  return 0
}
t3_restore_settings() {
  [ -n "$T3_SAVED_KEY" ] || return 0
  local key=$T3_SAVED_KEY rc=0
  T3_SAVED_KEY=""
  WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 30 "$RGM_WINE_BIN/wine" reg delete "$key" /f >/dev/null 2>&1 || true
  if [ "$T3_SAVED_HAD" = 1 ]; then
    WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 30 "$RGM_WINE_BIN/wine" reg import "$(winpath "$T3_SAVED_FILE")" \
      >/dev/null 2>&1 || rc=1
  fi
  return $rc
}

# Close a game like a user would (WM_CLOSE), force only if it ignores that. Prints how.
t3_close_game() {
  local exe=$1
  [ -n "$(game_pid "$exe")" ] || { echo "exited on its own"; return 0; }
  WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 20 "$RGM_WINE_BIN/wine" taskkill /im "$exe" >/dev/null 2>&1
  if wait_for 30 sh -c '! pgrep -f "SuperApp.games.*$1" >/dev/null' _ "$exe"; then
    echo "closed"
    return 0
  fi
  WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 20 "$RGM_WINE_BIN/wine" taskkill /f /im "$exe" >/dev/null 2>&1
  if wait_for 15 sh -c '! pgrep -f "SuperApp.games.*$1" >/dev/null' _ "$exe"; then
    echo "force-closed (ignored WM_CLOSE)"
    return 0
  fi
  echo "still running after taskkill /f"
  return 1
}

# t3_game SLUG VERSION WINDIR EXE ARGS
t3_game() {
  local slug=$1 ver=$2 windir=$3 exe=$4 args=$5 dir info company product plog start mark s problems="" how
  local name="game $slug $ver: starts, reaches its first scene, closes"
  dir="$(unixpath "$windir")"
  info="$dir/${exe%.exe}_Data/app.info"
  if [ ! -f "$info" ]; then skip "$name" "no $info"; return; fi
  company="$(sed -n 1p "$info" | tr -d '\r')"
  product="$(sed -n 2p "$info" | tr -d '\r')"
  plog="$RGM_PREFIX/drive_c/users/$(id -un)/AppData/LocalLow/$company/$product/Player.log"
  if [ "$T3_SHOW" != 1 ]; then
    args="$args $T3_GAME_WINDOW"
    t3_save_settings "HKCU\\Software\\$company\\$product" "$T3_DIR/$slug.reg"
  fi
  start=$(date +%s)
  mark=$(log_lines)
  s=$SECONDS
  # runGame resolves true once the app has started the game (after its "run game" line).
  local out started=0
  out="$(cdp call '(d, e, a) => window.electronAPI.runGame(d, e, a)' "$windir" "$exe" "$args" 2>&1)" || true
  if [ "$out" = true ]; then
    started=1
  else
    problems="$problems; runGame returned $out"
  fi
  # Player.log rewritten by this run, D3D11 device up (DXVK), first scene loaded.
  local ready=0 seen=0
  while [ "$started" = 1 ] && [ $((SECONDS - s)) -lt 180 ]; do
    if [ -f "$plog" ] && [ "$(stat -f %m "$plog")" -ge "$start" ]; then
      grep -q -E "$T3_CRASH" "$plog" && break
      if grep -q 'Version:  Direct3D 11' "$plog" && grep -q '^UnloadTime:' "$plog"; then ready=1; break; fi
    fi
    # Gone after it was up (checked twice), or never showed up within 60 s.
    if [ -n "$(game_pid "$exe")" ]; then
      seen=1
    elif [ "$seen" = 1 ]; then
      sleep 2
      [ -n "$(game_pid "$exe")" ] || break
    elif [ $((SECONDS - s)) -gt 60 ]; then
      break
    fi
    sleep 2
  done
  local up=$((SECONDS - s))
  if [ "$ready" = 1 ]; then
    sleep 10 # stays up
    [ -n "$(game_pid "$exe")" ] || problems="$problems; exited by itself within 10 s of its first scene"
    ! grep -q -E "$T3_CRASH" "$plog" || problems="$problems; crash marker in Player.log"
  elif [ "$started" = 1 ]; then
    problems="$problems; no D3D11 + first scene in Player.log after ${up}s"
    [ -n "$(game_pid "$exe")" ] || problems="$problems; game process gone"
  fi
  # Closed on every path (a start that looked failed may still have started it), then
  # its saved settings put back.
  how="$(t3_close_game "$exe")" || problems="$problems; $how"
  t3_restore_settings || problems="$problems; couldn't restore HKCU\\Software\\$company\\$product (saved in $T3_DIR/$slug.reg)"
  # The app notices, brings itself back and restarts its device manager.
  if [ "$started" = 1 ]; then
    if ! wait_for 60 log_after "$mark" "DEBUG: game closed"; then
      problems="$problems; app never logged 'game closed'"
    elif ! wait_for 60 sh -c 'tail -n +"$(($2 + 1))" "$1" | sed -n "/DEBUG: game closed/,\$p" | grep -q "DEBUG: start device manager"' _ "$T3_LOG" "$mark"; then
      problems="$problems; device manager not restarted after the game"
    fi
  fi
  app_alive && cdp eval '1 + 1' >/dev/null 2>&1 || problems="$problems; app not responding afterwards"
  if [ -z "$problems" ]; then
    pass "$name" "first scene after ${up}s, $how"
  else
    fail "$name" "${problems#; }"
    [ ! -f "$plog" ] || grep -E "$T3_CRASH|Direct3D|UnloadTime" "$plog" | head -10 | indent
    tail -n +"$((mark + 1))" "$T3_LOG" | grep -E 'DEBUG: (run|game|start device|device manager)' | head -10 | indent
  fi
}

t3_quit() {
  local s=$SECONDS rc how="window.close()"
  cdp close >/dev/null 2>&1 || true
  if ! wait_for 45 sh -c '! kill -0 "$1" 2>/dev/null' _ "$T3_PID"; then
    how="taskkill (WM_CLOSE)"
    WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 20 "$RGM_WINE_BIN/wine" taskkill /im RapsodoGolf.exe >/dev/null 2>&1
    wait_for 45 sh -c '! kill -0 "$1" 2>/dev/null' _ "$T3_PID"
  fi
  if app_alive; then
    fail "app quits cleanly" "still running 90 s after window.close() and taskkill; killing Wine"
    t3_cleanup
    return
  fi
  rc=0
  wait "$T3_PID" || rc=$?
  T3_PID=""
  t3_guard_stop
  # After a quit every Wine process of this install exits (wineserver lingers ~3 s).
  if ! wait_for 30 nothing_running; then
    local left
    left="$(ps -o command= -p "$(wine_pids | paste -sd, -)" 2>/dev/null | tr '\n' ';' | cut -c1-300)"
    fail "app quits cleanly" "app exited ($rc) via $how, but Wine processes remain: $left"
    WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -k 2>/dev/null || true
  elif [ "$rc" != 0 ]; then
    fail "app quits cleanly" "launcher exit status $rc via $how"
  else
    pass "app quits cleanly" "via $how in $((SECONDS - s))s; no Wine process left"
  fi
}

tier3() {
  local why=""
  [ -f "$RGM_APP_DIR/RapsodoGolf.exe" ] || why="app not installed ($RGM_APP_DIR)"
  [ -n "$why" ] || [ -x "$RGM_WINE_BIN/wine" ] || why="Wine not installed"
  [ -n "$why" ] || have clang || why="no clang (xcode-select --install)"
  [ -n "$why" ] || { have node && node -e 'process.exit(typeof WebSocket === "function" ? 0 : 1)' 2>/dev/null; } ||
    why="needs Node 22 or newer (brew install node)"
  if [ -z "$why" ] && pgrep -f "RapsodoGolf.exe --no-sandbox" >/dev/null; then
    why="the app is running; quit it first (tier 3 starts its own copy in the same prefix)"
  fi
  # Tier 2's programs leave Wine's server up for a few seconds.
  if [ -z "$why" ] && ! wait_for 20 nothing_running; then
    why="other programs of this Wine install are running (a game, wine reg, ...)"
  fi
  if [ -z "$why" ] && nc -z 127.0.0.1 "$T3_PORT" 2>/dev/null; then
    why="port $T3_PORT is in use (set RGM_TEST_PORT)"
  fi
  if [ -n "$why" ]; then
    skip "tier 3" "$why"
    return
  fi
  if t3_start && t3_page; then
    if [ "${T4_WANTED:-0}" = 1 ] && monitor_up; then
      echo "-- Tier 4 checks (monitor), with this app"
      TIER=4
      t4_live || true
      T4_DONE=1
      TIER=3
    fi
    # The list comes in on fd 3, so nothing in the loop (wine, node) can eat it.
    local slug ver windir exe args n=0
    while IFS=$'\t' read -r slug ver windir exe args <&3; do
      [ -n "$slug" ] || continue
      case " ${RGM_TEST_GAMES:-$slug} " in *" $slug "*) ;; *) continue ;; esac
      n=$((n + 1))
      t3_game "$slug" "$ver" "$windir" "$exe" "$args" </dev/null
      app_alive || break
    done 3< <(t3_games)
    [ "$n" -gt 0 ] || skip "games" "no game downloaded${RGM_TEST_GAMES:+ matching RGM_TEST_GAMES}"
  fi
  if app_alive; then t3_quit; fi
  TIER3_CLEANUP=""
}
