#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-swift-weapons.sh
#
# Compiles and runs the weapon-trim persistence migration
# (App/Sources/WeaponTrimMigration.swift) against its host test, alone -- no
# Observation, no engine bridge, no simulator, no rest of the app module.
# The isolation is the point: the migration is the one half of the weapon
# tuning that can be proved before it meets a device, and it only stays
# provable while it imports nothing but Foundation. This is how
# tools/swifttest/weapons_test.swift gets re-run.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${TMPDIR:-/tmp}/qavp-weapons"

swiftc -O \
	"$ROOT_DIR/tools/swifttest/weapons_test.swift" \
	"$ROOT_DIR/App/Sources/WeaponTrimMigration.swift" \
	-o "$OUT"

"$OUT"
