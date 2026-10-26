#!/usr/bin/env python3
"""Patch deviceManagerServer.exe so Go's UDP sockets work under Wine.

Go's Windows UDP setup calls WSAIoctl(SIO_UDP_CONNRESET) then
WSAIoctl(SIO_UDP_NETRESET). Wine 11 stubs the first and rejects the second
(WSAEOPNOTSUPP, 10045), which kills the app's CoAP certificate request to the
monitor and makes APIAuthenticate fail. This rewrites the single
`mov $0x9800000f,%ebx` (NETRESET) to `mov $0x9800000c,%ebx` (CONNRESET).
The same fix works for the games' deviceManagerServer.dll and for MediaMTX
(mediamtx.exe, also Go), which otherwise exits on its first UDP listener.

Usage: patch_devicemanager.py <Go .exe or .dll>   (writes <file>.orig once)
"""

import shutil
import sys
from pathlib import Path

NETRESET = bytes.fromhex("bb0f000098")  # mov $0x9800000f,%ebx
CONNRESET = bytes.fromhex("bb0c000098")  # mov $0x9800000c,%ebx


def main() -> int:
    exe = Path(sys.argv[1])
    data = bytearray(exe.read_bytes())
    if data.count(NETRESET) == 0 and data.count(CONNRESET) == 2:
        print(f"already patched: {exe}")
        return 0
    hits = data.count(NETRESET)
    if hits != 1:
        print(f"expected 1 SIO_UDP_NETRESET site, found {hits}; not patching", file=sys.stderr)
        return 1
    backup = exe.with_name(exe.name + ".orig")
    if not backup.exists():
        shutil.copy2(exe, backup)
    pos = data.index(NETRESET)
    data[pos : pos + len(NETRESET)] = CONNRESET
    exe.write_bytes(data)
    print(f"patched {exe} at file offset {pos + 1} (backup: {backup.name})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
