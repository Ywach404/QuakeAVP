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
        QC_InputSetAim(0, 0, 0, 0, 0, 0)   // release the hand aim; body-anchored on the flat window
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
                QC_InputSetAim(1, -o.z / s, o.x / s, o.y / s, aimYaw, aimPitch)
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
        let handDebug: [Float] = HandDebug.shared.enabled ? HandDebug.shared.snapshot() : []

        // The virtual hand stands in while the world is solid and fades out
        // (1 - phase) as the melt reveals the real hand through passthrough.
        // Same corrected-tracking space and handViewproj as the debug bones.
        // Suppressed while the green wireframe is up -- otherwise the solid
        // skin/cuff hand draws over the wireframe (the stray skin/blue polys).
        let virtualHand: [Float] = HandDebug.shared.enabled ? [] : VirtualHand.shared.snapshot()
        let handOpacity: Float = 1 - (packet?.phase ?? 0)

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
