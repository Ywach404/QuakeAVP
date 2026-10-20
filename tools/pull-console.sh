#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# pull-console.sh
#
# Fetch the console the headset saved. Tap "Save" beside the command bar in
# the app's console pane, then run this; the file lands in the current
# directory as console.log and is printed.
#
# The app writes to its Documents folder rather than the game directory,
# which is not writable on device -- paks are read through the platform file
# layer and not a real path, so the engine's own `condump` writes nothing.

set -e

BUNDLE_ID="com.acervantez.quakeavp.app"
OUT="${1:-console.log}"

UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
DEV=$(xcrun devicectl list devices 2>/dev/null \
	| grep -Ei 'vision pro' | grep -Ei 'connected|available' \
	| grep -Eo "$UUID_RE" | head -1)
if [ -z "${DEV:-}" ]; then
	echo "no connected Vision Pro found. Full device list:"
	xcrun devicectl list devices
	exit 1
fi

rm -f "$OUT"
xcrun devicectl device copy from \
	--device "$DEV" \
	--domain-type appDataContainer \
	--domain-identifier "$BUNDLE_ID" \
	--source Documents/console.log \
	--destination "$OUT" >/dev/null

echo "== $OUT =="
cat "$OUT"
