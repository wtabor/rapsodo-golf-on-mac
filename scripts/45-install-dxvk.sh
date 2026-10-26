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
