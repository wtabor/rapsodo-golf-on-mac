# Rapsodo Golf PC app (1.0.0) on Mac — WORKING (USB-C link + patched libzmq)

Date: 10/19/2026 (work started 10/16/2026). Status: **connected** — app connects to
the MLM2PRO and receives device events under Wine 11.16. Shots not yet tested.

## Fix (10/19/2026)

Real root cause: libzmq 4.3.5 `make_fdpair_tcpip` (src/ip.cpp) has a "TCP slow
start" workaround (zeromq #1608) that does a **1 MB blocking `send` before any
`recv` on the same thread** over the loopback pair. Windows buffers it; Wine on
macOS blocks forever (`STATUS_DEVICE_NOT_READY`). Same class of bug as the
05/08/2026 GSPC blocking-socket issue, but fixable in-place here because libzmq
is open source.

- Patch: block disabled (`if (false && ...)`). Rebuilt 4.3.5 with Homebrew
  `mingw-w64` (UCRT, GCC 16), libsodium 1.0.20 import lib (links the app's own
  `libsodium-26.dll`), CURVE on, select poller, IPC off, static libstdc++/libgcc.
  71/71 exports match the original.
- Artifacts: `~/Library/Application Support/RapsodoGolf-Wine11/patches/`
  (`libzmq-4.3.5-nofdpair-slowstart.dll`, `libzmq-ip.cpp.patch`); original kept as
  `libzmq.dll.orig` next to the installed copy.
- Result log: `connection established to server` → `RHost connection success` →
  `Connected to the device` → DeviceParams/battery events every ~2 s.
- Launcher `~/Applications/Rapsodo Golf (Wine).app` now runs the Wine 11 prefix.

## Fix 2 — authentication (10/19/2026)

After connecting, `APIAuthenticate` failed ("No event returned") because the Go
provisioner's CoAP `request-cert` (UDP `192.168.36.1:5683`) died with
`wsaioctl: winapi error #10045`. Go's Windows UDP socket setup calls
`SIO_UDP_CONNRESET` (Wine stubs it → OK) then `SIO_UDP_NETRESET`
(`_WSAIOW(IOC_VENDOR,15)`, unimplemented in Wine 11.16 → fatal).

- Patch: 1 byte in `deviceManagerServer.exe` — the only `mov $0x9800000f,%ebx`
  (VA `0x1401ebb6a`, file offset `2011499` = `0x0f`→`0x0c`) so Go issues
  CONNRESET twice. Original kept as `deviceManagerServer.exe.orig`; patched copy in
  `patches/`.
- Result: first authenticate after launch still times out, the retry succeeds →
  UI "CONNECTION SUCCESSFUL".
- An app auto-update will overwrite both patches; re-apply after updates.
- Firmware update through the app worked under Wine (4.1.9 → **4.1.19**, 11:19–11:24
  on 10/19/2026); the link script recovered both LM restarts. The AerstrikeGolf BLE
  path is **unverified on 4.1.19**. The owner reported the app working end to end afterwards.
- USB link: macOS drops the temporary `ipconfig set` service; `usb-link.sh` now
  re-requests DHCP whenever `feth0` loses its `192.168.36.x` address.

## What the app is

- `Rapsodo Golf-Windows-1.0.0-Setup.exe` (NSIS / electron-builder). Electron 30.5.1
  (Chromium 124) UI + native backend in `resources/libs/windows/`:
  `deviceManagerServer.exe` (Go, gRPC :8080), `libRDCLib.dll` (libc++, "RapsodoLib"),
  `libV3Lib.dll`, `libzmq.dll` 4.3.5 (select poller), libsodium, OpenCV.
- Supports MLM2PRO, MLM2XPRO, CLM. **The PC talks to the MLM2PRO over USB-C, not BLE.**

## The MLM2PRO over USB-C (new, relevant to us)

- Enumerates as Rockchip `rk3xxx`, VID:PID `2207:0019`, **RNDIS** (class e0/01/03 +
  CDC data). macOS has no RNDIS driver → no interface by default.
- [TetherKit](https://github.com/XiaoMiku01/TetherKit) (MIT, userspace RNDIS via
  libusb + `feth`, no kext, SIP on) bridges it. Built from source; supervisor script
  at `~/Library/Application Support/RapsodoGolf-Wine/usb-link.sh` (run with sudo).
- LM runs DHCP: Mac gets `192.168.36.x`, LM is `192.168.36.1`.
- LM services on that link: SSH `:22` (OpenSSH_9.0), nginx `:80` ("IP Camera" web
  UI), **`:32501`** (ZeroMQ DEALER/ROUTER, CURVE-encrypted — the same port seen on
  WiFi in `2026-07-06-camera-live-test-plaintext-confirmed.md`), mDNS
  `_RapsodoDevice._tcp` → `MLM2-<serial>-1.11-4.1.9`.
- Gotchas: the LM resets USB on some connect attempts (~10 s re-enumeration);
  after replug its network side can take ~60 s / a power-button press before
  DHCP answers (RNDIS handshake succeeds but RX stays 0 until then).

## Wine results

| Runtime | UI | mDNS discovery | Connect |
|---|---|---|---|
| GPTK Wine 7.7 | OK with `--no-sandbox --disable-gpu --disable-gpu-compositing --in-process-gpu` | flaky (multicast send fails some launches) | **hangs** |
| Gcenx wine-staging 11.16 | OK, same flags | OK | **hangs** |

Root cause (winedbg `bt all` + `WINEDEBUG=+winsock`): on connect,
`ZMQDealerRouterConnection::launchConnection` → `ZMQKeyManager::getServerKey` →
new `zmq::context_t` → libzmq signaler `make_fdpair` (loopback TCP pair). After
`accept`, the first 1-byte `send` returns `STATUS_DEVICE_NOT_READY (0xc00000a3)`
and the thread blocks forever. No socket to the LM is ever opened. Also logged:
unimplemented `SIO_LOOPBACK_FAST_PATH` and unsupported ioctl `0x120348`.
Same failure in both Wine versions → not fixed upstream as of 11.16.

## Artifacts (local, not committed)

- GPTK prefix + launcher: `~/Library/Application Support/RapsodoGolf-Wine/`,
  `~/Applications/Rapsodo Golf (Wine).app`
- Wine 11 build + prefix: `~/Library/Application Support/RapsodoGolf-Wine11/`

## Open options

1. CrossOver 14-day trial (CodeWeavers' macOS-patched Wine) — untested.
2. Windows 11 ARM VM with USB passthrough of `2207:0019` — untested.
3. Talk to `:32501` natively from the Mac (CURVE key exchange + Rapsodo command
   set) — real RE work; would give AerstrikeGolf a wired, non-BLE LM path.

## Launching from Finder is blocked by Local Network privacy (10/19/2026)

The same launch command finds the monitor when started from a shell (the shell's
host app has Local Network permission) and fails when started from Finder
(`[MdnsTransport] query send failed … mDNS scan did not start (101)`). Adding
`NSLocalNetworkUsageDescription`/`NSBonjourServices`, ad-hoc signing, a compiled
Mach-O launcher, and spawning Wine as a child instead of `exec` all failed to make
macOS prompt or list the app. Working route: run `scripts/play.sh` from a terminal
app that has Local Network permission.
