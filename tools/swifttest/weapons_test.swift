// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  weapons_test.swift
//
//  Host-run test for the weapon-trim persistence migration
//  (App/Sources/WeaponTrimMigration.swift). Compiled and linked ALONE
//  against that one file by tools/check-swift-weapons.sh -- no Observation,
//  no engine bridge, no simulator, no rest of the app module.
//
//  This is the one piece of the per-game weapon work worth testing rather
//  than running on device: a bad widening destroys A.'s hand-tuned
//  placement silently, and a device run would show a plausible-looking gun
//  in the hand either way. WeaponTrim itself touches UserDefaults and calls
//  into C from init, so the remap is factored out here to be checkable
//  before it ever meets a headset.
//

import Foundation

func check(_ condition: Bool, _ label: String) {
    if condition {
        print("ok:   \(label)")
    } else {
        print("FAIL: \(label)")
        exit(1)
    }
}

// A `swiftc` multi-file compile only grants top-level executable statements
// to a file literally named `main.swift`; this file keeps its own name (it
// reads as a test, not an entry point) and wraps its body in `@main`
// instead, which is a declaration, not a top-level statement.
@main
struct WeaponsTest {

    static func main() {
        runWideningTests()
        runPlacementDecodeTests()
        runPublishedIdentityTests()
        runSlotTests()
        runInheritanceTests()
        print("PASSED (weapons_test.swift)")
    }

    /// The ABI publishes the held identity PLUS ONE. The offset exists because
    /// the consumer's "nothing held" test is a zero check and identity 0 is
    /// the axe, so a raw index would make an empty hand and the axe the same
    /// value and the axe would silently never receive its trim, in any game.
    static func runPublishedIdentityTests() {
        check(WeaponTrimMigration.identity(fromPublished: 1) == 0,
              "published 1 decodes to identity 0, the axe")
        check(WeaponTrimMigration.identity(fromPublished: 0) == nil,
              "published 0 means nothing held")
        check(WeaponTrimMigration.identity(fromPublished: 17) == 16,
              "published 17 decodes to the last identity")
    }

    /// The slot formula, which every table in WeaponTrim indexes through and
    /// which the migration's destination writes have to agree with. It had two
    /// copies at the old stride and the loader's copy was the one that did not
    /// get widened, which puts a migrated value in the wrong VARIANT: not a
    /// crash, just A.'s hands-tuned numbers showing up under psvr2.
    static func runSlotTests() {
        check(WeaponTrimMigration.slot(variant: 0, identity: 0) == 0,
              "variant 0 identity 0 is slot 0")
        check(WeaponTrimMigration.slot(variant: 1, identity: 0) == 17,
              "variant 1 starts at 17, not 8")
        check(WeaponTrimMigration.slot(variant: 3, identity: 16) == 67,
              "the last slot of the last variant is 67")
        // The destination the two-mode v2 and v1 formats fold into: mode m
        // lands in the limbs-ON variant, which is m*2 + 1.
        check(WeaponTrimMigration.slot(variant: 0 * 2 + 1, identity: 0) == 17,
              "mode 0 folds to the limbs-on variant at 17")
        check(WeaponTrimMigration.slot(variant: 1 * 2 + 1, identity: 7) == 58,
              "mode 1 folds to the limbs-on variant at 51 + 7")
    }

    /// A weapon the packs add has no tuning of its own, and falling back to the
    /// global cvars put it somewhere that reads wrong in the hand. Each one
    /// instead starts from its vanilla SIBLING, per variant, so a weapon that
    /// is a variant of the nailgun starts where the nailgun sits.
    static func runInheritanceTests() {
        // Distinct per-slot values so a wrong source is visible as a number.
        let old: [Float] = (0..<32).map { Float($0) }
        let new = WeaponTrimMigration.widen(old, oldStride: 8)

        check(new.count == 68, "inherited widening is still 4 * 17")

        // The vanilla eight are untouched, in every variant.
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 3)] == 3,
              "vanilla nailgun unchanged in variant 0")
        check(new[WeaponTrimMigration.slot(variant: 2, identity: 3)] == 19,
              "vanilla nailgun unchanged in variant 2")

        // The rogue pairings, which the device confirmed as the toggle pairs.
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 11)] == 3,
              "lava nailgun inherits the nailgun")
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 12)] == 4,
              "lava super nailgun inherits the super nailgun")
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 13)] == 5,
              "multi grenade inherits the grenade launcher")
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 14)] == 6,
              "multi rocket inherits the rocket launcher")
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 15)] == 7,
              "plasma gun inherits the thunderbolt")

        // Hipnotic's three, and the grapple's fallback.
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 8)] == 7,
              "laser cannon inherits the thunderbolt")
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 9)] == 0,
              "mjolnir inherits the axe")
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 10)] == 5,
              "proximity gun inherits the grenade launcher")
        check(new[WeaponTrimMigration.slot(variant: 0, identity: 16)] == 1,
              "grapple inherits the shotgun")

        // Inheritance is PER VARIANT: variant 3's lava nailgun takes variant
        // 3's nailgun, not variant 0's. Getting this wrong would put the
        // hands-tuned value under psvr2.
        check(new[WeaponTrimMigration.slot(variant: 3, identity: 11)] == 27,
              "variant 3 lava nailgun takes variant 3's nailgun")

        // Placement inherits too, rather than staying nil and falling back to
        // the global cvars.
        let places: [WeaponTrimMigration.Placement?] = (0..<32).map {
            .init(back: Float($0), up: 0, side: 0)
        }
        let np = WeaponTrimMigration.widen(places, oldStride: 8)
        check(np[WeaponTrimMigration.slot(variant: 0, identity: 15)]?.back == 7,
              "plasma gun placement inherits the thunderbolt's")
        check(np[WeaponTrimMigration.slot(variant: 1, identity: 9)]?.back == 8,
              "variant 1 mjolnir placement takes variant 1's axe")
    }

    /// The stride goes 8 to 17 while the variant count stays 4, so every
    /// variant after the first MOVES. Restriping it by hand is where the
    /// tuning gets lost, which is what these indices are guarding.
    static func runWideningTests() {
        // identity-preserving widening, per variant
        let old: [Float] = (0..<32).map { Float($0) }
        let new = WeaponTrimMigration.widen(old, oldStride: 8)
        check(new.count == 68, "widened front/rear is 4 * 17")
        check(new[0]  == 0,  "variant 0 slot 0 preserved")
        check(new[7]  == 7,  "variant 0 slot 7 preserved")
        check(new[17] == 8,  "variant 1 slot 0 lands at 17, not 8")
        check(new[51] == 24, "variant 3 slot 0 lands at 51")
        // Index 16 is the grapple, which now INHERITS the shotgun (slot 1)
        // rather than taking the flat fill. Checked against slot 1's value so
        // the assertion fails if the inheritance is dropped, which a bare
        // "== 1" would not, since the fill happens to be 1 as well.
        check(new[16] == new[1], "the grapple tail inherits the shotgun")

        // A new identity has no placement, and nil already means "follow the
        // global vr_weapon* cvars", so the tail must not become a zeroed
        // Placement, which would park an untuned weapon at the body centre.
        let oldPlace: [WeaponTrimMigration.Placement?] =
            (0..<32).map { .init(back: Float($0), up: 0, side: 0) }
        let newPlace = WeaponTrimMigration.widen(oldPlace, oldStride: 8)
        check(newPlace.count == 68, "widened placement is 4 * 17")
        check(newPlace[17] == .init(back: 8, up: 0, side: 0),
              "variant 1 slot 0 placement lands at 17")
        // A pack weapon's placement used to stay nil and fall through to the
        // global cvars, which read wrong in the hand. It now starts at its
        // vanilla sibling. Still never ZERO, which would be a real placement
        // at the origin rather than an absent one.
        check(newPlace[16] == newPlace[1],
              "a new placement slot inherits its sibling, not nil")
        check(newPlace[16] != .init(back: 0, up: 0, side: 0),
              "and is never a zeroed placement")
    }

    /// Each persisted key is gated on an EXACT count, because a v2 blob read
    /// at the v3 stride misfiles every value and nothing downstream can tell.
    static func runPlacementDecodeTests() {
        // placement decode: NaN is untuned, not zero
        let flat = [1.0, 2.0, 3.0] + Array(repeating: Double.nan, count: 93)
        let pl = WeaponTrimMigration.decodePlacement(flat: flat, stride: 32, columns: 3)
        check(pl?.count == 32, "v3 placement decodes 32 slots from 96 doubles")
        check(pl?[0] == .init(back: 1, up: 2, side: 3), "slot 0 decoded")
        check(pl?[1] == nil, "NaN decodes to nil, meaning follow the cvars")

        // the count gates, which are what stop a v2 blob being read as v3
        check(WeaponTrimMigration.decodePlacement(flat: flat, stride: 16, columns: 3) == nil,
              "a 96-double blob is rejected as v2 (48)")
        check(WeaponTrimMigration.decodePlacement(flat: [], stride: 32, columns: 3) == nil,
              "empty is rejected, not treated as all-untuned")

        // Review Focus 3: v1 carries a fourth grip column, and front/rear have no v1
        let v1 = (0..<64).map { Double($0) }
        let p1 = WeaponTrimMigration.decodePlacement(flat: v1, stride: 16, columns: 4)
        check(p1?.count == 16, "v1 decodes 16 slots from 64 doubles at stride 4")
        check(p1?[1] == .init(back: 4, up: 5, side: 6), "v1 skips the grip column")
    }

}
