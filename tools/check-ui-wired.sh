#!/bin/sh
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 A. Cervantez
#
# check-ui-wired.sh
#
# A model that exists to be DISPLAYED must be displayed by something.
#
# This is the third time a host test has passed over a feature that was not on
# screen. `CoverFlowMetrics.badges(for:)` computed both save-refusal warnings,
# had seven assertions over it, and no view ever called it: the Load button was
# correctly disabled and the card looked ordinary, so the only way to discover
# why a save would not load was to try it. The test suite was green throughout.
#
# docs/working-notes.md puts it as a standing rule -- green unit tests have
# twice hidden live failures -- so the cheap half of the answer is mechanical:
# name the display-only models and assert a view references each one.

set -e

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT_DIR/App/Sources"
fails=0

# The symbol must be matched QUALIFIED and as a fixed string. An unqualified
# substring is not enough: renaming the call to `DISABLED_badges(for:` left a
# bare `badges(for:` pattern still matching, so the guard passed over exactly
# the change it exists to catch. Proven by reverting it.
check_wired() {
	if grep -qF "$1" "$SRC/$2"; then
		echo "ok:   $1 is rendered by $2"
	else
		echo "FAIL: $1 is computed and tested but $2 never draws it"
		fails=$((fails + 1))
	fi
}

check_wired 'CoverFlowMetrics.badges(for:' SaveCoverFlow.swift
check_wired 'CoverFlowMetrics.emptyMessage(' SaveCoverFlow.swift
check_wired 'session.saveBlock.caption' ContentView.swift

# The renderer must ask for a controller pose in ONE place.
#
# `SpatialControllerTracker.isTracking` is the wrong question everywhere it
# was asked: a Sense pair stays connected and tracking on a desk after the
# player has switched to bare hands, so every tracking-gated branch went on
# preferring a controller nobody was holding. That put the rigid hand over the
# real one, left the wrist gauntlet pinned out of reach, and had the aim feed
# fighting HandInput for the single route into QC_InputSetAim. All four now go
# through activeControllerPose, which also asks whether controllers are the
# CHOSEN input. A fifth caller written the old way would be the same bug again
# and would look perfectly reasonable in isolation.
RENDERER="$ROOT_DIR/Sources/QuakeRenderer/ImmersiveRenderer.swift"
total=$(grep -c 'SpatialControllerTracker\.shared' "$RENDERER" || true)
inside=$(awk '/private func activeControllerPose/,/^    \}/' "$RENDERER" \
	| grep -c 'SpatialControllerTracker\.shared' || true)
if [ "$total" = "$inside" ]; then
	echo "ok:   the renderer asks for a controller pose in one place ($inside)"
else
	echo "FAIL: $((total - inside)) controller-tracking check(s) outside activeControllerPose"
	echo "      a pose gated on tracking alone survives the switch to bare hands"
	fails=$((fails + 1))
fi

if [ "$fails" -ne 0 ]; then
	echo "UI WIRING FAIL ($fails)"
	exit 1
fi
echo "UI WIRING PASS"
