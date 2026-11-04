# Regression tests: scripts/test.sh and a pre-push hook (11/01/2026)

Every push to main reaches every user at their next launch (`update.sh`), so changes
need a check before they get there. This adds one entry point, `scripts/test.sh`, in
four tiers, and an opt-in pre-push hook. Branch `regression-tests`, on top of main at
f00c711 (the video fix and the Dock names landed while this was written).

## How to run

```bash
scripts/test.sh               # tiers 1 and 2 (the default; what the hook runs)
scripts/test.sh 3 4           # the app, the games and the monitor: app closed, from iTerm
scripts/test.sh -v 2          # one tier, with the output of passing checks too
scripts/install-test-hook.sh  # opt-in: `git push` to main runs tiers 1-2 first
RGM_SKIP_TESTS=1 git push     # push anyway, once
```

Each check prints PASS, FAIL or SKIP; a missing prerequisite (no Wine, no app, no
monitor, no ffmpeg ...) is a SKIP. Exit status 1 when anything failed. Bash 3.2 safe
(macOS `/bin/bash`), checked by running the suite under it.

## What each tier checks

**Tier 1, static (~15 s).** Nothing installed is changed.
- `shellcheck -x -e SC1091 scripts/*.sh tests/*.sh`.
- Python syntax of `scripts/*.py` and `tests/*.py`, compiled in memory (no
  `__pycache__`), with the Python on PATH **and** macOS's `/usr/bin/python3` (3.9 with
  the Command Line Tools). Users without Homebrew's Python run the patchers with 3.9, so
  3.12-only syntax would break their install.
- The binary patchers on copies (APFS clones) of the installed files
  (`tests/patchers.py`): `patch_devicemanager.py` on the app's
  `deviceManagerServer.exe`, each game's `deviceManagerServer.dll` and `mediamtx.exe`
  (stock `.orig` -> exactly a 1-byte change, identical to the installed patched file,
  `.orig` written, re-run says "already patched", unknown file and a file with two
  NETRESET sites refused and untouched); `patch_alignment_ffmpeg.py` and
  `patch_app_polls.py` on `app.asar` (patch, re-run, `--revert`, `--revert` again, patch
  again, all byte-identical; unknown file refused); `patch_unity_video.py` (skipped
  in a checkout without it): each Unity build, `.orig`, replaced by rename (new inode),
  change confined to the 26-byte name, re-run, revert byte-identical, refuses an
  unknown file and a DLL built on the spot that imports mfplat statically.
- `update.sh` for real in a sandbox (clean environment, system bash, fake "GitHub" via
  `file://` URLs, stub `install.sh` in the new version): update (exit 3, new file
  swapped in, version recorded, `env.local.sh` and stale files kept), same version
  (silent exit 0), offline, cut-off tarball (warning, nothing swapped), failing
  install (exit 3, old version kept), `RGM_AUTO_UPDATE=0`, git checkout. Plus play.sh
  still restarts itself on exit 3.
- `launcher.c` and `appname.c` (clang), `geolocation_stub.c` and `display_fix.c`
  (MinGW) compile with the flags 50/40/48 use; the `tests/wine` programs compile.
- Repo hygiene: no tracked `.exe/.dll/.zip/.asar/.mp4/...` or PE/zip/7z/gzip content;
  no monitor serials, account ids or `/Users/<name>/` paths; scripts stay executable.

**Tier 2, Wine without the monitor (~18 s with a Wine server already up).** Programs
in `tests/wine/` (source only), built with MinGW into a temp folder and run with the
launcher's environment plus `WINEDLLOVERRIDES=d3d11,d3d10core=n,b`, each under a
`perl alarm` timeout (macOS has no `timeout`). They only read the prefix; they run fine
next to an open app and game.
- `udpioctl.exe`: Wine accepts `SIO_UDP_CONNRESET` (what the Fix 2 patch turns NETRESET
  into); reports whether NETRESET is still rejected.
- `d3d11check.exe`: `d3d11.dll` is DXVK (not Wine's builtin, told apart by Wine's
  "Wine builtin DLL" PE marker), hardware device at feature level 11_0, BGRA
  upload/readback, NV12 texture; reports that shared textures still don't work.
- `geocheck.exe`: a stub built from `scripts/geolocation_stub.c`, called through the
  raw ABI from its comment (8 bytes in RAX; 32-byte struct via the hidden pointer):
  Allowed + `RGM_GEO_*` (neutral test values), and no fix without them.
- `zmqcheck.exe`: the installed patched `libzmq.dll` (loaded by full path, so its
  `libsodium-26.dll` comes from the same folder): context, sockets, PAIR round trip on
  loopback TCP, CURVE DEALER/ROUTER round trip.
- MediaMTX (installed, patched) with its own loopback-only config on 185xx/188xx ports:
  RTSP UDP/RTP and WebRTC ICE/UDP listeners open, still running at the 8 s timeout.
- `rgm-display-fix.exe show` (built from source): a primary monitor, no "WinDisc".
- Media Foundation the way Unity reads video after `patch_unity_video.py`
  (`unityvp.exe NOD3D=1`: async reader, system memory, Unity's stride lookup) on
  **synthetic** videos made with ffmpeg each run (never the owner's swing videos):
  no-B-frame 480x640 3 fps; H.264 High with B-frames, 480x640 3 fps (its MP4 has an edit
  list with media time 8192 = 2 frames, like the Range's shot video; checked each run);
  the same with RGB32 output; B-frames 1536x1440 40 fps (edit list 0.05 s, like the
  swing video). Each: every frame, first sample time 0, every frame has a picture. And
  `mfsrc.exe`: the MP4 source's own first sample time is 0. The B-frame checks must pass
  only when `HKCU\Software\Wine\MediaFoundation\DisableGstByteStreamHandler=1` is set
  (read from `user.reg`, no Wine call); without it a failure is a SKIP (Wine's known
  default).

**Tier 3, the app without the monitor (not run yet; minutes).** Skips unless the app
and every Wine process of this install are closed (same prefix). Builds `launcher.c`
into the temp folder with its log there (the real `RapsodoGolf-Wine.log` is untouched)
and starts it with `RGM_REMOTE_DEBUGGING_PORT` (new opt-in in `launcher.c`, see below),
with `appname.c` built next to it as 50 does.
Checks: device manager start line; the page (loaded, Vue mounted, `electronAPI`,
`deviceManager.client.rdc` services); a renderer -> device manager call
(`game.findAllGames`). Then each downloaded game (list and `-language`/`--mode`
arguments from the app's own `findAllGames` / `findMiniApps`, else the folders on disk;
`RGM_TEST_GAMES` to pick): `electronAPI.runGame`, "run game" in the app log, a fresh
`Player.log` with `Direct3D 11` and `UnloadTime:` (first scene) and no crash marker,
still up 10 s later, closed with `wine taskkill` (WM_CLOSE; `/f` only if ignored), app
logs "game closed" and restarts its device manager, page still answers. Last, quit via
`window.close()` (fallback WM_CLOSE): launcher exits 0 and no Wine process is left.
Ctrl-C or any failure kills only that test copy (`wineserver -k`, safe because nothing
else was running).

**Tier 4, the monitor.** Skips unless 192.168.36.1 answers ping. With tier 3, while its
app is up and before the games: discovery (`MdnsScanner` / `V3ScanTCPDevices`),
"Connected to the device", `APIAuthenticate` with Status 0; then the alignment screen
(router push to `/alignment`, "Align Now"): "MediaMTX server ready" and both ffmpeg
publishers in the app log, both `<video>` views at 8+ fps (Fix 6 regressions show ~1
fps), and no ffmpeg or MediaMTX left after leaving the screen. Discovery needs the
terminal's Local Network permission: run it from iTerm. Alone (`scripts/test.sh 4`
next to an app you started with play.sh) it reads that app's log for the connection
lines. Never echoes log lines (serials, account ids). Always ends with a checklist: a
shot in the Range (ball flight, numbers), Shot and Impact videos play, connection holds,
app comes back after closing the Range.

## launcher.c change
`RGM_REMOTE_DEBUGGING_PORT=<digits, up to 5>` adds `--remote-debugging-port=<port>`
after the fixed arguments; anything else (unset, empty, `9222; rm -rf /`, `123456`,
`abc`) leaves the arguments exactly as before. Checked with a fake `wine` that records
its arguments. play.sh never sets it; the installed launcher only changes when 50
re-runs.

## Pre-push hook
`scripts/install-test-hook.sh` writes `pre-push` into the repo's hooks folder (`git
rev-parse --git-path hooks`, so worktrees and `core.hooksPath` work); refuses to replace
a hook that isn't its own; `--uninstall`. For each commit pushed to `refs/heads/main` it
checks that commit out in a temporary worktree (copying `scripts/env.local.sh`), runs
its `scripts/test.sh` (`RGM_PUSH_TEST_TIERS`, default `1 2`) and blocks the push on a
failure. Pushes to other branches and branch deletions aren't tested.
`RGM_SKIP_TESTS=1` or `git push --no-verify` skips it.

## Results on the owner's Mac (11/01/2026, app and a game running in another session)
- Tier 1: 26 passed, 0 failed, 0 skipped, 16 s (`patch_unity_video.py`: both Unity
  builds, 25 bytes differ, revert byte-identical, the mfplat-importing DLL refused).
- Tier 2: 13 passed, 0 failed, 0 skipped, 16–18 s (Wine server already running for the
  app; a cold start adds the server start, not measured).
- Through the hook (scratch clone, scratch bare remote): a good commit pushed to main
  after tiers 1–2 passed (34 s); a commit with a shellcheck error was blocked (remote
  main unchanged); `RGM_SKIP_TESTS=1` pushed it; a push to another branch ran nothing;
  no temporary worktree left; `--uninstall` and the foreign-hook refusal work.
- Same results under `/bin/bash` 3.2.57.
- The tests catch what they're for:
  - stock `libzmq.dll.orig` in `zmqcheck.exe`: hangs in `zmq_ctx_new`, killed at the
    timeout (the Fix 1 deadlock);
  - stock `mediamtx.exe.orig`: `ERR listen udp 127.0.0.1:18000: wsaioctl: winapi error
    #10045`, exit 1;
  - `d3d11=b`: detected as Wine's builtin, feature level 9_3;
  - `update.sh` with `exit 0` instead of `exit 3`: the sandbox check fails;
  - the location stub returning status 2: both geolocation checks fail;
  - `patch_alignment_ffmpeg.py` padding its edit with `#` instead of spaces: the
    round-trip check fails (it no longer recognizes the installed patch).
- Tier 3/4 code paths run against a mock page in headless Chrome (temporary profile, no
  Rapsodo app): page check, `findAllGames`, `--mode=` argument choice, `runGame` with
  backslash paths intact, Windows -> Mac path mapping, "Align Now" click, fps
  measurement, teardown navigation; the folder fallback for the game list; tier 4's log
  patterns on a synthetic log. Tiers 3 and 4 themselves were **not run**: another
  session was live-testing the app.

## Tier 3 live, and keeping it out of the way (11/01/2026, later)
- First live run, as written: started the app and games full screen on the owner's
  screen, maximized, and couldn't be minimized or hidden while it ran. The owner stopped
  it. Before the stop: app up, page loaded, `findAllGames`, Target Range started, reached
  its first scene and was force-closed (it ignores WM_CLOSE).
- Now quiet by default (`RGM_TEST_SHOW=1` for the old behavior):
  - `tests/wine/winctl.c` runs in Wine for the whole tier and minimizes, without
    activating (`SW_SHOWMINNOACTIVE`), every visible top-level window of RapsodoGolf.exe
    and the games' exes, 5 times a second (the app shows its window again after each
    game). Stopped only after the app has quit; stopping it when the quit started left
    the app window visible for ~4.5 s.
  - `tests/app/focusguard.swift` (built with swiftc) hides every regular app of this
    Wine install, 5 times a second, so nothing keeps the keyboard. `hide()` returns before
    the app is hidden, so it can't report success; checked separately: isHidden went
    false -> true.
  - Games get `-screen-fullscreen 0 -screen-width 640 -screen-height 360`.
  - Unity saves the window size in HKCU\Software\<company>\<product> when the game
    quits, so each game's key is exported before and deleted + re-imported after it is
    closed, on every path (a start that looked failed may have started it), and from the
    cleanup trap on Ctrl-C. The first quiet run returned early on a failure, skipped the
    restore, and left Driving Range with a saved 640x360 window; repaired by hand the way
    45 repairs a bad size (Resolution and Window Width/Height deleted, Use Native = 1).
  - That failure ("no 'run game' line in the app log" while `runGame` had returned true)
    didn't repeat. `runGame` resolves true only after the app logs "run game", so the
    log check was dropped; true now counts as started.
- Results, all five games, tiers 1-3: 29 + 13 + 9 passed, 277 s. A sampler (CGWindowList +
  NSWorkspace, every 0.5 s) saw a Wine window on screen in 25 of 541 samples (~1-1.5 s
  at each game start and close: windows caught mid minimize animation) and Wine as the
  frontmost app in none. Every game's settings key was identical before and after.

## Tier 4 live (11/04/2026, MLM2PRO on USB, from iTerm)
First run with a real monitor. Discovery, connection and APIAuthenticate passed at once,
so the launcher's naming library (`DYLD_INSERT_LIBRARIES`) doesn't cost the app Local
Network access. The alignment checks failed three times, each time a bug in the test, not
in the app (they had only run against a mock page):
- "no Align Now button": the test compared `innerText` with "Align Now", but the button
  has the `uppercase` class and innerText returns styled text. Now
  `[data-testid=cal-footer-cta]`, compared case-insensitively.
- "alignment camera streams start" failed while the log showed both streams online:
  `log_after` piped tail into `grep -q`. grep stops at the first match, tail dies of
  SIGPIPE, and scripts/test.sh's pipefail turns that into a failure. On this log: 0 of 20
  matches found with `grep -q`, 20 of 20 with `grep >/dev/null`. Most likely also the
  one-off "no 'run game' line" of the first quiet run.
- "want 2 views": the screen shows one camera at a time, on tabs. Now Shot Vision, then
  `[data-testid=camera-tab-impact]`.

Final run: tier 3 (no games) 4 passed, 1 skipped; tier 4 6 passed in 48 s. Live views 22.4
and 24.2 fps with the window minimized and hidden, so quiet mode doesn't throttle them.
Teardown left no ffmpeg or MediaMTX, the app quit cleanly. That run printed `cdp: Promise
was collected` for the Align Now step (the page changed under the pending call); the
click had landed and the streams started, and the check goes by the app log.

## Bug found in existing scripts (fixed: 340a7cc, every patcher now needs exactly one path)
- `patch_app_polls.py` with no file argument patches **its own source**: it takes
  `sys.argv[-1]`, which is then the script itself, and the Wi-Fi constants occur once
  each in it, so it rewrites `WIFI_ORIG` to `...36e5,` (checked on a copy). After that the
  Wi-Fi edit can't be applied or reverted. Only by hand (40 always passes the path).
  `patch_alignment_ffmpeg.py` has the same `sys.argv[-1]` pattern (opens itself
  read-write; no match today, so no write), and `--revert` without a path tries to open
  a file named `--revert`. `patch_devicemanager.py` without an argument dies with an
  IndexError. A usage check (exactly one path argument) would fix all three.
