# 11/03–11/04/2026 — First sessions on macOS 15 (Sequoia)

A second user's setup, not the owner's: macOS 15.7.2 (24G325), M4, MLM2PRO firmware
4.1.9, Rapsodo Golf 1.0.0, Driving Range v1.15.1. The README only lists macOS 26/27.
The monitor was plugged straight into the Mac (own USB bus, no hub); a TV on a USB-C
Digital AV adapter on another bus.

## Install
`install.sh` steps 00–50 + `build-tetherkit.sh` all exit 0 on macOS 15 (Rosetta was
already installed). 46 (GStreamer) not run yet: it needs the user's password.

## Range stuck loading on the first start (11/03)
Range downloaded and started at 15:44; 40 patched its `deviceManagerServer.dll` and
`UnityPlayer.dll` at 15:44:49, the game's log starts 15:44:58. Player.log then looped on
`Server not ready yet (Internal), retrying health check...` every 30 s with the app
connected to the monitor. Probably the game started before its DLLs were patched (the
README's "downloaded while the app is open" case); a restart got past it.

## Stale sudo wrapper blocks the USB link (11/04) — fixed in play.sh
Twice the `sudo .../usb-link.sh` process was left with no usb-link.sh or TetherKit under
it (first after the previous day's session, then after a monitor power cycle). play.sh's
`pgrep -f usb-link.sh` matched the wrapper, so it never started a link: no password
prompt, "Monitor not connected yet", `V3ScanTCPDevices: 0 device(s)`, no `feth0`. The
monitor was on USB (`2207:0019`). Plain `kill` didn't clear it (sudo forwards SIGTERM to
its missing child); `kill -9` did. Why the script under it exited isn't known.

## Range keeps dropping the monitor (11/04)
After a fresh link (17:47:52) the Range armed and took shots, then dropped three times in
about 4 minutes:

| Drop (`ZMQConnectionDropped`) | Before it | `feth0 DHCP (re)requested` |
|---|---|---|
| 17:53:46 | shot at 17:53:32 (carry ~110 yd, club data received) | 17:53:39 |
| 17:55:44 | re-armed 17:55:07, no shot | 17:55:44 |
| 17:57:13 | re-armed 17:57:06, no shot | 17:57:09 |

Each time: `DeviceDisconnected` ~18 s later, `heartbeat_timeout` 30 s after that, then
the game reconnects and re-arms on its own (~80 s). TetherKit kept running with no link
state change or bulk-IN errors; the monitor answered ping on `192.168.36.1` between drops.
Each drop came within ~7 s of usb-link.sh's DHCP re-request, i.e. `feth0` had lost its
`192.168.36.x` address (its lease is 48 h, so not expiry). Whether macOS dropping the
temporary `ipconfig set` service causes the drop, or the monitor's reset causes macOS to
drop it, isn't known: `log show` had nothing for configd/IPConfiguration at those times.
Battery 87%, CPU 44 °C. Same symptom as `2026-10-19-monitor-drops-during-play.md` run 1.

Next: log `ifconfig feth0` and `scutil` network state every second around a drop, to see
which comes first.

## Displays
The app and the games stay on the macOS main display under Wine. Dragging the window
to the TV snaps it back (app) or hides it (fullscreen Range); `rgm-display-fix` saw both
displays. Making the TV the main display before launching is the workaround (not yet
confirmed by the user).
