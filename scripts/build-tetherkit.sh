#!/usr/bin/env bash
# Build the TetherKit CLI (userspace RNDIS driver, MIT) into $RGM_HOME/tetherkit-cli.
# https://github.com/XiaoMiku01/TetherKit — needs: brew install libusb cmake
set -euo pipefail
. "$(dirname "$0")/env.sh"

: "${TETHERKIT_REF:=v0.1.5}"
src="$RGM_BUILD/TetherKit"
mkdir -p "$RGM_BUILD"
[ -d "$src" ] || git clone --depth 1 --branch "$TETHERKIT_REF" https://github.com/XiaoMiku01/TetherKit.git "$src"
cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
cmake --build "$src/build" -j "$(sysctl -n hw.ncpu)" --target tetherkit >/dev/null
cp "$src/build/bin/tetherkit-cli" "$RGM_HOME/tetherkit-cli"
echo "Built $RGM_HOME/tetherkit-cli"
