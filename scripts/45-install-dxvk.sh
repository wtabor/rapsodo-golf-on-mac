#!/usr/bin/env bash
# D3D11 for the Unity games (DrivingRange.exe etc.). Wine's wined3d can't create a
# D3D11 device on macOS ("Failed to create command stream"), and the games ship
# D3D11/D3D12 shaders only, so -force-glcore/-force-vulkan don't help. DXVK-macOS
# (D3D11 -> Vulkan -> MoltenVK, which this Wine already bundles) does.
# The DLLs go into system32 but are only used by the exes overridden below; every
# other program keeps Wine's builtin d3d11. Re-run after a Rapsodo update or
# after a new game is downloaded.
set -euo pipefail
. "$(dirname "$0")/env.sh"

DXVK_TAG=v1.10.3-20230507-repack
DXVK_NAME=dxvk-macOS-async-$DXVK_TAG
DXVK_URL=https://github.com/Gcenx/DXVK-macOS/releases/download/$DXVK_TAG/$DXVK_NAME.tar.gz
DXVK_SHA256=acd1520ad105d8ef124a09c8e11a259a5dc8bdc565ad18e0e52693f9807b2477
DXVK_DIR="$RGM_BUILD/dxvk"
SYS32="$RGM_PREFIX/drive_c/windows/system32"
GAMES="$RGM_PREFIX/drive_c/ProgramData/Rapsodo/SuperApp/games"
export WINEPREFIX="$RGM_PREFIX" WINEDEBUG=-all

if [ ! -f "$DXVK_DIR/$DXVK_NAME/x64/d3d11.dll" ]; then
  mkdir -p "$DXVK_DIR"
  curl -fL --progress-bar -o "$DXVK_DIR/dxvk.tar.gz" "$DXVK_URL"
  echo "$DXVK_SHA256  $DXVK_DIR/dxvk.tar.gz" | shasum -a 256 -c -
  tar -xzf "$DXVK_DIR/dxvk.tar.gz" -C "$DXVK_DIR"
  rm -f "$DXVK_DIR/dxvk.tar.gz"
fi

for dll in d3d11 d3d10core; do
  cmp -s "$DXVK_DIR/$DXVK_NAME/x64/$dll.dll" "$SYS32/$dll.dll" ||
    cp "$DXVK_DIR/$DXVK_NAME/x64/$dll.dll" "$SYS32/$dll.dll"
done
echo "DXVK $DXVK_TAG installed into system32"

# Per-exe overrides: DrivingRange.exe always, plus any Unity game already downloaded
# (games/<id>/<version>/<Name>.exe next to <Name>_Data/).
exes="DrivingRange.exe"
if [ -d "$GAMES" ]; then
  while IFS= read -r data; do
    exes="$exes
$(basename "${data%_Data}").exe"
  done < <(find "$GAMES" -mindepth 3 -maxdepth 3 -type d -name '*_Data')
fi
printf '%s\n' "$exes" | sort -u | while IFS= read -r exe; do
  key="HKCU\\Software\\Wine\\AppDefaults\\$exe\\DllOverrides"
  for dll in d3d11 d3d10core; do
    "$RGM_WINE_BIN/wine" reg add "$key" /v "$dll" /t REG_SZ /d native,builtin /f >/dev/null
  done
  echo "DXVK enabled for $exe"
done

# Unity saves each game's screen size under HKCU\Software\<company>\<product> (the two
# lines of <Game>_Data/app.info). A monitor unplugged while Wine ran used to leave Wine
# reporting a 0x0 display (see display_fix.c); Driving Range then saved 1x1 and
# crashed at every start ("RenderTextureDesc width must be greater than zero").
# Reset a saved size that small so the game uses the display's native size.
# `|| find`, not `&& find`: this is the script's last command, and a fresh install
# has no games/ folder yet (the app creates it on the first game download).
[ ! -d "$GAMES" ] || find "$GAMES" -mindepth 4 -maxdepth 4 -path '*_Data/app.info' | while IFS= read -r info; do
  key="HKCU\\Software\\$(sed -n 1p "$info" | tr -d '\r')\\$(sed -n 2p "$info" | tr -d '\r')"
  w="$("$RGM_WINE_BIN/wine" reg query "$key" /v "Screenmanager Resolution Width_h182942802" 2>/dev/null |
    awk '/REG_DWORD/ {print $NF}' | tr -d '\r')" || true
  [ -n "$w" ] && [ $((w)) -lt 320 ] || continue
  for v in "Screenmanager Resolution Width_h182942802" "Screenmanager Resolution Height_h2627697771"; do
    "$RGM_WINE_BIN/wine" reg delete "$key" /v "$v" /f >/dev/null 2>&1 || true
  done
  "$RGM_WINE_BIN/wine" reg add "$key" /v "Screenmanager Resolution Use Native_h1405027254" /t REG_DWORD /d 1 /f >/dev/null
  echo "reset the saved $((w))-pixel-wide screen size of $key"
done
