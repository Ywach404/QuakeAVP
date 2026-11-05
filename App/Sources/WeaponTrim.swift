// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  WeaponTrim.swift
//
//  Per-weapon vertex-clip trim (front = barrel end, rear = arm end), because
//  the baked-in round sits at a different depth on each weapon so one global
//  value can't fit all. Values are remembered per weapon and across launches;
//  the render thread pushes the held weapon's trim to the vr_weaponclip /
//  vr_weaponclipback cvars whenever the active weapon changes -- or the trim
//  VARIANT changes under the same weapon (see lastPublished's invalidation in
//  setMode/setLimbs/setProfileBase) -- and the engine's
//  QR_WeaponClip also feeds those planes back into the grip so trimming
//  re-seats the gun on the hand. The Weapon menu edits the current weapon.
//
//  The same store now carries PLACEMENT (back/up/side) per weapon, for the
//  same reason: the models' origins sit at different points on each gun, so
//  one global offset makes some of them clip through the hand. Placement is
//  keyed by input mode as well as weapon, and so is the clip: the trim planes
//  feed QR_WeaponClip, which re-seats the GRIP, so the right trim depends on
//  how the gun is held and not only on where the model's round sits. Tuning
//  both modes by hand settled it -- the same lightning gun wanted 0.851 in
//  bare hands and 0.608 on a controller.
//
//  Grip is deliberately NOT per weapon. It is a fraction of the trimmed
//  length, so it already adapts to each model and re-seats when the trim
//  moves, and it slides the gun along the same axis as `back` -- two knobs
//  over one degree of freedom. Tuning all eight weapons left grip at its
//  default on every one while back ranged over 3 to 18 units.
//
//  A weapon with no stored placement falls back to the active profile's global
//  values, which ProfileStore pushes in on apply. So tuning one gun does not
//  orphan the rest, and an untuned gun still follows the profile.
//

import Foundation

final class WeaponTrim: @unchecked Sendable {

    static let shared = WeaponTrim()

    /// Everything here is keyed by weapon IDENTITY, which is the weapon as a
    /// MODEL and so is game-independent: identity 1 draws progs/v_shot.mdl in
    /// id1, hipnotic, rogue and mg3 alike, whichever item bit happens to
    /// carry it there. What was tuned is where a model sits in the hand, so
    /// the identity is the key the numbers are actually about, and a mission
    /// pack inherits the tuning with no second session. Swift keeps no item
    /// bits at all now: the engine resolves bit to identity per game and the
    /// frame packet carries the answer.
    ///
    /// The baked tables below are the 2026-10-08 on-device tuning promoted to
    /// code, written at the old 8-wide stride and widened to the identity
    /// count programmatically -- never retyped, because hand-restriping 68
    /// entries across four variants is exactly where tuning gets lost.
    /// Identity order is the vanilla eight: axe, shotgun, super shotgun,
    /// nailgun, super nailgun, GL, RL, thunderbolt. The axe (melee) loads no
    /// round, so its model has no projectile to trim -- it stays at 1
    /// (untouched). FOUR variants, variant = mode*2 + limbs: 0 hands/no-arms,
    /// 1 hands/arms, 2 psvr2/no-arms, 3 psvr2/arms. `load` still overrides
    /// any slot stored on this device.

    /// Barrel-end clip keep-fraction (1 = none; the axe loads no round).
    private static let defaultFront32: [Float] = [
        1, 1, 1, 1, 1, 1, 1, 1,                 // hands / no arms
        // The shotgun sat at 0.985 here, clipping a sliver off the barrel
        // end. With the real hands showing it looks better untrimmed, so
        // every front default is now 1 and the barrel end is never cut.
        1, 1, 1, 1, 1, 1, 1, 1,                 // hands / arms shown
        1, 1, 1, 1, 1, 1, 1, 1,                 // psvr2 / no arms
        1, 1, 1, 1, 1, 1, 1, 1                  // psvr2 / arms shown
    ]
    /// Rear clip keep-fraction (retracts the round baked near the grip).
    private static let defaultRear32: [Float] = [
        1, 0.705, 0.500, 0.733, 0.500, 0.500, 0.522, 0.851,   // hands / no arms
        1, 0.800, 0.500, 0.733, 0.500, 0.500, 0.522, 0.851,   // hands / arms
        1, 0.696, 0.511, 0.721, 0.543, 0.500, 0.500, 0.608,   // psvr2 / no arms
        1, 0.696, 0.511, 0.721, 0.543, 0.500, 0.500, 0.608    // psvr2 / arms
    ]
    /// Per-weapon placement, same index. All four variants are tuned.
    private static let defaultPlace32: [Placement?] = [
        // hands / no arms
        Placement(back:  9.005, up:  4.684, side: -3.204),
        Placement(back: 10.406, up: -0.159, side:  0.000),
        Placement(back:  3.452, up: -3.085, side: -1.558),
        Placement(back:  7.078, up: -4.120, side:  0.000),
        Placement(back:  9.592, up: -1.941, side:  0.000),
        Placement(back:  9.796, up: -1.401, side:  0.000),
        Placement(back:  8.276, up: -4.937, side:  3.161),
        Placement(back: 15.841, up: -1.900, side:  0.000),
        // hands / arms shown
        Placement(back: 13.095, up:  5.200, side: -3.742),
        Placement(back: -0.055, up:  0.071, side: -1.793),
        Placement(back: -0.779, up: -0.672, side: -1.929),
        Placement(back: -0.662, up:  1.095, side: -2.188),
        Placement(back: -2.897, up: -1.941, side:  0.000),
        Placement(back:  4.015, up:  1.243, side:  0.000),
        Placement(back:  8.276, up: -2.418, side:  3.161),
        Placement(back: 13.987, up:  0.243, side:  0.000),
        // psvr2 / no arms
        Placement(back:  8.639, up:  0.000, side:  0.000),
        Placement(back: 10.793, up:  0.000, side:  0.000),
        Placement(back:  3.109, up:  0.000, side:  0.000),
        Placement(back:  9.088, up:  0.000, side:  0.000),
        Placement(back:  8.891, up: -0.066, side:  0.000),
        Placement(back: 12.713, up: -0.125, side:  0.000),
        Placement(back:  8.534, up: -4.576, side:  3.887),
        Placement(back: 12.743, up:  0.000, side:  0.000),
        // psvr2 / arms shown
        Placement(back:  8.639, up:  0.000, side:  0.000),
        Placement(back: 10.793, up:  0.000, side:  0.000),
        Placement(back:  3.109, up:  0.000, side:  0.000),
        Placement(back:  9.088, up:  0.000, side:  0.000),
        Placement(back:  8.891, up: -0.066, side:  0.000),
        Placement(back: 12.713, up: -0.125, side:  0.000),
        Placement(back:  8.534, up: -4.576, side:  3.887),
        Placement(back: 12.743, up:  0.000, side:  0.000)
    ]

    /// Per-weapon placement. NOT grip: it slides the model along the same axis
    /// as `back`, so the two were one degree of freedom with two knobs, and
    /// tuning all eight weapons left grip at its default on every one of them
    /// while back ranged over 3 to 18 units. Grip stays a single global cvar.
    ///
    /// Aliased rather than redeclared, so this file and the migration that
    /// reshapes its tables cannot drift in field order -- a drift that would
    /// not crash or look wrong, it would silently transpose A.'s numbers.
    typealias Placement = WeaponTrimMigration.Placement

    /// The shipped tables at the live stride, restriped from the 8-wide
    /// literals above. Static, so the widening runs once on first touch
    /// rather than per instance, and `resetCurrent`/`resetCurrentPlacement`
    /// index these and not the literals -- a reset reads a slot number in the
    /// widened space.
    private static let defaultFront = WeaponTrimMigration.widen(defaultFront32,
                                                                oldStride: 8)
    private static let defaultRear = WeaponTrimMigration.widen(defaultRear32,
                                                               oldStride: 8)
    private static let defaultPlace = WeaponTrimMigration.widen(defaultPlace32,
                                                                oldStride: 8)

    /// How wide one variant is. An identity is a model and there are
    /// seventeen of them across the packs, so this is the identity count and
    /// never a bare 17 -- adding a weapon is then a change in one place.
    private static let stride = WeaponTrimMigration.identityCount

    /// The whole table: every variant times every identity. Persistence gates
    /// on this exact count, which is the only thing stopping a narrower stored
    /// blob from being read as a wider one and smearing one variant's values
    /// across the next.
    private static let tableCount = WeaponTrimMigration.variantCount * stride

    // variant = mode*2 + limbs (limbs = real arms shown via visionOS
    // upperLimbVisibility). The gun clashes with a visible arm, so each mode
    // keeps a separate placement for arms-off vs arms-on. Tables are
    // variantCount * stride; one slot formula, `variant*stride + identity`.
    private let lock = NSLock()
    private var front = defaultFront
    private var rear  = defaultRear
    /// Per (variant, identity), index variant*stride + identity. Starts at
    /// the shipped tuning; `load` overrides any slot this device has stored.
    /// nil = no value for that identity, so it follows `global`.
    private var place = defaultPlace
    private var mode = 0                    // InputMode.rawValue (0 hands, 1 psvr2)
    private var limbs = 0                   // real arms visible (passthrough) 0/1
    private var global = Placement(back: 0, up: 0, side: 0)
    /// The global grip, kept here only to push the cvar on profile apply.
    private var globalGrip: Float = 0.15
    private var current = 1                 // held identity (shotgun default)
    /// The last value `frame()` acted on, in the packet's PUBLISHED encoding
    /// (identity plus one) rather than as an identity, so the sentinel below
    /// stays outside the range of anything real.
    private var lastPublished: UInt32 = 0
    /// Sentinel for `lastPublished` that forces `frame()` to re-push on the
    /// next call even though the held weapon hasn't changed -- set when the
    /// trim VARIANT changes instead (setMode/setLimbs/setProfileBase),
    /// because the front/rear tables are keyed by variant and the old
    /// variant's values would otherwise stay live until the next weapon
    /// switch (a stale rear clip reads as a pinched muzzle at rest). `.max`
    /// can never collide with a real published value: the packet carries an
    /// identity plus one, so the whole range is 0 to seventeen.
    private static let invalidPublished: UInt32 = .max

    /// Wired by the UI to the engine console queue (same route as WheelState).
    nonisolated(unsafe) var sendCommand: (@Sendable (String) -> Void)?

    private init() { load() }

    /// Publish the restored table. Called once the engine is up; `init` runs
    /// far too early for the C side to be listening.
    func applyEngine() { publish() }

    /// Every weapon's tuned values, for the console. Device UserDefaults is
    /// the only copy of a tuning session, and a reinstall takes it with it --
    /// this is how the numbers get read out and promoted to code defaults.
    ///
    /// The names come from the engine's label table rather than a copy kept
    /// here, for the same reason the placement table is pulled rather than
    /// mirrored: the bridge owns every per-game weapon fact, and a second
    /// list of seventeen strings is a second thing to forget to extend.
    func summary() -> [String] {
        let count = Self.stride
        let names = (0..<count).map { String(cString: QC_WeaponLabel(Int32($0))) }
        lock.lock()
        let base = variant * count
        let g = global, gg = globalGrip
        let pl = (0..<count).map { place[base + $0] }
        let fr = (0..<count).map { (front[base + $0], rear[base + $0]) }
        let m = variant
        lock.unlock()
        // Three decimals, not Float's full seventeen. The sliders are coarser
        // than that, and every extra digit is one more to misread -- the first
        // dump came back through OCR with most of its zeroes turned into
        // eights, which made twenty values ambiguous instead of none.
        func n(_ v: Float) -> String { String(format: "%.3f", v) }
        var out = ["[weapons] variant=\(m) global "
                   + "back=\(n(g.back)) up=\(n(g.up)) side=\(n(g.side)) "
                   + "grip=\(n(gg)) (grip is global)"]
        for i in 0..<count {
            let p = pl[i]
            let place = p.map {
                "back=\(n($0.back)) up=\(n($0.up)) side=\(n($0.side))"
            } ?? "untuned"
            out.append("[weapons] \(names[i]): "
                       + "front=\(n(fr[i].0)) rear=\(n(fr[i].1)) \(place)")
        }
        return out
    }

    private var variant: Int { mode * 2 + limbs }
    private var slot: Int { WeaponTrimMigration.slot(variant: variant,
                                                     identity: current) }

    /// Which input profile is live. Pushed from ProfileStore.active's didSet,
    /// so it follows the profile by construction rather than by remembering to
    /// call applyRig -- which bails when the console has never been opened,
    /// leaving `mode` at 0 while the PSVR2 profile was active. Every placement
    /// edit would then have been written into the HANDS slots.
    func setMode(_ m: Int) {
        lock.lock()
        guard m != mode else { lock.unlock(); return }
        mode = m
        // The variant changed under whatever weapon is held -- invalidate so
        // frame() re-pushes that weapon's NEW-variant trim next frame instead
        // of leaving the old variant's clip live until a weapon switch.
        lastPublished = Self.invalidPublished
        lock.unlock()
        publish()
    }

    /// Whether the real arms show through (visionOS passthrough). Flips the
    /// placement variant so the gun can sit clear of a visible arm. Pushed from
    /// DebugStore.showLimbs, the same control that drives upperLimbVisibility.
    func setLimbs(_ on: Bool) {
        lock.lock()
        let v = on ? 1 : 0
        guard v != limbs else { lock.unlock(); return }
        limbs = v
        // Same reasoning as setMode: the variant moved, so force frame() to
        // re-push the held weapon's trim for it.
        lastPublished = Self.invalidPublished
        lock.unlock()
        publish()
    }

    /// Pushed by ProfileStore on apply: which input profile is live and what
    /// its global placement is. Untuned weapons follow these.
    func setProfileBase(mode: Int, back: Float, up: Float, side: Float, grip: Float) {
        lock.lock()
        // Only invalidate on an actual mode change; setMode (active.didSet,
        // InputProfile) already ran on a profile switch, so this avoids a
        // second no-op invalidation on an otherwise-ordinary re-apply.
        if mode != self.mode { lastPublished = Self.invalidPublished }
        self.mode = mode
        global = Placement(back: back, up: up, side: side)
        globalGrip = grip
        let g = global
        lock.unlock()
        pushGlobal(g, grip: grip)
        publish()
    }

    /// The held weapon's effective placement -- its own if tuned, else global.
    var currentPlacement: Placement {
        lock.lock(); defer { lock.unlock() }
        return place[slot] ?? global
    }

    /// True when the held weapon has its own placement rather than the global.
    var currentPlacementIsCustom: Bool {
        lock.lock(); defer { lock.unlock() }
        return place[slot] != nil
    }

    func setPlacement(_ p: Placement) {
        lock.lock(); place[slot] = p; lock.unlock()
        publish(); save()
    }

    /// Put this weapon back to its SHIPPED placement -- the on-device tuning
    /// in `defaultPlace`, not the profile global. All four variants of the
    /// vanilla eight are tuned, so reverting to the global would be a
    /// downgrade for every one of them. The identities the packs add carry no
    /// shipped default yet and reset to `nil`, which is what falls back to
    /// the global `vr_weapon*` cvars.
    ///
    /// Indexes the WIDENED table: `slot` is a position in the identity space,
    /// which the 8-wide literal cannot answer for anything past the eighth.
    func resetCurrentPlacement() {
        lock.lock(); place[slot] = Self.defaultPlace[slot]; lock.unlock()
        publish(); save()
    }

    /// Hand the engine the whole table for the active input mode. The renderer
    /// reads the entry for whichever gun it is drawing, so this is correct on
    /// the first frame of a weapon switch and there is no switch event to miss.
    ///
    /// Placement used to be four cvars rewritten on each switch through the
    /// console queue. That arrived a frame or two after the gun it described,
    /// and `engine.send` drops anything sent before the engine is running --
    /// with no retry, because `frame` only pushes when the weapon CHANGES. One
    /// dropped command left that weapon wearing another gun's placement until
    /// you cycled away and back, which is indistinguishable from placement
    /// being global.
    /// The count goes over with the table rather than being inferred: the
    /// setter sizes its copy off whichever is smaller, so the two sides can
    /// never read a length from the wrong array.
    private func publish() {
        let count = Int(QC_WEAPON_SLOTS)
        lock.lock()
        let base = variant * Self.stride
        var table = [qc_weapon_placement_t](repeating: .init(), count: count)
        for i in 0..<count {
            guard let p = place[base + i] else { continue }   // custom == 0
            table[i] = qc_weapon_placement_t(back: p.back, up: p.up,
                                             side: p.side, custom: 1)
        }
        lock.unlock()
        QC_SetWeaponPlacement(table, Int32(count))
    }

    /// The profile's globals, which every untuned weapon falls back to. These
    /// stay cvars: one value, set rarely, and the console's way in.
    private func pushGlobal(_ p: Placement, grip: Float) {
        sendCommand?("vr_weaponback \(p.back)\n")
        sendCommand?("vr_weaponup \(p.up)\n")
        sendCommand?("vr_weaponside \(p.side)\n")
        sendCommand?("vr_weapongrip \(grip)\n")
    }

    /// Render thread, once per frame: when the held weapon changes -- or the
    /// trim variant changed under it (lastPublished forced to
    /// `invalidPublished` by setMode/setLimbs/setProfileBase) -- push its
    /// stored trim so each gun keeps its own values.
    ///
    /// Takes `qc_frame_t.active_identity` as the packet carries it, identity
    /// plus one. The decode returning nil covers both 0, nothing held, and
    /// anything out of range, and in both cases nothing is pushed. There is
    /// deliberately no fallback slot: the predecessor fell back to slot 1 and
    /// so an unrecognised weapon wore the shotgun's tuning and overwrote it
    /// the moment a slider moved.
    func frame(publishedIdentity: UInt32) {
        lock.lock()
        guard publishedIdentity != lastPublished,
              let identity = WeaponTrimMigration.identity(fromPublished: publishedIdentity)
        else { lock.unlock(); return }
        lastPublished = publishedIdentity
        current = identity
        let f = front[slot], r = rear[slot]
        lock.unlock()
        push(f, r)
        // Placement is NOT pushed here: the renderer pulls the held gun's
        // entry from the published table while it places the model, so it is
        // right on this very frame rather than a console round trip later.
        // Tell the UI the held weapon changed, so the Weapon tab re-reads its
        // sliders live instead of only on the tab's onAppear. Hop to the main
        // actor; this runs on a render thread.
        Task { @MainActor in WeaponFocus.shared.set(publishedIdentity) }
    }

    var currentFront: Float { lock.lock(); defer { lock.unlock() }; return front[slot] }
    var currentRear: Float { lock.lock(); defer { lock.unlock() }; return rear[slot] }

    func setFront(_ v: Float) {
        lock.lock(); front[slot] = v; lock.unlock()
        sendCommand?("vr_weaponclip \(v)\n"); save()
    }

    func setRear(_ v: Float) {
        lock.lock(); rear[slot] = v; lock.unlock()
        sendCommand?("vr_weaponclipback \(v)\n"); save()
    }

    /// Reset only the held weapon to its default.
    func resetCurrent() {
        lock.lock()
        let i = slot
        let f = Self.defaultFront32[i], r = Self.defaultRear32[i]
        front[i] = f; rear[i] = r
        lock.unlock()
        push(f, r); save()
    }

    private func push(_ f: Float, _ r: Float) {
        sendCommand?("vr_weaponclip \(f)\n")
        sendCommand?("vr_weaponclipback \(r)\n")
    }

    private func save() {
        lock.lock(); let f = front, r = rear; lock.unlock()   // 68 each
        UserDefaults.standard.set(f.map(Double.init), forKey: "weaponTrimFront.v4")
        UserDefaults.standard.set(r.map(Double.init), forKey: "weaponTrimRear.v4")
        lock.lock(); let pl = place; lock.unlock()             // 68
        // Flat [back,up,side] per slot, NaN marking "not tuned", so the array
        // shape stays fixed and a missing weapon cannot shift the rest.
        var flat = [Double]()
        for p in pl {
            if let p { flat += [Double(p.back), Double(p.up), Double(p.side)] }
            else { flat += [Double.nan, .nan, .nan] }
        }
        UserDefaults.standard.set(flat, forKey: "weaponPlacement.v4")
    }

    /// Restore whatever this device stored, oldest format included.
    ///
    /// v4 is the identity-strided layout. Every older format is SLOT-strided
    /// (v3 is 4 variants of 8, v2 and v1 are 2 modes of 8), so each is read at
    /// its own stride and then restriped. None of them can be assigned
    /// straight in: the stride moved, so variants 1 to 3 relocated, and
    /// copying a 32-entry v3 blob into the first 32 slots of a 68-slot table
    /// would spread one variant's tuning across the next two.
    ///
    /// The two chains are deliberately independent and are NOT the same
    /// length. A device can be mid-chain on one and not the other, and
    /// front/rear never had a v1 at all.
    ///
    /// Nothing here writes back. A device therefore keeps whatever it has
    /// until the next slider move calls `save()`, which is why the chain has
    /// to reach all the way down rather than only one step.
    private func load() {
        let d = UserDefaults.standard

        // Clip does not depend on limbs, so a two-mode value duplicates into
        // both limb variants of its mode.
        if let f = d.array(forKey: "weaponTrimFront.v4") as? [Double],
           f.count == Self.tableCount {
            front = f.map { Float($0) }
        } else if let f = d.array(forKey: "weaponTrimFront.v3") as? [Double],
                  f.count == 32 {
            front = WeaponTrimMigration.widen(f.map { Float($0) }, oldStride: 8)
        } else if let f = d.array(forKey: "weaponTrimFront.v2") as? [Double],
                  f.count == 16 {
            Self.overlayTwoMode(f.map { Float($0) }, into: &front,
                                acrossLimbs: true)
        }

        if let r = d.array(forKey: "weaponTrimRear.v4") as? [Double],
           r.count == Self.tableCount {
            rear = r.map { Float($0) }
        } else if let r = d.array(forKey: "weaponTrimRear.v3") as? [Double],
                  r.count == 32 {
            rear = WeaponTrimMigration.widen(r.map { Float($0) }, oldStride: 8)
        } else if let r = d.array(forKey: "weaponTrimRear.v2") as? [Double],
                  r.count == 16 {
            Self.overlayTwoMode(r.map { Float($0) }, into: &rear,
                                acrossLimbs: true)
        }

        // Placement, each step gated on an exact element count so a narrower
        // blob can never be mistaken for a wider one. The early returns matter:
        // a v4 hit must not fall through and have v3 overwrite it.
        let placementKeys: [(key: String, stride: Int, columns: Int)] = [
            ("weaponPlacement.v4", Self.tableCount, 3),
            ("weaponPlacement.v3", 32, 3),
            ("weaponPlacement.v2", 16, 3),
            ("weaponPlacement.v1", 16, 4),   // v1's 4th column was a per-weapon
                                             // grip, one global cvar now
        ]
        for k in placementKeys {
            guard let decoded = WeaponTrimMigration.decodePlacement(
                      flat: d.array(forKey: k.key) as? [Double] ?? [],
                      stride: k.stride, columns: k.columns)
            else { continue }

            if k.stride == Self.tableCount {
                place = decoded
            } else if k.stride == 32 {
                place = WeaponTrimMigration.widen(decoded, oldStride: 8)
            } else {
                Self.overlayTwoMode(decoded, into: &place, acrossLimbs: false)
            }
            break
        }

        // Last: any pack weapon still without a placement takes its vanilla
        // sibling. The widening already does this for the shipped defaults, but
        // a device that stored a v4 table before the siblings existed holds
        // explicit nils, and nil means "fall through to the global cvars",
        // which is the thing that read wrong in the hand. Doing it here rather
        // than only in the widening is what makes it true for every device
        // regardless of what it has already written.
        for identity in 0..<WeaponTrimMigration.identityCount {
            guard let from = WeaponTrimMigration.inheritsFrom[identity] else {
                continue
            }
            for variant in 0..<WeaponTrimMigration.variantCount {
                let dst = WeaponTrimMigration.slot(variant: variant,
                                                   identity: identity)
                guard place[dst] == nil else { continue }
                place[dst] = place[WeaponTrimMigration.slot(variant: variant,
                                                            identity: from)]
            }
        }
    }

    /// Fold a two-mode table into the four-variant one.
    ///
    /// An overlay rather than a replacement, because the identities the old
    /// format never knew about must keep their shipped code values; rebuilding
    /// the array would clear them to "untuned" instead.
    ///
    /// `acrossLimbs` is the difference between the two tables and is not a
    /// convenience. A clip fraction does not depend on whether the real arms
    /// are drawn, so it duplicates into both limb variants of its mode.
    /// Placement very much does depend on it, the gun clashes with a visible
    /// arm, and those stored values were tuned with the arms VISIBLE, so they
    /// land in limbs-ON alone and limbs-OFF keeps the default.
    private static func overlayTwoMode<T>(_ old: [T], into table: inout [T],
                                          acrossLimbs: Bool) {
        for i in 0..<16 {
            let mode = i / 8, weapon = i % 8
            table[WeaponTrimMigration.slot(variant: mode * 2 + 1,
                                           identity: weapon)] = old[i]
            if acrossLimbs {
                table[WeaponTrimMigration.slot(variant: mode * 2,
                                               identity: weapon)] = old[i]
            }
        }
    }
}
