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

    /// bgra8Unorm views over the drawable's sRGB color textures, keyed by
    /// texture identity (drawables recycle a small pool). Quake's textures
    /// are sRGB-authored values in unorm storage; writing them through a
    /// unorm view stores them byte-identical, and the compositor's sRGB
    /// decode then displays exactly what the flat window shows. Rendering
    /// into the sRGB format directly would re-encode and wash the world out.
    private var unormViews: [ObjectIdentifier: MTLTexture] = [:]

    /// Culling fov last reported to the engine, to dedupe the C call.
    private var reportedCullFov = SIMD2<Float>(0, 0)

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
        let originFromDevice = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        // World->tracking-origin: the Quake camera basis, scaled to metres.
        // The tracking origin *is* the player's eye at the published pose;
        // the head pose composes on top of it.
        var originFromQuake = matrix_identity_float4x4
        var quakeFromOrigin = matrix_identity_float4x4
        if let packet {
            let quakeView = RendererCore.quakeViewMatrix(
                origin: SIMD3(packet.vieworg.0, packet.vieworg.1, packet.vieworg.2),
                angles: SIMD3(packet.viewangles.0, packet.viewangles.1, packet.viewangles.2))
            let s = packet.world_scale > 0 ? packet.world_scale : 0.0254
            let scale = simd_float4x4(diagonal: SIMD4(s, s, s, 1))
            originFromQuake = scale * quakeView
            quakeFromOrigin = originFromQuake.inverse
        }

        var eyeViewproj: [simd_float4x4] = []
        var eyeOrigin: [SIMD4<Float>] = []
        for index in views.indices {
            let originFromEye = originFromDevice * views[index].transform
            let projection = drawable.computeProjection(viewIndex: index)
            eyeViewproj.append(projection * originFromEye.inverse * originFromQuake)
            // Per-eye view origin back in Quake units, for the sky
            // projection — this is what keeps the sky from mismatching
            // between the eyes.
            eyeOrigin.append(quakeFromOrigin * originFromEye.columns.3)
        }

        let clear: MTLClearColor
        if let packet {
            clear = MTLClearColor(
                red: Double(packet.clear_color.0),
                green: Double(packet.clear_color.1),
                blue: Double(packet.clear_color.2),
                alpha: 1)
        } else {
            clear = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        }

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
                            uniforms: uniforms, amplificationCount: 2)
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
                                uniforms: uniforms, amplificationCount: 1)
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
        descriptor.colorAttachments[0].texture = unormView(of: drawable.colorTextures[textureIndex])
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

    private func unormView(of texture: MTLTexture) -> MTLTexture {
        guard texture.pixelFormat == .bgra8Unorm_srgb else { return texture }
        let key = ObjectIdentifier(texture)
        if let view = unormViews[key] { return view }
        let view = texture.makeTextureView(pixelFormat: .bgra8Unorm) ?? texture
        unormViews[key] = view
        return view
    }

    private func buildPipelines() {
        let configuration = layerRenderer.configuration
        let colorFormat: MTLPixelFormat =
            configuration.colorFormat == .bgra8Unorm_srgb ? .bgra8Unorm : configuration.colorFormat

        singlePassStereo = configuration.layout == .layered
            && core.device.supportsVertexAmplificationCount(2)

        pipelines = core.makePipelines(
            colorFormat: colorFormat,
            depthFormat: configuration.depthFormat,
            amplified: singlePassStereo,
            reverseDepth: true)

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

        // Widest symmetric fov across both eyes, from the projection
        // matrices themselves (P00 = 2/(tanL+tanR), P20 = (tanR-tanL)/…).
        var maxTanX: Float = 0
        var maxTanY: Float = 0
        for index in drawable.views.indices {
            let p = drawable.computeProjection(viewIndex: index)
            let tanRight = abs((1 + p.columns.2.x) / p.columns.0.x)
            let tanLeft = abs((1 - p.columns.2.x) / p.columns.0.x)
            let tanTop = abs((1 + p.columns.2.y) / p.columns.1.y)
            let tanBottom = abs((1 - p.columns.2.y) / p.columns.1.y)
            maxTanX = max(maxTanX, tanLeft, tanRight)
            maxTanY = max(maxTanY, tanTop, tanBottom)
        }
        let fov = SIMD2<Float>(
            2 * atan(maxTanX) * 180 / .pi,
            2 * atan(maxTanY) * 180 / .pi)
        if abs(fov.x - reportedCullFov.x) > 0.5 || abs(fov.y - reportedCullFov.y) > 0.5 {
            reportedCullFov = fov
            QC_RendererSetCullingFov(fov.x, fov.y)
        }
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
