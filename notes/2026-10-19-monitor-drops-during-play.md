# 10/19/2026 — Monitor drops out during Driving Range

## Symptom
In Driving Range the game connects, authenticates, starts a session, arms the
monitor and streams alignment data (`APIEvent::HittingAreaData`, `evtID 9053`,
~3.6/s). Then the stream stops, the game logs
`Connection corrupted (cause: heartbeat_timeout)`, and it loops on "Connecting…".

This also confirms that the game-side patches (`libzmq.dll`,
`deviceManagerServer.dll`, see `40-apply-patches.sh`) work: connect, auth, session
start and arm all succeed under Wine.

## Two failures, same session setup
| Run | Stream start | Stream stop | USB at the stop | Afterwards |
|---|---|---|---|---|
| 1 (owner) | 17:31:49 | 17:33:00 (~70 s) | **stayed up**, no TetherKit errors | monitor accepts TCP on `:32501` but never answers `GetCommunicationKey`, even 10 min later and from the app; only a power cycle cleared it |
| 2 (scripted repro, launched via DevTools `electronAPI` / UI click) | 17:47:33 | 17:57:38 (~10 min) | **monitor left USB**: `bulk IN transfer failed` → `LIBUSB_ERROR_PIPE` → `NO_DEVICE`; not back on USB 90 s later | — |

In both runs the game sent nothing between `StartSession` and the stop; the
monitor stopped on its own. No socket-level ZMQ disconnect event in run 1.

Earlier the same day the monitor also dropped off USB at 17:12:36, 17:19:51,
17:29:56 and 17:30:26 (app only, no game running).

## 10/20/2026 run 3: monitor plugged straight into the Mac
- USB tree: `rk3xxx` alone on its own `AppleT8132USBXHCI` controller (no hub).
- `play.sh` (new self-heal + quiet logs) → app connected + authenticated 15:02:15.
- Driving Range: location prompt gone; session started and armed 15:06:19.
- Owner quit at 15:06:25 (clean "Shutting down the miniapp"); no USB drop, no
  heartbeat timeout. Only ~5 min and no shots, so not yet evidence that the hub was
  the cause; needs a 15+ min session with shots.

## Ruled out / checked
- **Wine/patches:** game ↔ monitor traffic is normal right up to the stop.
- **Heat:** CPU/NPU 58/54 °C at failure 1, 67/63 °C at failure 2. Far below
  typical throttle points, and no consistent threshold.
- **Message rate:** steady ~217 msgs/min the whole of run 2, no slowdown before the
  stop.
- **Battery:** `IsCharging: 0` throughout; 98% → 88% over ~25 min. The monitor is
  **not charging** while connected over USB-C.
- macOS unified log (`log show`) returned nothing from this session, so it's
  unknown whether the host or the device ended the USB connection.

## Open questions (owner)
- Is the MLM2PRO plugged straight into the Mac, or through a hub/dock? The Mac's
  USB tree shows a `USB3.2 Hub` / `USB2.1 Hub` (idVendor 3034 = 0x0BDA, Realtek).
- After a drop, is the monitor still powered on (lights), or did it shut off/reboot?

## Tools (`scripts/debug/`)
- `cdp-eval.mjs` / `cdp-shot.mjs`: evaluate JS in / screenshot the app's renderer
  over `--remote-debugging-port=9222` (Node 26 built-in WebSocket).
- `watch.sh`: tails `Player.log` + `rdc.log`, prints state changes and gaps >5 s.
- App launch path: `electronAPI.runGame(dir, exe, args)` → main-process
  `games:run-game`, which stops the app's download manager and device server
  before starting the game.

## Next test (needs the monitor)
1. Plug the MLM2PRO straight into a Mac USB-C port (no hub/dock) and repeat run 2:
   start the app with `--remote-debugging-port=9222`, open Practice → Driving Range
   (or `scripts/debug/cdp-eval.mjs`), then `scripts/debug/watch.sh 900`. If it survives,
   suspect the hub; if not, suspect the monitor's firmware or the cable.
2. Note whether the monitor is still on when it drops (lights) or rebooted.
3. Try a different USB-C cable once.
