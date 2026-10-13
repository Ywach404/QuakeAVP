#!/bin/sh
#
# check-swift-wristcomm.sh
#
# Compiles and runs the wrist communicator's pure math
# (App/Sources/WristCommMath.swift) against its host test, alone -- no
# ARKit/Metal/Observation, no simulator, no rest of the app module. Pulls in
# App/Sources/HudEditorMath.swift too, since the comm math reuses
# HudEditor.WristFrame/offsetInFrame/gridHalfY. This is how
# tools/swifttest/wrist_comm_test.swift gets re-run.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/wristcomm"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/wrist_comm_test.swift" \
	"$ROOT_DIR/App/Sources/WristCommMath.swift" \
	"$ROOT_DIR/App/Sources/HudEditorMath.swift" \
	-o "$OUT"

"$OUT"
