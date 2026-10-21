#!/usr/bin/env bash
# Run the USB link (usb-link.sh + TetherKit) as a root LaunchDaemon, so it's always
# up and play.sh never asks for a password. Usage:
#   sudo scripts/60-install-usb-daemon.sh             # install / update
#   sudo scripts/60-install-usb-daemon.sh --uninstall
# Root runs root-owned copies under /usr/local/libexec, never files in your home
# folder (anything your account can edit must not run as root at boot).
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }
. "$(dirname "$0")/env.sh"

LABEL=local.rapsodo-golf-mac.usb-link
PLIST=/Library/LaunchDaemons/$LABEL.plist
DEST=/usr/local/libexec/rapsodo-golf-mac
LOG=/Library/Logs/RapsodoGolf-usblink.log

launchctl bootout "system/$LABEL" 2>/dev/null || true
# Stop a USB link play.sh started by hand; two TetherKits can't share the monitor.
if pkill -f "$RGM_REPO/scripts/usb-link.sh"; then sleep 2; fi
if [ "${1:-}" = "--uninstall" ]; then
  rm -f "$PLIST"
  rm -rf "$DEST"
  echo "Removed $LABEL"
  exit 0
fi

src="$RGM_HOME/tetherkit-cli"
[ -x "$src" ] || { echo "missing $src: run scripts/build-tetherkit.sh first" >&2; exit 1; }
install -d -o root -g wheel -m 755 "$DEST"
install -o root -g wheel -m 755 "$(dirname "$0")/usb-link.sh" "$DEST/usb-link.sh"
install -o root -g wheel -m 644 "$(dirname "$0")/env.sh" "$DEST/env.sh"
install -o root -g wheel -m 755 "$src" "$DEST/tetherkit-cli"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>
    <string>/bin/bash</string><string>$DEST/usb-link.sh</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>RGM_HOME</key><string>$DEST</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
EOF
chown root:wheel "$PLIST"
chmod 644 "$PLIST"
plutil -lint "$PLIST" >/dev/null
launchctl bootstrap system "$PLIST"
echo "Installed $LABEL (log: $LOG)"
