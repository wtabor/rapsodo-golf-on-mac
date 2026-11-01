#!/usr/bin/env python3
"""Run the binary patchers on copies of the installed Rapsodo files (tier 1).

Never writes to the installed files: each check copies (APFS clone where possible)
into --work and patches the copy. Per patcher: patch, re-run says "already patched",
--revert is byte-identical (where supported), patching the stock file gives exactly
the installed patched file, and an unknown file is refused and left alone.

Prints one "PASS|FAIL|SKIP<TAB>name<TAB>detail" line per check (scripts/test.sh
relays them); other lines are details.

Usage: patchers.py --scripts DIR --work DIR --libs DIR --asar FILE --games DIR
                   --mediamtx FILE [--mingw CC]
"""

import argparse
import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

NETRESET = bytes.fromhex("bb0f000098")


def emit(status, name, detail=""):
    print(f"{status}\t{name}\t{detail}", flush=True)


def note(text):
    print(text, flush=True)


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def same(a, b):
    return subprocess.run(["cmp", "-s", str(a), str(b)]).returncode == 0


def clone(src, dst):
    """Copy src to dst, as an APFS clone when possible (instant, no extra space)."""
    dst = Path(dst)
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists():
        dst.unlink()
    if subprocess.run(["cp", "-c", str(src), str(dst)], capture_output=True).returncode != 0:
        shutil.copyfile(src, dst)
    os.chmod(dst, 0o644)
    return dst


def run(script, *args):
    """Run a patcher with python3 -I; returns (rc, stdout + stderr)."""
    p = subprocess.run([sys.executable, "-I", str(script), *map(str, args)], capture_output=True, text=True)
    out = (p.stdout + p.stderr).strip()
    note(f"$ {Path(script).name} {' '.join(map(str, args))}\n  rc {p.returncode}: {out}")
    return p.returncode, out


def diff_span(a, b):
    """(count of differing bytes, first offset, last offset) of two same-size files."""
    x, y = Path(a).read_bytes(), Path(b).read_bytes()
    if len(x) != len(y):
        return None
    offs = [i for i in range(len(x)) if x[i] != y[i]] if len(x) < 4096 else None
    if offs is None:
        # Large files: compare in blocks, then byte by byte only where blocks differ.
        offs = []
        step = 1 << 16
        for s in range(0, len(x), step):
            if x[s : s + step] != y[s : s + step]:
                offs += [s + i for i, (c, d) in enumerate(zip(x[s : s + step], y[s : s + step])) if c != d]
    return (len(offs), offs[0] if offs else None, offs[-1] if offs else None)


class Check:
    """Collects sub-step failures for one PASS/FAIL line."""

    def __init__(self, name):
        self.name, self.problems = name, []

    def expect(self, ok, what):
        if not ok:
            self.problems.append(what)
            note(f"  problem: {what}")
        return ok

    def done(self, detail=""):
        if self.problems:
            emit("FAIL", self.name, "; ".join(self.problems))
        else:
            emit("PASS", self.name, detail)


def unknown_file(work, name, size=65536):
    """A deterministic file no patcher knows."""
    p = Path(work) / name
    data = bytearray(hashlib.sha256(b"rgm-test").digest() * (size // 32))
    p.write_bytes(data)
    return p


def stock_of(installed):
    """The unpatched original of an installed file: its .orig backup, else itself."""
    orig = Path(str(installed) + ".orig")
    return orig if orig.exists() else Path(installed)


def game_dirs(games):
    """games/<id>/<version>/ folders (not the app's .tmp download area)."""
    if not games.is_dir():
        return []
    return sorted(p for p in games.glob("*/*") if p.is_dir() and not p.parts[-2].startswith("."))


# ---------------------------------------------------------------- devicemanager
def test_devicemanager(a, work):
    script = a.scripts / "patch_devicemanager.py"
    name = "patch_devicemanager.py"
    if not script.exists():
        emit("FAIL", name, "script missing")
        return
    targets = [a.libs / "deviceManagerServer.exe", a.mediamtx]
    for g in game_dirs(a.games):
        targets += sorted(g.glob("*_Data/Plugins/x86_64/deviceManagerServer.dll"))
    targets = [t for t in targets if t.exists()]
    if not targets:
        emit("SKIP", name, "no installed deviceManagerServer / mediamtx.exe found")
    seen = {}
    for t in targets:
        seen.setdefault(sha(stock_of(t)), []).append(t)

    def where(t):
        if t.suffix == ".dll":  # games/<id>/<version>/<Game>_Data/Plugins/x86_64/
            return f"{t.name} ({t.parents[4].name})"
        return t.name

    for n, (digest, group) in enumerate(seen.items()):
        installed = group[0]
        stock = stock_of(installed)
        label = f"{name} on " + ", ".join(where(t) for t in group)
        c = Check(label)
        data = stock.read_bytes()
        if data.count(NETRESET) != 1:
            # No stock copy to start from (installed file patched, no .orig): only re-run.
            copy = clone(installed, work / f"dm{n}" / installed.name)
            rc, out = run(script, copy)
            c.expect(rc == 0 and out.startswith("already patched"), f"patched file: expected 'already patched', got rc {rc}")
            c.done("no stock copy (.orig); checked re-run only")
            continue
        copy = clone(stock, work / f"dm{n}" / installed.name)
        rc, out = run(script, copy)
        c.expect(rc == 0 and out.startswith("patched"), f"patch: rc {rc}")
        span = diff_span(stock, copy)
        c.expect(span is not None and span[0] == 1, f"expected a 1-byte change, got {span and span[0]}")
        backup = Path(str(copy) + ".orig")
        c.expect(backup.exists() and same(backup, stock), "backup .orig missing or not the stock file")
        for inst in group:
            if not same(inst, stock):
                c.expect(same(copy, inst), f"patched copy differs from the installed patched {inst.name}")
        before = sha(copy)
        rc, out = run(script, copy)
        c.expect(rc == 0 and out.startswith("already patched") and sha(copy) == before, "re-run: not 'already patched' or file changed")
        c.done(f"1 byte at offset {span[1] if span else '?'}")

    c = Check(f"{name} refuses unknown files")
    u = unknown_file(work, "unknown.bin")
    before = sha(u)
    rc, out = run(script, u)
    c.expect(rc == 1 and sha(u) == before and not Path(str(u) + ".orig").exists(), "unknown file: not refused or changed")
    stock = stock_of(targets[0]) if targets else None
    if stock and stock.read_bytes().count(NETRESET) == 1:
        twice = work / "twice.bin"
        twice.write_bytes(stock.read_bytes() + NETRESET)
        before = sha(twice)
        rc, out = run(script, twice)
        c.expect(rc == 1 and sha(twice) == before, "file with two NETRESET sites: not refused or changed")
    c.done()


# ---------------------------------------------------------------- app.asar patchers
def asar_roundtrip(a, work, script_name, lines):
    """patch / re-run / --revert / --revert again / patch again on a clone of app.asar."""
    script = a.scripts / script_name
    if not script.exists():
        emit("FAIL", script_name, "script missing")
        return
    if a.asar.exists():
        asar_installed(a, work, script, script_name, lines)
    else:
        emit("SKIP", script_name, f"no installed app.asar ({a.asar})")

    c = Check(f"{script_name} refuses unknown files")
    u = work / f"{script_name}.unknown.txt"
    u.write_bytes(b'{"files":{}}\n' + b"console.log('not the Rapsodo app');\n" * 1000)
    before = sha(u)
    rc, out = run(script, u)
    c.expect(rc == 1 and sha(u) == before, "unknown file: not refused or changed")
    c.done()


def asar_installed(a, work, script, script_name, lines):
    c = Check(f"{script_name} patch / re-run / revert")
    copy = clone(a.asar, work / script_name / "app.asar")
    size = copy.stat().st_size
    rc, out = run(script, copy)
    first = out
    c.expect(rc == 0 and "patched" in out, f"patch: rc {rc}")
    patched = clone(copy, work / script_name / "patched.asar")
    rc, out = run(script, copy)
    c.expect(rc == 0 and out.count("already patched") == lines and same(copy, patched),
             "re-run: expected 'already patched' for every edit and no change")
    rc, out = run(script, "--revert", copy)
    c.expect(rc == 0 and out.count("reverted") == lines and not same(copy, patched) and copy.stat().st_size == size,
             "--revert: expected every edit reverted, same size")
    rc, out = run(script, "--revert", copy)
    c.expect(rc == 0 and out.count("already reverted") == lines, "--revert again: expected 'already reverted'")
    if "already patched" not in first:
        # The installed app.asar was stock: revert must give it back byte for byte.
        c.expect(same(copy, a.asar), "revert isn't byte-identical to the stock app.asar")
    rc, out = run(script, copy)
    c.expect(rc == 0 and same(copy, patched), "patch after revert differs from the first patch")
    state = "installed copy was already patched" if "already patched" in first else "installed copy was stock"
    c.done(f"{state}; revert/patch byte-identical")
    for f in work.joinpath(script_name).glob("*.asar"):
        f.unlink()


# ---------------------------------------------------------------- no path given
def no_argument(a, work):
    """Run with no path (or only --revert): usage and exit 2, nothing written. They used to
    take sys.argv[-1], which is then the script itself, and patch their own source."""
    c = Check("patchers refuse to run without a path")
    for name in ("patch_devicemanager.py", "patch_alignment_ffmpeg.py", "patch_app_polls.py",
                 "patch_app_window.py", "patch_unity_video.py"):
        src = a.scripts / name
        if not src.exists():
            continue
        copy = clone(src, work / "noarg" / name)
        before = sha(copy)
        for args in ((), ("--revert",)) if name != "patch_devicemanager.py" else ((),):
            rc, _ = run(copy, *args)
            c.expect(rc == 2 and sha(copy) == before, f"{name} {' '.join(args) or '(no args)'}: rc {rc}")
    c.done()


# ---------------------------------------------------------------- Unity video
def test_unity_video(a, work):
    name = "patch_unity_video.py"
    script = a.scripts / name
    if not script.exists():
        emit("SKIP", name, "not in this checkout (branch game-video-fix)")
        return
    dlls = [g / "UnityPlayer.dll" for g in game_dirs(a.games) if (g / "UnityPlayer.dll").exists()]
    if not dlls:
        emit("SKIP", name, "no installed game (games/<id>/<version>/UnityPlayer.dll)")
    seen = {}
    for dll in dlls:
        seen.setdefault(sha(stock_of(dll)), []).append(dll)
    for n, (digest, group) in enumerate(seen.items()):
        installed = group[0]
        stock = stock_of(installed)
        label = f"{name} on " + ", ".join(f"UnityPlayer.dll ({d.parent.parent.name})" for d in group)
        c = Check(label)
        copy = clone(stock, work / f"unity{n}" / "UnityPlayer.dll")
        ino = copy.stat().st_ino
        rc, out = run(script, copy)
        if rc == 0 and out.startswith("already patched"):
            c.done("no stock copy (.orig); checked re-run only")
            continue
        c.expect(rc == 0 and out.startswith("patched"), f"patch: rc {rc}")
        c.expect(copy.stat().st_ino != ino, "not replaced by rename (a running game would see the change)")
        span = diff_span(stock, copy)
        c.expect(span is not None and 0 < span[0] and span[2] - span[1] < 26, f"change not confined to the 26-byte name: {span}")
        backup = Path(str(copy) + ".orig")
        c.expect(backup.exists() and same(backup, stock), "backup .orig missing or not the stock file")
        for inst in group:
            if not same(inst, stock):
                c.expect(same(copy, inst), f"patched copy differs from the installed patched {inst.parent.parent.name}")
        before = sha(copy)
        rc, out = run(script, copy)
        c.expect(rc == 0 and out.startswith("already patched") and sha(copy) == before, "re-run: not 'already patched' or changed")
        rc, out = run(script, "--revert", copy)
        c.expect(rc == 0 and same(copy, stock), "--revert isn't byte-identical to the stock DLL")
        rc, out = run(script, "--revert", copy)
        c.expect(rc == 0 and out.startswith("already reverted"), "--revert again: expected 'already reverted'")
        c.done(f"{span[0] if span else '?'} bytes differ")

    c = Check(f"{name} refuses unknown files")
    u = unknown_file(work, "unity-unknown.dll")
    before = sha(u)
    rc, out = run(script, u)
    c.expect(rc == 1 and sha(u) == before, "unknown file: not refused or changed")
    if a.mingw:
        # A DLL that has the name but imports Media Foundation statically: must refuse.
        src = work / "mfimport.c"
        src.write_text(
            '#include <windows.h>\n#include <mfapi.h>\n'
            'const char name[] = "MFCreateDXGIDeviceManager";\n'
            '__declspec(dllexport) HRESULT f(void) { return MFStartup(MF_VERSION, 0); }\n')
        dll = work / "mfimport.dll"
        b = subprocess.run([a.mingw, "-shared", "-O0", "-o", str(dll), str(src), "-lmfplat"], capture_output=True, text=True)
        if b.returncode == 0:
            before = sha(dll)
            rc, out = run(script, dll)
            c.expect(rc == 1 and "imports Media Foundation" in out and sha(dll) == before,
                     "DLL importing mfplat: not refused or changed")
        else:
            note(f"  (couldn't build the mfplat-import sample: {b.stderr.strip()[:200]})")
    c.done()


def main():
    ap = argparse.ArgumentParser()
    for opt in ("--scripts", "--work", "--libs", "--asar", "--games", "--mediamtx"):
        ap.add_argument(opt, type=Path, required=True)
    ap.add_argument("--mingw", default="")
    a = ap.parse_args()
    a.work.mkdir(parents=True, exist_ok=True)
    test_devicemanager(a, a.work)
    asar_roundtrip(a, a.work, "patch_alignment_ffmpeg.py", 1)
    asar_roundtrip(a, a.work, "patch_app_polls.py", 2)
    asar_roundtrip(a, a.work, "patch_app_window.py", 3)
    test_unity_video(a, a.work)
    no_argument(a, a.work)
    return 0


if __name__ == "__main__":
    sys.exit(main())
