<div align="center">

<img src="docs/hero.svg" alt="Rapsodo Golf on Mac: the Windows-only PC app, running on your Mac" width="100%">

**[Install](#install)** · **[Play](#play)** · **[Troubleshooting](#troubleshooting)** · **[How it works](#how-it-works)**

![Tested on macOS 26 and 27](https://img.shields.io/badge/tested-macOS%2026%20%7C%2027-000?logo=apple)
![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-000?logo=apple)
![MLM2PRO over USB-C](https://img.shields.io/badge/MLM2PRO-USB--C-2ea44f)
![Status](https://img.shields.io/badge/status-beta-yellow)
![Unofficial](https://img.shields.io/badge/Rapsodo-unofficial-lightgrey)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

<a href="https://www.buymeacoffee.com/aerstrike"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black" alt="Buy me a coffee"></a>

</div>

## Your MLM2PRO, your Mac, no Windows PC.

Rapsodo only ships **Rapsodo Golf for PC** for Windows. This project runs it on an
Apple Silicon Mac under Wine, fixes the parts that break, and gives you a normal
Mac app to open. Plug the monitor in over USB-C and play.

<div align="center">

| | Step | What happens |
|:---:|---|---|
| **01** | Install | One script sets up Wine, Rapsodo's app and the fixes. |
| **02** | Plug in | MLM2PRO on USB-C, powered on. |
| **03** | Play | Open **Rapsodo Golf on Mac**, sign in, hit balls. |

</div>

### On a Mac

<p align="center">
  <img src="docs/screenshots/range.jpg" alt="Driving Range running on a Mac, connected to the MLM2PRO" width="100%">
</p>

<p align="center"><sub>Driving Range, armed and waiting for a shot</sub></p>

<p align="center">
  <img src="docs/screenshots/home.jpg" alt="Rapsodo Golf home screen on a Mac, monitor connected" width="100%">
</p>

<p align="center"><sub>Home screen, monitor connected (green link icon, top right)</sub></p>

### Status

| | |
|---|---|
| ✅ **Works** | App opens, finds the monitor, signs in, runs firmware updates (tested 4.1.9 → 4.1.19). Driving Range opens, connects and arms the monitor. The alignment screen shows the monitor's live camera. |
| 🟡 **Not confirmed yet** | Shot capture over a full session (the monitor dropped out twice in testing). |
| 🖥️ **Tested on** | macOS 26.6 and 27.0.1, M4 Mac, Rapsodo Golf 1.0.0 |

> [!NOTE]
> **Unofficial.** This is a community project, not made or endorsed by Rapsodo.
> It contains scripts and patches only, no Rapsodo files: you download the app from
> Rapsodo yourself, and the patches are applied to your own copy. A Rapsodo update
> can break it at any time. Use at your own risk.

## What you need

- A Mac with Apple Silicon (M1 or later).
- An MLM2PRO and a USB-C cable.
- A Rapsodo account with a membership that includes the PC app. Rapsodo says the
  PC app needs a Core membership ([Rapsodo Golf for PC](https://rapsodo.com/pages/rapsodo-studios-for-pc)).
- About 3 GB of disk space, plus 2–5 GB for each game you download from inside the
  app (Driving Range is about 4 GB).
- Your Mac password (or Touch ID) each time you play. See [Skip the password](#skip-the-password).

## Install

1. **Download the Rapsodo app.** On
   [Rapsodo's PC app page](https://rapsodo.com/pages/rapsodo-studios-for-pc), click
   **Download PC App**. You get `RapsodoGolfSetup.zip` (about 240 MB) in Downloads.
   Don't unzip it.

2. **Paste this into Terminal** (Applications → Utilities → Terminal) and press
   Return:

   ```bash
   /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/wtabor/rapsodo-golf-on-mac/main/bootstrap.sh)"
   ```

   It finds the Rapsodo download, puts this project in `~/rapsodo-golf-on-mac` (keep
   that folder: the app runs scripts from it), sets everything up and creates
   **Rapsodo Golf on Mac** in Applications. Type your Mac password if it asks.
   Run the same command again any time to update.

<details>
<summary>What the installer adds to your Mac</summary>

Anything you already have is skipped.

- **Rosetta 2**, Apple's Intel translator. Wine is an Intel program.
- **[Homebrew](https://brew.sh/)**, which also brings Apple's command-line
  developer tools.
- **mingw-w64, cmake, libusb** from Homebrew, to build the patched pieces.
- **[iTerm](https://iterm2.com/)**, which starts the app (see [Why iTerm](#why-iterm)).
- **Wine**, **DXVK** and Rapsodo's app, all inside
  `~/Library/Application Support/RapsodoGolf-Wine11/`.

</details>

## Play

1. Plug the MLM2PRO into the Mac with USB-C and turn it on.
2. Open **Rapsodo Golf on Mac** from Applications (drag it to the Dock to keep it
   handy). It opens an iTerm window that starts everything.
3. Type your Mac password when iTerm asks. The Rapsodo app opens once the monitor
   is connected; sign in with your Rapsodo account.

**First launch only**, macOS asks for two permissions. Allow both:

- **Let `bash` control iTerm** (Automation). If you miss it, the app says
  "Could not open iTerm": turn on iTerm under **bash** in System Settings →
  Privacy & Security → Automation, then open the app again.
- **Let iTerm find devices on your local network.** If you never see this prompt
  or missed it, make sure iTerm is on in System Settings → Privacy & Security →
  Local Network. Without it the Rapsodo app can't find the monitor.

**Your location (games only).** The games ask for a location and won't play without
one; this project answers for them with a fixed position. Set yours once:

```bash
cp ~/rapsodo-golf-on-mac/scripts/env.local.sh.example ~/rapsodo-golf-on-mac/scripts/env.local.sh
open -e ~/rapsodo-golf-on-mac/scripts/env.local.sh
```

Put in your latitude, longitude and altitude (meters) and save. Without it the
games use 0/0. Also set the game's own **Elevation** (Settings → Required): that one
drives ball flight.

## Troubleshooting

| You see | Do this |
|---|---|
| iTerm says **Rosetta 2 is not installed** (common after a macOS update) | Run `sudo softwareupdate --install-rosetta --agree-to-license`, then open the app again. Allow the iTerm prompt again if it comes back. |
| **Could not open iTerm** | System Settings → Privacy & Security → Automation → turn on iTerm under **bash**. Open the app again. |
| iTerm sits at **Waiting for the monitor** | The monitor turns itself off when idle: press its power button. After a replug it can take about 60 seconds to answer. |
| The Rapsodo app says **Device not found** | Wait a minute and retry. Check `~/Library/Logs/RapsodoGolf-usblink.log` for `feth0 DHCP (re)requested`. |
| A game says **Failed to initialize player / DirectX 11** | Run `~/rapsodo-golf-on-mac/scripts/45-install-dxvk.sh`, then start the game again. |
| Something broke after Rapsodo updated itself | Open the app again: it re-applies every fix on each launch. To do it by hand: `~/rapsodo-golf-on-mac/scripts/40-apply-patches.sh` then `~/rapsodo-golf-on-mac/scripts/45-install-dxvk.sh`. |
| The first sign-in times out | Nothing to do: the app retries on its own and the retry works. |

Game music can only be turned off inside each game's own settings.

## Skip the password

The USB link needs administrator rights each session, because macOS has no driver
for the MLM2PRO's USB network connection and the replacement
([TetherKit](https://github.com/XiaoMiku01/TetherKit)) must run as root. Pick one:

| Option | Each session | What runs as root |
|---|---|---|
| **Password** (default) | type your Mac password | TetherKit, only while you play |
| **Touch ID** (recommended) | touch the sensor | same as Password |
| **Always on** | nothing | TetherKit, all the time from boot |

**Touch ID** uses Apple's `sudo_local` hook ([macOS 14 Sonoma and
later](https://sixcolors.com/post/2023/08/in-macos-sonoma-touch-id-for-sudo-can-survive-updates/)).
It survives macOS updates and applies to every `sudo` on your Mac, not only this
project:

```bash
sudo sed 's/^#auth/auth/' /etc/pam.d/sudo_local.template | sudo tee /etc/pam.d/sudo_local
```

Check it with `sudo -v` in a new Terminal tab: you should get a Touch ID prompt.
Undo with `sudo rm /etc/pam.d/sudo_local`. It falls back to the password when Touch
ID isn't available (lid closed, external keyboard without Touch ID).

**Always on** installs TetherKit as a LaunchDaemon. No prompt at all, but a small
third-party USB driver then runs as root all the time, which is more attack surface
(for example a malicious USB device posing as the monitor). It runs root-owned
copies in `/usr/local/libexec/rapsodo-golf-on-mac/` and logs to
`/Library/Logs/RapsodoGolf-usblink.log`.

```bash
sudo ~/rapsodo-golf-on-mac/scripts/60-install-usb-daemon.sh              # install
sudo ~/rapsodo-golf-on-mac/scripts/60-install-usb-daemon.sh --uninstall  # remove
```

## Why iTerm

The Rapsodo app finds the monitor over mDNS, and macOS's Local Network privacy
only allows that for apps the user has approved. Wine's programs are unsigned, so
macOS never asks and silently blocks them. Started from iTerm, the app inherits
iTerm's permission. That's why the Mac app hands off to iTerm instead of starting
Wine itself.

## How it works

For developers. The full investigation, including dead ends, is in
[notes/2026-10-19-rapsodo-golf-pc-app-on-mac.md](notes/2026-10-19-rapsodo-golf-pc-app-on-mac.md);
`docs/architecture.html` is a diagram you can open in a browser after cloning.

| Layer | Piece |
|---|---|
| Windows runtime | [Gcenx wine-staging 11.16](https://github.com/Gcenx/macOS_Wine_builds/releases/tag/11.16) (unsigned build) |
| USB-C link | The MLM2PRO is a USB **RNDIS** network gadget (`2207:0019`). macOS has no RNDIS driver, so [TetherKit](https://github.com/XiaoMiku01/TetherKit) (userspace, no kext) bridges it. The monitor runs DHCP: it's `192.168.36.1`, the Mac gets `192.168.36.x`. |
| Fix 1 | Rebuilt `libzmq.dll` (4.3.5) without the 1 MB loopback "slow start" send that deadlocks under Wine → [`patches/`](patches/libzmq-4.3.5-no-fdpair-slowstart.patch) |
| Fix 2 | 1-byte patch in `deviceManagerServer.exe`: Go's `SIO_UDP_NETRESET` (unimplemented in Wine) → `SIO_UDP_CONNRESET`, so the CoAP certificate request and authentication work → [`scripts/patch_devicemanager.py`](scripts/patch_devicemanager.py) |
| Fix 3 | Unity games (Driving Range etc.) need D3D11; Wine's wined3d can't create the device on macOS. [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) (D3D11 → Vulkan → MoltenVK) is enabled per game exe → [`scripts/45-install-dxvk.sh`](scripts/45-install-dxvk.sh) |
| Fix 4 | Games ask WinRT `Geolocator` for a location, which Wine never grants. A stub `GeolocationPlugin.dll` reports `RGM_GEO_LAT` / `RGM_GEO_LON` / `RGM_GEO_ALT` → [`scripts/geolocation_stub.c`](scripts/geolocation_stub.c) |
| UI | Electron runs with `--no-sandbox --disable-gpu --disable-gpu-compositing --in-process-gpu` |

Each game ships its own `libzmq.dll`, `deviceManagerServer.dll` and
`GeolocationPlugin.dll`, so [`scripts/40-apply-patches.sh`](scripts/40-apply-patches.sh)
patches those too. [`scripts/play.sh`](scripts/play.sh) re-runs it and
`45-install-dxvk.sh` on every launch (about 4 seconds), because Rapsodo updates
and new game downloads undo them.

### Built on

<div align="center">

| [Wine](https://github.com/Gcenx/macOS_Wine_builds) | [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) | [TetherKit](https://github.com/XiaoMiku01/TetherKit) | [libzmq](https://github.com/zeromq/libzmq) |
|:---:|:---:|:---:|:---:|
| runs the Windows app | D3D11 for the games | USB-C network link | patched to stop a Wine deadlock |

</div>

## Open source

- **No Rapsodo files in this repo.** `.gitignore` blocks `*.exe`, `*.dll`, `*.zip`;
  patched DLLs and the app icon are produced on your Mac at install time.
- **Third-party pieces** are downloaded or built from their own projects, under
  their own licenses: [Gcenx's Wine builds](https://github.com/Gcenx/macOS_Wine_builds),
  [TetherKit](https://github.com/XiaoMiku01/TetherKit),
  [DXVK-macOS](https://github.com/Gcenx/DXVK-macOS) and
  [libzmq](https://github.com/zeromq/libzmq) (rebuilt with the patch in `patches/`).
- **Your location** stays in the gitignored `scripts/env.local.sh`, never in `env.sh`.
- **License:** [MIT](LICENSE), except the libzmq patch in `patches/`, which is
  [MPL-2.0](https://mozilla.org/MPL/2.0/) like libzmq itself.

## Legal

- **Trademarks.** Rapsodo, MLM2PRO and Rapsodo Golf are trademarks of Rapsodo. This
  project is not affiliated with, endorsed by or supported by Rapsodo; the names are
  used only to say what it works with.
- **Rapsodo's terms.** The installer modifies your own installed copy of Rapsodo's
  app (it swaps in a rebuilt `libzmq.dll`, patches one byte in
  `deviceManagerServer.exe`, and replaces `GeolocationPlugin.dll` in the games).
  Rapsodo's [Terms of Use](https://rapsodo.com/pages/terms-of-use) prohibit
  modifying their software. Read them and decide for yourself; using this project
  is your choice and your responsibility.
- **No warranty.** Provided as is, with no warranty of any kind (see [LICENSE](LICENSE)).
  Rapsodo can change or block their app at any time.

<div align="center">

**Saved you from buying a Windows PC?**

<a href="https://www.buymeacoffee.com/aerstrike"><img src="https://img.shields.io/badge/Buy%20me%20a%20coffee-FFDD00?style=for-the-badge&logo=buy-me-a-coffee&logoColor=black" alt="Buy me a coffee"></a>

</div>
