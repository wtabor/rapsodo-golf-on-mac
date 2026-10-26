# Wine's server crashes during a game and freezes everything (10/26/2026)

First seen when the monitor came back during a game (10:38); the second crash
(13:18) had a steady link, so the monitor isn't required. File name kept for links.

## Symptom
The owner was in Rapsodo Studios Golf (courses mode) with the monitor off, turned it
on, and the app and the game froze: the game stayed on "Align your MLM2PRO… Device
disconnected" with its on-screen clock stopped, and nothing responded.

## What happened
- **wineserver segfaulted** at 10:38:32. Its own SIGSEGV handler printed
  `wineserver crashed, please enable coredumps (ulimit -c unlimited) and restart.`
  The line landed in `~/Library/Logs/RapsodoGolf-heal.log` because the `wine reg`
  in `45-install-dxvk.sh` had started that server, so it inherited the heal log as
  stderr.
- That line is a real SIGSEGV inside wineserver, not an assert or SIGBUS. In Wine
  11.16 only `do_sigsegv()` prints it
  ([server/signal.c](https://gitlab.winehq.org/wine/wine/-/blob/wine-11.16/server/signal.c#L203)),
  and that handler is installed only for SIGSEGV and only when the core limit is 0
  (the macOS default). It calls `abort()`, and wineserver's SIGABRT handler calls
  `exit(1)` ([server/main.c](https://gitlab.winehq.org/wine/wine/-/blob/wine-11.16/server/main.c#L216)).
  So the server exits normally with status 1, which is why macOS wrote no crash
  report. The installed binary matches (checked with `otool`), and no wine-staging
  11.16 patch touches these files.
- Every Wine process needs the server for nearly everything, so all of them (app,
  renderer, device manager, game, crash handlers) stalled for good: still in `ps`
  at 0% CPU, windows still drawn. None exits on its own. That's known upstream:
  [WineHQ bug 57608](https://bugs.winehq.org/rest/bug/57608/comment) (open) asks for
  clients to be killed after a server crash, and Wine's maintainer rejected doing it
  from the crash handler.
- Opening the app again didn't help: play.sh saw `RapsodoGolf.exe` running and said
  "already running", and `wineserver -k` can't reach the processes of a dead server.

| Time | Event (USB link log, app log, game `Player.log`, macOS log) |
|---|---|
| before 10:29 | Monitor off (idle power-off) |
| 10:36:38 | play.sh starts Wine |
| 10:37:34 | App hands over to the game (stops its device manager) |
| 10:37:40 on | App runs `cmd /c tasklist` every second (its "game is running" check) |
| 10:38:15–17 | Monitor on: USB enumerates, TetherKit creates `feth0` |
| 10:38:23 | DHCP bound on `feth0` |
| ~10:38:25 | Game finds the monitor, enters `DeviceConnectingState`; Arm/Disarm fail "Transport not connected" |
| 10:38:29 | Monitor resets USB (`LIBUSB_ERROR_OTHER`, then `NO_DEVICE`); `feth0` stays up with a dead link |
| **10:38:32.68** | **wineserver gone** |
| 10:38:42 / :46 | TetherKit declares the link dead, then reconnects |

## Checked
- **Process churn alone doesn't do it.** While any game runs, the app spawns
  `cmd /c tasklist` once a second (`app.asar` main.js: `Lae()`, interval `Pae = 1e3`),
  which is 3 short-lived Wine processes per second (cmd, conhost, tasklist). Test A: Studios game
  connected to a steady monitor for 6.5 min (10:48:22–10:54:50, ~390 cycles), no
  crash.
- **A USB drop alone didn't do it on 10/19:** the monitor left USB mid-Range and
  wineserver survived (`notes/2026-10-19-monitor-drops-during-play.md`).
- **App-only power cycle, no crash (11:31–11:35):** with only the app open (no game),
  the monitor was turned off (ZMQ disconnect 11:31:24, USB gone 11:31:42) and back on
  (USB 11:34:55, DHCP 11:35:02, app reconnected 11:35:45). wineserver survived. The
  monitor came back without a USB reset this time.
- **Game open, two monitor resets, no crash (13:10–13:14):** Studios game (Courses)
  started 13:10:48. The monitor reset USB at 13:10:56 (`LIBUSB_ERROR_PIPE`, while the
  game was connecting) and again at 13:12:46; TetherKit relinked each time (13:11:16,
  13:13:05). Same wineserver pid throughout. The game logged "System busy. Can not
  execute discoveryCommand" on several reconnects, then was connected again by 13:14.
- So the crash is **intermittent**: one crash in four monitor drops with Wine running
  (10:38 crashed; 11:31, 13:10, 13:12 didn't).

## Second real crash, monitor steady (13:18:08)
- New session: app 13:16, Studios game (Courses) started ~13:16:40, on hole 1 in
  `IGolfShotReadyState`. **No USB event at all from 13:15 to 13:19** (steady traffic),
  so a power cycle is not needed.
- The game's last lines: its device manager loops on `System busy. Can not execute
  discoveryCommand` (Arm/Disarm), and `[DeviceAlignmentStream][Controller] Camera 0 did
  not return a stream url` (`StartBallFindingCamera`). The 10:38 crash also happened
  on a camera screen ("Align your MLM2PRO").
- **Recovery worked:** play.sh (started from the Dock, so iTerm) caught it, saved
  `*-crashed.log`, and the fresh app was starting at 13:18:13.
- **Crash report** (`/Library/Logs/DiagnosticReports/wineserver-2026-10-26-131808.ips`):
  `EXC_BAD_ACCESS` / SIGSEGV at address `0x58`, main thread. Faulting code at vmaddr
  `0x100013878`:
  `mov 0x48(%rdi),%rax ; mov 0x58(%rax),%rax ; test ; je default ; jmp *%rax`, a
  dispatcher that calls an operation from a table at `+0x48` of the object in `rdi`.
  That table pointer was NULL. Frames: main loop (`0x1000117c8`, calling an fd's
  `poll_event`) → a function with socket-flag bit tests (`0x100040b32`, after
  `call 0x100043c10`) → the dispatcher.

## The bug in Wine (mapped to wine-11.16 source)
Disassembly matched to the source by struct offsets, constants and debug strings
(`struct object` is 0x48 bytes here because `DEBUG_OBJECTS` is on), then re-checked by a
skeptical second pass:

```
main → main_loop (kqueue; fd_poll_event inlined)          server/fd.c
  → sock_poll_event                    [0x10003f9b0]   server/sock.c:1388
    → complete_async_polls (inlined)                    sock.c:1211
      → complete_async_poll(req, 0)    [0x100043c10]   sock.c:1138
        → async_request_complete (tail call)            server/async.c:468
          → async_terminate (tail call) [0x1000008c0]  async.c:213
            → async_reselect (inlined)
              → fd_reselect_async(async->fd, queue) [0x100013870]  fd.c:2258
                  fd->fd_ops == NULL → load of ->reselect_async (+0x58) faults
```

- `async->fd` points at a **freed** `struct fd` (a socket fd always has
  `fd_ops = &sock_fd_ops`; macOS zeroes freed blocks, wiping Wine's 0xaa poison).
- A pending `IOCTL_AFD_POLL` (from `select`/`WSAPoll` or similar) parked on a socket's
  `poll_q` keeps only a borrowed pointer to that socket's fd (`queue_async` releases its
  reference). It is cleared only when the socket itself is destroyed. In 11.16 the
  only code that frees a *live* socket's fd is the fd swap in `accept_into_socket`
  (an `AcceptEx` completing) and `init_socket`; neither re-points queued asyncs. So
  the most likely sequence is an `AcceptEx` completing on a socket that also had a
  pending poll queued, then a later event completing that poll. Which program in the
  game (libzmq, FFmpeg's RTSP, the Go device manager) does that isn't identified.
- **Not tied to the monitor:** the 13:18 crash had a steady USB link the whole time.
  No later upstream commit (through 10/15/2026) changes this code; wine-staging's
  patches don't touch it. No Wine setting avoids it.
- A source fix is small (~20 lines: re-point queued asyncs to the new fd before
  releasing the old one in `accept_into_socket`/`init_socket`), but it needs a
  rebuilt wineserver. Next step for confirming the freeing path: start the server
  ourselves with `-d1` (it logs `completing accept request for socket %p` and
  `completing poll for socket %p`); `WINESERVER=` can't wrap it, because ntdll only
  falls back to that variable when `bin/wineserver` fails to start.
- **Not an interface watcher:** wineserver on macOS doesn't monitor network
  interfaces. Its interface-change code is Linux netlink only; on macOS `get_ifchange()`
  returns `STATUS_NOT_SUPPORTED`
  ([server/sock.c](https://gitlab.winehq.org/wine/wine/-/raw/wine-11.16/server/sock.c)).
  Address changes are handled in `nsiproxy.sys`, inside a Wine process. A dying
  `feth0` can reach wineserver only as errors on sockets it holds (kqueue
  `EV_EOF`/`EV_ERROR` → `sock_poll_event`) or through client requests. No known Wine
  bug matches; the closest are socket asserts (bugs 53952, 56988, 60097), which print
  different output.
- **Process churn:** a known macOS wineserver crash from starting processes in a loop
  ([MR 5291](https://list.winehq.org/hyperkitty/list/wine-gitlab@list.winehq.org/thread/2QA2LGN6W4BLLL6R333UBOZBSJEK7B5A/),
  a `sendmsg` fd-passing race) was fixed in Wine 9.5, so 11.16 already has the fix.
- **No debugger or core dump** (at the time of the first crash): wineserver is
  stripped (157 symbols), `/cores` is root-only, and Developer Mode is off. The crash
  site was later derived from the 13:18 crash report plus disassembly (section above).
- `kill -SEGV <wineserver pid>` reproduces the symptom exactly: same message, no
  crash report, every process frozen.
- **Crash reports from now on:** with any core limit above 0, Wine skips its SIGSEGV
  handler and the crash is a real signal death. A test server killed with SIGSEGV
  under `ulimit -c 1` left `~/Library/Logs/DiagnosticReports/wineserver-*.ips`
  (translated x86_64, faulting-thread frames as `wineserver` offsets) and no core
  file. play.sh now sets `ulimit -c 1` before any Wine process starts, so the next
  real crash shows where it faulted. Under play.sh the reports went to
  `/Library/Logs/DiagnosticReports/` instead; Console's Crash Reports view lists both.

## Fix: recover instead of freezing (`scripts/play.sh`)
- **Detect:** the background watcher checks every 2 s. If the launcher is still
  running but this install's wineserver is gone (checked twice, 1 s apart), Wine has
  crashed. After the app exits it checks once more: Wine processes left with no
  server means the same thing.
- **Find the processes:** every process of this Wine install maps
  `share/wine/nls/locale.nls`, so `lsof -t` on that file lists all of them, and only
  them, even after the server died (0.35 s).
- **Recover:** `kill -9` them, copy `RapsodoGolf-Wine.log` and `RapsodoGolf-heal.log`
  to `*-crashed.log` (the next start truncates both), and start play.sh over. At most
  3 times per session (`RGM_WINE_RESTARTS`), and without a second update check
  (`RGM_UPDATED=1`).
- **Startup:** if `RapsodoGolf.exe` is running but has no server (checked twice,
  2 s apart), it's a frozen session: save its logs, close it and start normally. Also
  after `wineserver -k`, kill whatever it couldn't reach. A crash while the app is
  still starting ends the 120 s startup wait early instead of sitting it out.
- **Details from review:** the server is matched by its resolved path (`pwd -P`),
  because Wine starts it via realpath, so a symlinked `RGM_HOME` would otherwise make
  every healthy session look crashed. The watcher tracks the app's own server pid:
  after a crash, a `wine reg` from the new-game patch step would start a fresh
  server that could hide the crash. The patch step is skipped while that server is
  down, and runs in the background so the crash check keeps going.

Tested 10/26/2026 (monitor connected). First version:
1. SIGSEGV under the app and the Studios game, then play.sh: "The last session froze
   (Wine crashed)", everything killed including the game, app up again in ~35 s.
2. SIGSEGV under play.sh's own app: detected, closed, logs kept, up again in 16 s.
3. Normal close (`taskkill` sends WM_CLOSE): play.sh exits after 2 s, no restart,
   Wine shuts down normally.

Final version (after review fixes and `ulimit -c 1`):
- Crash during app startup: caught, restarted, up again in 19 s.
- Crash under the running app: restarted ("2 of 3"), up again in 14 s.
- Normal close: play.sh gone within 1 s, no restart.
- Unwatched frozen session (play.sh killed, then SIGSEGV), then play.sh: logs saved
  (the copy has the frozen session's startup), cleaned up, up again in 17 s.
- Each crash left a `wineserver-*.ips`; none printed the old "wineserver crashed"
  line, so the handler was skipped as intended.
- Path check: `RGM_HOME` through a symlink, or with a trailing slash, resolves to the
  same path Wine uses.

Not tested: a real crash from a monitor power cycle with the new play.sh.

## Next
- Reproduce: Studios game connecting, then power-cycle the monitor. If it repeats,
  read the faulting offset from the new `wineserver-*.ips`, map it to the source by
  disassembling the installed wineserver, and try once with the `tasklist` churn
  removed.
- If it reproduces, report it to Wine with the crash report.
