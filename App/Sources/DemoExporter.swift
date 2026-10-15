// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  DemoExporter.swift
//
//  Drives one offline export: takes over the packet stream from the window,
//  lock-steps the engine through `playdemo`, renders each step offscreen
//  (ExportRenderer) and feeds the encoder (VideoEncoder). UI state lives on
//  the main actor; the work runs on its own thread so the window stays
//  responsive and the engine thread never waits on anything but our step
//  requests.
//
//  Threading contract: while `.export` owns the stream this thread is the
//  only QC_Renderer* caller. Every engine entry point still executes on the
//  engine thread, inside `QuakeEngineHost.step`; commands go through the
//  host's queue and the rest through the any-thread setters.
//

import CoreVideo
import Foundation
import Metal
import Observation

@Observable
@MainActor
final class DemoExporter {

    enum State: Equatable {
        case idle
        case running(frames: Int, demoTime: Float)
        case done(URL)
        case failed(String)
    }

    private(set) var state: State = .idle
    private let cancelled = CancelFlag()

    var isRunning: Bool { if case .running = state { return true } else { return false } }

    func cancel() { cancelled.set() }

    /// Refuses (with a reason in `state`) rather than fighting the
    /// compositor thread for the stream while the immersive space is open.
    func start(demo: String, preset: ExportPreset, host: QuakeEngineHost?, core: RendererCore?,
               gameDirectory: URL, exportsDirectory: URL, immersiveActive: Bool) {
        guard !isRunning else { return }
        guard !immersiveActive else {
            state = .failed("Exit the immersive space first; it owns the renderer.")
            return
        }
        guard let host, let core else {
            state = .failed("The engine is not running.")
            return
        }
        guard !demo.isEmpty else {
            state = .failed("Pick a demo.")
            return
        }

        let camera: ExportCamera
        switch preset.camera {
        case .gun:
            camera = .gun
        case .chase:
            camera = .chase
        case .orbit:
            camera = .orbit
        case .front:
            camera = .front
        case .head, .smoothed:
            let url = gameDirectory.appendingPathComponent("\(demo).vrtrack")
            guard var track = try? VRTrack.load(url: url), !track.samples.isEmpty else {
                state = .failed("No head track for \(demo); use the Gun camera.")
                return
            }
            track.resample()
            camera = preset.camera == .head
                ? .head(track)
                : .smoothedHead(VRTrack.smoothed(track, tau: 0.12))
        }

        let out = exportsDirectory.appendingPathComponent(preset.fileName(demo: demo))
        cancelled.reset()
        state = .running(frames: 0, demoTime: 0)

        let cancelled = self.cancelled
        let thread = Thread { [weak self] in
            let result = Self.run(demo: demo, preset: preset, camera: camera, out: out,
                                  host: host, core: core, cancelled: cancelled) { frames, t in
                Task { @MainActor in
                    guard let self, self.isRunning else { return }
                    self.state = .running(frames: frames, demoTime: t)
                }
            }
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let url): self.state = .done(url)
                case .failure(let error): self.state = .failed("\(error)")
                }
            }
        }
        thread.name = "quake.export"
        thread.stackSize = 4 << 20
        thread.start()
    }

    // MARK: - The export thread

    nonisolated private static func run(demo: String, preset: ExportPreset, camera: ExportCamera,
                                        out: URL, host: QuakeEngineHost, core: RendererCore,
                                        cancelled: CancelFlag,
                                        progress: @escaping (Int, Float) -> Void) -> Result<URL, Error> {
        guard let renderer = ExportRenderer(core: core, width: preset.width, height: preset.height,
                                            fovXDegrees: preset.fovXDegrees)
        else { return .failure(VideoEncoderError(description: "could not build the export renderer")) }

        let encoder: VideoEncoder
        do {
            encoder = try VideoEncoder(url: out, width: preset.width, height: preset.height,
                                       fps: preset.fps, codec: preset.codec, device: core.device)
        } catch {
            return .failure(error)
        }

        core.activate(.export)
        host.beginStepping()
        defer {
            // Put the engine back the way real-time play expects it. The
            // extra step lets the restores land on the engine thread before
            // the pacer resumes and the window re-asserts its drawable size.
            host.execute("host_framerate 0\nhost_maxfps 72\nchase_active 0\n")
            QC_RendererSetCullingFov(0, 0)
            QC_ExportSetBodyYaw(0, 0)
            QC_ExportSetViewOrigin(0, 0, 0, 0)
            QC_InputSetHeadOffset(0, 0, 0, 0)
            host.step(dt: 1.0 / 60)
            host.endStepping()
            core.activate(.window)
        }

        let subDt = preset.simStep / Double(preset.subSteps)
        // host_framerate fixes the sim step whatever dt we pass; host_maxfps
        // 1000 keeps Host_FilterTime from refusing sub-steps down to 1 ms
        // (the server is not running during playback, so its 72 fps physics
        // caveat does not apply). chase_active puts the player model into
        // the entity list for third-person cameras (and drops the hand
        // weapon, as upstream does).
        host.execute("disconnect\nphase 0\nvr_pathdebug 0\nhost_maxfps 1000\nhost_framerate \(subDt)\n"
                     + "chase_active \(camera.isThirdPerson ? 1 : 0)\n")
        QC_RendererSetDrawableSize(Int32(preset.width), Int32(preset.height))
        if camera.needsOmniCulling {
            QC_RendererSetCullingFov(360, 360)
        } else {
            QC_RendererSetCullingFov(0, 0)
        }
        host.step(dt: subDt)
        host.execute("playdemo \(demo)\n")

        // Wait for the demo to be up with world geometry.
        var lastSeq: UInt32 = 0
        var recenterCount: UInt32 = 0
        var warm = 0
        while true {
            guard host.step(dt: subDt) else {
                encoder.cancel()
                return .failure(VideoEncoderError(description: "engine stopped"))
            }
            let ready: Bool = core.withConsumer(.export) {
                guard let f = QC_RendererAcquireFrame() else { return false }
                defer { QC_RendererReleaseFrame() }
                lastSeq = f.pointee.frame_seq
                recenterCount = f.pointee.recenter_count
                return f.pointee.demo_playing != 0 && f.pointee.num_batches > 0
            } ?? false
            if ready { break }
            warm += 1
            if warm > 600 {
                encoder.cancel()
                return .failure(VideoEncoderError(description: "demo \"\(demo)\" never started (missing file?)"))
            }
            if cancelled.isSet {
                encoder.cancel()
                return .failure(VideoEncoderError(description: "cancelled"))
            }
        }
        // Disarm the boot-time demo loop so the demo's end disconnects
        // instead of chaining to demo2: a bare `startdemos` during playback
        // takes the else branch in Host_Startdemos_f and sets demonum = -1.
        host.execute("startdemos\n")

        var frames = 0
        var lastTime: Float = 0
        var ended = false
        var thirdPersonCam = ThirdPersonCamera()
        var lastStats = HudStats()
        var lastConchars: UInt32 = 0
        var lastPlayer = SIMD3<Float>(0, 0, 0)
        var lastCam = SIMD3<Float>(0, 0, 0)
        var csv = "frame,video_time,demo_time,health,armor,weapon,ammo,shells,nails,rockets,cells,"
            + "kills,total_monsters,secrets,total_secrets,player_x,player_y,player_z,player_yaw,cam_x,cam_y,cam_z\n"

        frameLoop: while !cancelled.isSet && !ended {
            let pixelBuffer: CVPixelBuffer
            let target: MTLTexture
            do { (pixelBuffer, target) = try encoder.nextFrame() } catch {
                encoder.cancel()
                return .failure(error)
            }
            guard let commandBuffer = core.commandQueue.makeCommandBuffer() else { break }
            var accumulated = 0

            for _ in 0..<preset.subSteps {
                if camera.drivesViewOrigin {
                    let want = thirdPersonCam.position(for: camera, demoTime: lastTime, dt: Float(subDt))
                    QC_ExportSetViewOrigin(1, want.x, want.y, want.z)
                }
                guard host.step(dt: subDt) else { break frameLoop }
                let got: Bool = core.withConsumer(.export) {
                    guard let f = QC_RendererAcquireFrame() else { return false }
                    defer { QC_RendererReleaseFrame() }
                    let p = f.pointee
                    if p.demo_playing == 0 { ended = true; return false }
                    // The demo's final step aborts before publishing (and a
                    // refused sub-step would too): the same packet comes
                    // back, so do not draw it twice.
                    guard p.frame_seq != lastSeq else { return false }
                    lastSeq = p.frame_seq
                    lastTime = p.time
                    lastPlayer = SIMD3(p.player_org.0, p.player_org.1, p.player_org.2)
                    lastCam = SIMD3(p.vieworg.0, p.vieworg.1, p.vieworg.2)
                    thirdPersonCam.observe(player: lastPlayer, yaw: p.player_angles.1, demoTime: p.time)
                    lastStats = HudStats(stats: withUnsafeBytes(of: p.stats) {
                        Array($0.bindMemory(to: Int32.self))
                    })
                    lastConchars = p.conchars_texnum
                    if let track = camera.track {
                        Self.feedInputs(track.sample(at: p.time), recenterAck: recenterCount)
                    }
                    let mipCandidates = core.drainTextureQueues()
                    if !mipCandidates.isEmpty, let blit = commandBuffer.makeBlitCommandEncoder() {
                        for texture in mipCandidates { blit.generateMipmaps(for: texture) }
                        blit.endEncoding()
                    }
                    renderer.accumulate(frame: p, camera: camera,
                                        weight: 1 / Float(preset.subSteps), commandBuffer: commandBuffer)
                    return true
                } ?? false
                if got { accumulated += 1 }
                if ended { break }
            }

            if accumulated == 0 {
                commandBuffer.commit()
                continue
            }
            let hud = preset.hud
                ? HudOverlay.build(stats: lastStats, width: preset.width, height: preset.height)
                : []
            renderer.resolve(into: target, hud: hud, atlasTexnum: lastConchars, commandBuffer: commandBuffer)
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            do { try encoder.append(pixelBuffer, frameIndex: frames) } catch {
                encoder.cancel()
                return .failure(error)
            }
            let st = lastStats
            csv += "\(frames),\(String(format: "%.4f", Double(frames) / Double(preset.fps))),\(lastTime),"
                + "\(st.health),\(st.armor),\(HudOverlay.weaponName(st.activeWeapon)),\(st.ammo),"
                + "\(st.shells),\(st.nails),\(st.rockets),\(st.cells),"
                + "\(st.kills),\(st.totalMonsters),\(st.secrets),\(st.totalSecrets),"
                + "\(lastPlayer.x),\(lastPlayer.y),\(lastPlayer.z),\(thirdPersonCam.lastYaw),"
                + "\(lastCam.x),\(lastCam.y),\(lastCam.z)\n"
            frames += 1
            if frames % 10 == 0 { progress(frames, lastTime) }
        }

        if cancelled.isSet, frames == 0 {
            encoder.cancel()
            return .failure(VideoEncoderError(description: "cancelled"))
        }
        do { try encoder.finish() } catch {
            return .failure(error)
        }
        guard frames > 0 else {
            return .failure(VideoEncoderError(description: "no frames were rendered"))
        }
        // Per-frame stats next to the movie, for overlays built in the editor.
        try? csv.write(to: out.deletingPathExtension().appendingPathExtension("csv"),
                       atomically: true, encoding: .utf8)
        return .success(out)
    }

    /// Head cams rebuild the hand weapon in its recorded frame: body yaw,
    /// hand aim, head offset and height trim exactly as the engine was fed.
    nonisolated private static func feedInputs(_ s: VRTrackSample, recenterAck: UInt32) {
        QC_ExportSetBodyYaw(1, s.bodyYaw)
        QC_InputSetAim(s.aimValid ? 1 : 0, s.aimOrigin.x, s.aimOrigin.y, s.aimOrigin.z, s.aimYaw, s.aimPitch)
        QC_InputSetHeadOffset(s.headOffset.x, s.headOffset.y, s.headOffset.z, recenterAck)
        QC_InputSetHeightTrim(s.heightTrim)
    }
}

/// Where Orbit and Front put the engine's viewpoint each sub-step. The
/// engine traces the request to the walls; the packet reports where the
/// camera ended up, and the renderer looks at the player from there.
struct ThirdPersonCamera {
    static let orbitRadius: Float = 150
    static let orbitHeight: Float = 40
    static let orbitPeriod: Float = 12      // seconds of demo time per turn
    static let frontDistance: Float = 120
    static let frontHeight: Float = 32
    static let frontYawTau: Float = 0.4     // the aim jitters; the hero shot must not

    private(set) var player = SIMD3<Float>(0, 0, 0)
    private(set) var lastYaw: Float = 0
    private var smoothYaw: Float?
    private var orbitStart: Float?
    private var orbitStartYaw: Float = 0

    mutating func observe(player: SIMD3<Float>, yaw: Float, demoTime: Float) {
        self.player = player
        lastYaw = yaw
        if orbitStart == nil { orbitStart = demoTime; orbitStartYaw = yaw }
    }

    mutating func position(for camera: ExportCamera, demoTime: Float, dt: Float) -> SIMD3<Float> {
        switch camera {
        case .orbit:
            // Start in front of the player and circle counter-clockwise.
            let t = demoTime - (orbitStart ?? demoTime)
            let theta = (orbitStartYaw + 180) * .pi / 180 + 2 * .pi * t / Self.orbitPeriod
            return player + SIMD3(cos(theta), sin(theta), 0) * Self.orbitRadius
                + SIMD3(0, 0, Self.orbitHeight)
        case .front:
            let target = lastYaw
            var yaw = smoothYaw ?? target
            let k = 1 - exp(-dt / Self.frontYawTau)
            yaw += VRTrack.wrapDegrees(target - yaw) * k
            smoothYaw = yaw
            let r = yaw * .pi / 180
            return player + SIMD3(cos(r), sin(r), 0) * Self.frontDistance
                + SIMD3(0, 0, Self.frontHeight)
        default:
            return player
        }
    }
}

/// Set from the main actor, read on the export thread.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func reset() { lock.lock(); value = false; lock.unlock() }
}
