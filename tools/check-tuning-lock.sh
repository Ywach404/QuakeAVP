#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-tuning-lock.sh
#
# Every drag-driven control in the panel must be under the tuning lock.
#
# This is a SOURCE check rather than a unit test because what it guards is
# not behaviour, it is coverage: the lock works by being applied at each
# control, and the failure mode is a slider added later that nobody
# remembered to mark. That cannot be caught by testing the lock -- the lock
# would pass -- and it cannot be caught in the headset either, because an
# unlocked slider looks exactly like a locked one until a stray pinch moves
# it, which is the bug.
#
# A raw `Slider(value:` must be followed by `.tuningLocked()` within 20
# lines, and `gyroDisc` -- the one place all three dials go through -- must
# carry it too. The deliberate exemption is listed below with its reason.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/App/Sources/ContentView.swift"
fails=0

# The phase column is a SIBLING of the tab panel, not content inside its
# scroll view, so there is no scroll gesture for a pinch to misfire into and
# none of its three sliders is locked -- the lock pill that would explain a
# greyed row is in a different column entirely. They are still logged.
PHASE_FROM=$(grep -n 'private var phaseControls' "$SRC" | cut -d: -f1)

SLIDER_LINES=$(grep -nE '(^|[^A-Za-z])Slider\(value:' "$SRC" | cut -d: -f1)

for line in $SLIDER_LINES; do
	if [ -n "$PHASE_FROM" ] && [ "$line" -gt "$PHASE_FROM" ]; then
		echo "skip: ContentView.swift:$line is in the phase column, outside the panel"
		continue
	fi
	# Stop at the NEXT slider rather than at a fixed offset. With a flat
	# 20-line window two rows sitting close together let a missing
	# modifier borrow its neighbour's and pass, which would make the
	# check weakest exactly where the rows are densest.
	next=$(echo "$SLIDER_LINES" | awk -v l="$line" '$1 > l { print $1; exit }')
	end=$((line + 20))
	if [ -n "$next" ] && [ "$next" -le "$end" ]; then end=$((next - 1)); fi
	if sed -n "${line},${end}p" "$SRC" | grep -q '\.tuningLocked('; then
		echo "ok:   ContentView.swift:$line is under the tuning lock"
	else
		echo "FAIL: ContentView.swift:$line is a slider with no .tuningLocked()"
		fails=$((fails + 1))
	fi
done

# tuning-log-names.py cannot read a wrapper's body, so it ASSUMES how each
# one derives its log name. Those assumptions are pinned here: without this,
# dropping placeSlider's prefix would reintroduce the weapon tab's three-way
# "Up" collision while the duplicate check went on passing, because the check
# would still believe the prefix was there.
check_body() {
	if awk "/private func $1/,/^    \}/" "$SRC" | grep -q -- "$2"; then
		echo "ok:   $1 logs the name $3"
	else
		echo "FAIL: $1 no longer logs the name $3 -- tuning-log-names.py assumes it does"
		fails=$((fails + 1))
	fi
}
check_body placeSlider 'noteTuning("gun ' 'prefixed with gun'
check_body placementSlider 'noteTuning(cvar,' 'of its cvar'
check_body commPlaceRow 'commAlongArm ?' 'with the across/along mode'

# No two controls on one tab may log under the same name. See
# tools/tuning-log-names.py for why a collision drops a change outright.
dupes=$(python3 "$ROOT_DIR/tools/tuning-log-names.py" "$SRC")
if [ -n "$dupes" ]; then
	echo "$dupes" | sed 's/^/FAIL: two controls log under one name -- /'
	fails=$((fails + 1))
else
	echo "ok:   no two controls on a tab share a log name"
fi

# The dials. gyroDial and commDisc are thin wrappers over gyroDisc, so the
# lock belongs on the one of them that owns the DragGesture.
if awk '/private func gyroDisc/,/^    \}/' "$SRC" | grep -q '\.tuningLocked('; then
	echo "ok:   gyroDisc is under the tuning lock"
else
	echo "FAIL: gyroDisc has no .tuningLocked() -- every dial is unlocked"
	fails=$((fails + 1))
fi

# The dials must be LOGGED as well as locked, and that is a separate miss:
# gyroDisc owns the gesture, so the lock belongs there, but only gyroDial and
# commDisc know what their axes are CALLED -- so the lock passing says nothing
# about whether a dial drag is reported. It was in fact missed the first time.
for fn in gyroDial commDisc; do
	if awk "/private func $fn/,/^    \}/" "$SRC" | grep -q 'noteTuning('; then
		echo "ok:   $fn reports its changes"
	else
		echo "FAIL: $fn moves a tuned value without a [tune] line"
		fails=$((fails + 1))
	fi
done

# The lock must default to engaged. A lock that starts off is decoration.
if grep -q 'var isLocked = true' "$ROOT_DIR/App/Sources/TuningLock.swift"; then
	echo "ok:   the lock defaults to locked"
else
	echo "FAIL: TuningLock.isLocked does not default to true"
	fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
	echo "TUNING LOCK FAIL ($fails)"
	exit 1
fi
echo "TUNING LOCK PASS"
