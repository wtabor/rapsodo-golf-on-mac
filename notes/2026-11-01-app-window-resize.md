# App window: launches full screen, a smaller window shows only part of it (11/01/2026)

The owner: the home screen always opens full screen, and making the window smaller only
shows part of the app (screenshot of the maximized window on the 3840x2560 display).

## Why (Rapsodo Golf 1.0.0, app.asar dist-electron/main.js)
- The main window is created with `minWidth`/`minHeight` set to the primary display's
  work area (`const { width: i, height: a } = e.workAreaSize; Ne = new Pl({ minWidth: i,
  minHeight: a, resizable: !0, ... })`). On Windows that makes the window impossible to
  shrink. Under Wine the Mac window shrinks anyway, but the page keeps its full size, so
  the window crops it.
- The page zoom is set on every resize and display change (`Ne.on("resize", pm)`):
  `zoom = 1` up to 1920 px wide, more on wider windows (half the extra ratio, max 1.25),
  never below 1. Logged as `[SL-303 responsive-zoom] content WxH ratio R -> zoom Z`. On
  this Mac: 3832x2496 -> 1.25 (external display), 1792x1096 -> 1.0, 792x566 -> 1.0.
- It also calls `Ne.maximize()` when the splash closes and every time a game exits.

## First fix, not enough
Minimum size 800x450 plus zoom-to-fit: the owner opened the app, dragged it smaller:
still cropped. The log had no new `responsive-zoom` line, so the app never got the new
size. A small Wine tool (EnumWindows + GetWindowRect/IsZoomed) against the running app:
Win32 window 3840x2530, `IsZoomed` 1, while CGWindowList had the Mac window at 1920x1265.
Wine's `macdrv_window_frame_changed` does call `NtUserSetRawWindowPos` for a user resize,
but the maximized window kept its size. `ShowWindow(SW_RESTORE)` + `SetWindowPos(1600x1000)`
from the same tool: Win32 1600x1000, Mac 1592x998, and the app logged `content 1592x966 ->
zoom 0.829`. So the window must not be maximized.

## Fix: scripts/patch_app_window.py (Fix 12, run by 40)
Three same-length edits, found by structure, `--revert` restores the bytes exactly:
- window options: `width`/`height` = the work area (opens the same size as maximized, but
  as a normal window) and minimum 800x450, in place of `minWidth`/`minHeight` = work area
  and `resizable: !0` (Electron's default anyway);
- both `Ne.maximize(), Ne.show()` (splash closed, game closed): `Ne.focus()` instead, so
  the window keeps the size you gave it. Found from the literal `.maximize(), ` text: a
  regex starting with `[\w$]+` took minutes on the 280 MB archive;
- the zoom statement rewritten compactly (padded with spaces):
  `i = Math.min(w/1920, h/1080) || 1; zoom = i <= 1 ? i : 1 + (i - 1) * 0.5`, clamped to
  0.25..1.25. Below 1920x1080 the page zooms down so the 1920x1080 layout always fits;
  above, the same zoom as before except a wide but short window (3608x1132: 1.25 before,
  1.024 now, so its 1080-px-tall layout isn't cut off). `|| 1` keeps zoom 1 for the
  0x0 size the app reads while hidden or minimized, as before.

## Checked (11/01/2026)
- On a copy of the installed app.asar: all three edits apply (window options 7091750,
  maximize 7059679 and 7079445, zoom 7090247) in 0.3 s,
  a second run says "already patched", `--revert` is byte-identical, the other app.asar
  patches (6, 7) are untouched, size unchanged. Run with no or bad arguments: usage,
  exit 2 (the older patchers patch their own source then; found by the regression-test
  work, not fixed there yet).
- The patched main.js parses (`node --check`). Zoom computed with the patched code:
  1920x1080 1.0; 1512x945 0.787; 1000x600 0.521; 800x450 0.417; 3832x2496 1.25.
- `rapsodo-compat-check.py` now runs the patcher on each new Rapsodo release (Fix 12).
- Applied to the owner's install (app closed).

**Not tried yet:** opening the patched app and dragging the window smaller by hand.
