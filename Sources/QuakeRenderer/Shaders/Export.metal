// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  Export.metal
//
//  Offline export helpers. Motion blur is sub-frame accumulation, the
//  q3mme way: each sub-step's colour is added with weight 1/N into an
//  rgba16Float accumulator, then resolved into the encoder's bgra8 buffer
//  and the accumulator cleared for the next frame.
//

#include <metal_stdlib>
using namespace metal;

kernel void export_accumulate(texture2d<float, access::read>       src  [[texture(0)]],
                              texture2d<float, access::read_write> acc  [[texture(1)]],
                              constant float &weight                    [[buffer(0)]],
                              uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= acc.get_width() || gid.y >= acc.get_height()) return;
    float4 c = src.read(gid);
    acc.write(acc.read(gid) + float4(c.rgb * weight, 0.0), gid);
}

kernel void export_resolve(texture2d<float, access::read_write> acc [[texture(0)]],
                           texture2d<float, access::write>      dst [[texture(1)]],
                           uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= dst.get_width() || gid.y >= dst.get_height()) return;
    float4 c = acc.read(gid);
    dst.write(float4(saturate(c.rgb), 1.0), gid);
    acc.write(float4(0.0), gid);
}
