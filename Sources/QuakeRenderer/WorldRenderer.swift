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

import Metal
import MetalKit

final class WorldRenderer: NSObject, MTKViewDelegate {

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let depthState: MTLDepthStencilState
    private let worldSampler: MTLSamplerState
    private let lightmapSampler: MTLSamplerState

    /// Engine texnum -> GPU texture, mutated only on the draw thread.
    private var textures: [UInt32: MTLTexture] = [:]

    /// 0.5 gray: a batch with no lightmap renders albedo * 0.5 * 2 = albedo.
    private let neutralLightmap: MTLTexture

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
            let vertexFunction = library.makeFunction(name: "world_vertex"),
            let fragmentFunction = library.makeFunction(name: "world_fragment")
        else { return nil }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.label = "world"
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        pipelineDescriptor.depthAttachmentPixelFormat = depthPixelFormat

        let depthDescriptor = MTLDepthStencilDescriptor()
        depthDescriptor.depthCompareFunction = .lessEqual
        depthDescriptor.isDepthWriteEnabled = true

        // World textures wrap and get the full mip/aniso treatment; lightmap
        // atlases must clamp (blocks are packed edge to edge) and have no mips.
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

        let neutralDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)

        guard
            let pipeline = try? device.makeRenderPipelineState(descriptor: pipelineDescriptor),
            let depthState = device.makeDepthStencilState(descriptor: depthDescriptor),
            let worldSampler = device.makeSamplerState(descriptor: worldSamplerDescriptor),
            let lightmapSampler = device.makeSamplerState(descriptor: lightmapSamplerDescriptor),
            let neutralLightmap = device.makeTexture(descriptor: neutralDescriptor)
        else { return nil }

        var gray: [UInt8] = [128, 128, 128, 255]
        neutralLightmap.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0, withBytes: &gray, bytesPerRow: 4)

        self.device = device
        self.commandQueue = queue
        self.pipeline = pipeline
        self.depthState = depthState
        self.worldSampler = worldSampler
        self.lightmapSampler = lightmapSampler
        self.neutralLightmap = neutralLightmap
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
        encoder.setRenderPipelineState(pipeline)
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

        for i in 0..<Int(frame.num_batches) {
            let batch = batches[i]
            guard let diffuse = textures[batch.texnum] else { continue }
            let lightmap = textures[batch.lightmap] ?? neutralLightmap

            encoder.setFragmentTexture(diffuse, index: 0)
            encoder.setFragmentTexture(lightmap, index: 1)
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
