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
//  VARIANT changes under the same weapon (see lastWeapon's invalidation in
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

    /// IT_* bits in weapon order, matching WheelState and the engine ring:
    /// axe, shotgun, super shotgun, nailgun, super nailgun, GL, RL, lightning.
    private static let bits: [UInt32] = [4096, 1, 2, 4, 8, 16, 32, 64]
    /// Order: axe, shotgun, super shotgun, nailgun, super nailgun, GL, RL,
    /// lightning. The axe (melee) loads no round, so its model has no
    /// projectile to trim -- it stays at 1 (untouched).
    /// FOUR variants, variant = mode*2 + limbs: 0 hands/no-arms, 1 hands/arms,
    /// 2 psvr2/no-arms, 3 psvr2/arms. 8 weapons each in `bits` order (axe,
    /// shotgun, super shotgun, nailgun, super nailgun, GL, RL, lightning).
    /// These are the on-device tuning promoted to code (2026-10-08) so a fresh
    /// install ships with all four dialled in. `load` still overrides any slot
    /// stored on this device.

    /// Barrel-end clip keep-fraction (1 = none; the axe loads no round).
    private static let defaultFront32: [Float] = [
        1, 1, 1, 1, 1, 1, 1, 1,                 // hands / no arms
        1, 0.985, 1, 1, 1, 1, 1, 1,             // hands / arms shown
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
    struct Placement: Equatable { var back, up, side: Float }

    // variant = mode*2 + limbs (limbs = real arms shown via visionOS
    // upperLimbVisibility). The gun clashes with a visible arm, so each mode
    // keeps a separate placement for arms-off vs arms-on. Tables are 32 = 4*8;
    // one slot formula, `variant*8 + weapon`.
    private let lock = NSLock()
    private var front = defaultFront32
    private var rear  = defaultRear32
    /// Per (variant, weapon), index variant*8 + weapon. Starts at the shipped
    /// tuning; `load` overrides any slot this device has stored. nil = no value
    /// for that weapon, so it follows `global`.
    private var place = defaultPlace32
    private var mode = 0                    // InputMode.rawValue (0 hands, 1 psvr2)
    private var limbs = 0                   // real arms visible (passthrough) 0/1
    private var global = Placement(back: 0, up: 0, side: 0)
    /// The global grip, kept here only to push the cvar on profile apply.
    private var globalGrip: Float = 0.15
    private var current = 1                 // held-weapon index (shotgun default)
    private var lastWeapon: UInt32 = 0
    /// Sentinel for `lastWeapon` that forces `frame()` to re-push on the next
    /// call even though the held weapon hasn't changed -- set when the trim
    /// VARIANT changes instead (setMode/setLimbs/setProfileBase), because the
    /// front/rear tables are keyed by variant and the old variant's values
    /// would otherwise stay live until the next weapon switch (a stale rear
    /// clip reads as a pinched muzzle at rest). `.max` can never collide with
    /// a real `activeWeapon`: STAT_ACTIVEWEAPON is byte-truncated upstream, so
    /// every value `frame()` is ever called with fits in a byte.
    private static let invalidWeapon: UInt32 = .max

    /// Wired by the UI to the engine console queue (same route as WheelState).
    nonisolated(unsafe) var sendCommand: (@Sendable (String) -> Void)?

    private init() { load() }

    /// Publish the restored table. Called once the engine is up; `init` runs
    /// far too early for the C side to be listening.
    func applyEngine() { publish() }

    /// Every weapon's tuned values, for the console. Device UserDefaults is
    /// the only copy of a tuning session, and a reinstall takes it with it --
    /// this is how the numbers get read out and promoted to code defaults.
    func summary() -> [String] {
        let names = ["axe", "shotgun", "super shotgun", "nailgun",
                     "super nailgun", "grenade launcher", "rocket launcher",
                     "lightning gun"]
        lock.lock()
        let base = variant * 8
        let g = global, gg = globalGrip
        let pl = (0..<8).map { place[base + $0] }
        let fr = (0..<8).map { (front[base + $0], rear[base + $0]) }
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
        for i in 0..<8 {
            let p = pl[i]
            let place = p.map {
                "back=\(n($0.back)) up=\(n($0.up)) side=\(n($0.side))"
            } ?? "untuned"
            out.append("[weapons] \(names[i]): "
                       + "front=\(n(fr[i].0)) rear=\(n(fr[i].1)) \(place)")
        }
        return out
    }

    private static func index(for bit: UInt32) -> Int { bits.firstIndex(of: bit) ?? 1 }

    private var variant: Int { mode * 2 + limbs }
    private var slot: Int { variant * 8 + current }

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
        lastWeapon = Self.invalidWeapon
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
        lastWeapon = Self.invalidWeapon
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
        if mode != self.mode { lastWeapon = Self.invalidWeapon }
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
    /// in `defaultPlace`, not the profile global. For hands that tuning is the
    /// good answer, so reverting to the global would be a downgrade. A weapon
    /// with no shipped default (every PSVR2 slot, for now) still falls back to
    /// the global, which is what `nil` means.
    func resetCurrentPlacement() {
        lock.lock(); place[slot] = Self.defaultPlace32[slot]; lock.unlock()
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
    private func publish() {
        lock.lock()
        let base = variant * 8
        var table = [qc_weapon_placement_t](repeating: .init(), count: 8)
        for i in 0..<8 {
            guard let p = place[base + i] else { continue }   // custom == 0
            table[i] = qc_weapon_placement_t(back: p.back, up: p.up,
                                             side: p.side, custom: 1)
        }
        lock.unlock()
        QC_SetWeaponPlacement(table)
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
    /// trim variant changed under it (lastWeapon forced to `invalidWeapon` by
    /// setMode/setLimbs/setProfileBase) -- push its stored trim so each gun
    /// keeps its own values.
    func frame(activeWeapon: UInt32) {
        lock.lock()
        guard activeWeapon != lastWeapon, activeWeapon != 0 else { lock.unlock(); return }
        lastWeapon = activeWeapon
        current = Self.index(for: activeWeapon)
        let f = front[slot], r = rear[slot]
        lock.unlock()
        push(f, r)
        // Placement is NOT pushed here: the renderer pulls the held gun's
        // entry from the published table while it places the model, so it is
        // right on this very frame rather than a console round trip later.
        // Tell the UI the held weapon changed, so the Weapon tab re-reads its
        // sliders live instead of only on the tab's onAppear. Hop to the main
        // actor; this runs on a render thread.
        Task { @MainActor in WeaponFocus.shared.set(activeWeapon) }
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
        lock.lock(); let f = front, r = rear; lock.unlock()   // 32 each
        UserDefaults.standard.set(f.map(Double.init), forKey: "weaponTrimFront.v3")
        UserDefaults.standard.set(r.map(Double.init), forKey: "weaponTrimRear.v3")
        lock.lock(); let pl = place; lock.unlock()             // 32
        // Flat [back,up,side] per slot, NaN marking "not tuned", so the array
        // shape stays fixed and a missing weapon cannot shift the rest.
        var flat = [Double]()
        for p in pl {
            if let p { flat += [Double(p.back), Double(p.up), Double(p.side)] }
            else { flat += [Double.nan, .nan, .nan] }
        }
        UserDefaults.standard.set(flat, forKey: "weaponPlacement.v3")
    }

    private func load() {
        // v3 is the 4-variant (mode x limbs) layout. If a device only has the
        // older 2-mode v2, MIGRATE: the v2 values were tuned with the arms
        // VISIBLE, so they land in the limbs-ON variant; the limbs-OFF variant
        // keeps the code default (the recovered originals). Clip (front/rear)
        // doesn't depend on limbs, so it duplicates into both variants.
        if let f = UserDefaults.standard.array(forKey: "weaponTrimFront.v3") as? [Double],
           f.count == 32 {
            front = f.map { Float($0) }
        } else if let f = UserDefaults.standard.array(forKey: "weaponTrimFront.v2") as? [Double],
                  f.count == 16 {
            for m in 0..<2 { for w in 0..<8 {
                let v = Float(f[m*8+w]); front[(m*2)*8+w] = v; front[(m*2+1)*8+w] = v } }
        }
        if let r = UserDefaults.standard.array(forKey: "weaponTrimRear.v3") as? [Double],
           r.count == 32 {
            rear = r.map { Float($0) }
        } else if let r = UserDefaults.standard.array(forKey: "weaponTrimRear.v2") as? [Double],
                  r.count == 16 {
            for m in 0..<2 { for w in 0..<8 {
                let v = Float(r[m*8+w]); rear[(m*2)*8+w] = v; rear[(m*2+1)*8+w] = v } }
        }
        if let f = UserDefaults.standard.array(forKey: "weaponPlacement.v3") as? [Double],
           f.count == 96 {
            for i in 0..<32 {
                let b = f[i*3]
                if b.isNaN { place[i] = nil; continue }
                place[i] = Placement(back: Float(b), up: Float(f[i*3+1]), side: Float(f[i*3+2]))
            }
            return
        }
        if let f = UserDefaults.standard.array(forKey: "weaponPlacement.v2") as? [Double],
           f.count == 48 {
            for i in 0..<16 {
                let m = i / 8, w = i % 8
                let dst = (m*2 + 1)*8 + w        // limbs-ON variant
                let b = f[i*3]
                place[dst] = b.isNaN ? nil
                    : Placement(back: Float(b), up: Float(f[i*3+1]), side: Float(f[i*3+2]))
            }
            // limbs-OFF variants keep defaultPlace32 (the originals).
            return
        }
        legacyLoad()
    }

    /// Only reached when neither v3 nor v2 placement exists: the oldest v1
    /// format (a fourth grip column, global now). Fold it into the limbs-ON
    /// variant like v2, leaving limbs-OFF at the code originals. (v2 front/rear
    /// are already handled in load().)
    private func legacyLoad() {
        guard let f = UserDefaults.standard.array(forKey: "weaponPlacement.v1") as? [Double],
              f.count == 64 else { return }
        for i in 0..<16 {
            let m = i / 8, w = i % 8
            let dst = (m*2 + 1)*8 + w
            let b = f[i * 4]
            place[dst] = b.isNaN ? nil
                : Placement(back: Float(b), up: Float(f[i * 4 + 1]), side: Float(f[i * 4 + 2]))
        }
    }
}
