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
        print("PASSED (weapons_test.swift)")
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
        check(new[16] == 1,  "variant 0 new tail is the fill value")

        // A new identity has no placement, and nil already means "follow the
        // global vr_weapon* cvars", so the tail must not become a zeroed
        // Placement, which would park an untuned weapon at the body centre.
        let oldPlace: [WeaponTrimMigration.Placement?] =
            (0..<32).map { .init(back: Float($0), up: 0, side: 0) }
        let newPlace = WeaponTrimMigration.widen(oldPlace, oldStride: 8)
        check(newPlace.count == 68, "widened placement is 4 * 17")
        check(newPlace[17] == .init(back: 8, up: 0, side: 0),
              "variant 1 slot 0 placement lands at 17")
        check(newPlace[16] == nil, "a new placement slot is untuned, not zeroed")
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
