# 10/28/2026 — "Device not connected" with the monitor still plugged in

## Symptom
Mid-session in Studios (alignment dialog open), the game showed **DEVICE NOT
CONNECTED** and alignment showed "Device disconnected". The owner hadn't unplugged
or turned off the monitor.

## What the logs showed
`~/Library/Logs/RapsodoGolf-usblink.log` (TetherKit started 16:37:45):

```
WARN  16:39:30.125 [usb-event ] data_channel.cc:253  bulk IN transfer failed: status=1; retrying
WARN  16:39:30.125 [usb-event ] data_channel.cc:269  failed to resubmit a bulk IN transfer: LIBUSB_ERROR_PIPE
```

From then on every 5 s stats line read `RX 0 pps` (TX kept going for a few seconds,
then 0 too). `feth0` kept its `192.168.36.x` lease, but `ping 192.168.36.1` got no
answer. There was no USB re-enumeration and TetherKit didn't exit.

## Cause
`status=1` is `LIBUSB_TRANSFER_ERROR` on the bulk IN (device → Mac) endpoint.
TetherKit's completion handler (`src/usb/data_channel.cc`) then resubmits the
transfer. Here the resubmit failed with `LIBUSB_ERROR_PIPE` (endpoint halted), and
the handler just drops that transfer from flight. Nothing ever calls
`libusb_clear_halt` or resubmits it, so the receive path stays dead. The process
keeps running, and `usb-link.sh` only restarted TetherKit when it exited
(re-enumeration, `NO_DEVICE`), so the link stayed down until a manual restart.

This differs from the 10/19 run 2 drop (`notes/2026-10-19-monitor-drops-during-play.md`):
there the same two lines came right before the monitor *left* USB (`NO_DEVICE`),
so TetherKit exited and usb-link.sh recovered on its own.

Not known: why the transfer failed in the first place (status=1 gives no detail).
Can't rule out a link with the 10/26 RX idle-sleep patch
(`patches/tetherkit-rx-idle-sleep.patch`), but the stats line showed queue depth 0,
no backpressure and ~70 pps at the time, and USB completions run on the libusb event
thread rather than the RX thread that patch changes.

## Recovery used
`sudo pkill -f '/RapsodoGolf-Wine11/tetherkit-cli'` at 16:42:51. usb-link.sh
restarted it 3 s later, the monitor answered ping ~12 s after the kill, and the
app reconnected and authenticated (`APIAuthenticate` status 0) at 16:43:11 with
no clicks.

## Fix: `scripts/usb-link.sh` watchdog
TetherKit's output is also copied (`tee`) to a temp file. On each 5 s check, if it
contains `failed to resubmit a bulk IN transfer` **and** `ping -c 2 -t 3 192.168.36.1`
fails, usb-link.sh logs `USB receive stalled; restarting TetherKit`, sends SIGTERM
(SIGKILL after 15 s, then `ifconfig feth1/feth0 destroy`; changed 10/29/2026, see below),
and its loop starts TetherKit again. Requiring the ping
failure keeps one lost transfer that didn't stop the link from forcing a reconnect.

The script is swapped in by rename, so a running usb-link.sh keeps the old version.
The new one loads the next time the USB link starts (it isn't running, or it was
restarted). The always-on LaunchDaemon copy updates only when
`60-install-usb-daemon.sh` is re-run.

### Tests (stub TetherKit, not the real monitor)
The real script ran unmodified as a normal user, with `id`, `ifconfig`, `ipconfig`
and `ping` replaced by stubs on `PATH` and `RGM_HOME` pointing at a stub
`tetherkit-cli` that prints the PIPE line after 2 s. 22 s per case:

| Case | Stall line | Ping | Result |
|---|---|---|---|
| A | yes | fails | restarted at ~5 s and again at ~14 s (3 starts) ✅ |
| B | yes | answers | no restart (1 start) ✅ |
| C | no | fails | no restart (1 start) ✅ |

On SIGTERM the trap killed the stub and removed the temp file (after the current
`sleep 5`, as before this change). `shellcheck -x -e SC1091` is clean.

With the real TetherKit (17:03:50): the old usb-link.sh was stopped and the new one
started (`sudo -b`, appending to the usblink log). TetherKit's output still reaches
the log through `tee`, `feth0` got its lease, the monitor answered ping, and the
app reconnected and authenticated by itself at 17:04:11.

Not yet tested: a real stall (no way to trigger one on demand).

## 10/29/2026: longer stop, leftover interfaces
A review of TetherKit v0.1.5's teardown (`runtime.cc`, `data_channel.cc`) found that
its clean exit can take ~5 s (it drains cancelled USB transfers, `kDrainTimeout`), and
only a clean exit destroys `feth0`/`feth1`. The old 5 s SIGKILL could land first; a
killed TetherKit leaves the pair, the next one gets `feth2`, and usb-link.sh keeps
watching `feth0`. The watchdog now waits up to 15 s, then SIGKILLs and destroys the
pair. Sandbox test (fake TetherKit that ignores SIGTERM): SIGKILL at ~15 s, both
destroys after it, next run back on `feth0`/`feth1`. Still not tested with a real stall.

