# rapsodo-golf-mac

Run Rapsodo's Windows-only **Rapsodo Golf** PC app (1.0.0) on an Apple Silicon Mac,
connected to an **MLM2PRO** over USB-C. Verified 10/19/2026 on macOS 26.6.2 (M4):
the app connects, authenticates, and ran a firmware update (4.1.9 → 4.1.19).

This is an unofficial, open-source community project, not affiliated with or
endorsed by Rapsodo. It holds scripts and patches only and ships no Rapsodo
binaries, icons or other assets: you supply the installer (`RapsodoGolfSetup.zip`)
and your own Rapsodo account, and every patch is applied locally to your own copy.
Use it at your own risk; a Rapsodo update can break it at any time.

## How it works

| Layer | Piece |
|---|---|
| Windows runtime | [Gcenx wine-staging 11.16](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.16) (unsigned build) |
| USB-C link | The MLM2PRO is a USB **RNDIS** network gadget (`2207:0019`). macOS has no RNDIS driver, so [TetherKit](https://github.com/XiaoMiku01/TetherKit) (userspace, no kext) bridges it. The monitor runs DHCP: it's `192.168.36.1`, the Mac gets `192.168.36.x`. |
| Fix 1 | Rebuilt `libzmq.dll` (4.3.5) without the 1 MB loopback "slow start" send that deadlocks under Wine → [`patches/`](patches/libzmq-4.3.5-no-fdpair-slowstart.patch) |
| Fix 2 | 1-byte patch in `deviceManagerServer.exe`: Go's `SIO_UDP_NETRESET` (unimplemented in Wine) → `SIO_UDP_CONNRESET`, so the CoAP certificate request and authentication work → [`scripts/patch_devicemanager.py`](scripts/patch_devicemanager.py) |
| Fix 3 | Unity games (Driving Range etc.) need D3D11; Wine's wined3d can't create the device on macOS. [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) (D3D11 → Vulkan → MoltenVK) is enabled per game exe → [`scripts/45-install-dxvk.sh`](scripts/45-install-dxvk.sh) |
| UI | Electron runs with `--no-sandbox --disable-gpu --disable-gpu-compositing --in-process-gpu` |

Full investigation: [notes/2026-10-19-rapsodo-golf-pc-app-on-mac.md](notes/2026-10-19-rapsodo-golf-pc-app-on-mac.md).

## Install

```bash
brew install mingw-w64 cmake libusb
```

```bash
scripts/install.sh ~/Downloads/RapsodoGolfSetup.zip
```

Installs into `~/Library/Application Support/RapsodoGolf-Wine11/` and creates
`/Applications/Rapsodo Golf (Mac Port).app`.

## Play

1. Plug the MLM2PRO into the Mac with USB-C and power it on.
2. Double-click `/Applications/Rapsodo Golf (Mac Port).app` (or run `scripts/play.sh`
   in iTerm). The app opens an iTerm window and runs `play.sh` there; if Rapsodo is
   already open it just says so. Rebuild the app (icon included, taken from the
   installed Rapsodo app) with `scripts/50-make-launcher.sh`.

`play.sh` starts the USB link (needs administrator rights; see below), re-applies the Wine fixes (~4 s; they're undone by Rapsodo updates
and new game downloads), waits for the monitor, then opens the app.

**Why iTerm:** the Rapsodo app finds the monitor over mDNS, which macOS's Local
Network privacy allows only for apps with permission. Wine's unsigned binaries
never get the prompt, so the app has to inherit permission from a terminal that has
it (System Settings → Privacy & Security → Local Network → iTerm on). The first
open asks once to let the launcher control iTerm (macOS lists it as `bash` under
System Settings → Privacy & Security → Automation). If you miss that prompt the app
shows "Could not open iTerm"; open it again.

### Administrator rights for the USB link

macOS has no driver for the MLM2PRO's USB network connection, so
[TetherKit](https://github.com/XiaoMiku01/TetherKit) (userspace, libusb) provides it.
It has to take over the USB device and create the `feth0` network interface, which
macOS allows only as root. Pick one:

| Option | What you do each session | What runs as root |
|---|---|---|
| **Password** (default) | type your Mac password when `play.sh` asks | TetherKit, only while you play |
| **Touch ID** (recommended) | touch the sensor instead | same as Password |
| **LaunchDaemon** | nothing | TetherKit, always (from boot) |

**Touch ID for `sudo`** uses Apple's own `sudo_local` hook ([macOS 14 Sonoma and later](https://sixcolors.com/post/2023/08/in-macos-sonoma-touch-id-for-sudo-can-survive-updates/)), which
survives system updates and applies to every `sudo` on your Mac, not only this
project:

```bash
sudo sed 's/^#auth/auth/' /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local
```

Check it with `sudo -v` in a new terminal tab (you should get a Touch ID prompt).
Undo with `sudo rm /etc/pam.d/sudo_local`. It falls back to the password when Touch
ID isn't available (lid closed, external keyboard without Touch ID).

**LaunchDaemon:** no prompt at all, but a small third-party USB driver then runs as
root all the time, which is more attack surface (e.g. a malicious USB device posing
as the monitor). It runs root-owned copies in `/usr/local/libexec/rapsodo-golf-mac/`,
logging to `/Library/Logs/RapsodoGolf-usblink.log`.

```bash
sudo scripts/60-install-usb-daemon.sh              # install
sudo scripts/60-install-usb-daemon.sh --uninstall  # remove
```

**After a macOS update:** updates can remove Rosetta 2, which Wine needs (macOS
27.0.1 did). `play.sh` stops and tells you; reinstall it with
`softwareupdate --install-rosetta --agree-to-license`, and allow the iTerm prompt
again if it reappears.

If the app says "Device not found", check the USB link log for
`feth0 DHCP (re)requested` and retry. After a replug the monitor can take
~60 seconds (or a power-button press) before it answers DHCP.

**Games:** the location prompt ("Unable to get location permission state") is
answered by a stub `GeolocationPlugin.dll` that reports a fixed position from
`RGM_GEO_LAT` / `RGM_GEO_LON` / `RGM_GEO_ALT`. Set yours once:
`cp scripts/env.local.sh.example scripts/env.local.sh` and edit it (gitignored).
Without it the games get a 0/0 placeholder. The game's own **Elevation** setting
(Settings → Required) is separate and drives ball flight; set it to your altitude.
Turn game music off in the game's own settings; it's saved encrypted, so it can't
be set from outside.

## After a Rapsodo app update

`play.sh` re-applies everything on each launch. To do it by hand (each game ships
its own `libzmq.dll`, `deviceManagerServer.dll` and `GeolocationPlugin.dll`):

```bash
scripts/40-apply-patches.sh
```

After the app downloads a new game (or game version), or if a game says
"Failed to initialize player / DirectX 11":

```bash
scripts/45-install-dxvk.sh
```

## Known limits

- The first authenticate after launch can time out; the app's automatic retry succeeds.
- Shots, alignment and the camera view have only been confirmed by the owner, not instrumented.

## Open source

- **No Rapsodo files in this repo.** `.gitignore` blocks `*.exe`, `*.dll`, `*.zip`;
  patched DLLs and the app icon are produced on your Mac at install time.
- **Third-party pieces** are downloaded or built from their own projects, under
  their own licenses: [Gcenx's Wine builds](https://github.com/Gcenx/macOS_Wine_builds),
  [TetherKit](https://github.com/XiaoMiku01/TetherKit),
  [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) and
  [libzmq](https://github.com/zeromq/libzmq) (rebuilt with the patch in `patches/`).
- **Your location** for the games comes from `RGM_GEO_*`; put yours in the
  gitignored `scripts/env.local.sh`, never in `env.sh`.
- **License:** not chosen yet.
