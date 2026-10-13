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
//    off thumb+ring pinch      teleport (aim off-arm at floor, release)  [test]
//    move thumb+pinky hold     crouch
//    move palm-up              open the weapon wheel (that hand selects)
//    gun index pinch           fire (hold for automatic)
//    gun thumb+ring pinch      jump  [test remap]
//    gun horizontal flick      quick turn -- a fast un-pinched sideways whip
//    gun thumb+middle hold+drag  CONTINUOUS turn (Smooth mode): hold out to a
//                              side to keep turning, rate by drag distance
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
    // `flickFloor` fires one snap, then the gesture is disarmed until the
    // hand slows below `flickReset` AND the cooldown lapses -- so the return
    // stroke and a continued sweep can't spin you. The pad rx is HELD for
    // `flickPulse` after a trigger so the engine's tick reliably samples it
    // (a single-frame pulse landed between ticks and got dropped -- that was
    // the "turning doesn't work" bug). Watch the on-hand gauge to calibrate.
    //
    // The trigger floor is FIXED, not a user slider: a low value let ordinary
    // aim motion (~0.8 m/s lateral) cross the bar and fire phantom snaps, so
    // "Flick ease" was removed and the floor pinned high -- only a deliberate
    // hard whip clears it. The adaptive peak term can still raise it further.
    private static let flickFloor: Float = 1.60    // m/s: whip speed to turn
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
    private var turnDebugOffset: Float = 0     // stick hand offset from neutral (debug meter)
    // Auto-balance: each direction triggers at `flickFraction` of that
    // direction's own recent PEAK whip speed, so a strong and a weak direction
    // need equal EFFORT even though one whips faster -- the weak side earns a
    // lower absolute bar on its own. Peaks rise by `flickAttack` toward new
    // highs (one frame's spike can't define the bar) and decay over
    // `flickPeakTau`; the fixed `flickFloor` keeps ordinary aim motion and
    // tracking jitter from ever triggering.
    private static let flickFraction: Float = 0.55
    private static let flickAttack: Float = 0.35
    private static let flickPeakTau: Double = 2.5
    private var flickPeakPos: Float = 1.0          // decaying peak |speed|, body-right
    private var flickPeakNeg: Float = 1.0          // decaying peak |speed|, body-left
    private var flickPeakTime = 0.0
    private var flickArmed = true

    private var flickCooldownUntil = 0.0
    private var flickPulseUntil = 0.0
    private var flickDir: Float = 0

    // A whip must clear the threshold for at least `flickMinFrames` in a row
    // AND carry the wrist `flickMinTravel` metres sideways before it counts --
    // a one-frame velocity spike or an in-place jitter (same direction, no
    // real travel) is rejected. A genuine whip satisfies both in ~1 frame of
    // extra latency. `flickCand*` track the candidate run in progress.
    private static let flickMinFrames = 2
    private static let flickMinTravel: Float = 0.02   // m of lateral wrist travel
    private var flickCandFrames = 0
    private var flickCandDir: Float = 0
    private var flickCandStart: SIMD3<Float>?


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
    private var fireDebugVerts: [Float] = []
    private var lastFireTime = 0.0
    private static let fireFlash = 0.15    // s to hold the flash so it's visible
    private var lastLog = 0.0              // throttle for the input telemetry log
    private var lastPrayerLog = 0.0        // throttle for the summon-sign log

    /// Respawns the console window from inside the game. Mixed immersion lets
    /// the window coexist with the world, so this works without a crown press.
    /// Set by the window on appear.
    nonisolated(unsafe) static var summonConsole: (@MainActor () -> Void)?
    /// The prayer sign: deliberate, and crucially in a pose visionOS does not
    /// reserve, so a shorter dwell is safe. See SummonGesture.
    private var prayerDwell = GestureDwell(dwell: 0.6, cooldown: 3.0)
    /// The original aim-hand palm-up hold, kept as a fallback with its timings
    /// unchanged (the off hand's palm-up owns the wheel, so this is aim-only).
    private var palmUpDwell = GestureDwell(dwell: 1.2, cooldown: 5.0)

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
            OffHandWrist.shared.invalidate()
            GunHand.shared.invalidate()
            EditorHandInput.shared.invalidate()
            FingerTips.shared.invalidate()
            FingerWire.shared.invalidate()
            QC_InputSetTurnHold(0)   // hands standing down: don't strand the hold
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
            teleport(left: left, right: right)
            // Fold every enabled overlay into one published buffer: the
            // wireframe + gauge (full debug), and the figure overlays (aim rays,
            // strobe) which draw over the stylised hand too.
            let wire = HandDebug.shared.enabled
            let turnDbg = HandDebug.shared.turnDebug
            var dbg: [Float] = []
            let fireDbg = HandDebug.shared.fireDebug
            if wire { dbg += left.debugVerts + right.debugVerts }
            // The turn and fire meters follow their OWN toggles only. They used
            // to ride along under `wire` (the hand-wireframe master), which made
            // their individual switches look dead: with the wireframe up, turning
            // a meter off left it on screen because `wire ||` kept folding it in.
            // The wireframe draws the hand bones; the meters are their own thing.
            if turnDbg { dbg += turnGaugeVerts }         // flick gauge / turn meter
            if fireDbg { dbg += fireDebugVerts }         // fire-threshold meter
            if HandDebug.shared.aimRays { dbg += aimRayVerts }
            if HandDebug.shared.strobe { dbg += strobeVerts }
            // The muzzle fire/aim-health "diamond" belongs to the FIRE debug
            // only -- it used to ride along with the strobe/aim-ray overlays and
            // clutter the view with a colour-changing marker on the gun hand.
            if fireDbg { dbg += fireStatusVerts }
            if wire || turnDbg || fireDbg || HandDebug.shared.aimRays || HandDebug.shared.strobe {
                HandDebug.shared.publish(dbg)
            } else {
                // All debug overlays off: publish an empty frame so the last
                // turn/fire meter geometry is cleared. Without this the consumer
                // keeps drawing the final verts forever -- the meters never go
                // away after the toggle is switched off.
                HandDebug.shared.publish([])
            }
            // Off-hand-only option: with a gun in the dominant hand, a bare
            // shotgun with no hand reads oddly, so allow modelling just the off
            // hand (like the PSVR controllers do). Default: on -- a bare gun
            // with no hand on it reads better than two hands clipping the model.
            // In the HUD editor, force BOTH hand models on (the gun is hidden
            // via r_drawviewmodel) so you can see both hands to grab and the
            // weapon doesn't block the tiles. Otherwise honour offHandModelOnly.
            if VRSettings.shared.offHandModelOnly && !HudEditor.Session.renderSnapshot().active {
                let off = VRSettings.shared.rightHanded ? left : right
                VirtualHand.shared.publish(off.virtualVerts)
            } else {
                VirtualHand.shared.publish(left.virtualVerts + right.virtualVerts)
            }
        }
        aggregator.remove(.hands)
        VirtualHand.shared.publish([])   // hands gone: no stand-in to draw
        OffHandWrist.shared.invalidate()
        GunHand.shared.invalidate()
        EditorHandInput.shared.invalidate()
        FingerTips.shared.invalidate()
        FingerWire.shared.invalidate()
        QC_InputSetTeleport(0, 0, 0, 0, 0, 0, 0)   // drop any armed teleport
        QC_InputSetTurnHold(0)   // hands gone: don't strand the hold
        tpRingWas = false
    }

    // MARK: - Gesture synthesis

    private func emit(left: inout HandState, right: inout HandState) {
        var slice = PadAggregator.Slice()

        // UI turn hold (wrist communicator), pushed to the engine-side
        // edge turn (vr_edgeturn in in_null.c) on EVERY call, ahead of the
        // HUD-editor/prayer/wheel early-returns below -- those gates `return`
        // before reaching the turn-hold check further down, and a hold
        // computed only there would strand the engine at 1 if one of them
        // fired while the panel was still up. Computed here once and reused
        // by the turning: block below. See QC_InputSetTurnHold's doc comment.
        let turnHold = VRSettings.shared.wristCommNoTurn && Self.wristCommInUse()
        QC_InputSetTurnHold(turnHold ? 1 : 0)

        // HUD live editor grab input (Task 5): published every update,
        // ahead of every gate/suppression below -- the editor's own grab
        // state machine (HudEditorInput.swift) needs a fresh per-hand
        // pinch+point regardless of whether the wheel is open or a
        // gameplay gesture fired this frame. See EditorHandInput's doc
        // comment for why `point` is generic (not move/aim-labelled) and
        // nil exactly when that hand's pinch geometry isn't tracked.
        EditorHandInput.shared.publish(left: Self.editorSignal(left), right: Self.editorSignal(right))

        // Wrist communicator touch (plan Task 3): each hand's index-tip
        // world position, corrected into tracking space, published every
        // update for the same reason as the publish just above -- the
        // communicator's touch hit-test needs a fresh fingertip read
        // regardless of the editor/wheel/gameplay gates below.
        FingerTips.shared.publish(left: Self.fingertip(left), right: Self.fingertip(right))

        // ...and each hand's index-finger wireframe, for the same consumer
        // and published at the same point for the same reason. The renderer
        // draws it only for the hand actually hovering or pressing a key, so
        // publishing both every update costs nothing on the frames where
        // neither hand is near the panel.
        FingerWire.shared.publish(left: left.indexWireVerts, right: right.indexWireVerts)

        // While the HUD layout editor is open, the hands drive ONLY the grab
        // (published just above). Every gameplay gesture -- fire, move, turn,
        // jump -- is suppressed, exactly as under an open weapon wheel, so
        // reaching across with the gun hand to adjust an off-wrist tile can't
        // also fire the gun or walk the player off its anchor. The wrist
        // positions the grid rides are still published in `wheel()`, which runs
        // regardless. renderSnapshot() is a lock-protected any-thread read.
        if HudEditor.Session.renderSnapshot().active {
            aggregator.update(.hands, slice)   // zeroed
            turnGaugeVerts = []
            return
        }

        // Handedness: the OFF (non-gun) hand moves, jumps, crouches; the
        // DOMINANT (gun) hand aims and fires.
        let rightHanded = VRSettings.shared.rightHanded
        let move = rightHanded ? left : right
        let aim = rightHanded ? right : left

        // M6: feed the dominant hand's aim ray to the engine every update,
        // even while the wheel is open, so the gun keeps tracking the hand.
        feedAim(aim)
        aimRayVerts = buildAimRays(aim)

        // Console summon. Runs before the wheel gate so it works regardless of
        // what the off hand is doing.
        let summonNow = CACurrentMediaTime()
        let summonMode = VRSettings.shared.summonGesture
        let prayerHeld = PrayerPose.matches(left: left.palmPose, right: right.palmPose)
        logPrayer(left: left, right: right, held: prayerHeld, now: summonNow)
        let summonFired: Bool
        switch summonMode {
        case .prayer:
            summonFired = prayerDwell.update(active: prayerHeld, now: summonNow)
            _ = palmUpDwell.update(active: false, now: summonNow)
        case .palmUp:
            summonFired = palmUpDwell.update(active: aim.palmUp, now: summonNow)
            _ = prayerDwell.update(active: false, now: summonNow)
        }
        if summonFired {
            print("[summon] \(summonMode == .prayer ? "prayer sign" : "palm-up hold") recognised")
            if let summon = Self.summonConsole { Task { @MainActor in summon() } }
        }

        // Holding the sign puts each thumb alongside its own index finger,
        // which the pinch state machine reads as pinched -- so without this you
        // would fire and walk backward while summoning. Suppress everything
        // while it's held, the way the wheel does. Palm-up keeps its original
        // behaviour (no suppression): changing that fallback isn't this
        // gesture's business.
        if summonMode == .prayer, prayerHeld {
            aggregator.update(.hands, slice)   // zeroed
            turnGaugeVerts = []
            return
        }

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

        // Crouch: off-hand thumb+pinky (held).
        if move.pinkyPinched { slice.buttons |= UInt32(QC_PAD_LTHUMB) }  // +movedown
        // TEST remap: JUMP is now the GUN-hand ring pinch (thumb+ring), and the
        // OFF-hand ring pinch drives teleport (see teleport()). Ring is free on
        // the gun hand -- fire is index pinch/curl/hammer, not ring.
        if aim.ringPinched { slice.buttons |= UInt32(QC_PAD_A) }         // +jump

        let now = CACurrentMediaTime()

        // Fire: the selected gesture only -- pinch, curl, or the finger-gun
        // hammer -- so the aim-hand gestures can't collide.
        switch VRSettings.shared.fireMode {
        case .pinch:
            if aim.indexPinched { slice.rt = 1 }
        case .curl:
            if aim.indexCurled { slice.rt = 1 }
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
        fireDebugVerts = buildFireDebug(aim, now: now)

        // Two ways to turn, both on the gun hand:
        //  - QUICK WHIP (flick): a fast sideways wrist whip fires ONE snap (or a
        //    brief smooth nudge). Good for a glance.
        //  - HELD SCROLL (thumb+middle pinch-drag): pinch and hold the hand out
        //    to a side and it turns CONTINUOUSLY, rate proportional to how far
        //    you've dragged from where you pinched. With Smooth turning on this
        //    is a controllerless "right stick" -- hold to keep turning, release
        //    to stop. (Under Snap it just fires the one snap, like the whip.)
        let dt = Float(max(0, min(0.1, now - lastTurnTime)))
        lastTurnTime = now
        _ = dt   // retained for the (now unused) accumulate path's signature
        turning: do {
            turnIntent = 0; stickNeutral = nil; clutchAnchor = nil

            // TURNING ONLY is held while the wrist communicator is in use.
            // Reaching across with the GUN hand to press a key is a sideways
            // sweep of exactly the hand the whip and the pinch-drag watch, so
            // every press came with a snap turn nobody asked for -- and once
            // the view has turned, the panel has moved too.
            //
            // Movement, jump, crouch and fire are deliberately NOT suppressed
            // (unlike the wheel/editor/prayer gates above, which zero the
            // whole slice and return): the communicator is a six-key panel
            // you glance at, not a modal menu, and being unable to back away
            // while reading it would be worse than the turn. The slice built
            // above is left exactly as it is; only the turn synthesis below
            // is skipped, and the gauge cleared the way the other
            // suppressions clear it.
            //
            // The gate is the SAME condition the touch loop fires on -- a
            // published side that is enabled and revealed past
            // `WristComm.fireRevealFloor` -- so turning is held exactly while
            // a key could actually be pressed, never while the panel is
            // merely fading. A lock-snapshot read, the same class as the
            // publishers this method already touches.
            //
            // NB: this covers every turn path HandInput drives directly. The
            // aim-hand edge turn is engine-side (`vr_edgeturn` in in_null.c,
            // off the aim yaw the engine reads for itself) and the
            // wheel/editor gates above can't reach across to suppress it --
            // so `turnHold`, computed above from this same condition, is
            // pushed to the engine via QC_InputSetTurnHold every update and
            // gates that path from in_null.c's side instead.
            if turnHold {
                turnGaugeVerts = []
                // Drop any candidate whip run as well: a reach that began as
                // a plausible whip must not fire the instant the panel fades.
                flickCandFrames = 0
                flickCandStart = nil
                break turning
            }

            // The held pinch-drag is checked first (it's the deliberate one); if
            // it isn't driving, a quick sideways whip fires.
            var turnedByPinch = false
            if let drag = aim.middleDrag {
                let d = basis * drag
                let dz: Float = 0.02, full: Float = 0.12   // deadzone .. full-rate drag (m)
                if abs(d.x) > dz {
                    let v = min(1, (abs(d.x) - dz) / (full - dz))
                    slice.rx = v * (d.x > 0 ? 1 : -1)      // proportional, continuous
                    turnedByPinch = true
                }
            }

            // (Continuous "edge turn" is engine-side now -- IN_Teleport's
            // neighbour in in_null.c reads the gun AIM yaw: hold the aim past a
            // deadzone to a side and the body follows, Metroid Prime Hunters
            // style. Nothing to feed from here.)
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
            let floor = Self.flickFloor
            let posThreshold = max(floor, flickPeakPos * Self.flickFraction)
            let negThreshold = max(floor, flickPeakNeg * Self.flickFraction)
            let effThreshold = speed >= 0 ? posThreshold : negThreshold
            var firing = false
            if !turnedByPinch {
                if flickArmed, now >= flickCooldownUntil, mag > effThreshold {
                    // Over threshold: open or extend a candidate whip run. A
                    // direction flip restarts it. Fire only once the run has
                    // lasted flickMinFrames AND the wrist has actually travelled
                    // flickMinTravel sideways from where the run began -- so a
                    // single spiky frame, or a fast wobble that doesn't go
                    // anywhere, never trips a snap.
                    let dir: Float = speed > 0 ? 1 : -1
                    if flickCandFrames == 0 || flickCandDir != dir {
                        flickCandDir = dir
                        flickCandStart = aim.wrist
                        flickCandFrames = 1
                    } else {
                        flickCandFrames += 1
                    }
                    var travel: Float = 0
                    if let start = flickCandStart, let w = aim.wrist {
                        travel = abs((basis * (w - start)).x)
                    }
                    if flickCandFrames >= Self.flickMinFrames, travel >= Self.flickMinTravel {
                        flickDir = dir
                        flickArmed = false
                        flickSettledSince = 0
                        flickPulseUntil = now + Self.flickPulse
                        flickCooldownUntil = now + Self.flickCooldown
                        // Why this flick fired, for diagnosing phantom snaps:
                        // a deliberate whip reads as a high speed well over the
                        // threshold; an aim sweep crossing a decayed threshold
                        // reads as a modest speed just over a low thr.
                        if VRSettings.shared.inputLog {
                            HandDebug.shared.log(String(format:
                                "[flick] FIRED dir=%+.0f speed=%.2f thr=%.2f peak=%.2f/%.2f travel=%.3f frames=%d floor=%.2f",
                                dir, speed, effThreshold, flickPeakPos, flickPeakNeg,
                                travel, flickCandFrames, floor))
                        }
                        flickCandFrames = 0
                        flickCandStart = nil
                    }
                } else {
                    // Not over threshold this frame: the candidate run is
                    // broken (a real whip stays over threshold for its whole
                    // stroke), and the settle/re-arm bookkeeping resumes.
                    flickCandFrames = 0
                    flickCandStart = nil
                    if mag < Self.flickReset {
                        if flickSettledSince == 0 { flickSettledSince = now }
                        if now - flickSettledSince >= Self.flickDwell { flickArmed = true }
                    } else {
                        flickSettledSince = 0
                    }
                }
                firing = now < flickPulseUntil
                if firing { slice.rx = flickDir }
            }
            let refSpeed = max(posThreshold, negThreshold, 0.5)
            buildTurnGauge(wrist: aim.wrist, forearm: aim.aimBaseDir, speed: speed,
                           posThreshold: posThreshold, negThreshold: negThreshold, refSpeed: refSpeed,
                           armed: flickArmed, firing: firing)

        }

        // Input telemetry: the exact aim + turn signals (final slice), so a miss
        // can be read off numbers (paste back) instead of guessed. ~7 Hz.
        if VRSettings.shared.inputLog, now - lastLog > 0.15 {
            lastLog = now
            let mode = ["pinch", "curl"][VRSettings.shared.fireMode.rawValue]
            let tstyle = ["stick", "clutch", "flick"][VRSettings.shared.turnStyle.rawValue]
            HandDebug.shared.log("[inputlog] fire=\(mode)"
                + " straight=\(String(format: "%.2f", aim.indexStraightness))"
                + " curl=\(aim.indexCurled ? 1 : 0) ext=\(aim.indexExtended ? 1 : 0)"
                + " thumb=\(Int(aim.thumbBarrelDeg))° ham=\(aim.thumbHammerDown ? 1 : 0)"
                + " aim=\(aim.aimDir != nil ? 1 : 0) shot=\(slice.rt == 1 ? 1 : 0)"
                + " | turn=\(tstyle) snap=\(String(format: "%.2f", slice.rx))"
                + " spd=\(String(format: "%.2f", aim.wristVel.map { (basis * $0).x } ?? 0))")
        }

        aggregator.update(.hands, slice)
    }


    /// True while the wrist communicator is actually usable: any published
    /// side enabled AND revealed at or past `WristComm.fireRevealFloor`, the
    /// very floor the touch loop refuses to fire below. Reading the published
    /// `WristCommGeometry` rather than the reveal state itself keeps one
    /// definition of "the panel is up" shared by the draw, the touch gate and
    /// this hold -- a second opinion here would hold turning on frames where
    /// no key could be pressed, or free it on frames where one could.
    private static func wristCommInUse() -> Bool {
        WristCommGeometry.shared.snapshot().sides.contains {
            $0.enabled && $0.opacity >= WristComm.fireRevealFloor
        }
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

    /// Turn-trigger meter for the stick/clutch styles: a billboarded bar above
    /// the driving wrist. The centre-out fill shows progress toward the next
    /// snap (white flash when it fires); the base goes green when engaged/
    /// accumulating, red when idle. For the stick it also draws the deadzone
    /// band and a marker for where the hand sits, so you can see the exact
    /// moment you cross out of the deadzone into a turn.
    private func buildTurnDebug(wrist: SIMD3<Float>?, forearm: SIMD3<Float>?, engaged: Bool,
                                offset: Float, deadzone: Float, now: Double) -> [Float] {
        guard HandDebug.shared.turnDebug || HandDebug.shared.enabled,
              let dock = hudDock(wrist: wrist, forearm: forearm) else { return [] }
        let halfW: Float = 0.09
        let fullScale: Float = 0.15               // metres of offset mapped to the bar edge
        var v: [Float] = []
        func quad(_ cx: Float, _ hw: Float, _ hh: Float, _ col: SIMD4<Float>) {
            dockQuad(&v, dock, cx, 0, hw, hh, col)
        }
        let firing = now < snapPulseUntil
        // Base track: green when engaged/accumulating, red when idle.
        quad(0, halfW, 0.006, engaged ? SIMD4(0.10, 0.35, 0.16, 0.80) : SIMD4(0.30, 0.10, 0.10, 0.70))
        if deadzone > 0 {                          // stick: deadzone band + hand marker
            quad(0, halfW * min(1, deadzone / fullScale), 0.010, SIMD4(0.55, 0.50, 0.20, 0.35))
            let oFrac = max(-1, min(1, offset / fullScale))
            quad(oFrac * halfW, 0.006, 0.026, SIMD4(0.90, 0.92, 1.0, 0.95))
        }
        let tick = SIMD4<Float>(1.0, 0.55, 0.20, 0.95)
        quad(-halfW, 0.004, 0.022, tick)           // snap thresholds
        quad( halfW, 0.004, 0.022, tick)
        quad(0, 0.003, 0.014, tick)                // centre notch
        // Progress-to-snap fill: grows from centre toward a tick.
        let frac = max(-1, min(1, turnIntent / Self.snapStep))
        quad(frac * halfW * 0.5, abs(frac) * halfW * 0.5, 0.016,
             firing ? SIMD4(1, 1, 1, 1) : SIMD4(0.25, 1.0, 0.45, 0.95))
        return v
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
    private func buildTurnGauge(wrist: SIMD3<Float>?, forearm: SIMD3<Float>?, speed: Float,
                                posThreshold: Float, negThreshold: Float, refSpeed: Float,
                                armed: Bool, firing: Bool) {
        guard HandDebug.shared.enabled || HandDebug.shared.turnDebug,
              let dock = hudDock(wrist: wrist, forearm: forearm) else { turnGaugeVerts = []; return }
        var v: [Float] = []
        func quad(_ cx: Float, _ cy: Float, _ hw: Float, _ hh: Float, _ col: SIMD4<Float>) {
            dockQuad(&v, dock, cx, cy, hw, hh, col)
        }
        let halfW: Float = 0.09
        func fx(_ frac: Float) -> Float { max(-1.2, min(1.2, frac)) * halfW }
        let track  = SIMD4<Float>(0.10, 0.30, 0.14, 0.70)
        let tick   = SIMD4<Float>(1.0, 0.55, 0.20, 0.95)
        let armedC = SIMD4<Float>(0.25, 1.0, 0.45, 0.98)
        let coolC  = SIMD4<Float>(0.90, 0.80, 0.20, 0.90)
        let fireC  = SIMD4<Float>(1.0, 1.0, 1.0, 1.0)
        quad(0, 0, halfW, 0.008, track)                                 // track
        quad(fx( posThreshold / refSpeed), 0, 0.004, 0.024, tick)       // body-right trigger
        quad(fx(-negThreshold / refSpeed), 0, 0.004, 0.024, tick)       // body-left trigger
        quad(0, 0, 0.003, 0.016, track)                                 // centre notch
        quad(fx(speed / refSpeed), 0, 0.006, 0.030,                     // moving marker
             firing ? fireC : (armed ? armedC : coolC))
        turnGaugeVerts = v
    }

    /// The adjustable on-arm dock every debug meter renders into: anchored at
    /// the wrist, oriented by the forearm, offset + tilted by the live HUD
    /// params, then blended toward eye-facing by `hudFaceMe`. Returns the flat
    /// panel basis (origin, unit right, unit up) and a scale, or nil if the
    /// wrist isn't tracked.
    private func hudDock(wrist: SIMD3<Float>?, forearm: SIMD3<Float>?)
        -> (origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, scale: Float)? {
        guard let wrist else { return nil }
        let s = VRSettings.shared
        let corr = TrackingSpace.correction
        let w4 = corr * SIMD4(wrist, 1)
        var origin = SIMD3(w4.x, w4.y, w4.z)
        // Forearm frame (fallback: face -Z). fwd along the arm, right across it.
        var fwd = SIMD3<Float>(0, 0, -1)
        if let forearm {
            let f4 = corr * SIMD4(forearm, 0)
            let f = SIMD3(f4.x, f4.y, f4.z)
            if simd_length(f) > 1e-4 { fwd = simd_normalize(f) }
        }
        var armRight = simd_cross(SIMD3<Float>(0, 1, 0), fwd)
        armRight = simd_length(armRight) > 1e-4 ? simd_normalize(armRight) : SIMD3(1, 0, 0)
        let armUp = simd_normalize(simd_cross(fwd, armRight))
        origin += armRight * s.hudSide + armUp * s.hudUp + fwd * s.hudForward
        // Facing: blend the bracer normal (armUp) toward the eye direction.
        let f = max(0, min(1, s.hudFaceMe))
        let toEye = simd_normalize(ViewerPose.shared.eye - origin)
        var normal = armUp * (1 - f) + toEye * f
        normal = simd_length(normal) > 1e-4 ? simd_normalize(normal) : armUp
        // Panel up reference: along the arm when locked, world-up when facing.
        let refUp = simd_normalize(fwd * (1 - f) + SIMD3<Float>(0, 1, 0) * f)
        var right = simd_cross(refUp, normal)
        right = simd_length(right) > 1e-4 ? simd_normalize(right) : armRight
        var up = simd_normalize(simd_cross(normal, right))
        // Transform: pan (yaw) about up, then pitch about right, then roll.
        let yw = s.hudYaw * .pi / 180
        let right0 = simd_normalize(right * cos(yw) - normal * sin(yw))
        normal = simd_normalize(normal * cos(yw) + right * sin(yw))
        right = right0
        let p = s.hudPitch * .pi / 180
        let up1 = simd_normalize(up * cos(p) + normal * sin(p))
        normal = simd_normalize(normal * cos(p) - up * sin(p))
        up = up1
        let r = s.hudRoll * .pi / 180
        let right1 = simd_normalize(right * cos(r) + up * sin(r))
        up = simd_normalize(up * cos(r) - right * sin(r))
        right = right1
        return (origin, right, up, max(0.2, s.hudScale))
    }

    /// Emit one quad into the dock's flat panel: centre (cx, cy) and half-size
    /// (hw, hh) are panel-space metres, scaled by the dock scale.
    private func dockQuad(_ v: inout [Float],
                          _ dock: (origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>, scale: Float),
                          _ cx: Float, _ cy: Float, _ hw: Float, _ hh: Float, _ col: SIMD4<Float>) {
        let s = dock.scale
        let c = dock.origin + dock.right * (cx * s) + dock.up * (cy * s)
        let a = c - dock.right * (hw * s) - dock.up * (hh * s)
        let b = c + dock.right * (hw * s) - dock.up * (hh * s)
        let d = c + dock.right * (hw * s) + dock.up * (hh * s)
        let e = c - dock.right * (hw * s) + dock.up * (hh * s)
        for q in [a, b, d, a, d, e] { v += [q.x, q.y, q.z, col.x, col.y, col.z, col.w] }
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

    /// Fire-threshold meter for the active fire mode: a billboarded bar above
    /// the aim wrist showing the live signal against its trigger threshold, so
    /// dragging Curl-ease / Hammer-angle is visible. Left = the "fire zone"
    /// (shaded); the tick is the (live-tunable) threshold and MOVES as you drag
    /// the slider; the marker is your current signal -- it goes green when the
    /// gesture registers and flashes white on an actual shot. For hammer the
    /// base turns red when the gun pose (extended index) isn't held.
    private func buildFireDebug(_ aim: HandState, now: Double) -> [Float] {
        guard HandDebug.shared.fireDebug || HandDebug.shared.enabled else { return [] }
        var value01: Float = 0, thresh01: Float = 0, armed = true
        switch VRSettings.shared.fireMode {
        case .pinch:
            let full: Float = 0.08                         // metres of tip gap at bar edge
            value01 = min(1, aim.indexPinchDist / full)
            thresh01 = 0.025 / full                        // pinch "close" distance
        case .curl:
            value01 = min(1, max(0, aim.indexStraightness))
            thresh01 = VRSettings.shared.curlSensitivity
        }
        guard let dock = hudDock(wrist: aim.wrist, forearm: aim.aimBaseDir) else { return [] }
        let halfW: Float = 0.09
        let row: Float = 0.07                              // stacked above the turn meter
        func toX(_ f: Float) -> Float { (min(1, max(0, f)) * 2 - 1) * halfW }
        var v: [Float] = []
        func quad(_ cx: Float, _ hw: Float, _ hh: Float, _ col: SIMD4<Float>) {
            dockQuad(&v, dock, cx, row, hw, hh, col)
        }
        // Base: red when the pose gate isn't met (hammer without the gun pose).
        quad(0, halfW, 0.006, armed ? SIMD4(0.12, 0.12, 0.14, 0.75) : SIMD4(0.30, 0.10, 0.10, 0.75))
        // Fire zone: the low side below the threshold that triggers.
        let zoneL = -halfW, zoneR = toX(thresh01)
        quad((zoneL + zoneR) / 2, max(0, (zoneR - zoneL) / 2), 0.011, SIMD4(0.15, 0.45, 0.20, 0.35))
        quad(toX(thresh01), 0.004, 0.026, SIMD4(1.0, 0.55, 0.20, 0.95))   // threshold (moves w/ slider)
        let firing = now - lastFireTime < Self.fireFlash
        let markCol: SIMD4<Float> = firing ? SIMD4(1, 1, 1, 1)
            : (aim.fires ? SIMD4(0.25, 1.0, 0.45, 0.98) : SIMD4(0.90, 0.92, 1.0, 0.95))
        quad(toX(value01), 0.006, 0.030, markCol)                          // live signal
        return v
    }

    /// Motion strobe: the aim ray sampled over the last ~0.7 s, older samples
    /// fading, so one still frame conveys the gesture's motion.
    private func buildStrobe(now: Double) -> [Float] {
        var v: [Float] = []
        let span = Float(Self.strobeInterval * Double(Self.strobeCount))
        // At the AIM POINT: a dot projected out along each sampled ray (a fixed
        // throw, since the hit distance is engine-side), so the trail shows
        // where you were aiming, not a stub at the hand.
        let dist: Float = 3.0
        for s in strobeSamples {
            let alpha = max(0, 1 - Float(now - s.t) / span)
            var col = DebugColor.blend
            col.w = 0.12 + 0.78 * alpha
            octa(&v, s.o + s.d * dist, 0.02 + 0.02 * alpha, col)
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
    private var tpRingWas = false

    /// Point-and-blink teleport off the OFF hand (non-gun): aim the forearm at
    /// a floor and hold an index pinch to arm -- the engine shows the landing
    /// ring and jumps you there on release. Fed in the SAME body-frame ray form
    /// as feedAim, so IN_Teleport reconstructs the world ray exactly as it does
    /// the aim. The forearm ray is used (not the fingers): it survives the pinch
    /// that arms the teleport, where a finger ray would collapse.
    private func teleport(left: HandState, right: HandState) {
        // No locomotion while the HUD editor is open: an off-hand ring pinch is
        // a grab/footprint gesture there, not a teleport commit. Drop any armed
        // teleport and reset the edge detector so leaving the editor can't fire
        // a stale blink the next frame.
        if HudEditor.Session.renderSnapshot().active {
            if tpRingWas { QC_InputSetTeleport(0, 0, 0, 0, 0, 0, 0) }
            tpRingWas = false
            return
        }
        // The GUN reticle aims the teleport (engine side), so this ONLY needs
        // to detect the off-hand ring pinch and fire the commit. It must NOT
        // gate on the off-hand forearm ray -- that gate (a leftover from when
        // the off hand aimed) was returning early and swallowing the commit
        // whenever the off forearm wasn't cleanly tracked. The off-hand aim ray
        // is still computed in ingest, reserved for the PSVR dual-wield.
        let off = VRSettings.shared.rightHanded ? left : right
        let pinched = !WheelState.shared.isOpen && off.ringPinched
        // Commit on the RELEASE of the ring pinch (tap, then let go to blink),
        // so you can hold and line up the gun reticle, then release to go.
        let commit = !pinched && tpRingWas
        tpRingWas = pinched
        QC_InputSetTeleport(0, commit ? 1 : 0, 0, 0, 0, 0, 0)
    }

    private func feedAim(_ hand: HandState) {
        guard let o = hand.aimOrigin, let d = hand.aimDir else {
            TrackRecorder.shared.feedAim(valid: false, origin: .zero, yaw: 0, pitch: 0)
            return
        }
        let corr = TrackingSpace.correction
        let op = corr * SIMD4(o, 1)
        let dp = corr * SIMD4(d, 0)          // direction: rotation only (w = 0)
        let dir = simd_normalize(SIMD3(dp.x, dp.y, dp.z))
        let aimYaw = atan2(-dir.x, -dir.z) * 180 / .pi
        let horiz = (dir.x * dir.x + dir.z * dir.z).squareRoot()
        // No trim here. The resting-forearm bias is corrected ONCE, engine-side,
        // by vr_aimpitch. A hidden constant here plus a visible slider there
        // meant two knobs for one quantity, and a number you could not see.
        let aimPitch = -atan2(dir.y, horiz) * 180 / .pi
        let s = WheelState.shared.currentWorldScale
        TrackRecorder.shared.feedAim(valid: true, origin: SIMD3(-op.z / s, op.x / s, op.y / s),
                                     yaw: aimYaw, pitch: aimPitch)
    }

    /// Every threshold the prayer sign tests, against its limit, so the sign can
    /// be calibrated on device from the log instead of by argument -- which is
    /// how palmSign and the curl thresholds got settled. Logged BEFORE the
    /// suppression return, because the frames where the sign is held are the
    /// only interesting ones.
    private func logPrayer(left: HandState, right: HandState, held: Bool, now: Double) {
        // Behind the Comfort > Debug "Input telemetry log" toggle, which
        // survives the console window closing, so the sign can still be
        // calibrated with no window on screen. Armed off the WRISTS rather than
        // the palms: palms together occlude each other, so a missing palm plane
        // is itself a finding and gating on it would hide the interesting case.
        guard VRSettings.shared.inputLog, now - lastPrayerLog > 0.25 else { return }
        var wristGap = Float.infinity
        if let lw = left.wrist, let rw = right.wrist { wristGap = simd_distance(lw, rw) }
        guard wristGap < 0.35 else { return }
        lastPrayerLog = now
        func f(_ v: Float) -> String { String(format: "%.2f", v) }

        guard let l = left.palmPose, let r = right.palmPose else {
            print("[summon] hands close (wrists \(f(wristGap))m) but no palm plane:"
                + " L=\(left.palmPose != nil ? "ok" : "MISSING") [\(left.jointDebug)]"
                + " R=\(right.palmPose != nil ? "ok" : "MISSING") [\(right.jointDebug)]")
            return
        }
        let d = r.center - l.center
        let gap = simd_length(d)
        let toward = gap > 0 ? simd_dot(l.normal, d / gap) : 0
        let face = simd_dot(l.normal, r.normal)
        // Each condition with a pass/fail mark, so the blocking one is obvious
        // without doing the comparison by eye.
        func mark(_ ok: Bool) -> String { ok ? "ok" : "NO" }
        print("[summon] prayer=\(held ? 1 : 0)"
            + " gap=\(f(gap))<=\(PrayerPose.gapMax) \(mark(gap <= PrayerPose.gapMax))"
            + " | face=\(f(face))<=\(PrayerPose.facingDotMax) \(mark(face <= PrayerPose.facingDotMax))"
            + " | toward=\(f(toward))>0 \(mark(toward > 0))"
            + " | up=\(f(l.forward.y))/\(f(r.forward.y))>=\(PrayerPose.fingersUpMin) "
            + mark(l.forward.y >= PrayerPose.fingersUpMin && r.forward.y >= PrayerPose.fingersUpMin))
    }

    /// Weapon wheel. The OFF-hand palm gesture always holds the ring open; the
    /// ring then LOCKS in place and a wrist is the selector -- move the whole
    /// hand toward a weapon to highlight it and rest there ~0.28s to swap to it
    /// live; flip the palm back to close. No finger pointing (it was too fiddly
    /// on a ring anchored to a wrist); every other gesture stays suppressed
    /// while it's open.
    ///
    /// Which wrist SELECTS is a setting (VRSettings.wheelSelectHand):
    /// - offHand (default): the summoning off hand also selects -- one-handed,
    ///   today's behaviour.
    /// - dominant: the off hand holds the ring open while the GUN hand reaches
    ///   to select -- two-handed, matching the Sense-controller feel. The gun
    ///   visibly follows the reaching hand mid-select (firing is already
    ///   suppressed while the wheel is open), and the off-hand palm must stay up
    ///   throughout. Handedness-agnostic via rightHanded.
    private func wheel(left: HandState, right: HandState) {
        let rightHanded = VRSettings.shared.rightHanded
        let offHand = rightHanded ? left : right   // off hand holds AND anchors
        let gunHand = rightHanded ? right : left

        // Publish the off-hand wrist for the wrist-mode HUD panel, every
        // frame the wrist is tracked -- NOT gated on palmUp like the wheel's
        // own anchor below, since the HUD should ride the wrist whenever
        // it's visible, not only while the wheel gesture is held.
        if let wrist = offHand.wrist {
            let p = TrackingSpace.correction * SIMD4(wrist, 1)
            OffHandWrist.shared.publish(position: SIMD3(p.x, p.y, p.z), valid: true)
        } else {
            OffHandWrist.shared.invalidate()
        }

        // Mirror for the GUN hand, so the gun-anchored HUD tile has a
        // hands-only source too (see `GunHand`'s doc comment).
        if let wrist = gunHand.wrist {
            let p = TrackingSpace.correction * SIMD4(wrist, 1)
            GunHand.shared.publish(position: SIMD3(p.x, p.y, p.z), valid: true)
        } else {
            GunHand.shared.invalidate()
        }

        // The weapon wheel is suppressed while the HUD layout editor is open:
        // the Face/Health tiles live ON the off-hand wrist, so presenting that
        // wrist to grab a tile IS the palm-up gesture that opens the wheel --
        // the ring then renders over the grid and slows time right where you're
        // arranging. Standing the wheel down in edit mode keeps the forearm
        // clear for grabbing. renderSnapshot() is a lock-protected any-thread read.
        let editing = HudEditor.Session.renderSnapshot().active
        WheelState.shared.setHold(offHand.palmUp && !editing, source: .hands)
        guard offHand.palmUp, !editing else { return }

        let correction = TrackingSpace.correction
        // The ring is ALWAYS anchored to the off hand -- it stays locked to that
        // hand (flipped for left-handers) in both selection modes. The earlier
        // version fed the gun wrist here, which dragged the ring to the gun hand
        // (toward the body centre); that was the bug.
        if let wrist = offHand.wrist {
            let p = correction * SIMD4(wrist, 1)
            WheelState.shared.setAnchor(trackingPosition: SIMD3(p.x, p.y, p.z))
        }

        // "Other hand": the gun hand POINTS to select, exactly like the Sense
        // controllers (setPointer) -- the ring does not move. Default (offHand)
        // keeps the off-hand wrist-travel selection setAnchor just derived.
        if VRSettings.shared.wheelSelectHand == .dominant,
           let o0 = gunHand.aimOrigin, let d0 = gunHand.aimDir {
            let oc = correction * SIMD4(o0, 1)
            let dc = correction * SIMD4(d0, 0)
            let dir = SIMD3(dc.x, dc.y, dc.z)
            if simd_length(dir) > 1e-5 {
                WheelState.shared.setPointer(trackingOrigin: SIMD3(oc.x, oc.y, oc.z),
                                             direction: simd_normalize(dir))
            }
        }
    }

    /// This hand's pinch point for the HUD editor, in corrected tracking
    /// space -- the midpoint of thumb and index tips, same convention as
    /// every other tracked-joint consumer here (`TrackingSpace.correction`).
    /// `nil` when either tip isn't tracked, which is deliberately also true
    /// whenever `indexPinched` already reads false for the same reason (a
    /// lost thumb disables the pinch) -- there is no case where `pinched`
    /// is true but `point` is nil.
    private static func editorSignal(_ hand: HandState) -> EditorHandSignal {
        guard let thumb = hand.thumbTipPos, let index = hand.indexTipPos else {
            return EditorHandSignal(pinched: false, point: nil)
        }
        let mid = (thumb + index) * 0.5
        let corr = TrackingSpace.correction * SIMD4(mid, 1)
        return EditorHandSignal(pinched: hand.indexPinched, point: SIMD3(corr.x, corr.y, corr.z))
    }

    /// This hand's index-tip world position, corrected into tracking space,
    /// for the wrist communicator's touch hit-test -- `nil` when the tip
    /// isn't tracked.
    private static func fingertip(_ hand: HandState) -> SIMD3<Float>? {
        guard let index = hand.indexTipPos else { return nil }
        let corr = TrackingSpace.correction * SIMD4(index, 1)
        return SIMD3(corr.x, corr.y, corr.z)
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
    var indexPinchDist: Float = 0.08   // log/meter: index-to-thumb distance (m)
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
    /// Which probed ARKit joints are untracked, filled only while the palm
    /// plane is missing. Diagnostic, printed by logPrayer.
    var jointDebug = ""

    /// The palm PLANE (centroid, outward normal, finger direction), room frame.
    /// palmUp only answers "does the palm face the sky"; the prayer sign needs
    /// to compare the two palms to each other. nil when the knuckles that
    /// define the plane aren't tracked.
    var palmPose: PalmPose?
    var aimOrigin: SIMD3<Float>?      // wrist, room frame
    var aimDir: SIMD3<Float>?         // blended aim, room frame
    var aimBaseDir: SIMD3<Float>?     // raw forearm bone, unsmoothed (debug figure)
    // Raw pinch geometry, room frame -- retained (not just local to ingest)
    // so emit() can publish this hand's pinch point for the HUD live
    // editor's grab input (EditorHandInput, HudEditorInput.swift). nil
    // exactly when that tip isn't tracked -- the editor's "hand lost"
    // signal (plan Review Focus #1) reads straight off this, same as every
    // other consumer of a tracked joint here.
    var indexTipPos: SIMD3<Float>?
    var thumbTipPos: SIMD3<Float>?
    // Teleport pointing ray (room frame): wrist -> middle knuckle, which DOES
    // follow wrist flex, so pointing the hand down aims at the floor. Uses the
    // inferred pose so it's stable through the ring pinch that arms teleport.
    // Deliberately NOT the forearm aim ray, which ignores the hand on purpose.
    var pointOrigin: SIMD3<Float>?
    var pointDir: SIMD3<Float>?

    /// Coloured finger bones for the debug overlay, corrected-tracking
    /// space, 7 floats/vertex (xyz + rgba), line list. Built in ingest.
    var debugVerts: [Float] = []

    /// The stylised solid hand (forearm + palm + fingers), corrected-tracking
    /// space, 7 floats/vertex (xyz + rgba), triangle list. Built every ingest,
    /// drawn by the render thread at opacity 1 - phase. See VirtualHand.
    var virtualVerts: [Float] = []

    /// The INDEX FINGER alone as a wireframe, corrected-tracking space,
    /// 7 floats/vertex (xyz + rgba), triangle list. Built every ingest and
    /// published through `FingerWire`; drawn only while this hand is working
    /// the wrist communicator. See `buildIndexWire`.
    var indexWireVerts: [Float] = []

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
    private var prevWristVel: SIMD3<Float>?	// low-pass state for wristVel
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
        // The INFERRED joint pose (ignores isTracked): ARKit still reports a
        // transform for an occluded joint, which keeps every finger drawn
        // through a fist. Used for the DRAWN mesh and the teleport POINTING ray
        // only. GESTURES stay on strict `tip`: the finger-gun/hammer pose keeps
        // its joints visible anyway, and inferred angles proved less reliable
        // than observed ones (the hammer never crossed its threshold on them).
        func vtip(_ joint: HandSkeleton.JointName) -> SIMD3<Float>? {
            let world = anchor.originFromAnchorTransform
                * skeleton.joint(joint).anchorFromJointTransform
            return SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        }
        // A lost thumb tip (easy to occlude when curling toward the palm) only
        // disables the pinch -- it must NOT drop the whole hand. The aim, the
        // virtual hand and the other gestures all survive without it.
        let thumb = tip(.thumbTip)
        thumbTipPos = thumb

        // One knob (Comfort > Pinch distance) sets the close threshold; release
        // is +1.5 cm so the pair can't be set to chatter. Sampled once per
        // ingest rather than per finger -- five lock takes a frame for a value
        // that cannot change mid-hand is waste.
        let pinchClose = VRSettings.shared.pinchClose
        let pinchOpen = pinchClose + 0.015
        func pinch(_ tipPos: SIMD3<Float>?, _ pinched: Bool) -> Bool {
            guard let thumb, let tipPos else { return false }
            let d = simd_distance(thumb, tipPos)
            return d < (pinched ? pinchOpen : pinchClose)
        }

        let index = tip(.indexFingerTip)
        indexTipPos = index
        if let thumb, let index { indexPinchDist = simd_distance(thumb, index) } else { indexPinchDist = 0.08 }
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

        // Teleport pointing ray: wrist -> middle knuckle (inferred, so it
        // survives the ring pinch), which follows wrist flex -- point the hand
        // at the floor and this aims down, unlike the forearm aim ray.
        if let w = vtip(.wrist), let mk = vtip(.middleFingerKnuckle),
           simd_length(mk - w) > 1e-4 {
            pointOrigin = w
            pointDir = simd_normalize(mk - w)
        } else {
            pointOrigin = nil
            pointDir = nil
        }
        // Wrist velocity for the flick snap-turn. Skip the first sample and
        // any dt spike (tracking resuming after a dropout would read as a
        // huge phantom velocity and fire a bogus turn).
        let velNow = CACurrentMediaTime()
        if let w = wrist, let pw = prevWrist {
            let dt = velNow - prevWristTime
            if dt < 0.1 {
                // Clamp the divisor to a ~120 Hz floor: back-to-back anchor
                // updates a millisecond apart otherwise turn sub-millimetre
                // tracking jitter into a huge phantom velocity (1 mm / 1 ms =
                // 1 m/s) that fires a bogus flick snap. Then one-pole low-pass
                // it: a single spiky frame can't reach the flick threshold on
                // its own, while a real (sustained) whip still passes.
                let dtc = max(Float(dt), 1.0 / 120.0)
                let raw = (w - pw) / dtc
                let a: Float = 0.4
                let smoothed = prevWristVel.map { $0 + (raw - $0) * a } ?? raw
                wristVel = smoothed
                prevWristVel = smoothed
            } else {
                // dt spike (tracking resumed after a dropout): drop the sample
                // and reset the filter so the next one restarts clean.
                wristVel = nil
                prevWristVel = nil
            }
        } else {
            wristVel = nil
            prevWristVel = nil
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
        // The prayer sign's plane is built from the METACARPALS instead, and
        // deliberately kept separate from palmUp above. They answer different
        // questions with different reliability needs: palm-up is held with the
        // fingers open and its knuckles in plain view, while the sign presses
        // the fingers together and hides every knuckle from the cameras. The
        // duplication is the point -- palmUp works today and stays untouched.
        // (Self.palmSign is palmUp's legacy calibration knob; PalmPose pins its
        // own convention in PalmPoseBuildTests.)
        if let w = wrist,
           let indexMeta = tip(.indexFingerMetacarpal),
           let littleMeta = tip(.littleFingerMetacarpal) {
            palmPose = PalmPose(wrist: w, indexMetacarpal: indexMeta,
                                littleMetacarpal: littleMeta, isLeft: isLeft)
        } else {
            palmPose = nil
        }
        // Diagnostic: when the palm plane can't be built, record which joints
        // ARKit is actually reporting. palmUp reads the same two knuckles, so
        // whatever is missing here has been disabling the palm-up wheel too --
        // worth knowing exactly, rather than picking a replacement joint by
        // guesswork. Only built when the plane is missing.
        if palmPose == nil, VRSettings.shared.inputLog {
            let probes: [(HandSkeleton.JointName, String)] = [
                (.wrist, "wrist"), (.forearmWrist, "fWrist"),
                (.indexFingerMetacarpal, "idxMeta"), (.indexFingerKnuckle, "idxKnuck"),
                (.middleFingerMetacarpal, "midMeta"), (.middleFingerKnuckle, "midKnuck"),
                (.littleFingerMetacarpal, "litMeta"), (.littleFingerKnuckle, "litKnuck"),
                (.indexFingerTip, "idxTip"), (.middleFingerTip, "midTip"),
            ]
            let missing = probes.filter { !skeleton.joint($0.0).isTracked }.map(\.1)
            jointDebug = missing.isEmpty
                ? "all probed joints tracked"
                : "untracked: \(missing.joined(separator: ","))"
        } else {
            jointDebug = ""
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
            // Aim ray = the forearm BONE alone (elbow joint -> wrist joint). It
            // tracks in any pose (fist, fire pinch, turned wrist), is
            // roll-invariant so both grips aim alike, and the forearm joints
            // were never once missing across a full session's joint log.
            //
            // There used to be a second component blended in: wrist -> knuckle
            // centroid, which picked up wrist FLEX so you could point the hand
            // down to aim down. It is gone deliberately. It was built from the
            // knuckle joints, and ARKit abandons those under exactly the
            // occlusion a shooting pose creates -- so the component did not
            // degrade, it VANISHED mid-gesture and took the aim with it in a
            // jump. A blend whose input intermittently disappears is worse than
            // the steady input alone. Tested on device: forearm-only is
            // materially more consistent. See docs/decisions.md.
            var base: SIMD3<Float>?
            if let armJ = tip(.forearmArm), let wristJ = tip(.forearmWrist),
               simd_length(wristJ - armJ) > 0.05 {
                base = simd_normalize(wristJ - armJ)
            } else if let arm = tip(.forearmArm), simd_length(w - arm) > 0.05 {
                base = simd_normalize(w - arm)
            }
            aimDir = base
            aimBaseDir = base
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
            aimSmoothed = nil
        }

        buildDebug(tip: vtip)   // inferred, so the wireframe doesn't drop fingers either
        // The index-finger wire for the wrist communicator. Also fed the
        // INFERRED pose: the hand reaching across to a wrist panel is
        // partly occluded by the forearm it is reaching for, which is
        // precisely when a tracked-only chain drops joints out of the wire.
        buildIndexWire(tip: vtip)
        // The DRAWN hand uses the INFERRED pose (vtip, defined above): ARKit
        // still reports a transform for an occluded joint, which is how
        // three.js/WebXR keeps every finger visible in a fist. Dropping
        // !isTracked joints was the dropout.
        buildVirtual(tip: vtip, isLeft: isLeft)
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
            let lon = 8, lat = 4
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

        // WebXR webxr_vr_handinput style: a round sphere at EVERY joint of the
        // 25-joint set (wrist + 4 metacarpals + knuckles + phalanges + tips),
        // no bones -- the spheres read as a hand on their own. Fed the inferred
        // pose (vtip), so none drop out in a fist. Mild taper from the fuller
        // knuckles to the small tips; the metacarpals and wrist fill the palm.
        _ = wristPt   // the guard above proves the hand is present
        func sphere(_ at: SIMD3<Float>, _ rad: Float) {
            bead(at, SIMD3<Float>(0, 1, 0), rad, rad, skin)   // long == rad -> round
        }
        if let w = tip(.wrist) { sphere(w, 0.013) }

        let fingers: [[HandSkeleton.JointName]] = [
            [.thumbKnuckle, .thumbIntermediateBase, .thumbIntermediateTip, .thumbTip],
            [.indexFingerMetacarpal, .indexFingerKnuckle, .indexFingerIntermediateBase,
             .indexFingerIntermediateTip, .indexFingerTip],
            [.middleFingerMetacarpal, .middleFingerKnuckle, .middleFingerIntermediateBase,
             .middleFingerIntermediateTip, .middleFingerTip],
            [.ringFingerMetacarpal, .ringFingerKnuckle, .ringFingerIntermediateBase,
             .ringFingerIntermediateTip, .ringFingerTip],
            [.littleFingerMetacarpal, .littleFingerKnuckle, .littleFingerIntermediateBase,
             .littleFingerIntermediateTip, .littleFingerTip],
        ]
        for joints in fingers {
            for (i, j) in joints.enumerated() {
                guard let p = tip(j) else { continue }
                let t = Float(i) / Float(max(1, joints.count - 1))
                sphere(p, 0.0105 - 0.0045 * t)   // knuckle -> tip
            }
        }
        virtualVerts = v
    }

    /// The INDEX FINGER alone as a wireframe: thin-quad bones down the
    /// metacarpal->knuckle->base->tip chain with a small octahedral node at
    /// each joint. The wrist communicator's renderer draws this on the one
    /// hand that is hovering or has just pressed a key, so the finger doing
    /// the pressing is visible against the stone unit.
    ///
    /// Index only, and no wrist bone: the whole point is to show WHERE the
    /// pressing fingertip is, and a full hand rig over a 10 cm panel hides
    /// the keys it is meant to be aiming at. Thin quads and octahedra for the
    /// same reason `buildDebug` uses them -- foveation forbids line and point
    /// primitives on device.
    ///
    /// Built unconditionally (no debug toggle), because its consumer is a
    /// gameplay feature rather than a debug overlay; the colour here is a
    /// neutral placeholder the renderer overwrites with the hover/press tint.
    /// Corrected-tracking space, 7 floats/vertex (xyz + rgba).
    private mutating func buildIndexWire(tip: (HandSkeleton.JointName) -> SIMD3<Float>?) {
        let chain: [HandSkeleton.JointName] = [
            .indexFingerMetacarpal, .indexFingerKnuckle,
            .indexFingerIntermediateBase, .indexFingerIntermediateTip, .indexFingerTip,
        ]
        let correction = TrackingSpace.correction
        let placeholder = SIMD4<Float>(1, 1, 1, 1)
        var v: [Float] = []
        func corner(_ p: SIMD3<Float>) {
            let q = correction * SIMD4(p, 1)
            v += [q.x, q.y, q.z, placeholder.x, placeholder.y, placeholder.z, placeholder.w]
        }
        // Thin quad bone, perpendicular off world-up so a "line" shows from
        // most angles (the same construction and ~2.5 mm half-thickness
        // `buildDebug`'s bones use).
        let up = SIMD3<Float>(0, 1, 0)
        func bone(_ a: SIMD3<Float>, _ b: SIMD3<Float>) {
            var perp = simd_cross(b - a, up)
            if simd_length(perp) < 1e-5 { perp = simd_cross(b - a, SIMD3(1, 0, 0)) }
            perp = simd_length(perp) > 0 ? simd_normalize(perp) * 0.0025 : SIMD3(0.0025, 0, 0)
            let a0 = a - perp, a1 = a + perp, b0 = b - perp, b1 = b + perp
            corner(a0); corner(a1); corner(b0)
            corner(a1); corner(b1); corner(b0)
        }
        func node(_ p: SIMD3<Float>, _ r: Float) {
            let px = p + SIMD3(r,0,0), nx = p - SIMD3(r,0,0)
            let py = p + SIMD3(0,r,0), ny = p - SIMD3(0,r,0)
            let pz = p + SIMD3(0,0,r), nz = p - SIMD3(0,0,r)
            func f(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ d: SIMD3<Float>) {
                corner(a); corner(b); corner(d)
            }
            f(px,py,pz); f(py,nx,pz); f(nx,ny,pz); f(ny,px,pz)
            f(py,px,nz); f(nx,py,nz); f(ny,nx,nz); f(px,ny,nz)
        }
        var prev: SIMD3<Float>?
        for (i, j) in chain.enumerated() {
            guard let cur = tip(j) else { prev = nil; continue }
            if let p = prev { bone(p, cur) }
            // Tapered nodes, fat knuckle to small tip, so the fingertip
            // itself is the smallest, most precise mark on the panel.
            node(cur, 0.0055 - 0.0015 * Float(i) / Float(chain.count - 1))
            prev = cur
        }
        indexWireVerts = v
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

    /// Whether to draw the stand-in at all. Off means the real hands show
    /// through passthrough the whole time instead of only once the world melts.
    /// Gated here rather than at the draw call so `publish` drops the geometry
    /// too -- the flag is read on the render thread every frame, and there is
    /// no reason to keep handing it a buffer it will throw away.
    private var _visible = true
    var visible: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _visible }
        set {
            lock.lock()
            _visible = newValue
            if !newValue { verts = [] }
            lock.unlock()
        }
    }

    func publish(_ v: [Float]) {
        lock.lock(); if _visible { verts = v }; lock.unlock()
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

/// The OFF hand's wrist position, corrected-tracking space, for the
/// wrist-mode HUD panel (vr_hud 1). Published from `wheel()` every hand
/// update using the exact same `offHand.wrist` + `TrackingSpace.correction`
/// the weapon wheel's own anchor is built from — unlike `WheelState`'s
/// anchor, which only updates while the palm-up hold is active, this tracks
/// the wrist whenever it's visible so the HUD can ride it continuously.
/// Invalid (not just stale) the instant the wrist drops out of tracking or
/// hands stand down for a controller (see `HandInput.setActive`), so the
/// render thread's fallback to the float placement has a real signal to
/// read instead of a frozen pose.
final class OffHandWrist: @unchecked Sendable {
    static let shared = OffHandWrist()
    private let lock = NSLock()
    private var _position = SIMD3<Float>.zero
    private var _valid = false

    func publish(position: SIMD3<Float>, valid: Bool) {
        lock.lock(); _position = position; _valid = valid; lock.unlock()
    }

    func invalidate() {
        lock.lock(); _valid = false; lock.unlock()
    }

    func snapshot() -> (position: SIMD3<Float>, valid: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_position, _valid)
    }
}

/// The GUN (dominant) hand's wrist position, corrected-tracking space, for
/// the gun-anchored HUD tile (vr_hud 3's Ammo tile) in hands-only play --
/// the exact mirror of `OffHandWrist`, just published from `gunHand` instead
/// of `offHand`. Before this existed, `ImmersiveRenderer.gunPosition()` had
/// no hands-only source and fell back to nothing, so the gun tile silently
/// required a Sense controller. See `OffHandWrist`'s doc comment for the
/// invalidation contract -- it applies here unchanged.
final class GunHand: @unchecked Sendable {
    static let shared = GunHand()
    private let lock = NSLock()
    private var _position = SIMD3<Float>.zero
    private var _valid = false

    func publish(position: SIMD3<Float>, valid: Bool) {
        lock.lock(); _position = position; _valid = valid; lock.unlock()
    }

    func invalidate() {
        lock.lock(); _valid = false; lock.unlock()
    }

    func snapshot() -> (position: SIMD3<Float>, valid: Bool) {
        lock.lock(); defer { lock.unlock() }
        return (_position, _valid)
    }
}

/// Shared debug-figure palette, reused across overlays so every screenshot
/// reads as one document. Colourblind-safe and matched to TriggerScope's chart
/// hues: blue forearm, orange centroid, green blend.
enum DebugColor {
    static let forearm  = SIMD4<Float>(0x39 / 255.0, 0x87 / 255.0, 0xE5 / 255.0, 0.95)
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
