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
log_after() { tail -n +"$(($1 + 1))" "$T3_LOG" 2>/dev/null | grep -q -E "$2"; }
log_lines() { if [ -f "$T3_LOG" ]; then wc -l <"$T3_LOG" | tr -d ' '; else echo 0; fi; }
nothing_running() { [ -z "$(wine_pids)" ]; }

# Close the app this tier started, however the run ends (Ctrl-C included). Only Wine
# processes of this install can be running then (checked before starting).
t3_cleanup() {
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
  RGM_REMOTE_DEBUGGING_PORT="$T3_PORT" "$T3_DIR/launch" &
  T3_PID=$!
  TIER3_CLEANUP=t3_cleanup
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

# t3_game SLUG VERSION WINDIR EXE ARGS
t3_game() {
  local slug=$1 ver=$2 windir=$3 exe=$4 args=$5 dir info company product plog start mark s problems=""
  local how="exited on its own"
  local name="game $slug $ver: starts, reaches its first scene, closes"
  dir="$(unixpath "$windir")"
  info="$dir/${exe%.exe}_Data/app.info"
  if [ ! -f "$info" ]; then skip "$name" "no $info"; return; fi
  company="$(sed -n 1p "$info" | tr -d '\r')"
  product="$(sed -n 2p "$info" | tr -d '\r')"
  plog="$RGM_PREFIX/drive_c/users/$(id -un)/AppData/LocalLow/$company/$product/Player.log"
  start=$(date +%s)
  mark=$(log_lines)
  s=$SECONDS
  local out
  out="$(cdp call '(d, e, a) => window.electronAPI.runGame(d, e, a)' "$windir" "$exe" "$args" 2>&1)" || true
  if [ "$out" != true ]; then
    fail "$name" "runGame returned $out"
    return
  fi
  if ! wait_for 30 log_after "$mark" "DEBUG: run game $exe"; then
    fail "$name" "no 'run game' line in the app log"
    tail -n +"$((mark + 1))" "$T3_LOG" | tail -n 20 | indent
    return
  fi
  # Player.log rewritten by this run, D3D11 device up (DXVK), first scene loaded.
  local ready=0 seen=0
  while [ $((SECONDS - s)) -lt 180 ]; do
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
  else
    problems="$problems; no D3D11 + first scene in Player.log after ${up}s"
    [ -n "$(game_pid "$exe")" ] || problems="$problems; game process gone"
  fi
  # Close it like a user would (WM_CLOSE), force only if it ignores that.
  if [ -n "$(game_pid "$exe")" ]; then
    WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 20 "$RGM_WINE_BIN/wine" taskkill /im "$exe" >/dev/null 2>&1
    if wait_for 30 sh -c '! pgrep -f "SuperApp.games.*$1" >/dev/null' _ "$exe"; then
      how="closed"
    else
      WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all with_timeout 20 "$RGM_WINE_BIN/wine" taskkill /f /im "$exe" >/dev/null 2>&1
      wait_for 15 sh -c '! pgrep -f "SuperApp.games.*$1" >/dev/null' _ "$exe" && how="force-closed (ignored WM_CLOSE)" ||
        problems="$problems; still running after taskkill /f"
    fi
  fi
  # The app notices, brings itself back and restarts its device manager.
  if ! wait_for 60 log_after "$mark" "DEBUG: game closed"; then
    problems="$problems; app never logged 'game closed'"
  elif ! wait_for 60 sh -c 'tail -n +"$(($2 + 1))" "$1" | sed -n "/DEBUG: game closed/,\$p" | grep -q "DEBUG: start device manager"' _ "$T3_LOG" "$mark"; then
    problems="$problems; device manager not restarted after the game"
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
