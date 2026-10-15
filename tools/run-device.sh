#!/bin/bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
# Build, install and launch on the Vision Pro WITHOUT the debugger.
#
# The whole audio saga turned on one thing: launching from Xcode attaches lldb,
# which breaks audio and the compositor XPC. This launches detached via
# devicectl, so `make run` always gives a real, un-ptraced process -- the
# shipping path -- with no Stop-then-tap dance and no attached/detached
# guessing. Logs stream to the terminal.
set -euo pipefail

BUNDLE_ID="com.acervantez.quakeavp.app"
DERIVED="build"

echo "== building =="
xcodebuild -project QuakeAVP.xcodeproj -scheme QuakeAVP \
	-destination generic/platform=visionOS \
	-derivedDataPath "$DERIVED" \
	build >/dev/null

APP=$(find "$DERIVED/Build/Products" -name "QuakeAVP.app" -type d | head -1)
if [ -z "$APP" ]; then echo "no QuakeAVP.app built"; exit 1; fi
echo "built $APP"

# First connected Vision Pro: grab the UUID-shaped identifier from a line that
# mentions Vision Pro and a connected/available state. Matching the UUID pattern
# directly is more robust than guessing a column.
UUID_RE='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'
DEV=$(xcrun devicectl list devices 2>/dev/null \
	| grep -Ei 'vision pro' | grep -Ei 'connected|available' \
	| grep -Eo "$UUID_RE" | head -1)
if [ -z "${DEV:-}" ]; then
	echo "no connected Vision Pro found. Full device list:"
	xcrun devicectl list devices
	echo
	echo "If it is listed but not matched, run its identifier manually:"
	echo "  xcrun devicectl device install app --device <ID> $DERIVED/.../QuakeAVP.app"
	echo "  xcrun devicectl device process launch --device <ID> --console $BUNDLE_ID"
	exit 1
fi
echo "device $DEV"

echo "== installing =="
xcrun devicectl device install app --device "$DEV" "$APP" >/dev/null

echo "== launching (detached, no debugger) =="
# --console streams the app's stdout/stderr here; no lldb is attached.
exec xcrun devicectl device process launch --device "$DEV" --console "$BUNDLE_ID"
