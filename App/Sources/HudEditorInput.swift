//
//  HudEditorInput.swift
//
//  The HUD live editor's grab/move/scale input (plan Task 5): the thin
//  ARKit/GameController plumbing that reads real hand pinches or Sense
//  controller triggers/poses/thumbsticks, turns them into a
//  `HudEditor.GrabInput`, and calls the PURE `HudEditor.updateGrab`
//  (HudEditorMath.swift) -- then applies the result to `HudEditor.shared`
//  on the MAIN ACTOR, since `Session` is `@MainActor`. No ARKit/Metal/
//  Observation leaks into `updateGrab` itself; this file is the only place
//  that does the actor hop, and the only place that calls no `QC_*` at all
//  (the editor never touches the engine thread).
//
//  Geometry: the workbench's zone/tile-row frames are anchored to the
//  HEAD POSE, which only the render thread has (`ImmersiveRenderer`'s
//  `originFromDevice`/`deviceAnchor`) -- this file's own loop runs off
//  that thread entirely, so it can't rebuild that frame itself. Instead it
//  reads `WorkbenchGeometry`, a lock-protected per-frame publish from
//  `ImmersiveRenderer.publishWorkbenchGeometry`, the same cross-loop
//  pattern `GunHand`/`OffHandWrist`/`HudEditor.Session.renderSnapshot`
//  already use for exactly this kind of state.
//
//  Hands: `EditorHandInput` is published from `HandInput.emit` every hand
//  update (pinch + pinch-point, per hand, generic -- not move/aim-labelled,
//  since either hand can grab a tile here). This file never opens its own
//  ARKit hand session; that would be a second, redundant `HandTrackingProvider`
//  fighting the one `HandInput` already owns.
//
//  Source binding: once a grab starts, `tick()` stays bound to whichever
//  source started it (`boundSource`) and feeds ONLY that source's signal
//  through `HudEditor.grabInput(for:...)` -- it does NOT re-decide
//  "controller or hands" from live tracking state every tick. A controller
//  that stops tracking (or a hand that stops pinching) mid-grab therefore
//  reports its own `primaryActive == false` and releases through
//  `updateGrab`'s existing path, rather than silently handing the grab off
//  to a different source that happens to be live that tick.
//

import Foundation
import GameController
import QuartzCore
import simd

/// One hand's pinch + pinch-point for the editor, published by
/// `HandInput.emit`. `point` is `nil` exactly when that hand's pinch
/// geometry (thumb + index tip) isn't tracked -- the "hand lost" signal
/// `HudEditor.updateGrab` releases a grab on (Review Focus #1).
struct EditorHandSignal {
    var pinched: Bool
    var point: SIMD3<Float>?   // corrected tracking space
}

/// Cross-loop publish of the latest per-hand pinch signal for the editor's
/// grab input. Written by `HandInput.emit` every hand update (ahead of its
/// own wheel/prayer suppressions -- the editor needs a fresh read whether
/// or not a gameplay gesture fired this frame); read by `HudEditorInput`'s
/// own loop, which runs at its own cadence. Same lock-protected
/// plain-value pattern as `GunHand`/`OffHandWrist`.
final class EditorHandInput: @unchecked Sendable {
    static let shared = EditorHandInput()

    private let lock = NSLock()
    private var _left = EditorHandSignal(pinched: false, point: nil)
    private var _right = EditorHandSignal(pinched: false, point: nil)

    func publish(left: EditorHandSignal, right: EditorHandSignal) {
        lock.lock(); _left = left; _right = right; lock.unlock()
    }

    func snapshot() -> (left: EditorHandSignal, right: EditorHandSignal) {
        lock.lock(); defer { lock.unlock() }
        return (_left, _right)
    }

    /// Hands stood down (a controller took over, or the immersive space
    /// closed) -- publish "lost" for both, so a live editor grab releases
    /// instead of freezing on a stale pinch. Called from the same places
    /// `HandInput` already invalidates `GunHand`/`OffHandWrist`.
    func invalidate() {
        publish(left: EditorHandSignal(pinched: false, point: nil),
               right: EditorHandSignal(pinched: false, point: nil))
    }
}

/// Cross-loop publish of each hand's index-fingertip world position, for
/// the wrist communicator's touch hit-test (plan Task 3). Written by
/// `HandInput.emit` every hand update, immediately alongside
/// `EditorHandInput.shared.publish(...)` and ahead of every gate/suppression
/// below it -- the communicator needs a fresh fingertip read whether or not
/// a gameplay gesture or the HUD editor is active this frame, the same
/// reasoning `EditorHandInput`'s doc comment gives for its own publish.
/// `nil` per hand exactly when that hand's index tip isn't tracked. Same
/// lock-protected plain-value pattern as `EditorHandInput`/`GunHand`/
/// `OffHandWrist`.
final class FingerTips: @unchecked Sendable {
    static let shared = FingerTips()

    private let lock = NSLock()
    private var _left: SIMD3<Float>?
    private var _right: SIMD3<Float>?

    func publish(left: SIMD3<Float>?, right: SIMD3<Float>?) {
        lock.lock(); _left = left; _right = right; lock.unlock()
    }

    func snapshot() -> (left: SIMD3<Float>?, right: SIMD3<Float>?) {
        lock.lock(); defer { lock.unlock() }
        return (_left, _right)
    }

    /// Hands stood down -- publish "lost" for both, the same stand-down
    /// EditorHandInput.invalidate() answers for its own signal.
    func invalidate() {
        publish(left: nil, right: nil)
    }
}

/// Cross-loop publish of each hand's INDEX-FINGER wireframe, for the wrist
/// communicator's touch feedback. Written by `HandInput.emit` every hand
/// update, immediately alongside `FingerTips.shared.publish(...)` and ahead
/// of every gate/suppression below it, for the same reason that publish
/// gives: the communicator needs a fresh read whether or not a gameplay
/// gesture or the HUD editor is active this frame.
///
/// Thin-quad TRIANGLE vertices, 7 floats each (xyz + rgba), in corrected
/// tracking space -- the `GuideVertex` layout every hand overlay uses, and
/// quads rather than lines because line primitives are illegal under the
/// device's foveation rate map. Empty per hand exactly when that hand isn't
/// tracked.
///
/// The published colour is a neutral placeholder: the renderer overwrites it
/// per vertex (`ImmersiveRenderer.tintedFingerWire`) with the hover/press
/// tint, because whether a hand is working a panel -- and which of the two
/// panels -- is the renderer's knowledge, not this loop's. Same
/// lock-protected plain-value pattern as `FingerTips`/`WristCommGeometry`.
final class FingerWire: @unchecked Sendable {
    static let shared = FingerWire()

    private let lock = NSLock()
    private var _left: [Float] = []
    private var _right: [Float] = []

    func publish(left: [Float], right: [Float]) {
        lock.lock(); _left = left; _right = right; lock.unlock()
    }

    func snapshot() -> (left: [Float], right: [Float]) {
        lock.lock(); defer { lock.unlock() }
        return (_left, _right)
    }

    /// Hands stood down -- publish nothing to draw, the same stand-down
    /// `FingerTips.invalidate()` answers for its own signal. Without it the
    /// renderer would keep a frozen wire from the last tracked frame, which
    /// a hover arriving later would then light up.
    func invalidate() {
        publish(left: [], right: [])
    }
}

/// Cross-loop publish of this frame's workbench hit-test geometry. The
/// render thread builds it (see `ImmersiveRenderer.publishWorkbenchGeometry`,
/// which documents the zone/tile layout this mirrors) every frame the
/// editor is active, since it alone has the head pose the workbench is
/// anchored to; this file's own loop reads the published snapshot instead
/// of trying to reconstruct that frame.
final class WorkbenchGeometry: @unchecked Sendable {
    static let shared = WorkbenchGeometry()

    struct Snapshot {
        var active: Bool
        /// The two wrist-grid frames this frame -- the off-hand and gun-hand
        /// forearm planes the render thread resolved (origin/right/up/forward
        /// in corrected tracking space, `valid == false` for an untracked
        /// wrist). The input layer (Task 5) hit-tests a wrist drop against
        /// these instead of the old free-floating zone proxies.
        var off: HudEditor.WristFrame
        var gun: HudEditor.WristFrame
        var tiles: [HudEditor.TileFrame]
        /// tileIDs currently hidden (`show == false`). Carried for the input
        /// layer's recall path; the render thread draws nothing for them.
        var hiddenTileIDs: [Int]

        private static let noWrist = HudEditor.WristFrame(anchor: 0, origin: .zero, right: .zero,
                                                          up: .zero, forward: .zero, valid: false)
        static let inactive = Snapshot(active: false, off: noWrist, gun: noWrist,
                                       tiles: [], hiddenTileIDs: [])
    }

    private let lock = NSLock()
    private var _snapshot = Snapshot.inactive

    func publish(_ snapshot: Snapshot) {
        lock.lock(); _snapshot = snapshot; lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }
}

/// Cross-loop publish of this frame's wrist-communicator geometry: for each
/// side (0 = off wrist, 1 = gun wrist) the wrist plane the 2x3 action grid
/// is seated on, the grid centre `WristComm.commOrigin` resolved from it,
/// and how revealed the panel is right now. Written by the render thread
/// (`ImmersiveRenderer.updateWristComm`, which documents the reveal
/// hysteresis and the fade) every frame, because it alone holds the
/// late-latched head pose and the latched wrist frames the grid is anchored
/// to -- the exact same cross-loop reason `WorkbenchGeometry` above exists.
/// Read by the communicator's touch loop (Task 5), which hit-tests a
/// fingertip against `commOrigin`/`frame` rather than rebuilding them.
///
/// BOTH sides are published every frame whatever their state (disabled,
/// untracked wrist, faded out), so the touch loop can gate itself on
/// `enabled`/`opacity`/`frame.valid` from one snapshot instead of guessing
/// what an absent entry meant. Same lock-protected plain-value pattern as
/// `WorkbenchGeometry`/`EditorHandInput`/`FingerTips`.
final class WristCommGeometry: @unchecked Sendable {
    static let shared = WristCommGeometry()

    /// One side's communicator geometry this frame. `frame.valid == false`
    /// (and a zero `commOrigin`) is an untracked wrist -- nothing to touch;
    /// `opacity` is the faded reveal the draw uses, which the touch loop
    /// reads too so a cell can only fire while the panel is actually up.
    struct Side {
        var enabled: Bool
        var frame: HudEditor.WristFrame
        var commOrigin: SIMD3<Float>
        var opacity: Float
    }

    struct Snapshot {
        /// Index 0 = off wrist, 1 = gun wrist -- the same side order
        /// `WristCommStore.Snapshot.sides` uses.
        var sides: [Side]

        private static let idle = Side(enabled: false, frame: .invalid,
                                       commOrigin: .zero, opacity: 0)
        /// No communicator anywhere: what a reader sees before the immersive
        /// render loop has published a frame, and after it stops -- the
        /// render thread publishes this explicitly as it exits (see
        /// `ImmersiveRenderer.run`'s teardown), rather than leaving the last
        /// frame's snapshot frozen for the touch loop to fire off.
        static let inactive = Snapshot(sides: [idle, idle])
    }

    private let lock = NSLock()
    private var _snapshot = Snapshot.inactive

    func publish(_ snapshot: Snapshot) {
        lock.lock(); _snapshot = snapshot; lock.unlock()
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return _snapshot
    }
}

/// Cross-loop publish of the LAST wrist-communicator cell that actually
/// fired, so the renderer can flash the key that was pressed. Written by
/// the communicator's touch loop (`WristCommInput.tick`) at the one point
/// it commits to a fire -- after `WristComm.updateTouch`'s edge/cooldown
/// gate and after `WristComm.shouldFire` -- and read by the render thread
/// in `ImmersiveRenderer.updateWristComm`.
///
/// Published from the TOUCH loop rather than from `WristCommStore.fire`
/// deliberately: `fire` runs on the main actor one hop later, so keying the
/// flash off it would date the press by however long that hop took and
/// would also light up a cell that a console `wristcomm` refresh re-bound
/// in between. The touch loop's own `CACurrentMediaTime()` is the instant
/// the finger crossed the plane.
///
/// Only the last fire is kept, not a queue: `WristComm.pressFlash` is
/// shorter than `WristComm.cooldown`, so one key's flash has always
/// finished before that key can fire again, and two different keys cannot
/// fire in the same tick (`updateTouch` fires at most one cell per tick).
/// A second press inside the window therefore legitimately replaces the
/// first rather than queueing behind it. Same lock-protected plain-value
/// pattern as `FingerTips`/`WristCommGeometry`.
final class WristCommFeedback: @unchecked Sendable {
    static let shared = WristCommFeedback()

    private let lock = NSLock()
    private var _side = 0
    private var _cell = 0
    /// `nil` until the first fire of the session -- the renderer draws no
    /// flash at all rather than flashing cell 0 at time 0, which a
    /// `CACurrentMediaTime()` comparison against a default 0 would do for
    /// the first `pressFlash` seconds after launch.
    private var _time: Double?

    func noteFire(side: Int, cell: Int, at time: Double) {
        lock.lock(); _side = side; _cell = cell; _time = time; lock.unlock()
    }

    func snapshot() -> (side: Int, cell: Int, time: Double)? {
        lock.lock(); defer { lock.unlock() }
        guard let time = _time else { return nil }
        return (_side, _cell, time)
    }

    /// A fire's flash must not survive a stand-down. The renderer clears this
    /// when the immersive layer parks or tears down and when the HUD editor
    /// opens -- otherwise a press made just before the suppression (flash
    /// window 0.25 s, fade-in crosses the draw floor in one 90 Hz frame)
    /// comes back as a key already lit with no fingertip on it.
    func invalidate() {
        lock.lock(); _time = nil; lock.unlock()
    }
}

/// Drives `HudEditor.updateGrab` every tick from real hand pinches
/// (`EditorHandInput`) or Sense controller triggers/poses/thumbsticks
/// (`SpatialControllerTracker` + `GCController`), and applies the result to
/// `HudEditor.shared` on the main actor. Idle-polls cheaply while the
/// editor is closed (`WorkbenchGeometry.snapshot().active == false`), so
/// `start()` can simply run for the app's lifetime once the owner (the
/// "Edit HUD Layout" entry point) calls it -- mirroring `InputHost`'s own
/// "call start() once, let the gates do the rest" lifecycle for
/// `GameControllerInput`.
final class HudEditorInput: @unchecked Sendable {
    static let shared = HudEditorInput()

    private var runTask: Task<Void, Never>?
    private var lastTick = CACurrentMediaTime()
    /// Which physical source is holding the current grab, once one starts.
    /// `nil` exactly when no grab is live -- kept in sync with
    /// `HudEditor.shared.grab` being nil, so a release always clears it.
    /// Touched only from this instance's own single sequential loop task,
    /// never concurrently.
    ///
    /// Bound deliberately, not re-picked every tick: a controller that
    /// stops tracking (or a hand that stops pinching) mid-grab must report
    /// through its OWN now-inactive signal and release via `updateGrab`'s
    /// existing path -- never fall through to a different source that
    /// happens to be live and silently take over the hold. See
    /// `HudEditor.grabInput(for:...)`'s doc comment for the bug this fixes
    /// and the host test that covers it (`runSourceStickinessTests` in
    /// hud_editor_input_test.swift).
    private var boundSource: HudEditor.GrabSource?

    private static let stickDeadzone: Float = 0.15

    func start() {
        guard runTask == nil else { return }
        runTask = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        let budget = 1.0 / 90.0
        while !Task.isCancelled {
            if WorkbenchGeometry.shared.snapshot().active {
                // Rate-compensate: sleep only the REMAINDER of the 90 Hz budget
                // after the tick's own work (two main-actor hops), so the loop
                // holds a true 90 Hz instead of 90 Hz PLUS the tick duration --
                // which had quietly dropped the effective grab rate and added
                // input->grid latency.
                let start = CACurrentMediaTime()
                await tick()
                let remaining = budget - (CACurrentMediaTime() - start)
                if remaining > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                }
            } else {
                // Editor closed: nothing to drive. Poll slowly rather than
                // spin, and drop any stale source bookkeeping so a later
                // session starts clean.
                boundSource = nil
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func tick() async {
        let now = CACurrentMediaTime()
        let dt = Float(max(1.0 / 240, min(0.1, now - lastTick)))
        lastTick = now

        let geometry = WorkbenchGeometry.shared.snapshot()
        guard geometry.active else { boundSource = nil; return }

        // Grab-start hit targets: every currently VISIBLE tile at its wrist
        // cell (`geometry.tiles`). `off`/`gun` are this frame's two wrist-
        // grid frames (Task 5) -- `updateGrab` snaps a release onto whichever
        // one the point lands over (`resolveWristDrop`) and sets a two-hand
        // footprint while dragging; `zones` stays empty, so a release that
        // misses both wrists falls through to `resolveDrop`'s keep-previous
        // path rather than a free-floating GUN/FLOAT proxy.
        let tiles = geometry.tiles
        let off = geometry.off
        let gun = geometry.gun
        let zones: [HudEditor.Zone] = []

        let (grab, working) = await MainActor.run { (HudEditor.shared.grab, HudEditor.shared.working) }

        // This tick's raw signal from every physical source, gathered
        // up front -- which of these actually DRIVES the grab is decided
        // below, and (the fix) is NOT simply "whichever is live" once a
        // grab already exists.
        let controllerTracking = SpatialControllerTracker.shared.isTracking
        let rightHanded = VRSettings.shared.rightHanded
        let controllerRaw = controllerTracking
            ? controllerSignal(left: !rightHanded) : (active: false, point: nil, stickAxis: nil)
        let controller = HudEditor.SourceSignal(active: controllerRaw.active, point: controllerRaw.point)
        let hands = EditorHandInput.shared.snapshot()
        let handLeft = HudEditor.SourceSignal(active: hands.left.pinched, point: hands.left.point)
        let handRight = HudEditor.SourceSignal(active: hands.right.pinched, point: hands.right.point)

        let input: HudEditor.GrabInput
        let source: HudEditor.GrabSource

        if grab != nil {
            // A grab is already live: stay bound to whichever source
            // started it (the fix) -- `grabInput` reports ONLY that
            // source's own signal, so a controller that stops tracking
            // (or a hand that stops pinching) surfaces as `primaryActive
            // == false` and fires `updateGrab`'s existing release-at-
            // lastPoint path, rather than a different source that
            // happens to be live taking over. `boundSource` should
            // already be set from the tick the grab started; the
            // fallback is defensive only (it should never actually be
            // reached in normal operation).
            source = boundSource ?? .handLeft
            input = HudEditor.grabInput(for: source, controller: controller,
                                        handLeft: handLeft, handRight: handRight,
                                        stickScaleAxis: controllerRaw.stickAxis)
        } else if controllerTracking {
            // Nobody's holding anything yet, and a controller is
            // tracking: hardware wins over hands per the repo-wide rule
            // (InputActivation.handsActive), so the controller is the
            // only candidate -- even if its trigger isn't pressed this
            // tick (then `updateGrab` simply finds no hit and starts
            // nothing).
            source = .controller
            input = HudEditor.GrabInput(primaryActive: controller.active, primaryPoint: controller.point,
                                        stickScaleAxis: controllerRaw.stickAxis)
        } else {
            // No controller tracking: let whichever hand actually hits a
            // tile become the candidate. A dry run (pure, no side
            // effects) against the left hand first decides it -- an
            // arbitrary tie-break if both land on a tile the same tick.
            let leftTry = HudEditor.GrabInput(primaryActive: handLeft.active, primaryPoint: handLeft.point)
            let dry = HudEditor.updateGrab(grab: nil, input: leftTry, working: working,
                                           tiles: tiles, zones: zones, off: off, gun: gun, dt: dt)
            if dry.grab != nil {
                source = .handLeft
                input = leftTry
            } else {
                source = .handRight
                input = HudEditor.GrabInput(primaryActive: handRight.active, primaryPoint: handRight.point)
            }
        }

        let result = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                          tiles: tiles, zones: zones, off: off, gun: gun, dt: dt)
        boundSource = result.grab == nil ? nil : source

        await MainActor.run {
            HudEditor.shared.grab = result.grab
            HudEditor.shared.working = result.working
        }
    }

    // MARK: - Controller reads

    /// Trigger (grab) + pose (grab point, corrected tracking space) +
    /// thumbstick Y (scale axis, deadzoned) for the controller on the
    /// given side, or all-idle if that side isn't attached/tracked.
    private func controllerSignal(left: Bool) -> (active: Bool, point: SIMD3<Float>?, stickAxis: Float?) {
        guard let controller = GCController.controllers().first(where: {
            $0.productCategory == GCProductCategorySpatialController
                && SpatialControllerTracker.shared.isLeft($0) == left
        }), let pose = SpatialControllerTracker.shared.pose(left: left) else {
            return (false, nil, nil)
        }
        let p = TrackingSpace.correction * pose.columns.3
        let point = SIMD3<Float>(p.x, p.y, p.z)
        let profile = controller.physicalInputProfile
        let active = Self.button(profile, containing: "Trigger")?.isPressed ?? false
        var stickAxis: Float?
        if let stick = Self.dpad(profile, containing: "Thumbstick") {
            let v = stick.yAxis.value
            stickAxis = abs(v) > Self.stickDeadzone ? v : nil
        }
        return (active, point, stickAxis)
    }

    /// Small, deliberately duplicated subset of `SenseMapper`'s own element
    /// lookup (GameControllerInput.swift, `private` to that file) -- this
    /// file only needs the trigger and the thumbstick, not the whole
    /// button map, so it isn't worth widening that type's access just for
    /// two lookups.
    private static func button(_ profile: GCPhysicalInputProfile,
                               containing fragment: String) -> GCControllerButtonInput? {
        if let exact = profile.buttons[fragment] { return exact }
        for (name, input) in profile.buttons where name.localizedCaseInsensitiveContains(fragment) {
            return input
        }
        return nil
    }

    private static func dpad(_ profile: GCPhysicalInputProfile,
                             containing fragment: String) -> GCControllerDirectionPad? {
        for (name, input) in profile.dpads where name.localizedCaseInsensitiveContains(fragment) {
            return input
        }
        return nil
    }
}
