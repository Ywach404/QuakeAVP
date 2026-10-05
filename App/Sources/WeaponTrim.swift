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
//  The same store now carries PLACEMENT (back/up/side/grip) per weapon, for
//  the same reason: the models' origins sit at different points on each gun,
//  so one global offset makes some of them clip through the hand. Placement is
//  keyed by input mode as well as weapon -- unlike clip, where the gun is held
//  differs between bare hands and a Sense controller.
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
    /// lightning. The axe (melee) and lightning gun (hitscan beam) load no
    /// round, so their model has no projectile to trim -- default them to 1
    /// (untouched); the projectile weapons default to a rear shave.
    private static let defaultFront = [Float](repeating: 1, count: 8)
    private static let defaultRear:  [Float] = [1, 0.79, 0.79, 0.79, 0.79, 0.79, 0.79, 1]

    /// Per (input mode, weapon) placement. nil = never tuned, use the
    /// profile's global. Index: mode.rawValue * 8 + weapon.
    struct Placement: Equatable { var back, up, side, grip: Float }

    private let lock = NSLock()
    private var front = defaultFront
    private var rear  = defaultRear
    private var place = [Placement?](repeating: nil, count: 16)
    private var mode = 0                    // InputMode.rawValue
    private var global = Placement(back: 0, up: 0, side: 0, grip: 0.15)
    private var current = 1                 // held-weapon index (shotgun default)
    private var lastWeapon: UInt32 = 0

    /// Wired by the UI to the engine console queue (same route as WheelState).
    nonisolated(unsafe) var sendCommand: (@Sendable (String) -> Void)?

    private init() { load() }

    /// Publish the restored table. Called once the engine is up; `init` runs
    /// far too early for the C side to be listening.
    func applyEngine() { publish() }

    private static func index(for bit: UInt32) -> Int { bits.firstIndex(of: bit) ?? 1 }

    private var slot: Int { mode * 8 + current }

    /// Pushed by ProfileStore on apply: which input profile is live and what
    /// its global placement is. Untuned weapons follow these.
    func setProfileBase(mode: Int, back: Float, up: Float, side: Float, grip: Float) {
        lock.lock()
        self.mode = mode
        global = Placement(back: back, up: up, side: side, grip: grip)
        let g = global
        lock.unlock()
        pushGlobal(g)
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

    /// Drop this weapon's own placement and fall back to the profile global.
    func resetCurrentPlacement() {
        lock.lock(); place[slot] = nil; lock.unlock()
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
                                             side: p.side, grip: p.grip, custom: 1)
        }
        lock.unlock()
        QC_SetWeaponPlacement(table)
    }

    /// The profile's globals, which every untuned weapon falls back to. These
    /// stay cvars: one value, set rarely, and the console's way in.
    private func pushGlobal(_ p: Placement) {
        sendCommand?("vr_weaponback \(p.back)\n")
        sendCommand?("vr_weaponup \(p.up)\n")
        sendCommand?("vr_weaponside \(p.side)\n")
        sendCommand?("vr_weapongrip \(p.grip)\n")
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
        // Flat [back,up,side,grip] per slot, NaN marking "not tuned", so the
        // array shape stays fixed and a missing weapon cannot shift the rest.
        var flat = [Double]()
        for p in pl {
            if let p { flat += [Double(p.back), Double(p.up), Double(p.side), Double(p.grip)] }
            else { flat += [Double.nan, .nan, .nan, .nan] }
        }
        UserDefaults.standard.set(flat, forKey: "weaponPlacement.v1")
    }

    private func load() {
        if let f = UserDefaults.standard.array(forKey: "weaponTrimFront") as? [Double], f.count == 8 {
            front = f.map { Float($0) }
        }
        if let r = UserDefaults.standard.array(forKey: "weaponTrimRear") as? [Double], r.count == 8 {
            rear = r.map { Float($0) }
        }
        if let f = UserDefaults.standard.array(forKey: "weaponPlacement.v1") as? [Double],
           f.count == 64 {
            for i in 0..<16 {
                let b = f[i * 4]
                if b.isNaN { place[i] = nil; continue }
                place[i] = Placement(back: Float(b), up: Float(f[i * 4 + 1]),
                                     side: Float(f[i * 4 + 2]), grip: Float(f[i * 4 + 3]))
            }
        }
    }
}
