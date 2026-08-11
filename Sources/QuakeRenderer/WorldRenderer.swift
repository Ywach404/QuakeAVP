//
//  WorldRenderer.swift
//
//  The flat window's half of the consumer: an MTKView delegate that runs one
//  RendererCore consume cycle per display-link tick, mono. It exists as the
//  debug view — the immersive space is the real output — so it draws exactly
//  what the packet's own viewproj describes and nothing more.
//
//  While the immersive space is open the core's arbitration hands the packet
//  stream to the compositor thread and `withConsumer` here returns nil, so a
//  straggling draw callback cannot race the immersive consumer. Nothing in
//  this file ever calls QC_* engine entry points.
//

import Metal
import MetalKit

final class WorldRenderer: NSObject, MTKViewDelegate {

    private let core: RendererCore
    private let pipelines: RenderPipelines

    init?(core: RendererCore, colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        guard let pipelines = core.makePipelines(
            colorFormat: colorPixelFormat,
            depthFormat: depthPixelFormat,
            amplified: false,
            reverseDepth: false)
        else { return nil }

        self.core = core
        self.pipelines = pipelines
        super.init()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // Only report while this view owns the packet stream; the immersive
        // layer reports its own view size when it is the consumer.
        _ = core.withConsumer(.window) {
            QC_RendererSetDrawableSize(Int32(size.width), Int32(size.height))
        }
    }

    func draw(in view: MTKView) {
        _ = core.withConsumer(.window) {
            drawLocked(in: view)
        }
    }

    private func drawLocked(in view: MTKView) {
        // Re-assert this view's drawable size every frame (the C side
        // dedupes): after the immersive space closes, the engine is still
        // sized for the headset views and there is no resize event to
        // trigger the usual callback.
        QC_RendererSetDrawableSize(Int32(view.drawableSize.width),
                                   Int32(view.drawableSize.height))

        guard let commandBuffer = core.commandQueue.makeCommandBuffer() else { return }

        let mipCandidates = core.drainTextureQueues()
        if !mipCandidates.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
            for texture in mipCandidates {
                blit.generateMipmaps(for: texture)
            }
            blit.endEncoding()
        }

        let frame = QC_RendererAcquireFrame()
        defer { if frame != nil { QC_RendererReleaseFrame() } }

        if let frame {
            view.clearColor = MTLClearColor(
                red: Double(frame.pointee.clear_color.0),
                green: Double(frame.pointee.clear_color.1),
                blue: Double(frame.pointee.clear_color.2),
                alpha: 1)
        }

        guard
            let passDescriptor = view.currentRenderPassDescriptor,
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
        else {
            commandBuffer.commit()
            return
        }

        if let frame {
            let f = frame.pointee
            let viewproj = simd_float4x4(columns: (
                SIMD4(f.viewproj.0, f.viewproj.1, f.viewproj.2, f.viewproj.3),
                SIMD4(f.viewproj.4, f.viewproj.5, f.viewproj.6, f.viewproj.7),
                SIMD4(f.viewproj.8, f.viewproj.9, f.viewproj.10, f.viewproj.11),
                SIMD4(f.viewproj.12, f.viewproj.13, f.viewproj.14, f.viewproj.15)))
            let eyeorg = SIMD4<Float>(f.vieworg.0, f.vieworg.1, f.vieworg.2, 1)
            let uniforms = RendererCore.WorldUniforms(
                viewproj0: viewproj, viewproj1: viewproj,
                eyeorg0: eyeorg, eyeorg1: eyeorg)
            core.encode(frame: f, with: encoder, pipelines: pipelines,
                        uniforms: uniforms, amplificationCount: 1)
        }
        encoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }
}
