#!/usr/bin/env python3
"""Make Wine report the real display topology, so games see a second screen.

Wine's NtUserQueryDisplayConfig (win32u.so) always answers
QDC_DATABASE_CURRENT with DISPLAYCONFIG_TOPOLOGY_INTERNAL ("laptop screen
only"), even with two displays active. Rapsodo's Unity games read that topology
for their Extended Screens panel and show "Second screen not detected" although
EnumDisplayMonitors and the display paths list both screens.

This rewrites two spots of that function in Gcenx's wine-staging 11.16 build
(pinned by sha256; any other build is refused):
  - where it stored INTERNAL (the FIXME print that preceded it is dropped): keep
    the caller's topology pointer in an unused stack slot, store INTERNAL as a
    placeholder, and put a small code cave in the freed bytes;
  - the success path: jump to the cave, which (after the original stores of the
    path and mode counts) sets the topology to EXTEND when 2+ paths were returned,
    else INTERNAL, then continues at the original unlock.
macOS mirroring shows up in Wine as one display, so CLONE is never reported.
SetDisplayConfig stays a Wine stub (returns success, changes nothing): the game's
Mirror/Extend buttons don't change the Mac's display arrangement.

The new file is ad-hoc signed and swapped in by rename (macOS caches code
signatures per vnode). Restart Wine (the app) for it to take effect.

Usage: patch_wine_topology.py [--revert] <wine>/lib/wine/x86_64-unix/win32u.so
"""

import hashlib
import os
import shutil
import subprocess
import sys
from pathlib import Path

STOCK_SHA256 = "48e91706aaebd2752f74e1364c8ef8335acb9459123469c179ae71469ff02ac8"

SITE_A = 0x13EA5A  # testq %rbx,%rbx ... movl $0x1,(%rbx)   (75 bytes, up to 0x13eaa5)
SITE_B = 0x13EEAD  # movl %r8d,(%r15); movl %ebx,(%r14); xorl %r13d,%r13d  (9 bytes)
CAVE = 0x13EA6E
RESUME = 0x13EEB6  # leaq <display lock>,%rdi; callq unlock (shared with the error paths)
AFTER_A = 0x13EAA5

ORIG_B = bytes.fromhex("458907" "41891e" "4531ed")


def rel32(src_next: int, dst: int) -> bytes:
    return (dst - src_next).to_bytes(4, "little", signed=True)


def build() -> tuple[bytes, bytes]:
    a = bytearray()
    a += bytes.fromhex("48899d70ffffff")  # mov %rbx,-0x90(%rbp)   topology ptr (or NULL)
    a += bytes.fromhex("4885db")  # test %rbx,%rbx
    a += bytes.fromhex("7406")  # je +6
    a += bytes.fromhex("c70301000000")  # movl $1,(%rbx)          INTERNAL until we know
    a += b"\xeb" + bytes([AFTER_A - (SITE_A + len(a) + 2)])  # jmp 0x13eaa5
    assert SITE_A + len(a) == CAVE
    a += ORIG_B  # the success path's own stores and r13d = 0
    a += bytes.fromhex("488b8570ffffff")  # mov -0x90(%rbp),%rax
    a += bytes.fromhex("4885c0")  # test %rax,%rax
    a += bytes.fromhex("7413")  # je +0x13 (to the jmp back)
    a += bytes.fromhex("b901000000")  # mov $1,%ecx   INTERNAL
    a += bytes.fromhex("ba04000000")  # mov $4,%edx   EXTEND
    a += bytes.fromhex("4183f801")  # cmp $1,%r8d   path count
    a += bytes.fromhex("0f47ca")  # cmova %edx,%ecx
    a += bytes.fromhex("8908")  # mov %ecx,(%rax)
    a += b"\xe9" + rel32(SITE_A + len(a) + 5, RESUME)  # jmp 0x13eeb6
    a += b"\xcc" * (AFTER_A - SITE_A - len(a))
    assert len(a) == AFTER_A - SITE_A
    b = b"\xe9" + rel32(SITE_B + 5, CAVE) + b"\xcc" * 4
    assert len(b) == len(ORIG_B)
    return bytes(a), b


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def swap_in(target: Path, data: bytes, sign: bool) -> None:
    tmp = target.with_name(target.name + ".rgmtmp")
    tmp.write_bytes(data)
    os.chmod(tmp, target.stat().st_mode & 0o7777)
    if sign:  # the stock file is already signed; keep it byte for byte
        subprocess.run(["codesign", "-f", "-s", "-", str(tmp)], check=True, capture_output=True)
    os.replace(tmp, target)


def main() -> int:
    args = sys.argv[1:]
    revert = bool(args) and args[0] == "--revert"
    if revert:
        args = args[1:]
    if len(args) != 1:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    target = Path(args[0])
    if not target.is_file():
        print(f"not found: {target}", file=sys.stderr)
        return 1
    data = target.read_bytes()
    new_a, new_b = build()
    patched = (data[SITE_A : SITE_A + len(new_a)] == new_a
               and data[SITE_B : SITE_B + len(new_b)] == new_b)
    backup = target.with_name(target.name + ".orig")

    if revert:
        if not patched:
            print(f"already reverted: {target}")
            return 0
        if not backup.exists() or sha256(backup.read_bytes()) != STOCK_SHA256:
            print(f"no stock backup ({backup.name}); not reverting", file=sys.stderr)
            return 1
        swap_in(target, backup.read_bytes(), sign=False)
        print(f"reverted {target}")
        return 0

    if patched:
        print(f"already patched: {target}")
        return 0
    if sha256(data) != STOCK_SHA256:
        print(f"unknown win32u.so build (sha256 {sha256(data)[:12]}…); not patching",
              file=sys.stderr)
        return 1
    out = bytearray(data)
    out[SITE_A : SITE_A + len(new_a)] = new_a
    out[SITE_B : SITE_B + len(new_b)] = new_b
    if not backup.exists():
        shutil.copy2(target, backup)
    swap_in(target, bytes(out), sign=True)
    print(f"patched {target} (backup: {backup.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
