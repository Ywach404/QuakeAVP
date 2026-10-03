//
//  VRTrack.swift
//
//  The head/aim sidecar that rides next to a recorded demo. A Quake demo
//  carries the game state but not where the head was: the immersive camera
//  is late-latched render-side and never reaches the engine. So the
//  immersive thread writes one sample per render frame, keyed on cl.time --
//  the SERVER clock, the same one the demo's messages are stamped with --
//  and the exporter samples this track at each replayed packet's time to
//  rebuild the camera the player actually had.
//
//  Never key the track on wall time: a paused or slowed engine (the weapon
//  wheel) would drift it off the demo.
//

import Foundation
import simd

/// One immersive render frame's worth of camera truth.
struct VRTrackSample: Equatable {
    var clTime: Float
    /// Seconds since recording started; only used to spread samples that
    /// share a cl.time (see `resample`).
    var wall: Float
    /// Head position, Quake units, world.
    var position: SIMD3<Float>
    /// Head orientation: tracking axes (x right, y up, -z forward) in world.
    var orientation: simd_quatf
    var bodyYaw: Float
    var aimValid: Bool
    /// Body frame fwd/right/up, Quake units -- what QC_InputSetAim was fed.
    var aimOrigin: SIMD3<Float>
    var aimYaw: Float
    var aimPitch: Float
    /// fwd/right/up fed to QC_InputSetHeadOffset.
    var headOffset: SIMD3<Float>
    var heightTrim: Float

    static let identity = VRTrackSample(
        clTime: 0, wall: 0, position: .zero,
        orientation: simd_quatf(angle: 0, axis: SIMD3(0, 1, 0)),
        bodyYaw: 0, aimValid: false, aimOrigin: .zero, aimYaw: 0, aimPitch: 0,
        headOffset: .zero, heightTrim: 0)
}

struct VRTrack: Equatable {
    /// "QAVT" as little-endian bytes.
    static let magic: UInt32 = 0x5456_4151
    static let version: UInt32 = 1
    static let recordFloats = 20

    var samples: [VRTrackSample]

    // MARK: - File

    func write(to url: URL) throws {
        var data = Data()
        data.reserveCapacity(12 + samples.count * Self.recordFloats * 4)
        func put(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        put(Self.magic); put(Self.version); put(UInt32(samples.count))
        for s in samples {
            let f: [Float] = [
                s.clTime, s.wall, s.position.x, s.position.y, s.position.z,
                s.orientation.imag.x, s.orientation.imag.y, s.orientation.imag.z, s.orientation.real,
                s.bodyYaw, s.aimValid ? 1 : 0, s.aimOrigin.x, s.aimOrigin.y, s.aimOrigin.z,
                s.aimYaw, s.aimPitch, s.headOffset.x, s.headOffset.y, s.headOffset.z, s.heightTrim,
            ]
            for v in f { put(v.bitPattern) }
        }
        try data.write(to: url, options: .atomic)
    }

    static func load(url: URL) throws -> VRTrack {
        let data = try Data(contentsOf: url)
        func u32(_ o: Int) -> UInt32 {
            data.subdata(in: o..<(o + 4)).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }
        }
        guard data.count >= 12, u32(0) == magic, u32(4) == version else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let count = Int(u32(8))
        guard data.count >= 12 + count * recordFloats * 4 else { throw CocoaError(.fileReadCorruptFile) }
        var out: [VRTrackSample] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let base = 12 + i * recordFloats * 4
            func f(_ k: Int) -> Float { Float(bitPattern: u32(base + k * 4)) }
            out.append(VRTrackSample(
                clTime: f(0), wall: f(1), position: SIMD3(f(2), f(3), f(4)),
                orientation: simd_quatf(ix: f(5), iy: f(6), iz: f(7), r: f(8)),
                bodyYaw: f(9), aimValid: f(10) > 0.5,
                aimOrigin: SIMD3(f(11), f(12), f(13)), aimYaw: f(14), aimPitch: f(15),
                headOffset: SIMD3(f(16), f(17), f(18)), heightTrim: f(19)))
        }
        return VRTrack(samples: out)
    }

    // MARK: - Keys

    /// Render frames outnumber engine ticks (both nominally 90 Hz, never in
    /// phase), so runs of samples share one cl.time. Spread each run
    /// linearly by wall clock up to the next distinct cl.time, leaving
    /// strictly increasing keys.
    mutating func resample() {
        guard samples.count > 1 else { return }
        var i = 0
        while i < samples.count {
            var j = i
            while j + 1 < samples.count, samples[j + 1].clTime == samples[i].clTime { j += 1 }
            if j > i {
                let t0 = samples[i].clTime
                let w0 = samples[i].wall
                let hasNext = j + 1 < samples.count
                // With no later key, assume real time: one wall second is one
                // demo second.
                let nextT: Float = hasNext ? samples[j + 1].clTime : t0 + (samples[j].wall - w0)
                let nextW: Float = hasNext ? samples[j + 1].wall : samples[j].wall
                let span = max(nextW - w0, 1e-6)
                for k in i...j {
                    let frac = min(max((samples[k].wall - w0) / span, 0), 1)
                    samples[k].clTime = t0 + (nextT - t0) * frac
                }
                // Keep the run strictly increasing even if wall stamps repeat.
                for k in (i + 1)...j where samples[k].clTime <= samples[k - 1].clTime {
                    samples[k].clTime = samples[k - 1].clTime.nextUp
                }
            }
            i = j + 1
        }
    }

    /// Pose at demo time `t`; clamps to the first/last sample outside the
    /// track (a recording that started after the demo holds its first pose).
    func sample(at t: Float) -> VRTrackSample {
        guard let first = samples.first, let last = samples.last else { return .identity }
        if t <= first.clTime { return first }
        if t >= last.clTime { return last }
        var lo = 0, hi = samples.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if samples[mid].clTime <= t { lo = mid } else { hi = mid }
        }
        let a = samples[lo], b = samples[hi]
        let f = (t - a.clTime) / max(b.clTime - a.clTime, 1e-6)
        var s = a
        s.clTime = t
        s.position = simd_mix(a.position, b.position, SIMD3(repeating: f))
        s.orientation = simd_slerp(a.orientation, b.orientation, f)
        s.bodyYaw = a.bodyYaw + Self.wrapDegrees(b.bodyYaw - a.bodyYaw) * f
        s.aimOrigin = simd_mix(a.aimOrigin, b.aimOrigin, SIMD3(repeating: f))
        s.aimYaw = a.aimYaw + Self.wrapDegrees(b.aimYaw - a.aimYaw) * f
        s.aimPitch = a.aimPitch + (b.aimPitch - a.aimPitch) * f
        s.headOffset = simd_mix(a.headOffset, b.headOffset, SIMD3(repeating: f))
        s.heightTrim = a.heightTrim + (b.heightTrim - a.heightTrim) * f
        return s
    }

    static func wrapDegrees(_ d: Float) -> Float {
        var x = d.truncatingRemainder(dividingBy: 360)
        if x > 180 { x -= 360 } else if x < -180 { x += 360 }
        return x
    }

    /// One-pole low-pass over position and orientation, time constant `tau`
    /// seconds of demo time. The frag-comp look: micro-shake gone, intent
    /// kept. Everything else (aim, body yaw) passes through untouched so the
    /// weapon still sits where the hand was.
    static func smoothed(_ track: VRTrack, tau: Float) -> VRTrack {
        guard var prev = track.samples.first else { return track }
        var out = track
        for i in 1..<out.samples.count {
            let s = out.samples[i]
            let dt = max(s.clTime - prev.clTime, 0)
            let k = 1 - exp(-dt / max(tau, 1e-4))
            var m = s
            m.position = simd_mix(prev.position, s.position, SIMD3(repeating: k))
            m.orientation = simd_slerp(prev.orientation, s.orientation, k)
            out.samples[i] = m
            prev = m
        }
        return out
    }
}
