#!/bin/sh
#
# check-swift-math.sh
#
# Compiles and runs the HUD live editor's pure placement math
# (App/Sources/HudEditorMath.swift) against its host test, alone -- no
# ARKit/Metal/Observation, no simulator, no rest of the app module. This is
# how tools/swifttest/hud_editor_math_test.swift gets re-run.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/hemath"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/hud_editor_math_test.swift" \
	"$ROOT_DIR/App/Sources/HudEditorMath.swift" \
	-o "$OUT"

"$OUT"
