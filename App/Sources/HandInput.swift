//
//  HandInput.swift
//
//  Controller-less play: ARKit hand tracking synthesized onto the same
//  virtual pad every other input source feeds, so the engine plumbing,
//  bindings, snap-turn hysteresis and comfort systems all apply unchanged.
//  Active only while the immersive space is open AND no physical controller
//  is attached — hardware always wins.
//
//  The gesture language (QuakeQuest's conclusions, adapted to bare hands):
//    left index pinch + drag   virtual movement stick (2 cm deadzone,
//                              full speed at 12 cm, body-frame axes)
//    left middle pinch tap     jump
//    right index pinch         fire (hold for automatic)
//    right middle pinch drag   snap turn (±6 cm sideways)
//    right middle pinch tap    next weapon
//    both index pinches 1 s    recenter
//
//  Drag vectors are rotated by the render thread's recenter correction
//  (TrackingSpace) so "forward" is the body's forward, not the room's
//  arbitrary axis. Aim stays on the body for now: hand-attached weaponry
//  needs the aim/body packet split (M6).
//

import ARKit
import QuartzCore
import simd

final class HandInput: @unchecked Sendable {

    private let aggregator: PadAggregator
    private var session: ARKitSession?
    private var task: Task<Void, Never>?

    init(aggregator: PadAggregator) {
        self.aggregator = aggregator
    }

    @MainActor private(set) var isRunning = false

    @MainActor
    func setActive(_ active: Bool) {
        if active, task == nil {
            isRunning = true
            task = Task { [weak self] in await self?.run() }
        } else if !active, task != nil {
            isRunning = false
            task?.cancel()
            task = nil
            session?.stop()
            session = nil
            aggregator.remove(.hands)
        }
    }

    private func run() async {
        guard HandTrackingProvider.isSupported else {
            print("[input] hand tracking unsupported here")
            await MainActor.run { isRunning = false }
            return
        }
        let provider = HandTrackingProvider()
        let session = ARKitSession()
        self.session = session
        do {
            try await session.run([provider])
        } catch {
            print("[input] hand tracking failed to start: \(error)")
            await MainActor.run { isRunning = false }
            return
        }

        var left = HandState()
        var right = HandState()

        for await update in provider.anchorUpdates {
            if Task.isCancelled { break }
            guard update.event == .updated || update.event == .added else {
                if update.anchor.chirality == .left { left = HandState() }
                else { right = HandState() }
                continue
            }
            let anchor = update.anchor
            if anchor.chirality == .left {
                left.ingest(anchor, isLeft: true)
            } else {
                right.ingest(anchor, isLeft: false)
            }
            emit(left: &left, right: &right)
            wheel(left: left, right: right)
        }
        aggregator.remove(.hands)
    }

    // MARK: - Gesture synthesis

    private func emit(left: inout HandState, right: inout HandState) {
        var slice = PadAggregator.Slice()
        let now = CACurrentMediaTime()

        // Body-frame axes: rotate room-frame drags by the same correction
        // the renderer composes under the head pose.
        let basis = TrackingSpace.rotation

        // Left index pinch-drag: the movement stick.
        if let drag = left.indexDrag {
            let d = basis * drag
            slice.lx = Self.stick(d.x)
            slice.ly = Self.stick(-d.z)
        }

        // Right index pinch: fire.
        if right.indexPinched {
            slice.rt = 1
        }

        // Right middle pinch: sideways drag snaps, a clean tap cycles.
        if let drag = right.middleDrag {
            let d = basis * drag
            if abs(d.x) > 0.06 {
                slice.rx = d.x > 0 ? 1 : -1
            }
        }
        if right.middleTapFired(now: now) {
            right.stickyUntil[.nextWeapon] = now + Self.pulse
        }
        if left.middleTapFired(now: now) {
            left.stickyUntil[.jump] = now + Self.pulse
        }

        // Both index pinches held still: recenter.
        if left.indexPinched, right.indexPinched,
           left.indexDragLength < 0.02, right.indexDragLength < 0.02 {
            if let since = bothPinchedSince {
                if now - since > 1.0 {
                    left.stickyUntil[.recenter] = now + Self.pulse
                    bothPinchedSince = now + 999  // once per hold
                }
            } else {
                bothPinchedSince = now
            }
        } else {
            bothPinchedSince = nil
        }

        // Sticky pulses outlive a couple of engine frames so the edge diff
        // can't miss them between drains.
        if left.stickyUntil[.jump, default: 0] > now { slice.buttons |= UInt32(QC_PAD_A) }
        if right.stickyUntil[.nextWeapon, default: 0] > now { slice.buttons |= UInt32(QC_PAD_Y) }
        if left.stickyUntil[.recenter, default: 0] > now { slice.buttons |= UInt32(QC_PAD_OPTIONS) }

        aggregator.update(.hands, slice)
    }

    private var bothPinchedSince: Double?
    private var wheelCommitLatch = false

    /// Weapon wheel, hands language: off-hand palm up opens and anchors
    /// the ring at that wrist; the aim hand's index ray highlights; a pinch
    /// commits without closing the wheel. The engine has already silenced
    /// fire and locomotion while it's open.
    private func wheel(left: HandState, right: HandState) {
        WheelState.shared.setHold(left.palmUp, source: .hands)
        guard left.palmUp else {
            wheelCommitLatch = false
            return
        }
        let correction = TrackingSpace.correction
        if let wrist = left.wrist {
            let p = correction * SIMD4(wrist, 1)
            WheelState.shared.setAnchor(trackingPosition: SIMD3(p.x, p.y, p.z))
        }
        if let origin = right.indexRayOrigin, let dir = right.indexRayDirection {
            let o = correction * SIMD4(origin, 1)
            let d = TrackingSpace.rotation * dir
            WheelState.shared.setPointer(trackingOrigin: SIMD3(o.x, o.y, o.z),
                                         direction: simd_normalize(d))
        }
        if right.indexPinched, !wheelCommitLatch {
            wheelCommitLatch = true
            WheelState.shared.commitHighlight()
        } else if !right.indexPinched {
            wheelCommitLatch = false
        }
    }

    private static let pulse = 0.12
    private static func stick(_ metres: Float) -> Float {
        let deadzone: Float = 0.02, full: Float = 0.12
        let magnitude = abs(metres)
        guard magnitude > deadzone else { return 0 }
        let v = min((magnitude - deadzone) / (full - deadzone), 1)
        return metres < 0 ? -v : v
    }
}

/// Per-hand pinch state machine over the skeleton's fingertips.
private struct HandState {

    enum Pulse: Hashable { case jump, nextWeapon, recenter }

    var indexPinched = false
    var middlePinched = false
    var indexDrag: SIMD3<Float>?       // metres from pinch start, room frame
    var middleDrag: SIMD3<Float>?
    var stickyUntil: [Pulse: Double] = [:]

    // Wheel facts, room frame (uncorrected).
    var wrist: SIMD3<Float>?
    var palmUp = false
    var indexRayOrigin: SIMD3<Float>?
    var indexRayDirection: SIMD3<Float>?

    /// Flips the palm-normal convention if the skeleton's winding turns
    /// out mirrored on hardware; calibrate on device, not by argument.
    private static let palmSign: Float = 1

    private var indexStart: SIMD3<Float>?
    private var middleStart: SIMD3<Float>?
    private var middleStartTime = 0.0
    private var middleMoved: Float = 0
    private var middleReleasedClean = false

    var indexDragLength: Float { indexDrag.map(simd_length) ?? 0 }

    mutating func ingest(_ anchor: HandAnchor, isLeft: Bool) {
        guard let skeleton = anchor.handSkeleton else { return }
        func tip(_ joint: HandSkeleton.JointName) -> SIMD3<Float>? {
            let j = skeleton.joint(joint)
            guard j.isTracked else { return nil }
            let world = anchor.originFromAnchorTransform * j.anchorFromJointTransform
            return SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        }
        guard let thumb = tip(.thumbTip) else { return }

        // Hysteresis: 1.8 cm closes a pinch, 2.8 cm opens it, so a held
        // pinch can't flutter at the threshold.
        func pinch(_ tipPos: SIMD3<Float>?, _ pinched: Bool) -> Bool {
            guard let tipPos else { return false }
            let d = simd_distance(thumb, tipPos)
            return pinched ? d < 0.028 : d < 0.018
        }

        let index = tip(.indexFingerTip)
        let wasIndex = indexPinched
        indexPinched = pinch(index, indexPinched)
        if indexPinched, !wasIndex { indexStart = index }
        if !indexPinched { indexStart = nil }
        indexDrag = (indexPinched && indexStart != nil && index != nil)
            ? index! - indexStart! : nil

        let middle = tip(.middleFingerTip)
        let wasMiddle = middlePinched
        middlePinched = pinch(middle, middlePinched)
        if middlePinched, !wasMiddle {
            middleStart = middle
            middleStartTime = CACurrentMediaTime()
            middleMoved = 0
        }
        if middlePinched, let middle, let start = middleStart {
            middleMoved = max(middleMoved, simd_distance(middle, start))
            middleDrag = middle - start
        }
        if !middlePinched {
            if wasMiddle {
                middleReleasedClean = middleMoved < 0.02
                    && CACurrentMediaTime() - middleStartTime < 0.35
            }
            middleStart = nil
            middleDrag = nil
        }

        // Wheel facts: the wrist, the palm's facing, the index ray.
        wrist = tip(.wrist)
        if let w = wrist,
           let indexKnuckle = tip(.indexFingerKnuckle),
           let littleKnuckle = tip(.littleFingerKnuckle) {
            var normal = simd_cross(indexKnuckle - w, littleKnuckle - w)
            // The knuckle winding mirrors between hands; normalize both to
            // "out of the palm" before asking whether it faces the sky.
            if !isLeft { normal = -normal }
            normal *= Self.palmSign
            let len = simd_length(normal)
            palmUp = len > 0 && (normal / len).y > 0.55
        } else {
            palmUp = false
        }
        if let knuckle = tip(.indexFingerKnuckle), let tipPos = index,
           simd_distance(knuckle, tipPos) > 0.02 {
            indexRayOrigin = knuckle
            indexRayDirection = simd_normalize(tipPos - knuckle)
        } else {
            indexRayOrigin = nil
            indexRayDirection = nil
        }
    }

    /// True exactly once when a short, still middle pinch was released.
    mutating func middleTapFired(now: Double) -> Bool {
        guard middleReleasedClean else { return false }
        middleReleasedClean = false
        return true
    }
}

/// The recenter correction, shared from the render thread: the rotation
/// maps gesture DRAG deltas into body axes; the full matrix maps absolute
/// positions (wrists, controllers) into the body frame the engine expects.
enum TrackingSpace {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _rotation = matrix_identity_float3x3
    nonisolated(unsafe) private static var _correction = matrix_identity_float4x4

    static var rotation: simd_float3x3 {
        lock.lock(); defer { lock.unlock() }
        return _rotation
    }

    static var correction: simd_float4x4 {
        lock.lock(); defer { lock.unlock() }
        return _correction
    }

    static func setCorrection(_ correction: simd_float4x4) {
        let r = simd_float3x3(
            SIMD3(correction.columns.0.x, correction.columns.0.y, correction.columns.0.z),
            SIMD3(correction.columns.1.x, correction.columns.1.y, correction.columns.1.z),
            SIMD3(correction.columns.2.x, correction.columns.2.y, correction.columns.2.z))
        lock.lock()
        _rotation = r
        _correction = correction
        lock.unlock()
    }
}
