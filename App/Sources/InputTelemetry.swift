//
//  InputTelemetry.swift
//
//  Ring buffer behind the trigger scope: analog trigger samples from the
//  pad aggregator, fire/kickback event marks from the output side, and the
//  active weapon's adaptive-trigger feel zone. Producers run on handler
//  queues and the render thread; the scope snapshots under one lock at
//  display cadence.
//
//  The demo generator exists for portfolio capture and deviceless
//  verification: it plays a canned pull -> actuation -> kickback -> release
//  trace through the same buffer real input uses, clearly user-invoked.
//

import Foundation
import QuartzCore

final class InputTelemetry: @unchecked Sendable {

    static let shared = InputTelemetry()

    struct Sample {
        var t: Double
        var rt: Float
        var lt: Float
    }

    struct Event {
        enum Kind { case fire, kickback }
        var t: Double
        var kind: Kind
        var intensity: Float
    }

    private let lock = NSLock()
    private var samples: [Sample] = []
    private var events: [Event] = []
    private var weapon: UInt32 = 0
    private var demoTask: Task<Void, Never>?

    private static let window = 4.0

    // MARK: - Producers

    func record(rt: Float, lt: Float) {
        append(Sample(t: CACurrentMediaTime(), rt: rt, lt: lt))
    }

    func fire() {
        appendEvent(Event(t: CACurrentMediaTime(), kind: .fire, intensity: 1))
    }

    func kickback(intensity: Float) {
        appendEvent(Event(t: CACurrentMediaTime(), kind: .kickback, intensity: intensity))
    }

    func setWeapon(_ w: UInt32) {
        lock.lock(); weapon = w; lock.unlock()
    }

    // MARK: - The scope's read

    func snapshot() -> (samples: [Sample], events: [Event], weapon: UInt32) {
        let cutoff = CACurrentMediaTime() - Self.window
        lock.lock(); defer { lock.unlock() }
        samples.removeAll { $0.t < cutoff }
        events.removeAll { $0.t < cutoff }
        return (samples, events, weapon)
    }

    // MARK: - Demo trace

    /// A canned shotgun pull: ease past the actuation threshold, three
    /// shots with kickback, ease off. Runs through the same buffer as real
    /// input so what it films is what the pipeline does.
    func runDemo() {
        demoTask?.cancel()
        demoTask = Task {
            let dt = 1.0 / 90.0
            var t = 0.0
            var fired = false
            var shots = 0
            while t < 2.6, !Task.isCancelled {
                let rt: Float
                switch t {
                case ..<0.7:            // the pull, eased
                    let p = Float(t / 0.7)
                    rt = p * p * (3 - 2 * p)
                case ..<1.8: rt = 1.0   // held: automatic cadence
                default:                // the release
                    let p = Float(min((t - 1.8) / 0.5, 1))
                    rt = 1 - p * p * (3 - 2 * p)
                }
                record(rt: rt, lt: 0)
                if rt >= 0.35, !fired { fired = true; fire(); shots = 1; kickback(intensity: 0.9) }
                if rt < 0.2 { fired = false }
                if fired, t > 0.7 + Double(shots) * 0.45, shots < 3 {
                    shots += 1
                    fire()
                    kickback(intensity: 0.9)
                }
                try? await Task.sleep(nanoseconds: UInt64(dt * 1e9))
                t += dt
            }
        }
    }

    // MARK: - Internals

    private func append(_ sample: Sample) {
        lock.lock()
        samples.append(sample)
        if samples.count > 2048 { samples.removeFirst(samples.count - 2048) }
        lock.unlock()
    }

    private func appendEvent(_ event: Event) {
        lock.lock()
        events.append(event)
        if events.count > 256 { events.removeFirst(events.count - 256) }
        lock.unlock()
    }
}
