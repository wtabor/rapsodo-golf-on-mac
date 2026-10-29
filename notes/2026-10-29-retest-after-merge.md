# Retest after merging the crash, load and display fixes (10/29/2026)

main was merged and pushed as 643f8de: crash recovery (c3a4e0d), load fixes (adcc8c1),
display fix (ad9b97a, merge c07a8d3) and the USB-stall watchdog (643f8de). Then
everything was retested. The launch monitor wasn't available and the Mac was locked,
so hardware and on-screen checks are listed at the end as still open.

## Sandbox tests (two rounds, four testers each, every failure re-checked by a skeptic)
Run in scratch copies with a fake HOME and stubbed Wine, TetherKit, curl, ping and
ifconfig; nothing touched the real install.

Round 1 (on 643f8de) found, and these were fixed:
- **High, live on main:** `45-install-dxvk.sh` ended with `[ -d "$GAMES" ] && find ...`,
  so on a fresh install (no `games/` until the first game download) it exited 1.
  install.sh then stopped silently after 45: no MediaMTX, display helper, Dock app or
  TetherKit, and bootstrap.sh failed. Auto-update also retried the install at every
  launch for users with no games. Fixed and pushed alone as 66cff02.
- usb-link.sh SIGKILLed TetherKit 5 s after SIGTERM, but TetherKit's clean exit can take
  ~5 s and is the only thing that removes `feth0`/`feth1`. Now 15 s, then SIGKILL and
  `ifconfig feth1/feth0 destroy`.
- Auto-update copied files with `cp -p`, so they kept GitHub's commit-time mtimes, and
  48 (`-nt`) could skip rebuilding a changed `display_fix.c` (same for 40's
  `GeolocationPlugin.dll`). Now plain `cp`, and both rebuild by source sha256
  (`<output>.src.sha256`).
- The "always-on USB link still runs an older version" note only went to the update
  log. update.sh now repeats installer `note:` lines in the window, build-tetherkit.sh
  also compares the daemon's usb-link.sh and env.sh, and play.sh checks all three at
  every launch (an installed older update.sh would otherwise still hide it).
- After a Wine crash during startup, play.sh started the display helper, whose wine
  started a fresh server that looked like the app's, which could delay or skip crash
  recovery. play.sh now records the app's server before the helper and starts the
  helper only when the app and its server are up.
- Docs: "Fix 8" meant two fixes (README: TetherKit; CLAUDE.md: display); the display
  fix is now Fix 9 in both, with a README row and troubleshooting row. README Legal
  lists the app.asar timer edits. CLAUDE.md status and Untested lines updated.

Round 2 (on the fixes) passed every functional case: auto-update and install (18
cases, including old installed update.sh copies doing the update, file modes, a fresh
install with no games folder, sha256 rebuilds), the watchdog (18, including the 15 s
SIGKILL and the feth destroys), play.sh integration (19: normal start/quit, Wine
crash mid-session and at startup, device-manager retry, auto-update re-exec, restart
limit, new-game patching). Small follow-ups from it: `disown` for the display helper
(no "Killed: 9" job notice on a crash restart), and play.sh adds Homebrew's PATH like
install.sh (mingw for 40/48 in a bare iTerm environment).

Refuted or left alone as theoretical: a false "crashed" at startup needs the app's
wine to take ~5 s to reach the server; the trap in usb-link.sh not waiting for
TetherKit on Ctrl-C; feth leftovers from a TetherKit that crashes by itself.

## Live tests on the owner's Mac (no monitor)
play.sh run from a shell with a stand-in for the USB link (no sudo), the real launcher
for the launch/crash/quit tests and a DevTools copy of it for the games:
- Launch: fixes applied, `48` built, display helper started and reported the right
  layout (`\\.\DISPLAY1 0,0-1800,1169 primary; \\.\DISPLAY2 -923,-2160-2917,0`), app and
  device manager up.
- `kill -SEGV` on the app's wineserver: detected in ~3 s, frozen processes killed,
  `*-crashed.log` kept, a `wineserver-*.ips` crash report written (ulimit), app
  restarted ("Wine crash 1 of 3") with a new display helper.
- Normal quit (`wine taskkill`, i.e. WM_CLOSE): play.sh gone in ~2 s, no false crash,
  no Wine process left.
- Driving Range: starts (D3D11 via DXVK) and stays up; it used to crash at every start
  after the 1x1 saved size. Saved size now 1800x1169, fullscreen window. Its
  localization/Addressables errors also appear in the last good run's log.
- Studios (courses): starts, reaches the Courses screen, 3 minutes with a stable
  wineserver. ecosystemd: 0–4% during games (one 67% sample at game start); the app's
  game check ran once a minute, and a game's exit was noticed at once.
- Mid-session game: a fake game with a stock libzmq.dll was patched 20 s after it
  appeared (15 s quiet fallback) and got its DXVK override; removed afterwards.

## Still open (needs the monitor or the owner)
- Fullscreen size and cursor reach on screen after a display change (the Mac was
  locked; the owner confirmed the cursor fix on 10/28).
- Monitor connect, alignment views, arming in a Studios round, Driving Range x3, real
  shots, TetherKit idle CPU with the patched build, a real USB stall, a real Wine crash
  from a monitor power cycle.
