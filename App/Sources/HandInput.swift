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
            if HandDebug.shared.enabled {
                HandDebug.shared.publish(left.debugVerts + right.debugVerts)
            }
        }
        aggregator.remove(.hands)
    }

    // MARK: - Gesture synthesis

    private func emit(left: inout HandState, right: inout HandState) {
        var slice = PadAggregator.Slice()
        let now = CACurrentMediaTime()

        // While the wheel is open, ALL other gestures are suppressed --
        // you are choosing a weapon, not fighting or moving. This is why
        // the dominant hand stopped "confusing it": open the wheel and the
        // only live gestures are point (highlight) and release (commit).
        if WheelState.shared.isOpen {
            aggregator.update(.hands, slice)   // zeroed
            return
        }

        // Body-frame axes: rotate room-frame drags by the same correction
        // the renderer composes under the head pose.
        let basis = TrackingSpace.rotation

        // Handedness: the OFF (non-gun) hand moves, jumps, crouches; the
        // DOMINANT (gun) hand aims and fires.
        let rightHanded = VRSettings.shared.rightHanded
        let move = rightHanded ? left : right
        let aim = rightHanded ? right : left

        // Movement, VRChat-style: hold a thumb+middle pinch on the move hand
        // to walk forward where you look (vr_moverelative steers by head).
        // A hold, not a drag -- a drag kept resetting when the pinch
        // flickered, which is why it "didn't pick up". Frees the index
        // finger for the wheel and aiming.
        if move.middlePinched {
            slice.ly = 1
        }

        // Jump: move-hand thumb+ring pinch. Crouch: thumb+pinky (held).
        if move.ringPinched { slice.buttons |= UInt32(QC_PAD_A) }        // +jump
        if move.pinkyPinched { slice.buttons |= UInt32(QC_PAD_LTHUMB) }  // +movedown

        // Fire: dominant index pinch.
        if aim.indexPinched { slice.rt = 1 }

        // Snap turn: dominant thumb+middle pinch dragged sideways.
        if let drag = aim.middleDrag {
            let d = basis * drag
            if abs(d.x) > 0.06 { slice.rx = d.x > 0 ? 1 : -1 }
        }

        // Both index pinches held still for a second: recenter.
        var moveW = move
        if left.indexPinched, right.indexPinched,
           left.indexDragLength < 0.02, right.indexDragLength < 0.02 {
            if let since = bothPinchedSince {
                if now - since > 1.0 {
                    moveW.stickyUntil[.recenter] = now + Self.pulse
                    bothPinchedSince = now + 999  // once per hold
                }
            } else {
                bothPinchedSince = now
            }
        } else {
            bothPinchedSince = nil
        }
        if moveW.stickyUntil[.recenter, default: 0] > now { slice.buttons |= UInt32(QC_PAD_OPTIONS) }
        if rightHanded { left = moveW } else { right = moveW }

        aggregator.update(.hands, slice)
    }

    private var bothPinchedSince: Double?

    /// Weapon wheel, ONE-HANDED. The off-hand palm gesture holds the ring
    /// open around that wrist, and the SAME hand selects: point the index
    /// finger toward a slot to highlight it and rest there ~0.28s to swap
    /// to it live; flip the palm back to close. Nothing else -- the other
    /// hand is free and every other gesture is suppressed while it's open.
    private func wheel(left: HandState, right: HandState) {
        let rightHanded = VRSettings.shared.rightHanded
        let hand = rightHanded ? left : right

        WheelState.shared.setHold(hand.palmUp, source: .hands)
        guard hand.palmUp else { return }

        let correction = TrackingSpace.correction
        if let wrist = hand.wrist {
            let p = correction * SIMD4(wrist, 1)
            WheelState.shared.setAnchor(trackingPosition: SIMD3(p.x, p.y, p.z))
        }
        // The wheel hand's own finger direction is the pointer: its angle in
        // the ring plane (body-right = x, world-up = y after correction) is
        // the highlighted slot.
        if let dir = hand.indexRayDirection {
            let d = TrackingSpace.rotation * dir
            WheelState.shared.setPointerAngle(right: d.x, up: d.y)
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
    var ringPinched = false
    var pinkyPinched = false
    var indexDrag: SIMD3<Float>?       // metres from pinch start, room frame
    var middleDrag: SIMD3<Float>?
    var stickyUntil: [Pulse: Double] = [:]

    // Wheel facts, room frame (uncorrected).
    var wrist: SIMD3<Float>?
    var palmUp = false
    var indexRayOrigin: SIMD3<Float>?
    var indexRayDirection: SIMD3<Float>?

    /// Coloured finger bones for the debug overlay, corrected-tracking
    /// space, 7 floats/vertex (xyz + rgba), line list. Built in ingest.
    var debugVerts: [Float] = []

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

        // Hysteresis, loosened so pinches catch reliably (the middle-finger
        // pinch for movement was dropping out): 2.5 cm closes, 4.0 cm opens.
        func pinch(_ tipPos: SIMD3<Float>?, _ pinched: Bool) -> Bool {
            guard let tipPos else { return false }
            let d = simd_distance(thumb, tipPos)
            return pinched ? d < 0.040 : d < 0.025
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

        // Ring and pinky pinches: discrete holds (jump, crouch).
        ringPinched = pinch(tip(.ringFingerTip), ringPinched)
        pinkyPinched = pinch(tip(.littleFingerTip), pinkyPinched)

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

        buildDebug(tip: tip)
    }

    /// Colour each finger by whether its gesture is firing, so the overlay
    /// shows detection live. Points are pushed through the recenter
    /// correction into the same frame the renderer draws in.
    private mutating func buildDebug(tip: (HandSkeleton.JointName) -> SIMD3<Float>?) {
        guard HandDebug.shared.enabled else { debugVerts = []; return }
        let dim = SIMD4<Float>(0.7, 0.7, 0.7, 0.5)
        let green = SIMD4<Float>(0.1, 1.0, 0.4, 0.95)
        let blue = SIMD4<Float>(0.3, 0.6, 1.0, 0.95)
        let red = SIMD4<Float>(1.0, 0.3, 0.3, 0.95)
        let cyan = SIMD4<Float>(0.3, 0.9, 1.0, 0.9)

        let fingers: [(joints: [HandSkeleton.JointName], color: SIMD4<Float>)] = [
            ([.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
             middlePinched || ringPinched ? green : dim),
            ([.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
             indexPinched ? red : dim),
            ([.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
             middlePinched ? green : dim),
            ([.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
             ringPinched ? green : dim),
            ([.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip],
             pinkyPinched ? blue : dim),
        ]
        let correction = TrackingSpace.correction
        var v: [Float] = []
        func add(_ p: SIMD3<Float>, _ c: SIMD4<Float>) {
            let q = correction * SIMD4(p, 1)
            v += [q.x, q.y, q.z, c.x, c.y, c.z, c.w]
        }
        let wristPt = tip(.wrist)
        for (joints, baseColor) in fingers {
            let color = palmUp ? cyan : baseColor
            var prev = wristPt
            for j in joints {
                guard let cur = tip(j) else { prev = nil; continue }
                if let p = prev { add(p, color); add(cur, color) }
                prev = cur
            }
        }
        debugVerts = v
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
