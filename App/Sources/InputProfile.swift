//
//  InputProfile.swift
//
//  Persisted per-input tuning so the control sliders "lock in" instead of
//  resetting every launch. Two profiles -- Hands (controllerless) and PSVR2
//  (Sense controllers) -- because optimal weapon placement and aim feel differ
//  between them. The active profile auto-follows whether a controller is
//  connected, unless the user has manually overridden it.
//
//  A profile stores FEEL only: aim/turn/fire tuning, the on-arm debug HUD
//  placement, and the weapon/laser rig. It does NOT store which debug meters
//  are toggled on (that's a session concern), and per-weapon clip trim keeps
//  its own store (WeaponTrim) since it's orthogonal to the input source.
//

import Foundation
import GameController

enum InputMode: Int, Codable, CaseIterable { case hands, psvr2 }

/// One input source's full feel. Defaults match the historical hardcoded values
/// so a fresh install behaves as before, then diverges as the user tunes.
struct InputProfile: Codable, Equatable {
    // Aim + fire tuning (VRSettings-consumed).
    var aimSmooth: Float = 0.4
    var aimBlend: Float = 0.35
    var curlSensitivity: Float = 0.72
    var hammerDropDeg: Float = 45
    var turnFlickSpeed: Float = 0.35
    var fireMode: Int = 0            // FireMode.rawValue
    var turnStyle: Int = 0           // TurnStyle.rawValue
    var heightOffset: Float = 0.4

    // On-arm debug HUD placement (VRSettings-consumed).
    var hudForward: Float = 0
    var hudUp: Float = 0.14
    var hudSide: Float = 0
    var hudPitch: Float = 0
    var hudRoll: Float = 0
    var hudFaceMe: Float = 0.8
    var hudScale: Float = 1

    // Weapon rig (engine cvars).
    var weaponBack: Float = 0
    var weaponUp: Float = 0
    var weaponSide: Float = 0
    var weaponGrip: Float = 0.15
    var aimPitch: Float = 0

    // Aiming laser (engine cvars).
    var laser: Bool = false
    var laserForward: Float = 0
    var laserUp: Float = 0
    var laserSide: Float = 0
    var laserPitch: Float = 0
    var laserYaw: Float = 0
}

/// Owns the two profiles, persists them to UserDefaults, and applies the active
/// one to the runtime (VRSettings for feel, engine cvars for the rig). The
/// window binds its sliders to `current`; a slider edit mutates the profile,
/// which persists via didSet, then `applyRig`/VRSettings carry it to the engine.
@MainActor
@Observable
final class ProfileStore {

    static let shared = ProfileStore()

    /// Set by the window so the store can push cvars (vr_weapon*, vr_laser*).
    @ObservationIgnored var sendCommand: ((String) -> Void)?
    /// True once the user picks a profile by hand; suppresses the auto-switch.
    @ObservationIgnored var manualOverride = false

    var hands: InputProfile { didSet { save() } }
    var psvr2: InputProfile { didSet { save() } }
    var active: InputMode { didSet { UserDefaults.standard.set(active.rawValue, forKey: Self.activeKey) } }

    private static let key = "inputProfiles.v1"
    private static let activeKey = "inputProfiles.active"

    private init() {
        let d = UserDefaults.standard
        if let data = d.data(forKey: Self.key),
           let pair = try? JSONDecoder().decode([String: InputProfile].self, from: data) {
            hands = pair["hands"] ?? InputProfile()
            psvr2 = pair["psvr2"] ?? InputProfile()
        } else {
            hands = InputProfile()
            psvr2 = InputProfile()
        }
        active = InputMode(rawValue: d.integer(forKey: Self.activeKey)) ?? .hands
    }

    /// The active profile; assigning routes to the right stored profile so the
    /// didSet persistence fires.
    var current: InputProfile {
        get { active == .hands ? hands : psvr2 }
        set { if active == .hands { hands = newValue } else { psvr2 = newValue } }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(["hands": hands, "psvr2": psvr2]) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    /// Auto-select by controller presence unless the user overrode it.
    func refreshActiveFromInput() {
        guard !manualOverride else { return }
        active = GCController.controllers().isEmpty ? .hands : .psvr2
    }

    /// Reset the active profile to defaults and re-apply.
    func resetCurrent() {
        current = InputProfile()
        apply()
    }

    /// Push the whole active profile: feel to VRSettings, rig to the engine.
    func apply() {
        let p = current
        let s = VRSettings.shared
        s.aimSmooth = p.aimSmooth
        s.aimBlend = p.aimBlend
        s.curlSensitivity = p.curlSensitivity
        s.hammerDropDeg = p.hammerDropDeg
        s.turnFlickSpeed = p.turnFlickSpeed
        s.fireMode = FireMode(rawValue: p.fireMode) ?? .pinch
        s.turnStyle = TurnStyle(rawValue: p.turnStyle) ?? .stick
        s.heightOffset = p.heightOffset
        s.hudForward = p.hudForward
        s.hudUp = p.hudUp
        s.hudSide = p.hudSide
        s.hudPitch = p.hudPitch
        s.hudRoll = p.hudRoll
        s.hudFaceMe = p.hudFaceMe
        s.hudScale = p.hudScale
        applyRig()
    }

    /// Push just the engine-cvar rig (weapon placement + laser) for the active
    /// profile. Safe to call before the engine is up (no-op without sendCommand).
    func applyRig() {
        guard let send = sendCommand else { return }
        let p = current
        send("vr_weaponback \(p.weaponBack)")
        send("vr_weaponup \(p.weaponUp)")
        send("vr_weaponside \(p.weaponSide)")
        send("vr_weapongrip \(p.weaponGrip)")
        send("vr_aimpitch \(p.aimPitch)")
        send("vr_laser \(p.laser ? 1 : 0)")
        send("vr_laserforward \(p.laserForward)")
        send("vr_laserup \(p.laserUp)")
        send("vr_laserside \(p.laserSide)")
        send("vr_laserpitch \(p.laserPitch)")
        send("vr_laseryaw \(p.laserYaw)")
    }
}
