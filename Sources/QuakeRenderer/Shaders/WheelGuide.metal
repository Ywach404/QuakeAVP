// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  WheelGuide.metal
//
//  The weapon wheel's guide: a wireframe ring in world space plus a bright
//  marker arc at the highlighted slot, so the radial layout is legible and
//  you can see which weapon you're about to pick. Drawn as line primitives
//  after the world, no depth test, so it floats over the scene like a HUD
//  element that happens to live in 3D.
//
//  Inherits the stereo scheme: one vertex function, per-eye view-projection
//  indexed by [[amplification_id]], colour carried to the fragment flat.
//  Positions arrive already in Quake world space; the caller builds the
//  ring geometry on the CPU from the packet's wheel fields.
//

#include <metal_stdlib>
using namespace metal;

constant bool qavp_guide_linear [[function_constant(0)]];

struct GuideVertex {
    packed_float3 pos;      // Quake world space
    packed_float4 color;    // rgba, linear-authored
};

struct GuideUniforms {
    float4x4 viewproj[2];   // per eye; [1] == [0] on the mono path
};

struct GuideVaryings {
    float4 position [[position]];
    float4 color [[flat]];
};

vertex GuideVaryings wheel_guide_vertex(uint vid [[vertex_id]],
                                        uint amp [[amplification_id]],
                                        const device GuideVertex *verts [[buffer(0)]],
                                        constant GuideUniforms &u [[buffer(1)]])
{
    GuideVertex v = verts[vid];
    GuideVaryings out;
    out.position = u.viewproj[amp] * float4(float3(v.pos), 1.0);
    out.color = float4(v.color);
    return out;
}

fragment float4 wheel_guide_fragment(GuideVaryings in [[stage_in]])
{
    float4 c = in.color;
    if (qavp_guide_linear) {
        float3 lo = c.rgb / 12.92;
        float3 hi = pow((c.rgb + 0.055) / 1.055, 2.4);
        c.rgb = select(hi, lo, c.rgb <= 0.04045);
    }
    // Premultiplied, matching the mixed-immersion contract.
    return float4(c.rgb * c.a, c.a);
}
