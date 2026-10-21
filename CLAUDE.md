# CLAUDE.md — rapsodo-golf-mac

Runs Rapsodo's Windows-only **Rapsodo Golf** PC app (1.0.0, Electron) on an Apple
Silicon Mac with an **MLM2PRO** connected over USB-C. Scripts and patches only; no
Rapsodo binaries are ever committed (`.gitignore` blocks `*.exe`, `*.dll`, `*.zip`).

Read first: `README.md`, then `notes/2026-10-19-rapsodo-golf-pc-app-on-mac.md`
(full investigation, root causes, dead ends).

## Response style
- Answer in a few sentences. No preamble, no recap. Detail goes in `notes/`, not chat.

## Where things stand (10/19/2026)
- **Working:** app connects, authenticates, and updated the monitor firmware
  4.1.9 → 4.1.19 under Wine. The owner confirmed it works end to end.
- **Only confirmed launch route:** `scripts/play.sh` run from a terminal app that has
  Local Network permission (iTerm). It starts the USB link, re-applies the patches
  (`40`, `45`), and starts the app. The Dock app now hands off to iTerm running
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
- **Untested:** `scripts/play.sh` end to end, instrumented shot capture, alignment.

## How it works
- **Runtime:** Gcenx wine-staging 11.16 (unsigned; Homebrew's Wine casks were disabled
  09/01/2026). Installed under `~/Library/Application Support/RapsodoGolf-Wine11/`
  (`prefix/`, `build/`, `tetherkit-cli`). Paths live in `scripts/env.sh`.
- **USB link:** the MLM2PRO is a USB RNDIS gadget (Rockchip `2207:0019`). macOS has no
  RNDIS driver; TetherKit (userspace, libusb + `feth`) bridges it. The monitor runs
  DHCP: it is `192.168.36.1`, the Mac gets `192.168.36.x` on `feth0`.
  `scripts/usb-link.sh` (root) restarts TetherKit when the monitor re-enumerates and
  re-applies DHCP when macOS drops the temporary `ipconfig set` service.
- **Fix 1 — libzmq:** libzmq 4.3.5's `make_fdpair_tcpip` sends 1 MB over a blocking
  loopback socket before reading (zeromq #1608 workaround). Wine on macOS deadlocks.
  `scripts/30-build-libzmq.sh` cross-builds a patched DLL (mingw-w64 UCRT, CURVE via
  the app's own `libsodium-26.dll`, select poller, IPC off). 71/71 exports match.
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
- Game settings (`miniapp:Practice:SavedSettings`, incl. music) live in
  `C:\ProgramData\Rapsodo\SuperApp\app.db`: a plain Redis-style `set` log, but the
  values are encrypted.
- `launcher.c` sets `MVK_CONFIG_LOG_LEVEL=1` + `DXVK_LOG_LEVEL=warn` (games inherit
  them); otherwise MoltenVK logs ~86 MB per 10-minute game session.
- A Rapsodo app auto-update, or a new game download, undoes the patches →
  `scripts/40-apply-patches.sh`, then `scripts/45-install-dxvk.sh`.

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
- Drive the UI without clicking: launch with `--remote-debugging-port=9222` and use the
  Chrome DevTools Protocol; the renderer exposes
  `window.deviceManager.client.rdc.<Service>.<method>` (e.g.
  `DiscoveryAndConnectionService.scanTcpDevices(6)`).
- Wine socket tracing: `WINEDEBUG=+winsock`. Thread backtraces:
  `wine winedbg --command "bt all" 0x<wpid>` (`info proc` lists pids).
- `sudo` needs the owner's password: start root commands in a terminal tab for them
  to type it; never ask for the password in chat.

## Rules
- Never commit Rapsodo binaries, installers, or patched copies of them.
- Keep `scripts/` idempotent; re-run them rather than hand-editing the prefix.
- Lint shell with `shellcheck -x -e SC1091 scripts/*.sh` before committing.
- Add a dated `notes/YYYY-MM-DD-*.md` for any meaningful experiment, including failures.
