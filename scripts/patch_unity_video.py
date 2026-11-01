#!/usr/bin/env python3
"""Make a Unity game's VideoPlayer decode into system memory (Range swing video).

With Direct3D 11, Unity's Windows video player (WindowsVideoMedia) decodes on its own
D3D11 device and hands every frame to the render device through a DXGI shared handle
(IDXGIResource::GetSharedHandle, then OpenSharedResource). DXVK-macOS can't share
textures ("VK_KHR_EXTERNAL_MEMORY_WIN32 not supported"), so every frame fails with
"Failed getting shared handle from IDXGIResource" (E_INVALIDARG) and the video stays
blank. Unity only takes that path when GetProcAddress(mfplat, "MFCreateDXGIDeviceManager")
succeeds; otherwise it reads frames into system memory and uploads them itself, which
works under Wine. This renames that one string (same length), so the lookup fails.

Only touches a UnityPlayer.dll that loads Media Foundation dynamically (no static
mfplat import) and has the name exactly once.

Usage: patch_unity_video.py [--revert] <UnityPlayer.dll>   (writes <file>.orig once)
"""

import os
import shutil
import struct
import sys
from pathlib import Path

ORIG = b"MFCreateDXGIDeviceManager\0"
PATCHED = b"RGMNoDXGIDeviceManager\0\0\0\0"
assert len(ORIG) == len(PATCHED)


def imported_dlls(data: bytes) -> list[str]:
    """Names in the PE import directory (lowercase)."""
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    nsec = struct.unpack_from("<H", data, pe + 6)[0]
    opt = pe + 24
    opt_size = struct.unpack_from("<H", data, pe + 20)[0]
    dirs = opt + (112 if struct.unpack_from("<H", data, opt)[0] == 0x20B else 96)
    imp_rva = struct.unpack_from("<I", data, dirs + 8)[0]
    sections = [struct.unpack_from("<IIII", data, pe + 24 + opt_size + 40 * i + 8) for i in range(nsec)]

    def off(rva: int) -> int:
        for vsize, va, rsize, raw in sections:
            if va <= rva < va + max(vsize, rsize):
                return raw + rva - va
        raise ValueError(f"RVA {rva:#x} not in any section")

    names, pos = [], off(imp_rva) if imp_rva else None
    while pos is not None:
        name_rva = struct.unpack_from("<I", data, pos + 12)[0]
        if not name_rva:
            break
        start = off(name_rva)
        names.append(data[start : data.index(b"\0", start)].decode("latin1").lower())
        pos += 20
    return names


def main() -> int:
    args = sys.argv[1:]
    revert = args[:1] == ["--revert"]
    if revert:
        args = args[1:]
    if len(args) != 1:
        # A missing path must not make sys.argv[-1] this script itself.
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    dll = Path(args[0])
    data = dll.read_bytes()
    find, put = (PATCHED, ORIG) if revert else (ORIG, PATCHED)
    if data.count(put) == 1 and data.count(find) == 0:
        print(f"already {'reverted' if revert else 'patched'}: {dll}")
        return 0
    if data.count(find) != 1:
        print(f"MFCreateDXGIDeviceManager name not found exactly once in {dll}; not patching", file=sys.stderr)
        return 1
    if any(name.startswith("mf") for name in imported_dlls(data)):
        print(f"{dll} imports Media Foundation directly; not patching", file=sys.stderr)
        return 1
    backup = dll.with_name(dll.name + ".orig")
    if not revert and not backup.exists():
        shutil.copy2(dll, backup)
    # Write a new file and rename it over: a running game keeps its mapped copy.
    tmp = dll.with_name(dll.name + ".new")
    tmp.write_bytes(data.replace(find, put))
    shutil.copymode(dll, tmp)
    os.replace(tmp, dll)
    print(f"{'reverted' if revert else 'patched'} {dll} at file offset {data.index(find)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
