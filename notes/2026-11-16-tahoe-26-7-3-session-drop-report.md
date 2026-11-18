# 11/16/2026: user report, session fails after shots on macOS 26.7.3

Source: two Reddit replies on the r/Rapsodo "Rapsodo Studios for Mac" post (alert
emails 11/13 and 11/15/2026, previews cut off). Symptom after "registers shots, but
imme..." is unknown. Full triage brief: the owner's Downloads copy of
`tahoe-26.7.3-bug-report.md` (not in the repo; it names the reporter).

## What changed for users between 11/04 and 11/13 (checked in git 11/16)

| Commit | Date | Touches the session / USB path? |
|---|---|---|
| 1b2399b TetherKit: clear a halted bulk IN pipe | 11/04/2026 | **Yes.** `patches/tetherkit-clear-halt.patch`, applied by `build-tetherkit.sh`, which `install.sh` re-runs after every auto-update. Its 200 ms retry was never tested with a monitor. |
| f83312f Fix 13 display topology | 11/09/2026 | No. Patches only `NtUserQueryDisplayConfig` in `win32u.so` (2 sites, sha256-pinned). Runs when a game queries the display config, not per shot. |
| db8b29d Rosetta notes | 11/12/2026 | No (notes only). |

`update.sh`, `play.sh`, `usb-link.sh`, `env.sh`: unchanged since 10/29/2026.

Correction to the triage brief: it says the clear-halt patch "is not committed" on a
branch `tetherkit-clear-halt`. Wrong: it is on main since 11/04 (1b2399b) and no such
branch exists. Any user who launched after 11/04 runs it (a running TetherKit keeps
the old binary until usb-link.sh restarts it; the LaunchDaemon copy only updates when
`60-install-usb-daemon.sh` is re-run).

## Leading hypothesis (unverified, no logs yet)

Clear-halt patch misbehaves under a real shot burst (the first version "lost its
transfers to a burst"; the 200 ms version is the untested fix for that). A shot is
the biggest burst in a session (shot + impact video). Fits "connects, registers
shots, then fails right after". macOS 26.7.3 may be a coincidence: Apple's notes
mention no USB change (https://support.apple.com/en-us/149719).

Second: wineserver segfault (`notes/2026-10-26-wineserver-crash-on-monitor-power-cycle.md`).

## What decides it

- `RapsodoGolf-usblink.log` around the failure: `bulk IN transfer failed`,
  `USB receive stalled; restarting TetherKit`, or clear-halt retries giving up.
- `Player.log`: `heartbeat_timeout`, Connected → Lost.
- `wineserver-*.ips` in DiagnosticReports → crash path instead.
- Which repo sha they run (`.rgm-version` in the install folder).

## Can't test here

This Mac is on 27.0.1 (build 26A434); macOS can't be downgraded to 26.7.3 in place.
A tier-4 run with real shots on 27.0.1 still tests the clear-halt patch, which is the
more likely cause.

## Draft reply to the reporter (not posted)

> Thanks, that helps. Your reply got cut off after "registers shots, but imme…", so
> what happens right after the shot: "Device not connected", stuck on
> "Connecting…", or does everything freeze? To pin it down, could you send these
> (zip them; they have no passwords, but skim for anything you'd rather not share):
> - ~/Library/Logs/RapsodoGolf-usblink.log (or /Library/Logs/RapsodoGolf-usblink.log
>   if you installed the always-on USB service)
> - ~/Library/Logs/RapsodoGolf-Wine.log and any RapsodoGolf-Wine-crashed.log
> - Any wineserver report in Console → Crash Reports
> - The Player.log of the game you were in:
>   ~/Library/Application Support/RapsodoGolf-Wine11/prefix/drive_c/users/<you>/AppData/LocalLow/Rapsodo/<game>/Player.log
> - Which game (Range, Studios, a course) and whether the monitor is plugged straight
>   into the Mac or through a hub.

## 12:29: Rapsodo Golf 1.1.0 self-updated mid-test

- The app updated itself 1.0.0 → 1.1.0 (electron-updater, `--updated`) and relaunched
  outside play.sh. `rapsodo-compat-check.py` on the cached installer: all fixes apply
  except Fix 12's "no maximize" edit (window can't shrink without cropping; warn-only).
  Tier 1 `patch_app_window.py` round trip fails for the same reason.
- 1.1.0 wants new game builds (Target Range v1.16.0). The app deletes the old version
  folder and downloads the new one, so "lost downloads" after an app update is
  Rapsodo moving to new game versions, not something this repo removes.
- **Games 1.16.0 ship Authenticode-signed DLLs.** `libzmq.dll` and
  `GeolocationPlugin.dll` differ from the known builds only by the PE checksum, the
  security directory entry and the appended signature (8-byte zero pad + table). 40
  hashed whole files, so it skipped both: stock libzmq (Fix 1 deadlock) and the
  location prompt (Fix 4) came back in Target Range 1.16.0.
  Fix on branch `game-dll-signatures`: `scripts/pe_unsigned_sha256.py` hashes the
  unsigned form; 40 compares that. Verified: old and signed copies hash alike for both
  DLLs; 40 now patches Target Range 1.16.0. Not yet run in a game.
- Possibly related to the 26.7.3 report: a user whose games updated to 1.16.0 would
  run the stock libzmq under Wine.

## 12:39–12:52: shot test attempt (no result)

Driving Range 1.16.0 downloaded and was patched by the branch's 40 (libzmq + geo) at
12:39. Over the next 13 min no game process ran (DrivingRange Player.log last written
11/09/2026), the USB link stayed up with idle traffic (4–5 pps, 0 drops, no halts or
TetherKit restarts), and the app log shows only battery events. So no shot reached
the Mac; the clear-halt patch wasn't exercised.

## 12:55–12:58: Driving Range 1.16.0, retry

- Game started, connected, StartSession OK, `Entering state : Armed` 12:55:28 and the
  monitor's `DeviceArmed` event, then `DeviceDisarmed` 0.3 s later. From 12:56:27 every
  re-arm fails: `sendCommandWait ERROR: Timeout waiting for cmd APICommand::ArmDevice`
  (gRPC 13999), every 10 s. Game shows NOT READY. `StartCameraStream` also throws.
- Meanwhile: monitor pings, battery events keep arriving in the app log, USB link
  clean (no halts, no TetherKit restart, 0 drops). So the link is up and the monitor
  ignores (or never gets) commands; not a USB stall.
- Screen sharing can't be stopped: the game logs `deactivating screen sharing,
  Setting default topology: Internal` → `SetDisplayConfig` (Wine stub, changes
  nothing) → Fix 13 still reports EXTEND, so the game stays in sharing mode. Screen 2
  is the MacBook's built-in display ("WINE MONITOR": no EDID name under Wine).
  Fix idea: have patched win32u remember the topology SetDisplayConfig asked for.

### 13:00: what the logs show

- The game's own SDK log (`…/LocalLow/Rapsodo/DrivingRange/log/rdc.log`): 5×
  `GolfZMQApiManager JSON Error` during connect/start (12:55:25–29), then every arm and
  camera start ends `Wrong number or event type received for Device Armed /
  StartCameraStream. Size: 0`: the command goes out, no result event comes back.
- The first arm worked (12:55:29.245 `DeviceArmed`). The game then disarmed itself
  0.3 s later (its transition queue went back to SessionStarted while its cloud
  session was still being set up, `DB Session setup finished` 12:56:23). Every arm
  after that got no reply.
- Same shape as the 10/26 Studios failure
  (`notes/2026-10-26-studios-arming-and-resources.md`): arm + disarm in quick
  succession, then the firmware silently drops Arm/Disarm while other traffic (battery
  events) keeps flowing. That time it cleared after the game exited and the monitor
  left USB.
- No firmware update on offer (`findAvailableVersions`: NOT_FOUND); monitor 4.1.19.
- Not known: whether the JSON errors are new with 1.16.0 (older games' rdc.log are
  overwritten each run).

## 11/18/2026 13:02: USB drop before any shot

- Launched 12:59 (play.sh on this branch; it cleared the frozen 11/16 session, whose
  log stopped 11/16 13:25:32 with "Connection dropped"; no wineserver .ips).
- Driving Range 1.16.0 up 13:01:56. At 13:02:06 bulk IN halts; clear-halt patch logged
  "clearing the halt and continuing" but every resubmit failed `LIBUSB_ERROR_PIPE`,
  then `LIBUSB_ERROR_NO_DEVICE` at 13:02:08: the monitor left USB. Watchdog restarted
  TetherKit 13:02:12; monitor still absent from USB at 13:03:24. Owner: no shot had
  been hit yet. So halts + drop happen without shot traffic too.
- Repeats: monitor back on USB 13:03:55, game `Connected to device` 13:04:23, halts +
  `NO_DEVICE` 13:04:28. Both drops come 5–9 s after the game's `Authenticating...`
  (13:01:57 → 13:02:06; 13:04:23 → 13:04:28): the monitor resets its USB during the
  game's authentication (CLAUDE.md: "resets USB on some connect attempts"). Straight
  USB-C to the Mac, no hub. On 11/16 the same game authenticated fine.

## 13:07–13:15: A/B without the clear-halt patch (not the cause)

- Swapped in TetherKit v0.1.5 + rx-idle-sleep only (clear-halt reversed). Monitor on,
  link up 13:13:17. App `ConnectDeviceTCP` → 2× `GolfZMQApiManager JSON Error`
  13:13:48 → 13:13:49 one bulk IN `PIPE` and the monitor itself sends
  `RNDIS_STATUS_MEDIA_DISCONNECT`; `GetCommunicationKeyResult Event wait Timeout`;
  monitor off USB, then powered off (owner: yellow = charging only).
- Same failure without clear-halt, and the device announces the disconnect: the
  monitor shuts down ~1 s into the app's connect handshake. Patched build restored.
- Today every connect (app or game) kills it; on 11/16 12:33 the same app/build
  connected and authenticated. Not yet tested: the monitor with the iPhone app.

## 11/18/2026: monitor fault confirmed

Owner connected the MLM2PRO to the Rapsodo iPhone app (no Mac involved): it shuts off
there too. So today's drops are the monitor itself, not Wine, TetherKit or this repo.
Next: Rapsodo support. Shot test (TetherKit clear-halt under real shots) still open.

## 11/18/2026 16:10: after a full recharge, the monitor stays up

Owner recharged the MLM2PRO; the iPhone app then worked. Mac retry (app 1.1.0, this
branch's TetherKit with clear-halt): monitor on USB 16:10:29 (one bulk IN STALL at
16:10:30, cleared), app `Connected to the device` 16:11:26, `APIAuthenticate` sent,
monitor still pinging and traffic steady 20+ s later. Earlier today it shut off ~1 s
into this handshake. So today's drops were most likely a low battery (the LED read
"charged"), not a monitor fault. Shot test still open.

## 11/18/2026 16:20–16:24: Driving Range 1.16.0 with real shots

Same launch (branch `game-dll-signatures`, so the signed 1.16.0 libzmq/geo DLLs are
patched; TetherKit with clear-halt).

- Connected 16:20:24, armed 16:20:26 and again 16:21:25 (DB session up), both camera
  streams started, re-armed after each shot. 0 `Timeout waiting for cmd` in rdc.log.
  The 11/16 ArmDevice timeouts didn't recur: most likely the same low battery.
- Shot 16:23:25: ShotTrigger → ShotParameters 2.7 s later (PW, 53 yd carry), ball flight,
  Shot and Impact videos play (owner's screenshots). Link stayed up, no TetherKit restart.
  One bulk IN STALL at link start (16:10:30) was cleared by the clear-halt patch.
- Extended Screens: the game's own state toggles ("Sharing not active, saving mode:
  Extend" 16:24:16), but the second-screen window stays on the BenQ. On Windows
  `SetDisplayConfig(INTERNAL)` switches the external display off; Wine's is a stub, so
  nothing removes the display. Fixing it means implementing SetDisplayConfig against
  macOS (mirror / unmirror via CoreGraphics) in user32 + a unix call: not done.
  Workaround: macOS mirroring (System Settings → Displays → Mirror) or unplugging,
  which Wine sees as one display (INTERNAL).

## Fix 12 on app 1.1.0

1.1.0 has a third `Ce.maximize(), Ce.show()` site (function `iI`). `patch_app_window.py`
now edits every site (at least 2 in total). Round trip on a copy of the installed 1.1.0
app.asar: 3 sites patched, revert byte-identical; tier 1 34/34. Applies at the next
play.sh launch (40); not yet seen on screen.
