#!/usr/bin/env bash
# One command to play: starts the USB link (needs your password once, unless the
# LaunchDaemon from 60-install-usb-daemon.sh is installed), re-applies the Wine
# fixes, and starts the app.
#
# Run this from a terminal app that has Local Network permission (System
# Settings → Privacy & Security → Local Network; e.g. iTerm). The app inherits
# that permission. Launched from Finder instead, macOS silently blocks the app's
# mDNS discovery because Wine's binaries are unsigned and never get a prompt.
set -euo pipefail
d="$(cd "$(dirname "$0")" && pwd)"
. "$d/env.sh"

# Opened from the Dock app, the iTerm window closes when this exits: keep errors on
# screen until the user has read them.
fail() {
  echo "error: $*" >&2
  [ -t 0 ] && read -r -p "Press Return to close." _
  exit 1
}

# Wine's server for this install. If it crashes, every Wine process (the app and
# any game) freezes for good: windows stay up, nothing moves. Seen 10/26/2026 when
# the monitor reset its USB link while a game was connecting. Wine starts it by its
# resolved path, so compare against that (RGM_HOME may go through a symlink).
wine_root="$(cd "$RGM_HOME/Wine Staging.app" 2>/dev/null && pwd -P)" ||
  wine_root="$RGM_HOME/Wine Staging.app"
is_server() { case "$(ps -o command= -p "$1" 2>/dev/null)" in "$wine_root/"*) return 0 ;; esac; return 1; }
server_pid() {
  local p
  for p in $(pgrep -x wineserver); do
    is_server "$p" && { echo "$p"; return 0; }
  done
  return 1
}
server_running() { server_pid >/dev/null; }
# Every process of this Wine install maps locale.nls (other Wine copies map their
# own), so lsof finds them even after their server is gone.
wine_nls="$RGM_WINE_BIN/../share/wine/nls/locale.nls"
wine_pids() { lsof -t "$wine_nls" 2>/dev/null || true; }
kill_wine() {
  local pids
  pids="$(wine_pids)"
  # shellcheck disable=SC2086  # one pid per word
  [ -z "$pids" ] || kill -9 $pids 2>/dev/null || true
}
# The next start truncates both logs; keep a copy of each for bug reports.
save_crash_logs() {
  local l
  for l in "$RGM_LOG" "$RGM_USER_HOME/Library/Logs/RapsodoGolf-heal.log"; do
    cp "$l" "${l%.log}-crashed.log" 2>/dev/null || true
  done
}
# With any core limit above 0, wineserver skips its own SIGSEGV handler (which just
# prints "wineserver crashed" and exits), so a crash leaves a macOS crash report
# with the faulting address: wineserver-*.ips in ~/Library/Logs/DiagnosticReports or
# /Library/Logs/DiagnosticReports (Console app → Crash Reports shows both).
# 1 block is too small for any core file to be written. Wine processes inherit it.
# Soft limit only, and never fatal: a hard limit of 0 just means no crash report.
ulimit -Sc 1 2>/dev/null || true

# Wine is an Intel build. macOS updates can remove Rosetta 2 (27.0.1 did, 10/2026),
# and then every Wine binary fails with "Bad CPU type in executable".
arch -x86_64 /usr/bin/true 2>/dev/null ||
  fail "Rosetta 2 is not installed (a macOS update can remove it). Install it with:
  sudo softwareupdate --install-rosetta --agree-to-license"

if pgrep -f "RapsodoGolf.exe --no-sandbox" >/dev/null; then
  # An app that is just starting has no server for a moment; a frozen one never
  # gets it back.
  if server_running || { sleep 2; server_running; }; then
    echo "Rapsodo Golf is already running."
    exit 0
  fi
  echo "The last session froze (Wine crashed). Closing what's left of it."
  save_crash_logs
fi

# A crashed or force-quit session can leave Wine processes behind (renderer,
# deviceManagerServer.exe) holding the app's database. The new device manager
# then exits before binding a port: "The device manager could not start".
# The app isn't running (checked above), so anything left in the prefix is stale.
WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -k 2>/dev/null || true
# wineserver -k can't reach processes whose server crashed; they'd stay frozen.
server_running || kill_wine

# Install any newer version of this project from GitHub, then start over with the
# new play.sh (see update.sh). After the cleanup above, so no stale Wine process is
# around while the update re-applies the fixes. RGM_UPDATED stops a second check.
if [ -z "${RGM_UPDATED:-}" ]; then
  rc=0
  "$d/update.sh" || rc=$?
  [ "$rc" = 3 ] && RGM_UPDATED=1 exec "$d/play.sh" "$@"
fi

if ! pgrep -f "usb-link.sh" >/dev/null; then
  sudo -v
  # shellcheck disable=SC2024  # log stays user-owned on purpose
  sudo "$d/usb-link.sh" >"$RGM_USER_HOME/Library/Logs/RapsodoGolf-usblink.log" 2>&1 &
  echo "USB link started (log: ~/Library/Logs/RapsodoGolf-usblink.log)"
fi

# Rapsodo auto-updates and new game downloads undo the fixes; re-applying is
# idempotent and takes a few seconds.
heal_log="$RGM_USER_HOME/Library/Logs/RapsodoGolf-heal.log"
if "$d/40-apply-patches.sh" >"$heal_log" 2>&1 && "$d/45-install-dxvk.sh" >>"$heal_log" 2>&1 &&
  "$d/47-install-mediamtx.sh" >>"$heal_log" 2>&1; then
  echo "Wine fixes checked (log: ~/Library/Logs/RapsodoGolf-heal.log)"
else
  echo "warning: re-applying the Wine fixes failed; see $heal_log" >&2
fi

# Don't block on the monitor: the app is usable without it, and usb-link.sh keeps
# watching in the background, so the link comes up whenever the monitor appears.
if ifconfig feth0 2>/dev/null | grep -q "inet 192\.168\.36\."; then
  echo "Monitor link up: $(ifconfig feth0 | awk '/inet /{print $2}')"
else
  echo "Monitor not connected yet. Starting the app anyway: power the monitor on and"
  echo "plug in USB-C, then connect from the app (it can take about 60 s to answer)."
fi

# Start the app and watch its log. If the device manager fails to start ("The
# device manager could not start"), clear Wine and start the app again, up to
# three tries. A failed try's log is kept as RapsodoGolf-Wine-failed.log.
failed_log="${RGM_LOG%.log}-failed.log"
tries=3
for try in $(seq 1 "$tries"); do
  : >"$RGM_LOG"
  "$RGM_APP_BUNDLE/Contents/MacOS/launch" &
  pid=$!
  result=""
  seen=""
  for _ in $(seq 1 120); do
    if grep -q "DEBUG: start device manager" "$RGM_LOG"; then result=ok; break; fi
    if grep -q "device manager server start failed" "$RGM_LOG"; then result=failed; break; fi
    kill -0 "$pid" 2>/dev/null || break
    # Wine crashed before the app got this far: it never will. The watcher below
    # closes it and starts over.
    if server_running; then
      seen=1
    elif [ -n "$seen" ] && { sleep 1; ! server_running; } && kill -0 "$pid" 2>/dev/null; then
      result=crashed
      break
    fi
    sleep 1
  done
  [ "$result" = failed ] || break
  cp "$RGM_LOG" "$failed_log"
  if [ "$try" -lt "$tries" ]; then
    echo "The device manager didn't start (try $try of $tries). Restarting the app..."
    WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -k 2>/dev/null || true
    wait "$pid" || true
    sleep 2
  else
    echo "error: the device manager still didn't start after $tries tries. Please open an" >&2
    echo "issue and attach ~/Library/Logs/$(basename "$failed_log")." >&2
  fi
done
[ "$result" = ok ] && echo "Rapsodo Golf started."

# A game downloaded while the app runs ships its own unpatched libzmq.dll and
# deviceManagerServer.dll. The app hands the monitor to the game (light goes red,
# "ready to connect") and the game can't connect. Patch new games as soon as the
# app logs "download game end" (or, failing that, once games/ has been unchanged
# for 15 s), and never while a game is running.
games="$RGM_PREFIX/drive_c/ProgramData/Rapsodo/SuperApp/games"
tried=""
ends=0
# The app's own server. Once it's gone, a new one (a `wine reg` below would start
# one) doesn't bring the frozen app back, so watch this pid, not just any server.
srv="$(server_pid)" || srv=""
app_server_alive() { if [ -n "$srv" ]; then is_server "$srv"; else server_running; fi; }
while kill -0 "$pid" 2>/dev/null; do
  sleep 2
  # Wine's server crashed while the app runs: close the frozen app and game so
  # the end of this script can start over. Checked twice, with the app still up,
  # so a normal quit never counts.
  if kill -0 "$pid" 2>/dev/null && ! app_server_alive; then
    sleep 1
    if kill -0 "$pid" 2>/dev/null && ! app_server_alive; then
      echo "Wine crashed, which froze the app and any game. Closing them..."
      kill_wine
      exit 3
    fi
  fi
  [ -d "$games" ] || continue
  new="$(find "$games" -mindepth 6 -maxdepth 6 -path '*_Data/Plugins/x86_64/libzmq.dll' 2>/dev/null |
    while IFS= read -r zmq; do [ -f "$zmq.orig" ] || echo "$zmq"; done)" || true
  # One try per new game, so a game 40 can't patch doesn't loop.
  [ -n "$new" ] && [ "$new" != "$tried" ] || continue
  n="$(grep -c "download game end" "$RGM_LOG" 2>/dev/null)" || n=0
  if [ "$n" -le "$ends" ] && [ -n "$(find "$games" -mtime -15s -print -quit 2>/dev/null)" ]; then
    continue
  fi
  ends=$n
  pgrep -f 'SuperApp[/\\]games[/\\].*\.exe' >/dev/null && continue
  app_server_alive || continue
  tried="$new"
  echo "New game downloaded; applying the Wine fixes to it."
  # In the background, so a Wine crash meanwhile is still caught at the top of
  # the loop (kill_wine also ends a frozen `wine reg`).
  { "$d/40-apply-patches.sh" && "$d/45-install-dxvk.sh"; } >>"$heal_log" 2>&1 &
  patcher=$!
  while kill -0 "$patcher" 2>/dev/null && app_server_alive; do sleep 1; done
  kill -0 "$patcher" 2>/dev/null && continue
  wait "$patcher" || echo "warning: patching the new game failed; see $heal_log" >&2
done &
watcher=$!

# Stay open as long as the app runs, like the exec this replaced. The watcher ends
# within 2 s of the app; status 3 means Wine crashed and it closed everything.
rc=0
wait "$pid" || rc=$?
wrc=0
wait "$watcher" || wrc=$?
# Leftover Wine processes with no server are frozen too (the app's main process
# can die on its own when the server crashes, so the watcher may not see it). After
# a normal quit the app's server lingers a few seconds, then everything exits. A
# server a `wine reg` started after a crash exits within ~3 s too; wait it out.
if [ "$wrc" != 3 ] && ! app_server_alive && [ -n "$(wine_pids)" ]; then
  for _ in 1 2 3 4 5; do server_running || break; sleep 2; done
  if ! server_running && [ -n "$(wine_pids)" ]; then
    kill_wine
    wrc=3
  fi
fi
if [ "$wrc" = 3 ]; then
  save_crash_logs
  restarts=$((${RGM_WINE_RESTARTS:-0} + 1))
  if [ "$restarts" -le 3 ]; then
    echo "Restarting Rapsodo Golf (Wine crash $restarts of 3 allowed this session)..."
    RGM_WINE_RESTARTS=$restarts RGM_UPDATED=1 exec "$d/play.sh" "$@"
  fi
  fail "Wine crashed again ($restarts times). Start Rapsodo Golf again from the Dock. If it
  keeps happening, open an issue and attach ~/Library/Logs/RapsodoGolf-Wine-crashed.log
  and the newest wineserver crash report (Console app → Crash Reports → wineserver)."
fi
exit "$rc"
