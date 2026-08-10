//
//  World.metal
//
//  BSP world surfaces: diffuse * lightmap with the overbright doubling.
//  Vertex layout must match qc_world_vertex_t in QuakeCore.h.
//

#include <metal_stdlib>
using namespace metal;

struct WorldVertex {
    packed_float3 xyz;
    packed_float2 st;
    packed_float2 lm_st;
};

struct WorldUniforms {
    float4x4 viewproj;
};

struct WorldVaryings {
    float4 position [[position]];
    float2 st;
    float2 lm;
};

// Vertices are fetched manually so the index buffer's uint32 indices land in
// vertex_id via drawIndexedPrimitives -- no vertex descriptor needed.
vertex WorldVaryings world_vertex(uint vid [[vertex_id]],
                                  const device WorldVertex *vertices [[buffer(0)]],
                                  constant WorldUniforms &uniforms [[buffer(1)]])
{
    WorldVertex v = vertices[vid];
    WorldVaryings out;
    out.position = uniforms.viewproj * float4(float3(v.xyz), 1.0);
    out.st = float2(v.st);
    out.lm = float2(v.lm_st);
    return out;
}

fragment float4 world_fragment(WorldVaryings in [[stage_in]],
                               texture2d<float> diffuse [[texture(0)]],
                               texture2d<float> lightmap [[texture(1)]],
                               sampler diffuseSampler [[sampler(0)]],
                               sampler lightmapSampler [[sampler(1)]])
{
    float4 albedo = diffuse.sample(diffuseSampler, in.st);

    // Fence textures carry alpha; upstream alpha-tests them at 0.666 and
    // every other world texture is fully opaque, so one discard covers both.
    if (albedo.a < 0.666)
        discard_fragment();

    // gl_overbright: lightmaps are baked >>8 so full bright is 0.5; the *2
    // here is the other half of that contract (see R_BuildLightMap).
    float3 light = lightmap.sample(lightmapSampler, in.lm).rgb;
    return float4(albedo.rgb * light * 2.0, 1.0);
}
