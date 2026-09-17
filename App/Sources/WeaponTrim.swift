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

    private let lock = NSLock()
    private var front = defaultFront
    private var rear  = defaultRear
    private var current = 1                 // held-weapon index (shotgun default)
    private var lastWeapon: UInt32 = 0

    /// Wired by the UI to the engine console queue (same route as WheelState).
    nonisolated(unsafe) var sendCommand: (@Sendable (String) -> Void)?

    private init() { load() }

    private static func index(for bit: UInt32) -> Int { bits.firstIndex(of: bit) ?? 1 }

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
    }

    private func load() {
        if let f = UserDefaults.standard.array(forKey: "weaponTrimFront") as? [Double], f.count == 8 {
            front = f.map { Float($0) }
        }
        if let r = UserDefaults.standard.array(forKey: "weaponTrimRear") as? [Double], r.count == 8 {
            rear = r.map { Float($0) }
        }
    }
}
