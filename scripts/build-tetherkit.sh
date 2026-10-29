#!/usr/bin/env bash
# Build the TetherKit CLI (userspace RNDIS driver, MIT) into $RGM_HOME/tetherkit-cli.
# https://github.com/XiaoMiku01/TetherKit — needs: brew install libusb cmake
set -euo pipefail
. "$(dirname "$0")/env.sh"

: "${TETHERKIT_REF:=v0.1.5}"
src="$RGM_BUILD/TetherKit"
mkdir -p "$RGM_BUILD"
[ -d "$src" ] || git clone --depth 1 --branch "$TETHERKIT_REF" https://github.com/XiaoMiku01/TetherKit.git "$src"

# Its RX thread spins and sched_yield()s while idle, which on macOS keeps a core at
# ~100% with no traffic; sleep 500 us instead (patches/tetherkit-rx-idle-sleep.patch).
patch_file="$RGM_REPO/patches/tetherkit-rx-idle-sleep.patch"
if git -C "$src" apply --check "$patch_file" 2>/dev/null; then
  git -C "$src" apply "$patch_file"
elif ! git -C "$src" apply --reverse --check "$patch_file" 2>/dev/null; then
  echo "tetherkit-rx-idle-sleep.patch does not apply to TetherKit $TETHERKIT_REF" >&2
  exit 1
fi

cmake -S "$src" -B "$src/build" -DCMAKE_BUILD_TYPE=RelWithDebInfo >/dev/null
cmake --build "$src/build" -j "$(sysctl -n hw.ncpu)" --target tetherkit >/dev/null
# Replace by rename, never cp over it: macOS caches a Mach-O's code signature per
# vnode, so rewriting the file in place can get the running or next copy killed.
cp "$src/build/bin/tetherkit-cli" "$RGM_HOME/tetherkit-cli.new"
mv -f "$RGM_HOME/tetherkit-cli.new" "$RGM_HOME/tetherkit-cli"
echo "Built $RGM_HOME/tetherkit-cli"
# The optional LaunchDaemon (60-install-usb-daemon.sh) runs its own root-owned
# copies of TetherKit, usb-link.sh and env.sh; updates can't refresh them without sudo.
daemon_dir=/usr/local/libexec/rapsodo-golf-on-mac
if [ -e "$daemon_dir/tetherkit-cli" ] && {
  ! cmp -s "$daemon_dir/tetherkit-cli" "$RGM_HOME/tetherkit-cli" ||
    ! cmp -s "$daemon_dir/usb-link.sh" "$RGM_REPO/scripts/usb-link.sh" ||
    ! cmp -s "$daemon_dir/env.sh" "$RGM_REPO/scripts/env.sh"
}; then
  echo "note: the always-on USB link still runs an older version. Update it with:" >&2
  echo "  sudo \"$RGM_REPO/scripts/60-install-usb-daemon.sh\"" >&2
fi
