# Cursor can't reach the right side of a fullscreen game: stale Wine display layout after a monitor change (10/28/2026)

## Symptom

"When the game enters full screen it doesn't let me move my cursor to the far right
side of the screen." The owner later narrowed it down: "seems to happen when I
disconnect from the external monitor." Their "full screen" is Rectangle Pro's
Maximize (Ctrl+Option+Return) on Rapsodo Studios (Golf Simulation). Setup: built-in
display (1800x1169 pt) plus, sometimes, a 3840x2560 external monitor set as the main
display, with the built-in to its left.

## Root cause

Wine 11.16's win32u keeps every display source's logical index (source order,
primary first) as a volatile registry symlink:

    HKLM\System\CurrentControlSet\Hardware Profiles\Current\System\CurrentControlSet\
        Control\Video\{gpu}\0000  ->  ...\Video\{gpu}\Sources\<CG display id>

`write_source_to_registry` (dlls/win32u/sysparams.c) creates the link with
`REG_OPTION_CREATE_LINK`. When that fails because the link exists, it retries with
`REG_OPTION_OPEN_LINK` and writes the new `SymbolicLinkValue`. Neither win32u's
`reg_create_key` (font.c) nor wineserver's `create_key` maps `REG_OPTION_OPEN_LINK`
to `OBJ_OPENLINK` on a create. So the retry follows the old link and writes a stray
`SymbolicLinkValue` into the old target. **A link never changes target within a
Wine session.** Wine master has the same code.

The fresh enumeration is correct for a moment. But every process then re-reads the
layout from the registry through these links. Once the primary display changes
(unplugging the main external monitor, plugging one in that becomes main), index
0000 still points at the old source. The result:

- `err:system:find_monitor_from_path Failed to find monitor with path ...`
- `warn:system:find_primary_source Failed to find primary source.`
- `err:system:display_mode_changed Failed to get primary source current display settings.`
- `EnumDisplayMonitors` reports a source-less placeholder, `WinDisc 0,0-1024,768`,
  as the primary, and drops the real monitor. In other cases it reports the removed
  monitor's size, or misnumbers the devices (primary not `DISPLAY1`).

Everything that sizes itself to the monitor (Unity's fullscreen window, win32u's
fullscreen cursor clip, the server's desktop rect) then uses a screen that doesn't
match macOS. The stale layout lasts until the Wine session ends. That is why a fresh
start was always fine and the bug seemed random.

Seen live in the owner's prefix with `wine reg query` on that key:
`\0000 -> Sources\0001` (built-in, StateFlags 0x1, not primary) while the real
primary was `Sources\0002` (the external monitor, StateFlags 0x5). The old targets
held the stray `SymbolicLinkValue` entries.

## Fix

`scripts/display_fix.c` → `rgm-display-fix.exe`, built by
`scripts/48-build-display-fix.sh` (mingw; rebuilt when `display_fix.c`'s sha256 differs
from `rgm-display-fix.exe.src.sha256`, since 10/29/2026: an auto-update can install a
changed source with an older mtime; also run by install.sh).

- `repair`: deletes only the logical-index link keys. Each is opened with
  `OBJ_OPENLINK` and must have a REG_LINK `SymbolicLinkValue` and no `GPUID` value,
  so a source key is never deleted. It then starts a fresh copy of itself. That
  process finds no source 0, so win32u re-enumerates the displays and recreates the
  links. Last, it broadcasts `WM_DISPLAYCHANGE` and calls `ClipCursor(NULL)`.
- `watch RapsodoGolf.exe`: polls `EnumDisplayMonitors` once a second. When the
  layout changes, it waits 2 s and runs `repair` once. It exits when no
  RapsodoGolf.exe is left, so it never keeps Wine running after the app quits.
- play.sh starts the watcher right after the app (output in
  `~/Library/Logs/RapsodoGolf-heal.log`).

## Driving Range crashed at every start: saved 1x1 screen size

Driving Range had `Screenmanager Resolution Width`=1 and `Height`=1 (fullscreen-window
mode, `Use Native`=0) under `HKCU\Software\Rapsodo\DrivingRange`. It renders at that
size, a scaled render texture ends up 0 wide, and every start crashed:

1. `Screen: Display Data Changed`
2. `Render Graph Execution error` / `ArgumentException: RenderTextureDesc width must be
   greater than zero`
3. Native access violation at `UnityPlayer.dll+0x516b42` (reading 0x10090)

All five crash dumps since 10/26 are identical, including 10/26 15:01 and 15:07 (right
after the external monitor was unplugged; see
`notes/2026-10-26-studios-arming-and-resources.md`) and 16:33 today, before any of this
fix existed. Most likely Unity saved 1x1 when Wine reported the 0x0 placeholder after
that unplug.

`45-install-dxvk.sh` now reads each Unity game's key (company and product from
`<Game>_Data/app.info`). If the saved width is under 320, it deletes the saved
width/height and sets `Use Native`=1, so the game uses the display's native size. It
reset Driving Range's 1x1 and changed nothing on a second run. Afterwards, Driving
Range started on its own ran 45 s fullscreen (0,0 1800x1169) with no render error.
Started from the app at 17:21, it got past `Display Data Changed` with no render error or
crash and connected to the monitor. The owner confirmed it works.

## Verification (10/28/2026)

- Repair on the owner's broken live session: `before: WinDisc 0,0-1024,768
  primary; \\.\DISPLAY1 -1800,1391-0,2560` → `after: \\.\DISPLAY1 0,0-3840,2560
  primary; \\.\DISPLAY2 -1800,1391-0,2560`. A separately started process saw the
  same; the links pointed at the right sources again.
- The watcher, with the app running, across a simulated monitor (macOS private
  `CGVirtualDisplay`, as DeskPad uses) made main and then removed. Both changes
  broke Wine's layout, and the watcher repaired each:
  - misnumbered `DISPLAY3 ... primary` → `DISPLAY1 ... primary`
  - `WinDisc 0,0-1024,768 primary` → `DISPLAY1 0,0-3840,2560 primary`
- `shellcheck -x -e SC1091 scripts/*.sh` clean.
- The owner's real unplug, with the app running: the watcher logged
  `WinDisc 0,0-1024,768 primary` → `\\.\DISPLAY1 0,0-1800,1169 primary`.
- A Dock launch with the new play.sh started the watcher by itself.
- The owner confirmed the cursor reaches the right edge in a game after unplugging the
  external monitor.
- **Not verified:** how Unity re-fits its window after the repair's `WM_DISPLAYCHANGE`.
  A game that is open during an unplug still sees the broken layout for the ~3 s
  before the repair, and may react to it.

## Tests before committing (10/28/2026)

- shellcheck clean on the branch tree. `display_fix.c` builds with `-Wall -Wextra`;
  the only warnings are two unused parameters that the callback signature requires.
- A dry merge with `load-fixes-and-crash-recovery` (`git merge-tree`) is clean.
- **48:** rebuilds when the source is newer; does nothing when current.
- **45:** a forced 1x1 Driving Range size was reset (`Use Native`=1). Studios' valid
  1800x1169 was untouched, and a second run changed nothing.
- **`repair` on a healthy layout:** the layout was unchanged. Link `0000` was
  recreated and `Sources\0001` kept. Run with a persistent wineserver: the display
  keys are volatile, so with the app closed they vanish between commands.
- **The branch's play.sh, from a clean export with `RGM_AUTO_UPDATE=0`:** the app
  started and the watcher came up. On a normal quit (`taskkill`), the app went in
  1 s and the watcher in 2 s. play.sh and wineserver exited, no Wine processes were
  left, and no crash log was written.
- **The working tree's play.sh (with the crash recovery) and `kill -SEGV`
  wineserver:** the recovery closed everything, including the watcher, and
  restarted the app with one new watcher. A normal quit after that was clean.
  This left `/Library/Logs/DiagnosticReports/wineserver-2026-10-28-173046.ips`
  (deliberate, not a real crash). The earlier `*-crashed.log` files were restored.

## Tried and ruled out

- **Win32 `ClipCursor`:** `GetClipCursor` was always the whole screen, polled every
  250 ms for 15 min with only the built-in display.
- **Game code:** the game's display plugins (DisplayIdentifier, DisplayManagerNative,
  DisplaySettingsNative) import no `SetCursorPos`/`ClipCursor`.
- **macdrv's own handling:** it re-enumerates on display changes
  (`DisplayReconfigCallback` → `DISPLAYS_CHANGED` → `DisplayModeChanged`), and
  activating a Wine app forces another pass. Both produce the right layout, which
  the registry re-read then overwrites.
- **Rectangle Pro's Maximize:** it animates the game window (shrinks to ~494x330,
  grows back), and the game repositions itself afterwards (DisplayIdentifier.dll
  calls `SetWindowPos`). With only the built-in display it left the cursor free.
- **Cursor stalls at x≈1455 and x≈1515–1531:** logged before the external-monitor
  lead. Screenshots showed the cursor at rest, not stopped at a wall.
- **Running Driving Range without the app:** it crashes after about a minute.
  Reproduce through the app.
- **A caution:** macdrv's default clipper (`-[NSWindow setMouseConfinementRect:]`,
  cocoa_cursorclipping.m) stores the clip relative to the window, computed once.
  It isn't updated when the window moves or resizes, and `macdrv_clip_cursor`
  returns early for an unchanged rect. A wrong clip set during a display change can
  therefore outlive the change until the game loses focus. Not observed directly.
- **A side effect of testing:** a simulated display made primary and then removed
  leaves the same broken layout, until a repair or a new Wine session.
