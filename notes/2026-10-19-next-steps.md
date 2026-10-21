# 10/19/2026 — Next steps: usability and runtime

Review of the repo plus today's logs (`~/Library/Logs/RapsodoGolf-Wine.log`, the
game's `Player.log`) and running processes. Ranked by how much each blocks
actually playing.

## Evidence from today

- The app has been running since 12:12, started from the Dock/Finder launcher
  (`~/Applications/Rapsodo Golf (Wine).app`, the known-broken route). No USB link
  was started (no `RapsodoGolf-usblink.log`, no `feth0`), so for 4+ hours every
  scan returned `0 device(s) discovered`.
- Driving Range was played twice from the app (16:10–16:20 after the DXVK fix). It
  rendered, but logged `User device does not exist in scan result`.
- **All three games ship their own copies of both buggy files the app needed
  patched**, in `games/<id>/<ver>/<Game>_Data/Plugins/x86_64/`:
  - `libzmq.dll`: sha256 `6cdd06bf…`, byte-identical to the app's original
    (unpatched) libzmq 4.3.5;
  - `deviceManagerServer.dll`: still has the one `SIO_UDP_NETRESET` site
    (`bb0f000098`) that `patch_devicemanager.py` rewrites.
  The game runs its own device manager (the app's reports "device manager exited"
  while a game is open), so with the monitor connected, the game will most likely
  hit the same connect hang and auth failure the app had.
- Log flood: the game writes ~517,000 MoltenVK lines
  (`VK_ERROR_OUT_OF_POOL_MEMORY: VkDescriptorPool exhausted`, normal for DXVK on
  MoltenVK) into the app log — 86 MB in one 10-minute session.

## Ranked next steps

| # | Step | Why | Effort |
|---|---|---|---|
| 1 | **Done 10/19/2026:** `40-apply-patches.sh` now patches each game's `libzmq.dll` and `deviceManagerServer.dll` (all 3 games: zmq sha256 `a883a6ca…`, NETRESET 0 / CONNRESET 2). Driving Range still starts and its device manager runs. | Still unverified with the monitor connected. | test with the monitor |
| 2 | **Built 10/19/2026, not yet installed/tested:** `60-install-usb-daemon.sh` (sudo) installs the USB link as LaunchDaemon `local.rapsodo-golf-mac.usb-link` from root-owned copies; the Dock app's executable is now `open-in-iterm`, which runs `play.sh` in iTerm. | Dock icon was the natural start and silently couldn't connect. | owner: run the installer once, then double-click |
| 3 | **Done 10/19/2026:** `play.sh` runs `40-apply-patches.sh` + `45-install-dxvk.sh` before launch (3.6 s; log `~/Library/Logs/RapsodoGolf-heal.log`) and prints a power-button hint after 60 s of waiting. | Updates and new games undo the patches. | — |
| 4 | **Done 10/19/2026:** `launcher.c` sets `MVK_CONFIG_LOG_LEVEL=1` and `DXVK_LOG_LEVEL=warn`; a test game run wrote 1.7 KB to stdout, 0 MoltenVK warnings. | — | — |
| 5 | **Play-test and tune the game.** One Driving Range session with shots. Measure FPS with `DXVK_HUD=fps`, and try `DXVK_ASYNC=1` (this async build supports it) if shaders stutter. | DXVK rendering is verified; play with shots is not. | ~30 min with the owner |

## Added 10/19/2026

- **Location prompt fixed:** `scripts/geolocation_stub.c` replaces each game's `GeolocationPlugin.dll`; Driving Range logs `Location permission status: Allowed` and the configured position.
- **Monitor drop-outs** are now the blocker for play: `notes/2026-10-19-monitor-drops-during-play.md`.
- **Music:** saved in encrypted `SavedSettings`; set it in-game.
- **10/20/2026 location default:** with no position (`GetLocation` ok=false) Driving
  Range shows "Network access required"; with any position it doesn't. So `env.sh`
  defaults to a 0/0/0 placeholder and personal values live in the gitignored
  `scripts/env.local.sh`.
- **Elevation:** Driving Range's Settings → Required → Elevation read 6562 ft
  (= 2000 m, the `elevation: 2000` in its session info) even with a sea-level
  position, so the location doesn't set it. Set it by hand or carry reads long.

## Later

- **Rosetta deadline:** this Wine is x86_64 and runs through Rosetta 2, which loses
  general app support in macOS 28. Spike a Windows 11 ARM VM with USB passthrough
  of `2207:0019` before then. Don't upgrade to macOS 28 until that works.
- **Monitor-wait message:** `play.sh` waits forever if the monitor is off. After 60 s,
  print "press the monitor's power button" (it powers off when idle).
