//
//  WorldRenderer.swift
//
//  The consumer half of the renderer bridge (see qr_bridge.c for the
//  producer). Runs entirely on MTKView's draw thread and talks to the engine
//  only through the QC_Renderer* handoff API: it drains texture uploads into
//  MTLTextures, mirrors the world vertex array into an MTLBuffer once per
//  map, and each frame copies the latest packet's indices into a ring buffer
//  and encodes one draw call per batch. Nothing here ever calls QC_* engine
//  entry points, so the engine-thread rule is preserved by construction.
//
//  Batches arrive in draw order (sky, opaque world, liquids) with a kind
//  that selects the pipeline; all animation state (cl.time, view origin,
//  sky textures) travels in the packet, never sampled on this thread.
//

import Metal
import MetalKit

final class WorldRenderer: NSObject, MTKViewDelegate {

    // Layouts must match LiquidUniforms / SkyUniforms in World.metal.
    private struct LiquidUniforms {
        var time: Float
        var alpha: Float
    }

    private struct SkyUniforms {
        var vieworgTime: SIMD4<Float>
        var skyalpha: Float
    }

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let worldPipeline: MTLRenderPipelineState
    private let liquidPipeline: MTLRenderPipelineState
    private let skyLayersPipeline: MTLRenderPipelineState
    private let skyBoxPipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let noWriteDepthState: MTLDepthStencilState
    private let worldSampler: MTLSamplerState
    private let lightmapSampler: MTLSamplerState

    /// Engine texnum -> GPU texture, mutated only on the draw thread.
    private var textures: [UInt32: MTLTexture] = [:]

    /// 0.5 gray: a batch with no lightmap renders albedo * 0.5 * 2 = albedo.
    private let neutralLightmap: MTLTexture

    /// Upstream's pink/black "notexture" checker: any batch whose texture
    /// hasn't been uploaded yet draws this, so a miss is loud, not invisible.
    private let missingTexture: MTLTexture

    private var vertexBuffer: MTLBuffer?
    private var geometryGeneration: UInt32 = 0

    /// Index data is copied out of the frame packet each draw; a small ring
    /// keeps the GPU from reading a buffer the CPU is rewriting.
    private var indexBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var ringIndex = 0

    init?(colorPixelFormat: MTLPixelFormat, depthPixelFormat: MTLPixelFormat) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary(),
            let vertexFunction = library.makeFunction(name: "world_vertex")
        else { return nil }

        func makePipeline(fragment: String, blended: Bool) -> MTLRenderPipelineState? {
            guard let fragmentFunction = library.makeFunction(name: fragment) else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
            descriptor.depthAttachmentPixelFormat = depthPixelFormat
            if blended {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .zero
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true

        // Translucent liquids test but don't write, like upstream's
        // glDepthMask(GL_FALSE) in R_BeginTransparentDrawing.
        let noWriteDepthDescriptor = MTLDepthStencilDescriptor()
        noWriteDepthDescriptor.depthCompareFunction = .lessEqual
        noWriteDepthDescriptor.isDepthWriteEnabled = false

        // World textures wrap and get the full mip/aniso treatment; lightmap
        // atlases must clamp (blocks are packed edge to edge) and have no
        // mips. Skybox faces reuse the clamping sampler: clamp-to-edge is
        // what Sky_EmitSkyBoxVertex's half-texel seam remap emulated.
        let worldSamplerDescriptor = MTLSamplerDescriptor()
        worldSamplerDescriptor.minFilter = .linear
        worldSamplerDescriptor.magFilter = .linear
        worldSamplerDescriptor.mipFilter = .linear
        worldSamplerDescriptor.sAddressMode = .repeat
        worldSamplerDescriptor.tAddressMode = .repeat
        worldSamplerDescriptor.maxAnisotropy = 8

        let lightmapSamplerDescriptor = MTLSamplerDescriptor()
        lightmapSamplerDescriptor.minFilter = .linear
        lightmapSamplerDescriptor.magFilter = .linear
        lightmapSamplerDescriptor.sAddressMode = .clampToEdge
        lightmapSamplerDescriptor.tAddressMode = .clampToEdge

        let smallTextureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)

        let checkerDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 2, height: 2, mipmapped: false)

        guard
            let worldPipeline = makePipeline(fragment: "world_fragment", blended: false),
            let liquidPipeline = makePipeline(fragment: "liquid_fragment", blended: true),
            let skyLayersPipeline = makePipeline(fragment: "sky_layers_fragment", blended: false),
            let skyBoxPipeline = makePipeline(fragment: "sky_box_fragment", blended: false),
            let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
            let noWriteDepthState = device.makeDepthStencilState(descriptor: noWriteDepthDescriptor),
            let worldSampler = device.makeSamplerState(descriptor: worldSamplerDescriptor),
            let lightmapSampler = device.makeSamplerState(descriptor: lightmapSamplerDescriptor),
            let neutralLightmap = device.makeTexture(descriptor: smallTextureDescriptor),
            let missingTexture = device.makeTexture(descriptor: checkerDescriptor)
        else { return nil }

        var gray: [UInt8] = [128, 128, 128, 255]
        neutralLightmap.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0, withBytes: &gray, bytesPerRow: 4)

        // Same pixels as the bridge's notexture (qr_bridge.c).
        var checker: [UInt8] = [
            159, 91, 83, 255,   0, 0, 0, 255,
            0, 0, 0, 255,       159, 91, 83, 255,
        ]
        missingTexture.replace(
            region: MTLRegionMake2D(0, 0, 2, 2),
            mipmapLevel: 0, withBytes: &checker, bytesPerRow: 8)

        self.device = device
        self.commandQueue = queue
        self.worldPipeline = worldPipeline
        self.liquidPipeline = liquidPipeline
        self.skyLayersPipeline = skyLayersPipeline
        self.skyBoxPipeline = skyBoxPipeline
        self.depthState = depthState
        self.noWriteDepthState = noWriteDepthState
        self.worldSampler = worldSampler
        self.lightmapSampler = lightmapSampler
        self.neutralLightmap = neutralLightmap
        self.missingTexture = missingTexture
        super.init()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        QC_RendererSetDrawableSize(Int32(size.width), Int32(size.height))
    }

    func draw(in view: MTKView) {
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }

        let mipCandidates = drainTextureQueues()
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
            encode(frame: frame.pointee, with: encoder)
        }
        encoder.endEncoding()

        if let drawable = view.currentDrawable {
            commandBuffer.present(drawable)
        }
        commandBuffer.commit()
    }

    // MARK: - Frame encoding

    private func encode(frame: qc_frame_t, with encoder: MTLRenderCommandEncoder) {
        guard frame.num_batches > 0, frame.num_indices > 0,
              let batches = frame.batches
        else { return }
        guard syncGeometry(generation: frame.generation),
              let vertexBuffer,
              let indexBuffer = copyIndices(from: frame)
        else { return }

        encoder.label = "world"
        encoder.setDepthStencilState(depthState)
        // The bridge already backface-culls, and Quake's fan winding flips
        // with SURF_PLANEBACK, so GPU face culling would drop half the world.
        encoder.setCullMode(.none)

        var viewproj = frame.viewproj
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &viewproj) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.setFragmentSamplerState(worldSampler, index: 0)
        encoder.setFragmentSamplerState(lightmapSampler, index: 1)

        var skyUniforms = SkyUniforms(
            vieworgTime: SIMD4(frame.vieworg.0, frame.vieworg.1, frame.vieworg.2, frame.time),
            skyalpha: 1)
        let skyboxTexnums = [
            frame.skybox_texnums.0, frame.skybox_texnums.1, frame.skybox_texnums.2,
            frame.skybox_texnums.3, frame.skybox_texnums.4, frame.skybox_texnums.5,
        ]
        let hasSkybox = skyboxTexnums[0] != 0

        var currentKind = UInt32.max
        for i in 0..<Int(frame.num_batches) {
            let batch = batches[i]

            if batch.kind != currentKind {
                currentKind = batch.kind
                switch batch.kind {
                case UInt32(QC_BATCH_SKY):
                    encoder.setRenderPipelineState(hasSkybox ? skyBoxPipeline : skyLayersPipeline)
                    encoder.setDepthStencilState(depthState)
                    if hasSkybox {
                        for (slot, texnum) in skyboxTexnums.enumerated() {
                            encoder.setFragmentTexture(textures[texnum] ?? missingTexture, index: slot)
                        }
                    } else {
                        encoder.setFragmentTexture(
                            textures[frame.sky_solid_texnum] ?? missingTexture, index: 0)
                        encoder.setFragmentTexture(
                            textures[frame.sky_alpha_texnum] ?? missingTexture, index: 1)
                    }
                case UInt32(QC_BATCH_LIQUID):
                    encoder.setRenderPipelineState(liquidPipeline)
                default:
                    encoder.setRenderPipelineState(worldPipeline)
                    encoder.setDepthStencilState(depthState)
                }
            }

            switch batch.kind {
            case UInt32(QC_BATCH_SKY):
                skyUniforms.skyalpha = batch.alpha
                withUnsafeBytes(of: &skyUniforms) { raw in
                    encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                }

            case UInt32(QC_BATCH_LIQUID):
                // Translucent liquids keep testing but stop writing depth,
                // exactly upstream's R_BeginTransparentDrawing.
                encoder.setDepthStencilState(batch.alpha < 1 ? noWriteDepthState : depthState)
                encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
                var uniforms = LiquidUniforms(time: frame.time, alpha: batch.alpha)
                withUnsafeBytes(of: &uniforms) { raw in
                    encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                }

            default:
                encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
                encoder.setFragmentTexture(textures[batch.lightmap] ?? neutralLightmap, index: 1)
            }

            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: Int(batch.index_count),
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: Int(batch.first_index) * MemoryLayout<UInt32>.size)
        }
    }

    /// Mirror the engine's world vertex array on generation change. The
    /// geometry lock is held for exactly one memcpy; a map load on the
    /// engine thread can block on this, so get in and out.
    private func syncGeometry(generation: UInt32) -> Bool {
        if generation == geometryGeneration, vertexBuffer != nil {
            return true
        }

        var vertices: UnsafePointer<qc_world_vertex_t>?
        var count: UInt32 = 0
        let current = QC_RendererAcquireGeometry(&vertices, &count)
        defer { QC_RendererReleaseGeometry() }

        guard current == generation, let vertices, count > 0 else { return false }

        let length = Int(count) * MemoryLayout<qc_world_vertex_t>.stride
        guard let buffer = device.makeBuffer(bytes: vertices, length: length,
                                             options: .storageModeShared)
        else { return false }
        buffer.label = "world vertices"

        vertexBuffer = buffer
        geometryGeneration = current
        return true
    }

    private func copyIndices(from frame: qc_frame_t) -> MTLBuffer? {
        guard let indices = frame.indices else { return nil }
        let length = Int(frame.num_indices) * MemoryLayout<UInt32>.size

        ringIndex = (ringIndex + 1) % indexBuffers.count
        if (indexBuffers[ringIndex]?.length ?? 0) < length {
            indexBuffers[ringIndex] = device.makeBuffer(
                length: max(length, 1 << 16), options: .storageModeShared)
            indexBuffers[ringIndex]?.label = "frame indices"
        }
        guard let buffer = indexBuffers[ringIndex] else { return nil }

        buffer.contents().copyMemory(from: indices, byteCount: length)
        return buffer
    }

    // MARK: - Texture queues

    /// Returns the textures that still need a mip chain generated.
    private func drainTextureQueues() -> [MTLTexture] {
        var frees: UnsafePointer<UInt32>?
        let freeCount = QC_RendererAcquireTextureFrees(&frees)
        if let frees {
            for i in 0..<Int(freeCount) {
                textures.removeValue(forKey: frees[i])
            }
        }
        QC_RendererReleaseTextureFrees()

        var uploads: UnsafePointer<qc_texture_upload_t>?
        let uploadCount = QC_RendererAcquireUploads(&uploads)
        var mipCandidates: [MTLTexture] = []
        if let uploads {
            for i in 0..<Int(uploadCount) {
                let upload = uploads[i]
                guard let texture = makeTexture(for: upload) else { continue }
                textures[upload.texnum] = texture
                if upload.flags & UInt32(QC_TEXFLAG_MIPMAP) != 0 {
                    mipCandidates.append(texture)
                }
            }
        }
        QC_RendererReleaseUploads()
        return mipCandidates
    }

    private func makeTexture(for upload: qc_texture_upload_t) -> MTLTexture? {
        let mipmapped = upload.flags & UInt32(QC_TEXFLAG_MIPMAP) != 0
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: Int(upload.width),
            height: Int(upload.height),
            mipmapped: mipmapped)
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared

        guard let rgba = upload.rgba,
              let texture = device.makeTexture(descriptor: descriptor)
        else { return nil }

        texture.replace(
            region: MTLRegionMake2D(0, 0, Int(upload.width), Int(upload.height)),
            mipmapLevel: 0,
            withBytes: rgba,
            bytesPerRow: Int(upload.width) * 4)
        return texture
    }
}
