// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  HudPanel.metal
//
//  The modular HUD's (vr_hud 3) per-tile background panel: a procedural
//  stone-textured, rounded-rect card with a raised lit lip, drawn behind
//  each tile's own content by `RendererCore.drawHudTiles` (replaces the
//  earlier flat dark quad). No texture asset -- the stone fill and the
//  bevel lighting are both computed in the fragment shader from the
//  quad's own uv, which spans 0..1 across the PADDED tile bbox (see
//  `RendererCore.hudBgQuad`).
//
//  Same stereo scheme as WheelGuide/Text: one vertex function, per-eye
//  view-projection indexed by [[amplification_id]]. The uniform also
//  carries the padded bbox's aspect ratio so the rounded-rect corners and
//  the stone noise stay isotropic instead of stretching with the tile's
//  own (often very non-square) shape.
//

#include <metal_stdlib>
using namespace metal;

struct HudPanelVertex {
    packed_float3 pos;      // tile-local, same space as the tile's content verts
    packed_float2 uv;       // 0..1 across the padded bbox
    packed_float4 color;    // unused by the fragment; kept for buffer-layout parity
};

struct HudPanelUniforms {
    float4x4 viewproj[2];   // per eye; [1] == [0] on the mono path
    float    aspect;        // paddedW / paddedH
};

struct HudPanelVaryings {
    float4 position [[position]];
    float2 uv;
    float  aspect [[flat]];
};

vertex HudPanelVaryings hud_panel_vertex(uint vid [[vertex_id]],
                                         uint amp [[amplification_id]],
                                         const device HudPanelVertex *verts [[buffer(0)]],
                                         constant HudPanelUniforms &u [[buffer(1)]])
{
    HudPanelVertex v = verts[vid];
    HudPanelVaryings out;
    out.position = u.viewproj[amp] * float4(float3(v.pos), 1.0);
    out.uv = float2(v.uv);
    out.aspect = u.aspect;
    return out;
}

// -- Procedural stone: a small value-noise FBM, no texture asset needed. --

static float qavp_hash21 (float2 p)
{
    p = fract(p * float2(123.34, 456.21));
    p += dot(p, p + 45.32);
    return fract(p.x * p.y);
}

static float qavp_noise2 (float2 p)
{
    float2 i = floor(p);
    float2 f = fract(p);
    float a = qavp_hash21(i);
    float b = qavp_hash21(i + float2(1.0, 0.0));
    float c = qavp_hash21(i + float2(0.0, 1.0));
    float d = qavp_hash21(i + float2(1.0, 1.0));
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

static float qavp_fbm (float2 p)
{
    float sum = 0.0;
    float amp = 0.5;
    for (int i = 0; i < 4; i++) {
        sum += amp * qavp_noise2(p);
        p *= 2.02;
        amp *= 0.5;
    }
    return sum;
}

// Panel look constants -- device-tuned, nudge on device rather than guessed
// here. Units are normalized panel half-extents (see hud_panel_fragment):
// "1.0" is half the panel's SHORTER side, so radius/width read the same
// regardless of a tile's own aspect ratio.
constant float    kPanelCornerRadius = 0.22;   // device-tuned
constant float    kPanelBevelWidth   = 0.10;   // device-tuned
constant float    kPanelBevelStrength = 0.35;  // device-tuned
constant float    kPanelInteriorAlpha = 0.85;  // device-tuned
constant float3   kStoneDark  = float3(0.07, 0.065, 0.06);   // device-tuned
constant float3   kStoneLight = float3(0.24, 0.20, 0.16);    // device-tuned
constant float    kStoneFrequency = 6.0;       // device-tuned

fragment float4 hud_panel_fragment(HudPanelVaryings in [[stage_in]])
{
    // Normalize uv into a centered, aspect-corrected coordinate so a
    // rounded-rect SDF and the noise frequency both stay isotropic on a
    // very wide/short (or tall/narrow) tile instead of stretching into
    // ellipses and streaks.
    float2 halfSize = in.aspect >= 1.0 ? float2(in.aspect, 1.0)
                                       : float2(1.0, 1.0 / in.aspect);
    float2 p = (in.uv * 2.0 - 1.0) * halfSize;

    // Rounded-rect SDF (Inigo Quilez's formulation): negative inside,
    // zero at the border, positive outside.
    float2 d = abs(p) - halfSize + kPanelCornerRadius;
    float dist = min(max(d.x, d.y), 0.0) + length(max(d, 0.0)) - kPanelCornerRadius;
    if (dist > 0.0) {
        discard_fragment();
    }

    float n = qavp_fbm(in.uv * kStoneFrequency);
    float3 stone = mix(kStoneDark, kStoneLight, n);

    // Raised lip: brighten the top-left border band, darken the
    // bottom-right, faking a directional light from the SDF's own border
    // distance and a normalized outward direction -- reads as a bevel
    // without an actual normal map.
    float band = 1.0 - smoothstep(0.0, kPanelBevelWidth, -dist);
    float2 outward = normalize(p + float2(1e-4, 1e-4));
    float2 lightDir = normalize(float2(-1.0, -1.0));
    float lightTerm = dot(outward, lightDir);
    stone += lightTerm * band * kPanelBevelStrength;

    float alpha = kPanelInteriorAlpha * (1.0 - smoothstep(-0.015, 0.0, dist));
    float3 c = clamp(stone, 0.0, 1.0);
    // Premultiplied, matching the mixed-immersion contract (see Text.metal).
    return float4(c * alpha, alpha);
}
