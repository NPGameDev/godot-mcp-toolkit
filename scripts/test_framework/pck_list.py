"""List the files a standalone Godot 4 PCK carries, one res:// path per line.

The export-strip check asserts on this listing rather than grepping the PCK's
bytes: the exported class cache, uid_cache.bin and project.binary all name the
addon's script paths as metadata, so a byte grep would flag a clean export.

Reads pack format versions 2 (Godot 4.2-4.4), 3 (4.5-4.6) and 4 (4.7), the
layout in core/io/file_access_pack.cpp. An encrypted directory cannot be read
without the key, so it is an error rather than an empty listing.

Usage: python3 scripts/test_framework/pck_list.py <file.pck>
Exit 0 = listed, 1 = not a PCK this script can read.
"""

import struct
import sys

_MAGIC = b"GDPC"
_SUPPORTED_VERSIONS = (2, 3, 4)
_DIR_ENCRYPTED = 1 << 0
_FILE_REMOVAL = 1 << 1
_RESERVED_V2 = 16 * 4


def list_paths(data):
    """Return the pack's file paths, each with a res:// prefix.

    From pack format 3 on, the engine stores paths without the prefix, so it
    is added back to give one spelling across versions.
    """
    if data[:4] != _MAGIC:
        raise ValueError("no GDPC magic at offset 0 (not a standalone PCK)")
    version, = struct.unpack_from("<I", data, 4)
    if version not in _SUPPORTED_VERSIONS:
        raise ValueError("unsupported pack format version %d" % version)
    # Magic, then format version and the engine's major, minor and patch.
    offset = 20
    flags, _file_base = struct.unpack_from("<IQ", data, offset)
    offset += 12
    if flags & _DIR_ENCRYPTED:
        raise ValueError("the pack directory is encrypted")
    if version >= 3:
        offset, = struct.unpack_from("<Q", data, offset)
    else:
        offset += _RESERVED_V2
    count, = struct.unpack_from("<I", data, offset)
    offset += 4
    paths = []
    for _ in range(count):
        length, = struct.unpack_from("<I", data, offset)
        offset += 4
        path = data[offset:offset + length].rstrip(b"\0").decode("utf-8")
        offset += length
        # File offset, size and MD5, then the per-file flags.
        offset += 8 + 8 + 16
        file_flags, = struct.unpack_from("<I", data, offset)
        offset += 4
        if file_flags & _FILE_REMOVAL:
            continue
        if not path.startswith("res://"):
            path = "res://" + path
        paths.append(path)
    return paths


def main(argv):
    if len(argv) != 2:
        print("usage: pck_list.py <file.pck>", file=sys.stderr)
        return 1
    with open(argv[1], "rb") as pck:
        data = pck.read()
    try:
        paths = list_paths(data)
    except (ValueError, struct.error) as err:
        print("pck_list.py: %s: %s" % (argv[1], err), file=sys.stderr)
        return 1
    for path in paths:
        print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
