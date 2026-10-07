#!/bin/bash
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

APP=$(find "$DERIVED/Build/Products" -name "Quake.app" -type d | head -1)
if [ -z "$APP" ]; then echo "no Quake.app built"; exit 1; fi
echo "built $APP"

# First connected Vision Pro (a real device, not a simulator).
DEV=$(xcrun devicectl list devices 2>/dev/null \
	| awk -F'  +' '/Vision Pro|xros|visionOS/ && /connected|available/ {print $3; exit}')
if [ -z "${DEV:-}" ]; then
	echo "no connected Vision Pro found. Devices:"
	xcrun devicectl list devices
	exit 1
fi
echo "device $DEV"

echo "== installing =="
xcrun devicectl device install app --device "$DEV" "$APP" >/dev/null

echo "== launching (detached, no debugger) =="
# --console streams the app's stdout/stderr here; no lldb is attached.
exec xcrun devicectl device process launch --device "$DEV" --console "$BUNDLE_ID"
