#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-swift-input.sh
#
# Compiles and runs the HUD live editor's grab/move/scale state machine
# (HudEditor.updateGrab, in App/Sources/HudEditorMath.swift) against its
# host test, alone -- no ARKit/GameController/Observation, no simulator, no
# rest of the app module. This is how
# tools/swifttest/hud_editor_input_test.swift gets re-run; it never compiles
# HudEditorInput.swift (the ARKit/GameController plumbing), which only
# builds as part of `make device`.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/heinput"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/hud_editor_input_test.swift" \
	"$ROOT_DIR/App/Sources/HudEditorMath.swift" \
	-o "$OUT"

"$OUT"
