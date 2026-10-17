#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-swift-floor.sh
#
# Compiles and runs the immersive floor anchor's pure math
# (App/Sources/FloorMath.swift) against its host test, alone -- no ARKit,
# no Metal, no engine, no simulator. This is how
# tools/swifttest/floor_test.swift gets re-run.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/floortest"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/floor_test.swift" \
	"$ROOT_DIR/App/Sources/FloorMath.swift" \
	-o "$OUT"

"$OUT"
