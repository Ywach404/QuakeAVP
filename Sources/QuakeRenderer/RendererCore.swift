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
    /// Comfort vignette: fullscreen periphery fade, drawn last.
    let vignette: MTLRenderPipelineState
    /// Polyblend: fullscreen v_blend tint (damage/pickup/underwater). Optional
    /// like text/sprite -- a build failure must not nil the whole set.
    let polyblend: MTLRenderPipelineState?
    /// Weapon-wheel guide: wireframe ring + highlight, line primitives.
    let wheelGuide: MTLRenderPipelineState
    /// Billboarded 2D text (wheel labels, item selector, HUD) from conchars.
    /// Optional on purpose: a failure to build this NEW pipeline must never
    /// nil out the whole set and take the renderer down with it (that bails
    /// renderFrame before startSubmission and trips queryNextFrame's
    /// __BUG_IN_CLIENT__ abort). Worst case: no labels, everything else draws.
    let text: MTLRenderPipelineState?
    /// Sprite models (explosions, bubbles) as depth-tested textured
    /// billboards. Optional for the same reason as `text`: a build failure
    /// must not nil the whole set. Worst case: no sprite effects.
    let sprite: MTLRenderPipelineState?
    /// Modular HUD tile background panel (vr_hud_bg): procedural stone +
    /// bevel, drawn behind each tile's content. Optional like `text`/
    /// `sprite`: a build failure must not take down the rest of the
    /// renderer. Worst case: no panel, tile content still draws.
    let hudPanel: MTLRenderPipelineState?
    let depthWrite: MTLDepthStencilState
    let depthNoWrite: MTLDepthStencilState
    /// For pass B: pass exactly the prepass depth, write nothing.
    let depthEqualNoWrite: MTLDepthStencilState
    /// For the vignette: no depth test, no depth write.
    let depthAlways: MTLDepthStencilState
}

final class RendererCore {

    enum Output {
        case window
        case immersive
        /// The offline exporter's thread (DemoExporter), lock-stepping the
        /// engine through a demo while the immersive space is closed.
        case export
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
        // xyz = fog color, w = exp2 density (0 = no fog). Filled per frame
        // from the packet inside the encoder; callers may omit it.
        var fog: SIMD4<Float> = .zero
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

    /// White 1x1: lazily created (the modular HUD tiles' opaque backing is
    /// the only consumer) so `drawHudTiles` can guarantee a fully OPAQUE
    /// quad behind every tile's content via the always-available
    /// `pipelines.text` path — `text_fragment` multiplies this texture's
    /// (1,1,1,1) sample by the vertex color, so an alpha-1 vertex color
    /// comes out alpha-1 regardless of the digit glyphs' own transparency
    /// or whether the optional stone `hudPanel` pipeline built. nil until
    /// first needed.
    private var hudSolidTexture: MTLTexture?

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

        let alwaysDescriptor = MTLDepthStencilDescriptor()
        alwaysDescriptor.depthCompareFunction = .always
        alwaysDescriptor.isDepthWriteEnabled = false

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
            let vignette = pipeline(vertex: "vignette_vertex", fragment: "vignette_fragment", blended: true),
            let wheelGuide = pipeline(vertex: "wheel_guide_vertex", fragment: "wheel_guide_fragment", blended: true),
            let depthWrite = device.makeDepthStencilState(descriptor: writeDescriptor),
            let depthNoWrite = device.makeDepthStencilState(descriptor: noWriteDescriptor),
            let depthEqualNoWrite = device.makeDepthStencilState(descriptor: equalDescriptor),
            let depthAlways = device.makeDepthStencilState(descriptor: alwaysDescriptor)
        else { return nil }

        // Non-fatal: build the text pipeline separately so its failure leaves
        // the rest of the renderer intact. Log the outcome so a device run
        // tells us whether labels are available there.
        let textPipeline = pipeline(vertex: "text_vertex",
                                    fragment: "text_fragment", blended: true)
        print("[renderer] text pipeline: \(textPipeline == nil ? "FAILED (labels off)" : "ok")")

        let spritePipeline = pipeline(vertex: "sprite_vertex",
                                      fragment: "sprite_fragment", blended: true)
        print("[renderer] sprite pipeline: \(spritePipeline == nil ? "FAILED (sprites off)" : "ok")")

        let polyblendPipeline = pipeline(vertex: "vignette_vertex",
                                         fragment: "polyblend_fragment", blended: true)
        print("[renderer] polyblend pipeline: \(polyblendPipeline == nil ? "FAILED (polyblend off)" : "ok")")

        let hudPanelPipeline = pipeline(vertex: "hud_panel_vertex",
                                        fragment: "hud_panel_fragment", blended: true)
        print("[renderer] hud panel pipeline: \(hudPanelPipeline == nil ? "FAILED (tile bg off)" : "ok")")

        return RenderPipelines(
            world: world, worldDepthOnly: worldDepthOnly, worldEqual: worldEqual,
            worldBlend: worldBlend, liquid: liquid,
            skyLayers: skyLayers, skyBox: skyBox,
            aliasOpaque: aliasOpaque, aliasBlend: aliasBlend,
            vignette: vignette, polyblend: polyblendPipeline, wheelGuide: wheelGuide,
            text: textPipeline,
            sprite: spritePipeline,
            hudPanel: hudPanelPipeline,
            depthWrite: depthWrite, depthNoWrite: depthNoWrite,
            depthEqualNoWrite: depthEqualNoWrite,
            depthAlways: depthAlways)
    }

    // MARK: - Frame encoding

    /// Encode one frame packet. `amplificationCount` is 2 for single-pass
    /// stereo (with the identity/offset-1 view mappings) and 1 otherwise;
    /// same shaders either way.
    ///
    /// `windowHud` opts into drawing the 2D status-bar overlay, screen-
    /// mapped to the drawable, as the second-to-last step here — UNDER the
    /// comfort vignette drawn right after it, so the bar dims with the rest
    /// of the frame during a snap-turn/locomotion vignette instead of
    /// punching through at full brightness. It defaults to false and must
    /// stay that way for every caller except the flat window: the immersive
    /// space draws its own world-space panel itself via `drawOverlay`,
    /// AFTER this call returns (immersive-vs-vignette order isn't
    /// constrained the way the window's is), and the exporter burns its own
    /// sharp HUD in separately — neither may see this draw. Never key this
    /// off `amplificationCount` — the exporter also passes 1.
    func encode(frame: qc_frame_t,
                with encoder: MTLRenderCommandEncoder,
                pipelines: RenderPipelines,
                uniforms: WorldUniforms,
                phase: PhaseParams,
                amplificationCount: Int,
                viewmodelViewport: (full: MTLViewport, squished: MTLViewport)? = nil,
                drawsViewmodel: Bool = false,
                windowHud: Bool = false) {
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
        uniforms.fog = SIMD4<Float>(frame.fog_color.0, frame.fog_color.1,
                                    frame.fog_color.2, frame.fog_density)
        encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.setFragmentSamplerState(worldSampler, index: 0)
        encoder.setFragmentSamplerState(lightmapSampler, index: 1)

        var skyUniforms = SkyUniforms(
            time: frame.time, skyalpha: 1, fade: phase.skyFade,
            fog: SIMD4<Float>(frame.fog_color.0, frame.fog_color.1,
                              frame.fog_color.2, frame.sky_fog))
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
                    // The weapon. Its transform is vieworg + viewangles —
                    // the BODY pose — and the immersive camera composes the
                    // head on a yaw-only basis, so there it hangs on the
                    // body and pitches with the aim, decoupled from gaze
                    // (drawsViewmodel: real depth, stereo-correct). The
                    // flat window instead draws it squished into the near
                    // depth range like upstream glDepthRange(0, 0.3).
                    guard viewmodelViewport != nil || drawsViewmodel else { continue }
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
                                      entity.shadevector.2, entity.blend),
                    clip: SIMD4(entity.clip.0, entity.clip.1, entity.clip.2, entity.clip.3),
                    dbg: SIMD4(entity.dbg.0, entity.dbg.1, entity.dbg.2, entity.dbg.3),
                    eyeorg0: uniforms.eyeorg0, eyeorg1: uniforms.eyeorg1,
                    fog: SIMD4<Float>(frame.fog_color.0, frame.fog_color.1,
                                      frame.fog_color.2, frame.fog_density))
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

        // Particles (explosions, rocket trails, gunshots): billboarded colour
        // quads (7 floats/vert, xyz + rgba) built by the bridge. They reuse
        // the wheel-guide pipeline — colour triangles, no texture — but are
        // DEPTH-TESTED (depthNoWrite) so the world occludes them, unlike the
        // always-on-top overlays below.
        if frame.num_particle_verts >= 3, let src = frame.particle_verts {
            let floatCount = Int(frame.num_particle_verts) * 7
            if let buf = device.makeBuffer(bytes: src,
                                           length: floatCount * MemoryLayout<Float>.size,
                                           options: .storageModeShared) {
                setPipeline(pipelines.wheelGuide, depth: pipelines.depthNoWrite)
                var u = GuideUniforms(viewproj0: uniforms.viewproj0,
                                      viewproj1: uniforms.viewproj1)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                withUnsafeBytes(of: &u) { raw in
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: Int(frame.num_particle_verts))
            }
        }

        // Sprite models (explosions, bubbles) — textured billboards, one draw
        // per texture batch, DEPTH-TESTED (depthNoWrite) so the world occludes
        // them. Built by the bridge in world space; drawn in packet order.
        if let spritePipeline = pipelines.sprite,
           frame.num_sprite_batches > 0, frame.num_sprite_verts >= 3,
           let verts = frame.sprite_verts, let batches = frame.sprite_batches {
            let floatCount = Int(frame.num_sprite_verts) * 5
            if let buf = device.makeBuffer(bytes: verts,
                                           length: floatCount * MemoryLayout<Float>.size,
                                           options: .storageModeShared) {
                setPipeline(spritePipeline, depth: pipelines.depthNoWrite)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                for i in 0..<Int(frame.num_sprite_batches) {
                    let b = batches[i]
                    guard let tex = textures[b.texnum] else { continue }
                    var u = SpriteUniforms(viewproj0: uniforms.viewproj0,
                                           viewproj1: uniforms.viewproj1,
                                           alpha: b.alpha)
                    // Bind .stride (144), NOT .size (132): SpriteUniforms ends
                    // in a bare Float after two 16-aligned matrices, so its
                    // size has 12 bytes LESS than Metal's struct (which rounds
                    // to 16-byte alignment). withUnsafeBytes(of:)/raw.count give
                    // .size, which under-fills the buffer -- Metal draw
                    // validation then aborts ("space for 132 bytes, but argument
                    // has a length(144)") the instant a sprite (e.g. the
                    // s_explod explosion) is drawn. The var's storage is already
                    // stride-sized, so reading .stride bytes from &u is in bounds.
                    encoder.setVertexBytes(&u, length: MemoryLayout<SpriteUniforms>.stride, index: 1)
                    encoder.setFragmentTexture(tex, index: 0)
                    encoder.drawPrimitives(type: .triangle,
                                           vertexStart: Int(b.first_vert),
                                           vertexCount: Int(b.vert_count))
                }
            }
        }

        // Polyblend: the engine's v_blend screen tint over the 3D scene
        // (damage/pickup/powerup/underwater), under the HUD overlays below so
        // they stay readable during a flash. Fullscreen, no depth, blended.
        if let polyblendPipeline = pipelines.polyblend, frame.v_blend.3 > 0.001 {
            setPipeline(polyblendPipeline, depth: pipelines.depthAlways)
            var u = PolyblendUniforms(blend: SIMD4<Float>(
                frame.v_blend.0, frame.v_blend.1, frame.v_blend.2, frame.v_blend.3))
            withUnsafeBytes(of: &u) { raw in
                encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }

        // Weapon-wheel guide ring, over the world, before the vignette (so
        // locomotion vignette — never on while the wheel is open — could
        // still darken it, harmlessly).
        if frame.wheel_frac > 0.01, frame.wheel_count > 0, frame.wheel_radius > 0.5 {
            let guide = Self.wheelGuideGeometry(frame: frame)
            // A per-frame buffer, not setVertexBytes: the triangle geometry
            // exceeds the 4 KB setVertexBytes limit.
            if guide.count >= 21,
               let buf = device.makeBuffer(bytes: guide,
                                           length: guide.count * MemoryLayout<Float>.size,
                                           options: .storageModeShared) {
                setPipeline(pipelines.wheelGuide, depth: pipelines.depthAlways)
                var guideUniforms = GuideUniforms(viewproj0: uniforms.viewproj0,
                                                  viewproj1: uniforms.viewproj1)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                withUnsafeBytes(of: &guideUniforms) { raw in
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
                }
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: guide.count / 7)
            }
        }

        // Billboarded 2D text — wheel labels now, item selector and HUD next
        // — over the world and under the vignette. One conchars atlas, one
        // flat vertex run (9 floats/vert: xyz, uv, rgba), per-frame buffer.
        if let textPipeline = pipelines.text,
           frame.num_text_verts >= 3, frame.conchars_texnum != 0,
           let atlas = textures[frame.conchars_texnum],
           let src = frame.text_verts {
            let floatCount = Int(frame.num_text_verts) * 9
            if let buf = device.makeBuffer(bytes: src,
                                           length: floatCount * MemoryLayout<Float>.size,
                                           options: .storageModeShared) {
                setPipeline(textPipeline, depth: pipelines.depthAlways)
                var textUniforms = GuideUniforms(viewproj0: uniforms.viewproj0,
                                                 viewproj1: uniforms.viewproj1)
                encoder.setVertexBuffer(buf, offset: 0, index: 0)
                withUnsafeBytes(of: &textUniforms) { raw in
                    encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
                }
                encoder.setFragmentTexture(atlas, index: 0)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0,
                                       vertexCount: Int(frame.num_text_verts))
            }
        }

        // 2D HUD overlay — the authentic status bar from Sbar_Draw, as
        // textured quads batched by texnum. Window-only (see `windowHud`'s
        // doc comment); over the world, polyblend and wheel text, under the
        // vignette drawn next.
        if windowHud {
            if frame.hud_mode == 3 {
                drawHudTiles(frame: frame, tileModels: Self.windowHudTileModels(frame: frame),
                            viewproj0: Self.overlayWindowOrtho(), viewproj1: Self.overlayWindowOrtho(),
                            pipelines: pipelines, encoder: encoder)
            } else {
                drawOverlay(frame: frame, viewproj0: Self.overlayWindowOrtho(), viewproj1: Self.overlayWindowOrtho(),
                           pipelines: pipelines, encoder: encoder)
            }
        }

        // Comfort vignette, last over everything, engine-eased strength.
        if frame.vignette > 0.001 {
            setPipeline(pipelines.vignette, depth: pipelines.depthAlways)
            var vignetteUniforms = VignetteUniforms(strength: frame.vignette)
            withUnsafeBytes(of: &vignetteUniforms) { raw in
                encoder.setFragmentBytes(raw.baseAddress!, length: raw.count, index: 0)
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        }
    }

    /// Screen-space text for the export HUD: `verts` are the same 9-float
    /// glyph quads the bridge emits (xyz, uv, rgba) but in PIXEL coordinates,
    /// origin top-left, z ignored. Drawn over the pass with depth off.
    func drawScreenText(_ verts: [Float], atlasTexnum: UInt32, width: Int, height: Int,
                        pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = pipelines.text, verts.count >= 27,
              let atlas = textures[atlasTexnum],
              let buffer = device.makeBuffer(bytes: verts,
                                             length: verts.count * MemoryLayout<Float>.size,
                                             options: .storageModeShared)
        else { return }
        var ortho = matrix_identity_float4x4
        ortho.columns.0 = SIMD4(2 / Float(width), 0, 0, 0)
        ortho.columns.1 = SIMD4(0, -2 / Float(height), 0, 0)
        ortho.columns.2 = SIMD4(0, 0, 1, 0)
        ortho.columns.3 = SIMD4(-1, 1, 0, 1)
        var uniforms = GuideUniforms(viewproj0: ortho, viewproj1: ortho)
        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(pipelines.depthAlways)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 9)
    }

    /// The 2D HUD overlay — Sbar_Draw's status bar, baked by the bridge into
    /// textured quads (9 floats/vert: xyz uv rgba, same layout as
    /// `text_verts`) batched by texnum in a fixed 320x200 top-left-origin
    /// virtual screen. The overlay's own vertices never change: callers
    /// supply `viewproj0`/`viewproj1` to place that 320x200 plane wherever
    /// they need it — the window passes `Self.overlayWindowOrtho()` (classic
    /// Quake stretch straight to the drawable); the immersive space composes
    /// `handViewproj * panelModel` for a wrist- or head-anchored world panel
    /// (see `hudPanelModel`). One batch loop, shared by both.
    func drawOverlay(frame: qc_frame_t,
                     viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                     pipelines: RenderPipelines,
                     encoder: MTLRenderCommandEncoder) {
        // Presets only (vr_hud 1/2). Mode 3 (modular tiles) fills this SAME
        // overlay_verts/overlay_batches buffer through the tile path — see
        // `drawHudTiles` — and must never also go through this whole-panel
        // draw, which would place every tile's verts under one shared
        // wrist/float transform instead of each tile's own anchor.
        guard frame.hud_mode == 1 || frame.hud_mode == 2,
              frame.num_overlay_batches > 0, frame.num_overlay_verts >= 3,
              let verts = frame.overlay_verts, let batches = frame.overlay_batches,
              let pipeline = pipelines.text
        else { return }
        let floatCount = Int(frame.num_overlay_verts) * 9
        guard let buf = device.makeBuffer(bytes: verts,
                                          length: floatCount * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(pipelines.depthAlways)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        var uniforms = GuideUniforms(viewproj0: viewproj0, viewproj1: viewproj1)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        // The one thing this draw must now leave alone: the menu/console
        // range (`screen2d_first_vert`/`vert_count`), which the engine
        // appends to this SAME buffer after the status bar and which
        // `drawScreen2D` places on its own head-locked panel. Without the
        // exclusion a menu would also be painted onto the wrist/float HUD
        // panel, at HUD scale, under the HUD's transform.
        //
        // Clipped, not skipped by batch index, because batches coalesce by
        // texnum with no flush between the two emitters: the status bar's
        // last conchars batch and the menu's first conchars quad can be one
        // batch, so the boundary only exists in vertex space. Same mechanism
        // `drawHudTiles` uses for a batch straddling two tiles, and the
        // reason the packet carries a vert range rather than a batch range.
        let total = Int(frame.num_overlay_verts)
        let screen2dStart = Int(frame.screen2d_first_vert)
        let screen2dEnd = screen2dStart + Int(frame.screen2d_vert_count)
        for i in 0..<Int(frame.num_overlay_batches) {
            let b = batches[i]
            if frame.screen2d_vert_count == 0 {
                drawOverlayBatch(b, within: 0..<total, encoder: encoder)
            } else {
                drawOverlayBatch(b, within: 0..<screen2dStart, encoder: encoder)
                drawOverlayBatch(b, within: screen2dEnd..<total, encoder: encoder)
            }
        }
    }

    /// Draws the part of one overlay batch that falls inside `range`, under
    /// whatever transform and pipeline the caller has already bound. The
    /// intersection is the whole mechanism by which several consumers share
    /// one coalesced `overlay_verts` run: verts are 6 per quad and every
    /// published range is quad-aligned, so an intersection is always a whole
    /// number of quads. An empty intersection draws nothing.
    private func drawOverlayBatch(_ batch: qc_overlay_batch_t, within range: Range<Int>,
                                  encoder: MTLRenderCommandEncoder) {
        let start = max(Int(batch.first_vert), range.lowerBound)
        let end = min(Int(batch.first_vert) + Int(batch.vert_count), range.upperBound)
        guard end > start, let tex = textures[batch.texnum] else { return }
        encoder.setFragmentTexture(tex, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: start, vertexCount: end - start)
    }

    /// The menu, the console, the intermission scoreboards and the console's
    /// notify lines — `QR_EmitScreen2D`'s contiguous tail of the same
    /// `overlay_verts` run the status bar uses, in the same fixed 320x200
    /// top-left-origin virtual screen and the same 9-float layout, so it
    /// draws through the same `pipelines.text` + `depthAlways` path.
    ///
    /// Its own draw rather than a `hud_mode` of `drawOverlay`'s, because it
    /// is not a HUD preset: it is up or it is not, it coexists with whatever
    /// the wrist HUD is doing, and it wants its own placement (a head-locked
    /// panel, not a wrist). Callers supply the transform, exactly as
    /// `drawOverlay`'s doc comment describes — the immersive space composes
    /// `handViewproj * screen2dPanelModel`, the flat window passes the
    /// screen-mapped ortho.
    ///
    /// Draws nothing when the range is empty, which is every ordinary
    /// playing frame, so an idle frame costs one comparison.
    func drawScreen2D(frame: qc_frame_t,
                      viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                      pipelines: RenderPipelines,
                      encoder: MTLRenderCommandEncoder) {
        guard frame.screen2d_vert_count >= 3, frame.num_overlay_batches > 0,
              let verts = frame.overlay_verts, let batches = frame.overlay_batches,
              let pipeline = pipelines.text
        else { return }
        let floatCount = Int(frame.num_overlay_verts) * 9
        guard let buf = device.makeBuffer(bytes: verts,
                                          length: floatCount * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        else { return }

        encoder.setRenderPipelineState(pipeline)
        encoder.setDepthStencilState(pipelines.depthAlways)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        var uniforms = GuideUniforms(viewproj0: viewproj0, viewproj1: viewproj1)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        // The whole run is uploaded so vertex indices still match the
        // packet's; only this range is drawn.
        let start = Int(frame.screen2d_first_vert)
        let range = start..<(start + Int(frame.screen2d_vert_count))
        for i in 0..<Int(frame.num_overlay_batches) {
            drawOverlayBatch(batches[i], within: range, encoder: encoder)
        }
    }

    /// The flat window's overlay placement: the 320x200 virtual screen
    /// mapped straight to the drawable (classic Quake stretch), top-left
    /// origin, +y down. Mono — the same matrix serves both viewproj slots.
    static func overlayWindowOrtho() -> simd_float4x4 {
        var ortho = matrix_identity_float4x4
        ortho.columns.0 = SIMD4(2 / Float(320), 0, 0, 0)
        ortho.columns.1 = SIMD4(0, -2 / Float(200), 0, 0)
        ortho.columns.2 = SIMD4(0, 0, 1, 0)
        ortho.columns.3 = SIMD4(-1, 1, 0, 1)
        return ortho
    }

    /// The window's fixed modular-HUD layout (vr_hud 3): no wrist or gun
    /// pose exists in the flat mono debug view (see `WorldRenderer`'s doc
    /// comment — it draws exactly what the packet's own viewproj describes,
    /// nothing device-tracked), so the three tiles simply stack down the
    /// left edge of the 320x200 virtual screen, in `hud_tiles[]` order
    /// (AMMO, FACE, HEALTHARMOR), 4px gaps, ignoring anchor/offset/scale —
    /// "a simple fixed screen layout" per the brief, debug-only. One entry
    /// per `frame.hud_tiles[i]`; nil for a tile that emitted nothing this
    /// frame (`vert_count == 0`), same convention `drawHudTiles` expects.
    static func windowHudTileModels(frame: qc_frame_t) -> [simd_float4x4?] {
        guard frame.hud_mode == 3, frame.num_hud_tiles > 0, let tiles = frame.hud_tiles
        else { return [] }
        var models: [simd_float4x4?] = []
        var y: Float = 0
        for i in 0..<Int(frame.num_hud_tiles) {
            let tile = tiles[i]
            guard tile.vert_count > 0 else { models.append(nil); continue }
            var m = matrix_identity_float4x4
            m.columns.3 = SIMD4(0, y, 0, 1)
            models.append(m)
            y += tile.bbox_h + 4
        }
        return models
    }

    /// Modular HUD tiles (vr_hud 3): each tile's vertex sub-range — into
    /// the SAME `overlay_verts`/`overlay_batches` the whole-panel presets
    /// would otherwise have used (`QR_EmitModularHud` writes into the
    /// identical buffer `QR_EmitHud` would have, see its doc comment) —
    /// gets its OWN model matrix via `tileModels[i]`, because tiles may pin
    /// to different anchors (wrist vs gun) or, in the window's fixed
    /// layout, different fixed offsets. A nil entry skips that tile
    /// outright: it emitted nothing this frame (`vert_count == 0`) or its
    /// anchor has no live pose right now — never drawn at a stale
    /// position. One batch loop, like `drawOverlay`, just re-run per tile
    /// with that tile's own transform and restricted to its own vert
    /// range (a tile may span multiple batches — different texnums, e.g.
    /// HEALTHARMOR's two colour atlases). The emitter coalesces consecutive
    /// quads sharing a texnum with no tile-boundary flush, so a batch CAN
    /// straddle two adjacent tiles (e.g. AMMO's last white digit merging
    /// with HEALTHARMOR's white armor digit when FACE is hidden and they
    /// sit back-to-back); each tile therefore draws only the INTERSECTION
    /// of the batch's vert range with its own range, under its own
    /// transform — the straddling batch's two halves are drawn once each,
    /// by the two tiles they actually belong to. Verts are 6/quad and tile
    /// ranges are quad-aligned, so the intersection is always a whole
    /// number of quads.

    /// First-use creation of the 1x1 white texture the opaque tile backing
    /// (see `drawHudTiles`) binds through `pipelines.text`. Kept off
    /// `init?()` (unlike `neutralLightmap`/`blackTexture`, which every world
    /// draw needs) since only the modular HUD ever asks for it.
    private func ensureHudSolidTexture() -> MTLTexture? {
        if let hudSolidTexture { return hudSolidTexture }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        guard let tex = device.makeTexture(descriptor: descriptor) else { return nil }
        var white: [UInt8] = [255, 255, 255, 255]
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                   withBytes: &white, bytesPerRow: 4)
        hudSolidTexture = tex
        return tex
    }

    /// The vr_hud_bg background panel quad for one tile, in the SAME
    /// tile-local (0,0)-(bbox_w,bbox_h) coordinates and 9-float layout
    /// (xyz, uv, rgba) the tile's own content verts use, so it transforms
    /// under the exact same per-tile model matrix and tracks the tile.
    /// Padded by `pad` virtual px on every side. uv spans 0..1 across this
    /// PADDED quad (not the unpadded bbox) and is fed to `hud_panel_fragment`
    /// for its rounded-rect mask, stone fill and bevel; `color` is a
    /// per-vertex tint multiplied onto whatever's sampled — the stone panel
    /// leaves it at white (unused by that shader), while the opaque backing
    /// below uses it as the actual fill color against a white 1x1 texture.
    private static func hudBgQuad(bboxW: Float, bboxH: Float, pad: Float,
                                   color: (Float, Float, Float, Float) = (1, 1, 1, 1)) -> [Float] {
        let left: Float = -pad, top: Float = -pad
        let right = bboxW + pad, bottom = bboxH + pad
        let (r, g, b, a) = color
        func vert(_ x: Float, _ y: Float, _ u: Float, _ v: Float) -> [Float] {
            [x, y, 0, u, v, r, g, b, a]
        }
        return vert(left, top, 0, 0) + vert(right, top, 1, 0) + vert(left, bottom, 0, 1)
             + vert(right, top, 1, 0) + vert(right, bottom, 1, 1) + vert(left, bottom, 0, 1)
    }

    /// Layout must match HudPanelUniforms in HudPanel.metal: two
    /// view-projections (as GuideUniforms) plus the padded bbox's aspect
    /// ratio, so the panel's rounded corners and stone noise stay
    /// isotropic regardless of the tile's own (often very non-square)
    /// shape.
    private struct HudPanelUniforms {
        var viewproj0: simd_float4x4
        var viewproj1: simd_float4x4
        var aspect: Float
    }

    /// Encodes ONE procedural-stone card. `quad` is a six-vertex, 9-float
    /// (xyz, uv, rgba) run whose uv spans 0..1 across the panel, in
    /// whatever space `viewproj0`/`viewproj1` already fold their model
    /// matrix into; `aspect` is that panel's width/height, which
    /// `hud_panel_fragment` needs to keep its rounded corners and its stone
    /// noise isotropic on a non-square panel.
    ///
    /// The SINGLE copy of this encode. `drawHudTiles` (a modular HUD tile's
    /// background, in tile-local space under the tile's own model matrix)
    /// and `drawStonePanel` (a world-space rectangle, for the wrist
    /// communicator) differ only in how they arrive at a quad and a matrix
    /// -- the uniform layout, the `MemoryLayout.stride` bind and the draw
    /// live here, so the two callers cannot drift into two stone looks.
    private func encodeStonePanel(quad: [Float], aspect: Float,
                                  viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                                  panelPipeline: MTLRenderPipelineState,
                                  encoder: MTLRenderCommandEncoder) {
        guard let bgBuf = device.makeBuffer(bytes: quad,
                                            length: quad.count * MemoryLayout<Float>.size,
                                            options: .storageModeShared)
        else { return }
        var panelUniforms = HudPanelUniforms(viewproj0: viewproj0, viewproj1: viewproj1,
                                             aspect: aspect)
        encoder.setRenderPipelineState(panelPipeline)
        withUnsafeBytes(of: &panelUniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!,
                                   length: MemoryLayout<HudPanelUniforms>.stride, index: 1)
        }
        encoder.setVertexBuffer(bgBuf, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
    }

    /// How revealed a panel must be before its stone card is drawn at all.
    ///
    /// `hud_panel_fragment` takes its alpha from a shader constant
    /// (`kPanelInteriorAlpha`) and has no uniform to scale it, so a stone
    /// card cannot fade: drawn during a caller's fade-in it would sit at
    /// full alpha and snap the panel on. Below this floor `drawStonePanel`
    /// therefore draws its flat tinted layer alone -- which is exactly what
    /// the panel looked like before the stone -- and above it the panel is
    /// already near-opaque, so the card arriving changes coverage very
    /// little. Raise it towards 1 to confine the stone further into the
    /// glance; lower it only once the shader can fade.
    private static let stoneRevealFloor: Float = 0.9

    /// A world-space procedural-stone panel: the same card the modular HUD
    /// tiles are backed with (`pipelines.hudPanel`), placed on an arbitrary
    /// `origin`/`right`/`up` rectangle rather than under a tile's model
    /// matrix. Built for the wrist communicator's bezel and keys, so the
    /// unit reads as the same material as the HUD sitting above it.
    ///
    /// Two layers, in the same order and for the same reasons
    /// `drawHudTiles` stacks its own two:
    ///
    /// 1. `tint` as a flat quad through `pipelines.text` and the white 1x1
    ///    texel -- byte for byte `drawWorkbenchLabel`'s backing. This layer
    ///    alone is what a communicator panel looked like before the stone,
    ///    and it is the whole draw when `pipelines.hudPanel` did not build,
    ///    so a caller's tint ladder and its fade (carried in `tint`'s
    ///    alpha) still read with no stone pipeline at all.
    /// 2. The stone card on top. `hud_panel_fragment` ignores the vertex
    ///    colour entirely (it is carried for buffer-layout parity only), so
    ///    `tint` shows THROUGH the card's interior alpha instead of
    ///    multiplying it -- a tint ladder here is a subtle lift, and a
    ///    caller that needs an unmistakable highlight should wash a second,
    ///    inset flat quad over the card as well.
    ///
    /// The card is rounded and the flat layer is not, so the panel's
    /// corners show flat tint outside the card's mask -- the HUD tiles look
    /// exactly the same way, for exactly this reason.
    func drawStonePanel(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                        widthMeters: Float, heightMeters: Float,
                        tint: SIMD4<Float>, stoneReveal: Float = 1,
                        viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                        pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        drawFlatPanel(origin: origin, right: right, up: up,
                      width: widthMeters, height: heightMeters, color: tint,
                      viewproj0: viewproj0, viewproj1: viewproj1,
                      pipelines: pipelines, encoder: encoder)

        guard let panelPipeline = pipelines.hudPanel, stoneReveal >= Self.stoneRevealFloor,
              widthMeters > 0, heightMeters > 0
        else { return }
        // A 1x1 source plane, so the quad's own local coordinates ARE its
        // uv and `hudPanelModel` maps them straight onto the metres
        // rectangle the flat layer just covered.
        let model = Self.hudPanelModel(origin: origin, right: right, up: up,
                                       widthMeters: widthMeters, heightMeters: heightMeters,
                                       sourceWidth: 1, sourceHeight: 1)
        encoder.setDepthStencilState(pipelines.depthAlways)
        encodeStonePanel(quad: Self.hudBgQuad(bboxW: 1, bboxH: 1, pad: 0),
                         aspect: widthMeters / heightMeters,
                         viewproj0: viewproj0 * model, viewproj1: viewproj1 * model,
                         panelPipeline: panelPipeline, encoder: encoder)
    }

    func drawHudTiles(frame: qc_frame_t,
                      tileModels: [simd_float4x4?],
                      viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                      pipelines: RenderPipelines,
                      encoder: MTLRenderCommandEncoder) {
        guard frame.hud_mode == 3, frame.num_hud_tiles > 0, !tileModels.isEmpty,
              let tiles = frame.hud_tiles,
              frame.num_overlay_batches > 0, frame.num_overlay_verts >= 3,
              let verts = frame.overlay_verts, let batches = frame.overlay_batches,
              let pipeline = pipelines.text
        else { return }

        let floatCount = Int(frame.num_overlay_verts) * 9
        guard let buf = device.makeBuffer(bytes: verts,
                                          length: floatCount * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        else { return }

        encoder.setDepthStencilState(pipelines.depthAlways)

        let drawBg = frame.hud_bg != 0
        let pad: Float = 6

        let tileCount = min(Int(frame.num_hud_tiles), tileModels.count)
        for i in 0..<tileCount {
            let tile = tiles[i]
            guard tile.vert_count > 0, let model = tileModels[i] else { continue }

            // Backing, same per-tile transform, drawn BEFORE the tile's own
            // content below so it sits behind it. Two layers, in order:
            //
            // 1. An unconditionally OPAQUE dark quad through the
            //    always-available `pipelines.text` pipeline. This is the
            //    reliable backing: the digit glyphs are ~53% transparent,
            //    so without a guaranteed opaque surface behind them the
            //    rendered 3-D world shows through (the "bars" bug) and the
            //    thin ink washes out on bright/damage backdrops (the
            //    "blank" bug). `text_fragment` samples the solid white 1x1
            //    texture (always (1,1,1,1)) and multiplies by this quad's
            //    alpha-1 vertex color, so the result is opaque regardless
            //    of whether the stone panel pipeline built.
            // 2. The optional stone + bevel panel (`pipelines.hudPanel`) on
            //    top of that base, unchanged from before — it looks the
            //    same when it's available, the base just guarantees
            //    something's there when it isn't.
            //
            // Both are gated on `drawBg` together: with vr_hud_bg 0 the
            // user explicitly wants no box, so skip both and accept
            // transparent digits in that mode.
            if drawBg {
                if let solidTex = ensureHudSolidTexture() {
                    let baseQuad = Self.hudBgQuad(bboxW: tile.bbox_w, bboxH: tile.bbox_h, pad: pad,
                                                  color: (0.06, 0.05, 0.045, 1.0))
                    if let baseBuf = device.makeBuffer(bytes: baseQuad,
                                                       length: baseQuad.count * MemoryLayout<Float>.size,
                                                       options: .storageModeShared) {
                        var baseUniforms = GuideUniforms(viewproj0: viewproj0 * model, viewproj1: viewproj1 * model)
                        encoder.setRenderPipelineState(pipeline)
                        withUnsafeBytes(of: &baseUniforms) { raw in
                            encoder.setVertexBytes(raw.baseAddress!,
                                                   length: MemoryLayout<GuideUniforms>.stride, index: 1)
                        }
                        encoder.setVertexBuffer(baseBuf, offset: 0, index: 0)
                        encoder.setFragmentTexture(solidTex, index: 0)
                        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
                    }
                }

                if let panelPipeline = pipelines.hudPanel {
                    let paddedW = tile.bbox_w + 2 * pad
                    let paddedH = tile.bbox_h + 2 * pad
                    encodeStonePanel(quad: Self.hudBgQuad(bboxW: tile.bbox_w, bboxH: tile.bbox_h, pad: pad),
                                     aspect: paddedH > 0 ? paddedW / paddedH : 1,
                                     viewproj0: viewproj0 * model, viewproj1: viewproj1 * model,
                                     panelPipeline: panelPipeline, encoder: encoder)
                }
            }

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 0)
            var uniforms = GuideUniforms(viewproj0: viewproj0 * model, viewproj1: viewproj1 * model)
            withUnsafeBytes(of: &uniforms) { raw in
                encoder.setVertexBytes(raw.baseAddress!, length: MemoryLayout<GuideUniforms>.stride, index: 1)
            }

            let tileStart = Int(tile.first_vert)
            let tileEnd = tileStart + Int(tile.vert_count)
            for b in 0..<Int(frame.num_overlay_batches) {
                let batch = batches[b]
                let batchStart = Int(batch.first_vert)
                let batchEnd = batchStart + Int(batch.vert_count)
                let start = max(batchStart, tileStart)
                let end = min(batchEnd, tileEnd)
                guard end > start else { continue }   // no overlap with this tile
                guard let tex = textures[batch.texnum] else { continue }
                encoder.setFragmentTexture(tex, index: 0)
                encoder.drawPrimitives(type: .triangle,
                                       vertexStart: start,
                                       vertexCount: end - start)
            }
        }
    }

    // MARK: - HUD editor workbench labels (Task 4)

    /// Swift-side mirror of `QR_EmitText` (qr_bridge.c) for the workbench's
    /// zone/Done/Cancel labels, which have no engine-side glyph data of
    /// their own -- the HUD editor session never touches `QC_*` (it is
    /// render-only UI state, see `ImmersiveRenderer.wristGridFurniture`'s
    /// doc comment), so there is nothing in `frame.text_verts` to reuse for
    /// them. The conchars atlas layout is a stable Quake format (128x128,
    /// 16x16 grid of 8x8 cells, column = char & 15, row = char >> 4 --
    /// QR_EmitText's own doc comment), so this builds the SAME 9-float
    /// (xyz, uv, rgba) triangle quads the engine's own text path emits,
    /// without teaching the bridge a new string entry point. ASCII only
    /// (conchars has no other glyphs); anything else falls back to '?'.
    ///
    /// `alternate` picks Quake's SECOND character set, the one the menus
    /// draw with: conchars' 16x16 grid holds plain ASCII in rows 0-7 and a
    /// red/bronze copy of the same glyphs in rows 8-15, so `char | 0x80`
    /// is the red glyph for `char`. That is the engine's own indexing, not
    /// an assumption: `QR_GlyphCell` (qr_bridge.c) is
    /// `cx = ch & 15, cy = (ch >> 4) & 15` and `QR_DrawCharacter` hands it
    /// `num & 255`, while `menu.c`'s `M_Print` adds 128 to every character
    /// and `M_PrintWhite` does not -- the +128 set IS the coloured one.
    /// Default false, so every existing caller keeps the white set.
    private static func textQuads(_ s: String, origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                                   cellSize: Float, color: SIMD4<Float>,
                                   alternate: Bool = false) -> [Float] {
        let bytes = Array(s.utf8).map { $0 < 128 ? $0 : UInt8(ascii: "?") }
        guard !bytes.isEmpty else { return [] }
        let half = Float(bytes.count) * cellSize * 0.5
        let top = cellSize * 0.5, bot = -cellSize * 0.5
        func vert(_ p: SIMD3<Float>, _ u: Float, _ v: Float) -> [Float] {
            [p.x, p.y, p.z, u, v, color.x, color.y, color.z, color.w]
        }
        var verts: [Float] = []
        verts.reserveCapacity(bytes.count * 54)
        for (i, byte) in bytes.enumerated() {
            if byte == UInt8(ascii: " ") { continue }   // blank cell, no wasted verts
            let glyph = alternate ? Int(byte) | 0x80 : Int(byte)
            let cxi = Float(glyph & 15), cyi = Float(glyph >> 4)
            let u0 = cxi / 16, u1 = u0 + 1 / 16
            let v0 = cyi / 16, v1 = v0 + 1 / 16
            let x0 = -half + Float(i) * cellSize, x1 = x0 + cellSize
            let tl = origin + right * x0 + up * top
            let tr = origin + right * x1 + up * top
            let bl = origin + right * x0 + up * bot
            let br = origin + right * x1 + up * bot
            verts += vert(tl, u0, v0) + vert(tr, u1, v0) + vert(bl, u0, v1)
            verts += vert(tr, u1, v0) + vert(br, u1, v1) + vert(bl, u0, v1)
        }
        return verts
    }

    /// A solid-tinted quad in world space -- verts carry their own
    /// position, no model matrix, same convention `drawHandDebug`/
    /// `drawVirtualHand` use for the hand overlays -- 9-float layout so it
    /// draws through the SAME `pipelines.text` + white-texel path
    /// `drawHudTiles`'s opaque tile backing already uses.
    private static func workbenchPanelQuad(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                                            width: Float, height: Float, color: SIMD4<Float>) -> [Float] {
        let r = right * (width * 0.5)
        let u = up * (height * 0.5)
        let tl = origin - r + u, tr = origin + r + u, bl = origin - r - u, br = origin + r - u
        func vert(_ p: SIMD3<Float>, _ uu: Float, _ vv: Float) -> [Float] {
            [p.x, p.y, p.z, uu, vv, color.x, color.y, color.z, color.w]
        }
        return vert(tl, 0, 0) + vert(tr, 1, 0) + vert(bl, 0, 1)
             + vert(tr, 1, 0) + vert(br, 1, 1) + vert(bl, 0, 1)
    }

    /// Draws one workbench proxy (HUD live editor, Task 4): a solid tinted
    /// backing and, when `text` is non-nil, a centred label above it.
    /// `text == nil` draws the backing alone -- the grabbed-tile highlight,
    /// which has no label of its own. Both passes are world-space quads (no
    /// model matrix needed; `origin`/`right`/`up` already place them) drawn
    /// through `pipelines.text`, exactly like `drawHudTiles`'s opaque tile
    /// backing and the engine's own billboarded text -- a missing
    /// `pipelines.text` build (labels off) silently drops this instead of
    /// crashing, same contract as every other optional-pipeline draw here.
    ///
    /// `labelCentered` moves the label from ABOVE the backing (the default,
    /// the workbench's captioned proxies) to inside it, centred on `origin`
    /// -- what a BUTTON wants, where the text belongs on the key rather
    /// than floating over it (the wrist communicator's action cells). It is
    /// one placement flag rather than a second draw routine deliberately:
    /// the quad builders (`workbenchPanelQuad`/`textQuads`) and this encode
    /// path stay the single copy. Every colour is the CALLER's, alpha
    /// included, so a faded panel just passes pre-multiplied-down alphas in.
    func drawWorkbenchLabel(text: String?, origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                            panelWidth: Float, panelHeight: Float, cellSize: Float,
                            labelCentered: Bool = false,
                            panelColor: SIMD4<Float>, textColor: SIMD4<Float>,
                            conchars: UInt32,
                            viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                            pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        drawFlatPanel(origin: origin, right: right, up: up,
                      width: panelWidth, height: panelHeight, color: panelColor,
                      viewproj0: viewproj0, viewproj1: viewproj1,
                      pipelines: pipelines, encoder: encoder)
        guard let text else { return }
        drawPanelLabel(text: text,
                       origin: labelCentered ? origin : origin + up * (panelHeight * 0.5 + cellSize * 0.6),
                       right: right, up: up, cellSize: cellSize, color: textColor,
                       conchars: conchars, viewproj0: viewproj0, viewproj1: viewproj1,
                       pipelines: pipelines, encoder: encoder)
    }

    /// The backing half of `drawWorkbenchLabel`, on its own: one solid
    /// `color` rectangle in world space, through `pipelines.text` and the
    /// white 1x1 texel. Split out so `drawStonePanel` can use the very same
    /// encode as its flat layer (and its no-stone-pipeline fallback)
    /// instead of a second copy of it -- there is one flat-panel draw in
    /// this file, and the communicator, the editor's wrist grid and the
    /// stone panels all go through it.
    ///
    /// Public in its own right for a caller that wants a flat quad and
    /// nothing else -- the wrist communicator washes one of these over a
    /// stone card as its hover/press highlight.
    func drawFlatPanel(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                       width: Float, height: Float, color: SIMD4<Float>,
                       viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                       pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = pipelines.text, let solidTex = ensureHudSolidTexture() else { return }
        let quad = Self.workbenchPanelQuad(origin: origin, right: right, up: up,
                                           width: width, height: height, color: color)
        guard let buf = device.makeBuffer(bytes: quad, length: quad.count * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        else { return }
        encoder.setDepthStencilState(pipelines.depthAlways)
        var uniforms = GuideUniforms(viewproj0: viewproj0, viewproj1: viewproj1)
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: MemoryLayout<GuideUniforms>.stride, index: 1)
        }
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        encoder.setFragmentTexture(solidTex, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: quad.count / 9)
    }

    /// The label half of `drawWorkbenchLabel`, on its own: a conchars
    /// string centred on `origin`. `origin` is the label's own placement,
    /// already resolved by the caller -- `drawWorkbenchLabel` lifts it
    /// above its backing or leaves it on it per `labelCentered`, and the
    /// wrist communicator (which draws its panels through
    /// `drawStonePanel`, not through the backing half above) passes the
    /// key centre straight in.
    ///
    /// `alternate` selects conchars' red/bronze character set (`char |
    /// 0x80`, see `textQuads`). Off by default: the HUD editor's workbench
    /// labels keep the white glyphs they have always drawn, and only the
    /// communicator asks for the red ones.
    func drawPanelLabel(text: String, origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                        cellSize: Float, color: SIMD4<Float>, conchars: UInt32,
                        alternate: Bool = false,
                        viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                        pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        guard let pipeline = pipelines.text, let atlas = textures[conchars] else { return }
        let textVerts = Self.textQuads(text, origin: origin, right: right, up: up,
                                       cellSize: cellSize, color: color, alternate: alternate)
        guard !textVerts.isEmpty,
              let textBuf = device.makeBuffer(bytes: textVerts, length: textVerts.count * MemoryLayout<Float>.size,
                                              options: .storageModeShared)
        else { return }
        encoder.setDepthStencilState(pipelines.depthAlways)
        var uniforms = GuideUniforms(viewproj0: viewproj0, viewproj1: viewproj1)
        encoder.setRenderPipelineState(pipeline)
        withUnsafeBytes(of: &uniforms) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: MemoryLayout<GuideUniforms>.stride, index: 1)
        }
        encoder.setVertexBuffer(textBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(atlas, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: textVerts.count / 9)
    }

    /// The immersive HUD panel's model matrix: maps a `sourceWidth` x
    /// `sourceHeight` top-left-origin plane (+y down, z always 0 — pure 2D
    /// quads) onto a flat `widthMeters` x `heightMeters` rectangle centred
    /// at `origin`, in whatever space the caller's viewproj expects
    /// (corrected tracking space, for the immersive renderer's
    /// `handViewproj`). `right`/`up` must already be unit and mutually
    /// orthogonal (see `billboardBasis`). Overlay +x maps to `right`,
    /// overlay +y (down) maps to `-up`, so text reads right-side-up for a
    /// viewer standing where `billboardBasis` was told to face.
    ///
    /// `sourceWidth`/`sourceHeight` default to the whole-panel presets'
    /// fixed 320x200 virtual screen; the modular HUD tile path passes a
    /// tile's own `bbox_w`/`bbox_h` instead, since a tile's verts span only
    /// its own local extent, not the full screen.
    static func hudPanelModel(origin: SIMD3<Float>, right: SIMD3<Float>, up: SIMD3<Float>,
                              widthMeters: Float, heightMeters: Float,
                              sourceWidth: Float = 320, sourceHeight: Float = 200) -> simd_float4x4 {
        let rx = right * (widthMeters / sourceWidth)
        let uy = -up * (heightMeters / sourceHeight)
        let corner = origin - right * (widthMeters * 0.5) + up * (heightMeters * 0.5)
        var m = matrix_identity_float4x4
        m.columns.0 = SIMD4(rx.x, rx.y, rx.z, 0)
        m.columns.1 = SIMD4(uy.x, uy.y, uy.z, 0)
        m.columns.2 = SIMD4(0, 0, 0, 0)
        m.columns.3 = SIMD4(corner.x, corner.y, corner.z, 1)
        return m
    }

    /// A modular HUD tile anchor's pose (vr_hud 3), in whatever space the
    /// caller's viewproj expects. `right`/`up`/`forward` must be unit and
    /// mutually orthogonal — exactly what `billboardBasis` produces, with
    /// `forward` the `toward` vector it was built from (the panel's face
    /// normal, pointing at the viewer).
    struct HudAnchorFrame {
        var origin: SIMD3<Float>
        var right: SIMD3<Float>
        var up: SIMD3<Float>
        var forward: SIMD3<Float>
    }

    /// Billboard basis for a panel whose face normal points along `toward`
    /// (unit vector from the panel to the viewer), referencing world up —
    /// the same construction a camera's right/up derive from a look
    /// direction, so a viewer standing on the `toward` side and looking back
    /// along `-toward` reads the panel un-mirrored. Degenerates gracefully
    /// (falls back to world-right) when `toward` is nearly vertical.
    static func billboardBasis(toward: SIMD3<Float>) -> (right: SIMD3<Float>, up: SIMD3<Float>) {
        let worldUp = SIMD3<Float>(0, 1, 0)
        var right = simd_cross(worldUp, toward)
        if simd_length(right) < 1e-4 {
            right = SIMD3<Float>(1, 0, 0)
        } else {
            right = simd_normalize(right)
        }
        let up = simd_normalize(simd_cross(toward, right))
        return (right, up)
    }

    /// Draw the finger debug wireframe. `verts` are 7-float TRIANGLE
    /// vertices (xyz + rgba) in corrected-TRACKING space -- thin quads, not
    /// lines, because line primitives are illegal under the device's
    /// foveation rasterization-rate map. The viewprojs map that space
    /// straight to clip (projection * originFromEye.inverse), NOT through
    /// the game world, so the wires sit on the real hand and ignore the
    /// eye-height trim.
    func drawHandDebug(_ verts: [Float], viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                       pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        guard verts.count >= 21,
              let buf = device.makeBuffer(bytes: verts,
                                          length: verts.count * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        else { return }
        encoder.setRenderPipelineState(pipelines.wheelGuide)
        encoder.setDepthStencilState(pipelines.depthAlways)
        var u = GuideUniforms(viewproj0: viewproj0, viewproj1: viewproj1)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        withUnsafeBytes(of: &u) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: verts.count / 7)
    }

    /// The M6 virtual hand: a stylised forearm/palm/fingers mesh built in
    /// corrected-tracking space by HandInput (7 floats/vertex, xyz + rgba,
    /// triangles), drawn on the real hand through handViewproj like the debug
    /// wireframe. Opacity is 1 - phase: it stands in for the hand while the
    /// world is solid (phase 0, opaque world hides the room) and fades out as
    /// the melt reveals the real hand through passthrough (phase 1). Reuses
    /// the wheel-guide pipeline (stereo-amplified, premultiplied blend);
    /// depth-tested against the world, no write, so a wall in front occludes
    /// it. The per-vertex alpha is scaled by opacity before upload.
    func drawVirtualHand(_ verts: [Float], opacity: Float,
                         viewproj0: simd_float4x4, viewproj1: simd_float4x4,
                         pipelines: RenderPipelines, encoder: MTLRenderCommandEncoder) {
        guard opacity > 0.01, verts.count >= 21 else { return }
        var scaled = verts
        var i = 6
        while i < scaled.count { scaled[i] *= opacity; i += 7 }   // alpha per vertex
        guard let buf = device.makeBuffer(bytes: scaled,
                                          length: scaled.count * MemoryLayout<Float>.size,
                                          options: .storageModeShared)
        else { return }
        encoder.setRenderPipelineState(pipelines.wheelGuide)
        encoder.setDepthStencilState(pipelines.depthNoWrite)
        var u = GuideUniforms(viewproj0: viewproj0, viewproj1: viewproj1)
        encoder.setVertexBuffer(buf, offset: 0, index: 0)
        withUnsafeBytes(of: &u) { raw in
            encoder.setVertexBytes(raw.baseAddress!, length: raw.count, index: 1)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: scaled.count / 7)
    }

    /// Append a thin quad (two triangles) between A and B into a 7-float
    /// vertex list, so a "line" survives foveation. `perp` is a unit vector
    /// off the segment; `t` its half-thickness.
    static func addRibbon(_ a: SIMD3<Float>, _ b: SIMD3<Float>, perp: SIMD3<Float>,
                          t: Float, color col: SIMD4<Float>, into v: inout [Float]) {
        let a0 = a - perp * t, a1 = a + perp * t
        let b0 = b - perp * t, b1 = b + perp * t
        for p in [a0, a1, b0, a1, b1, b0] {
            v += [p.x, p.y, p.z, col.x, col.y, col.z, col.w]
        }
    }

    /// Build the wheel guide as a flat [Float] of 7-component line
    /// vertices (xyz + rgba, matching GuideVertex): a dim ring in the
    /// body-right / world-up plane, a radial spoke at each owned slot, and
    /// the highlighted slot's spoke long and bright so the selection reads
    /// at a glance. Layout mirrors QR_EmitWheel's slot angles exactly.
    private static func wheelGuideGeometry(frame: qc_frame_t) -> [Float] {
        let c = SIMD3(frame.wheel_center.0, frame.wheel_center.1, frame.wheel_center.2)
        let r = frame.wheel_radius
        let count = Int(frame.wheel_count)
        // The ring plane comes from the PACKET now, not re-derived from
        // body_yaw. The engine tilts it by the vr_wheel* trims, and this is the
        // only thing those trims move -- the weapons and labels stay on the
        // untilted basis, as does selection. Re-deriving here would ignore the
        // tilt and draw a flat circle around a ring the player had aimed.
        var right = SIMD3<Float>(frame.wheel_right.0, frame.wheel_right.1, frame.wheel_right.2)
        var up = SIMD3<Float>(frame.wheel_up.0, frame.wheel_up.1, frame.wheel_up.2)
        if simd_length(right) < 0.5 || simd_length(up) < 0.5 {
            // Older packet or no ring this frame: fall back to the flat body
            // plane rather than drawing a degenerate circle.
            let yaw = frame.body_yaw * .pi / 180
            right = SIMD3<Float>(sin(yaw), -cos(yaw), 0)
            up = SIMD3<Float>(0, 0, 1)
        }
        func pt(_ angle: Float, _ rad: Float) -> SIMD3<Float> {
            c + rad * cos(angle) * right + rad * sin(angle) * up
        }
        var v: [Float] = []
        func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ cc: SIMD3<Float>, _ col: SIMD4<Float>) {
            for p in [a, b, cc] { v += [p.x, p.y, p.z, col.x, col.y, col.z, col.w] }
        }
        let dim = SIMD4<Float>(0.6, 0.85, 1.0, 0.6)
        let hot = SIMD4<Float>(1.0, 0.85, 0.35, 0.95)
        // Thin quads in the ring plane, not lines (foveation forbids line
        // primitives), so the band and spokes read face-on to the player.
        let ringT = max(r * 0.04, 0.2)

        // ring as an in-plane annulus (inner..outer radius) of quads
        let seg = 48
        for i in 0..<seg {
            let a0 = 2 * Float.pi * Float(i) / Float(seg)
            let a1 = 2 * Float.pi * Float(i + 1) / Float(seg)
            let i0 = pt(a0, r - ringT), o0 = pt(a0, r + ringT)
            let i1 = pt(a1, r - ringT), o1 = pt(a1, r + ringT)
            tri(i0, o0, i1, dim); tri(o0, o1, i1, dim)
        }
        // a radial spoke at each slot; the highlighted one longer + hot,
        // thickened tangentially so it shows face-on
        let step = 360 / Float(count)
        for k in 0..<count {
            let theta = (90 - Float(k) * step) * .pi / 180
            let isHi = k == Int(frame.wheel_highlight)
            let col = isHi ? hot : dim
            let tangent = -sin(theta) * right + cos(theta) * up
            let inner = pt(theta, r * (isHi ? 0.55 : 0.82))
            let outer = pt(theta, r * (isHi ? 1.35 : 1.12))
            addRibbon(inner, outer, perp: tangent, t: ringT * 1.6, color: col, into: &v)
        }
        return v
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
        // xyz = fog color, w = sky fog fraction. SIMD4 forces 16-byte align,
        // matching Metal's float4 after the three floats.
        var fog: SIMD4<Float>
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

    /// Layout must match VignetteUniforms in Vignette.metal.
    private struct VignetteUniforms {
        var strength: Float
    }

    /// Layout must match PolyblendUniforms in Vignette.metal: one float4.
    private struct PolyblendUniforms {
        var blend: SIMD4<Float>
    }

    /// Layout must match GuideUniforms in WheelGuide.metal: two matrices.
    private struct GuideUniforms {
        var viewproj0: simd_float4x4
        var viewproj1: simd_float4x4
    }

    /// Layout must match SpriteUniforms in Sprite.metal: two matrices + alpha.
    private struct SpriteUniforms {
        var viewproj0: simd_float4x4
        var viewproj1: simd_float4x4
        var alpha: Float
    }

    /// Layout must match AliasUniforms in Alias.metal.
    private struct AliasUniforms {
        var viewproj0: simd_float4x4
        var viewproj1: simd_float4x4
        var model: simd_float4x4
        var light: SIMD4<Float>
        var shadeblend: SIMD4<Float>
        var clip: SIMD4<Float>
        var dbg: SIMD4<Float>
        var eyeorg0: SIMD4<Float>
        var eyeorg1: SIMD4<Float>
        var fog: SIMD4<Float>
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
