//
//  DebugStore.swift
//
//  The Debug tab's overlay toggles, persisted so a tuning session survives a
//  relaunch instead of resetting every time.
//
//  Deliberately NOT part of InputProfile. A profile is per input source (Hands
//  vs PSVR2) and stores FEEL; which meters you have switched on is global --
//  you do not want the wireframe to vanish because a controller connected.
//
//  Two-phase apply, the same shape as ProfileStore: the Swift-side flags land
//  immediately, but `vr_pathdebug` is an engine cvar and cannot be sent until
//  the engine is running. A plain @AppStorage on each toggle would restore the
//  checkbox and silently fail to re-arm the AI overlay, which is worse than not
//  persisting at all.
//

import Foundation

@MainActor
@Observable
final class DebugStore {

    static let shared = DebugStore()

    var fingerDebug: Bool  { didSet { save(); HandDebug.shared.enabled = fingerDebug } }
    var aimRayDebug: Bool  { didSet { save(); HandDebug.shared.aimRays = aimRayDebug } }
    var strobeDebug: Bool  { didSet { save(); HandDebug.shared.strobe = strobeDebug } }
    var turnDebug: Bool    { didSet { save(); HandDebug.shared.turnDebug = turnDebug } }
    var fireDebug: Bool    { didSet { save(); HandDebug.shared.fireDebug = fireDebug } }
    var showLimbs: Bool    { didSet { save(); ImmersionSettings.shared.handsVisible = showLimbs } }
    /// The low-poly stand-in hand drawn over your real one while the world is
    /// solid. Hands-only by nature: HandInput is the only thing that publishes
    /// it, so with a controller attached there is nothing to show either way.
    var virtualHands: Bool { didSet { save(); VirtualHand.shared.visible = virtualHands } }
    /// Engine cvar, so this one only takes effect through applyEngine.
    var pathDebug: Bool    { didSet { save() } }

    /// NOT persisted, and starts off every launch on purpose: it prints to the
    /// Xcode console several times a second, so a forgotten `true` would bury
    /// whatever you relaunched to look at. It is a debugging instrument, not a
    /// preference.
    var inputLog = false { didSet { VRSettings.shared.inputLog = inputLog } }

    /// Engine cvar, and not persisted for the same reason as `inputLog`: it
    /// prints a line per shot fired, which is what makes it useful and what
    /// makes leaving it on intolerable. A measurement, not a preference.
    var projDebug = false

    private static let key = "debugToggles.v1"

    private init() {
        let d = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
        fingerDebug = d["fingerDebug"] ?? false
        aimRayDebug = d["aimRayDebug"] ?? false
        strobeDebug = d["strobeDebug"] ?? false
        turnDebug   = d["turnDebug"] ?? false
        fireDebug   = d["fireDebug"] ?? false
        pathDebug   = d["pathDebug"] ?? false
        showLimbs   = d["showLimbs"] ?? true      // passthrough limbs on by default
        virtualHands = d["virtualHands"] ?? true  // stand-in hand on by default
    }

    private func save() {
        UserDefaults.standard.set([
            "fingerDebug": fingerDebug, "aimRayDebug": aimRayDebug,
            "strobeDebug": strobeDebug, "turnDebug": turnDebug,
            "fireDebug": fireDebug, "pathDebug": pathDebug, "showLimbs": showLimbs,
            "virtualHands": virtualHands,
        ], forKey: Self.key)
    }

    /// Push the restored Swift-side flags to the overlays. Call on window
    /// appear; the didSets only fire on user edits, not on the initial load.
    func apply() {
        HandDebug.shared.enabled = fingerDebug
        HandDebug.shared.aimRays = aimRayDebug
        HandDebug.shared.strobe = strobeDebug
        HandDebug.shared.turnDebug = turnDebug
        HandDebug.shared.fireDebug = fireDebug
        ImmersionSettings.shared.handsVisible = showLimbs
        VirtualHand.shared.visible = virtualHands
        VRSettings.shared.inputLog = inputLog
    }

    /// Cvars, once the engine is up. Separate because the console refuses
    /// commands before then and the setting would be silently dropped.
    func applyEngine(_ send: (String) -> Void) {
        send("vr_pathdebug \(pathDebug ? 1 : 0)")
        send("vr_projdebug \(projDebug ? 1 : 0)")
    }
}
