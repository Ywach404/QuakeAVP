//
//  ControllerOutput.swift
//
//  The output half of controller I/O: haptic pulses driven by the frame
//  packet's output channel (fire echoes locally, damage rises come from
//  the engine), and the adaptive-trigger scaffolding.
//
//  Adaptive triggers, honestly: visionOS 26 does not expose the Sense
//  controllers' resistive triggers (Apple documents vibration support only;
//  the resistive hardware is explicitly unsupported). The scaffolding here
//  probes every trigger element for GCDualSenseAdaptiveTrigger — the one
//  adaptive API GameController has — and if a future visionOS hands it
//  over, the per-weapon feel table lights up without further work. Until
//  then the probe reports unavailable and everything no-ops.
//
//  Threading: noteFire arrives from GameController handler queues,
//  frame(damage:weapon:) from the compositor render thread. Everything
//  funnels through one serial queue; haptic engines are only touched there.
//

import GameController
import CoreHaptics

final class ControllerOutput: @unchecked Sendable {

    static let shared = ControllerOutput()

    private let queue = DispatchQueue(label: "quake.controller.output")
    /// Haptic engines paired with their controller, so a fire pulse can target
    /// the hand that shot. The hand is resolved lazily at fire time through
    /// SpatialControllerTracker.isLeft (live position), which can be unknown
    /// until both controllers track — buzz both then.
    private var handEngines: [(controller: GCController, engine: CHHapticEngine)] = []
    private var engines: [CHHapticEngine] { handEngines.map { $0.engine } }
    private var adaptiveTriggers: [GCDualSenseAdaptiveTrigger] = []
    private var lastDamage: Float = 0
    private var lastWeapon: UInt32 = 0

    /// For the UI: nil until a controller attaches, then whether the
    /// resistive triggers are actually reachable on this OS.
    private(set) var adaptiveTriggerStatus: String?

    // MARK: - Attachment

    func attach(controllers: [GCController]) {
        queue.async {
            self.handEngines = controllers.compactMap { controller in
                guard let haptics = controller.haptics,
                      let engine = haptics.createEngine(withLocality: .default)
                else { return nil }
                try? engine.start()
                return (controller, engine)
            }

            self.adaptiveTriggers = controllers.flatMap { controller in
                controller.physicalInputProfile.buttons.values.compactMap {
                    $0 as? GCDualSenseAdaptiveTrigger
                }
            }
            if controllers.isEmpty {
                self.adaptiveTriggerStatus = nil
            } else if self.adaptiveTriggers.isEmpty {
                self.adaptiveTriggerStatus = "adaptive triggers: not exposed by visionOS"
            } else {
                self.adaptiveTriggerStatus = "adaptive triggers: active"
                self.applyTriggerFeel(weapon: self.lastWeapon)
            }
        }
    }

    // MARK: - Events

    /// Trigger crossed the fire threshold (any source). The kick lands on the
    /// FIRING hand — the dominant one — and is scaled by the held weapon, so a
    /// rocket shoves and a nailgun stutters. Local echo: the shot is the
    /// engine's call, but the feel must not wait a round trip.
    func noteFire() {
        InputTelemetry.shared.fire()
        let dominantLeft = !VRSettings.shared.rightHanded
        queue.async {
            let intensity = Self.fireIntensity(weapon: self.lastWeapon)
            if let engine = self.engineForHand(left: dominantLeft) {
                self.transient(on: [engine], intensity: intensity, sharpness: 0.7)
            } else {
                self.transient(on: self.engines, intensity: intensity, sharpness: 0.7)
            }
        }
    }

    /// The haptic engine on the given hand, or nil until the pairing resolves.
    private func engineForHand(left: Bool) -> CHHapticEngine? {
        for pair in handEngines
        where SpatialControllerTracker.shared.isLeft(pair.controller) == left {
            return pair.engine
        }
        return nil
    }

    /// Per-weapon fire intensity, in Quake's IT_* weapon bits. Tuned blind;
    /// revisit on hardware alongside the adaptive-trigger table.
    static func fireIntensity(weapon: UInt32) -> Float {
        switch weapon {
        case 1:    return 0.7    // shotgun
        case 2:    return 0.9    // super shotgun
        case 4:    return 0.45   // nailgun — rapid, light per shot
        case 8:    return 0.6    // super nailgun
        case 16:   return 0.8    // grenade launcher
        case 32:   return 1.0    // rocket launcher — heaviest
        case 64:   return 0.5    // lightning — continuous
        case 4096: return 0.35   // axe — a dull thunk
        default:   return 0.7
        }
    }

    /// Once per rendered frame, from the packet's output channel.
    func frame(damageFlash: Float, activeWeapon: UInt32) {
        queue.async {
            // Damage pulses on the RISE of the cshift percent; the decay
            // (V_UpdateBlend) brings it back down between hits.
            if damageFlash > self.lastDamage + 5 {
                let intensity = min(damageFlash / 100, 1)
                self.transient(on: self.engines, intensity: intensity, sharpness: 0.3)
                InputTelemetry.shared.kickback(intensity: intensity)
            }
            self.lastDamage = damageFlash

            if activeWeapon != self.lastWeapon {
                self.lastWeapon = activeWeapon
                self.applyTriggerFeel(weapon: activeWeapon)
                InputTelemetry.shared.setWeapon(activeWeapon)
            }
        }
    }

    // MARK: - Haptics

    private func transient(on engines: [CHHapticEngine], intensity: Float, sharpness: Float) {
        for engine in engines {
            let event = CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    .init(parameterID: .hapticIntensity, value: intensity),
                    .init(parameterID: .hapticSharpness, value: sharpness),
                ],
                relativeTime: 0)
            if let pattern = try? CHHapticPattern(events: [event], parameters: []),
               let player = try? engine.makePlayer(with: pattern) {
                try? player.start(atTime: CHHapticTimeImmediate)
            }
        }
    }

    // MARK: - Adaptive trigger feel (armed, awaiting OS support)

    /// The trigger-travel band the adaptive table programs per weapon; the
    /// scope draws it so the feel is visible before the hardware can
    /// render it.
    static func feelZone(weapon: UInt32) -> ClosedRange<Float>? {
        switch weapon {
        case 1, 2: return 0.3...0.7
        case 4, 8: return 0.2...1.0
        case 16, 32: return 0.1...1.0
        case 64: return 0.0...1.0
        default: return nil
        }
    }

    /// Per-weapon feel, in Quake's IT_* weapon bits. Tuned blind — revisit
    /// on hardware the day the probe reports "active".
    private func applyTriggerFeel(weapon: UInt32) {
        guard !adaptiveTriggers.isEmpty else { return }
        for trigger in adaptiveTriggers {
            switch weapon {
            case 1, 2:      // shotguns: a stiff break-action pull
                trigger.setModeWeaponWithStartPosition(
                    0.3, endPosition: 0.7, resistiveStrength: 0.8)
            case 4, 8:      // nailguns: buzzing feedback under the finger
                trigger.setModeVibrationWithStartPosition(
                    0.2, amplitude: 0.6, frequency: 0.55)
            case 16, 32:    // grenade/rocket: heavy uniform resistance
                trigger.setModeFeedbackWithStartPosition(
                    0.1, resistiveStrength: 1.0)
            case 64:        // lightning gun: light feedback, continuous
                trigger.setModeFeedbackWithStartPosition(
                    0.0, resistiveStrength: 0.35)
            default:        // axe / none
                trigger.setModeOff()
            }
        }
    }
}
