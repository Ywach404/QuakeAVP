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
    private static let flickReset: Float = 0.35    // m/s: "settled" speed
    private static let flickCooldown = 0.35        // s to swallow the return
    private static let flickPulse = 0.09           // s to hold the pad pulse
    // Re-arm requires the hand to DWELL settled for this long (a recenter), not
    // just dip below the reset for an instant -- so the return/re-wind stroke
    // after a turn can't catch a fresh trigger and snap you back.
    private static let flickDwell = 0.12
    private var flickSettledSince = 0.0

    // Stick / clutch snap turn: hand motion accumulates `turnIntent` (degrees);
    // every `snapStep` fires one discrete snap pulse, spaced by snapGap so the
    // engine re-arms between snaps. Comfort snaps, not smooth turning.
    private static let snapStep: Float = 30      // degrees of intent per snap
    private static let snapPulse = 0.09          // s to hold each snap pulse
    private static let snapGap = 0.12            // s min between snaps
    private static let stickDeadzone: Float = 0.06   // m of off-hand offset before turning
    private static let stickGain: Float = 600        // deg/sec per m beyond the deadzone
    private static let clutchGain: Float = 600       // deg per m of aim-hand drag
    private var turnIntent: Float = 0
    private var snapDir: Float = 0
    private var snapPulseUntil = 0.0
    private var snapCooldownUntil = 0.0
    private var stickNeutral: Float?
    private var clutchAnchor: Float?
    private var lastTurnTime = 0.0
    // Auto-balance: each direction triggers at `flickFraction` of that
    // direction's own recent PEAK whip speed, so a strong and a weak direction
    // need equal EFFORT even though one whips faster -- the weak side earns a
    // lower absolute bar on its own. Peaks rise by `flickAttack` toward new
    // highs (one frame's spike can't define the bar) and decay over
    // `flickPeakTau`; an absolute floor (VRSettings.turnFlickSpeed) keeps
    // tracking jitter from ever triggering.
    private static let flickFraction: Float = 0.55
    private static let flickAttack: Float = 0.35
    private static let flickPeakTau: Double = 2.5
    private var flickPeakPos: Float = 1.0          // decaying peak |speed|, body-right
    private var flickPeakNeg: Float = 1.0          // decaying peak |speed|, body-left
    private var flickPeakTime = 0.0
    private var flickArmed = true

    /// Extra downward pitch (degrees) added to the hand aim. The arm/hand line
    /// still sits a little above the sightline, so this drops the shot to where
    /// you think you're pointing. Positive = aim lower. Tune on device.
    private static let aimPitchTrimDeg: Float = 8

    // Finger-gun "bang": one shot per hammer drop. `hammerCocked` latches while
    // the gun pose holds with the thumb up; the drop emits a short fire pulse
    // (so the engine tick samples one shot), then you must re-cock.
    private static let hammerPulse = 0.10
    private var hammerCocked = false
    private var hammerPulseUntil = 0.0
    private var flickCooldownUntil = 0.0
    private var flickPulseUntil = 0.0
    private var flickDir: Float = 0

    /// Turn-gauge geometry (corrected tracking space, 7 floats/vertex),
    /// published alongside the debug wireframe when the overlay is on.
    private var turnGaugeVerts: [Float] = []

    /// Figure overlays (corrected tracking space, 7 floats/vertex): the aim-ray
    /// decomposition and the motion strobe of the aim ray over recent samples.
    private var aimRayVerts: [Float] = []
    private var strobeVerts: [Float] = []
    private var strobeSamples: [(t: Double, o: SIMD3<Float>, d: SIMD3<Float>)] = []
    private var lastStrobe = 0.0
    private static let strobeInterval = 0.06
    private static let strobeCount = 12

    /// Muzzle status bead: flashes on a successful shot and reports aim health,
    /// so you can SEE whether curl/hammer register and whether the aim is
    /// dropping out (the likely cause of the weapon popping in the gun pose).
    private var fireStatusVerts: [Float] = []
    private var lastFireTime = 0.0
    private static let fireFlash = 0.15    // s to hold the flash so it's visible
    private var lastLog = 0.0              // throttle for the input telemetry log

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
            // Fold every enabled overlay into one published buffer: the
            // wireframe + gauge (full debug), and the figure overlays (aim rays,
            // strobe) which draw over the stylised hand too.
            let wire = HandDebug.shared.enabled
            var dbg: [Float] = []
            if wire { dbg += left.debugVerts + right.debugVerts + turnGaugeVerts }
            if HandDebug.shared.aimRays { dbg += aimRayVerts }
            if HandDebug.shared.strobe { dbg += strobeVerts }
            if wire || HandDebug.shared.aimRays || HandDebug.shared.strobe {
                dbg += fireStatusVerts        // muzzle fire/aim-health indicator
                HandDebug.shared.publish(dbg)
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
        aimRayVerts = buildAimRays(aim)

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

        let now = CACurrentMediaTime()

        // Fire: the selected gesture only -- pinch, curl, or the finger-gun
        // hammer -- so the aim-hand gestures can't collide.
        switch VRSettings.shared.fireMode {
        case .pinch:
            if aim.indexPinched { slice.rt = 1 }
        case .curl:
            if aim.indexCurled { slice.rt = 1 }
        case .hammer:
            // Cock while the gun pose holds with the thumb up; the drop fires
            // one short pulse, then you must re-cock. Losing the pose disarms.
            if !aim.indexExtended {
                hammerCocked = false
            } else if !aim.thumbHammerDown {
                hammerCocked = true
            } else if hammerCocked {
                hammerCocked = false
                hammerPulseUntil = now + Self.hammerPulse
            }
            if now < hammerPulseUntil { slice.rt = 1 }
        }

        // Motion strobe: sample the aim ray over time so a still frame shows the
        // gesture's motion. Throttled; oldest samples fade out in buildStrobe.
        if HandDebug.shared.strobe, let o = aim.aimOrigin, let d = aim.aimDir {
            if now - lastStrobe > Self.strobeInterval {
                lastStrobe = now
                let corr = TrackingSpace.correction
                let o4 = corr * SIMD4(o, 1), d4 = corr * SIMD4(d, 0)
                strobeSamples.append((now, SIMD3(o4.x, o4.y, o4.z),
                                      simd_normalize(SIMD3(d4.x, d4.y, d4.z))))
                if strobeSamples.count > Self.strobeCount { strobeSamples.removeFirst() }
            }
            strobeVerts = buildStrobe(now: now)
        } else if !strobeSamples.isEmpty {
            strobeSamples.removeAll()
            strobeVerts = []
        }

        // Muzzle status: flash when the trigger actually fired this frame, and
        // report aim health so a dropout (the likely weapon-pop cause) is
        // visible. rt is set by the fire switch above.
        if slice.rt == 1 { lastFireTime = now }
        fireStatusVerts = buildFireStatus(aim, fired: now - lastFireTime < Self.fireFlash)

        // Input telemetry: the exact aim-hand signals, so a miss can be read off
        // numbers (paste back) instead of guessed. Throttled to ~7 Hz.
        if VRSettings.shared.inputLog, now - lastLog > 0.15 {
            lastLog = now
            let mode = ["pinch", "curl", "hammer"][VRSettings.shared.fireMode.rawValue]
            print("[inputlog] mode=\(mode)"
                + " straight=\(String(format: "%.2f", aim.indexStraightness))"
                + " curl=\(aim.indexCurled ? 1 : 0) ext=\(aim.indexExtended ? 1 : 0)"
                + " thumb=\(Int(aim.thumbBarrelDeg))° ham=\(aim.thumbHammerDown ? 1 : 0)"
                + " aim=\(aim.aimDir != nil ? 1 : 0) fire=\(slice.rt == 1 ? 1 : 0)")
        }

        // Turn: one of three styles (Comfort menu). Stick and clutch accumulate
        // hand motion into comfort snaps via emitTurnSnap; flick is the whip.
        let dt = Float(max(0, min(0.1, now - lastTurnTime)))
        lastTurnTime = now
        switch VRSettings.shared.turnStyle {
        case .flick:
            turnIntent = 0; stickNeutral = nil; clutchAnchor = nil
            // The pinch-drag is checked first (a deliberate held fallback); if it
            // isn't driving, a quick sideways whip fires one snap.
            var turnedByPinch = false
            if let drag = aim.middleDrag {
                let d = basis * drag
                if abs(d.x) > 0.06 { slice.rx = d.x > 0 ? 1 : -1; turnedByPinch = true }
            }
            let speed = aim.wristVel.map { (basis * $0).x } ?? 0   // body-right m/s
            let mag = abs(speed)
            // Auto-balanced flick: decay each direction's peak, fold in the
            // current whip, trigger at a fixed share of that direction's peak.
            let decay = Float(exp(-(now - flickPeakTime) / Self.flickPeakTau))
            flickPeakTime = now
            flickPeakPos *= decay
            flickPeakNeg *= decay
            if speed > 0, mag > flickPeakPos { flickPeakPos += (mag - flickPeakPos) * Self.flickAttack }
            if speed < 0, mag > flickPeakNeg { flickPeakNeg += (mag - flickPeakNeg) * Self.flickAttack }
            let floor = max(0.15, VRSettings.shared.turnFlickSpeed)
            let posThreshold = max(floor, flickPeakPos * Self.flickFraction)
            let negThreshold = max(floor, flickPeakNeg * Self.flickFraction)
            let effThreshold = speed >= 0 ? posThreshold : negThreshold
            var firing = false
            if !turnedByPinch {
                if flickArmed, now >= flickCooldownUntil, mag > effThreshold {
                    flickDir = speed > 0 ? 1 : -1
                    flickArmed = false
                    flickSettledSince = 0
                    flickPulseUntil = now + Self.flickPulse
                    flickCooldownUntil = now + Self.flickCooldown
                } else if mag < Self.flickReset {
                    if flickSettledSince == 0 { flickSettledSince = now }
                    if now - flickSettledSince >= Self.flickDwell { flickArmed = true }
                } else {
                    flickSettledSince = 0
                }
                firing = now < flickPulseUntil
                if firing { slice.rx = flickDir }
            }
            let refSpeed = max(posThreshold, negThreshold, 0.5)
            buildTurnGauge(wrist: aim.wrist, speed: speed,
                           posThreshold: posThreshold, negThreshold: negThreshold, refSpeed: refSpeed,
                           armed: flickArmed, firing: firing)

        case .stick:
            // Pinchless: off-hand lateral displacement from an auto-zeroed
            // neutral sets the snap cadence. Measured in the ROOM frame, so
            // "hand held right" keeps turning right no matter how far you've
            // already turned; resting the hand re-centres.
            turnGaugeVerts = []
            if let ow = move.wrist {
                let lat = (TrackingSpace.correction * SIMD4(ow, 1)).x
                let neutral = stickNeutral ?? lat
                let offset = lat - neutral
                if abs(offset) < Self.stickDeadzone {
                    stickNeutral = neutral + (lat - neutral) * 0.08   // rest redefines centre
                } else {
                    stickNeutral = neutral                            // hold centre while turning
                    let rate = (abs(offset) - Self.stickDeadzone) * Self.stickGain
                    turnIntent += rate * dt * (offset > 0 ? 1 : -1)
                }
            } else {
                stickNeutral = nil
                turnIntent = 0
            }
            emitTurnSnap(now: now, slice: &slice)

        case .clutch:
            // MPH stylus: hold the aim-hand MIDDLE pinch to engage, drag
            // laterally to add snap intent, release to re-centre. Fire stays on
            // the index, so shooting and turning never collide.
            turnGaugeVerts = []
            if aim.middlePinched, let aw = aim.wrist {
                let lat = (TrackingSpace.correction * SIMD4(aw, 1)).x
                if let anchor = clutchAnchor { turnIntent += (lat - anchor) * Self.clutchGain }
                clutchAnchor = lat
            } else {
                clutchAnchor = nil
            }
            emitTurnSnap(now: now, slice: &slice)
        }

        aggregator.update(.hands, slice)
    }


    /// Convert accumulated turn intent into discrete comfort snaps: one snap
    /// pulse per `snapStep` of intent, spaced by snapGap so the engine re-arms
    /// between snaps. Shared by the stick and clutch turn styles.
    private func emitTurnSnap(now: Double, slice: inout PadAggregator.Slice) {
        if abs(turnIntent) >= Self.snapStep, now >= snapCooldownUntil {
            let dir: Float = turnIntent > 0 ? 1 : -1
            snapDir = dir
            snapPulseUntil = now + Self.snapPulse
            snapCooldownUntil = now + Self.snapPulse + Self.snapGap
            turnIntent -= Self.snapStep * dir
        }
        // Clamp the backlog so a fast drag or release can't unleash a spin.
        turnIntent = max(-Self.snapStep, min(Self.snapStep, turnIntent))
        if now < snapPulseUntil { slice.rx = snapDir }
    }

    /// A world-space gauge floating above the gun-hand wrist that shows the
    /// flick snap-turn signal live: a curved track with a threshold tick each
    /// side and a marker that slides with the body-right wrist speed -- green
    /// while ARMED, yellow during the cooldown, white when a flick FIRES. So you
    /// can see the whip cross the line (and how close a too-slow whip came)
    /// instead of guessing why the turn didn't take.
    ///
    /// Framing: the panel billboards toward the eye and is then RECLINED by
    /// `tilt` so it lies back toward the downward glance you actually read your
    /// wrist from, rather than standing vertical. The track is a shallow arc
    /// bowed concave toward you (a curved-monitor look) so some segment always
    /// faces the glance. Built in the corrected tracking frame; drawn with the
    /// debug overlay through handViewproj. Triangles, not lines.
    private func buildTurnGauge(wrist: SIMD3<Float>?, speed: Float,
                                posThreshold: Float, negThreshold: Float, refSpeed: Float,
                                armed: Bool, firing: Bool) {
        guard HandDebug.shared.enabled, let w = wrist else { turnGaugeVerts = []; return }
        let c4 = TrackingSpace.correction * SIMD4(w, 1)
        let center = SIMD3(c4.x, c4.y + 0.14, c4.z)   // above the wrist

        // Billboard toward the eye, then recline the panel toward the glance:
        // `face` is the panel normal, `up` its up axis, both pitched back by
        // `tilt` about `right` so the gauge reads like a tilted dashboard.
        let toEye = simd_normalize(ViewerPose.shared.eye - center)
        var right = simd_cross(SIMD3<Float>(0, 1, 0), toEye)
        right = simd_length(right) > 1e-4 ? simd_normalize(right) : SIMD3(1, 0, 0)
        let up0 = simd_normalize(simd_cross(toEye, right))
        let tilt: Float = 0.55                        // ~31 deg recline toward the glance
        let face = simd_normalize(toEye * cos(tilt) + up0 * sin(tilt))
        let up = simd_normalize(simd_cross(face, right))

        // Shallow arc, concave toward the viewer, laid in (right, face): lateral
        // position rides `right` by R*sin(theta); the ends wrap toward you by
        // R*(1 - cos(theta)). halfW is the chord half-width.
        let halfW: Float = 0.09
        let arcHalf: Float = 0.42                      // half the subtended angle (~48 deg)
        let radius = halfW / sin(arcHalf)
        func arc(_ theta: Float, _ vy: Float) -> SIMD3<Float> {
            center + right * (radius * sin(theta))
                   + face  * (radius * (1 - cos(theta)))
                   + up * vy
        }
        var v: [Float] = []
        // A vertical bar of angular half-width `ha` and height `hh`, centred at
        // angle `theta` on the arc.
        func bar(_ theta: Float, _ ha: Float, _ hh: Float, _ col: SIMD4<Float>) {
            let a = arc(theta - ha, -hh), b = arc(theta + ha, -hh)
            let d = arc(theta + ha,  hh), e = arc(theta - ha,  hh)
            for q in [a, b, d, a, d, e] { v += [q.x, q.y, q.z, col.x, col.y, col.z, col.w] }
        }
        func theta(_ frac: Float) -> Float { max(-1.2, min(1.2, frac)) * arcHalf }

        let track  = SIMD4<Float>(0.10, 0.30, 0.14, 0.70)
        let tick   = SIMD4<Float>(1.0, 0.55, 0.20, 0.95)
        let armedC = SIMD4<Float>(0.25, 1.0, 0.45, 0.98)
        let coolC  = SIMD4<Float>(0.90, 0.80, 0.20, 0.90)
        let fireC  = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)

        // Curved track, drawn as a strip of segments so the bow is visible.
        let segs = 12
        let segHalf = arcHalf / Float(segs)
        for i in 0..<segs {
            let t = -arcHalf + (2 * Float(i) + 1) * segHalf
            bar(t, segHalf, 0.012, track)
        }
        // Auto-balanced ticks: each side sits at its own live threshold, so a
        // weaker direction's tick pulls in toward centre (an easier bar).
        bar(theta( posThreshold / refSpeed), 0.010, 0.026, tick)   // body-right trigger
        bar(theta(-negThreshold / refSpeed), 0.010, 0.026, tick)   // body-left trigger
        bar(0, 0.008, 0.020, track)                                // centre notch
        bar(theta(speed / refSpeed), 0.014, 0.030,                 // moving marker
            firing ? fireC : (armed ? armedC : coolC))
        turnGaugeVerts = v
    }

    /// A view-facing line-quad from a to b (corrected-tracking space) for the
    /// figure overlays -- billboards toward the eye like the turn gauge, since
    /// foveation forbids GL_LINES on device.
    private func lineQuad(_ v: inout [Float], _ a: SIMD3<Float>, _ b: SIMD3<Float>,
                          _ hw: Float, _ col: SIMD4<Float>) {
        let mid = (a + b) * 0.5
        let toEye = simd_normalize(ViewerPose.shared.eye - mid)
        var perp = simd_cross(b - a, toEye)
        perp = simd_length(perp) > 1e-5 ? simd_normalize(perp) * hw : SIMD3(hw, 0, 0)
        let a0 = a - perp, a1 = a + perp, b0 = b - perp, b1 = b + perp
        for q in [a0, a1, b1, a0, b1, b0] { v += [q.x, q.y, q.z, col.x, col.y, col.z, col.w] }
    }

    /// Aim-ray decomposition figure: the forearm-bone base (blue), the knuckle-
    /// centroid hand-forward (orange), and the blended final aim (green, longer
    /// and thicker) as three colour-coded rays from the aim wrist -- so a
    /// screenshot in each grip shows the hybrid ray and its roll-invariance.
    private func buildAimRays(_ aim: HandState) -> [Float] {
        guard HandDebug.shared.aimRays, let o = aim.aimOrigin else { return [] }
        let corr = TrackingSpace.correction
        let o4 = corr * SIMD4(o, 1)
        let origin = SIMD3(o4.x, o4.y, o4.z)
        func dir(_ d: SIMD3<Float>?) -> SIMD3<Float>? {
            guard let d else { return nil }
            let q = corr * SIMD4(d, 0)
            return simd_normalize(SIMD3(q.x, q.y, q.z))
        }
        var v: [Float] = []
        if let d = dir(aim.aimBaseDir) { lineQuad(&v, origin, origin + d * 0.55, 0.004, DebugColor.forearm) }
        if let d = dir(aim.aimHandDir) { lineQuad(&v, origin, origin + d * 0.55, 0.004, DebugColor.centroid) }
        if let d = dir(aim.aimDir)     { lineQuad(&v, origin, origin + d * 1.20, 0.006, DebugColor.blend) }
        return v
    }

    /// A cheap octahedron node (a round-ish dot from any angle) at p.
    private func octa(_ v: inout [Float], _ p: SIMD3<Float>, _ r: Float, _ c: SIMD4<Float>) {
        let px = p + SIMD3(r,0,0), nx = p - SIMD3(r,0,0)
        let py = p + SIMD3(0,r,0), ny = p - SIMD3(0,r,0)
        let pz = p + SIMD3(0,0,r), nz = p - SIMD3(0,0,r)
        func f(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ d: SIMD3<Float>) {
            for q in [a, b, d] { v += [q.x, q.y, q.z, c.x, c.y, c.z, c.w] }
        }
        f(px,py,pz); f(py,nx,pz); f(nx,ny,pz); f(ny,px,pz)
        f(py,px,nz); f(nx,py,nz); f(ny,nx,nz); f(px,ny,nz)
    }

    /// Muzzle status bead at the aim origin: hot-pink flash when a shot fired,
    /// red when the aim ray has dropped out (weapon will pop), dim green when
    /// armed and tracking is healthy. The one indicator answers both "did it
    /// fire?" and "is the aim alive?".
    private func buildFireStatus(_ aim: HandState, fired: Bool) -> [Float] {
        guard let o = aim.aimOrigin else { return [] }
        let corr = TrackingSpace.correction
        let o4 = corr * SIMD4(o, 1)
        var p = SIMD3(o4.x, o4.y, o4.z)
        if let d = aim.aimDir {                       // nudge forward like a muzzle
            let q = corr * SIMD4(d, 0)
            p += simd_normalize(SIMD3(q.x, q.y, q.z)) * 0.05
        }
        var v: [Float] = []
        if fired {
            octa(&v, p, 0.020, DebugColor.fire)
        } else if aim.aimDir == nil {
            octa(&v, p, 0.014, DebugColor.aimLost)
        } else {
            octa(&v, p, 0.008, DebugColor.aimOk)
        }
        return v
    }

    /// Motion strobe: the aim ray sampled over the last ~0.7 s, older samples
    /// fading, so one still frame conveys the gesture's motion.
    private func buildStrobe(now: Double) -> [Float] {
        var v: [Float] = []
        let span = Float(Self.strobeInterval * Double(Self.strobeCount))
        for s in strobeSamples {
            let alpha = max(0, 1 - Float(now - s.t) / span)
            var col = DebugColor.blend
            col.w = 0.12 + 0.78 * alpha
            lineQuad(&v, s.o, s.o + s.d * 0.35, 0.003 + 0.004 * alpha, col)
        }
        return v
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
        let aimPitch = -atan2(dir.y, horiz) * 180 / .pi + Self.aimPitchTrimDeg
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
    var indexCurled = false            // trigger pull: index flexed toward the palm
    var indexExtended = false          // barrel straight: the finger-gun pose
    var thumbHammerDown = false        // thumb dropped toward the barrel: hammer fell
    var indexStraightness: Float = 1   // log: index barrel straightness (1 = straight)
    var thumbBarrelDeg: Float = 180    // log: thumb-to-barrel angle in degrees
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
    var aimDir: SIMD3<Float>?         // blended aim, room frame
    var aimBaseDir: SIMD3<Float>?     // forearm-bone component (debug figure)
    var aimHandDir: SIMD3<Float>?     // knuckle-centroid component (debug figure)

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

    /// Trigger-curl fire thresholds on index STRAIGHTNESS (tip->knuckle chord
    /// over summed bone length: ~1 straight, small when curled). Pulls at
    /// `curlClose`, releases at `curlOpen` -- hysteresis so it can't chatter.
    /// Tune on device.
    /// Finger-gun barrel: index straightness above this counts as extended.
    /// (Curl and hammer thresholds are live-tunable in VRSettings.)
    private static let gunExtend: Float = 0.78

    /// Smoothed aim (the low-pass state); blend + smoothing amounts are
    /// live-tunable in VRSettings.
    private var aimSmoothed: SIMD3<Float>?

    private var prevWrist: SIMD3<Float>?
    private var prevWristTime = 0.0
    private var indexStart: SIMD3<Float>?
    private var middleStart: SIMD3<Float>?
    private var middleStartTime = 0.0
    private var middleMoved: Float = 0
    private var middleReleasedClean = false

    var indexDragLength: Float { indexDrag.map(simd_length) ?? 0 }

    /// Whether the SELECTED fire gesture is currently recognized -- one mode at
    /// a time, so the gestures can't collide. Drives the debug highlight; the
    /// hammer's one-shot edge/pulse is handled in emit().
    var fires: Bool {
        switch VRSettings.shared.fireMode {
        case .pinch:  return indexPinched
        case .curl:   return indexCurled
        case .hammer: return indexExtended && thumbHammerDown
        }
    }

    /// How long to hold the last-good pose after tracking drops before
    /// releasing it. Long enough to ride out ARKit blips, short enough that a
    /// genuinely hidden hand falls back promptly.
    private static let trackGrace = 0.2
    private var lostSince: Double?

    /// Called when a frame arrives without usable tracking: hold the last pose
    /// until the loss has lasted `trackGrace`, then clear so nothing freezes.
    private mutating func trackingLost() {
        let t = CACurrentMediaTime()
        if let s = lostSince {
            if t - s > Self.trackGrace { self = HandState() }   // sustained loss: release
        } else {
            lostSince = t                                        // first lost frame: start the grace
        }
    }

    mutating func ingest(_ anchor: HandAnchor, isLeft: Bool) {
        // Tracking loss (e.g. a lowered, curled gun pose hides the hand from the
        // cameras) is handled with a grace window: HOLD the last-good pose
        // through brief blips so the hand doesn't flicker, but RELEASE (clear)
        // after a sustained loss so the aim/gun/gesture fall back to the body
        // instead of freezing at the last pose.
        guard let skeleton = anchor.handSkeleton else { trackingLost(); return }
        lostSince = nil                          // skeleton present = tracked
        func tip(_ joint: HandSkeleton.JointName) -> SIMD3<Float>? {
            let j = skeleton.joint(joint)
            guard j.isTracked else { return nil }
            let world = anchor.originFromAnchorTransform * j.anchorFromJointTransform
            return SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        }
        // A lost thumb tip (easy to occlude when curling toward the palm) only
        // disables the pinch -- it must NOT drop the whole hand. The aim, the
        // virtual hand and the other gestures all survive without it.
        let thumb = tip(.thumbTip)

        // Hysteresis, loosened so pinches catch reliably (the middle-finger
        // pinch for movement was dropping out): 2.5 cm closes, 4.0 cm opens.
        func pinch(_ tipPos: SIMD3<Float>?, _ pinched: Bool) -> Bool {
            guard let thumb, let tipPos else { return false }
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

        // Trigger-curl fire (aim hand): index flexion toward the palm, thumb-
        // free, so it reads like squeezing a trigger. Straightness = the
        // tip->knuckle chord over the summed bone length (~1 straight, small
        // when curled); hysteresis keeps it from chattering. Independent of the
        // index->thumb pinch -- either gesture fires.
        if let k = tip(.indexFingerKnuckle), let b = tip(.indexFingerIntermediateBase),
           let t = tip(.indexFingerIntermediateTip), let p = index {
            let boneLen = simd_distance(k, b) + simd_distance(b, t) + simd_distance(t, p)
            let straightness = boneLen > 1e-4 ? simd_distance(p, k) / boneLen : 1
            let curlClose = VRSettings.shared.curlSensitivity   // live-tunable
            indexCurled = straightness < (indexCurled ? curlClose + 0.10 : curlClose)
            indexExtended = straightness > Self.gunExtend       // barrel of the finger gun
            indexStraightness = straightness
        } else {
            indexCurled = false
            indexExtended = false
        }

        // Thumb hammer: the ANGLE between the thumb and the index barrel. Splayed
        // up ~90 deg = cocked; dropped alongside the barrel ~25 deg = fired.
        // Angle, not height, so it reads the same in any wrist roll.
        if let ik = tip(.indexFingerKnuckle), let it = index,
           let tk = tip(.thumbKnuckle), let tt = tip(.thumbTip) {
            let barrel = simd_normalize(it - ik)
            let thumbDir = simd_normalize(tt - tk)
            let c = simd_dot(barrel, thumbDir)
            let dropDeg = VRSettings.shared.hammerDropDeg       // live-tunable
            let downCos = cos(dropDeg * .pi / 180)              // fire below this angle
            let upCos = cos((dropDeg + 18) * .pi / 180)         // re-cock above (+18 deg hysteresis)
            thumbHammerDown = c > (thumbHammerDown ? upCos : downCos)
            thumbBarrelDeg = acos(max(-1, min(1, c))) * 180 / .pi
        } else {
            thumbHammerDown = false
            thumbBarrelDeg = 180
        }

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
            // Aim ray = a STABLE base bent by a hand-forward line, so it reads
            // "where the palm points" the same underhand or overhand without
            // winking out when the fingers aren't tracked.
            //
            // Base: the forearm BONE (elbow joint -> wrist joint) tracks in any
            // pose (fist, fire pinch, turned wrist) and is roll-invariant, so
            // both grips aim alike. It alone aims a touch high (trimmed in
            // feedAim). Bend: wrist -> middle knuckle picks up wrist FLEX (point
            // the hand down to aim down), but the knuckle drops out in a
            // fist/fire pinch -- the old sole-source wrist->knuckle ray winked
            // out that way -- so it only BLENDS in when tracked and the ray
            // falls back to the steady forearm when it's gone.
            var base: SIMD3<Float>?
            if let armJ = tip(.forearmArm), let wristJ = tip(.forearmWrist),
               simd_length(wristJ - armJ) > 0.05 {
                base = simd_normalize(wristJ - armJ)
            } else if let arm = tip(.forearmArm), simd_length(w - arm) > 0.05 {
                base = simd_normalize(w - arm)
            }
            // Hand-forward = wrist -> the CENTROID of the knuckles, not a single
            // knuckle. The centroid rides the hand's midline, ~on the forearm's
            // roll axis, so it barely moves as you pronate/supinate -- while a
            // lone off-axis knuckle orbits that axis and swung the aim between
            // palm-down and palm-up. It still tips up/down when you actually
            // point the hand up/down, so wrist-flex aiming survives.
            var handFwd: SIMD3<Float>?
            var kc = SIMD3<Float>(0, 0, 0)
            var kn: Float = 0
            for j in [HandSkeleton.JointName.indexFingerKnuckle, .middleFingerKnuckle,
                      .ringFingerKnuckle, .littleFingerKnuckle] {
                if let k = tip(j) { kc += k; kn += 1 }
            }
            if kn > 0 {
                let centroid = kc / kn
                if simd_length(centroid - w) > 0.03 { handFwd = simd_normalize(centroid - w) }
            }
            if let base, let handFwd {
                let b = VRSettings.shared.aimBlend              // live-tunable
                aimDir = simd_normalize(base * (1 - b) + handFwd * b)
            } else {
                aimDir = base ?? handFwd
            }
            aimBaseDir = base
            aimHandDir = handFwd
            // Low-pass the aim so pinching/curling to fire and per-frame noise
            // don't jiggle the gun. Raw components stay unsmoothed for the debug
            // figure; only the fed/drawn aim is filtered.
            if let d = aimDir {
                let s = VRSettings.shared.aimSmooth             // live-tunable
                aimSmoothed = aimSmoothed.map { simd_normalize($0 + (d - $0) * s) } ?? d
                aimDir = aimSmoothed
            } else {
                aimSmoothed = nil
            }
        } else {
            aimOrigin = nil
            aimDir = nil
            aimBaseDir = nil
            aimHandDir = nil
            aimSmoothed = nil
        }

        buildDebug(tip: tip)
        buildVirtual(tip: tip, isLeft: isLeft)
    }

    /// The stylised virtual hand as DISCONNECTED oval beads: one flattened palm
    /// oval plus an ellipsoid at each finger joint, tapering fat at the knuckle
    /// to small at the tip. No bones, ribbons or forearm — the beads read as a
    /// hand on their own and drop the "weird poly connections" the ribbon build
    /// produced. Corrected-tracking space, triangles, 7 floats each. Colours are
    /// sRGB-ish; the guide fragment linearises them.
    private mutating func buildVirtual(tip: (HandSkeleton.JointName) -> SIMD3<Float>?,
                                       isLeft: Bool) {
        guard let wristPt = tip(.wrist) else { virtualVerts = []; return }
        let corr = TrackingSpace.correction
        let skin = SIMD4<Float>(0.80, 0.60, 0.48, 1)
        var v: [Float] = []
        func c(_ p: SIMD3<Float>) -> SIMD3<Float> {
            let q = corr * SIMD4(p, 1); return SIMD3(q.x, q.y, q.z)
        }
        // A low-poly ellipsoid bead centred at `at`, elongated along `axis` with
        // semi-length `long` and cross radius `rad` (a UV sphere scaled on its
        // pole axis). Corrected on emit.
        func bead(_ at: SIMD3<Float>, _ axis: SIMD3<Float>, _ long: Float, _ rad: Float,
                  _ col: SIMD4<Float>) {
            let zc = simd_length(axis) > 1e-5 ? simd_normalize(axis) : SIMD3<Float>(0, 1, 0)
            var xc = simd_cross(SIMD3<Float>(0, 1, 0), zc)
            xc = simd_length(xc) > 1e-5 ? simd_normalize(xc) : SIMD3(1, 0, 0)
            let yc = simd_normalize(simd_cross(zc, xc))
            let lon = 6, lat = 3
            func pt(_ i: Int, _ j: Int) -> SIMD3<Float> {
                let phi = Float.pi * Float(j) / Float(lat)          // pole (0) to pole (pi)
                let th  = 2 * Float.pi * Float(i) / Float(lon)
                let r = rad * sin(phi)
                return at + xc * (r * cos(th)) + yc * (r * sin(th)) + zc * (long * cos(phi))
            }
            func emit(_ p: SIMD3<Float>) {
                let q = c(p); v += [q.x, q.y, q.z, col.x, col.y, col.z, col.w]
            }
            for j in 0..<lat {
                for i in 0..<lon {
                    let a = pt(i, j), b = pt(i + 1, j)
                    let d = pt(i + 1, j + 1), e = pt(i, j + 1)
                    emit(a); emit(b); emit(d)
                    emit(a); emit(d); emit(e)
                }
            }
        }

        // Palm: one oval from the wrist toward the middle knuckle.
        let knuckles = [HandSkeleton.JointName.indexFingerKnuckle, .middleFingerKnuckle,
                        .ringFingerKnuckle, .littleFingerKnuckle].compactMap { tip($0) }
        if let midK = knuckles.count > 1 ? knuckles[1] : knuckles.first {
            bead((wristPt + midK) * 0.5, midK - wristPt, 0.038, 0.020, skin)
        }

        // Fingers: a bead per joint, fat at the knuckle tapering to the tip,
        // each elongated along the bone toward the next joint.
        let fingers: [[HandSkeleton.JointName]] = [
            [.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
            [.indexFingerKnuckle, .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip],
            [.middleFingerKnuckle, .middleFingerIntermediateBase, .middleFingerIntermediateTip, .middleFingerTip],
            [.ringFingerKnuckle, .ringFingerIntermediateBase, .ringFingerIntermediateTip, .ringFingerTip],
            [.littleFingerKnuckle, .littleFingerIntermediateBase, .littleFingerIntermediateTip, .littleFingerTip],
        ]
        for joints in fingers {
            let pts = joints.map { tip($0) }
            for (i, cur) in pts.enumerated() {
                guard let cur else { continue }
                let t = Float(i) / Float(max(1, joints.count - 1))
                let rad = 0.011 - 0.005 * t              // fat knuckle -> small tip
                var axis = SIMD3<Float>(0, 1, 0)
                if i + 1 < pts.count, let nxt = pts[i + 1] { axis = nxt - cur }
                else if i > 0, let prv = pts[i - 1] { axis = cur - prv }
                bead(cur, axis, rad * 1.5, rad, skin)
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
             fires),
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

/// The viewer's eye position in the SAME corrected-tracking space the debug
/// hands and the turn gauge are drawn in (handViewproj). The render thread
/// publishes it each frame so on-hand HUD can billboard toward the head
/// instead of hanging at a fixed angle that goes edge-on when you look away.
final class ViewerPose: @unchecked Sendable {
    static let shared = ViewerPose()
    private let lock = NSLock()
    private var _eye = SIMD3<Float>(0, 1.2, 0)
    func setEye(_ e: SIMD3<Float>) { lock.lock(); _eye = e; lock.unlock() }
    var eye: SIMD3<Float> { lock.lock(); defer { lock.unlock() }; return _eye }
}

/// Shared debug-figure palette, reused across overlays so every screenshot
/// reads as one document. Colourblind-safe and matched to TriggerScope's chart
/// hues: blue forearm, orange centroid, green blend.
enum DebugColor {
    static let forearm  = SIMD4<Float>(0x39 / 255.0, 0x87 / 255.0, 0xE5 / 255.0, 0.95)
    static let centroid = SIMD4<Float>(0xD9 / 255.0, 0x59 / 255.0, 0x26 / 255.0, 0.95)
    static let blend    = SIMD4<Float>(0x19 / 255.0, 0x9E / 255.0, 0x70 / 255.0, 1.0)
    // Muzzle status bead: fired / aim-lost / armed-ok.
    static let fire     = SIMD4<Float>(1.0, 0.16, 0.58, 1.0)   // hot pink: a shot fired
    static let aimLost  = SIMD4<Float>(0.95, 0.20, 0.20, 0.95) // red: aim tracking dropped
    static let aimOk    = SIMD4<Float>(0.20, 0.85, 0.45, 0.55) // dim green: armed / aim ok
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
