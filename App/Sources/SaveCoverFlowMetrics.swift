// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  SaveCoverFlowMetrics.swift
//
//  The save carousel's arithmetic and its wording, with no SwiftUI in sight.
//
//  Separate from SaveCoverFlow.swift on purpose: tools/check-swift-session.sh
//  compiles the window's pure halves ALONE, against no UI framework, so
//  anything it is to test cannot sit in a file that imports SwiftUI. These are
//  the parts of a ported look that can be silently wrong -- how wide the scroll
//  inset is, how many cards a column holds -- which is exactly what wants a
//  test, and the view itself is left to the device.
//
//  The five constants ARE the design. `ScrollTransitionPhase` hands the
//  transform closure three keyframes (-1, 0, +1) rather than a continuous
//  value, so no easing can live in there and nothing else can be tuned.
//

import Foundation

/// The two reasons a save cannot be loaded, both shown on the cover in orange.
/// Independent of each other: a file can be a foreign version AND have a name
/// the console cannot take, and then both are shown.
enum CoverBadge: Hashable {
    case versionMismatch(Int)
    case unaddressable

    /// Carried over verbatim from the rows this replaces. The wording is the
    /// engine's own refusal, said before the tap rather than after it.
    var caption: String {
        switch self {
        case .versionMismatch(let v):
            return "Savegame version \(v) — this engine reads version \(SaveGameHeader.version)."
        case .unaddressable:
            return "Rename this file (letters, digits, - and _) to load it — the console cannot take a name with a space or a dot in it."
        }
    }
}

enum CoverFlowMetrics {

    // Ported from the Cover Flow component in swiftui-gallery-seed, with its
    // reasoning. Every horizontal number is a fraction of cardWidth, so the
    // look is width-adaptive; only the height was arithmetic off that app's
    // 260pt drawer and is re-derived here for a tall panel column.
    static let cardWidth: CGFloat = 150
    static let cardHeight: CGFloat = 132
    static let tiltDegrees: CGFloat = 55
    /// How much the flankers overlap EACH OTHER -- the negative stack spacing.
    static let flankerOverlapFraction: CGFloat = 0.32
    /// How far an off-centre card is pushed AWAY from the hero. Positive means
    /// away: the sign was a real bug in the original, because negative looks
    /// plausible in a still and collapses the deck in motion.
    static let flankerPushAwayFraction: CGFloat = 0.30

    /// Centre-to-centre spacing of the stacked flankers.
    static var pitch: CGFloat { cardWidth * (1 - flankerOverlapFraction) }

    /// The deck's own height, which is NOT a card's height.
    ///
    /// A card tilted in perspective is taller than its flat self: the near
    /// edge is magnified toward the viewer, so a 55-degree turn pushes the top
    /// and bottom corners outside the rectangle the card occupies when facing
    /// you. Give the container exactly `cardHeight` and that is where those
    /// corners get cut -- which is what was happening, and why disabling the
    /// scroll view's clip appeared to cure it: the card was then free to draw
    /// outside a frame that was simply too small, at the cost of spilling
    /// across the whole window.
    ///
    /// Headroom is the actual fix. The multiplier is empirical rather than
    /// derived -- the exact magnification depends on `perspective`, which is
    /// a device-check dial -- so it is deliberately generous.
    static var deckHeight: CGFloat { cardHeight * 1.35 }

    /// The horizontal scroll-content inset.
    ///
    /// NOT centring, despite looking like it. `scrollTransition` and
    /// `.viewAligned` both measure against the margin-inset visible region, and
    /// insetting by half a column less half a card shrinks that region to
    /// exactly one card: only the centred card can then reach `.identity`, and
    /// every other card gets a non-zero phase and therefore a tilt. Remove this
    /// as redundant and several cards sit flat in the middle of the column with
    /// no Cover Flow at all.
    static func contentMargin(forWidth width: CGFloat) -> CGFloat {
        max(0, (width - cardWidth) / 2)
    }

    /// How many cards a column of this width shows, hero included.
    ///
    /// A flanker is tilted and scaled, so what it occupies is its projected
    /// width, not its full one. Past the second flanker a card is wholly
    /// outside the measured region and clamps to a full tilt -- the stacked
    /// deck -- so this is about what is legible, not what is drawn.
    static func visibleCardCount(forWidth width: CGFloat) -> Int {
        let halfViewport = width / 2
        let projectedHalf = cardWidth * 0.78 * cos(tiltDegrees * .pi / 180) / 2
        let push = cardWidth * flankerPushAwayFraction
        var count = 1                       // the hero is always there
        var index = 1
        while index <= 4 {
            let centre = push + pitch * CGFloat(index - 1)
            if centre + projectedHalf > halfViewport { break }
            count += 2                      // one each side
            index += 1
        }
        return count
    }

    /// Both refusals, in display order. A save can carry both.
    static func badges(for slot: SaveGameSlot) -> [CoverBadge] {
        var out: [CoverBadge] = []
        if !slot.isLoadable { out.append(.versionMismatch(slot.version)) }
        if !slot.isAddressable { out.append(.unaddressable) }
        return out
    }

    /// Two different nothings, and they are not the same sentence. Before the
    /// engine reports a game directory there is nothing to have looked in;
    /// after it, the directory really is empty.
    static func emptyMessage(gameDirectory: URL?) -> String {
        gameDirectory == nil ? "Waiting for the engine." : "No saved games yet."
    }
}

/// Naming a new save.
///
/// The name field used to default to a hardcoded "s0", left over from when
/// twelve numbered quick-slot buttons were how you chose a slot. With the deck
/// doing that job, a fixed default means the first save of every session
/// silently overwrites the same file -- which is what it did.
enum SaveNaming {

    /// The lowest `s<n>` not already taken.
    ///
    /// Counting the saves would be wrong: delete s1 of three and the count
    /// says 2, which is taken. The question is which name is FREE, not how
    /// many there are.
    static func nextFreeSlotName(existing: [String]) -> String {
        let taken = Set(existing)
        for n in 0..<100 where !taken.contains("s\(n)") { return "s\(n)" }
        // A hundred saves and every one of them an s-number. Fall back to
        // something that cannot collide rather than overwrite s99.
        return "save\(Int(Date().timeIntervalSince1970))"
    }
}

/// When to draw a cover for a save that was loaded without one.
///
/// Old saves -- every save written before covers existed -- show a plain
/// card. Rather than leave them plain forever or invent a picture for them,
/// they take one the first time they are actually played: the gap closes as
/// the player works through their saves, and a save never loaded keeps a
/// plain card, which is honest.
///
/// The timing is the whole of it, and both halves are wrong in the obvious
/// implementation. `Host_Loadgame_f` leaves the world PAUSED until the player
/// presses Resume, so drawing at load time captures a frozen frame of a level
/// they have not seen yet. And the pose ring holds one second, so immediately
/// after Resume it is still full of the level they just left -- a cover drawn
/// then is a picture of the wrong map.
enum CoverBackfill {

    /// How long after Resume to wait. At least a ring's worth, so nothing of
    /// the previous level survives in it.
    static let settle: TimeInterval = 1.25

    /// The save owed a cover, when one is due.
    static func due(pending: String?, levelLoaded: Bool, paused: Bool,
                    secondsSinceResume: TimeInterval) -> String? {
        guard let pending, levelLoaded, !paused, secondsSinceResume >= settle
        else { return nil }
        return pending
    }
}
