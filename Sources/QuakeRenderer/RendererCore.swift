//
//  RendererCore.swift
//
//  The output-agnostic half of the frame-packet consumer: GPU device state,
//  the engine-texnum -> MTLTexture table, the mirrored world vertex buffer,
//  the per-frame index ring, and the batch encoder. Both outputs — the flat
//  window's MTKView and the immersive space's LayerRenderer — drive this one
//  object, never concurrently.
//
//  The QC_Renderer* handoff allows exactly one consumer, but the *identity*
//  of the consuming thread changes when the immersive space opens or closes
//  (MTKView's display-link thread hands over to the compositor render
//  thread and back). `consumerLock` plus `activeOutput` make that handover
//  explicit: every consume cycle takes the lock, checks it still owns the
//  packet stream, and releases before returning. The lock is never held
//  across a wait.
//

import Metal
import simd

/// Pipeline family for one output. The two outputs differ in color/depth
/// formats, vertex amplification, and depth convention (the window clears to
/// 1.0 and tests less-equal; CompositorServices mandates reverse-Z — 1.0 at
/// the near plane, 0.0 at the far — so the immersive set tests greater-equal).
struct RenderPipelines {
    let world: MTLRenderPipelineState
    /// Phase pass A: world depth only, colour writes masked. Occlusion for
    /// everything drawn later comes from this pass and is identical at
    /// every phase value — that is the entire trick of the phase effect.
    let worldDepthOnly: MTLRenderPipelineState
    /// Phase pass B: world colour at depthCompare == .equal against A.
    let worldEqual: MTLRenderPipelineState
    let worldBlend: MTLRenderPipelineState   // translucent brush entities
    let liquid: MTLRenderPipelineState
    let skyLayers: MTLRenderPipelineState
    let skyBox: MTLRenderPipelineState
    let aliasOpaque: MTLRenderPipelineState
    let aliasBlend: MTLRenderPipelineState
    let depthWrite: MTLDepthStencilState
    let depthNoWrite: MTLDepthStencilState
    /// For pass B: pass exactly the prepass depth, write nothing.
    let depthEqualNoWrite: MTLDepthStencilState
}

final class RendererCore {

    enum Output {
        case window
        case immersive
    }

    /// Per-frame dissolve state. The radius comes from the packet (the
    /// engine owns the phase clock); the origin is supplied by the caller:
    /// the immersive path passes the late-latched head position mapped into
    /// Quake space, the window passes the packet's view origin.
    struct PhaseParams {
        var headorg: SIMD3<Float>
        var radius: Float
        var skyFade: Float
        var rimColor: SIMD3<Float>
    }

    /// Layout must match WorldUniforms in World.metal: two view-projections
    /// and two eye origins, indexed by [[amplification_id]]. The mono path
    /// fills both slots identically.
    struct WorldUniforms {
        var viewproj0: simd_float4x4
        var viewproj1: simd_float4x4
        var eyeorg0: SIMD4<Float>
        var eyeorg1: SIMD4<Float>
    }

    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let library: MTLLibrary
    let worldSampler: MTLSamplerState
    let lightmapSampler: MTLSamplerState

    /// Serialises consume cycles across the two outputs; see header comment.
    private let consumerLock = NSLock()
    private var activeOutput: Output = .window

    /// Engine texnum -> GPU texture. Mutated only inside a consume cycle.
    private var textures: [UInt32: MTLTexture] = [:]

    /// 0.5 gray: a batch with no lightmap renders albedo * 0.5 * 2 = albedo.
    private let neutralLightmap: MTLTexture

    /// Upstream's pink/black "notexture" checker: any batch whose texture
    /// hasn't been uploaded yet draws this, so a miss is loud, not invisible.
    private let missingTexture: MTLTexture

    /// Black 1x1: bound as the fullbright layer for skins without one, so
    /// the alias fragment's unconditional add contributes nothing.
    private let blackTexture: MTLTexture

    /// One alias model's GPU mesh: all poses' packed vertices followed by
    /// the shared texcoords in one buffer, plus a uint16 index list.
    struct AliasMesh {
        let buffer: MTLBuffer
        let stOffset: Int
        let poseStride: Int      // bytes per pose = vertsPerPose * 8
        let indexBuffer: MTLBuffer
    }

    /// Engine meshnum -> GPU mesh, mutated only inside a consume cycle.
    private var meshes: [UInt32: AliasMesh] = [:]

    private var vertexBuffer: MTLBuffer?
    private var geometryGeneration: UInt32 = 0

    /// Index data is copied out of the frame packet each draw; a small ring
    /// keeps the GPU from reading a buffer the CPU is rewriting.
    private var indexBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var ringIndex = 0

    init?() {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary()
        else { return nil }

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
            let worldSampler = device.makeSamplerState(descriptor: worldSamplerDescriptor),
            let lightmapSampler = device.makeSamplerState(descriptor: lightmapSamplerDescriptor),
            let neutralLightmap = device.makeTexture(descriptor: smallTextureDescriptor),
            let missingTexture = device.makeTexture(descriptor: checkerDescriptor),
            let blackTexture = device.makeTexture(descriptor: smallTextureDescriptor)
        else { return nil }

        var black: [UInt8] = [0, 0, 0, 255]
        blackTexture.replace(
            region: MTLRegionMake2D(0, 0, 1, 1),
            mipmapLevel: 0, withBytes: &black, bytesPerRow: 4)

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
        self.library = library
        self.worldSampler = worldSampler
        self.lightmapSampler = lightmapSampler
        self.neutralLightmap = neutralLightmap
        self.missingTexture = missingTexture
        self.blackTexture = blackTexture
    }

    // MARK: - Consumer arbitration

    /// Hand the packet stream to `output`. Callable from any thread; takes
    /// effect for the next consume cycle on either side.
    func activate(_ output: Output) {
        consumerLock.lock()
        activeOutput = output
        consumerLock.unlock()
    }

    /// Run one consume cycle if `output` currently owns the stream. Returns
    /// false (without calling `body`) after a handover, so a straggling draw
    /// callback from the losing output can't touch the QC_Renderer* API
    /// concurrently with the winner.
    func withConsumer<T>(_ output: Output, _ body: () -> T) -> T? {
        consumerLock.lock()
        defer { consumerLock.unlock() }
        guard activeOutput == output else { return nil }
        return body()
    }

    // MARK: - Pipelines

    func makePipelines(colorFormat: MTLPixelFormat,
                       depthFormat: MTLPixelFormat,
                       amplified: Bool,
                       reverseDepth: Bool,
                       linearOutput: Bool = false) -> RenderPipelines? {
        let constants = MTLFunctionConstantValues()
        var linear = linearOutput
        constants.setConstantValue(&linear, type: .bool, index: 0)

        func pipeline(vertex: String = "world_vertex", fragment: String,
                      blended: Bool, colorWrite: Bool = true) -> MTLRenderPipelineState? {
            guard
                let vertexFunction = try? library.makeFunction(name: vertex, constantValues: constants),
                let fragmentFunction = try? library.makeFunction(name: fragment, constantValues: constants)
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.label = fragment + (amplified ? " (stereo)" : "")
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            descriptor.colorAttachments[0].pixelFormat = colorFormat
            descriptor.depthAttachmentPixelFormat = depthFormat
            if !colorWrite {
                descriptor.colorAttachments[0].writeMask = []
            }
            if amplified {
                descriptor.maxVertexAmplificationCount = 2
            }
            if blended {
                let attachment = descriptor.colorAttachments[0]!
                attachment.isBlendingEnabled = true
                attachment.sourceRGBBlendFactor = .sourceAlpha
                attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
                // Alpha accumulates as "over" so translucent draws never
                // reduce the coverage the compositor sees in mixed
                // immersion: water over an opaque wall stays alpha 1.
                attachment.sourceAlphaBlendFactor = .one
                attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        let compare: MTLCompareFunction = reverseDepth ? .greaterEqual : .lessEqual

        let writeDescriptor = MTLDepthStencilDescriptor()
        writeDescriptor.depthCompareFunction = compare
        writeDescriptor.isDepthWriteEnabled = true

        // Translucent liquids test but don't write, like upstream's
        // glDepthMask(GL_FALSE) in R_BeginTransparentDrawing.
        let noWriteDescriptor = MTLDepthStencilDescriptor()
        noWriteDescriptor.depthCompareFunction = compare
        noWriteDescriptor.isDepthWriteEnabled = false

        let equalDescriptor = MTLDepthStencilDescriptor()
        equalDescriptor.depthCompareFunction = .equal
        equalDescriptor.isDepthWriteEnabled = false

        guard
            let world = pipeline(fragment: "world_fragment", blended: false),
            let worldDepthOnly = pipeline(fragment: "world_depth_fragment",
                                          blended: false, colorWrite: false),
            let worldEqual = pipeline(fragment: "world_phase_fragment", blended: false),
            let worldBlend = pipeline(fragment: "world_fragment", blended: true),
            let liquid = pipeline(fragment: "liquid_fragment", blended: true),
            let skyLayers = pipeline(fragment: "sky_layers_fragment", blended: false),
            let skyBox = pipeline(fragment: "sky_box_fragment", blended: false),
            let aliasOpaque = pipeline(vertex: "alias_vertex", fragment: "alias_fragment", blended: false),
            let aliasBlend = pipeline(vertex: "alias_vertex", fragment: "alias_fragment", blended: true),
            let depthWrite = device.makeDepthStencilState(descriptor: writeDescriptor),
            let depthNoWrite = device.makeDepthStencilState(descriptor: noWriteDescriptor),
            let depthEqualNoWrite = device.makeDepthStencilState(descriptor: equalDescriptor)
        else { return nil }

        return RenderPipelines(
            world: world, worldDepthOnly: worldDepthOnly, worldEqual: worldEqual,
            worldBlend: worldBlend, liquid: liquid,
            skyLayers: skyLayers, skyBox: skyBox,
            aliasOpaque: aliasOpaque, aliasBlend: aliasBlend,
            depthWrite: depthWrite, depthNoWrite: depthNoWrite,
            depthEqualNoWrite: depthEqualNoWrite)
    }

    // MARK: - Frame encoding

    /// Encode one frame packet. `amplificationCount` is 2 for single-pass
    /// stereo (with the identity/offset-1 view mappings) and 1 otherwise;
    /// same shaders either way.
    func encode(frame: qc_frame_t,
                with encoder: MTLRenderCommandEncoder,
                pipelines: RenderPipelines,
                uniforms: WorldUniforms,
                phase: PhaseParams,
                amplificationCount: Int,
                viewmodelViewport: (full: MTLViewport, squished: MTLViewport)? = nil) {
        guard frame.num_batches > 0, frame.num_indices > 0,
              let batches = frame.batches
        else { return }
        guard syncGeometry(generation: frame.generation),
              let vertexBuffer,
              let indexBuffer = copyIndices(from: frame)
        else { return }

        encoder.label = "world"
        encoder.setDepthStencilState(pipelines.depthWrite)
        // The bridge already backface-culls, and Quake's fan winding flips
        // with SURF_PLANEBACK, so GPU face culling would drop half the world.
        encoder.setCullMode(.none)

        if amplificationCount == 2 {
            var mappings = [
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0,
                                                  renderTargetArrayIndexOffset: 0),
                MTLVertexAmplificationViewMapping(viewportArrayIndexOffset: 0,
                                                  renderTargetArrayIndexOffset: 1),
            ]
            encoder.setVertexAmplificationCount(2, viewMappings: &mappings)
        }

        var uniforms = uniforms
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.setFragmentSamplerState(worldSampler, index: 0)
        encoder.setFragmentSamplerState(lightmapSampler, index: 1)

        var skyUniforms = SkyUniforms(time: frame.time, skyalpha: 1, fade: phase.skyFade)
        var phaseUniforms = PhaseFragUniforms(
            headorgRadius: SIMD4(phase.headorg.x, phase.headorg.y, phase.headorg.z, phase.radius),
            rimColor: SIMD4(phase.rimColor.x, phase.rimColor.y, phase.rimColor.z, 0))
        let skyboxTexnums = [
            frame.skybox_texnums.0, frame.skybox_texnums.1, frame.skybox_texnums.2,
            frame.skybox_texnums.3, frame.skybox_texnums.4, frame.skybox_texnums.5,
        ]
        let hasSkybox = skyboxTexnums[0] != 0

        // Per-batch model transform: identity for the world, the entity's
        // for brush entities. Track by entity index to skip redundant binds.
        var boundEntity = UInt32.max - 1   // != QC_ENTITY_NONE, forces first bind
        var currentPipeline: MTLRenderPipelineState?
        var currentDepth: MTLDepthStencilState?
        // Alias batches rebind vertex buffers 0-2 to their mesh; the world
        // path rebinds its own afterwards.
        var worldBuffersBound = true

        func setPipeline(_ p: MTLRenderPipelineState, depth: MTLDepthStencilState) {
            if p !== currentPipeline {
                encoder.setRenderPipelineState(p)
                currentPipeline = p
            }
            if depth !== currentDepth {
                encoder.setDepthStencilState(depth)
                currentDepth = depth
            }
        }

        // Phase pass A: the world's own geometry, depth only. Every later
        // draw — pass B, entities, liquids — is depth-tested against this,
        // so occlusion is decided here and never changes with phase.
        var identity = matrix_identity_float4x4
        withUnsafeBytes(of: &identity) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 2)
        }
        setPipeline(pipelines.worldDepthOnly, depth: pipelines.depthWrite)
        for i in 0..<Int(frame.num_batches) {
            let batch = batches[i]
            guard batch.kind == UInt32(QC_BATCH_WORLD), batch.entity == QC_ENTITY_NONE
            else { continue }
            encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: Int(batch.index_count),
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: Int(batch.first_index) * MemoryLayout<UInt32>.size)
        }

        for i in 0..<Int(frame.num_batches) {
            let batch = batches[i]

            if batch.kind == UInt32(QC_BATCH_ALIAS) {
                guard let entities = frame.entities else { continue }
                let entity = entities[Int(batch.entity)]
                if entity.flags & UInt32(QC_ENTFLAG_VIEWMODEL) != 0 {
                    // View-locked weapon: wrong in VR, drawn only where the
                    // caller supplies the upstream glDepthRange(0, 0.3)
                    // squish (the flat window). TODO(M4): decouple instead.
                    guard viewmodelViewport != nil else { continue }
                }
                guard let mesh = meshes[entity.meshnum] else { continue }

                setPipeline(batch.alpha < 1 ? pipelines.aliasBlend : pipelines.aliasOpaque,
                            depth: batch.alpha < 1 ? pipelines.depthNoWrite : pipelines.depthWrite)

                encoder.setVertexBuffer(mesh.buffer,
                                        offset: Int(entity.pose1) * mesh.poseStride, index: 0)
                encoder.setVertexBuffer(mesh.buffer,
                                        offset: Int(entity.pose2) * mesh.poseStride, index: 1)
                encoder.setVertexBuffer(mesh.buffer, offset: mesh.stOffset, index: 2)

                var aliasUniforms = AliasUniforms(
                    viewproj0: uniforms.viewproj0,
                    viewproj1: uniforms.viewproj1,
                    model: Self.matrix(from: entity.transform),
                    light: SIMD4(entity.light.0, entity.light.1, entity.light.2, entity.alpha),
                    shadeblend: SIMD4(entity.shadevector.0, entity.shadevector.1,
                                      entity.shadevector.2, entity.blend))
                withUnsafeBytes(of: &aliasUniforms) { raw in
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 3)
                }

                encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
                encoder.setFragmentTexture(
                    batch.lightmap != 0 ? (textures[batch.lightmap] ?? blackTexture) : blackTexture,
                    index: 1)

                let isViewmodel = entity.flags & UInt32(QC_ENTFLAG_VIEWMODEL) != 0
                if isViewmodel, let viewmodelViewport {
                    encoder.setViewport(viewmodelViewport.squished)
                }
                encoder.drawIndexedPrimitives(
                    type: .triangle,
                    indexCount: Int(batch.index_count),
                    indexType: .uint16,
                    indexBuffer: mesh.indexBuffer,
                    indexBufferOffset: 0)
                if isViewmodel, let viewmodelViewport {
                    encoder.setViewport(viewmodelViewport.full)
                }

                worldBuffersBound = false
                continue
            }

            if !worldBuffersBound {
                worldBuffersBound = true
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                withUnsafeBytes(of: &uniforms) { raw in
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
                }
                boundEntity = UInt32.max - 1    // force the model rebind too
            }

            if batch.entity != boundEntity {
                boundEntity = batch.entity
                var model = matrix_identity_float4x4
                if batch.entity != QC_ENTITY_NONE, let entities = frame.entities {
                    model = Self.matrix(from: entities[Int(batch.entity)].transform)
                }
                withUnsafeBytes(of: &model) { raw in
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 2)
                }
            }

            switch batch.kind {
            case UInt32(QC_BATCH_SKY):
                setPipeline(hasSkybox ? pipelines.skyBox : pipelines.skyLayers,
                            depth: pipelines.depthWrite)
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
                skyUniforms.skyalpha = batch.alpha
                withUnsafeBytes(of: &skyUniforms) { raw in
                    encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                }

            case UInt32(QC_BATCH_LIQUID):
                // Translucent liquids keep testing but stop writing depth,
                // exactly upstream's R_BeginTransparentDrawing.
                setPipeline(pipelines.liquid,
                            depth: batch.alpha < 1 ? pipelines.depthNoWrite : pipelines.depthWrite)
                encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
                var liquidUniforms = LiquidUniforms(time: frame.time, alpha: batch.alpha)
                withUnsafeBytes(of: &liquidUniforms) { raw in
                    encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                }

            default:
                // World geometry. The world's own batches are phase pass B:
                // colour at exactly the prepass depth, writing nothing.
                // Brush entities keep the ordinary depth test (they move;
                // they are not part of the prepass); entity alpha < 1
                // blends and stops writing depth like upstream's
                // R_BeginTransparentDrawing.
                if batch.entity == QC_ENTITY_NONE {
                    setPipeline(pipelines.worldEqual, depth: pipelines.depthEqualNoWrite)
                    encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
                    encoder.setFragmentTexture(textures[batch.lightmap] ?? neutralLightmap, index: 1)
                    withUnsafeBytes(of: &phaseUniforms) { raw in
                        encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                    }
                } else if batch.alpha >= 1, let entities = frame.entities,
                          entities[Int(batch.entity)].flags & UInt32(QC_ENTFLAG_PHASED) != 0 {
                    // Secret doors dissolve with the world: same phase
                    // fragment, but ordinary depth write/test -- they move,
                    // so they are not part of the prepass .equal contract.
                    setPipeline(pipelines.worldEqual, depth: pipelines.depthWrite)
                    encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
                    encoder.setFragmentTexture(textures[batch.lightmap] ?? neutralLightmap, index: 1)
                    withUnsafeBytes(of: &phaseUniforms) { raw in
                        encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                    }
                } else {
                    setPipeline(batch.alpha < 1 ? pipelines.worldBlend : pipelines.world,
                                depth: batch.alpha < 1 ? pipelines.depthNoWrite : pipelines.depthWrite)
                    encoder.setFragmentTexture(textures[batch.texnum] ?? missingTexture, index: 0)
                    encoder.setFragmentTexture(textures[batch.lightmap] ?? neutralLightmap, index: 1)
                    var fragUniforms = WorldFragUniforms(alpha: batch.alpha)
                    withUnsafeBytes(of: &fragUniforms) { raw in
                        encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
                    }
                }
            }

            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: Int(batch.index_count),
                indexType: .uint32,
                indexBuffer: indexBuffer,
                indexBufferOffset: Int(batch.first_index) * MemoryLayout<UInt32>.size)
        }
    }

    /// qc_entity_t.transform (a 16-float C array, column-major) as simd.
    static func matrix(from transform: (Float, Float, Float, Float, Float, Float, Float, Float,
                                        Float, Float, Float, Float, Float, Float, Float, Float)) -> simd_float4x4 {
        simd_float4x4(columns: (
            SIMD4(transform.0, transform.1, transform.2, transform.3),
            SIMD4(transform.4, transform.5, transform.6, transform.7),
            SIMD4(transform.8, transform.9, transform.10, transform.11),
            SIMD4(transform.12, transform.13, transform.14, transform.15)))
    }

    // Layouts must match the structs of the same name in World.metal.
    private struct LiquidUniforms {
        var time: Float
        var alpha: Float
    }

    private struct SkyUniforms {
        var time: Float
        var skyalpha: Float
        var fade: Float
    }

    /// Layout must match PhaseFragUniforms in World.metal: float4s only,
    /// so the layouts cannot disagree.
    private struct PhaseFragUniforms {
        var headorgRadius: SIMD4<Float>
        var rimColor: SIMD4<Float>
    }

    private struct WorldFragUniforms {
        var alpha: Float
    }

    /// Layout must match AliasUniforms in Alias.metal.
    private struct AliasUniforms {
        var viewproj0: simd_float4x4
        var viewproj1: simd_float4x4
        var model: simd_float4x4
        var light: SIMD4<Float>
        var shadeblend: SIMD4<Float>
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
    func drainTextureQueues() -> [MTLTexture] {
        drainMeshQueues()

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

    private func drainMeshQueues() {
        var frees: UnsafePointer<UInt32>?
        let freeCount = QC_RendererAcquireMeshFrees(&frees)
        if let frees {
            for i in 0..<Int(freeCount) {
                meshes.removeValue(forKey: frees[i])
            }
        }
        QC_RendererReleaseMeshFrees()

        var uploads: UnsafePointer<qc_mesh_upload_t>?
        let uploadCount = QC_RendererAcquireMeshUploads(&uploads)
        if let uploads {
            for i in 0..<Int(uploadCount) {
                let up = uploads[i]
                let poseStride = Int(up.numverts) * MemoryLayout<qc_mesh_vertex_t>.stride
                let vertexBytes = Int(up.numposes) * poseStride
                let stBytes = Int(up.numverts) * 2 * MemoryLayout<Float>.size
                guard
                    let vertices = up.vertices, let st = up.st, let indexes = up.indexes,
                    let buffer = device.makeBuffer(length: vertexBytes + stBytes,
                                                   options: .storageModeShared),
                    let indexBuffer = device.makeBuffer(
                        bytes: indexes,
                        length: Int(up.numindexes) * MemoryLayout<UInt16>.size,
                        options: .storageModeShared)
                else { continue }
                buffer.label = "alias mesh \(up.meshnum)"
                buffer.contents().copyMemory(from: vertices, byteCount: vertexBytes)
                (buffer.contents() + vertexBytes).copyMemory(from: st, byteCount: stBytes)
                meshes[up.meshnum] = AliasMesh(
                    buffer: buffer, stOffset: vertexBytes,
                    poseStride: poseStride, indexBuffer: indexBuffer)
            }
        }
        QC_RendererReleaseMeshUploads()
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

// MARK: - Quake view basis math

extension RendererCore {

    /// Column-major rotation about one axis, exactly Mat4_RotateAxis in
    /// qr_bridge.c — the immersive path must agree with the C mono path
    /// about what "the player's view" means, to the last sign.
    static func rotation(degrees: Float, axis: Int) -> simd_float4x4 {
        let r = degrees * .pi / 180
        let c = cos(r), s = sin(r)
        var m = matrix_identity_float4x4
        switch axis {
        case 0:
            m.columns.1 = SIMD4(0, c, s, 0)
            m.columns.2 = SIMD4(0, -s, c, 0)
        case 1:
            m.columns.0 = SIMD4(c, 0, -s, 0)
            m.columns.2 = SIMD4(s, 0, c, 0)
        default:
            m.columns.0 = SIMD4(c, s, 0, 0)
            m.columns.1 = SIMD4(-s, c, 0, 0)
        }
        return m
    }

    /// Quake world -> eye space (x right, y up, -z forward, Quake units):
    /// the view half of QR_BuildViewProj, same rotations in the same order.
    static func quakeViewMatrix(origin: SIMD3<Float>, angles: SIMD3<Float>) -> simd_float4x4 {
        var translate = matrix_identity_float4x4
        translate.columns.3 = SIMD4(-origin.x, -origin.y, -origin.z, 1)

        return rotation(degrees: -90, axis: 0)          // put Z going up
            * rotation(degrees: 90, axis: 2)            // put Z going up
            * rotation(degrees: -angles.z, axis: 0)     // roll
            * rotation(degrees: -angles.x, axis: 1)     // pitch
            * rotation(degrees: -angles.y, axis: 2)     // yaw
            * translate
    }
}
