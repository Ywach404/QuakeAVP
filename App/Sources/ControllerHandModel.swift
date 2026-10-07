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
//  Local frame = the controller frame: +X right, +Y up, forward = -Z. The hand
//  is modelled OPEN and reaching forward (fingers toward -Z, thumb out +X);
//  the exact handshake angle comes from the off-hand rotation offset the
//  caller folds into the pose matrix (vr_offhand{pitch,yaw,roll} sliders), so
//  it can be dialled in on device. Mirror on X serves both hands.
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

        // An OPEN hand REACHING FORWARD (fingers toward -Z) -- the basis for a
        // handshake once the off-hand rotation offset (vr_offhand* sliders)
        // rolls it to the exact angle. A presence stand-in, not an accurate
        // grip, so it reads as a hand rather than a fist on the controller.
        // Bigger than the first curled pass so it's visible.

        // Palm: three beads for a flat-ish heel-and-pad shape, back a touch.
        bead( 0.000, 0.0,  0.020, 0.040)   // heel of palm
        bead(-0.018, 0.0, -0.008, 0.034)   // pad, little-finger side
        bead( 0.018, 0.0, -0.008, 0.034)   // pad, index side

        // Four straight fingers pointing forward (-Z), splayed apart with
        // length, middle longest. Three beads each (base knuckle / mid / tip).
        let fx:   [Float] = [-0.030, -0.010, 0.010, 0.030]   // pinky .. index
        let flen: [Float] = [ 0.085,  0.110, 0.115, 0.095]
        for n in 0..<4 {
            let x = fx[n], L = flen[n]
            let fan = x * 0.25            // fingers fan apart as they extend
            bead(x,           0.0, -0.035,       0.015)    // base
            bead(x + fan*0.5, 0.0, -0.035 - L*0.5, 0.0135) // mid
            bead(x + fan,     0.0, -0.035 - L,     0.012)  // tip
        }

        // Thumb out to the side (mirrored for the left hand), angled up/fwd.
        bead(0.042, 0.012, -0.010, 0.016)   // base
        bead(0.058, 0.030, -0.030, 0.013)   // tip
        return v
    }
}
