#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-rig-store.sh
#
# A value with a store on the Swift side must not also be archived per game.
#
# CVAR_ARCHIVE sounds like "remember this", and for a knob the engine owns it
# is. For a knob the INPUT PROFILE owns it is a second store, and not one per
# player but one per GAME: Host_WriteConfiguration writes config.cfg into
# com_gamedir, so each installed pack keeps a frozen copy, and a `game` switch
# re-execs that pack's chain and overwrites the profile with whatever happened
# to be live the last time that directory was archived.
#
# It had been true for a year before anyone switched game twice in a session.
# Six packs on one headset held eleven of these at two different values: id1
# and rogue carried the controller profile's numbers while the other four
# carried the hands profile's, so bare hands in those two games aimed the gun
# 26 degrees high, swung it 29 degrees across, and tilted the weapon ring onto
# a plane the Swift-side selection math no longer agreed with.
#
# The list is DERIVED from the Swift sources rather than restated here, because
# a hardcoded list of 27 names is a 28th name waiting to be forgotten. Whatever
# ProfileStore and WeaponTrim push is what must not be archived, by definition.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/App/Sources"
IN_NULL="$ROOT_DIR/Sources/QuakeCore/platform/in_null.c"
fails=0

# Every cvar the two Swift stores push. The pattern is the opening of the
# command string, `"vr_name ` with the trailing space, which is what both
# `send("vr_x \(v)")` and `sendCommand?("vr_x \(v)\n")` start with.
owned=$(grep -oh '"vr_[a-z_0-9]* ' "$SRC/InputProfile.swift" "$SRC/WeaponTrim.swift" \
	| tr -d '" ' | sort -u)

if [ -z "$owned" ]; then
	echo "FAIL: found no profile-pushed cvars at all -- the extraction broke,"
	echo "      which would make this guard pass by finding nothing to check"
	exit 1
fi

for name in $owned; do
	decl=$(grep -h "cvar_t[[:space:]].*{\"$name\"," "$IN_NULL" || true)
	if [ -z "$decl" ]; then
		echo "FAIL: $name is pushed by the Swift store but declared nowhere in in_null.c"
		fails=$((fails + 1))
	elif printf '%s' "$decl" | grep -q 'CVAR_ARCHIVE'; then
		echo "FAIL: $name has a profile store AND CVAR_ARCHIVE, so a game switch"
		echo "      will revert it to whatever that pack's config.cfg last held"
		fails=$((fails + 1))
	else
		echo "ok:   $name is profile-owned and not archived per game"
	fi
done

echo
echo "checked $(printf '%s\n' "$owned" | wc -l | tr -d ' ') profile-owned cvars"

if [ "$fails" -ne 0 ]; then
	echo "$fails FAILURES"
	exit 1
fi
echo "all passed"
