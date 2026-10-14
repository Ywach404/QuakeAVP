#!/bin/sh
#
# check-swift-session.sh
#
# Compiles and runs the window Game tab's pure halves
# (App/Sources/SaveGames.swift, App/Sources/ConsoleArgument.swift) against
# their host test, alone -- no Observation, no engine bridge, no simulator,
# no rest of the app module. This is how tools/swifttest/session_test.swift
# gets re-run.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/qavp-session"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/session_test.swift" \
	"$ROOT_DIR/App/Sources/SaveGames.swift" \
	"$ROOT_DIR/App/Sources/ConsoleArgument.swift" \
	-o "$OUT"

"$OUT"
