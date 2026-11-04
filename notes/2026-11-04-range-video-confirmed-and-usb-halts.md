# Range video confirmed; USB bulk IN halts during play (11/04/2026)

## Swing video works (Fix 10 + 11)
First real shot on the fixes: a 7 iron in Driving Range, 11:50. The Shot tab played the
swing video with the clock moving (screenshot from the owner: 00:03 / 00:06). Player.log:
2 video loads, 0 `WindowsVideoMedia` errors, 0 shared-handle errors, 0 `First video frame
not zero`. The only video line left is the harmless `Color primaries 0 is unknown`.
The owner confirmed both the Shot and Impact videos play.

## The link kept dropping
All four tier 4 runs that morning (~09:50) streamed both cameras with no link trouble.
After the monitor was powered back on at about 11:33 the link would not stay up:
`bulk IN transfer failed: status=1`, then `failed to resubmit a bulk IN transfer:
LIBUSB_ERROR_PIPE`, then usb-link.sh's watchdog restarted TetherKit, about every 25 s.
This is the first real occurrence of the stall in `2026-10-28-tetherkit-bulk-in-stall.md`.

- Timing: 124 ms after the app's `StartCameraStream` (11:39:32) and 330 ms after the game's
  `StartSession` (11:40:43). But with the patch below logging each halt, they ran at 1-3 a
  second all through a session, so the session start isn't the only trigger.
- macOS's kernel log showed no USB errors or disconnects in that window.
- Why TetherKit didn't recover: it clears a halt on `LIBUSB_TRANSFER_STALL`, but here the
  transfer fails with status 1 (`LIBUSB_TRANSFER_ERROR`), so that case never runs, and the
  resubmit fails with `PIPE`.
- A clean restart (app, link, TetherKit) did not cure it; the stall returned within 27 s.
- Separate failure at 11:45:51: `LIBUSB_ERROR_NOT_FOUND` on every resubmit as the Range
  started, right after the app stopped its device manager. The interface went away, so
  clearing a halt can't help there.

## Patch: patches/tetherkit-clear-halt.patch (branch tetherkit-clear-halt, not committed)
- First version: on `PIPE`, ClearHalt and resubmit once; transfers aborted by a ClearHalt
  (`CANCELLED`) go back in flight unless shutting down. Result: 242 halts cleared, the link
  carried a session and the first shot, no restart for 4 min 40 s. Then it died: 14
  resubmits failed for good between 11:50:23 and 11:50:44, each one a receive transfer lost,
  until none were left (RX 8 pps -> 1 pps, game `Connected -> Lost` at 11:50:43).
- Second version: keeps clearing and resubmitting for up to 200 ms. Built 11:51:56.
  **Not tested:** at 11:51:55 and 11:52:29 TetherKit couldn't start at all (`RNDIS
  initialization failed: SEND_ENCAPSULATED_COMMAND failed`), and around 11:53 the monitor
  left USB. Unknown whether that was the monitor failing or the owner turning it off.

## Owner's report: iPhone Bluetooth (after 12:00)
The owner turned Bluetooth off on the iPhone and reports the drops stopped. Not confirmed by
the logs yet: at 12:10 this Mac had no session after 11:53 (no monitor on USB, no TetherKit,
Player.log ends 11:51, usb-link.sh still `waiting for monitor on USB`). To confirm: iPhone
Bluetooth off, monitor on USB, Range open for over 5 minutes. The retry build logs every halt,
so 0 `clearing the halt` lines would settle it. Then Bluetooth back on, to see them return.

## Open
- What makes the pipe halt. Status 1 rather than STALL hints at transfer errors on the wire
  rather than the monitor deliberately halting, but that's a guess. Things to rule out:
  a different or longer USB-C cable or a hub since the morning; the Rapsodo phone app
  connected over Bluetooth (the owner's idea; the Mac has no BLE link to the monitor,
  "There is no BLE connection to the device", but a phone can't be seen from here).
- usb-link.sh's watchdog can loop on a monitor that needs a replug.
- `tests/` has no check for this: the halts only showed with the monitor, under load.
