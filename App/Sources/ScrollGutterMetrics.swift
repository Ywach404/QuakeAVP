// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  ScrollGutterMetrics.swift
//
//  Where the gutter's position indicator sits and how long it is.
//
//  The gutter draws its OWN indicator rather than showing the system's, and
//  that is the whole reason this file exists. The system indicator lives at
//  the trailing edge, which is where the gutter has to be, and dragging one
//  does not follow your hand -- it maps the grab's position onto the scroll
//  offset, so a pinch landing on it threw the panel to the bottom and made a
//  gradual scroll impossible. Hiding it fixed the scrolling and lost the only
//  cue for how far down the tab you were.
//
//  So the indicator is drawn here and is NOT interactive. It cannot be
//  grabbed, which is precisely what makes it safe to put inside the one strip
//  that exists to be grabbed.
//
//  No SwiftUI: tools/check-swift-session.sh compiles this alone against its
//  test. Division by a zero or absent content size is the case that matters,
//  because it happens on the first frame of every tab, before layout has
//  measured anything.
//

import Foundation

enum ScrollGutter {

    /// Shortest the indicator may be drawn, in points. A very long tab would
    /// otherwise produce a few pixels that read as a rendering fault rather
    /// than as a position.
    static let minimumThumbLength: Double = 28

    /// How far through the content the view is, 0 at the top and 1 at the
    /// bottom. Zero when there is nothing to scroll, which is also the first
    /// frame of every tab.
    static func progress(offset: Double, content: Double, container: Double) -> Double {
        let scrollable = content - container
        guard scrollable > 0, offset.isFinite, scrollable.isFinite else { return 0 }
        return min(max(offset / scrollable, 0), 1)
    }

    /// The indicator's length for a track of `track` points.
    ///
    /// Proportional to how much of the content fits on screen, so it says
    /// how much there is as well as where you are -- and the full track when
    /// everything fits, which reads correctly as "there is nowhere to go".
    static func thumbLength(content: Double, container: Double, track: Double) -> Double {
        guard track > 0 else { return 0 }
        guard content > 0, content.isFinite, container > 0, container.isFinite,
              content > container
        else { return track }
        let proportion = min(max(container / content, 0), 1)
        return min(track, max(minimumThumbLength, track * proportion))
    }

    /// The indicator's offset from the top of the track.
    ///
    /// Takes its own length into account, so the bottom of the indicator
    /// meets the bottom of the track at full scroll rather than its top.
    static func thumbOffset(offset: Double, content: Double, container: Double,
                            track: Double) -> Double {
        let length = thumbLength(content: content, container: container, track: track)
        let free = max(0, track - length)
        return free * progress(offset: offset, content: content, container: container)
    }
}
