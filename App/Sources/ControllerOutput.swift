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
    private var engines: [CHHapticEngine] = []
    private var adaptiveTriggers: [GCDualSenseAdaptiveTrigger] = []
    private var lastDamage: Float = 0
    private var lastWeapon: UInt32 = 0

    /// For the UI: nil until a controller attaches, then whether the
    /// resistive triggers are actually reachable on this OS.
    private(set) var adaptiveTriggerStatus: String?

    // MARK: - Attachment

    func attach(controllers: [GCController]) {
        queue.async {
            self.engines = controllers.compactMap { controller in
                guard let haptics = controller.haptics else { return nil }
                let engine = haptics.createEngine(withLocality: .default)
                try? engine?.start()
                return engine
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

    /// Trigger crossed the fire threshold (any source). Local echo — the
    /// shot itself is decided by the engine, but the feel must not wait a
    /// round trip.
    func noteFire() {
        queue.async { self.transient(intensity: 0.8, sharpness: 0.7) }
    }

    /// Once per rendered frame, from the packet's output channel.
    func frame(damageFlash: Float, activeWeapon: UInt32) {
        queue.async {
            // Damage pulses on the RISE of the cshift percent; the decay
            // (V_UpdateBlend) brings it back down between hits.
            if damageFlash > self.lastDamage + 5 {
                let intensity = min(damageFlash / 100, 1)
                self.transient(intensity: intensity, sharpness: 0.3)
            }
            self.lastDamage = damageFlash

            if activeWeapon != self.lastWeapon {
                self.lastWeapon = activeWeapon
                self.applyTriggerFeel(weapon: activeWeapon)
            }
        }
    }

    // MARK: - Haptics

    private func transient(intensity: Float, sharpness: Float) {
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
