//
//  Sprite.metal
//
//  Quake sprite models (explosions s_explod.spr, bubbles, ...) as 3D
//  camera-facing textured billboards. The bridge builds each quad in Quake
//  world space (QR_EmitSpriteModel, a (right, up) basis per SPR_* type that
//  faces the packet view) and hands over a flat vertex run batched by texture;
//  this transforms per eye and samples the sprite texture, fullbright.
//
//  Same stereo scheme as Text/WheelGuide: one vertex function, per-eye
//  view-projection indexed by [[amplification_id]]. Drawn depth-tested with
//  no depth write, alpha-blended; output premultiplied to match the
//  mixed-immersion contract (so it composites over passthrough correctly).
//

#include <metal_stdlib>
using namespace metal;

struct SpriteVertex {
    packed_float3 pos;      // Quake world space
    packed_float2 st;       // into the sprite frame texture
};

struct SpriteUniforms {
    float4x4 viewproj[2];   // per eye; [1] == [0] on the mono path
    float    alpha;         // entity alpha for this batch
};

struct SpriteVaryings {
    float4 position [[position]];
    float2 uv;
    float  alpha [[flat]];
};

vertex SpriteVaryings sprite_vertex(uint vid [[vertex_id]],
                                    uint amp [[amplification_id]],
                                    const device SpriteVertex *verts [[buffer(0)]],
                                    constant SpriteUniforms &u [[buffer(1)]])
{
    SpriteVertex v = verts[vid];
    SpriteVaryings out;
    out.position = u.viewproj[amp] * float4(float3(v.pos), 1.0);
    out.uv = float2(v.st);
    out.alpha = u.alpha;
    return out;
}

fragment float4 sprite_fragment(SpriteVaryings in [[stage_in]],
                                texture2d<float> tex [[texture(0)]])
{
    constexpr sampler s(mag_filter::linear, min_filter::linear,
                        address::clamp_to_edge);
    float4 t = tex.sample(s, in.uv);
    float a = t.a * in.alpha;
    if (a < 0.02)
        discard_fragment();
    // Premultiplied, matching the mixed-immersion contract.
    return float4(t.rgb * a, a);
}
