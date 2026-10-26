# Rapsodo Studios Golf: monitor won't arm, and the Mac is overloaded (10/26/2026)

## Symptom
In Rapsodo Studios Golf (Courses), ball alignment "kind of works for a second" and no
shots register. Two sessions (13:16 and 13:19) logged, after a normal connect and
session start:
- every `ArmDevice`/`DisarmDevice` failing with `ExecuteCommand ERROR: System busy. Can
  not execute discoveryCommand` (13998) or `sendCommandWait ERROR: Timeout waiting for
  cmd APICommand::ArmDevice` (13999): 14 busy and 11 timeouts in the 13:19 session;
- `[DeviceAlignmentStream][Controller] Camera 0/1 did not return a stream url` (8×);
- `armed=0`. The game never reached ready-to-shoot.

## Control tests
- **Driving Range, 13:52 (clean app, USB link restarted):** connected, authenticated,
  started a session and **armed** (`DeviceArmed`); both camera streams started with
  URLs (`:554/rapsodo/live` 768x720 20 fps, `:1554/rapsodo/impact` 640x480 5 fps);
  re-armed after its Settings menu. No shot was taken (none possible at the time).
- **Studios, 13:56 (same clean session):** one `System busy` on the first Arm, then
  `Device armed`, `BallStatus Device NotReady -> Armed`, `Strip NotReadyToShot ->
  ReadyToShot`. So Studios *can* arm under Wine.
- An earlier Range launch (13:31) never got its in-game device manager up: `Server not
  ready yet (Internal)` every 30 s for 6 min, nothing listening on :9090.

## Mistakes and side issues found on the way
- **Two Studios copies:** at 13:58 a DevTools `runGame` from this session started a second
  copy while the owner's (13:56) was running. Killed. Don't launch games over DevTools
  without checking `pgrep -f RapsodoStudiosGolf` first.
- **A test loop restarted Wine under the owner (14:58:40):** a scripted frame-cap A/B
  (restart app with `DXVK_FRAME_RATE`, launch Studios, measure) ran while the owner was
  using the app; they closed its Studios and opened the Range, and the loop's next run
  did `wineserver -k`, killing their Range session. Scripted restarts must check that
  nobody is using the app (no game they started, no recent UI activity) and must not be
  chained in a loop that survives killing one run. The frame cap stays untested.
- **USB link killed with a Claude session:** `usb-link.sh` had been started in a Claude
  terminal tab; when that session closed (13:37:42) TetherKit got a shutdown signal
  and the monitor link stayed down. Restarted detached (`sudo -v && (nohup sudo
  usb-link.sh >> log &)`). play.sh's own start (`sudo ... &`) is tied to its terminal too.

## Resources (16 GB Mac, 13:59–14:02)
- Studios' footprint ~7.7 GB (top MEM); the app ~0.8 GB.
- Swap 9.4 of 10 GB used, PhysMem 15 GB used with 211 MB free, load average 28, CPU
  0% idle while Studios ran. A JetsamEvent (memory pressure) was logged at 12:50.
- TetherKit ~1 core all the time (seen before; no tuning option for idle polling).
- macOS `ecosystemd` ~0.9–1 core and `trustd`: ~18 Rosetta "GAME_CHECK"/code-signature
  analyses per second of Wine's processes, failing on ad-hoc signatures, even with no
  game running. (Later shown to be the backlog from the games' 1 s `tasklist` polling
  still draining; see "Load reduction" below.)
- The app spawns `cmd /c tasklist` (3 Wine processes) every second during a game.

Not established: that load causes the `System busy`/timeouts. Plausible (command
timeouts under heavy paging), but Studios armed at 13:56 under similar load.

## Why Studios didn't arm at 13:19 (log + libRDCLib analysis)
- **"System busy" is a side effect.** It comes from `libRDCLib.dll` (identical in the
  app, the Range and Studios): `GolfMediator::sendCommand` runs one command at a time
  (an atomic "current command" field) and answers anything that arrives meanwhile with
  Status 8 `System busy. Can not execute discoveryCommand` ("discoveryCommand" is
  copy-pasted text; discovery isn't involved). `ArmDevice`/`DisarmDevice` wait up to
  10 s for the monitor's reply, so every unanswered one blocks the next 10 s, including
  the ball-finding camera start (that's "Camera N did not return a stream url").
- **The real failure was the monitor.** The game's own SDK log (`rdc.log` beside its
  Player.log) shows the monitor at DeviceParams `State 4` (armed) when the 13:19 game
  connected: a session left by the 13:16 game that died in the 13:18:08 wineserver
  crash. `StartSession` on top of it produced Armed, Disarmed ×2, SessionStarted and
  both streams stopping, then `State 0`, after which the firmware silently dropped
  every Arm/Disarm (its global event counter stayed continuous: no result sent to
  anyone). Camera commands and DeviceParams kept working. Clean sessions (Range 03:21
  and 13:52, Studios 13:56 and 14:19) connect at `State 1` and arm in 0.3–0.5 s.
- `State 0` cleared by 13:27 without a monitor reboot (same RNDIS MAC, event counter
  still counting), after the game exited and the monitor dropped off USB. Which of the
  two cleared it is unknown, and the firmware sometimes drops a dead client's session
  on its own within ~15–20 s and sometimes doesn't. One sample; not reproduced.
- Not explained: the 13:16 session (clean `State 1` start) already showed 5 busy
  replies and no `Device armed` before the crash.
- **No shot event in any log today** (no `ShotTriggered`/`MLMClubDataAlgoEnd`, which
  libRDCLib handles). No ball was hit in any of these sessions, so shots are unproven.

## Load reduction: fewer Windows processes (`scripts/patch_app_polls.py`)
- macOS `ecosystemd` runs about **15 Rosetta/code-signature checks per Windows process
  start** (a `cmd /c netsh` burst of 3 processes cost ~46 checks) and manages only
  ~20–25/s (one thread, ~40 ms per check; ~18/s measured at one core).
  With the app starting 3 processes/s during games (`cmd /c tasklist` every 1 s) it fell
  behind: ~1 core busy, still draining its queue 7 minutes after the game closed (14:01
  to 14:08, with no Wine process running; CPU dropped to 0 when the queue emptied).
- Two same-length `app.asar` edits, applied by `40-apply-patches.sh` (warn only,
  `--revert` restores the original byte-for-byte):
  - game check `Pae = 1e3` → `6e4` (1 s → 60 s; measured below at 10 s, changed to 60 s
    before anything shipped). The app already learns the game closed from the exit of
    the `cmd /c` child that started it; the poll is a fallback.
  - Wi-Fi poll `WIFI_INTERVAL_TIME=15e3` → `36e5` (15 s → 1 h). `netsh wlan` has no data
    under Wine (the monitor is on USB), so it always came back empty.
- Measured (60 s windows, after ecosystemd's queue emptied):

  | | new Windows processes | ecosystemd | ecosystemanalyticsd | trustd |
  |---|---|---|---|---|
  | App idle, unpatched (14:10–14:14) | ~1 burst of 3 per 15 s | ~4.6 checks/s | | |
  | App idle, patched (14:17) | 0 | 0% (4 checks/min) | 0% | 0.1% |
  | Studios, unpatched (13:59 top) | 3/s | 55% (then ~90% for 7 min) | 45% | 23% |
  | Studios, patched (14:23) | 0.2/s | 9.6% | 3.1% | 3.0% |

  The unpatched Studios row is a `top` snapshot, not the same 60 s probe. Still large:
  the game itself (~150% of a core) and TetherKit (~80–95%).
- Why ~15 checks per process: ecosystemd analyzes each x86_64 Mach-O image Rosetta loads
  (ntdll.so, win32u.so, libfreetype, libz, libpng, brotli, ...), single-threaded at
  ~40 ms each. Signing differently or Info.plist flags wouldn't remove that work.

## Load reduction: TetherKit (`patches/tetherkit-rx-idle-sleep.patch`)
- One thread (`Bridge::RunReceiveInjector`) never blocked: with its receive ring empty
  it spun 64 times, called `std::this_thread::yield()` and started over. On macOS
  `sched_yield()` returns at once when nothing else wants the core, so it sat at ~100%
  of a (USER_INTERACTIVE, so P-) core with no traffic. No flag controls it; upstream
  v0.1.5 is the latest and identical. The patch sleeps 500 µs instead of yielding.
- `build-tetherkit.sh` applies it idempotently (`git apply --check`, else
  `--reverse --check`, else fail) and installs the binary by rename.
- Measured with the monitor (USB link restarted 14:40:01 on the patched binary):

  | | before | after |
  |---|---|---|
  | Idle (no traffic) | 96–99% of a core | 1.3% |
  | Range connected + armed, tracking data only (~7 pps) | ~83% | 1.2% |
  | App alignment, both cameras streaming | ~80–90% | 3.9% |

  While streaming: RX 680–690 pps / 7.4 Mbps, 0 dropped, 0 kernel drops; the Shot
  Vision view played 603 frames in 30 s (20.1 fps), 0 dropped. The Range armed normally
  through it (14:41:45). Offline benchmark of the real bridge code: +~0.6 ms RX latency
  at p99, 0 ring drops at 50 kpps.

## Driving Range crashes at 15:01 and 15:07: the external display was unplugged
- WindowServer: `Inserting hotplug event for state "out", display id: 2` at **15:01:04**
  (the BenQ, 3840x2560). The Range crashed at 15:01:18, and again 16 s after a launch
  at 15:07:33, both with exit `0xC0000005`.
- Player.log: `Screen: Display Data Changed`, then `ArgumentException: RenderTextureDesc
  width must be greater than zero` (URP `RTHandleSystem.CreateRenderTexture`), then
  `ArgumentNullException` in `ColorGradingLutPass` → `Blitter.BlitTexture`, then the
  native crash in UnityPlayer/GameAssembly. The Range is saved to fullscreen at
  3840x2560 native (`Screenmanager ...` in `HKCU\Software\Rapsodo\DrivingRange`), so with
  only the 3024x1964 built-in display left it ends up rendering at width 0.
- Not caused by today's patches: the 13:52 and 14:41 Range runs (same patches except
  the 60 s game check) logged the same `Display Data Changed` with the BenQ attached and
  worked. The DXVK `Failed to compile pipeline` errors (geometry/tessellation stages
  MoltenVK can't do) appear 9–10× in working runs too.
- The 15:08 launch then sat on its blank loading screen with `Server not ready yet
  (Internal)` from its in-game device manager, the same as at 13:31 (before the poll and
  TetherKit patches existed). Intermittent; cause not found yet.

## Test matrix before committing (play.sh recovery, Fix 7, Fix 8)
Done so far is marked; everything else must pass before a commit.
1. [x] Dock launch (`open -a "Rapsodo Golf on Mac"` → iTerm → play.sh), twice (15:29,
   15:30): device manager up 14 s after the click, heal log "game check: already patched",
   "Wi-Fi poll: already patched", connected to the monitor; normal quit → play.sh gone in
   2–3 s, no restart, no Wine processes left, `*-crashed.log` untouched.
2. [x] Crash recovery on final code: crash during startup, crash while running, normal
   quit, unwatched frozen session (T2–T6, 11:18–11:21). [x] Under a Dock launch: SIGSEGV
   15:30:35 → app relaunched 15:30:40 (same play.sh pid, exec) → connected 15:30:50; both
   `*-crashed.log` saved; a new `wineserver-*.ips`.
3. [x] Studios ×4 (one copy each, `pgrep` first; runs 1, 3, 4 patched, run 2 with the
   poll patch reverted as a control): connected 23–27 s after launch, session started,
   `System busy` 0, timeouts 0, disconnects 0, no DM-not-ready; quit → app logged
   `game closed` 2–5 s later (exit event); run 4 was a second game in the same app
   session. [ ] `Device armed` → `ReadyToShot` needs a round started in the game (owner;
   the game window can't be driven from here).
   Found: after any game closes, the app restarts its device manager but **does not
   reconnect to the monitor by itself** (none within 120 s in all 4 runs, none in 22 min
   at 14:24). Same with the poll patch reverted (run 2), so it's existing behavior, not
   a regression. The next game connects on its own; a UI reload reconnects the app.
4. [ ] Driving Range ×3, same checks. Needs the BenQ attached (its saved fullscreen
   resolution crashes the Range on the built-in display, see above).
5. [x] App alignment: both cameras, 20 fps, 0 dropped, clean teardown (14:47–14:49,
   patched TetherKit).
6. [x] Device popup opens without errors (15:40): monitor Connected, battery, "Ethernet
   Cable connected", firmware "Already Up to Date", "Align your device"; no JS errors.
7. [x] Load on the final build (60 s probes): app idle 15:38 — TetherKit 1.2%,
   ecosystemd 0%, 0 new Windows processes; Studios connected on its menu 15:47 — game
   147%, ecosystemd 1.9%, ecosystemanalyticsd 0.6%, trustd 0.8%, TetherKit 1.2%, 2 new
   Windows processes/min. [ ] Studios armed in a round (owner).
8. [ ] 15-minute armed session in Studios (needs a round: owner). Substitute run: the
   app's alignment stream (both cameras) for 15 min, 16:02–16:17, patched TetherKit.
   **The alignment view stalled after ~1.5 min**:
   - Link: TetherKit pid unchanged, CPU 1.5–3.9%, RX 672–689 pps until ~16:04:15, 0 RX/TX
     drops, 0 kernel drops, no USB errors or link drops in the window.
   - MediaMTX: `[session ...] destroyed: session timed out` for the shot publisher at
     16:04:00 (no data for its 10 s timeout, so the Wine ffmpeg stopped sending ~16:03:50),
     WebRTC reader closed; the shot ffmpeg then logged `Broken pipe` with no earlier
     input error. Data kept arriving at ~680 pps for ~25 s after its output stopped, so
     the stall is after the link (ffmpeg's encode/output or MediaMTX inside Wine).
   - The impact ffmpeg logged HEVC errors (`Invalid data found`, `Duplicate POC`) only from
     16:04:29, after the shot side had already died.
   - The 14:47 alignment run on the same build ran ~2 min with none of this; earlier runs
     were shorter. Long alignment streaming was never tested before today.
   - **A/B, 16:25–16:31:** alignment again plus native macOS ffmpeg pulling the same Shot
     Vision RTSP (no Wine) through the patched TetherKit for 6 min. Native: 7195 frames,
     20.01 fps, 0 dropped (18 HEVC "could not find ref" lines, all in the first seconds of
     joining mid-GOP). App view: 7751 frames, 0 dropped, ~20 fps the whole time. Link
     600–610 pps, 0 drops. No stall this time: the 16:04 stall is intermittent and on the
     Wine side, not the link.
11. [x] Final play.sh (after the review fixes) from the Dock, 16:32: connected; SIGSEGV →
    new `wineserver-*.ips`, app relaunched and reconnected; no "wineserver crashed" line
    (the soft core limit skipped Wine's handler); normal quit → play.sh gone in 2 s, no
    restart, nothing left running.

Review fixes applied after an independent review (16:10): `ulimit -Sc 1 2>/dev/null ||
true` (a hard core limit of 0, e.g. `ulimit -c 0` in a bash profile, would otherwise
abort play.sh under `set -e` before the app starts); build-tetherkit.sh notes when the
LaunchDaemon's TetherKit copy differs (that copy never auto-updates); README "Always on"
says so; ecosystemd throughput corrected to ~20–25/s; CLAUDE.md and the crash note no
longer blame the monitor power cycle.

Still open before claiming "done": the Range ×3 (needs the BenQ), arming in a Studios
round, real shots, a long armed session.
9. [ ] Real shots in Studios and the Range (owner).
10. [x] `build-tetherkit.sh` with a scratch `RGM_HOME` (fresh v0.1.5 clone): patch applied
    once, builds, binary runs and lists the monitor; second run is a no-op. `--revert` of
    the poll patch restored app.asar byte-for-byte (15:52) and re-patching gave the same
    5-byte change.

## Next
- Test Studios with Chrome and other large apps closed (frees GBs of RAM/swap), hitting
  real shots.
- If `System busy` returns, capture the game's state then (Player.log, top, swap).
