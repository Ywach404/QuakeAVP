// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  ScrollGutterState.swift
//
//  Where the gutter's scroll position lives, and the view that draws it.
//
//  BOTH HALVES OF THIS FILE EXIST FOR THE SAME REASON: dragging the panel
//  was choppy.
//
//  The position was first held in three @State properties on ContentView.
//  That is the obvious place and it is the wrong one: a @State write
//  invalidates the view that owns it, and ContentView owns the whole panel,
//  so every scroll event re-evaluated the active tab's entire body -- forty
//  rows of sliders and dials -- to move one capsule a few points. Held in an
//  @Observable that only GutterTrack reads, the write reaches the indicator
//  and nothing else: ContentView writes these without reading them, so
//  observation tracking never marks it dirty.
//
//  The rail was first a VStack of ~120 Circles sized from the track height.
//  At one view per dot, rebuilt on every frame of a drag, the view graph was
//  doing more work than the scroll. A Canvas draws the same dots in one pass
//  with no views at all.
//
//  The placement maths is in ScrollGutterMetrics.swift, which is pure and
//  host-tested; this file is only the shell and the drawing.
//

import Observation
import SwiftUI

@MainActor
@Observable
final class ScrollGutterState {

    /// One panel, one indicator. Written by the panel's
    /// `onScrollGeometryChange`, read only by `GutterTrack`.
    static let shared = ScrollGutterState()

    var offset: Double = 0
    var content: Double = 0
    var viewport: Double = 0
}

/// The gutter's visible rail, with the scroll position riding on it.
///
/// NOT INTERACTIVE, and that is the design rather than a limitation. The
/// system's own indicator sits in this exact strip and can be dragged, and
/// dragging one maps the grab's position onto the scroll offset instead of
/// following your hand -- which is what threw the panel to the bottom on a
/// pinch. Drawing our own gets the position cue back without putting a
/// scrubber inside the one strip that exists to be grabbed.
struct GutterTrack: View {

    let width: CGFloat
    let tint: Color

    /// Spacing and size of the rail's dots. The rail is the same visual
    /// language as the stepped sliders beside it; here the dots are just the
    /// rail rather than units of anything.
    private let dotSpacing: CGFloat = 9
    private let dotDiameter: CGFloat = 4

    /// The indicator's width. CHONKY on purpose: at 5pt it was a hairline
    /// and at 10pt it still read as a line rather than a bar. A headset is
    /// a low-DPI display viewed at arm's length through lenses, so a control
    /// that looks heavy-handed in a screenshot is about right in the device.
    /// It stays inside the 40pt strip with room either side so the rail is
    /// visible above and below it.
    private let thumbWidth: CGFloat = 24

    var body: some View {
        GeometryReader { geo in
            let track = geo.size.height
            let state = ScrollGutterState.shared
            let thumb = ScrollGutter.thumbLength(content: state.content,
                                                 container: state.viewport,
                                                 track: track)
            let drop = ScrollGutter.thumbOffset(offset: state.offset,
                                                content: state.content,
                                                container: state.viewport,
                                                track: track)
            ZStack(alignment: .top) {
                Canvas { context, size in
                    // One pass, no views. See the file comment: a view per
                    // dot made the drag choppy on its own.
                    let x = (size.width - dotDiameter) / 2
                    var y: CGFloat = 0
                    while y + dotDiameter <= size.height {
                        context.fill(
                            Path(ellipseIn: CGRect(x: x, y: y,
                                                   width: dotDiameter,
                                                   height: dotDiameter)),
                            with: .color(tint.opacity(0.32)))
                        y += dotSpacing
                    }
                }
                Capsule()
                    .fill(tint.opacity(0.8))
                    .frame(width: thumbWidth, height: thumb)
                    .offset(y: drop)
            }
            .frame(width: width, alignment: .center)
        }
        .frame(width: width)
        .allowsHitTesting(false)
    }
}
