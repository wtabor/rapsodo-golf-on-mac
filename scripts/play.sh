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

# Wine is an Intel build. macOS updates can remove Rosetta 2 (27.0.1 did, 10/2026),
# and then every Wine binary fails with "Bad CPU type in executable".
arch -x86_64 /usr/bin/true 2>/dev/null ||
  fail "Rosetta 2 is not installed (a macOS update can remove it). Install it with:
  sudo softwareupdate --install-rosetta --agree-to-license"

if pgrep -f "RapsodoGolf.exe --no-sandbox" >/dev/null; then
  echo "Rapsodo Golf is already running."
  exit 0
fi

# A crashed or force-quit session can leave Wine processes behind (renderer,
# deviceManagerServer.exe) holding the app's database. The new device manager
# then exits before binding a port: "The device manager could not start".
# The app isn't running (checked above), so anything left in the prefix is stale.
WINEPREFIX="$RGM_PREFIX" "$RGM_WINE_BIN/wineserver" -k 2>/dev/null || true

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
  for _ in $(seq 1 120); do
    if grep -q "DEBUG: start device manager" "$RGM_LOG"; then result=ok; break; fi
    if grep -q "device manager server start failed" "$RGM_LOG"; then result=failed; break; fi
    kill -0 "$pid" 2>/dev/null || break
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
while kill -0 "$pid" 2>/dev/null; do
  sleep 2
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
  tried="$new"
  echo "New game downloaded; applying the Wine fixes to it."
  { "$d/40-apply-patches.sh" && "$d/45-install-dxvk.sh"; } >>"$heal_log" 2>&1 ||
    echo "warning: patching the new game failed; see $heal_log" >&2
done &
watcher=$!

# Stay open as long as the app runs, like the exec this replaced.
rc=0
wait "$pid" || rc=$?
kill "$watcher" 2>/dev/null || true
exit "$rc"
