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
        while !Task.isCancelled {
            if WorkbenchGeometry.shared.snapshot().active {
                await tick()
                try? await Task.sleep(nanoseconds: 1_000_000_000 / 90)
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
        // cell (`geometry.tiles`). Wrist-drop resolution against the two
        // wrist frames (`geometry.off`/`geometry.gun`) and hidden-tile recall
        // are wired by the input task (Task 5); until then a release resolves
        // through `updateGrab`'s empty-`zones` path, which keeps the tile's
        // anchor and zeroes its offset rather than un-anchoring it.
        let tiles = geometry.tiles
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
                                           tiles: tiles, zones: zones, dt: dt)
            if dry.grab != nil {
                source = .handLeft
                input = leftTry
            } else {
                source = .handRight
                input = HudEditor.GrabInput(primaryActive: handRight.active, primaryPoint: handRight.point)
            }
        }

        let result = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                          tiles: tiles, zones: zones, dt: dt)
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
