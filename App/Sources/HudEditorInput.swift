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
        var zones: [HudEditor.Zone]
        var tiles: [HudEditor.TileFrame]
        /// tileIDs currently parked in the hidden tray (`show == false`).
        /// The render path draws every parked tile at the single HIDDEN
        /// zone spot (no distinct tray slots yet), so a pinch/trigger
        /// landing there is treated as reaching for one of these.
        var hiddenTileIDs: [Int]

        static let inactive = Snapshot(active: false, zones: [], tiles: [], hiddenTileIDs: [])
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
    /// Which hand is holding the current hands-mode grab, once one starts.
    /// `nil` exactly when no hand grab is live -- kept in sync with
    /// `HudEditor.shared.grab` being nil, so a release always clears it.
    /// Touched only from this instance's own single sequential loop task,
    /// never concurrently.
    private var grabbingIsLeft: Bool?

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
                // spin, and drop any stale hand bookkeeping so a later
                // session starts clean.
                grabbingIsLeft = nil
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func tick() async {
        let now = CACurrentMediaTime()
        let dt = Float(max(1.0 / 240, min(0.1, now - lastTick)))
        lastTick = now

        let geometry = WorkbenchGeometry.shared.snapshot()
        guard geometry.active else { grabbingIsLeft = nil; return }

        // Grab-start hit targets: every currently VISIBLE tile, plus one
        // synthetic frame at the HIDDEN zone for whichever tile is parked
        // there (see `WorkbenchGeometry.Snapshot.hiddenTileIDs`'s doc
        // comment) -- a pinch/trigger landing on that zone recalls it.
        var tiles = geometry.tiles
        if let tray = geometry.zones.first(where: { $0.isHiddenTray }),
           let firstHidden = geometry.hiddenTileIDs.first {
            tiles.append(HudEditor.TileFrame(tileID: firstHidden, origin: tray.origin,
                                             right: tray.right, up: tray.up,
                                             halfW: tray.radius, halfH: tray.radius))
        }
        let zones = geometry.zones

        let (grab, working) = await MainActor.run { (HudEditor.shared.grab, HudEditor.shared.working) }

        let input: HudEditor.GrabInput
        if SpatialControllerTracker.shared.isTracking {
            // Controllers own the grab while tracking -- no hand
            // bookkeeping needed, and hardware wins over hands per the
            // repo-wide rule (InputActivation.handsActive).
            grabbingIsLeft = nil
            let rightHanded = VRSettings.shared.rightHanded
            let dominant = controllerSignal(left: !rightHanded)
            input = HudEditor.GrabInput(primaryActive: dominant.active, primaryPoint: dominant.point,
                                        stickScaleAxis: dominant.stickAxis)
        } else {
            let hands = EditorHandInput.shared.snapshot()
            if grab == nil {
                // Nobody's holding anything yet: let whichever hand
                // actually hits a tile become primary. A dry run (pure,
                // no side effects) against the left hand first decides it
                // -- an arbitrary tie-break if both land on a tile the
                // same tick.
                let leftTry = HudEditor.GrabInput(primaryActive: hands.left.pinched, primaryPoint: hands.left.point)
                let dry = HudEditor.updateGrab(grab: nil, input: leftTry, working: working,
                                               tiles: tiles, zones: zones, dt: dt)
                if dry.grab != nil {
                    grabbingIsLeft = true
                    input = leftTry
                } else {
                    grabbingIsLeft = false
                    input = HudEditor.GrabInput(primaryActive: hands.right.pinched, primaryPoint: hands.right.point)
                }
            } else {
                let isLeft = grabbingIsLeft ?? true
                let primary = isLeft ? hands.left : hands.right
                let secondary = isLeft ? hands.right : hands.left
                input = HudEditor.GrabInput(primaryActive: primary.pinched, primaryPoint: primary.point,
                                            secondaryActive: secondary.pinched, secondaryPoint: secondary.point)
            }
        }

        let result = HudEditor.updateGrab(grab: grab, input: input, working: working,
                                          tiles: tiles, zones: zones, dt: dt)
        if result.grab == nil { grabbingIsLeft = nil }

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
