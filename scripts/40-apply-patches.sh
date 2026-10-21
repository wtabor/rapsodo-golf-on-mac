#!/usr/bin/env bash
# Apply the Wine fixes to the installed app and to every downloaded game (each
# game ships its own libzmq.dll, deviceManagerServer.dll and GeolocationPlugin.dll in
# games/<id>/<version>/<Game>_Data/Plugins/x86_64/). Re-run after any Rapsodo app
# update or after the app downloads a new game.
set -euo pipefail
. "$(dirname "$0")/env.sh"

[ -d "$RGM_LIBS_DIR" ] || { echo "app not installed: $RGM_LIBS_DIR" >&2; exit 1; }
[ -f "$RGM_BUILD/libzmq.dll" ] || "$(dirname "$0")/30-build-libzmq.sh"
geo_src="$(dirname "$0")/geolocation_stub.c"
if [ ! -f "$RGM_BUILD/GeolocationPlugin.dll" ] || [ "$geo_src" -nt "$RGM_BUILD/GeolocationPlugin.dll" ]; then
  mkdir -p "$RGM_BUILD"
  x86_64-w64-mingw32-gcc -shared -O2 -s -o "$RGM_BUILD/GeolocationPlugin.dll" "$geo_src"
fi
# The only GeolocationPlugin.dll whose ABI geolocation_stub.c was checked against.
GEO_SHA256=460583745a1b803ab877ac22bdd9d45a5181cc615bc9fad4e3f4dfd0b935874d
GAMES="$RGM_PREFIX/drive_c/ProgramData/Rapsodo/SuperApp/games"

# 1) libzmq: swap in the patched build, keep the original once.
[ -f "$RGM_LIBS_DIR/libzmq.dll.orig" ] || cp "$RGM_LIBS_DIR/libzmq.dll" "$RGM_LIBS_DIR/libzmq.dll.orig"
cp "$RGM_BUILD/libzmq.dll" "$RGM_LIBS_DIR/libzmq.dll"
echo "libzmq.dll replaced (original: libzmq.dll.orig)"

# 2) deviceManagerServer.exe: SIO_UDP_NETRESET -> SIO_UDP_CONNRESET.
python3 -I "$(dirname "$0")/patch_devicemanager.py" "$RGM_LIBS_DIR/deviceManagerServer.exe"

# 3) Same two fixes for each game. The patched libzmq is only a drop-in for the
#    exact 4.3.5 build the app ships, so skip any game whose original differs.
want="$(shasum -a 256 "$RGM_LIBS_DIR/libzmq.dll.orig" | cut -d' ' -f1)"
[ -d "$GAMES" ] || exit 0
find "$GAMES" -mindepth 6 -maxdepth 6 -path '*_Data/Plugins/x86_64/libzmq.dll' -print0 |
while IFS= read -r -d '' zmq; do
  dir="$(dirname "$zmq")"
  game="${dir#"$GAMES"/}"; game="${game%%_Data/*}"
  [ -f "$zmq.orig" ] || cp "$zmq" "$zmq.orig"
  if [ "$(shasum -a 256 "$zmq.orig" | cut -d' ' -f1)" = "$want" ]; then
    cp "$RGM_BUILD/libzmq.dll" "$zmq"
    echo "libzmq.dll replaced: $game"
  else
    echo "skipped libzmq.dll (not the known 4.3.5 build): $game" >&2
  fi
  [ ! -f "$dir/deviceManagerServer.dll" ] ||
    python3 -I "$(dirname "$0")/patch_devicemanager.py" "$dir/deviceManagerServer.dll"
  # 4) Location: report Allowed + RGM_GEO_* instead of the WinRT lookup Wine denies.
  geo="$dir/GeolocationPlugin.dll"
  if [ -f "$geo" ]; then
    [ -f "$geo.orig" ] || cp "$geo" "$geo.orig"
    if [ "$(shasum -a 256 "$geo.orig" | cut -d' ' -f1)" = "$GEO_SHA256" ]; then
      cp "$RGM_BUILD/GeolocationPlugin.dll" "$geo"
      echo "GeolocationPlugin.dll replaced: $game"
    else
      echo "skipped GeolocationPlugin.dll (unknown build, ABI unchecked): $game" >&2
    fi
  fi
done
