#!/bin/bash
# Keeps the MLM2PRO's USB-C RNDIS link up on macOS (TetherKit + DHCP).
# - restarts TetherKit whenever the monitor re-enumerates (it resets USB on
#   connect attempts and firmware updates);
# - re-applies DHCP whenever macOS drops the temporary `ipconfig set` service.
# Run with: sudo scripts/usb-link.sh   (Ctrl-C to stop)
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }
. "$(dirname "$0")/env.sh"
TK="$RGM_HOME/tetherkit-cli"
[ -x "$TK" ] || { echo "missing $TK — run scripts/build-tetherkit.sh first"; exit 1; }
trap 'kill $PID 2>/dev/null; exit 0' INT TERM
while true; do
  until "$TK" --list 2>&1 | grep -q "$RGM_USB_VID:$RGM_USB_PID"; do
    echo "$(date +%T) waiting for monitor on USB..."; sleep 2
  done
  "$TK" --vid "$RGM_USB_VID" --pid "$RGM_USB_PID" &
  PID=$!
  for _ in $(seq 1 30); do ifconfig feth0 >/dev/null 2>&1 && break; sleep 1; done
  # Watchdog: while TetherKit runs, keep feth0 up with a 192.168.36.x lease.
  while kill -0 $PID 2>/dev/null; do
    if ! ifconfig feth0 2>/dev/null | grep -q "inet 192\.168\.36\."; then
      ifconfig feth0 up 2>/dev/null
      ipconfig set feth0 DHCP && echo "$(date +%T) feth0 DHCP (re)requested"
      sleep 15
    fi
    sleep 5
  done
  echo "$(date +%T) link dropped; restarting in 3s"; sleep 3
done
