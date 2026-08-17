#!/usr/bin/env python3
"""
genpop.py -- emit gfx/pop.lmp to stdout.

Shareware Quake refuses custom/extra paks unless it finds gfx/pop.lmp, the
"registered" token. Its 256 bytes are 128 big-endian shorts whose values
are published verbatim in the open-source engine (common.c `pop[]`) -- so
this reads them straight out of the checked-in engine source rather than
embedding a copy. Not an id asset: a lookup table in GPL engine code, used
here only to unlock a personal dev build for a custom test map on the
user's own device.

  python3 tools/range/genpop.py > pop.lmp
"""

import re
import struct
import sys
from pathlib import Path

ENGINE = Path(__file__).resolve().parents[2] / "Sources/QuakeCore/engine/common.c"


def main() -> None:
    src = ENGINE.read_text()
    m = re.search(r"static unsigned short pop\[\] =\s*\{(.*?)\};", src, re.S)
    if not m:
        sys.exit("pop[] table not found in common.c")
    vals = [int(x, 16) for x in re.findall(r"0x[0-9a-fA-F]{4}", m.group(1))]
    if len(vals) != 128:
        sys.exit(f"expected 128 shorts, found {len(vals)}")
    sys.stdout.buffer.write(b"".join(struct.pack(">H", v) for v in vals))


if __name__ == "__main__":
    main()
