#!/usr/bin/env bash
# Runs the games the app starts under CrossOver (RGM_GAME_RUNTIME=crossover; see
# 49-game-runtime.sh). play.sh starts it next to the app: game-runner.sh <app pid>.
#
# The stand-in exe (game_runner.c) drops C:\ProgramData\rgm-game-runner\<pid>.req
# (line 1: its own Windows path, line 2: its arguments) and waits for <pid>.exit.
# For each request this runs the real exe (<Game>.exe.rgm-unity) from a mirror of
# the game folder in the bottle, C:\rgm-games\<id>\<ver>\: links to every file of
# the game plus a clone of the real exe under its own name, which Unity needs to find
# <Game>_Data. The stand-in touches its request every second; when that stops (the
# app killed it) the game is closed. Everything stops when the app exits.
set -uo pipefail
. "$(dirname "$0")/env.sh"

app_pid="${1:?usage: game-runner.sh <app pid>}"
dir="$RGM_PREFIX/drive_c/ProgramData/rgm-game-runner"
bottle="$RGM_CX_BOTTLES/$RGM_CX_BOTTLE"
mirrors="$bottle/drive_c/rgm-games"
games="$RGM_PREFIX/drive_c/ProgramData/Rapsodo/SuperApp/games"
log() { echo "$(date '+%H:%M:%S') $*"; }
stop_games() { WINEPREFIX="$bottle" "$RGM_CX_ROOT/bin/wineserver" -k 2>/dev/null || true; }

mkdir -p "$dir"
rm -f "$dir"/*  # requests from a session that's gone
stop_games

run_game() {
  local id=$1 req="$dir/$1.req" winexe args rel gdir exe name mirror winmirror gpid rc age
  winexe="$(sed -n 1p "$req" | tr -d '\r')"
  args="$(sed -n 2p "$req" | tr -d '\r')"
  # C:\ProgramData\Rapsodo\SuperApp\games\<id>\<ver>\<Game>.exe -> <id>/<ver>/<Game>.exe
  rel="$(printf '%s' "$winexe" | tr '\134' '/')"
  case "$rel" in
    [Cc]:/ProgramData/Rapsodo/SuperApp/games/*) rel="${rel#*:/ProgramData/Rapsodo/SuperApp/games/}" ;;
    *) log "not a game under SuperApp\\games: $winexe"; echo 1 >"$dir/$id.exit"; return ;;
  esac
  gdir="$games/$(dirname "$rel")"
  name="$(basename "$rel")"
  exe="$gdir/$name.rgm-unity"
  if [ ! -f "$exe" ]; then
    log "no $name.rgm-unity in $gdir (run 49-game-runtime.sh)"
    echo 1 >"$dir/$id.exit"
    return
  fi

  mirror="$mirrors/$(dirname "$rel")"
  mkdir -p "$mirror"
  local f b
  for f in "$gdir"/*; do
    b="$(basename "$f")"
    case "$b" in "$name" | "$name.rgm-unity") continue ;; esac
    [ "$(readlink "$mirror/$b" 2>/dev/null)" = "$f" ] || ln -sfn "$f" "$mirror/$b"
  done
  cmp -s "$exe" "$mirror/$name" || cp -c "$exe" "$mirror/$name" 2>/dev/null || cp "$exe" "$mirror/$name"
  winmirror="C:\\rgm-games\\$(dirname "$rel" | tr '/' '\134')\\$name"

  log "start $name $args ($RGM_GAME_BACKEND)"
  # shellcheck disable=SC2086  # the app's arguments, one per word (e.g. -language=en)
  env CX_GRAPHICS_BACKEND="$RGM_GAME_BACKEND" ${RGM_GAME_HUD:+MTL_HUD_ENABLED=1} \
    "$RGM_CX_ROOT/bin/wine" --bottle "$RGM_CX_BOTTLE" --no-update --cx-app "$winmirror" $args \
    >>"$RGM_USER_HOME/Library/Logs/RapsodoGolf-games-wine.log" 2>&1 &
  gpid=$!
  local orphan=""
  while kill -0 "$gpid" 2>/dev/null; do
    sleep 2
    age=$(($(date +%s) - $(stat -f %m "$req" 2>/dev/null || echo 0)))
    if [ "$age" -gt 15 ]; then
      log "the app closed $name; closing the game"
      orphan=1
      stop_games
      break
    fi
  done
  rc=0
  wait "$gpid" || rc=$?
  log "$name exited ($rc)"
  if [ -n "$orphan" ]; then
    rm -f "$req" "$dir/$id.started"  # nobody left to read an exit code
  else
    echo "$rc" >"$dir/$id.tmp" && mv -f "$dir/$id.tmp" "$dir/$id.exit"
  fi
}

log "game runner up (bottle $RGM_CX_BOTTLE, $RGM_GAME_BACKEND)"
while kill -0 "$app_pid" 2>/dev/null; do
  for req in "$dir"/*.req; do
    [ -e "$req" ] || continue
    id="$(basename "$req" .req)"
    [ -e "$dir/$id.started" ] && continue
    : >"$dir/$id.started"
    run_game "$id" &
  done
  sleep 0.5
done
log "app exited; stopping games"
stop_games
