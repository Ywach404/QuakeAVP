// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  ExportRenderer.swift
//
//  The third consumer: renders one packet per engine step into offscreen
//  textures at the export size, accumulating sub-steps for motion blur and
//  resolving into whatever bgra8 texture the encoder hands over. Only ever
//  driven inside `RendererCore.withConsumer(.export)` from the exporter's
//  thread (DemoExporter). Never calls engine entry points.
//
//  Cameras: Gun is the packet's own mono viewproj (what the flat window
//  draws, the aim direction). Head cams take the sidecar pose at the
//  packet's time and build the view the same way the immersive path does --
//  tracking axes (x right, y up, -z forward) in Quake units -- so the export
//  looks where the player looked.
//

import Metal
import simd

enum ExportCamera {
    case head(VRTrack)
    case smoothedHead(VRTrack)
    case gun
    /// Third person: the player model is drawn (chase_active 1). Chase is
    /// the engine's own chase cam; Orbit and Front park the engine's view
    /// origin where the exporter asks (QC_ExportSetViewOrigin) and look at
    /// the player.
    case chase
    case orbit
    case front

    /// Cameras that look somewhere other than where the engine culls need
    /// the immersive path's PVS-only culling.
    var needsOmniCulling: Bool {
        switch self {
        case .gun, .chase: return false
        default: return true
        }
    }

    var isThirdPerson: Bool {
        switch self {
        case .chase, .orbit, .front: return true
        default: return false
        }
    }

    /// The exporter feeds a world position for the engine's viewpoint.
    var drivesViewOrigin: Bool {
        switch self {
        case .orbit, .front: return true
        default: return false
        }
    }

    var track: VRTrack? {
        switch self {
        case .head(let t), .smoothedHead(let t): return t
        default: return nil
        }
    }
}

final class ExportRenderer {

    let width: Int
    let height: Int

    private let core: RendererCore
    private let pipelines: RenderPipelines
    private let color: MTLTexture
    private let depth: MTLTexture
    private let accumulator: MTLTexture
    private let accumulatePipeline: MTLComputePipelineState
    private let resolvePipeline: MTLComputePipelineState
    private let projection: simd_float4x4

    init?(core: RendererCore, width: Int, height: Int, fovXDegrees: Float, farClip: Float = 65536) {
        guard let pipelines = core.makePipelines(colorFormat: .bgra8Unorm, depthFormat: .depth32Float,
                                                 amplified: false, reverseDepth: false)
        else { return nil }
        let device = core.device
        func texture(_ format: MTLPixelFormat, _ usage: MTLTextureUsage) -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: format, width: width, height: height, mipmapped: false)
            desc.usage = usage
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }
        guard let color = texture(.bgra8Unorm, [.renderTarget, .shaderRead, .shaderWrite]),
              let depth = texture(.depth32Float, [.renderTarget]),
              let accumulator = texture(.rgba16Float, [.shaderRead, .shaderWrite]),
              let accumulateFn = core.library.makeFunction(name: "export_accumulate"),
              let resolveFn = core.library.makeFunction(name: "export_resolve"),
              let accumulatePipeline = try? device.makeComputePipelineState(function: accumulateFn),
              let resolvePipeline = try? device.makeComputePipelineState(function: resolveFn)
        else { return nil }

        self.core = core
        self.pipelines = pipelines
        self.width = width
        self.height = height
        self.color = color
        self.depth = depth
        self.accumulator = accumulator
        self.accumulatePipeline = accumulatePipeline
        self.resolvePipeline = resolvePipeline
        self.projection = Self.perspective(fovXDegrees: fovXDegrees,
                                           aspect: Float(width) / Float(height),
                                           near: 4, far: farClip)
    }

    /// Metal clip space (depth 0..1), eye space x right / y up / -z forward.
    static func perspective(fovXDegrees: Float, aspect: Float, near: Float, far: Float) -> simd_float4x4 {
        let xmax = near * tan(fovXDegrees * .pi / 360)
        let ymax = xmax / aspect
        var m = simd_float4x4(0)
        m.columns.0.x = near / xmax
        m.columns.1.y = near / ymax
        m.columns.2.z = far / (near - far)
        m.columns.2.w = -1
        m.columns.3.z = near * far / (near - far)
        return m
    }

    /// World -> clip and the eye origin for one sub-step.
    func viewProjection(frame f: qc_frame_t, camera: ExportCamera) -> (simd_float4x4, SIMD3<Float>) {
        switch camera {
        case .gun:
            let vp = simd_float4x4(columns: (
                SIMD4(f.viewproj.0, f.viewproj.1, f.viewproj.2, f.viewproj.3),
                SIMD4(f.viewproj.4, f.viewproj.5, f.viewproj.6, f.viewproj.7),
                SIMD4(f.viewproj.8, f.viewproj.9, f.viewproj.10, f.viewproj.11),
                SIMD4(f.viewproj.12, f.viewproj.13, f.viewproj.14, f.viewproj.15)))
            return (vp, SIMD3(f.vieworg.0, f.vieworg.1, f.vieworg.2))
        case .head(let track), .smoothedHead(let track):
            let s = track.sample(at: f.time)
            var pose = simd_float4x4(s.orientation)
            pose.columns.3 = SIMD4(s.position.x, s.position.y, s.position.z, 1)
            return (projection * pose.inverse, s.position)
        case .chase:
            return viewProjection(frame: f, camera: .gun)
        case .orbit, .front:
            // The engine already traced the requested position to the walls
            // and published where the camera ended up; look at the player's
            // chest from there.
            let eye = SIMD3(f.vieworg.0, f.vieworg.1, f.vieworg.2)
            let target = SIMD3(f.player_org.0, f.player_org.1, f.player_org.2 + 24)
            return (projection * Self.lookAt(eye: eye, target: target).inverse, eye)
        }
    }

    /// Eye -> world pose in the tracking axis convention (x right, y up,
    /// -z forward), Quake world up is +z.
    static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>) -> simd_float4x4 {
        var forward = target - eye
        if simd_length(forward) < 1e-3 { forward = SIMD3(1, 0, 0) }
        forward = simd_normalize(forward)
        var right = simd_cross(forward, SIMD3(0, 0, 1))
        if simd_length(right) < 1e-4 { right = simd_cross(forward, SIMD3(1, 0, 0)) }
        right = simd_normalize(right)
        let up = simd_cross(right, forward)
        return simd_float4x4(columns: (
            SIMD4(right.x, right.y, right.z, 0),
            SIMD4(up.x, up.y, up.z, 0),
            SIMD4(-forward.x, -forward.y, -forward.z, 0),
            SIMD4(eye.x, eye.y, eye.z, 1)))
    }

    /// Render `f` with `camera` and add it to the accumulator with `weight`.
    func accumulate(frame f: qc_frame_t, camera: ExportCamera, weight: Float,
                    commandBuffer: MTLCommandBuffer) {
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = color
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(
            red: Double(f.clear_color.0), green: Double(f.clear_color.1),
            blue: Double(f.clear_color.2), alpha: 1)
        pass.depthAttachment.texture = depth
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }

        let (viewproj, eye) = viewProjection(frame: f, camera: camera)
        let eye4 = SIMD4(eye.x, eye.y, eye.z, 1)
        let uniforms = RendererCore.WorldUniforms(
            viewproj0: viewproj, viewproj1: viewproj, eyeorg0: eye4, eyeorg1: eye4)
        // No passthrough offline: the dissolve is off (radius 0, sky solid).
        let phase = RendererCore.PhaseParams(
            headorg: eye, radius: 0, skyFade: 1, rimColor: SIMD3(1.5, 0.93, 0.27))
        let w = Double(width), h = Double(height)
        // Gun cam is the flat window: the view-locked weapon squished into
        // the near depth range. Head cams are the immersive view: the hand
        // weapon arrives as a world entity, the body-locked one is skipped.
        var viewports: (full: MTLViewport, squished: MTLViewport)?
        if case .gun = camera {
            viewports = (
                full: MTLViewport(originX: 0, originY: 0, width: w, height: h, znear: 0, zfar: 1),
                squished: MTLViewport(originX: 0, originY: 0, width: w, height: h, znear: 0, zfar: 0.3))
        }
        core.encode(frame: f, with: encoder, pipelines: pipelines, uniforms: uniforms,
                    phase: phase, amplificationCount: 1, viewmodelViewport: viewports,
                    drawsViewmodel: false)
        encoder.endEncoding()

        guard let compute = commandBuffer.makeComputeCommandEncoder() else { return }
        var wgt = weight
        compute.setComputePipelineState(accumulatePipeline)
        compute.setTexture(color, index: 0)
        compute.setTexture(accumulator, index: 1)
        compute.setBytes(&wgt, length: MemoryLayout<Float>.size, index: 0)
        compute.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()
    }

    /// Resolve the accumulated frame, draw the HUD over it (sharp, never
    /// blurred), and copy into `target` (the encoder's bgra8 buffer).
    func resolve(into target: MTLTexture, hud: [Float], atlasTexnum: UInt32,
                 commandBuffer: MTLCommandBuffer) {
        guard let compute = commandBuffer.makeComputeCommandEncoder() else { return }
        compute.setComputePipelineState(resolvePipeline)
        compute.setTexture(accumulator, index: 0)
        compute.setTexture(color, index: 1)
        compute.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        compute.endEncoding()

        if !hud.isEmpty, atlasTexnum != 0 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = color
            pass.colorAttachments[0].loadAction = .load
            pass.colorAttachments[0].storeAction = .store
            pass.depthAttachment.texture = depth
            pass.depthAttachment.loadAction = .dontCare
            pass.depthAttachment.storeAction = .dontCare
            if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) {
                core.drawScreenText(hud, atlasTexnum: atlasTexnum, width: width, height: height,
                                    pipelines: pipelines, encoder: encoder)
                encoder.endEncoding()
            }
        }

        if let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.copy(from: color, to: target)
            blit.endEncoding()
        }
    }
}
