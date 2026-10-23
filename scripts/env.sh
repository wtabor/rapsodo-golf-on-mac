# shellcheck shell=bash
# Shared paths for rapsodo-golf-on-mac scripts. Source this file; don't run it.
# Override any of these in the environment before sourcing, or put personal
# settings in scripts/env.local.sh (gitignored; see env.local.sh.example).
_rgm_local="$(dirname "${BASH_SOURCE[0]}")/env.local.sh"
# shellcheck source=/dev/null
[ -f "$_rgm_local" ] && . "$_rgm_local"
unset _rgm_local

# Under sudo (usb-link.sh), resolve paths against the invoking user's home.
if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then
  RGM_USER_HOME="$(dscl . -read "/Users/$SUDO_USER" NFSHomeDirectory | awk '{print $2}')"
else
  RGM_USER_HOME="$HOME"
fi
: "${RGM_HOME:=$RGM_USER_HOME/Library/Application Support/RapsodoGolf-Wine11}"
: "${RGM_WINE_VERSION:=11.16}"
: "${RGM_WINE_URL:=https://github.com/Gcenx/macOS_Wine_builds/releases/download/${RGM_WINE_VERSION}/wine-staging-${RGM_WINE_VERSION}-osx64.tar.xz}"
: "${RGM_APP_BUNDLE:=/Applications/Rapsodo Golf on Mac.app}"
: "${RGM_LOG:=$RGM_USER_HOME/Library/Logs/RapsodoGolf-Wine.log}"
# The monitor's USB RNDIS identity (MLM2PRO, Rockchip gadget).
: "${RGM_USB_VID:=2207}"
: "${RGM_USB_PID:=0019}"
# Position the games get instead of Windows location services (geolocation_stub.c).
# Decimal degrees and meters above sea level. The games need *some* position (with
# none they show "Network access required"); 0/0/0 is a placeholder. Set yours in
# scripts/env.local.sh.
: "${RGM_GEO_LAT:=0}"
: "${RGM_GEO_LON:=0}"
: "${RGM_GEO_ALT:=0}"

RGM_WINE_BIN="$RGM_HOME/Wine Staging.app/Contents/Resources/wine/bin"
RGM_PREFIX="$RGM_HOME/prefix"
RGM_APP_DIR="$RGM_PREFIX/drive_c/Program Files/RapsodoGolf"
RGM_LIBS_DIR="$RGM_APP_DIR/resources/libs/windows"
RGM_BUILD="$RGM_HOME/build"
RGM_REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export RGM_HOME RGM_WINE_BIN RGM_PREFIX RGM_APP_DIR RGM_LIBS_DIR RGM_BUILD RGM_REPO
export RGM_GEO_LAT RGM_GEO_LON RGM_GEO_ALT
