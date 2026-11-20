#!/usr/bin/env bash
# Opt-in: run the Unity games under CrossOver with DXMT (D3D11 straight to Metal)
# instead of this Wine's DXVK -> MoltenVK. ~4x the frame rate on a base M4
# (notes/2026-11-20-game-fps-benchmark.md). Needs CrossOver (paid, 14-day trial).
#
# Turn on with RGM_GAME_RUNTIME=crossover in scripts/env.local.sh. Then:
# - each game's <Game>.exe becomes rgm-game-runner.exe (game_runner.c); the real exe
#   is kept as <Game>.exe.rgm-unity. The app starts the stand-in as it would the
#   game, and game-runner.sh (started by play.sh) runs the real game in the bottle.
# - the bottle ($RGM_CX_BOTTLE) sees the app's C:\ProgramData\Rapsodo through a
#   symlink: the games read the signed-in user and settings from app.db there.
# Without it (the default), every real exe is put back. Re-run after a new game
# download (play.sh does). Never run it while a game is running.
set -euo pipefail
. "$(dirname "$0")/env.sh"

GAMES="$RGM_PREFIX/drive_c/ProgramData/Rapsodo/SuperApp/games"
MARKER=RGM-GAME-RUNNER-STUB
stub="$RGM_BUILD/rgm-game-runner.exe"
is_stub() { LC_ALL=C grep -q -a "$MARKER" "$1" 2>/dev/null; }

# Every game exe: games/<id>/<ver>/<Name>.exe next to <Name>_Data/.
game_exes() {
  [ -d "$GAMES" ] || return 0
  find "$GAMES" -mindepth 3 -maxdepth 3 -type d -name '*_Data' | while IFS= read -r data; do
    echo "${data%_Data}.exe"
  done
}

if [ "${RGM_GAME_RUNTIME:-wine}" != crossover ]; then
  game_exes | while IFS= read -r exe; do
    [ -f "$exe.rgm-unity" ] || continue
    mv -f "$exe.rgm-unity" "$exe"
    echo "game runtime: $(basename "$exe") runs in this Wine again"
  done
  exit 0
fi

cxwine="$RGM_CX_ROOT/bin/wine"
[ -x "$cxwine" ] || {
  echo "RGM_GAME_RUNTIME=crossover, but CrossOver isn't at $RGM_CX_ROOT" >&2
  exit 1
}

# The stand-in. Rebuilt only when its source changes (by content, like 48).
src="$(dirname "$0")/game_runner.c"
want="$(shasum -a 256 "$src" | cut -d' ' -f1)"
if [ ! -f "$stub" ] || [ "$(cat "$stub.src.sha256" 2>/dev/null)" != "$want" ]; then
  command -v x86_64-w64-mingw32-gcc >/dev/null || { echo "brew install mingw-w64" >&2; exit 1; }
  mkdir -p "$RGM_BUILD"
  x86_64-w64-mingw32-gcc -municode -O2 -s -o "$stub.tmp" "$src" -luser32
  mv -f "$stub.tmp" "$stub"
  echo "$want" >"$stub.src.sha256"
fi

# The bottle, created once.
bottle="$RGM_CX_BOTTLES/$RGM_CX_BOTTLE"
if [ ! -f "$bottle/cxbottle.conf" ]; then
  "$RGM_CX_ROOT/bin/cxbottle" --bottle "$RGM_CX_BOTTLE" --create --template win10_64 \
    --description "Rapsodo Golf games (rapsodo-golf-on-mac)" >/dev/null
  echo "game runtime: created CrossOver bottle $RGM_CX_BOTTLE"
fi
# The app's shared data (app.db: user, settings; games/). A real folder there is
# left from an older setup or a test: keep it aside rather than delete it.
link="$bottle/drive_c/ProgramData/Rapsodo"
if [ "$(readlink "$link" 2>/dev/null)" != "$RGM_PREFIX/drive_c/ProgramData/Rapsodo" ]; then
  mkdir -p "$(dirname "$link")"
  if [ -e "$link" ] || [ -L "$link" ]; then mv "$link" "$link.rgm-old.$(date +%s)"; fi
  ln -s "$RGM_PREFIX/drive_c/ProgramData/Rapsodo" "$link"
fi

# Swap the stand-in in. A non-stub <Game>.exe is a real one (new game, or a game
# update): it becomes the new .rgm-unity.
game_exes | while IFS= read -r exe; do
  [ -f "$exe" ] || continue
  if is_stub "$exe"; then
    cmp -s "$stub" "$exe" || cp "$stub" "$exe"
    continue
  fi
  mv -f "$exe" "$exe.rgm-unity"
  cp "$stub" "$exe"
  echo "game runtime: $(basename "$exe") runs under CrossOver ($RGM_GAME_BACKEND)"
done

# Each game's Unity settings (screen, monitor) live in the registry, which the
# bottle doesn't share. Copy them over once per game, so it opens where it did
# before; after that the bottle's copy is the game's own (a marker file records it,
# so a later run never overwrites settings changed in the game).
export WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all
copied="$bottle/drive_c/rgm-games/.settings-copied"
mkdir -p "$copied"
[ ! -d "$GAMES" ] || find "$GAMES" -mindepth 4 -maxdepth 4 -path '*_Data/app.info' | while IFS= read -r info; do
  key="HKCU\\Software\\$(sed -n 1p "$info" | tr -d '\r')\\$(sed -n 2p "$info" | tr -d '\r')"
  mark="$copied/$(printf '%s' "$key" | shasum | cut -c1-16)"
  [ -e "$mark" ] && continue
  if "$cxwine" --bottle "$RGM_CX_BOTTLE" --no-update reg query "$key" >/dev/null 2>&1; then
    echo "$key" >"$mark"  # already there (copied before markers existed)
    continue
  fi
  tmp="$RGM_PREFIX/drive_c/rgm-reg-export.reg"
  "$RGM_WINE_BIN/wine" reg export "$key" 'C:\rgm-reg-export.reg' /y >/dev/null 2>&1 || continue
  cp "$tmp" "$bottle/drive_c/rgm-reg-export.reg"
  if "$cxwine" --bottle "$RGM_CX_BOTTLE" --no-update reg import 'C:\rgm-reg-export.reg' >/dev/null 2>&1; then
    echo "$key" >"$mark"
    echo "game runtime: copied the settings of $key"
  fi
  rm -f "$tmp" "$bottle/drive_c/rgm-reg-export.reg"
done
