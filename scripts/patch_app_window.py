#!/usr/bin/env python3
"""Patch app.asar so the app's window can be resized, with its page scaled to fit.

The app creates its main window with its minimum size set to the whole screen
(`minWidth`/`minHeight` = the primary display's work area), maximizes it when the splash
closes and again after every game, and zooms the page only up, never down (the
"responsive-zoom" resize handler: zoom 1 up to 1920 px wide, more on wider windows).
Under Wine on a Mac the window can still be dragged smaller, but Wine doesn't pass a
resize of a *maximized* window on to it (the app kept 3840x2530 while the Mac window
was 1920x1265), so the page showed cropped. Three same-length edits in
dist-electron/main.js:

- window options: open at the work area's size (same look as maximized, but a normal
  window) with a minimum of 800x450, in place of minimum = work area. (`resizable: !0`,
  Electron's default, makes room.)
- both `win.maximize(), win.show()` calls: `win.focus()` instead of `maximize()`, so
  the window keeps the size you gave it, also after a game.
- the resize handler: zoom by the smaller of width/1920 and height/1080, down to 0.25
  (Chromium's minimum), so the whole page fits; wider windows still zoom up as before
  (capped at 1.25). A 0x0 size (a minimized window) keeps zoom 1, as before.

Same length, so the asar index stays valid (the asar integrity fuse is off in this
build); padding is spaces. Found by structure, not by minified names: the window
options right after `{ width: X, height: Y } = <display>.workAreaSize;`, the two
`<win>.maximize(), <win>.show()` calls, and the one `const [w, h] =
<win>.getContentSize(), ...` statement. Each edit is applied or reverted on its own; one
that isn't found as expected is skipped with a warning (exit status 1).

Usage: patch_app_window.py [--revert] <app.asar>
"""

import mmap
import re
import sys
from pathlib import Path

MIN_W, MIN_H = 800, 450
V = rb"([\w$]+)"
WINDOW_HEAD = rb"\{ width: " + V + rb", height: " + V + rb" \} = [\w$]+\.workAreaSize;\s+[\w$]+ = new [\w$]+\(\{"

# Window options.
SIZE_ORIG = re.compile(WINDOW_HEAD + rb"(\s+)minWidth: \1,(\s+)minHeight: \2,(\s+)resizable: !0,")
SIZE_NEW = re.compile(WINDOW_HEAD + rb"(\s+)width: \1, height: \2, minWidth: " + str(MIN_W).encode()
                      + rb", minHeight: " + str(MIN_H).encode() + rb",( *)")

# Maximize when the splash closes and after each game: `<win>.maximize(), <win>.show()`.
MAX_ORIG, MAX_NEW = b".maximize(), ", b".focus()   , "

# The responsive-zoom handler's one statement.
ZOOM_ORIG = re.compile(
    rb"const \[" + V + rb", " + V + rb"\] = " + V + rb"\.getContentSize\(\), " + V + rb" = \1 / " + V
    + rb", " + V + rb" = \4 <= 1 \? 1 : 1 \+ \(\4 - 1\) \* " + V + rb", " + V + rb" = Math\.min\(" + V
    + rb", Math\.max\(1, \6\)\);"
)
ZOOM_NEW = re.compile(
    rb"const\[" + V + rb"," + V + rb"\]=" + V + rb"\.getContentSize\(\),"
    + V + rb"=Math\.min\(\1/" + V + rb",\2/1080\)\|\|1," + V + rb"=\4<=1\?\4:1\+\(\4-1\)\*" + V + rb"," + V
    + rb"=Math\.min\(" + V + rb",Math\.max\(\.25,\6\)\); *"
)


def size_edit(m, revert):
    """[(offset, old bytes, new bytes)], "done" or "missing"."""
    find, other = (SIZE_NEW, SIZE_ORIG) if revert else (SIZE_ORIG, SIZE_NEW)
    hits = list(find.finditer(m))
    if len(hits) != 1:
        return "done" if not hits and len(list(other.finditer(m))) == 1 else "missing"
    h = hits[0]
    w, ht, ws = h.group(1).decode(), h.group(2).decode(), h.group(3)
    old = m[h.start(3) : h.end()]
    if revert:
        new = ws + f"minWidth: {w},".encode() + ws + f"minHeight: {ht},".encode() + ws + b"resizable: !0,"
    else:
        new = ws + f"width: {w}, height: {ht}, minWidth: {MIN_W}, minHeight: {MIN_H},".encode()
        new += b" " * (len(old) - len(new))
    return [(h.start(3), old, new)] if len(new) == len(old) else "missing"


def calls(m, middle):
    """`<win><middle><win>.show()` sites as (start, end, win). Found from the literal middle
    (a regex starting with a name would try every byte of the 280 MB archive)."""
    sites, at = [], m.find(middle)
    while at >= 0:
        name = re.search(rb"[\w$]+$", m[max(0, at - 64) : at])
        if name and m[at + len(middle) : at + len(middle) + len(name.group()) + 7] == name.group() + b".show()":
            sites.append((at - len(name.group()), at + len(middle) + len(name.group()) + 7, name.group().decode()))
        at = m.find(middle, at + 1)
    return sites


def max_edit(m, revert):
    find, other = (MAX_NEW, MAX_ORIG) if revert else (MAX_ORIG, MAX_NEW)
    hits = calls(m, find)
    if len(hits) != 2:
        return "done" if not hits and len(calls(m, other)) == 2 else "missing"
    edits = []
    for start, end, win in hits:
        new = (f"{win}.maximize(), {win}.show()" if revert else f"{win}.focus()   , {win}.show()").encode()
        edits.append((start, m[start:end], new))
    return edits if all(len(o) == len(n) for _, o, n in edits) else "missing"


def zoom_edit(m, revert):
    find, other = (ZOOM_NEW, ZOOM_ORIG) if revert else (ZOOM_ORIG, ZOOM_NEW)
    hits = list(find.finditer(m))
    if len(hits) != 1:
        return "done" if not hits and len(list(other.finditer(m))) == 1 else "missing"
    h = hits[0]
    n, e, win, i, ole, a, sle, l, ale = (g.decode() for g in h.groups())
    orig = (f"const [{n}, {e}] = {win}.getContentSize(), {i} = {n} / {ole}, {a} = {i} <= 1 ? 1 : "
            f"1 + ({i} - 1) * {sle}, {l} = Math.min({ale}, Math.max(1, {a}));").encode()
    new = (f"const[{n},{e}]={win}.getContentSize(),{i}=Math.min({n}/{ole},{e}/1080)||1,"
           f"{a}={i}<=1?{i}:1+({i}-1)*{sle},{l}=Math.min({ale},Math.max(.25,{a}));").encode()
    if revert:
        # The patched statement was padded with spaces to the original's length.
        old = m[h.start() : h.start() + len(orig)]
        if old.rstrip(b" ") != new:
            return "missing"
        return [(h.start(), old, orig)]
    old = m[h.start() : h.end()]
    if len(new) > len(old):
        return "missing"
    return [(h.start(), old, new + b" " * (len(old) - len(new)))]


def main() -> int:
    args = sys.argv[1:]
    revert = args[:1] == ["--revert"]
    if revert:
        args = args[1:]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    asar = Path(args[0])
    rc = 0
    with open(asar, "r+b") as f, mmap.mmap(f.fileno(), 0) as m:
        for name, edit in (("window size", size_edit), ("no maximize", max_edit), ("page zoom on resize", zoom_edit)):
            result = edit(m, revert)
            if result == "done":
                print(f"{name}: already {'reverted' if revert else 'patched'}")
            elif result == "missing":
                print(f"{name}: not found as expected in {asar}; skipped", file=sys.stderr)
                rc = 1
            else:
                for start, _old, new in result:
                    m[start : start + len(new)] = new
                print(f"{name}: {'reverted' if revert else 'patched'} at offset "
                      + ", ".join(str(start) for start, _, _ in result))
        m.flush()
    return rc


if __name__ == "__main__":
    sys.exit(main())
