// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  TrackRecorder.swift
//
//  Live sidecar capture (see VRTrack.swift). `noteFrame` is appended from
//  the immersive render thread once per frame with the same late-latched
//  pose the eyes were drawn with; `feedAim` is the one route every aim
//  source takes into QC_InputSetAim, so the recorder sees exactly what the
//  engine was fed. Nothing here touches engine state beyond that forwarded
//  any-thread setter.
//

import Foundation
import simd

final class TrackRecorder: @unchecked Sendable {

    static let shared = TrackRecorder()

    private let lock = NSLock()
    private var samples: [VRTrackSample] = []
    private var url: URL?
    private var started: CFAbsoluteTime = 0
    private var aimValid = false
    private var aimOrigin = SIMD3<Float>(0, 0, 0)
    private var aimYaw: Float = 0
    private var aimPitch: Float = 0

    var isRecording: Bool { lock.lock(); defer { lock.unlock() }; return url != nil }

    func start(url: URL) {
        lock.lock(); defer { lock.unlock() }
        self.url = url
        samples.removeAll(keepingCapacity: true)
        samples.reserveCapacity(90 * 60 * 5)
        started = CFAbsoluteTimeGetCurrent()
    }

    /// Writes the file on a background queue. Safe to call when not recording.
    func stop() {
        lock.lock()
        guard let url else { lock.unlock(); return }
        let track = VRTrack(samples: samples)
        self.url = nil
        samples = []
        lock.unlock()
        DispatchQueue.global(qos: .utility).async {
            do { try track.write(to: url) } catch { print("vrtrack: write failed: \(error)") }
        }
    }

    /// The single road into QC_InputSetAim. `origin` is body-frame
    /// fwd/right/up in Quake units, angles in Quake degrees.
    func feedAim(valid: Bool, origin: SIMD3<Float>, yaw: Float, pitch: Float) {
        QC_InputSetAim(valid ? 1 : 0, origin.x, origin.y, origin.z, yaw, pitch)
        // These are the RAW angles, before the engine adds the aim trims, which
        // is what "sight in" needs to measure. Tapped here because this is the
        // one road every aim source takes.
        AimCalibration.shared.noteAim(valid: valid, yaw: yaw, pitch: pitch)
        lock.lock()
        aimValid = valid; aimOrigin = origin; aimYaw = yaw; aimPitch = pitch
        lock.unlock()
    }

    /// `quakeFromHead` is quakeFromOrigin * originFromDevice from the
    /// immersive path; its linear part carries a 1/worldScale that is
    /// stripped here so the stored orientation is a unit quaternion.
    func noteFrame(clTime: Float, quakeFromHead: simd_float4x4, worldScale: Float,
                   bodyYaw: Float, headOffset: SIMD3<Float>, heightTrim: Float) {
        lock.lock(); defer { lock.unlock() }
        guard url != nil else { return }
        let s = worldScale > 0 ? worldScale : 0.0254
        let c0 = SIMD3(quakeFromHead.columns.0.x, quakeFromHead.columns.0.y, quakeFromHead.columns.0.z) * s
        let c1 = SIMD3(quakeFromHead.columns.1.x, quakeFromHead.columns.1.y, quakeFromHead.columns.1.z) * s
        let c2 = SIMD3(quakeFromHead.columns.2.x, quakeFromHead.columns.2.y, quakeFromHead.columns.2.z) * s
        let p = quakeFromHead.columns.3
        samples.append(VRTrackSample(
            clTime: clTime,
            wall: Float(CFAbsoluteTimeGetCurrent() - started),
            position: SIMD3(p.x, p.y, p.z),
            orientation: simd_normalize(simd_quatf(simd_float3x3(columns: (c0, c1, c2)))),
            bodyYaw: bodyYaw, aimValid: aimValid, aimOrigin: aimOrigin,
            aimYaw: aimYaw, aimPitch: aimPitch,
            headOffset: headOffset, heightTrim: heightTrim))
    }
}
