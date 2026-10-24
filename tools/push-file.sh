#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# push-file.sh LOCAL [DEVICE_PATH]
#
# Copy a file into the app's own data container on the connected Vision Pro.
# DEVICE_PATH is relative to the container and defaults to the engine's save
# directory, so a `.sav` or a `.jpg` put there is a file the running engine
# and the save browser both see.
#
# THAT DIRECTORY IS NOT Documents/id1. The dev build seeds the paks into
# Documents/id1, which makes it look like the game directory, and it is not:
# COM_AddGameDirectory re-points com_gamedir at Application Support, and
# `Saving game to .../Library/Application Support/QuakeAVP/id1/s0.sav` in the
# console is the proof. Files pushed to Documents/id1 are simply never
# scanned, with nothing reporting an error, because nothing is wrong there --
# they are just somewhere else. QuakeCore.h says this on com_gamedir too.
#
# This exists because two of the device checks in
# .superpowers/sdd/window-menu-report.md cannot be produced by the app: a
# save the engine would refuse (a version it never writes) and a cover
# caught mid-write (a zero-byte JPEG). Both have to be planted. The cover
# path was first proven exactly this way, by hand, before anything existed
# that could produce a cover at all.
#
# The reverse direction is tools/pull-console.sh.

set -e

if [ -z "${1:-}" ]; then
	echo "usage: $0 LOCAL [DEVICE_PATH]   (default Documents/id1/<basename>)"
	exit 2
fi

LOCAL="$1"
[ -f "$LOCAL" ] || { echo "no such file: $LOCAL"; exit 1; }
DEST="${2:-Library/Application Support/QuakeAVP/id1/$(basename "$LOCAL")}"
BUNDLE_ID="com.acervantez.quakeavp.app"

UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
DEV=$(xcrun devicectl list devices 2>/dev/null \
	| grep -Ei 'vision pro' | grep -Ei 'connected|available' \
	| grep -Eo "$UUID_RE" | head -1)
if [ -z "${DEV:-}" ]; then
	echo "no connected Vision Pro found. Full device list:"
	xcrun devicectl list devices
	exit 1
fi

xcrun devicectl device copy to \
	--device "$DEV" \
	--domain-type appDataContainer \
	--domain-identifier "$BUNDLE_ID" \
	--source "$LOCAL" \
	--destination "$DEST" >/dev/null

echo "pushed $(basename "$LOCAL") -> $DEST"
