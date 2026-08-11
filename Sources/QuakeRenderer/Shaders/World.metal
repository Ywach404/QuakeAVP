//
//  World.metal
//
//  BSP world surfaces: diffuse * lightmap with the overbright doubling,
//  plus the liquid (UV warp) and sky (projected scrolling layers / skybox)
//  fragment variants selected per batch kind.
//
//  One vertex function feeds every fragment shader, and it is written for
//  single-pass stereo: the uniforms carry two view-projections and two eye
//  origins, indexed by [[amplification_id]]. The immersive renderer encodes
//  with amplification count 2; the flat window encodes with count 1 and
//  fills both slots with the same mono matrix, so the shaders never know
//  which output they are drawing for. The per-eye origin rides to the sky
//  fragments as a flat varying because fragment functions have no
//  amplification id of their own.
//
//  Vertex layout must match qc_world_vertex_t in QuakeCore.h.
//

#include <metal_stdlib>
using namespace metal;

// Set true for pipelines rendering into an sRGB target (the immersive
// layer): Quake's colors are sRGB-authored, so emitting their linearized
// form lets the hardware's sRGB store re-encode them byte-identically to
// what the flat window's plain-unorm path displays.
constant bool qavp_linear_output [[function_constant(0)]];

static inline float4 qavp_out(float4 c)
{
    if (qavp_linear_output) {
        float3 lo = c.rgb / 12.92;
        float3 hi = pow((c.rgb + 0.055) / 1.055, 2.4);
        return float4(select(hi, lo, c.rgb <= 0.04045), c.a);
    }
    return c;
}

struct WorldVertex {
    packed_float3 xyz;
    packed_float2 st;
    packed_float2 lm_st;
};

struct WorldUniforms {
    float4x4 viewproj[2];   // per eye; [1] == [0] on the mono path
    float4 eyeorg[2];       // per-eye view origin, Quake units (w unused)
};

// Per-batch model->world transform: identity for world batches, the entity
// transform for brush-entity batches. Multiplying by the identity is
// bit-exact, so world rendering is unchanged by this indirection.
struct ModelUniforms {
    float4x4 model;
};

// Per-batch fragment state for the world pipelines; alpha is 1 for the
// world itself and ENTALPHA for translucent brush entities.
struct WorldFragUniforms {
    float alpha;
};

struct WorldVaryings {
    // invariant: the world draws twice (depth prepass, then a colour pass
    // with depthCompare == .equal); without invariance the two pipelines
    // may schedule the position math differently and .equal sparkles.
    float4 position [[position, invariant]];
    float3 worldpos;
    float3 eyeorg [[flat]];
    float2 st;
    float2 lm;
};

// Vertices are fetched manually so the index buffer's uint32 indices land in
// vertex_id via drawIndexedPrimitives -- no vertex descriptor needed.
vertex WorldVaryings world_vertex(uint vid [[vertex_id]],
                                  uint amp [[amplification_id]],
                                  const device WorldVertex *vertices [[buffer(0)]],
                                  constant WorldUniforms &uniforms [[buffer(1)]],
                                  constant ModelUniforms &entity [[buffer(2)]])
{
    WorldVertex v = vertices[vid];
    float4 worldpos = entity.model * float4(float3(v.xyz), 1.0);
    WorldVaryings out;
    out.position = uniforms.viewproj[amp] * worldpos;
    out.worldpos = worldpos.xyz;
    out.eyeorg = uniforms.eyeorg[amp].xyz;
    out.st = float2(v.st);
    out.lm = float2(v.lm_st);
    return out;
}

fragment float4 world_fragment(WorldVaryings in [[stage_in]],
                               constant WorldFragUniforms &uniforms [[buffer(0)]],
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
    return qavp_out(float4(albedo.rgb * light * 2.0, uniforms.alpha));
}

// Depth prepass for the world (phase pass A): colour writes are masked off
// at the pipeline, but fence textures must still discard so they cut holes
// in the depth buffer exactly like the colour pass does.
fragment float4 world_depth_fragment(WorldVaryings in [[stage_in]],
                                     texture2d<float> diffuse [[texture(0)]],
                                     sampler diffuseSampler [[sampler(0)]])
{
    if (diffuse.sample(diffuseSampler, in.st).a < 0.666)
        discard_fragment();
    return float4(0.0);
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
    return qavp_out(float4(albedo.rgb, uniforms.alpha));
}

// MARK: - Sky

struct SkyUniforms {
    float time;         // cl.time from the frame packet
    float skyalpha;     // r_skyalpha (cloud layer opacity)
};

// Sky_GetTexCoord (gl_sky.c): project the view ray onto a flattened sphere
// and scroll with time. speed is 8 for the solid layer, 16 for the clouds.
// The projection origin is the per-eye origin from the vertex stage, so the
// two eyes see correctly-parallaxed sky rather than one eye's copy.
static float2 sky_layer_uv(float3 worldpos, float3 eyeorg, float time, float speed)
{
    float3 dir = worldpos - eyeorg;
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
    float3 back = solid.sample(layerSampler, sky_layer_uv(in.worldpos, in.eyeorg, uniforms.time, 8.0)).rgb;
    float4 front = clouds.sample(layerSampler, sky_layer_uv(in.worldpos, in.eyeorg, uniforms.time, 16.0));

    // Upstream draws the solid layer then blends the cloud layer over it
    // with r_skyalpha; folded into one pass here.
    return qavp_out(float4(mix(back, front.rgb, front.a * uniforms.skyalpha), 1.0));
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
    float3 dir = in.worldpos - in.eyeorg;
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

    return qavp_out(float4(faces[axis].sample(faceSampler, uv).rgb, 1.0));
}
