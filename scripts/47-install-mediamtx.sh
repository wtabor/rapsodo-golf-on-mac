#!/usr/bin/env bash
# MediaMTX for the alignment camera view. On first use the app downloads MediaMTX
# and unzips it with PowerShell, which Wine only stubs (it exits 0 and extracts
# nothing), so alignment always fails with "Alignment Couldn't Start". This puts
# the same release where the app looks for it (the app only checks that the file
# exists) and fixes Go's UDP setup in it, as for deviceManagerServer.exe: unpatched,
# MediaMTX exits on its first UDP listener ("listen udp :8000: wsaioctl: winapi
# error #10045"). Idempotent; re-run any time.
set -euo pipefail
. "$(dirname "$0")/env.sh"

MTX_TAG=v1.17.0  # the version the app's main.js downloads
MTX_ZIP=mediamtx_${MTX_TAG}_windows_amd64.zip
MTX_URL=https://github.com/bluenviron/mediamtx/releases/download/$MTX_TAG/$MTX_ZIP
MTX_SHA256=99b365bbbc1661fd2d2a1488fe70689998b9543971a7e064160131443fcae312
# app.getPath("userData")\mediamtx; userData is %APPDATA%\super-app-clm.
MTX_DIR="$RGM_PREFIX/drive_c/users/$(id -un)/AppData/Roaming/super-app-clm/mediamtx"

if [ ! -f "$MTX_DIR/mediamtx.exe" ]; then
  tmp="$RGM_BUILD/mediamtx"
  rm -rf "$tmp"
  mkdir -p "$tmp" "$MTX_DIR"
  curl -fL --progress-bar -o "$tmp/$MTX_ZIP" "$MTX_URL"
  echo "$MTX_SHA256  $tmp/$MTX_ZIP" | shasum -a 256 -c -
  /usr/bin/unzip -o -q "$tmp/$MTX_ZIP" mediamtx.exe LICENSE -d "$tmp"
  # Move into place only when complete: an interrupted unzip must not leave a
  # truncated mediamtx.exe that later runs would take as installed.
  mv "$tmp/LICENSE" "$MTX_DIR/LICENSE"
  mv "$tmp/mediamtx.exe" "$MTX_DIR/mediamtx.exe"
  rm -rf "$tmp"
  echo "MediaMTX $MTX_TAG installed: $MTX_DIR"
fi

python3 -I "$(dirname "$0")/patch_devicemanager.py" "$MTX_DIR/mediamtx.exe"
