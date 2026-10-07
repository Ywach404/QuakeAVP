//
//  ControllerHandModel.swift
//
//  A rigid stand-in hand for CONTROLLER mode. With PSVR2 Sense controllers the
//  ARKit hand-tracking session is torn down (no finger joints), but the
//  controller's 6DOF pose is tracked -- so we pose a fixed low-poly hand on the
//  OFF hand for presence. The gun hand gets none; it holds the weapon model.
//
//  Bead style matches the bare-hand VirtualHand (disconnected ellipsoids), so
//  the two input modes look of a piece. Produced render-side in controller mode
//  and published through VirtualHand (which HandInput leaves empty then), so the
//  existing draw path, the 1-phase fade and the "virtual hand" hide toggle all
//  apply unchanged.
//
//  Local frame = the controller frame: +X right, +Y up, forward = -Z. The grip
//  layout below is a FIRST PASS -- the numbers are what to tune on device if the
//  hand sits wrong relative to the controller; mirror on X serves both hands.
//

import simd

enum ControllerHandModel {

    private static let skin = SIMD4<Float>(0.80, 0.60, 0.48, 1)
    private static var cacheRight: [Float]?
    private static var cacheLeft: [Float]?

    /// The hand's local-space beads transformed by `m` (expected:
    /// recenterCorrection * offHandControllerPose), ready for VirtualHand.
    /// 7 floats/vertex (xyz + rgba), triangle list.
    static func posed(by m: simd_float4x4, leftHand: Bool) -> [Float] {
        let local: [Float]
        if leftHand {
            local = cacheLeft ?? build(leftHand: true)
            cacheLeft = local
        } else {
            local = cacheRight ?? build(leftHand: false)
            cacheRight = local
        }
        var out = [Float](repeating: 0, count: local.count)
        var i = 0
        while i < local.count {
            let p = m * SIMD4(local[i], local[i + 1], local[i + 2], 1)
            out[i] = p.x; out[i + 1] = p.y; out[i + 2] = p.z
            out[i + 3] = local[i + 3]; out[i + 4] = local[i + 4]
            out[i + 5] = local[i + 5]; out[i + 6] = local[i + 6]
            i += 7
        }
        return out
    }

    private static func build(leftHand: Bool) -> [Float] {
        var v: [Float] = []
        let mir: Float = leftHand ? -1 : 1

        // A low-poly ellipsoid bead (lon 6 x lat 3), centre mirrored on X for
        // the left hand (the sphere itself is symmetric).
        func bead(_ cx: Float, _ cy: Float, _ cz: Float, _ r: Float) {
            let lon = 6, lat = 3
            func pt(_ i: Int, _ j: Int) -> SIMD3<Float> {
                let phi = Float.pi * Float(j) / Float(lat)
                let th = 2 * Float.pi * Float(i) / Float(lon)
                return SIMD3(cx * mir + r * sin(phi) * cos(th),
                             cy + r * cos(phi),
                             cz + r * sin(phi) * sin(th))
            }
            func emit(_ p: SIMD3<Float>) {
                v += [p.x, p.y, p.z, skin.x, skin.y, skin.z, skin.w]
            }
            for j in 0..<lat {
                for i in 0..<lon {
                    let a = pt(i, j), b = pt(i + 1, j)
                    let d = pt(i + 1, j + 1), e = pt(i, j + 1)
                    emit(a); emit(b); emit(d)
                    emit(a); emit(d); emit(e)
                }
            }
        }

        // Palm just below/at the controller point.
        bead(0.0, -0.01, 0.0, 0.028)
        // Four fingers wrapping the grip: a knuckle forward (-Z) and a curled
        // tip below, spread across X.
        for x in [Float(-0.022), -0.008, 0.006, 0.020] {
            bead(x, -0.015, -0.028, 0.012)   // knuckle
            bead(x, -0.035, -0.020, 0.009)   // curled tip
        }
        // Thumb across the top of the grip.
        bead(0.030, 0.0, -0.006, 0.012)
        bead(0.034, -0.016, -0.018, 0.009)
        return v
    }
}
