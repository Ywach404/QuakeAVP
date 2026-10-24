# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# tuning-tab-inventory.py -- which panel tabs actually hold a drag-driven
# control, counted from each tab's body. Run by tools/check-tuning-lock.sh to
# keep ContentView's `tabIsTunable` honest.
#
# The lock pill only appears on a tab that has something to lock, because a
# pill explaining that sliders are held says nothing on a tab of buttons. That
# makes the list a second place the truth is written down, and the failure is
# quiet in the wrong direction: a tab growing its FIRST slider keeps the lock
# (which applies everywhere) and loses the only on-screen explanation of why
# that slider has gone grey.

import re
import sys

src = open(sys.argv[1]).read().split('\n')

TABS = ['gameContent', 'comfortContent', 'weaponContent',
        'adminContent', 'captureContent', 'debugContent']

DRAG = re.compile(
    r'\b(placeSlider|trimSlider|transformSlider|tuneRow|commPlaceRow'
    r'|placementSlider|offHandSlider|gyroDial|commDisc)\(|Slider\(value:')

starts = {}
for i, line in enumerate(src):
    for tab in TABS:
        if re.search(r'private var %s: some View' % tab, line):
            starts[tab] = i
order = sorted(starts.items(), key=lambda kv: kv[1])

for idx, (tab, start) in enumerate(order):
    end = order[idx + 1][1] if idx + 1 < len(order) else len(src)
    count = sum(1 for i in range(start, end) for _ in DRAG.finditer(src[i]))
    # strip the "Content" suffix to match PanelTab's case names
    print('%s %d' % (tab[:-len('Content')], count))
