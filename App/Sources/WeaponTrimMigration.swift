// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  WeaponTrimMigration.swift
//
//  Reshaping persisted weapon tuning when the slot count changes.
//
//  Weapon trim used to be keyed by the slot a weapon occupied in the ring,
//  eight of them, which only worked because id1's item bits, ring order and
//  selection impulses happen to agree. They do not agree in the mission
//  packs, so the key becomes the weapon's IDENTITY (its view model) and
//  there are seventeen of those. The stride therefore goes 8 to 17 while
//  the variant count stays 4, which moves every variant after the first.
//
//  That reshape is the one half of the weapon work that can be proved
//  before it meets a headset, and only while it stays pure: a wrong
//  widening does not crash or look wrong, it quietly reassigns A.'s
//  device-tuned numbers to the wrong weapons, and a device run would show a
//  plausible gun in the hand either way. So this file imports Foundation
//  and nothing else, holds no state, and talks to neither UserDefaults nor
//  the engine. tools/check-swift-weapons.sh compiles it alone against
//  tools/swifttest/weapons_test.swift.
//

import Foundation

enum WeaponTrimMigration {

    /// One entry per weapon identity. Game-independent, because an
    /// identity is a view model and a model's placement in the hand is a
    /// property of the model, not of which bit carries it in which game.
    static let identityCount = 17

    /// Mode times limbs. The widening does not touch this, which is exactly
    /// why it is not a simple append: the variants are strided by the
    /// identity count, so changing the stride relocates variants 1 to 3.
    static let variantCount = 4

    /// Where a weapon sits relative to the hand, in Quake units.
    /// Nested rather than top-level so `WeaponTrim` can alias it and the
    /// two cannot drift in field order.
    struct Placement: Equatable { var back, up, side: Float }

    /// Decodes the held weapon as the frame packet carries it: the identity
    /// PLUS ONE, with 0 meaning nothing held.
    ///
    /// The offset is the whole point of the encoding. The consumer's
    /// "nothing held" test is a zero check and identity 0 is the axe, so a
    /// raw index would make an empty hand and the axe the same value and the
    /// axe would silently never receive its trim, in every game. Returning
    /// nil rather than a fallback slot matters for the same reason: the
    /// predecessor mapped an unknown weapon to slot 1 and so an unrecognised
    /// gun wore the shotgun's tuning, then overwrote it on the next slider
    /// move.
    static func identity(fromPublished published: UInt32) -> Int? {
        guard published > 0, published < UInt32(identityCount) + 1 else {
            return nil
        }
        return Int(published) - 1
    }

    /// Where one variant's identity sits in the flat tables.
    ///
    /// This has exactly one definition on purpose. The formula lived in two
    /// places at the old stride, the live tables and the persistence loader,
    /// and widening only one of them is the quiet failure mode here: a
    /// migrated value lands in the wrong VARIANT, so hands-tuned numbers turn
    /// up under psvr2 and nothing crashes or looks obviously wrong.
    static func slot(variant: Int, identity: Int) -> Int {
        variant * identityCount + identity
    }

    /// Restripes a flat `variantCount * oldStride` table of keep-fractions
    /// onto the current stride, preserving each slot's index within its
    /// variant.
    ///
    /// `fill` defaults to 1, a full-length weapon, because a slot the old
    /// table could not speak to means "untuned" and 0 would clip the whole
    /// model away.
    static func widen(_ old: [Float], oldStride: Int, fill: Float = 1) -> [Float] {
        restriped(old, oldStride: oldStride, fill: fill)
    }

    /// Restripes a flat `variantCount * oldStride` placement table onto the
    /// current stride.
    ///
    /// `fill` defaults to nil because nil is already the established
    /// meaning of "follow the global `vr_weapon*` cvars", which is what an
    /// untuned weapon should do. A zeroed `Placement` would instead park
    /// the gun at the body centre and read as a deliberate tuning.
    static func widen(_ old: [Placement?], oldStride: Int,
                      fill: Placement? = nil) -> [Placement?] {
        restriped(old, oldStride: oldStride, fill: fill)
    }

    /// Short or malformed input is carried as far as it goes rather than
    /// trapped: the exact-count gating belongs to the loader, which still
    /// has the key name and can fall through to an older one, and a crash
    /// in the headset is worse than the tuning this guards.
    private static func restriped<Value>(_ old: [Value], oldStride: Int,
                                         fill: Value) -> [Value] {
        var new = [Value](repeating: fill, count: variantCount * identityCount)
        guard oldStride > 0 else { return new }
        let carried = min(oldStride, identityCount)
        for variant in 0..<variantCount {
            for slot in 0..<carried {
                let source = variant * oldStride + slot
                guard source < old.count else { return new }
                new[variant * identityCount + slot] = old[source]
            }
        }
        return new
    }

    /// Decodes one persisted placement blob, or nil if the blob is not
    /// exactly the shape claimed.
    ///
    /// The exact-count gate is the whole defence: a 48-double v2 blob read
    /// at the v3 stride, or the reverse, misfiles every value and produces
    /// numbers that are individually plausible, so nothing downstream can
    /// notice. On nil the caller falls through to an older key instead of
    /// reshaping what it found.
    ///
    /// `columns` is a parameter because the oldest format carried a fourth
    /// grip column, which is now one global value: those bytes are read
    /// past, not folded in.
    ///
    /// NaN in the first column marks an untuned slot. It has to be NaN
    /// rather than zero, since zero is a legitimate tuned offset and the
    /// baked tables use it throughout.
    static func decodePlacement(flat: [Double], stride: Int,
                                columns: Int) -> [Placement?]? {
        guard stride > 0, columns >= 3, flat.count == stride * columns else {
            return nil
        }
        var decoded = [Placement?](repeating: nil, count: stride)
        for slot in 0..<stride {
            let row = slot * columns
            let back = flat[row]
            if back.isNaN { continue }
            decoded[slot] = Placement(back: Float(back),
                                      up: Float(flat[row + 1]),
                                      side: Float(flat[row + 2]))
        }
        return decoded
    }

}
