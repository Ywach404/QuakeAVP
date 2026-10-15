// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  Alias.metal
//
//  Alias (MDL) model rendering: two poses of packed byte vertices bound at
//  different offsets into one mesh buffer, lerped in the vertex shader with
//  the blend factor — upstream's GLSL alias path (r_alias.c) with the two
//  attribute pointers replaced by two buffer bindings. Lighting is the MH
//  shade-dot approximation against the quantized shadevector, exactly the
//  upstream shader; the light color arrives with overbright-model doubling
//  already baked. Fullbright skin pixels ride a second texture that is
//  added on top (a black texture stands in when the skin has none).
//
//  Inherits the M3 stereo scheme: per-eye view-projections indexed by
//  [[amplification_id]]; the mono window fills both slots.
//
//  Vertex layout must match qc_mesh_vertex_t in QuakeCore.h.
//

#include <metal_stdlib>
using namespace metal;

// Same contract as World.metal's qavp_linear_output; see that file.
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

struct AliasVertex {
    uchar4 xyz;     // raw MDL byte positions; the model matrix bakes
                    // scale_origin/scale
    char4 normal;   // [-127..127]
};

struct AliasUniforms {
    float4x4 viewproj[2];   // per eye; [1] == [0] on the mono path
    float4x4 model;
    float4 light;           // rgb = light color, a = entity alpha
    float4 shadeblend;      // xyz = shadevector, w = pose blend
    float4 clip;            // byte-space clip window for the hand weapon:
                            // x = front plane, y = rear plane, zw = collapse
                            // centre (y,z). x>=255 & y<0 disable each end.
    float4 dbg;             // dbg.x > 0.5 => draw solid green (identify tint)
    float4 eyeorg[2];       // per-eye view origin, Quake units (for fog)
    float4 fog;             // xyz = fog color, w = exp2 density (0 = no fog)
};

// Global exp2 distance fog (gl_fog.c), base-e matching GL_EXP2. Same as
// World.metal's apply_fog; density 0 short-circuits.
inline float3 alias_apply_fog(float3 rgb, float3 worldpos, float3 eyeorg, float4 fog)
{
    if (fog.w <= 0.0) return rgb;
    float d = fog.w * length(worldpos - eyeorg);
    float f = clamp(exp(-d * d), 0.0, 1.0);
    return mix(fog.xyz, rgb, f);
}

// Retract geometry the view models bake past EITHER end of the gun (a nail
// out the barrel, a round behind the receiver): any vertex forward of the
// front plane or behind the rear plane is pulled onto a point on that plane
// so its triangles degenerate away, leaving the gun body untouched.
static inline float3 alias_clip(float3 p, float4 clip)
{
    if (p.x > clip.x) return float3(clip.x, clip.z, clip.w);
    if (p.x < clip.y) return float3(clip.y, clip.z, clip.w);
    return p;
}

struct AliasVaryings {
    float4 position [[position]];
    float2 st;
    float4 color;
    float dbgHi [[flat]];   // > 0.5 => solid-green identify tint
    float3 worldpos;
    float3 eyeorg [[flat]];
    float4 fog [[flat]];
};

// From MH (via upstream's GLSL vertex shader): reproduces the anorm_dots
// table within reasonable tolerance for the >= 0 case, and their negative
// branch verbatim.
static float avertexnormal_dot(float3 vertexnormal, float3 shadevector)
{
    float d = dot(vertexnormal, shadevector);
    if (d < 0.0)
        return 1.0 + d * (13.0 / 44.0);
    else
        return 1.0 + d;
}

vertex AliasVaryings alias_vertex(uint vid [[vertex_id]],
                                  uint amp [[amplification_id]],
                                  const device AliasVertex *pose1 [[buffer(0)]],
                                  const device AliasVertex *pose2 [[buffer(1)]],
                                  const device float2 *texcoords [[buffer(2)]],
                                  constant AliasUniforms &uniforms [[buffer(3)]])
{
    float blend = uniforms.shadeblend.w;
    float3 shade = uniforms.shadeblend.xyz;

    // Lerp FIRST, then clip once. Clipping each pose separately and lerping the
    // results mixes a vertex's collapse point against its real position
    // whenever it is past the plane in one pose and not the other -- dragging
    // that vertex across the model for the whole blend. On a weapon with much
    // forward/back travel between frames (the rocket launcher's recoil) that
    // smears the geometry every shot. One decision on the blended vertex means
    // a triangle collapses coherently or not at all.
    float3 p1 = float3(pose1[vid].xyz.x, pose1[vid].xyz.y, pose1[vid].xyz.z);
    float3 p2 = float3(pose2[vid].xyz.x, pose2[vid].xyz.y, pose2[vid].xyz.z);
    float3 p = alias_clip(mix(p1, p2, blend), uniforms.clip);
    float4 world = uniforms.model * float4(p, 1.0);

    float dot1 = avertexnormal_dot(float3(pose1[vid].normal.x, pose1[vid].normal.y, pose1[vid].normal.z) * (1.0 / 127.0), shade);
    float dot2 = avertexnormal_dot(float3(pose2[vid].normal.x, pose2[vid].normal.y, pose2[vid].normal.z) * (1.0 / 127.0), shade);

    AliasVaryings out;
    out.position = uniforms.viewproj[amp] * world;
    out.st = texcoords[vid];
    out.color = float4(uniforms.light.rgb * mix(dot1, dot2, blend), uniforms.light.a);
    out.dbgHi = uniforms.dbg.x;
    out.worldpos = world.xyz;
    out.eyeorg = uniforms.eyeorg[amp].xyz;
    out.fog = uniforms.fog;
    return out;
}

fragment float4 alias_fragment(AliasVaryings in [[stage_in]],
                               texture2d<float> skin [[texture(0)]],
                               texture2d<float> fullbright [[texture(1)]],
                               sampler skinSampler [[sampler(0)]])
{
    // Debug identify: paint the whole entity solid green, skin and all.
    if (in.dbgHi > 0.5)
        return qavp_out(float4(0.0, 1.0, 0.0, 1.0));

    float4 tex = skin.sample(skinSampler, in.st);

    // MF_HOLEY fence-style skins; opaque skins have a == 1 so the test is
    // free for them, same trick as the world fragment.
    if (tex.a < 0.666)
        discard_fragment();

    float3 rgb = tex.rgb * in.color.rgb + fullbright.sample(skinSampler, in.st).rgb;
    rgb = alias_apply_fog(clamp(rgb, 0.0, 1.0), in.worldpos, in.eyeorg, in.fog);
    return qavp_out(float4(rgb, in.color.a));
}
