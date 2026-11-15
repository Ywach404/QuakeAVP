#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-swift-fist.sh
#
# Compiles and runs the off-hand fist gate (App/Sources/FistMath.swift)
# against its host test, alone -- no ARKit, no GameController, no rest of the
# app module. This is how tools/swifttest/fist_test.swift gets re-run; it
# never compiles HandInput.swift (the ARKit plumbing that measures the four
# fingers and feeds them in), which only builds as part of `make device`.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/fisttest"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/fist_test.swift" \
	"$ROOT_DIR/App/Sources/FistMath.swift" \
	-o "$OUT"

"$OUT"
