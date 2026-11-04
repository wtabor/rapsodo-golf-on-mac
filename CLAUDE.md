# CLAUDE.md — rapsodo-golf-on-mac

Runs Rapsodo's Windows-only **Rapsodo Golf** PC app (1.0.0, Electron) on an Apple
Silicon Mac with an **MLM2PRO** connected over USB-C. Scripts and patches only; no
Rapsodo binaries are ever committed (`.gitignore` blocks `*.exe`, `*.dll`, `*.zip`).

Read first: `README.md`, then `notes/2026-10-19-rapsodo-golf-pc-app-on-mac.md`
(full investigation, root causes, dead ends).

## Response style
- Answer in a few sentences. No preamble, no recap. Detail goes in `notes/`, not chat.

## Where things stand (10/29/2026)
- **Working:** app connects, authenticates, and updated the monitor firmware
  4.1.9 → 4.1.19 under Wine. The owner confirmed it works end to end.
- **Only confirmed launch route:** `scripts/play.sh` run from a terminal app that has
  Local Network permission (iTerm). It auto-updates (`update.sh`), starts the USB link,
  re-applies the patches (`40`, `45`, `47`), starts the app, then the `48` display helper
  and the crash / new-game watcher. The Dock app now hands off to iTerm running
  `play.sh` (`open-in-iterm`; works as of 10/20/2026 after the one-time Automation
  prompt, which TCC records for `/bin/bash`). The app icon is built from the
  installed app's `dist/icon.png` (`scripts/make_icon.swift`). `60-install-usb-daemon.sh`
  (sudo, optional) makes the USB link a LaunchDaemon; not installed. The owner
  uses Touch ID for sudo instead (`/etc/pam.d/sudo_local`, set 10/20/2026). The app
  bundle lives in `/Applications` (`RGM_APP_BUNDLE`).
- **Publishing:** the owner plans to open-source this repo. Keep it free of personal
  data (serials, usernames, locations) and of any Rapsodo files.
- **Broken:** starting Wine directly from Finder (the old launcher). macOS Local
  Network privacy silently blocks the app's mDNS discovery; no prompt ever
  appears. Hence the iTerm hand-off. Tried and failed: `NSLocalNetworkUsageDescription` + `NSBonjourServices`,
  ad-hoc signing, a compiled Mach-O launcher (`scripts/launcher.c`), spawning Wine as
  a child instead of `exec`. Likely cause: Wine's unsigned binaries get no app identity.
- **Games (10/19/2026):** Unity games failed with "Failed to initialize player /
  DirectX 11". Fixed by `scripts/45-install-dxvk.sh` (DXVK-macOS, per-exe override).
  Driving Range renders, connects, authenticates, starts a session and arms the
  monitor (patched game DLLs work). The location prompt is gone
  (`scripts/geolocation_stub.c`). Shots not yet seen: the monitor dropped out
  twice mid-session (`notes/2026-10-19-monitor-drops-during-play.md`).
- **Alignment (10/25/2026):** the app's own alignment screen always failed ("Alignment
  Couldn't Start"). Fixed by Fix 5 + Fix 6 below. Confirmed with the monitor
  10/26/2026: all setup steps pass, both live views play (~18–20 fps), teardown is
  clean (`notes/2026-10-25-alignment-camera-and-new-games.md`). A user's "red light in
  the Range" is most likely a game downloaded mid-session (unpatched DLLs); play.sh now
  patches those while the app runs. Not confirmed with their logs.
- **Untested (10/29/2026; needs the monitor or the owner):** instrumented shot capture
  and real shots; the mid-session game patch with a real download; a real TetherKit
  bulk-IN stall (only stubs and a manual kill so far); a real Wine crash from a monitor
  power cycle under the current play.sh; Driving Range x3 and arming in a Studios round;
  how Unity re-fits a game that is open during a display unplug. Done: play.sh end to
  end from the Dock, including Wine-crash recovery (10/26 and 10/28 notes).

## How it works
- **Runtime:** Gcenx wine-staging 11.16 (unsigned; Homebrew's Wine casks were disabled
  09/01/2026). Installed under `~/Library/Application Support/RapsodoGolf-Wine11/`
  (`prefix/`, `build/`, `tetherkit-cli`). Paths live in `scripts/env.sh`.
- **USB link:** the MLM2PRO is a USB RNDIS gadget (Rockchip `2207:0019`). macOS has no
  RNDIS driver; TetherKit (userspace, libusb + `feth`) bridges it. The monitor runs
  DHCP: it is `192.168.36.1`, the Mac gets `192.168.36.x` on `feth0`.
  `scripts/usb-link.sh` (root) restarts TetherKit when the monitor re-enumerates and
  re-applies DHCP when macOS drops the temporary `ipconfig set` service. It also
  restarts TetherKit when its log shows `failed to resubmit a bulk IN transfer`
  (`LIBUSB_ERROR_PIPE`) and `192.168.36.1` stops answering ping (SIGTERM, up to 15 s for
  TetherKit's own teardown, then SIGKILL and `ifconfig feth1/feth0 destroy`, since only a
  clean exit removes the pair). TetherKit never
  recovers from that stall on its own; the app showed "Device not connected" with
  the monitor plugged in (`notes/2026-10-28-tetherkit-bulk-in-stall.md`).
  **Fix 8:** `build-tetherkit.sh` applies `patches/tetherkit-rx-idle-sleep.patch` (v0.1.5): its RX
  thread spun on `sched_yield()` (~1 P-core at all times); sleeping 500 µs instead cut it
  to ~1% idle and ~4% while streaming both cameras (680 pps, 7.4 Mbps, 0 drops, 20 fps;
  10/26/2026). The binary is replaced by rename (macOS caches code signatures per vnode).
  A running TetherKit keeps the old binary until usb-link.sh restarts. The LaunchDaemon's
  root-owned copies (`60-install-usb-daemon.sh`: TetherKit, usb-link.sh, env.sh) update
  only when 60 is re-run; build-tetherkit.sh prints a `note:` when any of them differs,
  and update.sh repeats installer `note:` lines in the iTerm window.
  **Halted pipe (11/04/2026):** on macOS a halted bulk IN pipe arrives as a plain transfer
  error, so TetherKit's clear-halt case never ran. `patches/tetherkit-clear-halt.patch`
  clears it and resubmits for up to 200 ms. A first version held a session for 4 min 40 s
  through 242 halts; the 200 ms retry hasn't been tested with the monitor. The owner reports
  the drops stop with iPhone Bluetooth off; not confirmed in the logs
  (`notes/2026-11-04-range-video-confirmed-and-usb-halts.md`).
- **Fix 1 — libzmq:** libzmq 4.3.5's `make_fdpair_tcpip` sends 1 MB over a blocking
  loopback socket before reading (zeromq #1608 workaround). Wine on macOS deadlocks.
  `scripts/30-build-libzmq.sh` cross-builds a patched DLL (mingw-w64 UCRT, CURVE via
  the app's own `libsodium-26.dll`, select poller, IPC off). 71/71 exports match.
  libzmq's `Findsodium.cmake` has `find_package(PkgConfig REQUIRED)` although the
  sodium paths are passed in; 30 drops `REQUIRED`, so no pkg-config is needed (a user
  without Homebrew's pkgconf hit "Could NOT find PkgConfig", 11/01/2026).
- **Fix 2 — deviceManagerServer.exe (Go):** Go's UDP setup calls `SIO_UDP_NETRESET`,
  which Wine doesn't implement → the CoAP cert request (UDP `:5683`) fails →
  `APIAuthenticate` fails. `scripts/patch_devicemanager.py` rewrites the single
  `mov $0x9800000f,%ebx` to `0x9800000c` (CONNRESET, which Wine stubs).
- **UI flags:** `--no-sandbox --disable-gpu --disable-gpu-compositing --in-process-gpu`.
- **Fix 3 — D3D11 for Unity games:** wined3d fails `wined3d_device_init: Failed to
  create command stream`; games ship D3D11/D3D12 shaders only. DXVK-macOS
  `d3d11`/`d3d10core` in system32 + `AppDefaults\<Game>.exe\DllOverrides=native,builtin`.
  DXMT won't load: Gcenx's `winemac.so` hides the `macdrv_*` symbols it needs.
  Game log: `C:\users\<you>\AppData\LocalLow\Rapsodo\<Game>\Player.log`.
- Each game (`games/<id>/<ver>/<Game>_Data/Plugins/x86_64/`) ships its own
  unpatched `libzmq.dll` + `deviceManagerServer.dll`; `40-apply-patches.sh` patches
  those too (libzmq only if it's the same 4.3.5 build as the app's).
- **Fix 4 — location:** games call WinRT `Geolocator` via `GeolocationPlugin.dll`;
  Wine never grants access → "Unable to get location permission state". `40` swaps
  in `scripts/geolocation_stub.c` (Allowed + `RGM_GEO_*`), only over the original
  sha256 `46058374…` whose ABI was checked. With no position the game shows
  "Network access required", so `env.sh` defaults to 0/0/0; real values go in the
  gitignored `scripts/env.local.sh` (template `env.local.sh.example`).
- **Fix 5 — MediaMTX (alignment video):** `startStreamServer` downloads MediaMTX
  v1.17.0 into `%APPDATA%\super-app-clm\mediamtx\` and unzips it with PowerShell;
  Wine's `powershell.exe` is a stub (exits 0, extracts nothing). MediaMTX is Go, so it
  also needs the NETRESET patch. `scripts/47-install-mediamtx.sh` installs a
  sha256-checked, patched copy (the app only checks the file exists). It runs with an
  empty config (cwd is the app dir); fine.
- **Fix 6 — alignment frame rate:** the app re-encodes each camera with ffmpeg
  `-tune zerolatency` (sliced threads: one slice per core). Its Chromium (Electron 30 /
  Chrome 124 under Wine) assembles only keyframes of multi-slice H.264 → ~1 fps.
  `scripts/patch_alignment_ffmpeg.py` does a same-length edit in `app.asar` adding
  `-x264-params sliced-threads=0:threads=4` (asar integrity fuse is off; `--revert`).
- **Fix 7 — fewer Windows processes (load):** macOS `ecosystemd` does ~15 Rosetta /
  code-signature checks per Windows process start, single-threaded at ~40 ms each
  (~20–25/s at most; ~18/s measured at one core). The app's
  `cmd /c tasklist` game check (every 1 s while a game runs) outran it: ~1 core busy for
  minutes after a game. `scripts/patch_app_polls.py` (same-length `app.asar` edits,
  `--revert`): game check `<var> = 1e3` → `6e4` (60 s; the `cmd /c` child's exit already
  reports a normal quit; `<var>` is found by structure, `Pae` in 1.0.0, `due` in 0.6.0), Wi-Fi `netsh` poll `WIFI_INTERVAL_TIME=15e3` → `36e5` (no Wi-Fi
  data under Wine anyway). Studios: ecosystemd 55%+ → ~10% (measured at 10 s).
- **Fix 12 — resizable app window (11/01/2026):** `dist-electron/main.js` creates the
  main window with `minWidth`/`minHeight` = the primary display's `workAreaSize`,
  maximizes it when the splash closes and after every game (`Ne.maximize(), Ne.show()`),
  and its `responsive-zoom` resize handler (`pm`, logs `[SL-303 responsive-zoom] content
  WxH ... -> zoom Z`) zooms only up (1 up to 1920 px wide, max 1.25). Under Wine the Mac
  window can be dragged smaller, but Wine doesn't pass a resize of a *maximized* window
  on: Mac window 1920x1265 while the app still had 3840x2530 `IsZoomed`, page cropped.
  Un-maximized with `ShowWindow(SW_RESTORE)` + `SetWindowPos` it resized (content
  1592x966, zoom 0.829). `scripts/patch_app_window.py` (run by 40, same-length edits,
  `--revert`): window opens at the work area's size (normal, not maximized) with a
  minimum of 800x450 (`resizable: !0`, Electron's default, makes room); both
  `maximize()` calls become `focus()`; zoom = min(width/1920, height/1080) when below 1,
  floor 0.25 (`|| 1` keeps zoom 1 for a 0x0, minimized, window), up-zoom as before.
  Found by structure, the `maximize` sites from their literal text (a regex starting with
  a name crawls through the 280 MB archive).
- Games downloaded while the app runs are unpatched: play.sh watches `games/` and runs
  40 + 45 when the app logs `download game end` (fallback: 15 s with no changes) and no
  game is running. 40/45 skip files already in place (`cmp -s`), so re-runs never
  rewrite a loaded DLL; 40 only backs up a complete stock libzmq.
- **wineserver crash (10/26/2026):** wineserver segfaulted twice during Studios games
  (10:38, during a monitor USB reset; 13:18, with a steady link, so the monitor isn't
  required); every Wine process froze for good. Site: `fd_reselect_async` on a freed
  socket `struct fd` (use-after-free; most likely `accept_into_socket`'s fd swap while an
  AFD poll was still queued). Which program in the game triggers it isn't known
  (`notes/2026-10-26-wineserver-crash-on-monitor-power-cycle.md`).
  play.sh recovers: launcher alive + no wineserver → `kill -9` every pid that maps this
  install's `share/wine/nls/locale.nls` (`lsof -t`), keep `*-crashed.log`, re-exec (max 3,
  `RGM_WINE_RESTARTS`). Its startup also clears frozen leftovers. `kill -SEGV <wineserver>`
  reproduces the symptom. play.sh sets `ulimit -c 1` so wineserver skips its own
  SIGSEGV handler (print + `exit(1)`, no report) and a crash leaves `wineserver-*.ips`
  in `~/Library/Logs/DiagnosticReports` or `/Library/Logs/DiagnosticReports` (seen both).
  The watcher tracks the app's own server pid, so a `wine reg` restarting a server can't
  mask a crash; the server path is matched resolved (`pwd -P`), as Wine starts it.
- Game settings (`miniapp:Practice:SavedSettings`, incl. music) live in
  `C:\ProgramData\Rapsodo\SuperApp\app.db`: a plain Redis-style `set` log, but the
  values are encrypted.
- `launcher.c` sets `MVK_CONFIG_LOG_LEVEL=1` + `DXVK_LOG_LEVEL=warn` (games inherit
  them); otherwise MoltenVK logs ~86 MB per 10-minute game session. It also sets
  `GST_PLUGIN_FEATURE_RANK=vtdec:NONE,vtdec_hw:NONE,avfassetsrc:NONE`: GStreamer's
  applemedia (and vulkan) plugins link their own MoltenVK, and loading it next to
  Wine's gives "Class MVKBlockObserver is implemented in both"; libav decodes instead.
  And `DYLD_INSERT_LIBRARIES=<bundle>/Contents/MacOS/rgm-appname.dylib` (only if it
  exists; dyld won't start a process whose inserted library is missing), built by 50
  from `scripts/appname.c`: on `NSApplicationDidFinishLaunchingNotification` it sets the
  process's LaunchServices display name (Chromium's `_LSSetApplicationInformationItem`
  / `_kLSDisplayNameKey`) from argv[0], which Wine rewrites to the Windows exe:
  "Rapsodo Golf", "Driving Range", "Target Range", "Rapsodo Studios", else the exe name.
  Without it every Wine process is "wine" in the Dock, Command-Tab and Force Quit.
  `lsappinfo setinfo` from outside is silently ignored; only the process itself can.
  Verified 11/01/2026 with `NSRunningApplication.localizedName` (app + Range, through
  `cmd /c` like the app starts games); the menu bar's bold app name isn't changed.
- **Fix 10 — GStreamer for game video (11/01/2026):** Gcenx's Wine
  needs GStreamer.framework for all users; `winegstreamer.so` links `@rpath/libgst*`
  (1.28, compat 2802) via `/Library/Frameworks/GStreamer.framework/Libraries`. Without
  it Media Foundation can't open the Range's swing video (`MFCreateSourceReaderFromURL`
  = MF_E_UNEXPECTED), so Unity's VideoPlayer shows nothing. `46-install-gstreamer.sh`
  installs the official universal 1.28.8 runtime pkg (sha256-pinned) with
  `sudo installer`; skips an x86_64 libgstreamer >= 2802. Then pre-builds GStreamer's
  plugin list (`~/.cache/gstreamer-1.0/registry.x86_64.bin`; the first scan took ~60 s
  under Rosetta). Verified: the real ShotVideo.mp4 decodes 30/30 frames through Media
  Foundation (`notes/2026-11-01-user-bugs-pkg-config-and-swing-video.md`).
- **Fix 11 — game video frames (11/01/2026):** with GStreamer in place the Range's
  video panel stayed blank at 00:00. Two causes, both in Player.log:
  - `WindowsVideoMedia error 0x80070057 while reading` + `Context: Failed getting shared
    handle from IDXGIResource`, once per frame. With D3D11, Unity's WindowsVideoMedia
    decodes on its own D3D11 device and opens each frame on the render device via
    `GetSharedHandle` → `OpenSharedResource`. DXVK-macOS can't share textures
    ("VK_KHR_EXTERNAL_MEMORY_WIN32 not supported"; `GetSharedHandle` = E_INVALIDARG on
    every texture). Unity only takes that path if `GetProcAddress(mfplat,
    "MFCreateDXGIDeviceManager")` succeeds (globals checked in source setup and when
    building its D3D frame queue); otherwise it reads frames into system memory and
    uploads them itself. `scripts/patch_unity_video.py` (run by 40 on every
    `games/<id>/<ver>/UnityPlayer.dll`, `--revert`) renames that one string to
    `RGMNoDXGIDeviceManager` (same length; refuses a DLL that imports mf* statically).
  - `First video frame not zero: 2 (0.666667s)`: Unity turns each sample time into a
    frame number and drops any frame that isn't the one it asked for. Wine's default MP4
    reader (winegstreamer, qtdemux) ignores the edit list of B-frame MP4s, so frames start
    at 0.667 s (shot video, 3 fps) or 0.05 s (swing video, 40 fps). Wine's newer reader
    (mfsrcsnk + winedmo, using GStreamer.framework's FFmpeg 7.1) gets 0. 46 sets
    `HKCU\Software\Wine\MediaFoundation\DisableGstByteStreamHandler=1`.
  Verified offline with a program that reads like Unity (async callback, its reader
  attributes, no DXGI manager, its stride/orientation logic): both real videos, all
  frames, times from 0, right side up, for NV12/RGB32/ARGB32. Confirmed in the Range with
  a real shot 11/04/2026: Shot and Impact videos play, no video errors in Player.log.
  Known: on the D3D path the new reader sometimes lost the last 3 frames (decoder drain
  race); never on the system-memory path.
- **Fix 9 — display layout after a monitor change (10/28/2026):** win32u never
  re-points its per-source registry links (`...\Control\Video\{gpu}\0000` →
  `Sources\<id>`) within a session (`REG_OPTION_OPEN_LINK` is ignored on create). So
  after the primary display changes (unplugging the main external monitor),
  every process reads a stale layout: no primary, a `WinDisc 0,0-1024,768`
  placeholder, or the removed monitor's size. Fullscreen games and the cursor then
  stop short of the screen. `scripts/display_fix.c` (`48-build-display-fix.sh`):
  play.sh runs `rgm-display-fix.exe watch RapsodoGolf.exe` next to the app. It
  deletes only the stale links (`OBJ_OPENLINK`) after each layout change and lets a
  fresh process re-enumerate. `rgm-display-fix.exe show|repair` by hand
  (`notes/2026-10-28-display-layout-after-monitor-unplug.md`). That bug made Driving
  Range save a 1x1 screen size and crash at every start. 45 resets any Unity game's
  saved width under 320 (`Use Native`=1).
- **Auto-update (this project, 10/26/2026):** play.sh runs `scripts/update.sh` at each
  launch: GitHub API `commits/<ref>` (sha only, 5 s timeout; ref from `.rgm-ref`,
  default main) vs `.rgm-version`; if different, downloads `archive/<sha>.tar.gz`
  (curl and tar must both succeed), swaps files in by rename (running scripts keep
  their old inode; plain `cp`, so mtimes are fresh; 40/48 rebuild their C helpers by
  source sha256, not mtime), re-runs `install.sh`, records the sha on success, exits 3 →
  play.sh re-execs with `RGM_UPDATED=1`. Skipped for git checkouts and
  `RGM_AUTO_UPDATE=0`. `bootstrap.sh` pins the sha and ref for tarball installs.
  Installed copies run *their own* update.sh: never rename `scripts/install.sh` /
  `scripts/play.sh` or change the exit-3 contract. The new install.sh and play.sh
  inherit the old env.sh's exported paths (`RGM_HOME` etc.), so changing a path
  default (e.g. the `RapsodoGolf-Wine11` folder) needs migration code, not just a
  new default. Stale files are never deleted.
- **Rapsodo release watch (10/30/2026):** the app updates itself (electron-updater,
  generic provider) from `https://storage.googleapis.com/super-app-clm-prod/latest.yml`
  (`updaterFeedURL` in main.js; `resources/app-update.yml` says `-beta` but is
  overridden). `.github/workflows/rapsodo-app-watch.yml` reads it daily; for a release
  with no `rapsodo-release` issue yet (title = version + sha512 prefix, so nothing is
  committed) it runs `scripts/rapsodo-compat-check.py`: download, sha512, `7z` the NSIS
  installer → `$PLUGINSDIR/app-64.7z` → app, then on copies: stock libzmq sha256 (Fix 1),
  patch_devicemanager / patch_alignment_ffmpeg / patch_app_polls (Fixes 2, 6, 7), the
  MediaMTX tag the app downloads vs 47's `MTX_TAG` (Fix 5), the log lines play.sh keys
  on, and the feed URL. Exit 0 pass / 1 needs work / 2 couldn't run (job fails, no
  issue). `--channel test` reads Rapsodo's pre-release feed (manual dispatch only).
  Also checks the userData name (`super-app-clm`, 47's folder) and the games path 40/45/
  play.sh hardcode. Test 0.6.0 (10/27/2026) passes since Fix 7 finds its timer by
  structure (`notes/2026-10-30-rapsodo-release-watch.md`). Scheduled workflows in public
  repos stop after 60 days without repository activity.
- A Rapsodo app auto-update, or a new game download, undoes the patches →
  `scripts/40-apply-patches.sh`, then `scripts/45-install-dxvk.sh`, then
  `scripts/47-install-mediamtx.sh`.

## Monitor facts (MLM2PRO over USB)
- Services: SSH `:22`, nginx `:80` ("IP Camera"), ZeroMQ DEALER/ROUTER + CURVE
  `:32501`, CoAP UDP `:5683`, mDNS `_RapsodoDevice._tcp`
  (`MLM2-<serial>-<hw>-<fw>`).
- It resets USB on some connect attempts and during firmware updates (~10 s
  re-enumeration). After a replug it can take ~60 s or a power-button press before
  DHCP answers. It powers off when idle; check `feth0` before blaming the app.
- The first `APIAuthenticate` after launch can time out; the app's retry succeeds.

## Debugging toolkit
- App log: `~/Library/Logs/RapsodoGolf-Wine.log` (play.sh/launcher) — grep
  `MdnsScanner`, `V3ScanTCP`, `DEALER`, `Connected to the device`, `APIAuthenticate`,
  `request-cert`.
- USB link log: `~/Library/Logs/RapsodoGolf-usblink.log`.
- Drive the UI without clicking: launch with `--remote-debugging-port=9222` (a launcher
  built from the current `launcher.c` adds it when `RGM_REMOTE_DEBUGGING_PORT=9222` is
  set, as tier 3 of `scripts/test.sh` does; `tests/app/cdp.mjs` is a small client) and
  use the Chrome DevTools Protocol; the renderer exposes
  `window.deviceManager.client.rdc.<Service>.<method>` (e.g.
  `DiscoveryAndConnectionService.scanTcpDevices(6)`).
- Wine socket tracing: `WINEDEBUG=+winsock`. Thread backtraces:
  `wine winedbg --command "bt all" 0x<wpid>` (`info proc` lists pids).
- `sudo` needs the owner's password: start root commands in a terminal tab for them
  to type it; never ask for the password in chat.

## Rules
- **main ships.** Every push to main reaches every user at their next launch
  (auto-update). Push only changes that were tested; keep work in progress on a branch.
- Never commit Rapsodo binaries, installers, or patched copies of them.
- Keep `scripts/` idempotent; re-run them rather than hand-editing the prefix.
- Lint shell with `shellcheck -x -e SC1091 scripts/*.sh tests/*.sh` before committing.
- Run `scripts/test.sh` (tiers 1–2, under a minute) before anything goes to main; tiers
  3–4 (`scripts/test.sh 3 4`, app closed, monitor on, from iTerm) for changes to the
  launch path, games or monitor link. `scripts/install-test-hook.sh` makes `git push` to
  main run tiers 1–2 on the pushed commit (`RGM_SKIP_TESTS=1` to skip once).
  `notes/2026-11-01-regression-tests.md`.
- Add a dated `notes/YYYY-MM-DD-*.md` for any meaningful experiment, including failures.
