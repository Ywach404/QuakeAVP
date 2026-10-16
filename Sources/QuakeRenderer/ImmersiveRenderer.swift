// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  ImmersiveRenderer.swift
//
//  The immersive space's half of the consumer: a dedicated render thread
//  driving a CompositorServices LayerRenderer in stereo with real head
//  tracking. It owns queryNextFrame — the compositor is the clock for
//  *rendering*; the engine keeps its own 90 Hz pacer and the triple-buffered
//  handoff decouples the two, so a sim hitch (map load) can never stall the
//  compositor.
//
//  Head pose is late-latched: the engine publishes only the player's
//  world->view basis in Quake units, and this thread composes
//
//      projection x eyeFromDevice⁻¹ x deviceFromOrigin⁻¹ x scale x playerBasis
//
//  per eye *after* sampling drawable.deviceAnchor as close to encode as the
//  frame lifecycle allows. Building matrices engine-side would add a frame
//  of head-tracking latency, which is the difference between comfortable
//  and nauseating.
//
//  Stereo is single-pass by vertex amplification when the device supports
//  it (layered layout, count 2, [[amplification_id]] in world_vertex); the
//  fallback is one pass per view routed by view.textureMap, which also
//  covers the dedicated layout the simulator prefers. Same shaders, same
//  RendererCore encode path as the flat window.
//

import CompositorServices
import ARKit
import Metal
import simd

final class ImmersiveRenderer {

    private let layerRenderer: LayerRenderer
    private let core: RendererCore
    private let onStop: (ImmersiveRenderer) -> Void

    /// The world-tracking provider that serves this thread's device anchors,
    /// behind an owner that can rebuild it. See `DeviceAnchorSource`.
    ///
    /// A rebuild hands the engine a recenter request, not a render-side
    /// re-zero: the new provider's tracking origin is not the old one's, and
    /// only `vr_recenter` can move the world under the player without the
    /// absorption ledger shoving the player box to meet it. An any-thread
    /// `QC_Input*` producer, drained on the engine thread — the same route
    /// every other input takes.
    private let anchors = DeviceAnchorSource { QC_InputRequestRecenter() }

    /// Whether the previous frame had a device anchor, so an outage is logged
    /// on its EDGES only -- a line per frame at 90 Hz is exactly what made
    /// ARKit's own per-frame complaint unreadable. Starts true so a cold
    /// start that never gets a pose still says so on its first frame.
    private var hadAnchor = true
    private var skippedFrames = 0

    /// Whether world tracking has been asked for yet. Render-thread only;
    /// see the `.running` arm of `run()` for why it is not `start()`'s job.
    private var startedAnchors = false

    /// One-shot log latches for the two rare frame paths, so a device stream
    /// names them once instead of 90 times a second. Render-thread only.
    private var loggedNoCommandBuffer = false
    private var loggedBarePresent = false

    private var pipelines: RenderPipelines?
    private var singlePassStereo = false
    private var loggedSetup = false

    /// Culling fov last reported to the engine, to dedupe the C call.

    /// Seated recenter: when the packet's recenter_count bumps, capture a
    /// correction that maps the current head yaw and position to neutral,
    /// composed under every device pose until the next recenter. The count
    /// is echoed back through QC_InputSetHeadOffset so the engine knows
    /// which generation the feed belongs to.
    private var recenterCorrection = matrix_identity_float4x4
    private var recenterSeen: UInt32 = 0
    private var zeroedInitialPose = false

    // Last valid wrist-grid frames, held through hand occlusion while the HUD
    // editor is open: reaching a hand over a wrist hides it from the cameras,
    // so without this the grid would vanish the instant you reach to grab a
    // tile. Render-thread only. See wristFrames().
    private var lastOffWristFrame: HudEditor.WristFrame?
    private var lastGunWristFrame: HudEditor.WristFrame?

    // Wrist communicator reveal state, per side (index 0 = off wrist, 1 =
    // gun wrist -- the side order WristCommStore.Snapshot.sides uses).
    // `commRevealed` is the hysteresis latch WristComm.revealTarget needs to
    // hold its decision inside the on/off cone band; `commOpacity` is the
    // eased fade the draw and the touch gate both read. Render-thread only,
    // like the wrist latch above.
    private var commOpacity: [Float] = [0, 0]
    private var commRevealed: [Bool] = [false, false]
    /// Per-side last valid communicator POSE, and when it was last seen, for
    /// the communicator's OWN bounded occlusion hold -- see `commPose`,
    /// which documents why the editor latch above cannot serve here.
    /// Render-thread only, like the reveal state.
    ///
    /// ONE hold per side, whichever view is up: the across view's
    /// billboarded wrist plane and the along view's forearm pose are the
    /// two cases of `CommPose`, and both go through the same storage, the
    /// same timestamp and the same reveal gate. A second hold for the
    /// second view would be a second thing to keep in step with the first.
    private var commHeldPose: [CommPose?] = [nil, nil]
    private var commHeldSince: [Double] = [0, 0]
    /// The view (`dials.alongArm`) the held poses above were taken under,
    /// so a toggle mid-hold can be caught and the hold dropped rather than
    /// re-resolved against the OTHER view's dials -- see `updateWristComm`.
    /// `nil` until the first frame; render-thread only, like the hold itself.
    private var lastCommAlongArm: Bool?
    /// Per-side index of the fingertip (0 = left, 1 = right) last seen
    /// hovering this side's grid -- the hand the solid index-finger model is
    /// drawn on, latched so the finger stays on that hand for the tail of a
    /// press flash after the finger has withdrawn. Render-thread only.
    private var commHoverHand: [Int?] = [nil, nil]
    /// Previous frame's timestamp for the reveal fade's dt. nil until the
    /// first communicator update; CACurrentMediaTime rather than the
    /// compositor clock because the fade is wall-time comfort easing, not
    /// anything the presentation timeline needs to agree with.
    private var lastCommTick: Double?
    /// Whether the one-time bindings refresh has been requested yet (see
    /// `updateWristComm`, which documents why it has to happen at all).
    private var requestedCommBootstrap = false
    /// When the last bindings refresh was requested, for the rising-edge
    /// debounce in `requestCommRefresh` -- one timestamp shared by both
    /// sides, since the refresh it gates re-reads every side's cvars anyway.
    private var lastCommRefreshRequest: Double?

    // Frame timing stats, logged every `statsWindow` frames.
    private let statsWindow = 300
    private var statFrames = 0
    private var statCPUStart = 0.0
    private var statGPUTotal = 0.0
    private var statGPUWorst = 0.0
    private let gpuStatsLock = NSLock()

    init(layerRenderer: LayerRenderer, core: RendererCore,
         onStop: @escaping (ImmersiveRenderer) -> Void) {
        self.layerRenderer = layerRenderer
        self.core = core
        self.onStop = onStop
    }

    func start() {
        // NOT anchors.start() here. This runs from the CompositorLayer's
        // renderer closure, before the layer has reached `.running` -- and
        // a world-tracking provider asked for while the space is still
        // coming up starts and is immediately PAUSED by ARKit. The
        // supervisor only rebuilt on `.stopped`, so a provider parked in
        // `.paused` stayed there and every frame skipped for ever. It is
        // started from the render thread's first `.running` tick instead,
        // which is the point at which the space is actually presenting.
        let thread = Thread { [self] in run() }
        thread.name = "quake.render.immersive"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: - Render thread

    private func run() {
        // Cull by PVS only: the head faces anywhere the compositor renders,
        // so a body-forward frustum would drop the world behind the gaze.
        QC_RendererSetCullingFov(360, 360)
        loop: while true {
            switch layerRenderer.state {
            case .invalidated:
                break loop
            case .paused:
                // Stand the communicator down BEFORE blocking. The touch
                // loop keeps running at 90 Hz while this thread is parked,
                // so a space paused mid-glance would leave
                // `WristCommGeometry` frozen at `enabled: true, opacity ~
                // 1`: fingertips going nil and returning inside a frozen
                // cell read as a rising edge, and one bound command
                // ghost-fires with nothing on screen. Same freeze the
                // teardown below avoids, same fix. The per-side reveal
                // state goes with it, so a resume re-earns the reveal from
                // a fresh glance instead of resurrecting a stale one.
                standDownWristComm()
                layerRenderer.waitUntilRunning()
            case .running:
                // World tracking is asked for HERE, once, rather than from
                // start() -- see the note there. The layer being `.running`
                // is the app's only signal that the immersive space is
                // actually up, which is the condition ARKit needs before it
                // will leave a world-tracking provider running.
                if !startedAnchors {
                    startedAnchors = true
                    anchors.start()
                }
                autoreleasepool { renderFrame() }
            @unknown default:
                break loop
            }
        }

        // The engine outlives any number of immersive sessions; hand the
        // packet stream back to the window and drop the layer.
        QC_RendererSetCullingFov(0, 0)
        QC_InputSetHeadPitch(0)   // level the aim for a later flat-window session
        // release the hand aim; body-anchored on the flat window
        TrackRecorder.shared.feedAim(valid: false, origin: .zero, yaw: 0, pitch: 0)
        // Stand the communicator down. Nothing else publishes after this
        // thread stops, so without it the LAST frame's snapshot stays
        // frozen -- and a space dismissed mid-glance freezes it at
        // `enabled: true, opacity ~ 1`, from which the touch loop can read
        // one rising edge off an equally frozen fingertip and ghost-fire a
        // bound command with nothing on screen.
        standDownWristComm()
        // Stop the ARKit session with the thread that was using it. It used
        // to be left running: nothing called `stop()`, and the renderer was
        // kept alive by its own stop closure, so every open/dismiss cycle
        // leaked a live session with a running WorldTrackingProvider in it.
        anchors.stop()
        print("[immersive] layer invalidated, render thread exiting")
        onStop(self)
    }

    /// Yield briefly on an early return that happens BEFORE the frame's
    /// `optimalInputTime` wait, which is the loop's only pacing. Without it
    /// those paths spin a `.userInteractive` core flat out:
    /// `cp_layer_renderer_query_next_frame` returns nil when the layer is
    /// paused, invalidated "or has too many frames already in use", and the
    /// header's instruction for that is literally "wait a short time and try
    /// again". The anchor skip and the cancelled-frame return are both AFTER
    /// the wait and are paced by it, so they don't take this.
    private func idle() {
        Thread.sleep(forTimeInterval: 0.0015)
    }

    // MARK: - The submission window
    //
    // THE RULE, paid for three times on device in one day:
    //
    //   Everything that can fail happens BEFORE `startSubmission`. Between
    //   `startSubmission` and `endSubmission` there is one straight line
    //   with no `guard`, no optional chain and no early return, and it ends
    //   in `encodePresent` + `commit`.
    //
    // The three failures, each the same mistake in a different disguise:
    //
    //  1. Returning from a queried frame without submitting leaks it. A
    //     frame is in flight from `queryNextFrame` until
    //     `cp_frame_end_submission`, three is the limit, and after that
    //     `queryNextFrame` returns nil for ever ("or has too many frames
    //     already in use") and the view never draws again.
    //  2. An EMPTY submission -- `startSubmission` straight into
    //     `endSubmission`, no drawable -- aborts. SIGABRT on the first
    //     skipped frame, device-confirmed 2026-10-16. The submission pair is
    //     documented only as timing hints, which reads as though a drawable
    //     were optional between them. It is not.
    //  3. Taking the drawable AFTER `startSubmission` aborts too, because
    //     an empty `queryDrawables()` array leaves the frame "invalid to
    //     access" -- there is no `endSubmission` available to close a
    //     submission already opened on it. Device-confirmed the same day,
    //     re-entering the space with the headset off.
    //  4. And the one this structure exists for: a FALLIBLE STEP INSIDE the
    //     window. `makeCommandBuffer()` returned nil on a dying Metal
    //     context, an optional-chained `guard ... else { return }` swallowed
    //     it, nothing was presented, and `endSubmission` ran anyway --
    //     aborting inside `cp_frame_end_submission` itself
    //     (QuakeAVP-2026-10-16-120542.ips: __BUG_IN_CLIENT__ <-
    //     cp_frame_end_submission <- renderFrame, on
    //     quake.render.immersive). A silent present failure is
    //     indistinguishable from case 2 from the compositor's side.
    //
    // Hence acquire-first. If an acquisition fails we never open the
    // submission, and the frame is left holding in flight -- deliberately.
    // That is case 1, bounded: a nil command buffer means the layer is
    // going away, the next `queryNextFrame` returns nil, `idle()` paces the
    // loop, and the layer invalidates and the thread exits. Transient
    // starvation on a layer that is dying anyway is a trade worth making
    // against an abort on a layer that is merely asleep.
    //
    // The bare present itself -- a command buffer carrying only
    // `encodePresent`, with no device anchor set -- is device-confirmed
    // working (entry 1, 2026-10-16: five skipped frames on the way in, then
    // minutes at 90 fps). The compositor answers "Presenting a drawable
    // without a device anchor. This drawable won't be presented.", keeps
    // showing the last frame it has, and returns the frame. That warning is
    // the cost of a skip, bounded by the outage and invisible to the
    // wearer. Nothing is encoded beyond the present:
    // `cp_drawable_encode_present` asks only to be "the last step before
    // committing the specified command buffer", it does not require a
    // render pass, and an empty Metal command buffer is legal.

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { idle(); return }

        frame.startUpdate()
        // No per-frame input to gather until M4.
        frame.endUpdate()

        // A nil timing means the layer is paused or invalidated
        // (`cp_frame_predict_timing`), which is the SAME condition under
        // which `cp_frame_query_drawables` returns an empty array and the
        // frame "has been cancelled … and is invalid to access". So this
        // frame is already the compositor's again and is not touched
        // further -- the shape that shipped for weeks. `run()`'s state
        // machine parks or exits on the next iteration; `idle()` is there
        // because this return is ahead of the frame's only pacing wait.
        guard let timing = frame.predictTiming() else { idle(); return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        if pipelines == nil {
            buildPipelines()
        }

        // Late latch: the device pose is sampled here, after the input-time
        // wait, immediately before matrix composition and encode. This is
        // where CompositorServices says to do it —
        // `cp_drawable_set_device_anchor`: "you must predict the device
        // anchor in advance using available information. The
        // cp_frame_timing_get_optimal_input_time function provides a good
        // time to start the prediction for each frame."
        //
        // Sampled before the drawable is taken only because the skip
        // decision needs it; the drawable is taken either way now. That
        // puts the sample a drawable-query earlier than Apple's template
        // and `world_tracking.h`'s own example do it, which adds that
        // query's duration to the prediction distance -- sub-millisecond
        // after the input-time wait, but measured on device by looking for
        // new swim on a fast head turn rather than asserted here.
        let anchorTime = seconds(from: timing.presentationTime)
        let deviceAnchor = anchors.anchor(at: anchorTime)
        if deviceAnchor == nil {
            skippedFrames += 1
            if hadAnchor {
                hadAnchor = false
                print("[immersive] no device anchor -- skipping frames until tracking returns")
            }
        } else if !hadAnchor {
            hadAnchor = true
            print("[immersive] device anchor back after \(skippedFrames) skipped frame(s)")
            skippedFrames = 0
        }

        // The drawable is taken BEFORE the submission starts, and the
        // cancelled case is the reason. `cp_frame_query_drawables`: "the
        // array will have a count of 0 and frame is invalid" when the layer
        // is in the paused or invalidated state, and "the frame should be
        // discarded and is invalid to access" -- so there is no
        // `endSubmission` available on that frame. Querying after
        // `startSubmission` therefore left a STARTED submission that could
        // never be closed, and a layer dying under a sleeping device hands
        // back empty arrays frame after frame: three of them spent the
        // in-flight budget and aborted the process. Device-confirmed
        // 2026-10-16, taking the headset off and letting it sleep.
        //
        // The license is position-sensitive, which is the whole lesson
        // here: "discard the frame" is only free while nothing has been
        // started on it.
        //
        // Querying here is within the written contract --
        // `cp_frame_start_submission` says "Call this function before you
        // start any of the GPU work that depends on the input data", and a
        // drawable query is not GPU work -- and it is the order Apple's own
        // immersive-Metal template uses.
        guard let drawable = frame.queryDrawables().first else {
            // Nothing started, nothing to close. run()'s state machine
            // parks or exits on the next iteration.
            return
        }

        // The LAST fallible acquisition, and it is here rather than inside
        // the submission for the reason documented above the function: a nil
        // command buffer swallowed by an optional chain between
        // `startSubmission` and `endSubmission` presented nothing and
        // aborted inside `cp_frame_end_submission`.
        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else {
            if !loggedNoCommandBuffer {
                loggedNoCommandBuffer = true
                print("[immersive] cannot present (no command buffer) -- layer dying?")
            }
            // No submission opened, so nothing illegal; the frame is left in
            // flight on purpose. See the trade in the note above.
            return
        }

        // ---- The submission window. No guard, no early return, no
        // ---- optional chain from here to `endSubmission`.
        frame.startSubmission()

        var consumerHeld = false
        if let pipelines, let deviceAnchor {
            // A stale pose is worse than none, so the bare path below sets
            // no anchor at all -- see the coast-vs-skip note on
            // TrackRecorder in `encode`.
            drawable.deviceAnchor = deviceAnchor
            reportViewGeometry(for: drawable)
            consumerHeld = core.withConsumer(.immersive) { () -> Bool in
                let mipCandidates = core.drainTextureQueues()
                if !mipCandidates.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
                    for texture in mipCandidates {
                        blit.generateMipmaps(for: texture)
                    }
                    blit.endEncoding()
                }

                let packet = QC_RendererAcquireFrame()
                defer { if packet != nil { QC_RendererReleaseFrame() } }

                encode(packet: packet?.pointee, drawable: drawable,
                       deviceAnchor: deviceAnchor, pipelines: pipelines,
                       commandBuffer: commandBuffer)

                commandBuffer.addCompletedHandler { [weak self] buffer in
                    self?.recordGPUTime(buffer.gpuEndTime - buffer.gpuStartTime)
                }
                return true
            } ?? false
        }

        // ONE present, ONE commit, ONE endSubmission, on every path. If the
        // block above did not run -- no anchor, no pipelines, or the packet
        // stream was handed to another consumer mid-frame -- the drawable
        // goes back bare, which is what the skip path has always been.
        drawable.encodePresent(commandBuffer: commandBuffer)
        commandBuffer.commit()
        frame.endSubmission()
        // ---- End of the submission window.

        if consumerHeld {
            recordFrameStats()
        } else if !loggedBarePresent {
            // One line per session, on the rare path, so a device stream
            // says WHICH precondition fed a bare present rather than
            // leaving it to be inferred from the absence of fps lines.
            loggedBarePresent = true
            print("[immersive] bare present"
                + " anchor=\(deviceAnchor != nil ? 1 : 0)"
                + " pipelines=\(pipelines != nil ? 1 : 0)"
                + " consumer=0")
        }
    }

    // MARK: - Encoding

    private func encode(packet: qc_frame_t?,
                        drawable: LayerRenderer.Drawable,
                        deviceAnchor: DeviceAnchor?,
                        pipelines: RenderPipelines,
                        commandBuffer: MTLCommandBuffer) {
        let views = drawable.views
        let rawOriginFromDevice = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        // The first tracked pose after the space opens becomes neutral —
        // wherever the head is, that is now the player's eye. Without this
        // the tracking origin's arbitrary placement (metres away, in the
        // simulator) feeds in as a giant head offset and drags the player
        // across the map the moment the space opens.
        if deviceAnchor != nil, !zeroedInitialPose {
            zeroedInitialPose = true
            recenterCorrection = Self.correction(zeroing: rawOriginFromDevice)
            TrackingSpace.setCorrection(recenterCorrection)
        }
        if let packet, packet.recenter_count != recenterSeen {
            recenterSeen = packet.recenter_count
            recenterCorrection = Self.correction(zeroing: rawOriginFromDevice)
            TrackingSpace.setCorrection(recenterCorrection)
        }
        let originFromDevice = recenterCorrection * rawOriginFromDevice

        // Publish the eye position (corrected-tracking space, same frame as the
        // debug hands / turn gauge) so on-hand HUD can billboard toward it.
        let eyeCol = originFromDevice.columns.3
        ViewerPose.shared.setEye(SIMD3(eyeCol.x, eyeCol.y, eyeCol.z))

        // Output channel: haptic pulses (damage rises) and the per-weapon
        // trigger feel follow the packet; the wheel learns what the player
        // owns from the same source of truth the ring is built from.
        if let packet {
            ControllerOutput.shared.frame(damageFlash: packet.damage_flash,
                                          activeWeapon: packet.active_weapon,
                                          fireSeq: packet.weapon_fire_seq)
            WheelState.shared.frame(items: packet.items,
                                    worldScale: packet.world_scale)
            WeaponTrim.shared.frame(activeWeapon: packet.active_weapon)
        }

        // World->tracking-origin: the Quake BODY basis, scaled to metres —
        // yaw only (packet.body_yaw), because pitch and roll belong to the
        // head. This is deliberately the body, NOT the aim (viewangles): the
        // gun and the shot follow the hand ray, but the eye never does.
        // The anchor sits at vieworg minus what the engine already absorbed
        // of the head offset — absorption walks the box, not the eye — and
        // the un-absorbed lean is clamped to the packet's limit so the head
        // stops at the wall that refused the body.
        var originFromQuake = matrix_identity_float4x4
        var quakeFromOrigin = matrix_identity_float4x4
        if let packet {
            let s = packet.world_scale > 0 ? packet.world_scale : 0.0254

            // Body-frame head offset in Quake units: the tracking origin's
            // axes are the body's (yaw is baked into the basis below). Only
            // the horizontal offset walks the player box; the vertical is
            // the real head height and drives the camera height directly.
            let d = originFromDevice.columns.3
            let fwd = -d.z / s
            let right = d.x / s
            let up = d.y / s   // metres-scaled head height above the floor
            QC_InputSetHeadOffset(fwd, right, up, packet.recenter_count)

            // Head yaw relative to the body, for look-relative locomotion:
            // the head forward in the (yaw-only) tracking frame is already
            // body-relative. Quake yaw is CCW/left-positive.
            let hf = originFromDevice * SIMD4<Float>(0, 0, -1, 0)
            let headYaw = atan2(-hf.x, -hf.z) * 180 / .pi
            QC_InputSetHeadYaw(headYaw)

            // Head pitch (vr_headaim fallback): elevation of the head
            // forward, negated into Quake's sense where +pitch looks DOWN.
            let horiz = (hf.x * hf.x + hf.z * hf.z).squareRoot()
            let headPitch = -atan2(hf.y, horiz) * 180 / .pi
            QC_InputSetHeadPitch(headPitch)
            // Same frame and sense as the aim angles, so "sight in" can take
            // the difference directly. See AimCalibration.
            AimCalibration.shared.noteHead(yaw: headYaw, pitch: headPitch)

            // M6 aim: the dominant Sense controller's 6DOF pose becomes the
            // shot ray. Corrected into the recenter-neutral frame (the same
            // correction the head uses), then to Quake's body-frame angles:
            // yaw CCW/left-positive relative to room forward (the engine adds
            // the body yaw), pitch positive-down, and the muzzle origin in
            // body-frame Quake units. Hands feed the same setter from
            // HandInput; when neither is present the engine falls back to the
            // body-anchored aim. Controller forward is -Z.
            let rightHanded = VRSettings.shared.rightHanded
            if let domPose = SpatialControllerTracker.shared.pose(left: !rightHanded) {
                let c = recenterCorrection * domPose
                let o = c.columns.3
                let fwd0 = -c.columns.2          // controller forward, corrected
                let aimYaw = atan2(-fwd0.x, -fwd0.z) * 180 / .pi
                let aimHoriz = (fwd0.x * fwd0.x + fwd0.z * fwd0.z).squareRoot()
                let aimPitch = -atan2(fwd0.y, aimHoriz) * 180 / .pi
                TrackRecorder.shared.feedAim(valid: true, origin: SIMD3(-o.z / s, o.x / s, o.y / s),
                                             yaw: aimYaw, pitch: aimPitch)
            }

            // Off-hand presence model, CONTROLLER mode only. The ARKit hand
            // session is off then (no joints), but the controller pose is
            // tracked, so pose a rigid hand on the OFF controller. Only publish
            // while controllers track -- in hands-only mode HandInput owns
            // VirtualHand and we must not fight it. The gun hand gets no model.
            if SpatialControllerTracker.shared.isTracking,
               let offPose = SpatialControllerTracker.shared.pose(left: rightHanded) {
                // Fold the handshake-angle offset (tuned on device) into the
                // pose, in the controller-local frame -- so it rotates the hand
                // relative to the controller, not the world.
                let d = Float.pi / 180
                let rx = simd_quatf(angle: VRSettings.shared.offHandPitch * d, axis: [1, 0, 0])
                let ry = simd_quatf(angle: VRSettings.shared.offHandYaw * d, axis: [0, 1, 0])
                let rz = simd_quatf(angle: VRSettings.shared.offHandRoll * d, axis: [0, 0, 1])
                let rot = simd_float4x4(ry * rx * rz)
                VirtualHand.shared.publish(
                    ControllerHandModel.posed(by: recenterCorrection * offPose * rot,
                                              leftHand: rightHanded))
            }

            let yaw = packet.body_yaw * .pi / 180
            let fwdW = SIMD2(cos(yaw), sin(yaw))
            let rightW = SIMD2(sin(yaw), -cos(yaw))
            let offsetW = fwd * fwdW + right * rightW
            let absorbed = SIMD2(packet.head_absorbed.0, packet.head_absorbed.1)
            let excess = offsetW - absorbed
            let excessLen = simd_length(excess)
            let overLimit = excessLen > packet.lean_limit && excessLen > 0
                ? excess * ((excessLen - packet.lean_limit) / excessLen)
                : SIMD2<Float>(0, 0)

            // Eye-locked baseline: the anchor (Quake point at the tracking
            // origin) is the game eye, trimmed up/down by the live height
            // knob. Vertical head motion moves the eye from here naturally.
            // + raises the viewpoint (taller), - lowers it. Fed to the
            // engine too, so the wrist-locked wheel rises with the camera.
            let heightTrim = VRSettings.shared.heightOffset / s
            QC_InputSetHeightTrim(heightTrim)
            let anchor = SIMD3(packet.vieworg.0 - absorbed.x - overLimit.x,
                               packet.vieworg.1 - absorbed.y - overLimit.y,
                               packet.vieworg.2 + heightTrim)
            let quakeView = RendererCore.quakeViewMatrix(
                origin: anchor,
                angles: SIMD3(0, packet.body_yaw, 0))
            let scale = simd_float4x4(diagonal: SIMD4(s, s, s, 1))
            originFromQuake = scale * quakeView
            quakeFromOrigin = originFromQuake.inverse
            // Sidecar: the head in Quake space from the same late-latched
            // pose the eyes use, keyed on the packet's clock (see VRTrack).
            TrackRecorder.shared.noteFrame(
                clTime: packet.time,
                quakeFromHead: quakeFromOrigin * originFromDevice,
                worldScale: s, bodyYaw: packet.body_yaw,
                headOffset: SIMD3(fwd, right, up), heightTrim: heightTrim)
        }

        // Dissolve origin: the head itself (the device anchor), mapped into
        // Quake space with the same late-latched pose the view matrices
        // use, so the sphere tracks the head with no lag. Radius and sky
        // fade come from the packet — the engine owns the phase clock.
        let headQuake = quakeFromOrigin * originFromDevice.columns.3
        let phaseParams = RendererCore.PhaseParams(
            headorg: SIMD3(headQuake.x, headQuake.y, headQuake.z),
            radius: packet?.phase_radius ?? 0,
            skyFade: 1 - (packet?.phase ?? 0),
            rimColor: packet.map { SIMD3($0.phase_color.0, $0.phase_color.1, $0.phase_color.2) }
                ?? SIMD3(1.5, 0.93, 0.27))

        var eyeViewproj: [simd_float4x4] = []
        var eyeOrigin: [SIMD4<Float>] = []
        var handViewproj: [simd_float4x4] = []   // tracking->clip, ignores height trim
        for index in views.indices {
            let originFromEye = originFromDevice * views[index].transform
            let projection = drawable.computeProjection(viewIndex: index)
            eyeViewproj.append(projection * originFromEye.inverse * originFromQuake)
            handViewproj.append(projection * originFromEye.inverse)
            // Per-eye view origin back in Quake units, for the sky
            // projection — this is what keeps the sky from mismatching
            // between the eyes.
            eyeOrigin.append(quakeFromOrigin * originFromEye.columns.3)
        }

        // Alpha contract for mixed immersion, worked out once so nobody has
        // to re-derive it (see 181e113 for what silent colour assumptions
        // cost): the compositor samples the sRGB target (rgb decoded to
        // linear, alpha as-is) and expects PREMULTIPLIED linear rgb.
        //  - Clear is (0,0,0,0): fully transparent passthrough, which is
        //    also the only valid premultiplied zero-alpha value. The
        //    engine's clear_color (gl_clear / r_clearcolor) is advisory
        //    here — the flat window still honours it.
        //  - Opaque draws write alpha 1; rgb premultiplied by 1 is itself.
        //  - Translucent draws are straight-alpha sources blended
        //    srcAlpha/1-srcAlpha over premultiplied dst — which yields the
        //    correct premultiplied result — with alpha accumulating as
        //    src + dst*(1-src) ("over"), so water over a wall stays
        //    alpha 1 and water over passthrough keeps its own coverage.
        // Seal the world during normal play. A Quake level is a closed box;
        // the only intended see-through is the phase melt. But brush seams
        // (stair T-junctions) leave sub-pixel cracks that, over a transparent
        // clear, leak the real room -- the passthrough band that walks up the
        // stairs. Clear to OPAQUE black so those gaps read black instead, and
        // fade the clear to transparent as phase runs so the melt still
        // reveals passthrough.
        // Always FULLY OPAQUE. A Quake level is a sealed box; brush-seam
        // cracks must read black, never leak passthrough. The phase melt
        // reveals passthrough by making the melting SURFACES transparent
        // (world_phase_fragment), not by thinning this clear -- tying the
        // clear alpha to phase leaked everywhere the moment phase went
        // nonzero (crown/effect-driven), which is the stair bug.
        let clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)

        // Hand debug wireframe: the published bones are already in
        // corrected-tracking space; drawn with handViewproj they sit on the
        // real hand, untouched by the game-world height trim.
        let handOverlays = HandDebug.shared.enabled || HandDebug.shared.aimRays
            || HandDebug.shared.strobe || HandDebug.shared.turnDebug || HandDebug.shared.fireDebug
        let handDebug: [Float] = handOverlays ? HandDebug.shared.snapshot() : []

        // The virtual hand stands in while the world is solid and fades out
        // (1 - phase) as the melt reveals the real hand through passthrough.
        // Same corrected-tracking space and handViewproj as the debug bones.
        // Suppressed while the green wireframe is up -- otherwise the solid
        // skin/cuff hand draws over the wireframe (the stray skin/blue polys).
        let virtualHand: [Float] = HandDebug.shared.enabled ? [] : VirtualHand.shared.snapshot()
        let handOpacity: Float = 1 - (packet?.phase ?? 0)

        // HUD live editor (Task 4): the editor's placement state
        // (HudEditor.shared) lives on an @MainActor @Observable session;
        // this is a dedicated render thread, so it is never touched
        // directly here. `HudEditor.Session.renderSnapshot()` is a
        // lock-protected plain-value mirror the session republishes on
        // every `active`/`working`/`grab` change -- the exact pattern
        // `GunHand`/`OffHandWrist` already use for hand poses (HandInput.
        // swift) -- taken once per frame and shared by every branch below.
        let editorSnapshot = HudEditor.Session.renderSnapshot()

        // 2D HUD panel (vr_hud): wrist or float, in the SAME corrected
        // tracking space and handViewproj as the hand debug/virtual hand
        // above -- a world-space panel built once per frame, composed with
        // each eye's handViewproj at the draw call below. Suppressed while
        // the editor is active: the workbench below replaces it, and
        // drawing both would overlap.
        let hudModel: simd_float4x4? = editorSnapshot.active ? nil : packet.flatMap {
            hudPanelModel(packet: $0, originFromDevice: originFromDevice,
                         headPoseAvailable: deviceAnchor != nil)
        }

        // The menu/console panel, resolved once per frame beside the HUD
        // panel above and shared by both eyes and both pass layouts. nil on
        // every ordinary playing frame (the engine's range is empty), which
        // is what keeps an idle frame free.
        //
        // Deliberately NOT suppressed while the HUD editor is open, unlike
        // hudModel: the editor is render-side session state the engine knows
        // nothing about, so it cannot stop the engine putting a menu up --
        // and if a menu is up, it is how the player gets out of wherever
        // they are.
        let screen2dModel: simd_float4x4? = packet.flatMap {
            screen2dPanelModel(packet: $0, originFromDevice: originFromDevice,
                               headPoseAvailable: deviceAnchor != nil)
        }

        // The two wrist-grid frames + the free gun/float anchors, resolved
        // ONCE this frame and shared by the live tiles, the edit-mode grid,
        // and the published hit-test geometry, so all three agree on where a
        // wrist sits. An untracked wrist comes back invalid, not NaN.
        let wristFramePair = wristFrames()
        let gunFreeAnchor = gunAnchorFrame()
        let floatAnchor = floatAnchorFrame(originFromDevice: originFromDevice,
                                           headPoseAvailable: deviceAnchor != nil,
                                           distance: Self.floatDistance,
                                           lowerOffset: Self.floatLowerOffset)

        // Modular HUD tiles (vr_hud 3): per-tile model matrices in the SAME
        // corrected tracking space as hudModel above, resolved once and
        // shared by both eyes/branches below. Empty whenever hud_mode != 3
        // (hudTileModels itself guards that), so drawHudTiles is always
        // safe to call unconditionally -- it no-ops for modes 0/1/2. While
        // the editor is active the tiles ride their EDITED wrist cells (a
        // grabbed tile follows the grab point) via `wristGridTileModels`;
        // otherwise the live path places each tile at its packet anchor/cell.
        let tileModels: [simd_float4x4?] = packet.map {
            editorSnapshot.active
                ? wristGridTileModels(packet: $0, wrists: wristFramePair, gunFree: gunFreeAnchor,
                                     float_: floatAnchor, snapshot: editorSnapshot)
                : hudTileModels(packet: $0, wrists: wristFramePair, gunFree: gunFreeAnchor,
                               float_: floatAnchor)
        } ?? []

        // The edit-mode grid: four filled 2x2 cell backings on each tracked
        // forearm, the cell under the grab point and the grabbed tile's drop
        // footprint tinted brighter. Empty while the editor is inactive.
        let gridQuads: [GridCellQuad] = editorSnapshot.active
            ? wristGridFurniture(wrists: wristFramePair, snapshot: editorSnapshot)
            : []

        // The two wrist frames + each visible tile's cell quad, published for
        // the grab/drop input layer (Task 5, HudEditorInput.swift) -- it runs
        // its own ARKit hand/controller loop, with no independent way to
        // reconstruct a head/wrist-anchored frame (this render thread is the
        // only place `originFromDevice`/`deviceAnchor`/the wrist poses exist),
        // so it reads this snapshot instead of recomputing it. See
        // `WorkbenchGeometry`'s own doc comment for the cross-loop pattern.
        publishWorkbenchGeometry(packet: packet, wrists: wristFramePair, gunFree: gunFreeAnchor,
                                 float_: floatAnchor, snapshot: editorSnapshot)

        // Wrist communicator: the 2x3 action grid seated below the HUD tiles
        // on each enabled wrist, revealed by a glance. Built from the SAME
        // `wristFramePair` the tiles above sit on, so the comm can never
        // drift off the plane it is supposed to hang under. Reveal needs the
        // FULL head forward -- not the yaw-flattened one `floatAnchorFrame`
        // uses, since you look DOWN at your wrist -- which in this
        // convention is the device transform's third column negated (the
        // same -Z the head-yaw/pitch feed above takes). `originFromDevice`
        // is identity when the pose is missing, hence the explicit
        // availability flag rather than trusting the matrix.
        let commHeadForward = -originFromDevice.columns.2
        let commFurniture = updateWristComm(
            wrists: wristFramePair,
            headPos: SIMD3(eyeCol.x, eyeCol.y, eyeCol.z),
            headForward: SIMD3(commHeadForward.x, commHeadForward.y, commHeadForward.z),
            headPoseAvailable: deviceAnchor != nil,
            engineLive: packet != nil,
            editorActive: editorSnapshot.active)

        if singlePassStereo, views.count == 2 {
            let descriptor = passDescriptor(
                for: drawable, textureIndex: 0, slice: nil, clear: clear)
            descriptor.renderTargetArrayLength = 2
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else { return }
            if let packet {
                let uniforms = RendererCore.WorldUniforms(
                    viewproj0: eyeViewproj[0], viewproj1: eyeViewproj[1],
                    eyeorg0: eyeOrigin[0], eyeorg1: eyeOrigin[1])
                core.encode(frame: packet, with: encoder, pipelines: pipelines,
                            uniforms: uniforms, phase: phaseParams,
                            amplificationCount: 2, drawsViewmodel: false)
                core.drawVirtualHand(virtualHand, opacity: handOpacity,
                                     viewproj0: handViewproj[0], viewproj1: handViewproj[1],
                                     pipelines: pipelines, encoder: encoder)
                core.drawHandDebug(handDebug, viewproj0: handViewproj[0], viewproj1: handViewproj[1],
                                   pipelines: pipelines, encoder: encoder)
                if let hudModel {
                    core.drawOverlay(frame: packet,
                                     viewproj0: handViewproj[0] * hudModel,
                                     viewproj1: handViewproj[1] * hudModel,
                                     pipelines: pipelines, encoder: encoder)
                }
                // Grid cells first (translucent, behind): the tiles draw an
                // opaque backing, so a cell drawn over a tile would wash it.
                if !gridQuads.isEmpty {
                    drawWristGrid(gridQuads, conchars: packet.conchars_texnum,
                                  viewproj0: handViewproj[0], viewproj1: handViewproj[1],
                                  pipelines: pipelines, encoder: encoder)
                }
                core.drawHudTiles(frame: packet, tileModels: tileModels,
                                  viewproj0: handViewproj[0], viewproj1: handViewproj[1],
                                  pipelines: pipelines, encoder: encoder)
                // Communicator last: it is its own device, seated BELOW the
                // tiles, and its bezel must read over whatever it overlaps
                // rather than under it.
                drawWristComm(commFurniture.quads, conchars: packet.conchars_texnum,
                              viewproj0: handViewproj[0], viewproj1: handViewproj[1],
                              pipelines: pipelines, encoder: encoder)
                // The pressing finger, after the unit: it is depth-always
                // (drawHandDebug), so it reads over the key it is on rather
                // than disappearing into the bezel.
                core.drawHandDebug(commFurniture.finger,
                                   viewproj0: handViewproj[0], viewproj1: handViewproj[1],
                                   pipelines: pipelines, encoder: encoder)
                // The menu/console panel LAST, over the HUD and the
                // communicator both: while it is up it is the thing being
                // read and operated, and every 2D layer here is
                // depth-always, so paint order is what decides.
                if let screen2dModel {
                    core.drawScreen2D(frame: packet,
                                      viewproj0: handViewproj[0] * screen2dModel,
                                      viewproj1: handViewproj[1] * screen2dModel,
                                      pipelines: pipelines, encoder: encoder)
                }
            }
            encoder.endEncoding()
        } else {
            // One pass per view: the dedicated layout (separate textures)
            // and the no-amplification fallback (separate slices) both
            // route through view.textureMap.
            for index in views.indices {
                let map = views[index].textureMap
                let descriptor = passDescriptor(
                    for: drawable,
                    textureIndex: Int(map.textureIndex),
                    slice: Int(map.sliceIndex),
                    clear: clear)
                guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
                else { continue }
                if let packet {
                    let uniforms = RendererCore.WorldUniforms(
                        viewproj0: eyeViewproj[index], viewproj1: eyeViewproj[index],
                        eyeorg0: eyeOrigin[index], eyeorg1: eyeOrigin[index])
                    core.encode(frame: packet, with: encoder, pipelines: pipelines,
                                uniforms: uniforms, phase: phaseParams,
                                amplificationCount: 1, drawsViewmodel: false)
                    core.drawVirtualHand(virtualHand, opacity: handOpacity,
                                         viewproj0: handViewproj[index], viewproj1: handViewproj[index],
                                         pipelines: pipelines, encoder: encoder)
                    core.drawHandDebug(handDebug, viewproj0: handViewproj[index], viewproj1: handViewproj[index],
                                       pipelines: pipelines, encoder: encoder)
                    if let hudModel {
                        let hv = handViewproj[index] * hudModel
                        core.drawOverlay(frame: packet, viewproj0: hv, viewproj1: hv,
                                         pipelines: pipelines, encoder: encoder)
                    }
                    // Grid cells first (translucent, behind the opaque tiles).
                    if !gridQuads.isEmpty {
                        drawWristGrid(gridQuads, conchars: packet.conchars_texnum,
                                      viewproj0: handViewproj[index], viewproj1: handViewproj[index],
                                      pipelines: pipelines, encoder: encoder)
                    }
                    core.drawHudTiles(frame: packet, tileModels: tileModels,
                                      viewproj0: handViewproj[index], viewproj1: handViewproj[index],
                                      pipelines: pipelines, encoder: encoder)
                    // Communicator last, as in the single-pass branch above.
                    drawWristComm(commFurniture.quads, conchars: packet.conchars_texnum,
                                  viewproj0: handViewproj[index], viewproj1: handViewproj[index],
                                  pipelines: pipelines, encoder: encoder)
                    core.drawHandDebug(commFurniture.finger,
                                       viewproj0: handViewproj[index], viewproj1: handViewproj[index],
                                       pipelines: pipelines, encoder: encoder)
                    // The menu/console panel last, as in the single-pass
                    // branch above.
                    if let screen2dModel {
                        let sv = handViewproj[index] * screen2dModel
                        core.drawScreen2D(frame: packet, viewproj0: sv, viewproj1: sv,
                                          pipelines: pipelines, encoder: encoder)
                    }
                }
                encoder.endEncoding()
            }
        }
    }

    private func passDescriptor(for drawable: LayerRenderer.Drawable,
                                textureIndex: Int,
                                slice: Int?,
                                clear: MTLClearColor) -> MTLRenderPassDescriptor {
        let descriptor = MTLRenderPassDescriptor()
        descriptor.colorAttachments[0].texture = drawable.colorTextures[textureIndex]
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store
        descriptor.colorAttachments[0].clearColor = clear
        descriptor.depthAttachment.texture = drawable.depthTextures[textureIndex]
        descriptor.depthAttachment.loadAction = .clear
        descriptor.depthAttachment.storeAction = .store
        // CompositorServices depth is reversed: 1 at the near plane, 0 at
        // the far. computeProjection bakes it; clear to far accordingly.
        descriptor.depthAttachment.clearDepth = 0
        if let slice {
            descriptor.colorAttachments[0].slice = slice
            descriptor.depthAttachment.slice = slice
        }
        if drawable.rasterizationRateMaps.indices.contains(textureIndex) {
            descriptor.rasterizationRateMap = drawable.rasterizationRateMaps[textureIndex]
        }
        return descriptor
    }

    private func buildPipelines() {
        let configuration = layerRenderer.configuration

        singlePassStereo = configuration.layout == .layered
            && core.device.supportsVertexAmplificationCount(2)

        // Quake's colors are sRGB-authored: linearize at fragment output so
        // the sRGB (or float) target displays them like the flat window.
        pipelines = core.makePipelines(
            colorFormat: configuration.colorFormat,
            depthFormat: configuration.depthFormat,
            amplified: singlePassStereo,
            reverseDepth: true,
            linearOutput: true)

        if !loggedSetup {
            loggedSetup = true
            print("[immersive] layout=\(configuration.layout) foveation=\(configuration.isFoveationEnabled) singlePassStereo=\(singlePassStereo) color=\(configuration.colorFormat.rawValue)")
        }
    }

    // MARK: - HUD panel placement (vr_hud)

    /// Panel sizes keep the overlay's 320x200 aspect (1.6:1) so the status
    /// bar isn't stretched. Device-tuned; nudge on device, not guessed here.
    private static let wristPanelWidth: Float = 0.22
    private static let wristPanelHeight: Float = 0.1375
    /// Lift the panel off the wrist along its own "up" so it doesn't clip
    /// into the forearm.
    private static let wristLift: Float = 0.03
    private static let floatPanelWidth: Float = 0.8
    private static let floatPanelHeight: Float = 0.5
    private static let floatDistance: Float = 1.5
    /// Dropped below eye level so the float panel reads as a lower-centre
    /// HUD rather than sitting on the forward sightline. This is the float
    /// panel's vertical device-tune knob: larger drops it further down, so
    /// you glance DOWN to read it instead of up. (0.25 sat too high -- the
    /// bar is the bottom strip of the plane, so the readable content needs
    /// the whole panel centre pulled well below the gaze.)
    private static let floatLowerOffset: Float = 0.6
    /// Metres per tile-local unit for modular HUD tiles (vr_hud 3): the
    /// same per-pixel ratio `wristPanelWidth` uses over the full 320px
    /// virtual screen, so a compact tile (e.g. AMMO's 72x24 bbox) comes out
    /// a plausible wrist-icon size rather than needing its own device-tune
    /// pass. `tile.scale` multiplies on top of this.
    private static let hudTilePixelScale: Float = wristPanelWidth / 320
    /// How far ahead of the gun hand (controller grip) a gun-anchored tile
    /// floats, along the same "toward the eye" billboard normal the wrist
    /// tile uses — enough to clear the modelled weapon without the tile
    /// overlapping it. Device-tunable like the other HUD placement
    /// constants above.
    private static let gunTileLift: Float = 0.08

    /// The menu/console panel (`screen2d`). Closer and smaller than the
    /// float HUD above, and much closer to the sightline, because it is
    /// something you read and operate rather than glance at: a menu you have
    /// to look down 0.6 m to use is the wrong object. 0.9 x 0.5625 m keeps
    /// the overlay plane's 320x200 aspect, so the plaque and the menu items
    /// are not stretched, and at 1.2 m that is roughly a 40-degree-wide
    /// panel — a comfortable reading size. All four are device-tune knobs
    /// like the HUD's.
    private static let screen2dPanelWidth: Float = 0.9
    private static let screen2dPanelHeight: Float = 0.5625
    private static let screen2dDistance: Float = 1.2
    /// Dropped only slightly below eye level: enough that the panel is not
    /// dead centre in the view, not so far that reading it means looking at
    /// the floor (contrast `floatLowerOffset`, which deliberately parks the
    /// status bar well down).
    private static let screen2dLowerOffset: Float = 0.15

    /// This frame's whole-panel HUD model matrix (overlay-space -> corrected
    /// tracking space), or nil to draw nothing. `hud_mode == 0` is off;
    /// `hud_mode == 1` (wrist) anchors to the off-hand and billboards
    /// toward the eye, falling back to the float placement the instant the
    /// off-hand isn't tracked (Review Focus #3: never anchor to a stale or
    /// zero pose); `hud_mode == 2` floats ahead of the head, yaw+level only
    /// — no pitch, mirroring `QR_EmitCenterPrint`'s placement basis class.
    /// Picked once per frame and shared by both eyes. `hud_mode == 3`
    /// (modular tiles) is deliberately EXCLUDED here — it has no single
    /// panel to place; see `hudTileModels` for the per-tile placement that
    /// replaces this for that mode.
    private func hudPanelModel(packet: qc_frame_t, originFromDevice: simd_float4x4,
                               headPoseAvailable: Bool) -> simd_float4x4? {
        guard packet.hud_mode == 1 || packet.hud_mode == 2 else { return nil }

        if packet.hud_mode == 1, let wrist = offHandWristPosition() {
            let eye = ViewerPose.shared.eye
            let toEye = eye - wrist
            let toward = simd_length(toEye) > 1e-4 ? simd_normalize(toEye) : SIMD3<Float>(0, 0, 1)
            let basis = RendererCore.billboardBasis(toward: toward)
            let origin = wrist + basis.up * Self.wristLift
            return RendererCore.hudPanelModel(origin: origin, right: basis.right, up: basis.up,
                                              widthMeters: Self.wristPanelWidth,
                                              heightMeters: Self.wristPanelHeight)
        }

        // Float placement: hud_mode == 2 outright, or the wrist mode's
        // fallback this frame because the off-hand isn't tracked. Hide
        // entirely if even the head pose is unavailable -- there is nothing
        // sane left to anchor to.
        guard headPoseAvailable else { return nil }
        let headPos = originFromDevice.columns.3
        let headForward4 = originFromDevice * SIMD4<Float>(0, 0, -1, 0)
        let flatForward = SIMD3(headForward4.x, 0, headForward4.z)
        let forward = simd_length(flatForward) > 1e-4 ? simd_normalize(flatForward) : SIMD3<Float>(0, 0, -1)
        let origin = SIMD3(headPos.x, headPos.y, headPos.z)
            + forward * Self.floatDistance
            - SIMD3<Float>(0, Self.floatLowerOffset, 0)
        // toward is horizontal by construction, so billboardBasis's "up"
        // comes out as world-up exactly -- level, no pitch, no roll.
        let basis = RendererCore.billboardBasis(toward: -forward)
        return RendererCore.hudPanelModel(origin: origin, right: basis.right, up: basis.up,
                                          widthMeters: Self.floatPanelWidth,
                                          heightMeters: Self.floatPanelHeight)
    }

    /// The off-hand wrist position for the wrist-mode panel, corrected
    /// tracking space: the Sense controller pose when controllers are
    /// tracking (the same source the off-hand rigid-hand model reads,
    /// above), else the ARKit wrist `HandInput` publishes continuously
    /// whenever hands are the active input (see `OffHandWrist`). nil when
    /// neither source currently has the off-hand -- the caller's cue to
    /// fall back to the float placement.
    private func offHandWristPosition() -> SIMD3<Float>? {
        let rightHanded = VRSettings.shared.rightHanded
        if SpatialControllerTracker.shared.isTracking,
           let offPose = SpatialControllerTracker.shared.pose(left: rightHanded) {
            let p = recenterCorrection * offPose.columns.3
            return SIMD3(p.x, p.y, p.z)
        }
        let snap = OffHandWrist.shared.snapshot()
        return snap.valid ? snap.position : nil
    }

    // MARK: - Modular HUD tile placement (vr_hud 3)

    /// The two wrist-grid frames this frame: the off-hand and gun-hand
    /// forearm planes, each billboarded toward the eye and lifted by
    /// `wristLift`. Resolved once per frame and shared by the live tiles, the
    /// edit-mode grid draw, and the published hit-test geometry, so all three
    /// agree on where a wrist sits. An untracked wrist comes back `valid ==
    /// false` (never NaN), with NO float fallback -- a wrist tile simply
    /// hides when its hand drops out of view rather than jumping to the face.
    private func wristFrames() -> (off: HudEditor.WristFrame, gun: HudEditor.WristFrame) {
        let editing = HudEditor.Session.renderSnapshot().active
        // Between edit sessions the held frames go stale; drop them so a new
        // session re-latches from a freshly seen wrist rather than an old pose.
        if !editing { lastOffWristFrame = nil; lastGunWristFrame = nil }
        let off = latchedWristFrame(
            live: wristFrame(anchor: Int(QC_HUD_ANCHOR_WRIST_OFF), position: offHandWristPosition()),
            held: &lastOffWristFrame, editing: editing)
        let gun = latchedWristFrame(
            live: wristFrame(anchor: Int(QC_HUD_ANCHOR_WRIST_GUN), position: gunPosition()),
            held: &lastGunWristFrame, editing: editing)
        return (off, gun)
    }

    /// Caches a valid live frame; while the editor is open, substitutes the
    /// last valid one when the live frame drops to invalid (the wrist got
    /// occluded by the reaching hand), so the grid stays a stable, grabbable
    /// target. Outside the editor an invalid wrist still hides the HUD -- it's
    /// been lowered out of view, which is the right behaviour there.
    private func latchedWristFrame(live: HudEditor.WristFrame,
                                   held: inout HudEditor.WristFrame?,
                                   editing: Bool) -> HudEditor.WristFrame {
        if live.valid {
            held = live
            return live
        }
        if editing, let held { return held }
        return live
    }

    /// One wrist-grid frame from a wrist world position (corrected tracking
    /// space), billboarded toward the eye and lifted along the billboard up.
    /// `nil` position -> an invalid frame (that wrist isn't tracked).
    private func wristFrame(anchor: Int, position: SIMD3<Float>?) -> HudEditor.WristFrame {
        guard let wrist = position else {
            return HudEditor.WristFrame(anchor: anchor, origin: .zero, right: .zero,
                                        up: .zero, forward: .zero, valid: false)
        }
        let eye = ViewerPose.shared.eye
        let toEye = eye - wrist
        let toward = simd_length(toEye) > 1e-4 ? simd_normalize(toEye) : SIMD3<Float>(0, 0, 1)
        let basis = RendererCore.billboardBasis(toward: toward)
        let origin = wrist + basis.up * Self.wristLift
        return HudEditor.WristFrame(anchor: anchor, origin: origin, right: basis.right,
                                    up: basis.up, forward: toward, valid: true)
    }

    /// One tile's resolved world placement: the quad centre + its own
    /// right/up plane and the physical size its source `bbox` maps onto.
    private struct TilePlacement {
        var origin: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var width: Float
        var height: Float
        var sourceWidth: Float
        var sourceHeight: Float
    }

    /// Resolves one tile's placement from its anchor + placement fields,
    /// shared by the live path, the edit-mode draw, and the published
    /// hit-test geometry so they never disagree. WRIST_OFF/WRIST_GUN tiles
    /// sit in their 2x2 grid cell (origin + `wristCellOffset`, sized to the
    /// cell footprint); GUN/FLOAT tiles keep the free-offset path (offset
    /// along the anchor's own axes, sized by `hudTilePixelScale`).
    /// `originOverride` pins the quad centre to a world point (a grabbed tile
    /// riding `grab.lastPoint`) while keeping the anchor frame's orientation
    /// and size. Returns nil when the needed anchor has no live frame.
    private func tilePlacement(tile: qc_hud_tile_t, anchor: Int, slot: Int, spanW: Int, spanH: Int,
                               scale: Float, offset: SIMD3<Float>, originOverride: SIMD3<Float>?,
                               wrists: (off: HudEditor.WristFrame, gun: HudEditor.WristFrame),
                               gunFree: RendererCore.HudAnchorFrame?,
                               float_: RendererCore.HudAnchorFrame?) -> TilePlacement? {
        let s = scale > 0 ? scale : 1
        switch anchor {
        case Int(QC_HUD_ANCHOR_WRIST_OFF), Int(QC_HUD_ANCHOR_WRIST_GUN):
            let frame = anchor == Int(QC_HUD_ANCHOR_WRIST_GUN) ? wrists.gun : wrists.off
            guard frame.valid else { return nil }
            let cell = HudEditor.wristCellOffset(slot: slot, spanW: spanW, spanH: spanH)
            let origin = originOverride
                ?? (frame.origin + frame.right * cell.offset.x + frame.up * cell.offset.y)
            // Preserve the tile's native aspect: contain-fit its bbox inside the
            // footprint box rather than stretching each axis to fill it, which
            // crushed the wide ammo tile (96x24) into a square cell. The
            // footprint still sets the base size; `s` fine-tunes. A footprint
            // change never alters the ratio, so the rectangle always returns.
            let bw = max(tile.bbox_w, 1), bh = max(tile.bbox_h, 1)
            let fit = min(cell.size.x / bw, cell.size.y / bh)
            return TilePlacement(origin: origin, right: frame.right, up: frame.up,
                                 width: bw * fit * s, height: bh * fit * s,
                                 sourceWidth: tile.bbox_w, sourceHeight: tile.bbox_h)
        case Int(QC_HUD_ANCHOR_GUN):
            guard let frame = gunFree else { return nil }
            let origin = originOverride
                ?? (frame.origin + frame.right * offset.x + frame.up * offset.y + frame.forward * offset.z)
            return TilePlacement(origin: origin, right: frame.right, up: frame.up,
                                 width: tile.bbox_w * Self.hudTilePixelScale * s,
                                 height: tile.bbox_h * Self.hudTilePixelScale * s,
                                 sourceWidth: tile.bbox_w, sourceHeight: tile.bbox_h)
        default:   // QC_HUD_ANCHOR_FLOAT
            guard let frame = float_ else { return nil }
            let origin = originOverride
                ?? (frame.origin + frame.right * offset.x + frame.up * offset.y + frame.forward * offset.z)
            return TilePlacement(origin: origin, right: frame.right, up: frame.up,
                                 width: tile.bbox_w * Self.hudTilePixelScale * s,
                                 height: tile.bbox_h * Self.hudTilePixelScale * s,
                                 sourceWidth: tile.bbox_w, sourceHeight: tile.bbox_h)
        }
    }

    private func model(from placement: TilePlacement) -> simd_float4x4 {
        RendererCore.hudPanelModel(origin: placement.origin, right: placement.right, up: placement.up,
                                   widthMeters: placement.width, heightMeters: placement.height,
                                   sourceWidth: placement.sourceWidth, sourceHeight: placement.sourceHeight)
    }

    /// This frame's per-tile model matrices for the LIVE modular HUD, one
    /// entry per `packet.hud_tiles[i]` (fixed order AMMO/FACE/HEALTHARMOR —
    /// see `qc_frame_t`'s doc comment), nil where that tile drew nothing this
    /// frame (`vert_count == 0`) or its anchor has no live pose right now.
    /// Placement comes straight from the packet's own anchor/slot/span/scale
    /// via `tilePlacement`; the wrist frames + free anchors are resolved once
    /// per frame by the caller and threaded in.
    private func hudTileModels(packet: qc_frame_t,
                               wrists: (off: HudEditor.WristFrame, gun: HudEditor.WristFrame),
                               gunFree: RendererCore.HudAnchorFrame?,
                               float_: RendererCore.HudAnchorFrame?) -> [simd_float4x4?] {
        guard packet.hud_mode == 3, packet.num_hud_tiles > 0, let tiles = packet.hud_tiles
        else { return [] }

        var models: [simd_float4x4?] = []
        for i in 0..<Int(packet.num_hud_tiles) {
            let tile = tiles[i]
            guard tile.vert_count > 0 else { models.append(nil); continue }
            let placement = tilePlacement(tile: tile, anchor: Int(tile.anchor), slot: Int(tile.slot),
                                          spanW: Int(tile.span_w), spanH: Int(tile.span_h),
                                          scale: tile.scale,
                                          offset: SIMD3(tile.offset.0, tile.offset.1, tile.offset.2),
                                          originOverride: nil,
                                          wrists: wrists, gunFree: gunFree, float_: float_)
            models.append(placement.map { model(from: $0) })
        }
        return models
    }

    /// FLOAT anchor frame for modular tiles: ahead of the head, yaw+level
    /// only — no pitch — same maths as `hudPanelModel`'s float branch above,
    /// reused here as its own anchor rather than a wrist fallback. nil when
    /// the head pose is unavailable: there is nothing sane left to anchor to
    /// (Review Focus #3).
    ///
    /// `distance`/`lowerOffset` are the caller's so the menu/console panel
    /// (`screen2dPanelModel`) can take this exact placement at its own
    /// distance and height instead of keeping a second copy of the maths —
    /// the two must stay the same CLASS of placement (head-locked, level,
    /// never pitched) while being free to sit in different places. The
    /// modular tiles' own call passes the HUD constants it has always used.
    private func floatAnchorFrame(originFromDevice: simd_float4x4,
                                  headPoseAvailable: Bool,
                                  distance: Float,
                                  lowerOffset: Float) -> RendererCore.HudAnchorFrame? {
        guard headPoseAvailable else { return nil }
        let headPos = originFromDevice.columns.3
        let headForward4 = originFromDevice * SIMD4<Float>(0, 0, -1, 0)
        let flatForward = SIMD3(headForward4.x, 0, headForward4.z)
        let forward = simd_length(flatForward) > 1e-4 ? simd_normalize(flatForward) : SIMD3<Float>(0, 0, -1)
        let origin = SIMD3(headPos.x, headPos.y, headPos.z)
            + forward * distance
            - SIMD3<Float>(0, lowerOffset, 0)
        // toward is horizontal by construction, so billboardBasis's "up"
        // comes out as world-up exactly -- level, no pitch, no roll.
        let basis = RendererCore.billboardBasis(toward: -forward)
        return RendererCore.HudAnchorFrame(origin: origin, right: basis.right, up: basis.up,
                                           forward: -forward)
    }

    /// This frame's menu/console panel model matrix (overlay space ->
    /// corrected tracking space), or nil to draw nothing.
    ///
    /// Head-locked and level, the same placement class as the float HUD and
    /// `QR_EmitCenterPrint` — it has to be reachable and readable from
    /// wherever the player is standing, and it is up while the game is
    /// paused, so anchoring it to anything in the world (or to a hand that
    /// is also working the controller) would be wrong.
    ///
    /// Gated on `RendererCore.hasScreen2D` — the shared answer to "is the
    /// engine saying a menu, console, scoreboard or notify line is up", so
    /// that placing a panel and drawing into it cannot disagree — and NOT
    /// on `hud_mode`: a menu is not a HUD preset, it draws in every
    /// mode including `vr_hud 0`, and it coexists with the wrist HUD. nil
    /// without a head pose, for `hudPanelModel`'s reason: there is nothing
    /// sane left to anchor to.
    private func screen2dPanelModel(packet: qc_frame_t, originFromDevice: simd_float4x4,
                                    headPoseAvailable: Bool) -> simd_float4x4? {
        guard RendererCore.hasScreen2D(packet),
              let frame = floatAnchorFrame(originFromDevice: originFromDevice,
                                           headPoseAvailable: headPoseAvailable,
                                           distance: Self.screen2dDistance,
                                           lowerOffset: Self.screen2dLowerOffset)
        else { return nil }
        return RendererCore.hudPanelModel(origin: frame.origin, right: frame.right, up: frame.up,
                                          widthMeters: Self.screen2dPanelWidth,
                                          heightMeters: Self.screen2dPanelHeight)
    }

    /// GUN anchor frame for modular tiles: the dominant hand's controller
    /// pose, billboarded toward the eye like the wrist frame — or, in
    /// hands-only play, the ARKit gun-hand wrist (see `gunPosition()`). nil
    /// (hide, never a stale pose) only when neither source currently has
    /// the dominant hand.
    private func gunAnchorFrame() -> RendererCore.HudAnchorFrame? {
        guard let gunPos = gunPosition() else { return nil }
        let eye = ViewerPose.shared.eye
        let toEye = eye - gunPos
        let toward = simd_length(toEye) > 1e-4 ? simd_normalize(toEye) : SIMD3<Float>(0, 0, 1)
        let basis = RendererCore.billboardBasis(toward: toward)
        let origin = gunPos + toward * Self.gunTileLift
        return RendererCore.HudAnchorFrame(origin: origin, right: basis.right, up: basis.up,
                                           forward: toward)
    }

    /// The dominant hand's position, corrected tracking space: the
    /// Sense controller grip pose when controllers are tracking (the same
    /// source, and the same correction, the engine's own aim feed uses
    /// above) — read again here rather than cached across frames (this
    /// runs only when `vr_hud 3`, and cheaply) — else the ARKit gun-hand
    /// wrist `HandInput` publishes continuously whenever hands are the
    /// active input (see `GunHand`, the exact mirror of `OffHandWrist`).
    /// nil when neither source currently has the dominant hand.
    private func gunPosition() -> SIMD3<Float>? {
        let rightHanded = VRSettings.shared.rightHanded
        if SpatialControllerTracker.shared.isTracking,
           let domPose = SpatialControllerTracker.shared.pose(left: !rightHanded) {
            let p = recenterCorrection * domPose.columns.3
            return SIMD3(p.x, p.y, p.z)
        }
        let snap = GunHand.shared.snapshot()
        return snap.valid ? snap.position : nil
    }

    // MARK: - HUD live editor: in-place wrist grids (vr_hud 3, edit mode)

    /// Tint for an idle 2x2 grid cell backing -- a dim translucent fill, so
    /// the four cells read as a faint grid worn on the forearm without
    /// occluding what is behind them.
    private static let gridCellDim = SIMD4<Float>(0.6, 0.65, 0.75, 0.35)
    /// Tint for a cell inside the grabbed tile's drop footprint (where it
    /// would land this frame) -- brighter than idle, dimmer than the single
    /// hovered cell.
    private static let gridCellPreview = SIMD4<Float>(1.0, 0.85, 0.35, 0.4)
    /// Tint for the exact cell under the grab point -- the brightest, so the
    /// drop target is unmistakable.
    private static let gridCellHot = SIMD4<Float>(1.0, 0.85, 0.35, 0.85)
    /// Grid cells carry no label, but `drawWorkbenchLabel` still takes a text
    /// colour + cell size; these are inert placeholders for the `text == nil`
    /// backing-only path.
    private static let gridLabelTextColor = SIMD4<Float>(1, 1, 1, 1)
    private static let gridLabelCell: Float = 0.016

    /// One filled grid-cell backing quad: its centre, the wrist frame's own
    /// right/up plane, its footprint size (metres), and its tint. Drawn
    /// through `drawWorkbenchLabel` with no text (`RendererCore`'s solid
    /// tinted quad path).
    private struct GridCellQuad {
        var origin: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var width: Float
        var height: Float
        var color: SIMD4<Float>
    }

    /// The working edit for tile `i` -- the in-progress placement the editor
    /// mutates -- falling back to the packet's own fields when the working
    /// copy has no entry for it (it always should, but never trust an index).
    private func tileEdit(at i: Int, snapshot: HudEditor.Session.RenderSnapshot,
                          tile: qc_hud_tile_t) -> HudEditor.TileEdit {
        if i < snapshot.working.count { return snapshot.working[i] }
        return HudEditor.TileEdit(anchor: Int(tile.anchor),
                                  offset: SIMD3(tile.offset.0, tile.offset.1, tile.offset.2),
                                  scale: tile.scale, show: true,
                                  slot: Int(tile.slot), spanW: Int(tile.span_w), spanH: Int(tile.span_h))
    }

    /// This frame's tile matrices while the editor is ACTIVE: each tile rides
    /// its edited wrist cell (or free GUN/FLOAT offset) exactly as the live
    /// path would, but placed from the in-progress working copy rather than
    /// the packet, so edits show immediately. The grabbed tile (if any)
    /// follows `snapshot.grab.lastPoint` instead of its cell. Same
    /// `[simd_float4x4?]` shape as `hudTileModels`, so it drops into the same
    /// `drawHudTiles` call; a hidden (`show == false`) or empty
    /// (`vert_count == 0`) tile draws as nil, and a wrist tile whose forearm
    /// isn't tracked draws as nil too (its frame is invalid).
    private func wristGridTileModels(packet: qc_frame_t,
                                     wrists: (off: HudEditor.WristFrame, gun: HudEditor.WristFrame),
                                     gunFree: RendererCore.HudAnchorFrame?,
                                     float_: RendererCore.HudAnchorFrame?,
                                     snapshot: HudEditor.Session.RenderSnapshot) -> [simd_float4x4?] {
        guard packet.num_hud_tiles > 0, let tiles = packet.hud_tiles else { return [] }
        var models: [simd_float4x4?] = []
        for i in 0..<Int(packet.num_hud_tiles) {
            let tile = tiles[i]
            guard tile.vert_count > 0 else { models.append(nil); continue }
            let edit = tileEdit(at: i, snapshot: snapshot, tile: tile)
            guard edit.show else { models.append(nil); continue }
            let pinnedOrigin = (snapshot.grab?.tileID == i) ? snapshot.grab?.lastPoint : nil
            let placement = tilePlacement(tile: tile, anchor: edit.anchor, slot: edit.slot,
                                          spanW: edit.spanW, spanH: edit.spanH, scale: edit.scale,
                                          offset: edit.offset, originOverride: pinnedOrigin,
                                          wrists: wrists, gunFree: gunFree, float_: float_)
            models.append(placement.map { model(from: $0) })
        }
        return models
    }

    /// The edit-mode grid this frame: four filled 2x2 cell backings on each
    /// TRACKED forearm (an untracked wrist draws nothing -- never a NaN
    /// quad). The single cell under the grab point reads brightest
    /// (`gridCellHot`); every cell inside the grabbed tile's drop footprint
    /// reads bright (`gridCellPreview`); the rest are dim (`gridCellDim`).
    /// Purely visual -- the drop itself (`HudEditorMath.resolveWristDrop`)
    /// runs on release, owned by the grab/drop input task, not this path.
    /// The DONE/CANCEL buttons live in SwiftUI (ContentView), not here.
    private func wristGridFurniture(wrists: (off: HudEditor.WristFrame, gun: HudEditor.WristFrame),
                                    snapshot: HudEditor.Session.RenderSnapshot) -> [GridCellQuad] {
        var quads: [GridCellQuad] = []
        for frame in [wrists.off, wrists.gun] {
            guard frame.valid else { continue }

            // The cell under the grab point, and the footprint the grabbed
            // tile would drop into rooted there (clamped to the grid). Only
            // when a grab is live and its point is over THIS forearm.
            var hoveredCell: Int?
            var previewCells: Set<Int> = []
            if let grab = snapshot.grab,
               let cell = HudEditor.cellUnderPoint(grab.lastPoint, frame: frame) {
                hoveredCell = cell
                if grab.tileID >= 0, grab.tileID < snapshot.working.count {
                    let edit = snapshot.working[grab.tileID]
                    let (w, h) = HudEditor.clampFootprint(slot: cell, spanW: edit.spanW, spanH: edit.spanH)
                    previewCells = HudEditor.spannedCells(slot: cell, spanW: w, spanH: h)
                } else {
                    previewCells = [cell]
                }
            }

            for slot in 0 ..< (HudEditor.gridCols * HudEditor.gridRows) {
                let cell = HudEditor.wristCellOffset(slot: slot, spanW: 1, spanH: 1)
                let origin = frame.origin + frame.right * cell.offset.x + frame.up * cell.offset.y
                let color: SIMD4<Float>
                if hoveredCell == slot {
                    color = Self.gridCellHot
                } else if previewCells.contains(slot) {
                    color = Self.gridCellPreview
                } else {
                    color = Self.gridCellDim
                }
                quads.append(GridCellQuad(origin: origin, right: frame.right, up: frame.up,
                                          width: cell.size.x, height: cell.size.y, color: color))
            }
        }
        return quads
    }

    /// This frame's HIT-TEST geometry for the grab/drop input layer (Task 5):
    /// the two wrist frames (`wrists.off`/`wrists.gun`, the planes the input
    /// layer resolves a wrist drop against) and each VISIBLE tile's world
    /// quad at the exact cell/offset it is drawn at -- turned into the plain
    /// `HudEditor.WristFrame`/`TileFrame` shapes and published through
    /// `WorkbenchGeometry` (HudEditorInput.swift), since the head/wrist poses
    /// this is anchored to belong to this render thread alone. An inactive
    /// editor (or no packet) publishes `.inactive`, so the input layer finds
    /// nothing to hit -- never stale geometry from a previous session. A
    /// hidden (`show == false`) tile has no quad of its own; its tileID rides
    /// `hiddenTileIDs` for the input layer's recall path instead.
    private func publishWorkbenchGeometry(packet: qc_frame_t?,
                                          wrists: (off: HudEditor.WristFrame, gun: HudEditor.WristFrame),
                                          gunFree: RendererCore.HudAnchorFrame?,
                                          float_: RendererCore.HudAnchorFrame?,
                                          snapshot: HudEditor.Session.RenderSnapshot) {
        guard snapshot.active, let packet, packet.num_hud_tiles > 0, let tiles = packet.hud_tiles
        else {
            WorkbenchGeometry.shared.publish(.inactive)
            return
        }

        var tileFrames: [HudEditor.TileFrame] = []
        var hiddenTileIDs: [Int] = []
        for i in 0..<Int(packet.num_hud_tiles) {
            let tile = tiles[i]
            guard tile.vert_count > 0 else { continue }
            let edit = tileEdit(at: i, snapshot: snapshot, tile: tile)
            guard edit.show else { hiddenTileIDs.append(i); continue }
            let pinnedOrigin = (snapshot.grab?.tileID == i) ? snapshot.grab?.lastPoint : nil
            guard let placement = tilePlacement(tile: tile, anchor: edit.anchor, slot: edit.slot,
                                                spanW: edit.spanW, spanH: edit.spanH, scale: edit.scale,
                                                offset: edit.offset, originOverride: pinnedOrigin,
                                                wrists: wrists, gunFree: gunFree, float_: float_)
            else { continue }
            tileFrames.append(HudEditor.TileFrame(
                tileID: i, origin: placement.origin, right: placement.right, up: placement.up,
                halfW: placement.width * 0.5, halfH: placement.height * 0.5))
        }

        WorkbenchGeometry.shared.publish(.init(active: true, off: wrists.off, gun: wrists.gun,
                                               tiles: tileFrames, hiddenTileIDs: hiddenTileIDs))
    }

    /// Draws every grid cell `wristGridFurniture` built this frame as a solid
    /// tinted quad through `RendererCore.drawWorkbenchLabel` (its `text ==
    /// nil` backing-only path) -- same `viewproj0`/`viewproj1` the tiles drew
    /// with just above, so the cells sit in the wrist plane beneath them.
    private func drawWristGrid(_ quads: [GridCellQuad], conchars: UInt32,
                               viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                               pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        for quad in quads {
            core.drawWorkbenchLabel(text: nil, origin: quad.origin,
                                    right: quad.right, up: quad.up,
                                    panelWidth: quad.width, panelHeight: quad.height,
                                    cellSize: Self.gridLabelCell,
                                    panelColor: quad.color, textColor: Self.gridLabelTextColor,
                                    conchars: conchars,
                                    viewproj0: viewproj0, viewproj1: viewproj1,
                                    pipelines: pipelines, encoder: encoder)
        }
    }

    // MARK: - Wrist communicator (vr_wristcomm_*)

    /// The device bezel behind the action grid -- near-black and mostly
    /// opaque, so the six cells read as keys on a physical unit strapped to
    /// the forearm rather than six floating labels. Alpha is the FULL-reveal
    /// alpha; every colour here is scaled by the live fade before it is
    /// handed to the draw.
    private static let commBezelColor = SIMD4<Float>(0.05, 0.05, 0.06, 0.8)
    /// One action cell's key face -- a cool dark grey, lighter than the
    /// bezel so each key's edge separates from the body around it.
    private static let commCellColor = SIMD4<Float>(0.16, 0.19, 0.24, 0.92)
    /// Key legend TINT, multiplied into conchars' RED character set (see
    /// `commLabelAlternate`). A DEVICE-TUNING LEVER -- this is the one
    /// number to move if the legends are hard to read in the headset.
    ///
    /// Near-neutral and a touch warm, deliberately: the colour the player
    /// sees now lives in the TEXELS (the alternate charset's glyphs are
    /// already red/bronze), so this only has to avoid dulling them. A
    /// saturated tint on top of coloured texels multiplies to mud.
    ///
    /// Two earlier attempts are why it is a charset choice and not a tint
    /// at all: a cool near-white, which the light cool stone card swallowed
    /// for want of hue separation, and then a warm parchment, whose button
    /// titles were still hard to read on device,
    /// because a tint only shifts the hue of ink that is still mid-value.
    /// Red ink with a black outline carries both; alpha is still multiplied
    /// by the side's live opacity at the draw (`faded`).
    private static let commLabelColor = SIMD4<Float>(1.0, 0.98, 0.94, 1.0)
    /// Draw the legends with conchars' SECOND character set -- `char |
    /// 0x80`, the red/bronze glyphs Quake's menus use. The legends wanted
    /// Quake's own red, and this is the engine's own red rather than a
    /// tinted white: the glyph bitmaps differ, so the ink reads as Quake's
    /// and not as a recolour.
    private static let commLabelAlternate = true
    /// The legend's BLACK OUTLINE: the same glyphs drawn four times in
    /// near-black, offset +/- one `commLabelOutlineFrac` of the glyph cell
    /// along the panel's own right and up, with the fill on top. Four
    /// passes rather than one drop shadow because the outline has to work
    /// in every direction the stone noise happens to go light -- a shadow
    /// only darkens one side of each stroke, which is what the first cut
    /// shipped (and it is replaced, not stacked: a backing border and a
    /// shadow do the same job, and the border IS the stronger of the two).
    ///
    /// Fraction of the glyph, not metres, so a legend shrunk to fit its key
    /// (`commGlyphSize`) gets a proportionally thinner outline instead of a
    /// fixed one that would close up NOCLIP's counters.
    ///
    /// Comm-only by construction: it lives in this draw loop rather than in
    /// `RendererCore.drawPanelLabel`, so the HUD editor's workbench labels
    /// (the other caller of that path) are untouched.
    private static let commLabelOutlineColor = SIMD4<Float>(0, 0, 0, 0.95)
    private static let commLabelOutlineFrac: Float = 0.12
    /// Largest glyph a key legend may use (metres per conchars cell). A
    /// short label (GOD) would otherwise fill its key edge to edge; a long
    /// one (NOCLIP) is shrunk below this to fit, see `commGlyphSize`.
    ///
    /// Bumped with the legibility pass: raising the CAP only enlarges the
    /// SHORT labels, since `commGlyphSize`'s fit rule still shrinks anything
    /// long enough to reach the key edge -- so NOCLIP is exactly where it
    /// was and GOD/QUAD got bigger.
    private static let commGlyphCell: Float = 0.0095
    /// Fraction of the key width a legend may occupy, so the longest label
    /// keeps a visible margin inside its key rather than touching the edge.
    private static let commLabelFill: Float = 0.86
    /// Below this opacity the panel contributes nothing a viewer can see,
    /// so it is not built or drawn at all -- the draw-skip threshold, NOT a
    /// reveal threshold (the fade itself keeps easing through it).
    private static let commFadeFloor: Float = 0.02
    /// Minimum gap between rising-edge bindings refreshes, seconds. See
    /// `requestCommRefresh` for the flicker this exists to absorb.
    private static let commRefreshDebounce: Double = 0.5

    // Feedback ladder: base key < hovered key < pressed key. Two things
    // carry each step, because `hud_panel_fragment` ignores the vertex
    // colour (see `RendererCore.drawStonePanel`) and a stone panel's tint
    // therefore only shows through the card's interior alpha:
    //
    //  * the key's own stone TINT, lifted towards the highlight colour by
    //    `commTintLift` -- the subtle half, a change of cast across the
    //    whole key;
    //  * a WASH, a flat inset quad over the card -- the half that reads
    //    from arm's length, and the only half that survives
    //    `pipelines.hudPanel` failing to build.
    //
    // Every colour here is at FULL reveal; the live fade is applied to all
    // of them (`faded`) before they reach the draw.

    /// A hovered key's lit face: cool and bright enough to pick one key out
    /// of six at a glance, without reading as "pressed".
    private static let commHoverWash = SIMD4<Float>(0.38, 0.56, 0.90, 0.50)
    /// A fired key's flash -- near-white, decaying to nothing across
    /// `WristComm.pressFlash` so a press reads as a strike rather than a
    /// state change.
    private static let commPressWash = SIMD4<Float>(0.95, 0.98, 1.0, 0.90)
    /// The solid finger's tint while its hand is HOVERING a key: the legend
    /// parchment, so the finger reads as part of the same unit rather than
    /// as an overlay that happens to be on the hand. Alpha is deliberately
    /// short of 1 -- the finger is drawn depth-always OVER the key it is on,
    /// and an opaque fingertip hides the very key it is about to light.
    private static let commFingerHover = SIMD4<Float>(1.0, 0.92, 0.58, 0.90)
    /// ...and while the key it pressed is still flashing: near-white, the
    /// `commPressWash` family, so the finger strikes with the key.
    private static let commFingerPress = SIMD4<Float>(0.97, 0.99, 1.0, 0.96)
    /// How much of those tints is MIXED INTO the finger's own shaded skin,
    /// 0...1 -- the two DEVICE-TUNING LEVERS for the finger's material.
    ///
    /// Not a full replace, which is what the wireframe this solid finger replaced
    /// used: a solid shape flooded with one colour has no shading left and
    /// reads as a glow stick in the shape of a finger. A wash keeps the
    /// bead modelling (`HandState.buildIndexFinger` bakes a half-lambert
    /// into the published vertices) and still carries the state -- warm
    /// parchment-lit skin on hover, struck almost white on a press, which
    /// is a bigger jump than the hover wash so the two never read alike.
    private static let commFingerHoverWash: Float = 0.42
    private static let commFingerPressWash: Float = 0.82
    /// The lit face's size as a fraction of the key. Well inside
    /// `hud_panel_fragment`'s rounded corner radius, so a highlight lights
    /// the stone card it sits on rather than spilling past its mask and
    /// squaring the key off.
    private static let commWashInset: Float = 0.74
    /// How much of a highlight's colour also lifts the key's own stone
    /// tint, 0...1.
    private static let commTintLift: Float = 0.8

    /// One communicator quad: a bezel body or one action key, in the wrist
    /// frame's own right/up plane, with its legend (nil for the bezel) and
    /// the glyph size that legend fits at. Drawn through
    /// `RendererCore.drawWorkbenchLabel`'s `labelCentered` path.
    private struct CommQuad {
        var origin: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var width: Float
        var height: Float
        var color: SIMD4<Float>
        var label: String?
        var glyph: Float
        /// This quad's live reveal fade, carried so the legend colour can be
        /// faded by the same factor its key face was without reverse-
        /// engineering it out of `color`'s alpha. Doubles as the
        /// `stoneReveal` the stone card is gated on.
        var opacity: Float
        /// The hover/press lit face drawn over this quad's stone card, or
        /// nil for an idle key and for the bezel. Already faded. Drawn
        /// between the card and the legend, so a flash lights the key
        /// without ever washing out the label on it.
        var wash: SIMD4<Float>?
    }

    /// `color` faded by `opacity` -- alpha only, so a half-revealed panel
    /// blends out instead of washing to grey (the `text` pipeline blends
    /// straight-alpha; see the alpha contract in `encode`).
    private static func faded(_ color: SIMD4<Float>, _ opacity: Float) -> SIMD4<Float> {
        SIMD4(color.x, color.y, color.z, color.w * opacity)
    }

    /// The glyph size `label` fits in one key at: `commGlyphCell`, shrunk if
    /// the string is too long to sit inside `commLabelFill` of the key.
    /// `textQuads` lays glyphs out one `cellSize` apart, so the run is
    /// exactly `count * cellSize` wide.
    private static func commGlyphSize(for label: String) -> Float {
        let count = Float(max(label.count, 1))
        return min(commGlyphCell, WristComm.cellSize * commLabelFill / count)
    }

    /// One key's face this frame: its stone tint and the lit face washed
    /// over it, both already faded by `opacity`.
    ///
    /// `press` is the fired-key flash's remaining strength (1 at the
    /// instant of the fire, 0 once `WristComm.pressFlash` has elapsed, 0
    /// for a key that did not fire). Pressed beats hovered beats base: a
    /// key being pressed is necessarily also hovered (`touchDepth` is a
    /// strict subset of `hoverDepth`), so without that order every flash
    /// would be overwritten by the hover tint of the finger that caused it.
    private static func commKeyFace(hovered: Bool, press: Float,
                                    opacity: Float) -> (tint: SIMD4<Float>, wash: SIMD4<Float>?) {
        let base = commCellColor
        let highlight: SIMD4<Float>
        let strength: Float
        if press > 0 {
            highlight = commPressWash
            strength = min(press, 1)
        } else if hovered {
            highlight = commHoverWash
            strength = 1
        } else {
            return (faded(base, opacity), nil)
        }
        let lift = strength * commTintLift
        let tint = SIMD4<Float>(base.x + (highlight.x - base.x) * lift,
                                base.y + (highlight.y - base.y) * lift,
                                base.z + (highlight.z - base.z) * lift,
                                base.w)
        let wash = SIMD4<Float>(highlight.x, highlight.y, highlight.z, highlight.w * strength)
        return (faded(tint, opacity), faded(wash, opacity))
    }

    /// Requests a bindings refresh on a reveal rising edge, no more often
    /// than `commRefreshDebounce`. The edge is NOT rare outside an edit
    /// session: the wrist latch only holds a pose while the HUD editor is
    /// open, so ARKit wrist-tracking flicker alternates `frame.valid` and
    /// drops the latch each time, re-arming the edge -- at frame rate that
    /// is ~45 main-actor hops a second, each doing 26 cvar reads, and each
    /// one more chance for the `QC_CvarString`-vs-`Cvar_Set` string race
    /// `qr_bridge.c` documents. Half a second still picks up a console edit
    /// well before the fade finishes. The one-shot bootstrap does not go
    /// through here; it is unconditional.
    private func requestCommRefresh(now: Double) {
        if let last = lastCommRefreshRequest, now - last < Self.commRefreshDebounce { return }
        lastCommRefreshRequest = now
        WristCommStore.requestRefresh()
    }

    /// Publishes an inactive communicator and clears every per-side piece of
    /// reveal state (fade, hysteresis latch, occlusion hold, fade clock), so
    /// no reader sees a frozen panel and no resume inherits one. Render
    /// thread; called when the layer parks and when it goes away.
    private func standDownWristComm() {
        commOpacity = [0, 0]
        commRevealed = [false, false]
        commHeldPose = [nil, nil]
        commHeldSince = [0, 0]
        lastCommAlongArm = nil
        // The hovering hand goes with the flash it serves: resuming with a
        // latched hand would draw the finger model on a hand that is no longer
        // anywhere near the panel.
        commHoverHand = [nil, nil]
        lastCommTick = nil
        WristCommGeometry.shared.publish(.inactive)
        // A press flash must not survive the park: without this, pausing or
        // tearing down within pressFlash of a fire resumes with a key already
        // lit (the fade crosses the draw floor in a single frame).
        WristCommFeedback.shared.invalidate()
    }

    /// The RAW, PRE-DIAL pose one side's communicator is built from, in
    /// whichever view is active -- the single thing the occlusion hold holds.
    ///
    /// Raw rather than resolved, deliberately, and that is the same choice
    /// the across path has always made: the placement dials are a placement
    /// on top of whatever pose is current, so re-dialling mid-hold has to
    /// move the panel rather than find yesterday's dial baked into the held
    /// pose. Holding the resolved frame would bake it.
    ///
    /// Two cases because there are two genuinely different sources, not two
    /// renderings of one: `across` is the eye-billboarded wrist plane
    /// (`wristFrames()`), which is what the watch-glance view wants and
    /// which does not move with the arm; `along` is the forearm itself
    /// (`ForearmPose`), which is what a unit STRAPPED to the arm wants and
    /// which has no eye in it at all.
    private enum CommPose {
        case across(HudEditor.WristFrame)
        case along(ForearmSample)

        var valid: Bool {
            switch self {
            case .across(let frame): return frame.valid
            case .along(let sample): return sample.valid
            }
        }
    }

    /// This side's live communicator pose for the active view. The across
    /// case is the frame the HUD tiles already sit on, so the two can never
    /// drift apart; the along case is the forearm of the hand on that side
    /// (side 0 = off hand, side 1 = gun hand).
    ///
    /// `arms` and `offIsLeft` are passed in rather than read here because
    /// both sides must agree on them: a handedness sampled per side could,
    /// if the setting moved mid-frame, strap BOTH panels to the same arm --
    /// the same reason the dials are one atomic read.
    private func liveCommPose(side: Int, alongArm: Bool,
                              wrists: (off: HudEditor.WristFrame, gun: HudEditor.WristFrame),
                              arms: (left: ForearmSample, right: ForearmSample),
                              offIsLeft: Bool) -> CommPose {
        guard alongArm else { return .across(side == 0 ? wrists.off : wrists.gun) }
        // Off hand is the LEFT hand for a right-handed player; the gun hand
        // is the other one -- the mapping `offHandWristPosition` makes from
        // the same `VRSettings.rightHanded`.
        let wantLeft = side == 0 ? offIsLeft : !offIsLeft
        return .along(wantLeft ? arms.left : arms.right)
    }

    /// The pose the communicator uses for `side` this frame: the live one
    /// whenever it is valid, and otherwise -- for at most
    /// `WristComm.occlusionHold` seconds, and only while this side is
    /// revealed past `WristComm.fireRevealFloor` -- the last valid one.
    ///
    /// This is the communicator's own hold, deliberately NOT
    /// `latchedWristFrame`'s: that latch only holds while the HUD editor is
    /// open and is explicitly dropped between edit sessions, which is the
    /// communicator's entire operating mode. The arm reaching to press a
    /// cell is exactly what hides that wrist from the cameras, so with no
    /// hold of its own a sustained occlusion invalidates the frame, the
    /// touched cell goes nil and the fade crosses below the fire floor
    /// within a handful of frames: the panel vanishes from under the
    /// fingertip, and after re-acquire the touch loop's idle reset and
    /// seeding absorb the still-resting finger, so the press has to be
    /// withdrawn and made again.
    ///
    /// Reveal-gated rather than unconditional: a stale frame plus a blind
    /// touch must not fire. Below the fire floor there is nothing on screen
    /// to aim at, so an invalid wrist behaves exactly as it did before --
    /// fade out. Bounded for the same reason: a wrist genuinely lowered out
    /// of view still hides, just a quarter-second later.
    ///
    /// The pose returned here resolves into the ONE frame + origin that
    /// feeds the drawn quads, the hover test and the published
    /// `WristCommGeometry` side alike, so the fingertip is hit-tested
    /// against the panel the eye is looking at -- the same three-path
    /// discipline the HUD keeps between its tiles, its editor grid and its
    /// hit-test geometry. It covers BOTH views: the along view's arm is
    /// hidden by the reaching hand just as readily as the across view's
    /// wrist is, and more so, since the reach crosses the whole forearm.
    private func commPose(side: Int, live: CommPose, now: Double) -> CommPose {
        if live.valid {
            commHeldPose[side] = live
            commHeldSince[side] = now
            return live
        }
        guard commOpacity[side] > WristComm.fireRevealFloor,
              let held = commHeldPose[side],
              now - commHeldSince[side] <= WristComm.occlusionHold else {
            commHeldPose[side] = nil
            return live
        }
        return held
    }

    /// One side's resolved communicator placement: the panel frame and the
    /// panel centre, from a raw pose plus the active view's five dials.
    /// THE one resolution -- reveal, hover, quads, press flash, finger beads
    /// and the published geometry all take this pair and nothing else.
    ///
    /// ACROSS is bit-for-bit the chain that shipped: `orientedFrame` turns
    /// the billboarded wrist plane in its own plane, `commOrigin` drops the
    /// unit clear of the HUD grid by the rotated rectangle's own extent, and
    /// `adjustedFrame` applies the tilt and all three offsets in that turned
    /// frame's axes.
    ///
    /// ALONG is the SAME CHAIN SHAPE, and that is the structural win of this
    /// round: base frame -> `orientedFrame(rot)` -> seated origin ->
    /// `adjustedFrame(all four dials)`, for both views. They differ in
    /// exactly two places -- WHICH BASE FRAME (`WristComm.alongBaseFrame`,
    /// anchored on the forearm and billboarded at the eye, against the
    /// already-billboarded wrist plane) and WHICH AXIS THE UNIT SEATS ALONG
    /// (down the arm by `alongSeatDistance`, against down the panel by
    /// `commOrigin`). Everything else is shared code. The along case used to
    /// be a second chain with its own spin, its own offset application and
    /// its own tilt-only `adjustedFrame` call; the two then had to be kept
    /// in step by hand, and the one mistake that invites -- applying the
    /// offsets twice, once into the origin and once through `adjustedFrame`
    /// -- is now unwritable, because there is only one place they are
    /// applied at all.
    ///
    /// Dial meanings come out the same in both views -- Forward along the
    /// panel's long axis (which the along base frame has lying down the
    /// arm), Side across it, Height toward the eye -- but NOT by handing
    /// `adjustedFrame` the same three arguments. Its parameter names are
    /// written for the across frame; the along base frame assigns `right`/
    /// `up`/`forward` to different physical axes, so the along case permutes
    /// the dials onto it. The permutation is spelled out at the call below,
    /// where it is made, and pinned by directional (not identity) assertions
    /// in `runAlongBaseFrameTests`. What IS now common to both views: the
    /// offsets are applied once, by `adjustedFrame`, and the along view no
    /// longer bakes any of them into `origin`.
    ///
    /// WHY THE ALONG VIEW BILLBOARDS AT ALL: see
    /// `WristComm.alongBaseFrame`. Flat to the skin is geometrically honest
    /// and unreadable -- in any natural glance pose the inner forearm is
    /// nearly edge-on to the eye, and the panel came up on device as a
    /// horizontal line that the Angle/Rotate gimbal could not recover. The
    /// position stays on the arm; only the orientation moved to the eye.
    ///
    /// BOTH cases clear the HUD grid by derivation, which is the fix for the
    /// collision seen on device: the along unit was seated at the forearm
    /// MIDPOINT, off a different thing entirely from the wrist tiles, and
    /// near the wrist the two always fought -- no placement dial could
    /// separate them because the dials moved one and not the other. One
    /// derivation, two drop axes. The seat applies in EVERY `vr_hud` mode,
    /// deliberately -- it is one muscle-memory position, and a unit that
    /// jumped when the player changed HUD style would be worse than a unit
    /// seated a little low with the tiles off. Nothing about the HUD's mode
    /// or its live tiles reaches this chain.
    ///
    /// `eye` is the head position the caller already has in hand
    /// (`updateWristComm`'s `headPos`, the device anchor's own translation),
    /// threaded through rather than re-read: no new publisher, no extra lock
    /// take, and the frame the panel faces is the same head pose the reveal
    /// test below is taken against.
    ///
    /// An invalid pose resolves to an invalid frame at the origin, which is
    /// exactly what the across path produced before and what the caller's
    /// `frame.valid` guard expects.
    private func resolveCommPlacement(
        _ pose: CommPose, sideIndex: Int, eye: SIMD3<Float>,
        dials: (alongArm: Bool, tilt: Float, fwd: Float, side: Float, up: Float, rot: Float)
    ) -> (frame: HudEditor.WristFrame, origin: SIMD3<Float>) {
        switch pose {
        case .across(let wrist):
            let oriented = WristComm.orientedFrame(wrist, rollDegrees: dials.rot)
            return WristComm.adjustedFrame(
                oriented,
                origin: wrist.valid ? WristComm.commOrigin(wrist: wrist,
                                                           rollDegrees: dials.rot) : .zero,
                tiltDegrees: dials.tilt, fwd: dials.fwd, side: dials.side, up: dials.up)
        case .along(let arm):
            let anchor = sideIndex == 0 ? Int(QC_HUD_ANCHOR_WRIST_OFF) : Int(QC_HUD_ANCHOR_WRIST_GUN)
            var base = WristComm.alongBaseFrame(wrist: arm.wrist, elbow: arm.elbow, eye: eye)
            guard base.valid else {
                return (HudEditor.WristFrame(anchor: anchor, origin: .zero, right: .zero,
                                             up: .zero, forward: .zero, valid: false), .zero)
            }
            base.anchor = anchor
            let oriented = WristComm.orientedFrame(base, rollDegrees: dials.rot)
            // Seated down the TRUE bone, not the panel's long axis: the
            // panel's is the bone as seen in the billboarded plane, and the
            // unit has to back away along the arm it is riding whatever the
            // head is doing. Guarded by `base.valid`, which already refused
            // a collapsed forearm.
            let armAxis = simd_normalize(arm.wrist - arm.elbow)
            let origin = arm.wrist - armAxis * WristComm.alongSeatDistance(rollDegrees: dials.rot)
            // THE OFFSETS ARE PERMUTED, DELIBERATELY, AND MUST STAY SO.
            // `adjustedFrame` moves the origin by `right * side + up * up +
            // forward * fwd` -- parameter names written for the ACROSS
            // frame, where `forward` is the toward-you axis and `right` the
            // across-the-panel one. This view's base frame assigns the same
            // three names differently: `right` is THE ARM, `forward` is
            // toward the eye, `up` is across the panel. So the dials go in
            // rotated by one --
            //
            //     Forward (along the arm)   -> side: rides `right`
            //     Side    (across the panel)-> up:   rides `up`
            //     Height  (toward you)      -> fwd:  rides `forward`
            //
            // -- and that is what the captions, the defaults and
            // `runAlongBaseFrameTests`' directional assertions all say.
            // Passing them positionally compiles, type-checks and silently
            // gives three wrong dials: it shipped once, in the commit that
            // folded this view's hand-rolled offsets into `adjustedFrame`,
            // and the 1 cm default Height slid the panel sideways instead of
            // lifting it off the arm -- putting the hit-test plane inside
            // the forearm, where a fingertip stopped by the skin never
            // reaches `touchDepth`. The test asserts DIRECTIONS (dot
            // products against the bone and the line of sight) rather than
            // restating this call, so the next way of getting it wrong
            // fails too.
            return WristComm.adjustedFrame(oriented, origin: origin, tiltDegrees: dials.tilt,
                                           fwd: dials.up, side: dials.fwd, up: dials.side)
        }
    }

    /// Advances the wrist communicator's reveal state for this frame and
    /// returns the quads to draw (empty when nothing is revealed) plus the
    /// solid finger that goes over them (empty unless a key is hovered
    /// or flashing -- see the finger's own comment in the loop below). Also
    /// publishes `WristCommGeometry` for the touch loop -- ALWAYS, for both
    /// sides whatever their state, since that reader gates itself.
    ///
    /// Reveal is a glance: `WristComm.revealTarget` compares the head
    /// forward against the direction to the grid centre, with an on/off cone
    /// band so a panel on the edge of the gaze cannot flicker, and
    /// `smoothedOpacity` eases the result so it fades rather than pops. A
    /// side with no binding (`enabled == false`), an untracked wrist, or no
    /// head pose to glance WITH takes no reveal decision at all and simply
    /// decays what is already up -- never a hard cut, and never a reveal
    /// test against an identity (missing) head pose.
    ///
    /// `headPos` does double duty now: the reveal test above takes its
    /// glance direction from it, and `resolveCommPlacement` bills it as the
    /// EYE the along view's panel turns its face toward. One head pose, both
    /// uses -- a second read could in principle face the panel at one eye
    /// position and test the glance against another.
    ///
    /// A wrist (or forearm) whose live pose drops out while its panel is up
    /// keeps its last valid one briefly -- see `commPose`. While the HUD live
    /// editor is open every side is treated as hidden: the comm sits 12 mm
    /// under the grid being rearranged, where it is already inert (the touch
    /// loop refuses to fire during an edit session) but would only clutter
    /// the tile the hand is reaching for.
    ///
    /// Thread: render thread. `WristCommStore.snapshot()` is the nonisolated
    /// lock-protected read and `requestRefresh()` hops to the main actor to
    /// do the cvar work; no `QC_*` call is made from here.
    private func updateWristComm(wrists: (off: HudEditor.WristFrame, gun: HudEditor.WristFrame),
                                 headPos: SIMD3<Float>, headForward: SIMD3<Float>,
                                 headPoseAvailable: Bool, engineLive: Bool,
                                 editorActive: Bool) -> (quads: [CommQuad], finger: [Float]) {
        let now = CACurrentMediaTime()

        // The editor suppresses the communicator; a press flash from just
        // before it opened must not survive to light a key the instant it
        // closes (same stand-down rule the pause/teardown path applies).
        if editorActive { WristCommFeedback.shared.invalidate() }

        // Bootstrap the bindings exactly once. The store's published
        // snapshot starts INERT -- both sides disabled, every label empty --
        // and only `refresh()` ever populates it. The reveal rising edge
        // below is the only other refresh trigger, and it is gated on this
        // side being `enabled`, which reads false until a refresh has run:
        // without this call the communicator could never appear at all.
        // Deferred until the packet stream is live because the cvars it
        // reads are registered during Host_Init, and `QC_CvarValue` answers
        // 0 for a name it cannot find yet (qr_bridge.c) -- which would burn
        // the one bootstrap on an empty read. Unconditional, not debounced:
        // it is the one refresh that MUST land.
        if engineLive, !requestedCommBootstrap {
            requestedCommBootstrap = true
            lastCommRefreshRequest = now
            WristCommStore.requestRefresh()
        }

        // Same clamp the other dt consumers use (HudEditorInput.tick): a
        // first frame, a hitch, or a backgrounded space must not deliver a
        // dt that jumps the fade or inverts it.
        let dt = Float(max(1.0 / 240, min(0.1, now - (lastCommTick ?? now))))
        lastCommTick = now

        let comm = WristCommStore.snapshot()
        // Feedback inputs, read ONCE for the frame. Both are the same class
        // of nonisolated lock-protected read as `WristCommStore.snapshot()`
        // above -- plain values, no actor, no `QC_*` -- and both are
        // hit-tested/compared below against the SAME resolved frame and
        // `commOrigin` that the quads are built from and that
        // `WristCommGeometry` publishes. One pose, three paths.
        let tips = FingerTips.shared.snapshot()
        let lastFire = WristCommFeedback.shared.snapshot()
        // The ACTIVE VIEW's placement dials, read ONCE for the frame and as a
        // set (see `VRSettings.wristCommPlacement` for why they are not five
        // separate reads). Same class of nonisolated lock-protected read as
        // the two above -- and the same precedent as the `offHandPitch/Yaw/
        // Roll` reads this render thread already makes for the controller
        // hand pose.
        //
        // The across/along choice is INSIDE that one read now, not a second
        // read beside it: it selects which of the two stored sets comes
        // back, and `rot` (which both turns the frame and sets the seating
        // drop) travels with the offsets it has to agree with. Both wrist
        // sides are then built from this one value, so a toggle or a drag
        // landing mid-frame can never turn one side and not the other.
        let dials = VRSettings.shared.wristCommPlacement
        // The VIEW comes back inside that same take, not from a second read:
        // it now selects the POSE SOURCE (`liveCommPose`) as well as the
        // resolution (`resolveCommPlacement`), so a toggle landing between
        // two reads could strap the unit to an arm using the across view's
        // numbers. Both sides take this one answer.
        let alongArm = dials.alongArm
        // A view toggle invalidates whatever is held: `commHeldPose` is one
        // slot per side shared by both `CommPose` cases (see its doc above),
        // and the hold is keyed only on time, not on which view took it. Left
        // alone, toggling views inside another view's occlusion window would
        // hand `resolveCommPlacement` a pose from one view resolved against
        // the OTHER view's live dials -- a stale forearm pose placed by the
        // across dials, or vice versa -- for up to `WristComm.occlusionHold`.
        // Clearing both sides' holds on the transition (not just the side
        // that happens to be occluded) keeps the one-hold-per-side invariant
        // honest: the slot may only ever hold a pose taken under the CURRENT
        // view.
        if let last = lastCommAlongArm, last != alongArm {
            commHeldPose = [nil, nil]
            commHeldSince = [0, 0]
        }
        lastCommAlongArm = alongArm
        // The along view's pose source, snapshotted ONCE for both sides, and
        // only when that view is up -- across never looks at an arm. Same
        // class of nonisolated lock-protected read as the dials above.
        let arms = alongArm
            ? ForearmPose.shared.snapshot()
            : (left: ForearmSample.invalid, right: ForearmSample.invalid)
        let offIsLeft = VRSettings.shared.rightHanded
        var quads: [CommQuad] = []
        var sides: [WristCommGeometry.Side] = []
        var finger: [Float] = []
        // The published finger models, fetched lazily: nothing is hovered
        // or flashing on most frames, and copying two vertex buffers out of a
        // lock to then discard them is pure waste at 90 Hz.
        var published: (left: [Float], right: [Float])?

        for side in 0..<commOpacity.count {
            let live = liveCommPose(side: side, alongArm: alongArm, wrists: wrists,
                                    arms: arms, offIsLeft: offIsLeft)
            let enabled = side < comm.sides.count && comm.sides[side].enabled
            let resolved: CommPose
            if editorActive {
                // No hold while editing: the comm is suppressed below
                // anyway, and `wristFrames()` is doing its own (editor-
                // specific) latching for the grid. Dropping the held pose
                // means a later reveal re-acquires from a freshly seen
                // wrist or arm rather than an edit-session pose.
                commHeldPose[side] = nil
                resolved = live
            } else {
                resolved = commPose(side: side, live: live, now: now)
            }

            // THE ONE RESOLUTION, applied once here, to the pair
            // everything below is derived from: the reveal decision, the
            // hover hit-test, the drawn quads, the press flash, the finger
            // beads AND the published `WristCommGeometry` side all take
            // `frame`/`origin` from this one result, so the touch loop
            // hit-tests the panel that is actually on screen and needs no
            // change of its own. Applying any of it at the draw instead
            // would move the picture off its hit-test -- exactly the
            // three-path split the hold above exists to avoid.
            //
            // The held (occlusion-hold) pose above stays RAW on purpose:
            // the dials are a placement on top of whatever pose is current,
            // so re-dialling mid-hold moves the panel rather than baking
            // yesterday's dial into the held pose. That is why `CommPose`
            // carries the forearm's two joints rather than a built frame.
            //
            // What the dials DO reads the same in both views now -- Rotate
            // spins the unit in its own plane, Forward runs along the
            // panel's long axis, Side across it, Height toward you -- which
            // is the point of `resolveCommPlacement`'s one chain shape. The
            // views differ in which base frame they spin, which axis they
            // seat along (across drops down the billboarded wrist plane,
            // along backs down the forearm), and -- because the two base
            // frames put different physical axes under the same three field
            // names -- in which order the offsets are handed to
            // `adjustedFrame`. That last one is a trap, not a symmetry; it
            // is spelled out where it is made.
            let adjusted = resolveCommPlacement(resolved, sideIndex: side, eye: headPos,
                                                dials: dials)
            let frame = adjusted.frame
            let origin = adjusted.origin

            guard enabled, !editorActive, frame.valid, headPoseAvailable else {
                // Nothing to glance at -- or nothing that should be on
                // screen, with the editor open: drop the latch (so
                // returning to a tracked, un-suppressed wrist is a fresh
                // rising edge, bindings refreshed with it) and ease
                // whatever is up out.
                commRevealed[side] = false
                commOpacity[side] = WristComm.smoothedOpacity(current: commOpacity[side],
                                                              target: 0, dt: dt)
                sides.append(WristCommGeometry.Side(
                    enabled: enabled, frame: frame,
                    commOrigin: origin,
                    opacity: commOpacity[side]))
                continue
            }

            let revealed = WristComm.revealTarget(headPos: headPos, headForward: headForward,
                                                  commOrigin: origin,
                                                  wasRevealed: commRevealed[side])
            if revealed, !commRevealed[side] {
                // Rising edge: pick up any console/config edit to the
                // bindings before the legends become readable, rather than
                // re-reading cvars (a main-actor hop) every frame.
                requestCommRefresh(now: now)
            }
            commRevealed[side] = revealed
            commOpacity[side] = WristComm.smoothedOpacity(current: commOpacity[side],
                                                          target: revealed ? 1 : 0, dt: dt)
            sides.append(WristCommGeometry.Side(enabled: true, frame: frame, commOrigin: origin,
                                                opacity: commOpacity[side]))

            guard commOpacity[side] > Self.commFadeFloor else { continue }

            // Which key a fingertip is approaching, against this side's own
            // resolved plane. `min()` only to be deterministic when both
            // hands are over the grid at once -- an interaction nobody
            // aims, but one that must not flicker between two keys frame
            // to frame. Gated on the FIRE floor, not the draw floor: the
            // touch loop refuses to fire below fireRevealFloor, and the
            // highlight must only promise what that gate will honour -- a
            // key must not light under a fingertip while the panel is still
            // fading in or out.
            //
            // `hoverPick` reports WHICH tip won as well as which cell, which
            // is the hand the solid finger below is drawn on. `map` (not
            // `compactMap`) so an untracked hand keeps its slot and tip 1
            // stays tip 1 -- the right hand.
            let hover = commOpacity[side] >= WristComm.fireRevealFloor
                ? WristComm.hoverPick([tips.left, tips.right].map {
                    $0.flatMap { WristComm.hoveredCell($0, commOrigin: origin, frame: frame) }
                })
                : nil
            let hovered: Int? = hover?.cell

            // Which key just fired, and how much of its flash is left. The
            // touch loop timestamps a fire with `CACurrentMediaTime()`, the
            // same clock `now` came from, so this is a straight window test
            // -- no cross-clock conversion and nothing to tick down. The
            // lower bound rejects a timestamp from the future, which a
            // publish landing between this frame's `now` and the draw would
            // otherwise turn into a flash stuck at full strength.
            var press: Float = 0
            var pressedCell = -1
            if let fire = lastFire, fire.side == side {
                let age = now - fire.time
                if age >= 0, age <= WristComm.pressFlash {
                    press = Float(1 - age / WristComm.pressFlash)
                    pressedCell = fire.cell
                }
            }

            quads += commQuads(frame: frame, origin: origin,
                               labels: side < comm.sides.count ? comm.sides[side].labels : [],
                               opacity: commOpacity[side],
                               hovered: hovered, pressedCell: pressedCell, press: press)

            // The solid index finger, on the ONE hand that is working
            // this panel and only while it is working it. `WristCommFeedback`
            // records the side and cell of a fire but not the hand, so the
            // hovering hand is latched here and reused for the tail of the
            // flash: `touchDepth` is a strict subset of `hoverDepth`, so the
            // pressing finger is necessarily hovering at the instant of the
            // fire -- the latch only covers the few frames after the finger
            // has withdrawn while its key is still lit.
            if let hover { commHoverHand[side] = hover.tip }
            guard let hand = hover?.tip ?? (press > 0 ? commHoverHand[side] : nil) else {
                continue
            }
            let model = published ?? FingerModel.shared.snapshot()
            published = model
            finger += Self.tintedFinger(
                hand == 0 ? model.left : model.right,
                color: press > 0 ? Self.commFingerPress : Self.commFingerHover,
                wash: press > 0 ? Self.commFingerPressWash : Self.commFingerHoverWash,
                opacity: commOpacity[side])
        }

        WristCommGeometry.shared.publish(WristCommGeometry.Snapshot(sides: sides))
        return (quads, finger)
    }

    /// A published solid finger washed with the communicator's feedback
    /// colour: each vertex's own shaded skin is mixed `wash` of the way
    /// toward `color.rgb`, and its alpha REPLACED by `color.w` times the
    /// side's live fade, so the finger appears and fades with the panel it
    /// belongs to.
    ///
    /// A mix, not an overwrite. The publisher bakes a half-lambert shade
    /// into the skin (`HandState.buildIndexFinger`) and `drawHandDebug` adds
    /// no lighting of its own, so flooding every vertex with one colour --
    /// which is what the wireframe this replaced wanted -- would flatten the
    /// finger into a silhouette. Washing keeps the modelling and still
    /// reads the state unambiguously at arm's length.
    ///
    /// Washed here rather than at the publisher because the state it carries
    /// (hovering a key vs flashing one) is the renderer's to know --
    /// `HandInput` has no idea the hand is over a panel -- and the same
    /// published buffer may be washed differently for each side in one
    /// frame. 7 floats per vertex (xyz + rgba), the `GuideVertex` layout
    /// every hand overlay already uses.
    private static func tintedFinger(_ verts: [Float], color: SIMD4<Float>,
                                     wash: Float, opacity: Float) -> [Float] {
        guard verts.count >= 21 else { return [] }
        let w = min(max(wash, 0), 1)
        var out = verts
        var i = 3
        while i + 3 < out.count {
            out[i] += (color.x - out[i]) * w
            out[i + 1] += (color.y - out[i + 1]) * w
            out[i + 2] += (color.z - out[i + 2]) * w
            out[i + 3] = color.w * opacity
            i += 7
        }
        return out
    }

    /// One side's communicator geometry: the bezel body first, then the six
    /// action keys over it at `WristComm.cellCenter`, all in the wrist
    /// frame's plane and all faded by `opacity`.
    ///
    /// Every extent here is PANEL-LOCAL -- `gridHalfX` along `frame.right`,
    /// `gridHalfY` along `frame.up`, cell centres as right/up multiples --
    /// which is what makes either view's rotation free: the caller hands in
    /// an already-turned frame -- `WristComm.orientedFrame` in BOTH views
    /// now, over each view's own base frame -- and the
    /// bezel, the keys and the legends all turn with it, in agreement with
    /// the hover test and the published geometry built from the same frame.
    /// Keep it that way; a world-axis extent here would wrap the rotated
    /// unit in a bezel the wrong way round. A key with an empty binding
    /// label draws its face alone -- the unit keeps its full six-key shape
    /// rather than growing holes, which is what the device would look like.
    private func commQuads(frame: HudEditor.WristFrame, origin: SIMD3<Float>,
                           labels: [String], opacity: Float,
                           hovered: Int?, pressedCell: Int, press: Float) -> [CommQuad] {
        var quads: [CommQuad] = []
        quads.append(CommQuad(origin: origin, right: frame.right, up: frame.up,
                              width: (WristComm.gridHalfX + WristComm.bezelPad) * 2,
                              height: (WristComm.gridHalfY + WristComm.bezelPad) * 2,
                              color: Self.faded(Self.commBezelColor, opacity),
                              label: nil, glyph: 0, opacity: opacity, wash: nil))
        for cell in 0 ..< (WristComm.cols * WristComm.rows) {
            let centre = WristComm.cellCenter(cell)
            let raw = cell < labels.count ? labels[cell] : ""
            let label = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let face = Self.commKeyFace(hovered: hovered == cell,
                                        press: cell == pressedCell ? press : 0,
                                        opacity: opacity)
            quads.append(CommQuad(
                origin: origin + frame.right * centre.x + frame.up * centre.y,
                right: frame.right, up: frame.up,
                width: WristComm.cellSize, height: WristComm.cellSize,
                color: face.tint,
                label: label.isEmpty ? nil : label,
                glyph: Self.commGlyphSize(for: label), opacity: opacity,
                wash: face.wash))
        }
        return quads
    }

    /// Draws this frame's communicator quads as PROCEDURAL STONE panels --
    /// `RendererCore.drawStonePanel`, the same `pipelines.hudPanel` card
    /// the modular HUD tiles above are backed with, so the unit reads as
    /// the same material as the HUD rather than as six flat rectangles.
    /// Same `viewproj0`/`viewproj1` the tiles drew with, so it still sits
    /// in the wrist plane below them.
    ///
    /// Three layers per quad, in this order and for this reason:
    ///
    ///  1. the stone panel at the quad's tint (`drawStonePanel` itself
    ///     falls back to that tint as a flat quad -- today's look -- when
    ///     the stone pipeline did not build, or while the panel is still
    ///     fading in and the card's fixed alpha would snap it on);
    ///  2. the hover/press lit face, inset over the card;
    ///  3. the conchars legend, LAST, so a near-white press flash lights
    ///     the key underneath its label instead of swallowing it -- itself
    ///     five passes (a four-way black outline, then the red fill), which
    ///     is the legibility pass and is COMM-ONLY: it lives here, not in
    ///     `RendererCore.drawPanelLabel`, so the HUD editor's workbench
    ///     labels through that same path keep their single plain white pass.
    ///     A dark strip under the run went with it -- it gave the ink a
    ///     constant backdrop and cost a visible band on the stone ("looks
    ///     trashy"); the outline does the same job per stroke instead.
    ///
    /// Every colour arrives already faded by the caller.
    private func drawWristComm(_ quads: [CommQuad], conchars: UInt32,
                               viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                               pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        for quad in quads {
            core.drawStonePanel(origin: quad.origin, right: quad.right, up: quad.up,
                                widthMeters: quad.width, heightMeters: quad.height,
                                tint: quad.color, stoneReveal: quad.opacity,
                                viewproj0: viewproj0, viewproj1: viewproj1,
                                pipelines: pipelines, encoder: encoder)

            if let wash = quad.wash {
                core.drawFlatPanel(origin: quad.origin, right: quad.right, up: quad.up,
                                   width: quad.width * Self.commWashInset,
                                   height: quad.height * Self.commWashInset,
                                   color: wash,
                                   viewproj0: viewproj0, viewproj1: viewproj1,
                                   pipelines: pipelines, encoder: encoder)
            }

            if let label = quad.label {
                // FIVE passes for one legend: four near-black copies of the
                // string, offset +/- one outline step along the panel's own
                // right and up, then the red fill on top. The ink is a
                // BITMAP (conchars' coloured glyphs), so colour alone cannot
                // separate it from procedural stone -- the outline gives
                // every stroke its own edge whichever way the noise under it
                // happens to go light. Offsets are IN-PLANE, so the outline
                // turns with the unit when it lies along the forearm instead
                // of across the wrist. All five are depth-always like the
                // layers under them, so the painter order here IS the
                // stacking order.
                //
                // The outline passes use the SAME red charset as the fill:
                // what an outline pass contributes is the glyph's
                // SILHOUETTE, so the charset only has to agree with the
                // fill's coverage shape -- a white-set outline would
                // misfit the red glyph it is meant to edge.
                let step = quad.glyph * Self.commLabelOutlineFrac
                let outline = Self.faded(Self.commLabelOutlineColor, quad.opacity)
                for offset in [quad.right * step, quad.right * -step,
                               quad.up * step, quad.up * -step] {
                    core.drawPanelLabel(text: label, origin: quad.origin + offset,
                                        right: quad.right, up: quad.up,
                                        cellSize: quad.glyph,
                                        color: outline,
                                        conchars: conchars,
                                        alternate: Self.commLabelAlternate,
                                        viewproj0: viewproj0, viewproj1: viewproj1,
                                        pipelines: pipelines, encoder: encoder)
                }
                core.drawPanelLabel(text: label, origin: quad.origin,
                                    right: quad.right, up: quad.up,
                                    cellSize: quad.glyph,
                                    color: Self.faded(Self.commLabelColor, quad.opacity),
                                    conchars: conchars,
                                    alternate: Self.commLabelAlternate,
                                    viewproj0: viewproj0, viewproj1: viewproj1,
                                    pipelines: pipelines, encoder: encoder)
            }
        }
    }

    // MARK: - Engine reporting

    /// Tell the engine what geometry this consumer renders: the per-eye
    /// pixel size (vid_null.c stays the single place drawable geometry is
    /// known) and the merged binocular fov its culling frustum must cover.
    private func reportViewGeometry(for drawable: LayerRenderer.Drawable) {
        let color = drawable.colorTextures[0]
        QC_RendererSetDrawableSize(Int32(color.width), Int32(color.height))

        // NB: no per-frame culling-fov report here. Immersive renders the
        // WHOLE level (omni, set once in run()); reporting the drawable's
        // ~100 deg binocular fov each frame here used to overwrite that back
        // to a body-forward cone, which is what made the world drop out on
        // move/turn/climb. The drawable size is all this needs to publish.
    }

    /// The correction that maps `pose`'s yaw and position to neutral —
    /// pitch and roll are left alone, they are genuinely the head's. This
    /// zeroes the head fully at recenter, so the baseline eye is the game
    /// eye (vieworg) and vertical head motion tracks from there (stand up
    /// and you rise). A floor-locked variant that preserved height and
    /// pinned the game floor to the real floor was tried and reverted: it
    /// depended on the tracking origin being at floor level, which did not
    /// hold on device and left the height wrong in both postures. Eye
    /// height is now trimmed live from the Comfort menu instead.
    private static func correction(zeroing pose: simd_float4x4) -> simd_float4x4 {
        // Device forward is -Z; its XZ heading is the yaw to undo.
        let f = -pose.columns.2
        let yaw = atan2(-f.x, -f.z)
        let rotation = simd_float4x4(simd_quatf(angle: yaw, axis: SIMD3(0, 1, 0)))
        var neutral = rotation
        neutral.columns.3 = pose.columns.3
        return neutral.inverse
    }

    // MARK: - Timing

    private func seconds(from instant: LayerRenderer.Clock.Instant) -> TimeInterval {
        let duration = LayerRenderer.Clock.Instant.epoch.duration(to: instant)
        return Double(duration.components.seconds)
            + Double(duration.components.attoseconds) * 1e-18
    }

    private func recordGPUTime(_ seconds: CFTimeInterval) {
        gpuStatsLock.lock()
        statGPUTotal += seconds
        statGPUWorst = max(statGPUWorst, seconds)
        gpuStatsLock.unlock()
    }

    private func recordFrameStats() {
        if statFrames == 0 {
            statCPUStart = CACurrentMediaTime()
        }
        statFrames += 1
        guard statFrames >= statsWindow else { return }

        let elapsed = CACurrentMediaTime() - statCPUStart
        gpuStatsLock.lock()
        let gpuAvgMS = statGPUTotal / Double(statFrames) * 1000
        let gpuWorstMS = statGPUWorst * 1000
        statGPUTotal = 0
        statGPUWorst = 0
        gpuStatsLock.unlock()

        let fps = Double(statFrames) / elapsed
        print(String(format: "[immersive] %.1f fps over %d frames, gpu avg %.2f ms worst %.2f ms",
                     fps, statFrames, gpuAvgMS, gpuWorstMS))
        statFrames = 0
    }
}

// MARK: - Device anchors

/// Owns the ARKit session and the world-tracking provider that serve the
/// immersive thread's device anchors, and rebuilds them when ARKit stops
/// them underneath us.
///
/// Why this is an object and not two stored properties on the renderer: an
/// ARKit data provider is single-use. Anything that interrupts tracking —
/// starting a Reality Composer Pro Developer Capture, a FaceTime call,
/// Guest Mode — stops every provider on the session, and nothing restarts
/// them. A stopped `WorldTrackingProvider` cannot be re-run, and querying
/// one answers nothing while logging "The device_anchor can only be queried
/// when the world tracking provider is running" on every frame, forever.
/// Recovery means a NEW provider on a NEW session, so the provider has to be
/// a `var` that somebody owns and swaps — this.
///
/// The hand session survived the same interruption only by accident:
/// `HandInput.run()` builds a fresh `ARKitSession` and a fresh
/// `HandTrackingProvider` every time hands are activated, and the immersive
/// space's teardown and re-creation drives `setActive(false)` then
/// `setActive(true)` through `InputHost` — a full rebuild, for free. The
/// world provider got neither: it was created once with the renderer, and
/// the renderer's own session was never even stopped. That is the whole
/// difference between "[summon] hand input ACTIVE" and a dead device anchor
/// in the same log.
///
/// Thread contract. `anchor(at:)` is for the render thread alone —
/// `ar_world_tracking_provider_query_device_anchor_at_timestamp` is
/// documented "not thread safe", and the render thread is the only caller.
/// The supervisor task never queries; it only publishes a replacement under
/// `lock`. The lock is held across the state check AND the query, so the
/// onset of an outage cannot slip a query through against a provider that
/// stopped between the two — that race is a burst of the very ARKit console
/// error this type exists to silence.
final class DeviceAnchorSource: @unchecked Sendable {

    private let lock = NSLock()
    private var session: ARKitSession?
    private var provider: WorldTrackingProvider?
    private var live = false
    private var supervisor: Task<Void, Never>?

    /// Raised when a REBUILT provider comes up (never on the first one), so
    /// the owner can put the world back under the player — see
    /// `QC_InputRequestRecenter`. Kept as a closure so this type stays pure
    /// ARKit and knows nothing about the engine.
    private let onRebuilt: @Sendable () -> Void

    /// Pause between a provider dying and its replacement being run, and the
    /// unit of the backoff. Short enough that an interruption costs a blink,
    /// long enough that a hard failure (no authorization, unsupported)
    /// cannot spin a core.
    private static let retryDelay = Duration.milliseconds(250)
    private static let maxBackoff = 8
    /// How long a provider has to stay up before the backoff is forgiven. A
    /// sustained interruption lets each new provider start and immediately
    /// stops it again; without this the backoff reset after every successful
    /// `run` and the rebuild cadence stayed flat at 4 Hz for the whole
    /// capture — a new session and provider every 250 ms, with log lines to
    /// match.
    private static let stableGrace = 2.0
    /// Engine-tick headroom between asking for the recenter and letting the
    /// render thread see the new provider. The request is drained on the
    /// engine thread (~11 ms at 90 Hz) and bumps `recenter_count`; until it
    /// lands, a head offset fed from the NEW origin would be absorbed
    /// against the OLD ledger, which is the body shove being prevented.
    private static let recenterSettle = Duration.milliseconds(50)
    /// How often the supervisor looks at the provider's state, and how long
    /// a `.paused` is tolerated before it is rebuilt like a stop. The grace
    /// is generous because a pause ARKit lifts by itself costs nothing to
    /// wait out; it only has to be short enough that a pause ARKit will
    /// never lift does not outlast the player's patience.
    private static let pollInterval = Duration.milliseconds(100)
    private static let pausedGrace = 1.5

    /// The one source allowed to run a world-tracking provider. A
    /// dismiss/reopen can briefly have two `ImmersiveRenderer`s alive (which
    /// is why `immersiveDidStop` checks identity at all), and two sources
    /// would each run a provider and each *auto-rebuild* when the other's
    /// arrival stopped theirs — they would fight, where the old code merely
    /// went dead. Claiming stands the previous one down first.
    private static let registry = NSLock()
    nonisolated(unsafe) private static weak var current: DeviceAnchorSource?

    init(onRebuilt: @escaping @Sendable () -> Void) {
        self.onRebuilt = onRebuilt
    }

    deinit {
        // Backstop. `[weak self]` on the supervisor is cosmetic -- once
        // `supervise()` is entered, self is strongly held for the whole
        // call -- so this only runs when `stop()` already did its work. It
        // is here so an escaped source can never outlive its owner with a
        // provider still running.
        stop()
    }

    func start() {
        // Before `live`, so an unsupported device does not later announce a
        // stand-down for something that never stood up.
        guard WorldTrackingProvider.isSupported else {
            print("[immersive] world tracking unsupported here -- no device anchors")
            return
        }

        Self.registry.lock()
        let previous = Self.current
        Self.current = self
        Self.registry.unlock()
        if previous !== self { previous?.stop() }

        lock.lock()
        guard !live else { lock.unlock(); return }
        live = true
        lock.unlock()

        let task = Task.detached(priority: .userInitiated) { [weak self] () -> Void in
            await self?.supervise()
        }
        // Under the lock like every other field, and cancelled immediately
        // if a stand-down beat the assignment -- `stop()` would otherwise
        // have read nil and left the supervisor running.
        lock.lock()
        if live { supervisor = task } else { task.cancel() }
        lock.unlock()
    }

    func stop() {
        Self.registry.lock()
        if Self.current === self { Self.current = nil }
        Self.registry.unlock()

        lock.lock()
        guard live else { lock.unlock(); return }
        live = false
        let dying = session
        let task = supervisor
        session = nil
        provider = nil
        supervisor = nil
        lock.unlock()

        task?.cancel()
        // Stopping the session also ends its event stream, which is how the
        // supervisor wakes up from `for await` and sees that it is no longer
        // live. Cancellation alone would not: the events sequence never
        // throws and is not documented to honour it.
        dying?.stop()
        print("[immersive] world tracking stood down")
    }

    /// The device anchor predicted for `timestamp`, or nil when there is no
    /// running provider to ask — during the start-up race, between an
    /// interruption and its recovery, or on a device without world tracking.
    /// Render thread only.
    func anchor(at timestamp: TimeInterval) -> DeviceAnchor? {
        // The state check and the query are ONE critical section. Reading
        // the reference under the lock and then checking state outside it
        // is a time-of-check/time-of-use gap: the provider can stop in
        // between and the query prints the per-frame ARKit error anyway,
        // which would fail a device check on an otherwise correct build.
        // The section is a reference read plus a prediction, the render
        // thread is its only caller, and the supervisor contends only on a
        // rare swap.
        lock.lock(); defer { lock.unlock() }
        // Gate on the provider's own state rather than on the query's nil.
        // Asking a provider that is not running is what produced the
        // per-frame ARKit error in the capture report, and it answers
        // nothing either way.
        guard let provider, provider.state == .running else { return nil }
        return provider.queryDeviceAnchor(atTimestamp: timestamp)
    }

    // MARK: - Supervision

    private var isLive: Bool {
        lock.lock(); defer { lock.unlock() }
        return live
    }

    /// Run a provider, park on the session's events until ARKit stops it,
    /// then build a replacement — for as long as this source is live.
    private func supervise() async {
        var backoff = 0
        var rebuild = false
        while isLive, !Task.isCancelled {
            let session = ARKitSession()
            let provider = WorldTrackingProvider()
            do {
                try await session.run([provider])
            } catch {
                print("[immersive] world tracking failed to run: \(error)")
                backoff = min(backoff + 1, Self.maxBackoff)
                try? await Task.sleep(for: Self.retryDelay * backoff)
                continue
            }

            // A REBUILT provider brings a tracking origin that need not be
            // the old one's. Left alone, the head offset computed against it
            // is fed to the engine as the player having physically walked
            // there, and IN_AbsorbHeadOffset sweeps the player box to match
            // -- metres of uncommanded translation, blocked by the first
            // wall, with the head yaw and the hand frame stale alongside.
            // Drive the engine's own recenter instead of re-zeroing the
            // render-side correction: vr_recenter absorbs the last good
            // residual, clears the ledger and bumps recenter_count in one
            // engine-thread step, and the count mismatch keeps absorption
            // frozen until the renderer echoes it against the new origin. A
            // render-side re-zero without that bump would walk the body
            // BACKWARDS by the whole absorbed total.
            //
            // Asked for -- and settled -- BEFORE the new provider is
            // published, so the render thread cannot feed a new-origin
            // offset while the old count is still current.
            if rebuild {
                print("[immersive] world tracking rebuilt -- recentering")
                onRebuilt()
                try? await Task.sleep(for: Self.recenterSettle)
            }

            guard adopt(session: session, provider: provider) else {
                // Stood down while we were starting; don't leave it running.
                session.stop()
                return
            }
            let ranAt = CACurrentMediaTime()
            print("[immersive] world tracking running")

            // ARKit's own error text for a state change, logged as a side
            // channel. It is the only place the reason for a stop appears.
            let errors = Task.detached(priority: .utility) { () -> Void in
                for await event in session.events {
                    guard case let .dataProviderStateChanged(_, newState, error) = event,
                          let error else { continue }
                    print("[immersive] world tracking \(newState): \(error)")
                }
            }
            let reason = await watch(provider)
            errors.cancel()

            // After the liveness check, not before it: a stand-down also
            // ends the watch, and announcing a rebuild there would be a
            // lie -- `stop()` has its own line.
            guard isLive, !Task.isCancelled else { break }
            print("[immersive] world tracking \(reason) -- rebuilding provider")
            // Forgive the backoff only for a provider that actually held.
            // A sustained interruption starts one and stops it again at
            // once; resetting on every successful `run` churned a session
            // and a provider every 250 ms for the capture's whole length.
            backoff = CACurrentMediaTime() - ranAt >= Self.stableGrace
                ? 0 : min(backoff + 1, Self.maxBackoff)
            rebuild = true
            // Retire the dead provider BEFORE building its replacement, so
            // the render thread cleanly skips frames in between rather than
            // querying a corpse.
            retire(session)
            try? await Task.sleep(for: Self.retryDelay * max(1, backoff))
        }
    }

    /// Watch a running provider until it is no longer usable, logging every
    /// state change, and return the reason to rebuild for.
    ///
    /// A poll rather than a bare `for await session.events`, which is what
    /// the previous version did and what broke the device: the events
    /// sequence parks indefinitely, so a provider that went `.paused` and
    /// never came back parked this loop with it and every frame skipped for
    /// the rest of the session. `data_provider.h:33-37` defines the states
    /// as `initialized / running / paused / stopped`, and neither the header
    /// nor the Swift interface documents a guaranteed transition BACK from
    /// either of the last two — so `.paused` is given a bounded grace (a
    /// pause ARKit lifts costs nothing, we just keep watching) and then
    /// rebuilt like a stop. That is what lets the system actually return to
    /// `.running` rather than hope.
    ///
    /// `.stopped` is immediate: `queryDeviceAnchor` on a stopped provider is
    /// the per-frame ARKit error this whole type exists to end.
    private func watch(_ provider: WorldTrackingProvider) async -> String {
        var last = provider.state
        var pausedSince: Double?
        while isLive, !Task.isCancelled {
            let state = provider.state
            if state != last {
                print("[immersive] world tracking \(state)")
                last = state
            }
            switch state {
            case .stopped:
                return "stopped"
            case .paused:
                let now = CACurrentMediaTime()
                guard let since = pausedSince else { pausedSince = now; break }
                if now - since >= Self.pausedGrace { return "paused too long" }
            default:
                pausedSince = nil
            }
            try? await Task.sleep(for: Self.pollInterval)
        }
        return "stood down"
    }

    /// Publishes a freshly running session/provider pair. Returns false if
    /// the source was stood down while the run was in flight, in which case
    /// the caller owns the orphan.
    private func adopt(session: ARKitSession, provider: WorldTrackingProvider) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard live else { return false }
        self.session?.stop()
        self.session = session
        self.provider = provider
        return true
    }

    private func retire(_ dead: ARKitSession) {
        lock.lock()
        if session === dead {
            session = nil
            provider = nil
        }
        lock.unlock()
        dead.stop()
    }
}
