# Alignment "couldn't start" and the red light in the Range (10/25/2026)

A user reinstalled this morning. The monitor connects (blue light), but alignment
says **"Alignment Couldn't Start — We ran into a problem while connecting to your
device cameras"** for both Shot Vision and Impact Vision; the light stays blue. If
they skip alignment and open the Range, the light turns red and the monitor doesn't
connect until they're back in the app. Their logs aren't available; everything
below was found and tested on the owner's Mac, without the monitor plugged in.

## 1. Alignment never starts: MediaMTX is missing, then can't open UDP

The app's own alignment screen (`MlmAlignment`, Electron, not a game) sets up in
this order; any failure shows the error card:

1. `electronAPI.startStreamServer()` (main process) starts **MediaMTX**, a local
   RTSP→WebRTC server.
2. `CommandService.setGolfSessionInfo` + `startSession` (device).
3. `startCameraStream(0)` (Shot Vision, 1536x1440) and `startCameraStream(1)`
   (Impact Vision, 480x640): the monitor returns an RTSP URL for each.
4. `stream:add-path`: the app runs `resources/ffmpeg-static/ffmpeg.exe` to
   re-encode each camera with libx264 and publish it into MediaMTX; the renderer
   plays `http://127.0.0.1:8889/<path>/whep` over WebRTC.

Step 1 fails every time under Wine, before any device command (so the light stays
blue and nothing is left running on the monitor):

- On first use the app downloads MediaMTX v1.17.0
  (`mediamtx_v1.17.0_windows_amd64.zip`, from
  [the GitHub release](https://github.com/bluenviron/mediamtx/releases/tag/v1.17.0))
  into `%APPDATA%\super-app-clm\mediamtx\` and unzips it with
  `powershell Expand-Archive`. **Wine's `powershell.exe` is a stub**: tested, it
  exits 0 and extracts nothing. The app deletes the zip, spawns a missing exe
  (ENOENT), polls the API for 10 s and throws "MediaMTX server failed to start".
  Retry downloads it again, with the same result.
- With the exe in place, MediaMTX (Go) still exits at once:
  `ERR listen udp :8000: wsaioctl: winapi error #10045`. Same cause as
  deviceManagerServer: Go calls `WSAIoctl(SIO_UDP_NETRESET)`, which Wine rejects.
  `patch_devicemanager.py` works unchanged on `mediamtx.exe` (exactly one
  `bb 0f 00 00 98`, in `net.(*netFD).init`).

**Fix:** `scripts/47-install-mediamtx.sh` downloads the same release, checks its
sha256 (`99b365bb…`, from the release's `checksums.sha256`), unzips it where the
app looks (the app only checks that `mediamtx.exe` exists, so it never downloads)
and patches it. play.sh and install.sh run it.

MediaMTX runs with an empty configuration: the app spawns it without a cwd, so it
looks for `mediamtx.yml` in `C:\Program Files\RapsodoGolf` (the launcher's
chdir). The defaults work.

Tested in the running app over DevTools (`--remote-debugging-port=9222`):
`startStreamServer()` returns `{webrtcPort: 8889}` and the log shows every
listener open and `MediaMTX server ready`, with no download.

## 2. The live view showed ~1 frame per second

With MediaMTX working, the app's `stream:add-path` + WebRTC worked but decoded
only keyframes (`framesDecoded == keyFramesDecoded`, ~1 fps with `-g 30`).

- The app's ffmpeg uses `-preset ultrafast -tune zerolatency`. zerolatency turns
  on x264 sliced threads: one slice per core, 10 slices per frame here.
- The app's Chromium (Electron 30.5.1, Chrome 124, under Wine) assembles only the
  keyframes of a multi-slice stream. Native Chromium 152 plays the same stream at
  30 fps (287 frames in 10 s). A single-slice stream plays at 28 fps in the app.
  Not tested: whether this is Wine or Chrome 124.

**Fix:** `scripts/patch_alignment_ffmpeg.py` (run by `40-apply-patches.sh`) adds
`-x264-params sliced-threads=0:threads=4` to those ffmpeg arguments inside
`app.asar`. The edit is the same length (whitespace absorbs the difference), so the
asar index stays valid; the build's `EnableEmbeddedAsarIntegrityValidation` fuse
is off. `--revert` undoes it byte for byte. If a Rapsodo update changes the
arguments, it warns and leaves the file alone.

Tested in the app with two test-pattern "cameras" at the real sizes going through
the app's own `addStreamPath`: Shot 274 frames and Impact 290 frames in 10 s
(27–29 fps), both at once. The two re-encodes used about 21% and 5% of a core.

## 3. Red light in the Range: a game downloaded mid-session isn't patched

- Red is not an error on the MLM2 family. Rapsodo's own LED legend in the app says
  "Red: Ready to Connect", as does
  [Rapsodo's FAQ](https://rapsodo.com/pages/frequently-asked-golf-questions-faq)
  ("waiting to connect to the app"). Before starting a game the app disconnects
  the monitor (`disconnectTcpDevice("GAME_LAUNCH")`) and stops its own device
  manager; the game then connects with its **own** `libzmq.dll` and
  `deviceManagerServer.dll` (`games/<id>/<ver>/<Game>_Data/Plugins/x86_64/`).
  So red means the game never connected. When the game closes, the app restarts
  its (patched) device manager and reconnects, which matches "connects again back
  in the app".
- The game's DLLs are patched only by `40-apply-patches.sh`, which ran only before
  the app started. After a reinstall the Range is downloaded during the session,
  so its first launch uses stock libzmq (hangs on connect under Wine) and the stock
  Go device manager (fails authentication). DXVK is hard-coded for
  `DrivingRange.exe`, so the scene still renders.

**Fix:** while the app runs, play.sh checks every 2 s for a game `libzmq.dll` with
no `.orig` next to it. It patches as soon as the app logs
`DEBUG: [SL-610] download game end <slug>` (the event that turns the card into
Play), or, without that line, once nothing under `games/` has changed for 15 s.
It skips while a game is running, runs `40-apply-patches.sh` and
`45-install-dxvk.sh` (log: `RapsodoGolf-heal.log`), and tries once per new game.
Hardening from review:
- 40 and 45 skip files already in place (`cmp -s`), so a re-run never rewrites a
  loaded DLL.
- 40 backs up a game's `libzmq.dll` only when it is the complete stock build; a
  copy taken mid-download used to become a `.orig` that was trusted forever.
- 47 unzips into `build/mediamtx/` and moves the exe into place, so an interrupted
  install can't leave a truncated `mediamtx.exe` that later runs keep.

Tested: a fake game (stock libzmq + stock device-manager DLL under
`games/zz-test/`) was patched 2 s after a `download game end` line, with fresh
mtimes (libzmq replaced, NETRESET 0 / CONNRESET 2, DXVK override added); a
truncated libzmq was skipped with no `.orig`; 47 installed cleanly into an empty
home and was a no-op on re-run. Test files removed afterwards.

Still open: a game started within about 2 s of its download finishing, or one
already running when the watcher fires, runs unpatched once; closing and starting
it again fixes it.

**Not confirmed for this user:** we don't know their Range was downloaded today.
Other causes from the investigation, less likely: the USB link dropping at the
hand-off (`notes/2026-10-19-monitor-drops-during-play.md`), or the game failing to
start graphics.

## Not tested (needs the monitor)

- Alignment steps 2–3 on real hardware: session start, `StartCameraStream`, and
  ffmpeg reading the monitor's RTSP URL over `feth0`. The URL is logged as
  `DEBUG: stream-module addPath alignment-shot -> <url>`.
- CPU with the real camera streams (decode + re-encode, two at once).
- The alignment UI itself (it needs a connected device).

## Logs to ask for if it still fails

Copy them before reopening the app (it truncates them on launch):

- `~/Library/Logs/RapsodoGolf-Wine.log`: `grep -n -E "MediaMTX|mediamtx|stream-module|ffmpeg \[alignment|stream:start-server|run command|game closed|Connected to the device|APIAuthenticate"`.
  Renderer lines (`MlmAlignment step …`) don't reach this log.
- `~/Library/Logs/RapsodoGolf-heal.log` (whole file).
- Game: `…/prefix/drive_c/users/<you>/AppData/LocalLow/Rapsodo/DrivingRange/Player.log`
  and `…/DrivingRange/log/rdc.log` (`ConnectDeviceTCP`, `GetCommunicationKey`,
  `APIAuthenticate`).
- `~/Library/Logs/RapsodoGolf-usblink.log` around the game start (`link dropped`,
  `LIBUSB_ERROR`).

## Correction

README listed "The alignment screen shows the monitor's live camera" as working
(10/23/2026). That can't have been the app's alignment screen: step 1 always failed
and this prefix had no `mediamtx` folder. It was most likely the Driving Range's
own view. README now lists alignment as fixed but not yet confirmed with the
monitor.
