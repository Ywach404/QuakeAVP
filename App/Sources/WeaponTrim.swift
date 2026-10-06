//
//  WeaponTrim.swift
//
//  Per-weapon vertex-clip trim (front = barrel end, rear = arm end), because
//  the baked-in round sits at a different depth on each weapon so one global
//  value can't fit all. Values are remembered per weapon and across launches;
//  the render thread pushes the held weapon's trim to the vr_weaponclip /
//  vr_weaponclipback cvars whenever the active weapon changes, and the engine's
//  QR_WeaponClip also feeds those planes back into the grip so trimming
//  re-seats the gun on the hand. The Weapon menu edits the current weapon.
//
//  The same store now carries PLACEMENT (back/up/side) per weapon, for the
//  same reason: the models' origins sit at different points on each gun, so
//  one global offset makes some of them clip through the hand. Placement is
//  keyed by input mode as well as weapon -- unlike clip, where the gun is held
//  differs between bare hands and a Sense controller.
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
    private static let defaultFront = [Float](repeating: 1, count: 8)
    /// Promoted from a completed hands tuning pass (2026-10-06). The flat 0.79
    /// these replace was one guess applied to every projectile weapon; each
    /// gun's round actually sits at its own depth, which is why the measured
    /// values spread from 0.500 to 0.851. The lightning gun turned out to need
    /// a shave too -- it fires a hitscan beam and loads no round, but its
    /// model's rear end still reaches back into the hand.
    private static let defaultRear: [Float] = [
        1,      // axe -- melee, nothing to trim
        0.657,  // shotgun
        0.500,  // super shotgun
        0.733,  // nailgun
        0.500,  // super nailgun
        0.500,  // grenade launcher
        0.522,  // rocket launcher
        0.851   // lightning gun
    ]

    /// Per-weapon placement defaults, same index as `place`: mode * 8 + weapon.
    ///
    /// From the same pass, and **hands only**. PSVR2 stays nil because it was
    /// never tuned -- where the gun is held differs between bare hands and a
    /// controller, so copying these across would be inventing numbers rather
    /// than promoting measured ones. Those weapons keep following the profile
    /// global, exactly as before.
    ///
    /// The spread here is the whole argument for placement being per weapon:
    /// `back` runs from 3.452 on the super shotgun to 15.841 on the lightning
    /// gun. The axe is the only weapon needing a real `side` and a positive
    /// `up`, which follows from it being swung rather than aimed.
    private static let defaultPlace: [Placement?] = [
        // mode 0 -- hands
        Placement(back:  7.510, up:  6.913, side: -4.132),  // axe
        Placement(back: 10.406, up:  0.071, side:  0.000),  // shotgun
        Placement(back:  3.452, up: -1.651, side:  0.000),  // super shotgun
        Placement(back:  7.078, up: -1.392, side:  0.000),  // nailgun
        Placement(back:  9.592, up: -1.941, side:  0.000),  // super nailgun
        Placement(back:  9.796, up: -1.401, side:  0.000),  // grenade launcher
        Placement(back:  8.276, up: -4.937, side:  3.161),  // rocket launcher
        Placement(back: 15.841, up: -1.900, side:  0.000),  // lightning gun
        // mode 1 -- psvr2, untuned
        nil, nil, nil, nil, nil, nil, nil, nil
    ]

    /// Per-weapon placement. NOT grip: it slides the model along the same axis
    /// as `back`, so the two were one degree of freedom with two knobs, and
    /// tuning all eight weapons left grip at its default on every one of them
    /// while back ranged over 3 to 18 units. Grip stays a single global cvar.
    struct Placement: Equatable { var back, up, side: Float }

    private let lock = NSLock()
    private var front = defaultFront
    private var rear  = defaultRear
    /// Per (input mode, weapon), index mode.rawValue * 8 + weapon. Starts at
    /// the shipped tuning; `load` overrides any slot this device has stored.
    /// nil = no value for that weapon, so it follows `global`.
    private var place = defaultPlace
    private var mode = 0                    // InputMode.rawValue
    private var global = Placement(back: 0, up: 0, side: 0)
    /// The global grip, kept here only to push the cvar on profile apply.
    private var globalGrip: Float = 0.15
    private var current = 1                 // held-weapon index (shotgun default)
    private var lastWeapon: UInt32 = 0

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
        let base = mode * 8
        let g = global, gg = globalGrip, f = front, r = rear
        let pl = (0..<8).map { place[base + $0] }
        let m = mode
        lock.unlock()
        // Three decimals, not Float's full seventeen. The sliders are coarser
        // than that, and every extra digit is one more to misread -- the first
        // dump came back through OCR with most of its zeroes turned into
        // eights, which made twenty values ambiguous instead of none.
        func n(_ v: Float) -> String { String(format: "%.3f", v) }
        var out = ["[weapons] mode=\(m) global "
                   + "back=\(n(g.back)) up=\(n(g.up)) side=\(n(g.side)) "
                   + "grip=\(n(gg)) (grip is global)"]
        for i in 0..<8 {
            let p = pl[i]
            let place = p.map {
                "back=\(n($0.back)) up=\(n($0.up)) side=\(n($0.side))"
            } ?? "untuned"
            out.append("[weapons] \(names[i]): "
                       + "front=\(n(f[i])) rear=\(n(r[i])) \(place)")
        }
        return out
    }

    private static func index(for bit: UInt32) -> Int { bits.firstIndex(of: bit) ?? 1 }

    private var slot: Int { mode * 8 + current }

    /// Pushed by ProfileStore on apply: which input profile is live and what
    /// its global placement is. Untuned weapons follow these.
    func setProfileBase(mode: Int, back: Float, up: Float, side: Float, grip: Float) {
        lock.lock()
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
    private func publish() {
        lock.lock()
        let base = mode * 8
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

    /// Render thread, once per frame: when the held weapon changes, push its
    /// stored trim so each gun keeps its own values.
    func frame(activeWeapon: UInt32) {
        lock.lock()
        guard activeWeapon != lastWeapon, activeWeapon != 0 else { lock.unlock(); return }
        lastWeapon = activeWeapon
        current = Self.index(for: activeWeapon)
        let f = front[current], r = rear[current]
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

    var currentFront: Float { lock.lock(); defer { lock.unlock() }; return front[current] }
    var currentRear: Float { lock.lock(); defer { lock.unlock() }; return rear[current] }

    func setFront(_ v: Float) {
        lock.lock(); front[current] = v; lock.unlock()
        sendCommand?("vr_weaponclip \(v)\n"); save()
    }

    func setRear(_ v: Float) {
        lock.lock(); rear[current] = v; lock.unlock()
        sendCommand?("vr_weaponclipback \(v)\n"); save()
    }

    /// Reset only the held weapon to its default.
    func resetCurrent() {
        lock.lock()
        let i = current
        let f = Self.defaultFront[i], r = Self.defaultRear[i]
        front[i] = f; rear[i] = r
        lock.unlock()
        push(f, r); save()
    }

    private func push(_ f: Float, _ r: Float) {
        sendCommand?("vr_weaponclip \(f)\n")
        sendCommand?("vr_weaponclipback \(r)\n")
    }

    private func save() {
        lock.lock(); let f = front, r = rear; lock.unlock()
        UserDefaults.standard.set(f.map(Double.init), forKey: "weaponTrimFront")
        UserDefaults.standard.set(r.map(Double.init), forKey: "weaponTrimRear")
        lock.lock(); let pl = place; lock.unlock()
        // Flat [back,up,side] per slot, NaN marking "not tuned", so the array
        // shape stays fixed and a missing weapon cannot shift the rest.
        var flat = [Double]()
        for p in pl {
            if let p { flat += [Double(p.back), Double(p.up), Double(p.side)] }
            else { flat += [Double.nan, .nan, .nan] }
        }
        UserDefaults.standard.set(flat, forKey: "weaponPlacement.v2")
    }

    private func load() {
        if let f = UserDefaults.standard.array(forKey: "weaponTrimFront") as? [Double], f.count == 8 {
            front = f.map { Float($0) }
        }
        if let r = UserDefaults.standard.array(forKey: "weaponTrimRear") as? [Double], r.count == 8 {
            rear = r.map { Float($0) }
        }
        if let f = UserDefaults.standard.array(forKey: "weaponPlacement.v2") as? [Double],
           f.count == 48 {
            for i in 0..<16 {
                let b = f[i * 3]
                if b.isNaN { place[i] = nil; continue }
                place[i] = Placement(back: Float(b), up: Float(f[i * 3 + 1]),
                                     side: Float(f[i * 3 + 2]))
            }
        } else if let f = UserDefaults.standard.array(forKey: "weaponPlacement.v1") as? [Double],
                  f.count == 64 {
            // v1 carried a fourth column, grip, which is global now. Fold the
            // table down rather than discarding it -- these are hand-tuned
            // values that exist nowhere but this device.
            for i in 0..<16 {
                let b = f[i * 4]
                if b.isNaN { place[i] = nil; continue }
                place[i] = Placement(back: Float(b), up: Float(f[i * 4 + 1]),
                                     side: Float(f[i * 4 + 2]))
            }
        }
    }
}
