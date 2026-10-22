// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  SaveCoverFlow.swift
//
//  The save slots as a Cover Flow deck instead of a list of rows. A save is a
//  place you were standing; the thing that tells you which one it is, is the
//  picture. Covers arrive later -- until then every card is the plain dark
//  one, which is already a better read than a row of text because the level,
//  the difficulty, the kills and the date sit together on a face you can
//  recognise at a glance.
//
//  Ported from the Cover Flow browser in swiftui-gallery-seed. Three things
//  that are not obvious and were established before writing this, so nobody
//  has to find them twice:
//
//  1. `.contentMargins(..., for: .scrollContent)` is LOAD-BEARING and is not
//     centring. See CoverFlowMetrics.contentMargin.
//  2. `ScrollTransitionPhase` gives the closure three keyframes (-1, 0, +1),
//     not a continuous value, and interpolates the returned effect between
//     them. No easing can live in that closure; the five constants in
//     CoverFlowMetrics are the entire design surface.
//  3. `rotation3DEffect`'s `perspective:` label chooses the overload. WITH it
//     you get the flat projection macOS used. WITHOUT it, Swift resolves to
//     the RotationAxis3D overload, which is a true depth rotation inside the
//     window's volume -- possibly better in a headset, possibly clipped by
//     the window's depth budget. Keeping the flat one until that is tried on
//     device.
//
//  Deliberately NOT ported: the folder rail, breadcrumbs, favourites, the
//  thumbnail store, drag-out, the focus plumbing (gaze does not set SwiftUI
//  focus), `onMoveCommand` (unavailable on visionOS -- a compile error), and
//  `ScrollStepAccumulator`, whose only producer is an AppKit scroll monitor
//  and which therefore has zero callers here.
//

import SwiftUI

struct SaveCoverFlow: View {

    let slots: [SaveGameSlot]
    let gameDirectory: URL?
    /// Which cover is in front. The deck chooses; the caller acts.
    @Binding var selectedIndex: Int

    @State private var scrollID: Int?

    /// Identity of the LIST, not of a card. The deck is sorted newest-first,
    /// so saving prepends and every index shifts; `ForEach` diffs on the slot's
    /// name while `scrollPosition` is keyed on Int, and that mismatch leaves the
    /// scroll view holding a stale offset -- a new save's card would not show
    /// up until something else forced a rebuild. Keying the scroll view on this
    /// rebuilds it when the list changes shape.
    private var revision: [String] { slots.map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if slots.isEmpty {
                Text(CoverFlowMetrics.emptyMessage(gameDirectory: gameDirectory))
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(height: CoverFlowMetrics.cardHeight,
                           alignment: .center)
            } else {
                carousel
            }
        }
        .onChange(of: revision) { old, new in
            // A delete can leave the index past the end.
            if selectedIndex >= slots.count { selectedIndex = max(0, slots.count - 1) }
            // A new save PREPENDS, because the list is newest-first, so every
            // index shifts under the scroll view. Go to it: you just made it,
            // it is what you want to be looking at, and it also stops the
            // selection silently pointing at a different save than before.
            if slots.count > old.count { selectedIndex = 0 }
        }
    }

    // MARK: - the deck

    private var carousel: some View {
        GeometryReader { geometry in
            ScrollView(.horizontal) {
                LazyHStack(spacing: -CoverFlowMetrics.cardWidth
                                    * CoverFlowMetrics.flankerOverlapFraction) {
                    ForEach(Array(slots.enumerated()), id: \.element.id) { index, slot in
                        card(slot, at: index)
                            .id(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $scrollID)
            .scrollIndicators(.hidden)
            // Not centring. Shrinks the measured region to one card so only
            // the centred card reaches .identity -- see the metrics file.
            .contentMargins(.horizontal,
                            CoverFlowMetrics.contentMargin(forWidth: geometry.size.width),
                            for: .scrollContent)
            // The inset above deliberately shrinks the measured region to one
            // card, so every flanker lies OUTSIDE it and the scroll view clips
            // them at the edge. The hero is unaffected, which is why this
            // reads as "some of them are cut off" rather than as broken.
            .scrollClipDisabled()
            .id(revision)
        }
        .frame(height: CoverFlowMetrics.cardHeight)
        // Two-way, with a guard on each side so the pair cannot oscillate.
        // Animated only model -> scroll; a scroll that sets the model back
        // would fight the gesture.
        .onChange(of: selectedIndex, initial: true) { _, index in
            guard scrollID != index else { return }
            withAnimation(.snappy(duration: 0.28)) { scrollID = index }
        }
        .onChange(of: scrollID) { _, id in
            guard let id, id != selectedIndex else { return }
            selectedIndex = id
        }
    }

    private func card(_ slot: SaveGameSlot, at index: Int) -> some View {
        let isCentre = index == selectedIndex
        return cardFace(slot, isCentre: isCentre)
            .frame(width: CoverFlowMetrics.cardWidth,
                   height: CoverFlowMetrics.cardHeight)
            // Before the transform, so the gaze highlight follows the rotated
            // geometry rather than an untilted rectangle.
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10))
            .hoverEffect()
            .zIndex(Double(slots.count - abs(index - selectedIndex)))
            .scrollTransition(.interactive, axis: .horizontal) { content, phase in
                content
                    .rotation3DEffect(.degrees(phase.value * -CoverFlowMetrics.tiltDegrees),
                                      axis: (x: 0, y: 1, z: 0), perspective: 0.7)
                    .scaleEffect(phase.isIdentity ? 1 : 0.78)
                    .offset(x: phase.value * CoverFlowMetrics.cardWidth
                               * CoverFlowMetrics.flankerPushAwayFraction)
                    .opacity(1 - 0.25 * abs(phase.value))
            }
            .onTapGesture {
                // SELECTS. Never loads.
                //
                // A first version loaded when you tapped the centre card, and
                // it fired by accident: the gesture that summons the window
                // releases over the window the instant it appears, lands as a
                // tap on whatever card is in front, and silently threw away
                // the running game. The console caught it -- a summon line
                // followed immediately by a load. Loading is destructive and
                // gets an explicit button, the way the rows this replaces had
                // one.
                selectedIndex = index
            }
            .accessibilityLabel("\(slot.name), \(slot.displayText)")
    }

    private func cardFace(_ slot: SaveGameSlot, isCentre: Bool) -> some View {
        ZStack(alignment: .bottomLeading) {
            // A dark solid, not .ultraThinMaterial: material is near-invisible
            // against visionOS glass and a screenshot needs something to sit
            // on. The gradient is the same shape the cover's own overlay will
            // take, so the plain card and a covered one read as one family.
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Color(white: 0.14), Color(white: 0.07)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
            caption(slot)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.white.opacity(isCentre ? 0.35 : 0.15))
        }
        .shadow(color: .black.opacity(isCentre ? 0.5 : 0.25),
                radius: isCentre ? 10 : 4, y: isCentre ? 5 : 2)
    }

    /// Facts on the cover's face, so three can be read at once instead of
    /// swiping to find out what each one is.
    private func caption(_ slot: SaveGameSlot) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(slot.displayText.isEmpty ? slot.name : slot.displayText)
                .font(.caption2.weight(.semibold))
                .lineLimit(2)
            HStack(spacing: 4) {
                if let d = slot.difficulty {
                    Text(d.label.uppercased())
                        .font(.system(size: 7, weight: .bold))
                        .padding(.horizontal, 3).padding(.vertical, 1)
                        .background(pipColour(d), in: RoundedRectangle(cornerRadius: 2))
                }
                Text(slot.modified.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 8)).foregroundStyle(.secondary)
            }
        }
        .padding(5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: [.black.opacity(0.2), .black.opacity(0.85)],
                           startPoint: .top, endPoint: .bottom))
    }

    private func pipColour(_ d: Difficulty) -> Color {
        switch d {
        case .easy:      return Color(red: 0.18, green: 0.42, blue: 0.25)
        case .normal:    return Color(red: 0.17, green: 0.37, blue: 0.54)
        case .hard:      return Color(red: 0.54, green: 0.35, blue: 0.12)
        case .nightmare: return Color(red: 0.49, green: 0.12, blue: 0.12)
        }
    }
}
