#!/usr/bin/env python3
"""Check whether a Rapsodo Golf PC app release still works with this project's fixes.

Rapsodo's app updates itself from a public electron-updater feed
(https://storage.googleapis.com/super-app-clm-prod/latest.yml). This downloads the
release the feed points at, checks its sha512, unpacks it with 7-Zip (NSIS installer
-> $PLUGINSDIR/app-64.7z -> the app) and runs each fix against a copy of the stock
files: the same patch scripts 40-apply-patches.sh runs, plus the strings play.sh and
47-install-mediamtx.sh depend on. Nothing is written outside the work directory.

Prints a Markdown report. Exit status: 0 = every check passed, 1 = at least one
check failed (this project needs work before users get that release), 2 = the check
itself couldn't run (feed, download, unpack).

Usage:
  rapsodo-compat-check.py [--channel prod] [--workdir DIR] [--report FILE]
  rapsodo-compat-check.py --installer "Rapsodo Golf-Windows-1.0.0-Setup.exe"
  rapsodo-compat-check.py --app-dir DIR   # an unpacked *stock* app, not your patched install
  rapsodo-compat-check.py --feed-only     # print the feed's version/sha512 line and exit

Needs Python 3 and 7-Zip (`7z` or `7zz`; `7za` can't read NSIS installers) for installers.
"""

from __future__ import annotations  # `str | None` hints on macOS's Python 3.9

import argparse
import base64
import hashlib
import os
import re
import json
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

FEEDS = {
    "prod": "https://storage.googleapis.com/super-app-clm-prod",
    # Rapsodo's own pre-release channel (the app knows dev/test/stage too). Opt-in.
    "test": "https://storage.googleapis.com/super-app-clm-test",
}
SCRIPTS = Path(__file__).resolve().parent

# The stock 1.0.0 builds this project was built and tested against.
KNOWN = {
    # Fix 1: scripts/30-build-libzmq.sh rebuilds exactly this libzmq 4.3.5, linked
    # against the app's libsodium-26.dll. 40 swaps it in without checking what's there.
    "libzmq.dll": "6cdd06bfee2f1b4e1eb17d9d92245b0f743a40140a32db8c8fef452de7775675",
    "deviceManagerServer.exe": "87a254e92d2f76c604481d2e8d3b83aded53c3003ff676902763fff8d0ed77ee",
}
# What users would see if a check fails and the release reached them.
IMPACT = {
    "layout": "the launch or the patch steps fail",
    "games": "games downloaded after this update are never patched (they can't connect)",
    "Fix 1": "the app likely hangs connecting to the monitor (wrong libzmq swapped in)",
    "Fix 2": "the monitor never authenticates (the app and games can't connect)",
    "Fix 5": "alignment says \"Alignment Couldn't Start\"",
    "Fix 6": "alignment video at ~1 fps (warn-only patch)",
    "Fix 7": "more background CPU during games (warn-only patch)",
    "Fix 12": "the app's window can't be made smaller than the screen without cropping (warn-only patch)",
    "play.sh": "play.sh's device-manager retry or new-game patching stops working",
    "watch": "this watcher reads the wrong feed",
}
# 47-install-mediamtx.sh and play.sh/40/45 hardcode where the app keeps things.
APP_NAME = "super-app-clm"  # %APPDATA%\\super-app-clm (userData) holds mediamtx\\
MEDIAMTX_DIR_CODE = b'getPath("userData"), "mediamtx"'
GAMES_DIR_CODE = b'"Rapsodo", "SuperApp", "games"'  # C:\\ProgramData\\Rapsodo\\SuperApp\\games
# Log lines play.sh waits for (device-manager retry, new-game patching).
PLAY_SH_LOG_LINES = [
    b"DEBUG: start device manager",
    b"device manager server start failed",
    b"download game end",
]


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def fetch(url: str, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "rapsodo-golf-on-mac compat check"})
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return r.read()


def read_feed(channel: str) -> dict:
    """The few top-level fields of electron-updater's latest.yml (flat `key: value`)."""
    text = fetch(f"{FEEDS[channel]}/latest.yml").decode()
    feed = {}
    for line in text.splitlines():
        m = re.match(r"^(version|path|sha512|releaseDate):\s*'?([^']*)'?\s*$", line)
        if m:
            feed[m.group(1)] = m.group(2)
    missing = {"version", "path", "sha512"} - feed.keys()
    if missing:
        raise RuntimeError(f"latest.yml is missing {', '.join(sorted(missing))}")
    feed["url"] = f"{FEEDS[channel]}/{urllib.request.quote(feed['path'])}"
    return feed


def us_date(iso: str) -> str:
    """'2026-10-14T14:12:29.493Z' -> '10/14/2026 14:12 UTC' (the feed's releaseDate)."""
    m = re.match(r"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2})", iso)
    return f"{m[2]}/{m[3]}/{m[1]} {m[4]}:{m[5]} UTC" if m else (iso or "?")


def download(url: str, dest: Path, sha512_b64: str) -> None:
    h = hashlib.sha512()
    req = urllib.request.Request(url, headers={"User-Agent": "rapsodo-golf-on-mac compat check"})
    with urllib.request.urlopen(req, timeout=60) as r, open(dest, "wb") as f:
        for chunk in iter(lambda: r.read(1 << 20), b""):
            h.update(chunk)
            f.write(chunk)
    if base64.b64encode(h.digest()).decode() != sha512_b64:
        raise RuntimeError("downloaded installer doesn't match the feed's sha512")


def unpack(installer: Path, work: Path) -> Path:
    seven = next((shutil.which(n) for n in ("7z", "7zz") if shutil.which(n)), None)
    if not seven:
        raise RuntimeError("7-Zip not found (7z or 7zz; 7za can't read NSIS installers)")
    nsis, app = work / "nsis", work / "app"
    # A reused --workdir must not mix in files from an earlier release.
    for old in (nsis, app):
        shutil.rmtree(old, ignore_errors=True)
    subprocess.run([seven, "x", "-y", f"-o{nsis}", str(installer), "$PLUGINSDIR/app-64.7z"],
                   check=True, stdout=subprocess.DEVNULL)
    inner = nsis / "$PLUGINSDIR" / "app-64.7z"
    if not inner.is_file():
        raise RuntimeError("installer has no $PLUGINSDIR/app-64.7z (packaging changed)")
    subprocess.run([seven, "x", "-y", f"-o{app}", str(inner)], check=True, stdout=subprocess.DEVNULL)
    inner.unlink()  # 250 MB we no longer need
    return app


def run_patcher(script: str, target: Path) -> tuple[int, str]:
    p = subprocess.run([sys.executable, "-I", str(SCRIPTS / script), str(target)],
                       capture_output=True, text=True)
    return p.returncode, (p.stdout + p.stderr).replace(str(target.parent) + os.sep, "").strip()


def asar_package_json(asar: Path) -> dict:
    """package.json from the asar's own index (header: 4 uint32s, then JSON)."""
    with open(asar, "rb") as f:
        head = f.read(16)
        pickle_size, header_size = struct.unpack("<I", head[4:8])[0], struct.unpack("<I", head[12:16])[0]
        header = json.loads(f.read(header_size))
        entry = header["files"]["package.json"]
        f.seek(8 + pickle_size + int(entry["offset"]))
        return json.loads(f.read(entry["size"]))


def mediamtx_tag_in_47() -> str:
    m = re.search(r"^MTX_TAG=(\S+)", (SCRIPTS / "47-install-mediamtx.sh").read_text(), re.M)
    return m.group(1) if m else "?"


def check(app: Path, work: Path, feed_url: str | None = None) -> list[tuple[str, str, str, str]]:
    """Returns (status, fix, check, detail) rows. status: PASS, FAIL or INFO."""
    rows = []
    libs = app / "resources" / "libs" / "windows"
    asar = app / "resources" / "app.asar"

    for rel in ["RapsodoGolf.exe", "resources/app.asar", "resources/libs/grpc-env.yaml",
                "resources/libs/windows/libzmq.dll", "resources/libs/windows/libsodium-26.dll",
                "resources/libs/windows/deviceManagerServer.exe"]:
        ok = (app / rel).is_file()
        rows.append(("PASS" if ok else "FAIL", "layout", f"`{rel}` exists",
                     "" if ok else "play.sh, 40 or the launcher expect this file"))

    zmq = libs / "libzmq.dll"
    if zmq.is_file():
        got = sha256(zmq)
        same = got == KNOWN["libzmq.dll"]
        rows.append(("PASS" if same else "FAIL", "Fix 1", "stock `libzmq.dll` is the known 4.3.5 build",
                     "" if same else f"sha256 {got[:16]}…: 40 would still swap in our rebuilt 4.3.5, "
                     "and games are only patched when their libzmq matches the app's. Check the "
                     "new version/exports and update 30-build-libzmq.sh and KNOWN in this script."))

    dm = libs / "deviceManagerServer.exe"
    if dm.is_file():
        got = sha256(dm)
        if got != KNOWN["deviceManagerServer.exe"]:
            rows.append(("INFO", "Fix 2", "`deviceManagerServer.exe` changed", f"sha256 {got[:16]}…"))
        copy = work / "deviceManagerServer.exe"
        for old in (copy, work / "deviceManagerServer.exe.orig"):
            old.unlink(missing_ok=True)
        shutil.copy2(dm, copy)
        rc, out = run_patcher("patch_devicemanager.py", copy)
        rows.append(("PASS" if rc == 0 else "FAIL", "Fix 2", "UDP NETRESET patch applies", out.splitlines()[-1] if out else ""))

    if asar.is_file():
        data = asar.read_bytes()
        copy = work / "app.asar"
        copy.unlink(missing_ok=True)
        shutil.copy2(asar, copy)
        rc, out = run_patcher("patch_alignment_ffmpeg.py", copy)
        rows.append(("PASS" if rc == 0 else "FAIL", "Fix 6", "alignment ffmpeg edit applies", out.splitlines()[-1] if out else ""))
        rc, out = run_patcher("patch_app_polls.py", copy)
        rows.append(("PASS" if rc == 0 else "FAIL", "Fix 7", "game-check and Wi-Fi poll edits apply", "; ".join(out.splitlines())))
        rc, out = run_patcher("patch_app_window.py", copy)
        rows.append(("PASS" if rc == 0 else "FAIL", "Fix 12", "window minimum-size and page-zoom edits apply", "; ".join(out.splitlines())))

        # The MediaMTX release the app downloads, found through its URL template so a
        # renamed minified variable doesn't matter: the last `<name> = "v..."` before it.
        want = mediamtx_tag_in_47()
        m = re.search(rb"`mediamtx_\$\{([\w$]+)\}_", data)
        tag = None
        if m:
            decl = re.compile(rb"(?<![\w$.])" + re.escape(m.group(1)) + rb'\s*=\s*"(v[0-9][0-9.]*)"')
            found = [v.group(1).decode() for v in decl.finditer(data, 0, m.start())]
            tag = found[-1] if found else None
        rows.append(("PASS" if tag == want else "FAIL", "Fix 5", f"app downloads MediaMTX {want} (47's MTX_TAG)",
                     "" if tag == want else f"app wants {tag or 'an unknown version'}: update 47 "
                     "(tag, sha256) and re-check its NETRESET patch"))

        # Where the app keeps MediaMTX (userData = %APPDATA%\\<productName or name>) and
        # its games: 47, 40, 45 and play.sh hardcode both.
        try:
            pkg = asar_package_json(asar)
        except (KeyError, ValueError, OSError) as e:
            pkg = {"error": str(e)}
        user_data = pkg.get("productName") or pkg.get("name")
        ok = user_data == APP_NAME and MEDIAMTX_DIR_CODE in data
        rows.append(("PASS" if ok else "FAIL", "Fix 5", f"app keeps MediaMTX in `%APPDATA%\\{APP_NAME}\\mediamtx` (47's folder)",
                     "" if ok else f"app name is {user_data!r} (productName/name), userData+\"mediamtx\" code "
                     f"{'found' if MEDIAMTX_DIR_CODE in data else 'not found'}: update MTX_DIR in 47"))
        ok = GAMES_DIR_CODE in data
        rows.append(("PASS" if ok else "FAIL", "games", "app keeps games in `ProgramData\\Rapsodo\\SuperApp\\games`",
                     "" if ok else "40, 45 and play.sh's new-game watcher would patch nothing"))

        for line in PLAY_SH_LOG_LINES:
            ok = line in data
            rows.append(("PASS" if ok else "FAIL", "play.sh", f"app still logs `{line.decode()}`",
                         "" if ok else "play.sh's retry or new-game patching keys on it"))

        # A channel's builds point at that channel's own feed.
        m = re.search(rb'updaterFeedURL:\s*"([^"]+)"', data)
        feed = m.group(1).decode() if m else "not found"
        ok = feed == feed_url if feed_url else feed in FEEDS.values()
        rows.append(("PASS" if ok else "FAIL", "watch", "app still updates from the feed this watcher reads",
                     f"{feed}" if ok else f"app's feed is {feed}: point FEEDS at it"))
        rows.append(("INFO", "", "app version (package.json)", str(pkg.get("version", "?"))))

    exe = app / "RapsodoGolf.exe"
    if exe.is_file():
        data = exe.read_bytes()
        e = re.search(rb"Electron/([0-9]+\.[0-9]+\.[0-9]+)", data)
        c = re.search(rb"Chrome/([0-9.]+)", data)
        rows.append(("INFO", "UI", "Electron / Chromium",
                     f"{e.group(1).decode() if e else '?'} / {c.group(1).decode() if c else '?'} "
                     "(tested: 30.5.1 / 124.0.6367.243; a new major can change Fix 6 and the GPU flags)"))
    return rows


def report(title: str, rows: list, extra: str = "") -> str:
    fails = [r for r in rows if r[0] == "FAIL"]
    lines = [f"## {title}", "",
             f"**{'FAIL: ' + str(len(fails)) + ' check(s) need work before users get this release' if fails else 'PASS: every fix still applies'}**",
             ""]
    if extra:
        lines += [extra, ""]
    lines += ["| Result | Fix | Check | Detail |", "|---|---|---|---|"]
    for status, fix, name, detail in rows:
        if status == "FAIL" and fix in IMPACT:
            detail = f"{detail} **Impact:** {IMPACT[fix]}.".strip()
        lines.append(f"| {status} | {fix} | {name} | {detail.replace('|', '/')} |")
    lines += ["", "Static checks only: they don't run Wine, the games or the monitor. "
              "Games update separately (through the app, signed in) and aren't covered."]
    return "\n".join(lines) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    src = ap.add_mutually_exclusive_group()
    src.add_argument("--installer", type=Path, help="a downloaded Rapsodo Golf Setup .exe")
    src.add_argument("--app-dir", type=Path, help="an unpacked stock app folder")
    ap.add_argument("--channel", choices=sorted(FEEDS), default="prod")
    ap.add_argument("--feed-only", action="store_true", help="print '<version> <sha512>' and exit")
    ap.add_argument("--workdir", type=Path, help="keep downloads and unpacked files here")
    ap.add_argument("--report", type=Path, help="also write the Markdown report here")
    args = ap.parse_args()
    # Turn SIGTERM/SIGHUP into an exit, so the work dir is removed and subprocess.run
    # kills a running 7z (as it does on Ctrl-C).
    for sig in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(sig, lambda signum, frame: sys.exit(128 + signum))

    work = args.workdir or Path(tempfile.mkdtemp(prefix="rgm-compat-"))
    work.mkdir(parents=True, exist_ok=True)
    try:
        feed, extra = None, ""
        if args.app_dir:
            app, title = args.app_dir, f"Rapsodo Golf app at {args.app_dir}"
        else:
            if args.installer:
                installer, title = args.installer, f"Rapsodo Golf installer {args.installer.name}"
            else:
                feed = read_feed(args.channel)
                if args.feed_only:
                    print(feed["version"], feed["sha512"])
                    return 0
                installer = work / "setup.exe"
                download(feed["url"], installer, feed["sha512"])
                title = f"Rapsodo Golf PC app {feed['version']} ({args.channel})"
                extra = (f"Released {us_date(feed.get('releaseDate', ''))}; installer `{feed['path']}`, "
                         f"sha512 `{feed['sha512'][:16]}…` (verified).")
            app = unpack(installer, work)
        rows = check(app, work, FEEDS[args.channel] if feed else None)
    except Exception as e:  # noqa: BLE001 - report any failure to run as exit 2
        print(f"error: the compatibility check couldn't run: {e}", file=sys.stderr)
        return 2
    finally:
        if not args.workdir:
            shutil.rmtree(work, ignore_errors=True)
    text = report(title, rows, extra)
    print(text)
    if args.report:
        args.report.write_text(text)
    return 1 if any(r[0] == "FAIL" for r in rows) else 0


if __name__ == "__main__":
    sys.exit(main())
