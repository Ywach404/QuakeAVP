#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez

"""
mkpak.py -- wrap files into a Quake .pak.

The reason this exists: shareware Quake refuses LOOSE files in
subdirectories (COM_FindFile skips any filename containing a slash unless
`registered` is set -- id's original anti-piracy check), so a custom map
can't be dropped in as id1/maps/range.bsp. Files inside a pak are exempt.
The first argument below is the OUTPUT path -- never point it at a real pak.
Stage the result as id1/pak2.pak (the app's own slot for a generated pak,
next to pak0.pak and pak1.pak if you have one), or as id1/pak1.pak only in
the shareware-only case where no real pak1.pak exists.

  python3 tools/range/mkpak.py out.pak maps/range.bsp=path/to/range.bsp ...
"""

import struct
import sys
from pathlib import Path


def main() -> None:
    if len(sys.argv) < 3:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    entries = []
    data = b""
    for spec in sys.argv[2:]:
        inner, _, src = spec.partition("=")
        if not src:
            sys.exit(f"bad spec (want inner=path): {spec}")
        if len(inner) > 55:
            sys.exit(f"pak name too long: {inner}")
        blob = Path(src).read_bytes()
        entries.append((inner, 12 + len(data), len(blob)))
        data += blob
    diroff = 12 + len(data)
    pak = b"PACK" + struct.pack("<ii", diroff, len(entries) * 64) + data
    for name, off, size in entries:
        pak += struct.pack("<56sii", name.encode("latin-1"), off, size)
    out.write_bytes(pak)
    print(f"wrote {out} ({len(entries)} files, {len(pak)} bytes)")


if __name__ == "__main__":
    main()
