// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  Text.metal
//
//  2D text as billboarded glyph quads sampled from Quake's conchars atlas:
//  weapon-wheel labels, the item selector, the HUD. The bridge lays the
//  glyphs out in Quake world space (a (right, up) basis chosen to face the
//  eye) and hands over a flat vertex run; this just transforms per eye and
//  samples the atlas.
//
//  Same stereo scheme as WheelGuide: one vertex function, per-eye
//  view-projection indexed by [[amplification_id]]. Nearest sampling keeps
//  the 8x8 glyphs crisp; index 0/255 of the atlas are transparent, so the
//  quad shows only ink.
//

#include <metal_stdlib>
using namespace metal;

constant bool qavp_text_linear [[function_constant(0)]];

struct TextVertex {
    packed_float3 pos;      // Quake world space
    packed_float2 uv;       // into the 128x128 conchars atlas
    packed_float4 color;    // rgba tint, sRGB-authored
};

struct TextUniforms {
    float4x4 viewproj[2];   // per eye; [1] == [0] on the mono path
};

struct TextVaryings {
    float4 position [[position]];
    float2 uv;
    float4 color [[flat]];
};

vertex TextVaryings text_vertex(uint vid [[vertex_id]],
                                uint amp [[amplification_id]],
                                const device TextVertex *verts [[buffer(0)]],
                                constant TextUniforms &u [[buffer(1)]])
{
    TextVertex v = verts[vid];
    TextVaryings out;
    out.position = u.viewproj[amp] * float4(float3(v.pos), 1.0);
    out.uv = float2(v.uv);
    out.color = float4(v.color);
    return out;
}

fragment float4 text_fragment(TextVaryings in [[stage_in]],
                              texture2d<float> atlas [[texture(0)]])
{
    constexpr sampler s(mag_filter::nearest, min_filter::nearest,
                        address::clamp_to_edge);
    float4 c = atlas.sample(s, in.uv) * in.color;
    if (qavp_text_linear) {
        float3 lo = c.rgb / 12.92;
        float3 hi = pow((c.rgb + 0.055) / 1.055, 2.4);
        c.rgb = select(hi, lo, c.rgb <= 0.04045);
    }
    // Premultiplied, matching the mixed-immersion contract.
    return float4(c.rgb * c.a, c.a);
}
