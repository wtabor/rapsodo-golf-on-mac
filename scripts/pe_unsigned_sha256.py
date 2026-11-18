#!/usr/bin/env python3
"""Print the sha256 of a PE file (DLL/EXE) as it was before Authenticode signing.

Rapsodo signs some game DLLs (from Target Range 1.16.0, 11/16/2026): signing
appends a certificate table and sets the PE checksum and the security directory
entry, but leaves the code untouched. This hash drops the appended table and
zeroes those two header fields, so a signed copy hashes like the unsigned build
our patches were checked against. A file that isn't a PE hashes as-is.

Usage: pe_unsigned_sha256.py <file>
"""

import hashlib
import struct
import sys


def unsigned_bytes(data: bytes) -> bytes:
    if len(data) < 0x40 or data[:2] != b"MZ":
        return data
    pe = struct.unpack_from("<I", data, 0x3C)[0]
    if pe + 0x18 > len(data) or data[pe:pe + 4] != b"PE\0\0":
        return data
    opt = pe + 0x18
    magic = struct.unpack_from("<H", data, opt)[0]
    dirs = opt + (0x70 if magic == 0x20B else 0x60)  # PE32+ / PE32
    sec = dirs + 4 * 8  # IMAGE_DIRECTORY_ENTRY_SECURITY
    if sec + 8 > len(data):
        return data
    out = bytearray(data)
    off, size = struct.unpack_from("<II", data, sec)
    if size and off + size == len(data):
        del out[off:]
    # Signing pads the file with zeros to 8 bytes before the table. Drop up to 7
    # trailing zeros from every file, signed or not, so both hash alike.
    n = 0
    while n < 7 and out and out[-1] == 0:
        out.pop()
        n += 1
    out[opt + 0x40:opt + 0x44] = b"\0" * 4  # CheckSum
    out[sec:sec + 8] = b"\0" * 8
    return bytes(out)


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as f:
        print(hashlib.sha256(unsigned_bytes(f.read())).hexdigest())
    return 0


if __name__ == "__main__":
    sys.exit(main())
