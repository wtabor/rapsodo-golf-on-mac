# Extended Screens: "Second screen not detected" (11/09/2026)

On 11/08/2026 the Driving Range's Extended Screens panel showed screen 1 "Screen Detected /
WINE MONITOR" and screen 2 "Second screen not detected", with the Mac's built-in display
and a BenQ RD280UA (3840x2560, not mirrored) attached.

## Cause

The Range (v1.15.1, `DisplayManager.Win.WindowsDisplayApi`) reads the display topology
through `QueryDisplayConfig(QDC_DATABASE_CURRENT, ..., &topologyId)` and switches it with
`SetDisplayConfig(SDC_TOPOLOGY_CLONE|EXTEND)`. A probe calling the same APIs under this
Wine (Gcenx wine-staging 11.16) with both displays on:

- `EnumDisplayMonitors`: `\\.\DISPLAY1 0,0-1800,1169` primary, `\\.\DISPLAY2 0,-2560-3840,0`
- `QDC_ALL_PATHS` / `QDC_ONLY_ACTIVE_PATHS`: 2 paths, targets "Wine Monitor" and "BenQ RD280UA"
- `QDC_DATABASE_CURRENT`: 2 paths, **topology INTERNAL**
- `SetDisplayConfig(<topology>|SDC_VALIDATE)`: 0 for all four

Wine's own FIXMEs: `NtUserQueryDisplayConfig setting toplogyid to
DISPLAYCONFIG_TOPOLOGY_INTERNAL` and `SetDisplayConfig ... stub`.

## Test

A one-byte change (`movl $0x1,(%rbx)` → `$0x4` at 0x13ea9f of `win32u.so`), app and Range
restarted: the panel showed screen 2 "Screen Detected / BENQ RD280UA", with Mirror
Screen / Extend Screen and Stop Screen Sharing available (owner's screenshot).

## Fix 13

`scripts/patch_wine_topology.py`, run by `10-install-wine.sh` (so `update.sh` brings it to
every install). Only Gcenx 11.16's stock win32u.so (sha256 `48e91706…`) is patched;
anything else is refused and 10 prints a note instead of failing.

- At the old INTERNAL store (the FIXME print before it is dropped): save the caller's
  topology pointer in `-0x90(%rbp)` (the frame's lowest 8 bytes; nothing else in the
  function touches them), store INTERNAL as a placeholder, and keep a 45-byte code cave
  in the freed bytes.
- The success path (`*paths = n; *modes = m; ret = 0`) jumps to the cave, which does those
  stores, then sets topology = n > 1 ? EXTEND : INTERNAL, and jumps back to the unlock.
  Error paths skip it.
- Ad-hoc re-signed, swapped in by rename; `.orig` keeps the stock file; `--revert` puts it
  back byte for byte.

Verified: probe gives EXTEND with both displays and INTERNAL in a one-monitor virtual
desktop; tier 1 (patcher round trip, refusal) and tier 2 (`tests/wine/topology.c`) pass.
The Range with the final patch: restarted, not yet re-checked on screen.

## Limits

- `SetDisplayConfig` is still a Wine stub: Mirror/Extend in the game report success but
  don't change the Mac's arrangement (System Settings → Displays does). With macOS
  mirroring on, Wine sees one display, so the game sees INTERNAL.
- Whether the extended screen's 2D map / metrics render on the BenQ during a real
  session with the monitor connected isn't confirmed yet.

## Mistake to avoid

Running `wine explorer /desktop=…,800x600` next to the running app changed the display
layout of every process on that wineserver (the app and the Range saw one 800x600
monitor). `rgm-display-fix.exe repair` fixed it. Tier 2's one-monitor check now skips
while the app or a game runs and waits for its own wineserver to exit.
