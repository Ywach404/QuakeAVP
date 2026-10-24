# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# tuning-log-names.py -- report any two controls on one tab that would log
# under the same name. Run by tools/check-tuning-lock.sh; prints one line per
# collision and nothing when there are none.
#
# A collision is not a cosmetic problem. Changes coalesce per name, so two
# controls sharing one merge into a SINGLE line carrying the first control's
# starting value and the second control's final value, and the second change
# is never reported at all -- a wrong line and a dropped line, silently. The
# weapon tab had three "Up" sliders and three "Side" when this was written.

import re
import sys

src = open(sys.argv[1]).read().split('\n')

TABS = ['gameContent', 'comfortContent', 'weaponContent',
        'adminContent', 'captureContent', 'debugContent']

starts = {}
for i, line in enumerate(src):
    for tab in TABS:
        if re.search(r'private var %s: some View' % tab, line):
            starts[tab] = i
order = sorted(starts.items(), key=lambda kv: kv[1])

# Wrappers whose first string argument becomes the log name. placementSlider
# and commPlaceRow are deliberately absent: the first logs its cvar, which is
# unique by construction, and the second appends the across/along mode.
PATTERN = re.compile(
    r'\b(placeSlider|trimSlider|transformSlider|tuneRow|offHandSlider)\("([^"]+)"')

collisions = []
for idx, (tab, start) in enumerate(order):
    end = order[idx + 1][1] if idx + 1 < len(order) else len(src)
    seen = {}
    for i in range(start, end):
        for m in PATTERN.finditer(src[i]):
            name = m.group(2)
            if m.group(1) == 'placeSlider':
                name = 'gun ' + name      # matches the call in placeSlider
            seen.setdefault(name, []).append(i + 1)
    for name, lines in sorted(seen.items()):
        if len(lines) > 1:
            collisions.append('%s: "%s" at lines %s'
                              % (tab, name, ', '.join(map(str, lines))))

for c in collisions:
    print(c)
