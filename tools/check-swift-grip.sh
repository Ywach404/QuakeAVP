#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-swift-grip.sh
#
# Compiles and runs the off-hand rope grip latch (App/Sources/GripLatch.swift)
# against its host test, alone -- no ARKit, no GameController, no rest of the
# app module. Same seam as tools/check-swift-fist.sh and for the same reason:
# the policy worth asserting is a SEQUENCE of updates, several of which never
# measured the hand, and nothing about that needs a device.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/griptest"

rm -f "$OUT"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/grip_test.swift" \
	"$ROOT_DIR/App/Sources/GripLatch.swift" \
	-o "$OUT"

"$OUT"

# The other half of the same contract, which running the type cannot show: the
# rope bit must be set from the LATCH and never from the raw reading. That one
# substitution is the whole of the original bug (a wipeable field decided
# whether a player stayed on a rope), it is a one-word edit to make by
# accident, and HandInput.swift only compiles under `make device`, so nothing
# else in the tree would catch it.
IN="$ROOT_DIR/App/Sources/HandInput.swift"
bits=$(grep -c 'QC_PAD_RSHOULDER' "$IN")
if [ "$bits" -eq 0 ]; then
	echo "FAIL: found no QC_PAD_RSHOULDER in HandInput.swift at all, so this"
	echo "      guard would pass by having nothing to check"
	exit 1
fi
bad=$(grep -n 'QC_PAD_RSHOULDER' "$IN" | grep 'fistClosed' || true)
if [ -n "$bad" ]; then
	echo "FAIL: the rope bit is set from the raw fist reading, which a tracking"
	echo "      loss wipes. It must come from GripLatch, or crossing your hands"
	echo "      drops you off the rope again:"
	echo "$bad"
	exit 1
fi
echo "ok:   the rope bit ($bits site(s)) is not set from the wipeable reading"
