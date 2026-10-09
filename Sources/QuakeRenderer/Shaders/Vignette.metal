//
//  Vignette.metal
//
//  Comfort vignette: a fullscreen periphery fade drawn last, at the
//  packet's eased strength, while artificial locomotion is fast. The
//  radial falloff runs on interpolated NDC — not framebuffer position —
//  so foveated (variable-rasterization-rate) targets sample it correctly.
//
//  Alpha contract (mixed immersion): the target holds PREMULTIPLIED
//  linear rgb. Black at alpha a premultiplies to (0,0,0,a); blended with
//  (one, oneMinusSourceAlpha) it darkens rendered world and passthrough
//  alike — over passthrough the accumulated alpha is what dims the room,
//  which is the entire point of narrowing the FOV.
//

#include <metal_stdlib>
using namespace metal;

struct VignetteVaryings {
    float4 position [[position]];
    float2 ndc;
};

struct VignetteUniforms {
    float strength;     // qc_frame_t.vignette, eased engine-side
};

// One triangle covering the screen; same geometry for both amplified eyes.
vertex VignetteVaryings vignette_vertex(uint vid [[vertex_id]])
{
    float2 ndc = float2(vid == 1 ? 3.0 : -1.0, vid == 2 ? 3.0 : -1.0);
    VignetteVaryings out;
    out.position = float4(ndc, 0.0, 1.0);
    out.ndc = ndc;
    return out;
}

fragment float4 vignette_fragment(VignetteVaryings in [[stage_in]],
                                  constant VignetteUniforms &uniforms [[buffer(0)]])
{
    float d = length(in.ndc);
    float a = uniforms.strength * smoothstep(0.55, 1.05, d);
    return float4(0.0, 0.0, 0.0, a);
}

// Polyblend: the engine's v_blend, a uniform fullscreen rgba tint (damage,
// pickup, powerup, underwater/lava/slime). Reuses vignette_vertex. Output is
// PREMULTIPLIED to match the mixed-immersion contract, so the (one,
// oneMinusSourceAlpha) blend tints the rendered world and passthrough alike.
struct PolyblendUniforms {
    float4 blend;       // qc_frame_t.v_blend: rgb + alpha
};

fragment float4 polyblend_fragment(VignetteVaryings in [[stage_in]],
                                   constant PolyblendUniforms &uniforms [[buffer(0)]])
{
    float a = uniforms.blend.a;
    return float4(uniforms.blend.rgb * a, a);
}
