//
//  World.metal
//
//  BSP world surfaces: diffuse * lightmap with the overbright doubling,
//  plus the liquid (UV warp) and sky (projected scrolling layers / skybox)
//  fragment variants selected per batch kind.
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
    float3 worldpos;
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
    out.worldpos = float3(v.xyz);
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

// MARK: - Liquids

struct LiquidUniforms {
    float time;     // cl.time from the frame packet
    float alpha;    // GL_WaterAlphaForSurface for this batch
};

// Upstream's WARPCALC (gl_warp.c) evaluated per fragment. The vertex st is
// raw texels / 128 (Mod_PolyForUnlitSurface), the warp period; turbsin is
// 8 * sin over a 256-entry cycle and the final divide is /64, one repeat per
// 64-texel water texture. In st units that collapses to:
//   uv = 2*st + (8/64) * sin(2*pi*st.yx + cl.time)
fragment float4 liquid_fragment(WorldVaryings in [[stage_in]],
                                constant LiquidUniforms &uniforms [[buffer(0)]],
                                texture2d<float> diffuse [[texture(0)]],
                                sampler diffuseSampler [[sampler(0)]])
{
    float2 uv = 2.0 * in.st
              + 0.125 * sin(fma(in.st.yx, float2(6.283185307), fmod(uniforms.time, 6.283185307)));
    float4 albedo = diffuse.sample(diffuseSampler, uv);
    // Liquids are unlit: no lightmap, no overbright doubling, upstream
    // modulates by glColor(1,1,1,wateralpha) only.
    return float4(albedo.rgb, uniforms.alpha);
}

// MARK: - Sky

struct SkyUniforms {
    float4 vieworg_time;    // xyz = r_origin, w = cl.time
    float skyalpha;         // r_skyalpha (cloud layer opacity)
};

// Sky_GetTexCoord (gl_sky.c): project the view ray onto a flattened sphere
// and scroll with time. speed is 8 for the solid layer, 16 for the clouds.
static float2 sky_layer_uv(float3 worldpos, float3 vieworg, float time, float speed)
{
    float3 dir = worldpos - vieworg;
    dir.z *= 3.0;                       // flatten the sphere
    float len = 6.0 * 63.0 / length(dir);
    float scroll = fmod(time * speed, 128.0);
    return (scroll + dir.xy * len) * (1.0 / 128.0);
}

fragment float4 sky_layers_fragment(WorldVaryings in [[stage_in]],
                                    constant SkyUniforms &uniforms [[buffer(0)]],
                                    texture2d<float> solid [[texture(0)]],
                                    texture2d<float> clouds [[texture(1)]],
                                    sampler layerSampler [[sampler(0)]])
{
    float3 vieworg = uniforms.vieworg_time.xyz;
    float time = uniforms.vieworg_time.w;

    float3 back = solid.sample(layerSampler, sky_layer_uv(in.worldpos, vieworg, time, 8.0)).rgb;
    float4 front = clouds.sample(layerSampler, sky_layer_uv(in.worldpos, vieworg, time, 16.0));

    // Upstream draws the solid layer then blends the cloud layer over it
    // with r_skyalpha; folded into one pass here.
    return float4(mix(back, front.rgb, front.a * uniforms.skyalpha), 1.0);
}

// Sky_ProjectPoly's axis pick plus the st_to_vec/vec_to_st projection from
// gl_sky.c, evaluated per fragment instead of per clipped poly. Faces are
// bound already reordered by skytexorder (the bridge does that), and the
// clamping sampler replaces Sky_EmitSkyBoxVertex's half-texel seam remap.
constant int3 vec_to_st[6] = {
    int3(-2,  3,  1),
    int3( 2,  3, -1),
    int3( 1,  3,  2),
    int3(-1,  3, -2),
    int3(-2, -1,  3),
    int3(-2,  1, -3),
};

static float sky_component(float3 dir, int j)
{
    return (j < 0) ? -dir[-j - 1] : dir[j - 1];
}

fragment float4 sky_box_fragment(WorldVaryings in [[stage_in]],
                                 constant SkyUniforms &uniforms [[buffer(0)]],
                                 array<texture2d<float>, 6> faces [[texture(0)]],
                                 sampler faceSampler [[sampler(1)]])
{
    float3 dir = in.worldpos - uniforms.vieworg_time.xyz;
    float3 av = abs(dir);
    int axis;
    if (av.x > av.y && av.x > av.z)
        axis = (dir.x < 0.0) ? 1 : 0;
    else if (av.y > av.z && av.y > av.x)
        axis = (dir.y < 0.0) ? 3 : 2;
    else
        axis = (dir.z < 0.0) ? 5 : 4;

    float dv = sky_component(dir, vec_to_st[axis].z);
    float s = sky_component(dir, vec_to_st[axis].x) / dv;
    float t = sky_component(dir, vec_to_st[axis].y) / dv;
    float2 uv = float2((s + 1.0) * 0.5, 1.0 - (t + 1.0) * 0.5);

    return float4(faces[axis].sample(faceSampler, uv).rgb, 1.0);
}
