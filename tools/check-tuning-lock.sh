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

# The phase LEVEL slider is the dissolve itself, scrubbed live during play
# rather than tuned once -- an action, not a held value. Locking it would
# take away a control that is meant to be used with the lock on.
EXEMPT='\$phaseLevel'

for line in $(grep -nE '(^|[^A-Za-z])Slider\(value:' "$SRC" | cut -d: -f1); do
	text=$(sed -n "${line}p" "$SRC")
	if echo "$text" | grep -q "$EXEMPT"; then
		echo "skip: ContentView.swift:$line exempt (the phase level is an action)"
		continue
	fi
	end=$((line + 20))
	if sed -n "${line},${end}p" "$SRC" | grep -q '\.tuningLocked('; then
		echo "ok:   ContentView.swift:$line is under the tuning lock"
	else
		echo "FAIL: ContentView.swift:$line is a slider with no .tuningLocked()"
		fails=$((fails + 1))
	fi
done

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
