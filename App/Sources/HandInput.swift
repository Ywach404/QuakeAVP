//
//  HandInput.swift
//
//  Controller-less play: ARKit hand tracking synthesized onto the same
//  virtual pad every other input source feeds, so the engine plumbing,
//  bindings, snap-turn hysteresis and comfort systems all apply unchanged.
//  Active only while the immersive space is open AND no physical controller
//  is attached — hardware always wins.
//
//  The gesture language (VRChat/Battle-Talent conclusions, adapted to bare
//  hands). The OFF hand locomotes, the GUN hand aims and turns:
//    move thumb+middle hold    walk forward (where you look, vr_moverelative)
//    move thumb+index hold     walk backward
//    move thumb+ring pinch     jump
//    move thumb+pinky hold     crouch
//    move palm-up              open the weapon wheel (that hand selects)
//    gun index pinch           fire (hold for automatic)
//    gun horizontal flick      snap turn -- quick un-pinched sideways whip
//    gun thumb+middle drag     turn fallback / smooth-turn's held signal
//
//  Drag vectors are rotated by the render thread's recenter correction
//  (TrackingSpace) so "forward" is the body's forward, not the room's
//  arbitrary axis. M6: the dominant hand's FOREARM axis (elbow->wrist, not
//  a finger — pinching to fire, a fist, or an open hand must not move or drop
//  the aim) is fed to the engine as the aim (feedAim -> QC_InputSetAim), so
//  the gun is an arm-cannon along the forearm, decoupled from body and gaze.
//

import ARKit
import QuartzCore
import simd

final class HandInput: @unchecked Sendable {

    private let aggregator: PadAggregator
    private var session: ARKitSession?
    private var task: Task<Void, Never>?

    // Flick snap-turn on the gun hand: a horizontal wrist speed past
    // `flickSpeed` fires one snap, then the gesture is disarmed until the
    // hand slows below `flickReset` AND the cooldown lapses -- so the return
    // stroke and a continued sweep can't spin you. The pad rx is HELD for
    // `flickPulse` after a trigger so the engine's tick reliably samples it
    // (a single-frame pulse landed between ticks and got dropped -- that was
    // the "turning doesn't work" bug). Watch the on-hand gauge to calibrate.
    // Trigger speed is live-tunable: VRSettings.turnFlickSpeed (Comfort menu).
    private static let flickReset: Float = 0.35    // m/s to re-arm
    private static let flickCooldown = 0.35        // s to swallow the return
    private static let flickPulse = 0.09           // s to hold the pad pulse
    private var flickArmed = true
    private var flickCooldownUntil = 0.0
    private var flickPulseUntil = 0.0
    private var flickDir: Float = 0

    /// Turn-gauge geometry (corrected tracking space, 7 floats/vertex),
    /// published alongside the debug wireframe when the overlay is on.
    private var turnGaugeVerts: [Float] = []

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
            VirtualHand.shared.publish([])
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
                HandDebug.shared.publish(left.debugVerts + right.debugVerts + turnGaugeVerts)
            }
            VirtualHand.shared.publish(left.virtualVerts + right.virtualVerts)
        }
        aggregator.remove(.hands)
        VirtualHand.shared.publish([])   // hands gone: no stand-in to draw
    }

    // MARK: - Gesture synthesis

    private func emit(left: inout HandState, right: inout HandState) {
        var slice = PadAggregator.Slice()

        // Handedness: the OFF (non-gun) hand moves, jumps, crouches; the
        // DOMINANT (gun) hand aims and fires.
        let rightHanded = VRSettings.shared.rightHanded
        let move = rightHanded ? left : right
        let aim = rightHanded ? right : left

        // M6: feed the dominant hand's aim ray to the engine every update,
        // even while the wheel is open, so the gun keeps tracking the hand.
        feedAim(aim)

        // While the wheel is open, ALL other gestures are suppressed --
        // you are choosing a weapon, not fighting or moving. This is why
        // the dominant hand stopped "confusing it": open the wheel and the
        // only live gestures are point (highlight) and release (commit).
        if WheelState.shared.isOpen {
            aggregator.update(.hands, slice)   // zeroed
            turnGaugeVerts = []                // no turning while choosing a weapon
            return
        }

        // Body-frame axes: rotate room-frame drags by the same correction
        // the renderer composes under the head pose.
        let basis = TrackingSpace.rotation

        // Movement, VRChat-style holds on the move hand (not drags -- a
        // drag reset whenever the pinch flickered): thumb+INDEX walks
        // FORWARD where you look, thumb+MIDDLE walks BACKWARD. Steer with
        // your head (vr_moverelative).
        if move.indexPinched { slice.ly += 1 }    // forward
        if move.middlePinched { slice.ly -= 1 }   // backward

        // Jump: move-hand thumb+ring pinch. Crouch: thumb+pinky (held).
        if move.ringPinched { slice.buttons |= UInt32(QC_PAD_A) }        // +jump
        if move.pinkyPinched { slice.buttons |= UInt32(QC_PAD_LTHUMB) }  // +movedown

        // Fire: dominant index pinch.
        if aim.indexPinched { slice.rt = 1 }

        // Turn on the gun hand, two ways in. The pinch-drag is checked first
        // so smooth-turn (which needs a HELD signal) and a deliberate snap
        // fallback keep working; if it isn't driving, a quick UN-PINCHED
        // sideways FLICK of the hand fires one snap. The flick is the easy
        // default -- no finger gesture, just whip the hand left or right.
        var turnedByPinch = false
        if let drag = aim.middleDrag {
            let d = basis * drag
            if abs(d.x) > 0.06 { slice.rx = d.x > 0 ? 1 : -1; turnedByPinch = true }
        }
        let speed = aim.wristVel.map { (basis * $0).x } ?? 0   // body-right m/s
        let flickSpeed = max(0.2, VRSettings.shared.turnFlickSpeed)   // live-tunable
        let now = CACurrentMediaTime()
        var firing = false
        if !turnedByPinch {
            if flickArmed, now >= flickCooldownUntil, abs(speed) > flickSpeed {
                flickDir = speed > 0 ? 1 : -1
                flickArmed = false
                flickPulseUntil = now + Self.flickPulse         // HOLD so the engine samples it
                flickCooldownUntil = now + Self.flickCooldown   // swallow the return stroke
            } else if abs(speed) < Self.flickReset {
                flickArmed = true                // hand slowed: ready for the next flick
            }
            firing = now < flickPulseUntil
            if firing { slice.rx = flickDir }
        }
        // Drive the on-hand turn gauge so the flick is visible/debuggable.
        buildTurnGauge(wrist: aim.wrist, speed: speed, threshold: flickSpeed,
                       armed: flickArmed, firing: firing)

        aggregator.update(.hands, slice)
    }


    /// A world-space gauge floating above the gun-hand wrist that shows the
    /// flick snap-turn signal live: a horizontal track with threshold ticks at
    /// +/- flickSpeed, and a marker that slides with the body-right wrist speed
    /// -- green while ARMED, yellow during the cooldown, white when a flick
    /// FIRES. So you can see the whip cross the line (and how close a too-slow
    /// whip came) instead of guessing why the turn didn't take. Built in the
    /// corrected tracking frame where +X is body-right (the flick axis); drawn
    /// with the debug overlay through handViewproj. Triangles, not lines.
    private func buildTurnGauge(wrist: SIMD3<Float>?, speed: Float, threshold: Float,
                                armed: Bool, firing: Bool) {
        guard HandDebug.shared.enabled, let w = wrist else { turnGaugeVerts = []; return }
        let c4 = TrackingSpace.correction * SIMD4(w, 1)
        let center = SIMD3(c4.x, c4.y + 0.14, c4.z - 0.02)   // above/ahead of the wrist
        let halfW: Float = 0.09
        var v: [Float] = []
        func quad(_ cx: Float, _ hw: Float, _ hh: Float, _ col: SIMD4<Float>) {
            let x = center.x + cx, y = center.y, z = center.z
            let a = SIMD3(x - hw, y - hh, z), b = SIMD3(x + hw, y - hh, z)
            let c = SIMD3(x + hw, y + hh, z), d = SIMD3(x - hw, y + hh, z)
            for q in [a, b, c, a, c, d] { v += [q.x, q.y, q.z, col.x, col.y, col.z, col.w] }
        }
        let track = SIMD4<Float>(0.10, 0.30, 0.14, 0.70)
        let tick  = SIMD4<Float>(1.0, 0.55, 0.20, 0.95)
        let armedC = SIMD4<Float>(0.25, 1.0, 0.45, 0.98)
        let coolC  = SIMD4<Float>(0.90, 0.80, 0.20, 0.90)
        let fireC  = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        quad(0, halfW, 0.004, track)                 // track
        quad(-halfW, 0.004, 0.016, tick)             // threshold ticks = flickSpeed
        quad( halfW, 0.004, 0.016, tick)
        quad(0, 0.003, 0.012, track)                 // centre
        let frac = max(-1.2, min(1.2, speed / threshold))   // edge = current threshold
        quad(frac * halfW, 0.008, 0.020,             // moving marker
             firing ? fireC : (armed ? armedC : coolC))
        turnGaugeVerts = v
    }

    /// M6 aim: turn the dominant hand's FOREARM axis into the engine's aim.
    /// The ray (wrist origin, elbow->wrist direction — deliberately NOT a
    /// finger, which moves when you pinch to fire and drops out in a fist or
    /// open hand) is corrected into the recenter-neutral frame — the same
    /// TrackingSpace correction the wheel
    /// and the renderer use — then to Quake's body axes: yaw CCW/left-positive
    /// relative to room forward (the engine adds the body yaw), pitch
    /// positive-down, muzzle origin in body-frame Quake units. `valid 0` when
    /// the wrist isn't tracked, so the shot falls back to the body aim.
    private func feedAim(_ hand: HandState) {
        guard let o = hand.aimOrigin, let d = hand.aimDir else {
            QC_InputSetAim(0, 0, 0, 0, 0, 0)
            return
        }
        let corr = TrackingSpace.correction
        let op = corr * SIMD4(o, 1)
        let dp = corr * SIMD4(d, 0)          // direction: rotation only (w = 0)
        let dir = simd_normalize(SIMD3(dp.x, dp.y, dp.z))
        let aimYaw = atan2(-dir.x, -dir.z) * 180 / .pi
        let horiz = (dir.x * dir.x + dir.z * dir.z).squareRoot()
        let aimPitch = -atan2(dir.y, horiz) * 180 / .pi
        let s = WheelState.shared.currentWorldScale
        QC_InputSetAim(1, -op.z / s, op.x / s, op.y / s, aimYaw, aimPitch)
    }

    /// Weapon wheel, ONE-HANDED. The off-hand palm gesture holds the ring
    /// open; the ring then LOCKS in place and the same wrist is the selector
    /// -- move the whole hand toward a weapon to highlight it and rest there
    /// ~0.28s to swap to it live; flip the palm back to close. No finger
    /// pointing (it was too fiddly on a ring anchored to that same wrist);
    /// every other gesture stays suppressed while it's open.
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
    /// Wrist velocity, room frame, metres/sec -- drives the flick snap turn.
    var wristVel: SIMD3<Float>?
    var palmUp = false
    var aimOrigin: SIMD3<Float>?      // wrist, room frame
    var aimDir: SIMD3<Float>?         // forearm->knuckle, room frame

    /// Coloured finger bones for the debug overlay, corrected-tracking
    /// space, 7 floats/vertex (xyz + rgba), line list. Built in ingest.
    var debugVerts: [Float] = []

    /// The stylised solid hand (forearm + palm + fingers), corrected-tracking
    /// space, 7 floats/vertex (xyz + rgba), triangle list. Built every ingest,
    /// drawn by the render thread at opacity 1 - phase. See VirtualHand.
    var virtualVerts: [Float] = []

    /// Flips the palm-normal convention if the skeleton's winding turns
    /// out mirrored on hardware; calibrate on device, not by argument.
    private static let palmSign: Float = 1

    private var prevWrist: SIMD3<Float>?
    private var prevWristTime = 0.0
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
        // Wrist velocity for the flick snap-turn. Skip the first sample and
        // any dt spike (tracking resuming after a dropout would read as a
        // huge phantom velocity and fire a bogus turn).
        let velNow = CACurrentMediaTime()
        if let w = wrist, let pw = prevWrist {
            let dt = velNow - prevWristTime
            wristVel = (dt > 0.001 && dt < 0.1) ? (w - pw) / Float(dt) : nil
        } else {
            wristVel = nil
        }
        prevWrist = wrist
        prevWristTime = velNow
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
        // Aim along the FOREARM axis -- a "megaman cannon" that points where
        // the arm points. Crucially this does NOT depend on finger tracking,
        // so the gun holds steady through a fist, an open hand, a turned wrist
        // or a fire pinch (the old wrist->knuckle ray lost the middle knuckle
        // in those poses and the gun winked out). Direction is elbow-side
        // forearm joint -> wrist, extended out the hand; origin is the wrist,
        // which tracks whenever the hand does. Fall back to wrist->knuckle
        // only if the forearm joint is missing.
        if let w = wrist {
            aimOrigin = w
            if let arm = tip(.forearmArm), simd_length(w - arm) > 0.05 {
                aimDir = simd_normalize(w - arm)
            } else if let knuckle = tip(.middleFingerKnuckle),
                      simd_length(knuckle - w) > 0.03 {
                aimDir = simd_normalize(knuckle - w)
            } else {
                aimDir = nil
            }
        } else {
            aimOrigin = nil
            aimDir = nil
        }

        buildDebug(tip: tip)
        buildVirtual(tip: tip, isLeft: isLeft)
    }

    /// The stylised virtual hand: a sleeve-toned forearm stub, a skin palm
    /// fan from the wrist to the knuckles, and tapered finger ribbons — enough
    /// to read as a hand without arm IK (there is no shoulder to solve to, and
    /// a guessed elbow looks worse than none, so the forearm is just the
    /// ARKit forearm joint). Corrected-tracking space, triangles, 7 floats
    /// each. Colours are sRGB-ish; the guide fragment linearises them.
    private mutating func buildVirtual(tip: (HandSkeleton.JointName) -> SIMD3<Float>?,
                                       isLeft: Bool) {
        guard let wristPt = tip(.wrist) else { virtualVerts = []; return }
        let corr = TrackingSpace.correction
        let skin = SIMD4<Float>(0.80, 0.60, 0.48, 1)
        let cuff = SIMD4<Float>(0.30, 0.34, 0.44, 1)
        let up = SIMD3<Float>(0, 1, 0)
        var v: [Float] = []
        func c(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = corr * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z)
        }
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ d: SIMD3<Float>, _ col: SIMD4<Float>) {
            for p in [c(a), c(b), c(d)] { v += [p.x, p.y, p.z, col.x, col.y, col.z, col.w] }
        }
        func ribbon(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ t: Float, _ col: SIMD4<Float>) {
            var perp = simd_cross(b - a, up)
            if simd_length(perp) < 1e-5 { perp = simd_cross(b - a, SIMD3(1, 0, 0)) }
            perp = simd_length(perp) > 0 ? simd_normalize(perp) * t : SIMD3(t, 0, 0)
            tri(a - perp, a + perp, b - perp, col)
            tri(a + perp, b + perp, b - perp, col)
        }
        // Forearm stub from the ARKit forearm joint to the wrist.
        if let arm = tip(.forearmArm) { ribbon(arm, wristPt, 0.026, cuff) }
        // Palm: a fan from the wrist across the knuckle line.
        let knuckles = [HandSkeleton.JointName.indexFingerKnuckle, .middleFingerKnuckle,
                        .ringFingerKnuckle, .littleFingerKnuckle].compactMap { tip($0) }
        for i in 0..<max(0, knuckles.count - 1) {
            tri(wristPt, knuckles[i], knuckles[i + 1], skin)
        }
        if let thumbK = tip(.thumbKnuckle), let idxK = knuckles.first {
            tri(wristPt, thumbK, idxK, skin)
        }
        // Fingers as tapered ribbons.
        let fingers: [[HandSkeleton.JointName]] = [
            [.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
            [.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
            [.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
            [.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
            [.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip],
        ]
        for joints in fingers {
            var prev: SIMD3<Float>?
            for (i, j) in joints.enumerated() {
                guard let cur = tip(j) else { prev = nil; continue }
                if let p = prev { ribbon(p, cur, i <= 1 ? 0.009 : 0.007, skin) }
                prev = cur
            }
        }
        virtualVerts = v
    }

    /// A GREEN WIREFRAME skeleton: thin bones between joints and a small
    /// sphere-ish node at each joint, so the tracked hand reads like a
    /// classic wireframe rig. Still doubles as the gesture debugger -- a
    /// finger brightens when its pinch/gesture fires, so a dim finger you're
    /// pinching means the gesture isn't registering. Bones are thin quads and
    /// nodes are octahedra, not lines/points (foveation forbids those on
    /// device). Corrected-tracking space, 7 floats/vertex (xyz + rgba).
    private mutating func buildDebug(tip: (HandSkeleton.JointName) -> SIMD3<Float>?) {
        guard HandDebug.shared.enabled else { debugVerts = []; return }
        let dimGreen = SIMD4<Float>(0.10, 0.55, 0.20, 0.85)
        let hotGreen = SIMD4<Float>(0.25, 1.0, 0.45, 0.98)

        let fingers: [(joints: [HandSkeleton.JointName], active: Bool)] = [
            ([.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
             middlePinched || ringPinched),
            ([.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
             indexPinched),
            ([.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
             middlePinched),
            ([.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
             ringPinched),
            ([.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip],
             pinkyPinched),
        ]
        let correction = TrackingSpace.correction
        var v: [Float] = []
        func corner(_ p: SIMD3<Float>, _ c: SIMD4<Float>) {
            let q = correction * SIMD4(p, 1)
            v += [q.x, q.y, q.z, c.x, c.y, c.z, c.w]
        }
        // Thin quad bone (~2.5 mm half-thickness), perpendicular off world-up
        // so a "line" shows from most angles.
        let up = SIMD3<Float>(0, 1, 0)
        func bone(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD4<Float>) {
            var perp = simd_cross(b - a, up)
            if simd_length(perp) < 1e-5 { perp = simd_cross(b - a, SIMD3(1, 0, 0)) }
            perp = simd_length(perp) > 0 ? simd_normalize(perp) * 0.0025 : SIMD3(0.0025, 0, 0)
            let a0 = a - perp, a1 = a + perp, b0 = b - perp, b1 = b + perp
            corner(a0, c); corner(a1, c); corner(b0, c)
            corner(a1, c); corner(b1, c); corner(b0, c)
        }
        // Octahedron node: 6 axis points, 8 faces -- a cheap round dot that
        // reads as a joint sphere from any angle.
        func node(_ p: SIMD3<Float>, _ r: Float, _ c: SIMD4<Float>) {
            let px = p + SIMD3(r,0,0), nx = p - SIMD3(r,0,0)
            let py = p + SIMD3(0,r,0), ny = p - SIMD3(0,r,0)
            let pz = p + SIMD3(0,0,r), nz = p - SIMD3(0,0,r)
            func f(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ d: SIMD3<Float>) {
                corner(a, c); corner(b, c); corner(d, c)
            }
            f(px,py,pz); f(py,nx,pz); f(nx,ny,pz); f(ny,px,pz)
            f(py,px,nz); f(nx,py,nz); f(ny,nx,nz); f(px,ny,nz)
        }
        let wristPt = tip(.wrist)
        for (joints, active) in fingers {
            let color = (palmUp || active) ? hotGreen : dimGreen
            var prev = wristPt
            for j in joints {
                guard let cur = tip(j) else { prev = nil; continue }
                if let p = prev { bone(p, cur, color) }
                node(cur, 0.006, color)
                prev = cur
            }
        }
        if let w = wristPt { node(w, 0.010, palmUp ? hotGreen : dimGreen) }
        debugVerts = v
    }

    /// True exactly once when a short, still middle pinch was released.
    mutating func middleTapFired(now: Double) -> Bool {
        guard middleReleasedClean else { return false }
        middleReleasedClean = false
        return true
    }
}

/// The stylised virtual hand mesh, shared from HandInput to the render
/// thread. Corrected-tracking space, 7 floats/vertex (xyz + rgba), triangle
/// list — the render thread scales the alpha by 1 - phase and draws it on the
/// real hand with the wheel-guide pipeline. Empty while no hand is tracked.
final class VirtualHand: @unchecked Sendable {
    static let shared = VirtualHand()
    private let lock = NSLock()
    private var verts: [Float] = []

    func publish(_ v: [Float]) {
        lock.lock(); verts = v; lock.unlock()
    }

    func snapshot() -> [Float] {
        lock.lock(); defer { lock.unlock() }
        return verts
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
