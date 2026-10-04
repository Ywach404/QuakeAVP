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
    /// Migration marker. `nil` means the profile was written before the aim
    /// trim was unified, when 8 degrees lived hidden in HandInput and this
    /// profile's aimPitch was only the delta on top. ProfileStore folds the 8
    /// in on load so the effective trim is unchanged. See `aimPitch`.
    var schema: Int? = InputProfile.currentSchema
    static let currentSchema = 3

    // Aim + fire tuning (VRSettings-consumed).
    var aimSmooth: Float = 0.4
    var curlSensitivity: Float = 0.72
    var pinchClose: Float = 0.015
    var hammerDropDeg: Float = 45
    var turnFlickSpeed: Float = 0.35
    var fireMode: Int = 0            // FireMode.rawValue
    var turnStyle: Int = 0           // TurnStyle.rawValue
    /// SummonGesture.rawValue. Optional so profiles saved before the
    /// prayer sign existed still decode, defaulting to prayer.
    var summonGesture: Int? = 0
    var heightOffset: Float = 0.4

    // On-arm debug HUD placement (VRSettings-consumed).
    var hudForward: Float = 0
    var hudUp: Float = 0.14
    var hudSide: Float = 0
    var hudPitch: Float = 0
    var hudRoll: Float = 0
    /// Optional so profiles saved before this field existed still decode.
    var hudYaw: Float? = 0
    var hudFaceMe: Float = 0.8
    var hudScale: Float = 1

    // Weapon rig (engine cvars).
    var weaponBack: Float = 0
    var weaponUp: Float = 0
    var weaponSide: Float = 0
    var weaponGrip: Float = 0.15
    /// THE aim-height trim, degrees, positive = aim lower. Pushed to
    /// `vr_aimpitch`, which is the only place the correction is applied --
    /// there is deliberately no second constant in the Swift aim path.
    var aimPitch: Float = 8
    /// The lateral half of the same trim, degrees, positive = aim further
    /// right. Pushed to `vr_aimyaw`. Default 0: unlike the vertical bias, the
    /// sideways one is per-person.
    var aimYaw: Float = 0

    // Weapon-wheel ring plane (degrees) and radius scale.
    var wheelPitch: Float = 0
    var wheelYaw: Float = 0
    var wheelRoll: Float = 0
    var wheelRadius: Float = 1

    // Aiming laser (engine cvars). Offsets are deliberately 0 and should stay
    // there: the laser's job is to SHOW where the arm actually points so the
    // two trims above can be calibrated against it. A laser with its own
    // angular offset is a reference that lies, and you end up chasing it.
    var laser: Bool = false
    var laserForward: Float = 0
    var laserUp: Float = 0
    var laserSide: Float = 0
    var laserPitch: Float = 0
    var laserYaw: Float = 0

    init() {}

    /// Decode field by field, falling back to each property's default when the
    /// key is absent.
    ///
    /// Swift's SYNTHESISED Decodable throws on a missing key rather than using
    /// the default, and ProfileStore decodes with `try?` -- so adding a single
    /// non-optional field made every previously saved profile fail to decode
    /// and silently reset every slider the user had tuned. That already
    /// happened once (aimYaw). This init means new fields can be added plainly,
    /// without the Optional-and-`?? default` dance spreading through the
    /// call sites, and old profiles keep everything they stored.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func f(_ k: CodingKeys, _ fallback: Float) -> Float {
            ((try? c.decodeIfPresent(Float.self, forKey: k)) ?? nil) ?? fallback
        }
        func i(_ k: CodingKeys, _ fallback: Int) -> Int {
            ((try? c.decodeIfPresent(Int.self, forKey: k)) ?? nil) ?? fallback
        }
        func b(_ k: CodingKeys, _ fallback: Bool) -> Bool {
            ((try? c.decodeIfPresent(Bool.self, forKey: k)) ?? nil) ?? fallback
        }
        schema = (try? c.decodeIfPresent(Int.self, forKey: .schema)) ?? nil
        aimSmooth = f(.aimSmooth, 0.4)
        curlSensitivity = f(.curlSensitivity, 0.72)
        pinchClose = f(.pinchClose, 0.015)
        hammerDropDeg = f(.hammerDropDeg, 45)
        turnFlickSpeed = f(.turnFlickSpeed, 0.35)
        fireMode = i(.fireMode, 0)
        turnStyle = i(.turnStyle, 0)
        summonGesture = (try? c.decodeIfPresent(Int.self, forKey: .summonGesture)) ?? nil
        heightOffset = f(.heightOffset, 0.4)
        hudForward = f(.hudForward, 0)
        hudUp = f(.hudUp, 0.14)
        hudSide = f(.hudSide, 0)
        hudPitch = f(.hudPitch, 0)
        hudRoll = f(.hudRoll, 0)
        hudYaw = (try? c.decodeIfPresent(Float.self, forKey: .hudYaw)) ?? nil
        hudFaceMe = f(.hudFaceMe, 0.8)
        hudScale = f(.hudScale, 1)
        weaponBack = f(.weaponBack, 0)
        weaponUp = f(.weaponUp, 0)
        weaponSide = f(.weaponSide, 0)
        weaponGrip = f(.weaponGrip, 0.15)
        aimPitch = f(.aimPitch, 8)
        aimYaw = f(.aimYaw, 0)
        wheelPitch = f(.wheelPitch, 0)
        wheelYaw = f(.wheelYaw, 0)
        wheelRoll = f(.wheelRoll, 0)
        wheelRadius = f(.wheelRadius, 1)
        laser = b(.laser, false)
        laserForward = f(.laserForward, 0)
        laserUp = f(.laserUp, 0)
        laserSide = f(.laserSide, 0)
        laserPitch = f(.laserPitch, 0)
        laserYaw = f(.laserYaw, 0)
    }
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
            hands = Self.migrate(pair["hands"] ?? InputProfile())
            psvr2 = Self.migrate(pair["psvr2"] ?? InputProfile())
        } else {
            hands = InputProfile()
            psvr2 = InputProfile()
        }
        active = InputMode(rawValue: d.integer(forKey: Self.activeKey)) ?? .hands
    }

    private static func migrate(_ p: InputProfile) -> InputProfile {
        var out = p
        // 1 -> 2: the aim trim was 8 hidden degrees in HandInput plus whatever
        // this profile held. Fold the 8 in so the effective trim survives the
        // unification unchanged -- without this, loading an old profile pushes
        // `vr_aimpitch 0` and the aim silently rises 8 degrees.
        if out.schema == nil {
            out.aimPitch += 8
            out.schema = 2
        }
        // 2 -> 3: zero the laser offsets. The laser is the instrument the aim
        // trims are calibrated against, so it has to report the arm's true
        // direction; any stored angular offset silently biases the reference.
        if (out.schema ?? 0) < 3 {
            out.laserForward = 0
            out.laserUp = 0
            out.laserSide = 0
            out.laserPitch = 0
            out.laserYaw = 0
            out.schema = 3
        }
        return out
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
        s.curlSensitivity = p.curlSensitivity
        s.pinchClose = p.pinchClose
        s.wheelPitch = p.wheelPitch
        s.wheelYaw = p.wheelYaw
        s.wheelRoll = p.wheelRoll
        s.hammerDropDeg = p.hammerDropDeg
        s.turnFlickSpeed = p.turnFlickSpeed
        s.fireMode = FireMode(rawValue: p.fireMode) ?? .pinch
        s.turnStyle = TurnStyle(rawValue: p.turnStyle) ?? .stick
        s.summonGesture = SummonGesture(rawValue: p.summonGesture ?? 0) ?? .prayer
        s.heightOffset = p.heightOffset
        s.hudForward = p.hudForward
        s.hudUp = p.hudUp
        s.hudSide = p.hudSide
        s.hudPitch = p.hudPitch
        s.hudRoll = p.hudRoll
        s.hudYaw = p.hudYaw ?? 0
        s.hudFaceMe = p.hudFaceMe
        s.hudScale = p.hudScale
        applyRig()
    }

    /// Push just the engine-cvar rig (weapon placement + laser) for the active
    /// profile. Safe to call before the engine is up (no-op without sendCommand).
    func applyRig() {
        guard let send = sendCommand else { return }
        let p = current
        // Placement is per weapon now; hand the profile's globals to WeaponTrim
        // as the fallback for weapons never tuned, and let it push the cvars
        // for whichever gun is actually held.
        WeaponTrim.shared.setProfileBase(mode: active.rawValue, back: p.weaponBack,
                                         up: p.weaponUp, side: p.weaponSide,
                                         grip: p.weaponGrip)
        send("vr_aimpitch \(p.aimPitch)")
        send("vr_aimyaw \(p.aimYaw)")
        send("vr_wheelpitch \(p.wheelPitch)")
        send("vr_wheelyaw \(p.wheelYaw)")
        send("vr_wheelroll \(p.wheelRoll)")
        send("vr_wheelradius \(p.wheelRadius)")
        send("vr_laser \(p.laser ? 1 : 0)")
        send("vr_laserforward \(p.laserForward)")
        send("vr_laserup \(p.laserUp)")
        send("vr_laserside \(p.laserSide)")
        send("vr_laserpitch \(p.laserPitch)")
        send("vr_laseryaw \(p.laserYaw)")
    }
}
