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
    private let onStop: () -> Void

    private let arSession = ARKitSession()
    private let worldTracking = WorldTrackingProvider()

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

    // Frame timing stats, logged every `statsWindow` frames.
    private let statsWindow = 300
    private var statFrames = 0
    private var statCPUStart = 0.0
    private var statGPUTotal = 0.0
    private var statGPUWorst = 0.0
    private let gpuStatsLock = NSLock()

    init(layerRenderer: LayerRenderer, core: RendererCore, onStop: @escaping () -> Void) {
        self.layerRenderer = layerRenderer
        self.core = core
        self.onStop = onStop
    }

    func start() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                print("[immersive] ARKitSession failed: \(error)")
            }
        }

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
                layerRenderer.waitUntilRunning()
            case .running:
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
        print("[immersive] layer invalidated, render thread exiting")
        onStop()
    }

    private func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        // No per-frame input to gather until M4.
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        if pipelines == nil {
            buildPipelines()
        }
        guard let pipelines else { return }

        frame.startSubmission()
        guard let drawable = frame.queryDrawables().first else {
            // The layer is pausing or being torn down mid-frame. There is
            // nothing to present, and ending a submission that presented
            // nothing trips CompositorServices' client-bug abort — so leave
            // it open and bail; the state machine in run() handles the rest.
            return
        }

        // Late latch: the device pose is sampled here, after the input-time
        // wait, immediately before matrix composition and encode.
        let anchorTime = seconds(from: timing.presentationTime)
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: anchorTime)
        drawable.deviceAnchor = deviceAnchor


        reportViewGeometry(for: drawable)

        let presented = core.withConsumer(.immersive) { () -> Bool in
            guard let commandBuffer = core.commandQueue.makeCommandBuffer() else { return false }

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
            drawable.encodePresent(commandBuffer: commandBuffer)
            commandBuffer.commit()
            return true
        } ?? false

        if !presented {
            // Lost the packet stream (handover) or no command buffer: the
            // drawable must still be presented before the submission ends.
            if let commandBuffer = core.commandQueue.makeCommandBuffer() {
                drawable.encodePresent(commandBuffer: commandBuffer)
                commandBuffer.commit()
            }
        }
        frame.endSubmission()
        recordFrameStats()
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

        // 2D HUD panel (vr_hud): wrist or float, in the SAME corrected
        // tracking space and handViewproj as the hand debug/virtual hand
        // above -- a world-space panel built once per frame, composed with
        // each eye's handViewproj at the draw call below.
        let hudModel: simd_float4x4? = packet.flatMap {
            hudPanelModel(packet: $0, originFromDevice: originFromDevice,
                         headPoseAvailable: deviceAnchor != nil)
        }

        // Modular HUD tiles (vr_hud 3): per-tile model matrices in the SAME
        // corrected tracking space as hudModel above, resolved once and
        // shared by both eyes/branches below. Empty whenever hud_mode != 3
        // (hudTileModels itself guards that), so drawHudTiles is always
        // safe to call unconditionally -- it no-ops for modes 0/1/2.
        let tileModels: [simd_float4x4?] = packet.map {
            hudTileModels(packet: $0, originFromDevice: originFromDevice,
                         headPoseAvailable: deviceAnchor != nil)
        } ?? []

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
                core.drawHudTiles(frame: packet, tileModels: tileModels,
                                  viewproj0: handViewproj[0], viewproj1: handViewproj[1],
                                  pipelines: pipelines, encoder: encoder)
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
                    core.drawHudTiles(frame: packet, tileModels: tileModels,
                                      viewproj0: handViewproj[index], viewproj1: handViewproj[index],
                                      pipelines: pipelines, encoder: encoder)
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

    /// This frame's per-tile model matrices for the modular HUD, one entry
    /// per `packet.hud_tiles[i]` (fixed order AMMO/FACE/HEALTHARMOR — see
    /// `qc_frame_t`'s doc comment), nil where that tile drew nothing this
    /// frame (`vert_count == 0`) or its anchor has no live pose right now.
    /// Resolved once per frame, shared by both eyes, exactly like the
    /// whole-panel `hudPanelModel(packet:...)` above.
    private func hudTileModels(packet: qc_frame_t, originFromDevice: simd_float4x4,
                               headPoseAvailable: Bool) -> [simd_float4x4?] {
        guard packet.hud_mode == 3, packet.num_hud_tiles > 0, let tiles = packet.hud_tiles
        else { return [] }

        // Resolved once per frame rather than per tile: every OFFWRIST tile
        // shares one wrist-or-float frame, every GUN tile shares one
        // gun-or-nothing frame.
        let offwrist = offWristAnchorFrame(originFromDevice: originFromDevice,
                                           headPoseAvailable: headPoseAvailable)
        let gun = gunAnchorFrame()

        var models: [simd_float4x4?] = []
        for i in 0..<Int(packet.num_hud_tiles) {
            let tile = tiles[i]
            guard tile.vert_count > 0 else { models.append(nil); continue }
            let anchor = (tile.anchor == QC_HUD_ANCHOR_GUN) ? gun : offwrist
            guard let anchor else { models.append(nil); continue }
            models.append(RendererCore.hudTileModel(tile: tile, anchor: anchor,
                                                     pixelScale: Self.hudTilePixelScale))
        }
        return models
    }

    /// OFFWRIST anchor frame for modular tiles: the off-hand wrist,
    /// billboarded toward the eye, exactly like the wrist-mode whole panel
    /// above — falling back to the float frame the instant the off-hand
    /// isn't tracked (Review Focus #2: never pin a wrist tile to a stale or
    /// zero pose), and to nil (hide) if even the head pose is unavailable.
    private func offWristAnchorFrame(originFromDevice: simd_float4x4,
                                     headPoseAvailable: Bool) -> RendererCore.HudAnchorFrame? {
        if let wrist = offHandWristPosition() {
            let eye = ViewerPose.shared.eye
            let toEye = eye - wrist
            let toward = simd_length(toEye) > 1e-4 ? simd_normalize(toEye) : SIMD3<Float>(0, 0, 1)
            let basis = RendererCore.billboardBasis(toward: toward)
            let origin = wrist + basis.up * Self.wristLift
            return RendererCore.HudAnchorFrame(origin: origin, right: basis.right, up: basis.up,
                                               forward: toward)
        }
        guard headPoseAvailable else { return nil }
        return floatAnchorFrame(originFromDevice: originFromDevice)
    }

    /// The float placement as an anchor frame — same maths as the
    /// whole-panel float branch above (ahead of the head, yaw+level only,
    /// no pitch), reused both as `hud_mode == 2`'s panel source and as the
    /// OFFWRIST tile fallback when the wrist isn't tracked.
    private func floatAnchorFrame(originFromDevice: simd_float4x4) -> RendererCore.HudAnchorFrame {
        let headPos = originFromDevice.columns.3
        let headForward4 = originFromDevice * SIMD4<Float>(0, 0, -1, 0)
        let flatForward = SIMD3(headForward4.x, 0, headForward4.z)
        let forward = simd_length(flatForward) > 1e-4 ? simd_normalize(flatForward) : SIMD3<Float>(0, 0, -1)
        let origin = SIMD3(headPos.x, headPos.y, headPos.z)
            + forward * Self.floatDistance
            - SIMD3<Float>(0, Self.floatLowerOffset, 0)
        let basis = RendererCore.billboardBasis(toward: -forward)
        return RendererCore.HudAnchorFrame(origin: origin, right: basis.right, up: basis.up,
                                           forward: -forward)
    }

    /// GUN anchor frame for modular tiles: the dominant hand's controller
    /// pose, billboarded toward the eye like the wrist frame. nil (hide,
    /// never a stale pose) whenever controllers aren't tracking — there is
    /// no ARKit-hands equivalent published continuously enough to trust
    /// here (the gun hand gets no rigid-hand model either, see
    /// `offHandWristPosition`'s sibling code above: "the gun hand gets no
    /// model"), so a GUN-anchored tile simply doesn't draw in hands-only
    /// play until that's added.
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

    /// The dominant hand's controller grip position, corrected tracking
    /// space — the same source (`SpatialControllerTracker`) and correction
    /// the engine's own aim feed uses above, just read again here rather
    /// than cached across frames (this runs only when `vr_hud 3`, and
    /// cheaply). nil whenever controllers aren't tracking.
    private func gunPosition() -> SIMD3<Float>? {
        guard SpatialControllerTracker.shared.isTracking else { return nil }
        let rightHanded = VRSettings.shared.rightHanded
        guard let domPose = SpatialControllerTracker.shared.pose(left: !rightHanded) else { return nil }
        let p = recenterCorrection * domPose.columns.3
        return SIMD3(p.x, p.y, p.z)
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
