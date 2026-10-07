//
//  AudioSink.swift
//
//  The device half of Quake's sound: an AVAudioSourceNode whose render block
//  copies from the dma_t ring the engine's mixer writes into. Everything above
//  it -- channels, spatialisation, ambients, looping -- is upstream snd_dma.c
//  and snd_mix.c, untouched. Only the sink was ever missing.
//
//  THREE threads meet here and the split is deliberate:
//
//  - The ENGINE thread calls open/close/setRunning through the QC_Audio* shim.
//  - The MAIN actor delivers the scene-active signal and session interruptions.
//  - The AUDIO thread runs the render block, which is realtime.
//
//  The first two share `lock`. The render block takes NO lock and touches NO
//  property of this class: it captures an immutable RenderConfig by value, so
//  there is no `self`, no ARC traffic, and no optional loads on the realtime
//  path.
//
//  WHAT THE DEVICE LOGS PROVED (and the thread split that follows)
//  ---------------------------------------------------------------
//  Successive device runs ruled the suspects out one by one:
//   - setActive is NOT the problem. "session: ACTIVE ok" prints; it succeeds.
//   - The failure is AURemoteIO at `connect`: "-50 Creating proxy session
//     failed ... no reporter associated with ... session". AVAudioEngine's
//     output unit cannot register its session reporter.
//   - "no reporter" is a RUN-LOOP signature: the engine was being built on a
//     bare GCD global queue, which has no run loop for CoreAudio to attach its
//     property listeners to.
//
//  So the split is: the SESSION work (setCategory + setActive) runs on a
//  background thread -- proven safe and successful there -- and the ENGINE
//  bring-up (attach/connect/start) is handed to the MAIN thread, which has a
//  run loop. See runEngine -> buildEngineOnMain.
//
//  A separate bug lives upstream in Quake itself: SNDDMA_Init returning true
//  makes S_Init run its precache/codec/mixer on device for the first time ever,
//  and something there hangs boot. QAVP_AUDIO=ring isolates it (ring + mixer,
//  no device). That is why `on` is not the default yet.
//
//  QAVP_AUDIO selects a mode, each isolating one variable, every sub-step logged
//  before its call so the last line printed names any hang:
//    off      (default) SNDDMA_Init fails, boots silent. Known good.
//    ring     ring + mixer, NO device. Isolates the Quake-side boot hang.
//    session  setCategory + setActive only. (Confirmed: succeeds.)
//    tone     session (bg) + AVAudioEngine 440 Hz (main). Bug-2 test.
//    on       the real sink: ring + device, engine on main.
//
//  The ring is allocated once and NEVER freed. close() is reachable only from
//  S_Shutdown at app teardown, so freeing it would mean proving the render
//  block has returned, which AVAudioEngine does not document for
//  AVAudioSourceNode. Leaking 32 KB on the way out beats a use-after-free on
//  the audio thread.
//

import AVFoundation
import os

final class AudioSink: @unchecked Sendable {

    static let shared = AudioSink()

    /// os_log so the audio trace is visible in Console.app on the Mac from the
    /// device with NO debugger attached -- which matters, because the next test
    /// is a Home View launch with Xcode detached (print() is invisible then).
    private static let log = Logger(subsystem: "com.acervantez.quakeavp", category: "audio")

    enum Mode: String {
        /// off     no ring; SNDDMA_Init fails; game boots silent. Default.
        /// ring    ring allocated so Quake's mixer runs, but NO device/session
        ///         is ever brought up. Isolates bug 1 (does Quake's sound path
        ///         itself hang on device?) from bug 2 (the -50 session failure).
        ///         If the app LOADS in ring mode, the mixer is fine and the hang
        ///         is the AVAudioEngine bring-up; if it HANGS, the hang is in
        ///         S_Init/precache/S_Update, nothing to do with AVAudioSession.
        /// session setActive only, in isolation.
        /// tone    AVAudioEngine + 440 Hz, session established first. Bug 2 test.
        /// on      the real sink: ring + device. Only once ring and tone both pass.
        case off, ring, session, tone, on
    }

    /// QAVP_AUDIO selects the mode; default `on` -- audio is the shipping path.
    ///
    /// The whole saga resolved to ONE cause: running under the Xcode debugger.
    /// lldb ptracing the process disrupted the audio XPC (and the compositor
    /// XPC), which produced the "-50 Creating proxy session failed" at connect
    /// AND, almost certainly, the "loads forever" boot hang -- the latter being
    /// the immersive layer's XPC stalling, not Quake's S_Init. Launched normally
    /// from the Home View, with no debugger attached, AVAudioEngine comes up and
    /// plays. So `on` is correct as the default, and it MUST be the default,
    /// because env vars only reach launches started FROM Xcode -- a Home View
    /// launch never sees QAVP_AUDIO, so the shipping path cannot be opt-in.
    ///
    /// The env var still overrides from Xcode, which is the recovery hatch: if a
    /// Home View launch ever misbehaves, run once from Xcode with QAVP_AUDIO=off
    /// (loads clean -- off needs no audio session) and flip the Debug "Game
    /// audio" toggle, which persists and wins on the next Home View launch.
    static let mode: Mode = {
        if let raw = ProcessInfo.processInfo.environment["QAVP_AUDIO"]?.lowercased(),
           let m = Mode(rawValue: raw) {
            return m                          // Xcode override wins
        }
        // Persisted Debug toggle. Default OFF so the app ALWAYS loads -- audio
        // on by default was shipped before the full sink path was ever confirmed
        // to boot on device, and under the debugger (or if the sound init really
        // does hang) that is a non-loading app with no in-app way back. Opt in
        // with the "Game audio (next launch)" toggle, then relaunch DETACHED.
        // UserDefaults because env vars never reach a Home View launch.
        if UserDefaults.standard.object(forKey: "audioEnabled") != nil {
            return UserDefaults.standard.bool(forKey: "audioEnabled") ? .on : .off
        }
        return .off
    }()

    /// Everything the render block needs, by value. Immutable, so it can be
    /// captured once and read with no synchronisation at all.
    private struct RenderConfig {
        let buffer: UnsafeMutablePointer<UInt8>
        let monoSamples: Int
        let channels: Int
        let bytesPerSample: Int
        /// Play cursor in mono samples. The render block writes it, the engine
        /// thread reads it through QC_AudioSamplePos. A naturally-aligned 32-bit
        /// word: single loads and stores do not tear on arm64, which is all this
        /// needs -- there is no read-modify-write across threads.
        let cursor: UnsafeMutablePointer<Int32>
        /// Diagnostics, written by the render block, read by a timer. The tone
        /// works but the sink is silent, so the question is whether the ring the
        /// mixer fills actually has audio in it. `calls` counts callbacks (is the
        /// device pulling?), `peak` is the largest |int16| seen since last reset
        /// (is the ring non-zero, i.e. is Quake painting?).
        let calls: UnsafeMutablePointer<Int32>
        let peak: UnsafeMutablePointer<Int32>
    }

    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private var config: RenderConfig?
    private var interruption: NSObjectProtocol?
    private var sampleRate = 44100

    /// Lifecycle gates, all under `lock`. `sceneActive` and the ring both gate
    /// the real sink's auto-start. `inFlight` latches during a bring-up attempt
    /// and `engineRunning` once one succeeds -- but a FAILED attempt clears
    /// `inFlight`, so the Debug button (and the `on` retry) can try again
    /// rather than wedging on a one-shot latch. The -50 proxy-session failure
    /// came back on the FIRST attempt; a retriable latch is how we learn
    /// whether it is transient.
    private var sceneActive = false
    private var inFlight = false
    private var engineRunning = false

    private init() {}

    /// Wired by ContentView to the in-headset console (engine.note), so the
    /// audio trace is readable IN THE HEADSET on a debugger-detached Home View
    /// launch -- no Mac, no Console.app. That is what finally makes the detached
    /// test practical.
    nonisolated(unsafe) var onLog: (@Sendable (String) -> Void)?

    /// Step trace, to three places: print (Xcode), os_log (Console.app, even
    /// detached), and the in-headset console (readable with no Mac at all).
    /// Printed BEFORE the call it names, so a silent log after a step line is
    /// that step hanging.
    private func step(_ s: String) {
        print("[audio] \(s)")
        Self.log.notice("[audio] \(s, privacy: .public)")
        onLog?("[audio] \(s)")
    }

    // MARK: - Engine thread (SNDDMA_Init)

    /// ENGINE THREAD, inside SNDDMA_Init. Allocates the ring for `on` mode and
    /// returns; never touches the device or the session. Every other mode
    /// returns nil so SNDDMA_Init fails and the mixer stays idle -- no ring to
    /// fight the tone/session probe for the output.
    func open(speed: Int, channels: Int, bits: Int)
        -> (buffer: UnsafeMutablePointer<UInt8>, monoSamples: Int)? {

        // Only `on` and `ring` allocate the ring (so Quake's mixer runs). `ring`
        // then never brings up a device, which is the whole point of the probe.
        guard Self.mode == .on || Self.mode == .ring else {
            step("mode=\(Self.mode.rawValue); SNDDMA_Init declines (no ring)")
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        guard config == nil else { return nil }

        // A fifth of a second, rounded DOWN to a power of two: snd_mix.c masks
        // with this.
        let target = speed * channels / 5
        var monoSamples = 1
        while monoSamples * 2 <= target { monoSamples *= 2 }
        guard AudioRing(monoSamples: monoSamples, channels: channels) != nil else {
            step("refusing a \(monoSamples)-sample ring (floor "
                + "\(AudioRing.minimumMonoSamples)); check snd_mixspeed")
            return nil
        }

        let bps = bits / 8
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: monoSamples * bps)
        buf.initialize(repeating: 0, count: monoSamples * bps)
        let cursor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cursor.pointee = 0
        let calls = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        calls.pointee = 0
        let peak = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        peak.pointee = 0

        config = RenderConfig(buffer: buf, monoSamples: monoSamples,
                              channels: channels, bytesPerSample: bps,
                              cursor: cursor, calls: calls, peak: peak)
        sampleRate = speed

        // Only `on` auto-starts a device; `ring` allocates the buffer and stops
        // there. If the scene already went active before the ring existed, start
        // now (same settle delay); otherwise sceneDidActivate drives it.
        if Self.mode == .on && sceneActive {
            scheduleRealStart(afterSeconds: 2)
        } else {
            step("ring ready (\(monoSamples) mono samples)"
                + (Self.mode == .on ? "; waiting for scene-active" : "; ring mode, no device"))
        }
        return (buf, monoSamples)
    }

    // MARK: - Main actor (scene lifecycle)

    /// From QuakeAVPApp at scenePhase == .active. For `on` it waits for the ring
    /// and then brings the device up with retries; the probes run straight away.
    func sceneDidActivate() {
        switch Self.mode {
        case .off:
            return
        case .ring:
            // Ring is live and the mixer runs; deliberately bring up NO device.
            step("ring mode: mixer active, no device -- if the app loaded, the "
                + "Quake sound path is fine and the hang is the AVAudioEngine "
                + "bring-up")
            return
        case .session:
            kick { self.runSessionProbe() }
        case .tone:
            kick { self.runEngine(tone: true, attempt: 1, maxAttempts: 2) }
        case .on:
            lock.lock()
            sceneActive = true
            let go = config != nil
            lock.unlock()
            // Delay the first real attempt past the launch handshake: audio ops
            // DURING it hung before, audio ops when settled fail fast. 2s is
            // well clear -- the log reaches 120fps within the first second.
            if go { scheduleRealStart(afterSeconds: 2) }
        }
    }

    /// Start the real sink after a settle delay, once.
    private func scheduleRealStart(afterSeconds: Double) {
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + afterSeconds) {
            [weak self] in
            guard let self else { return }
            self.kick { self.runEngine(tone: false, attempt: 1, maxAttempts: 3) }
        }
    }

    /// Claim an attempt. Returns false if one is in flight or an engine is
    /// already running. Off the main thread so a hang leaks a disposable thread.
    private func kick(_ body: @escaping () -> Void) {
        lock.lock()
        guard !inFlight, !engineRunning else { lock.unlock(); return }
        inFlight = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async(execute: body)
    }

    private func finishAttempt(running: Bool) {
        lock.lock(); inFlight = false; engineRunning = running; lock.unlock()
    }

    // MARK: - Session (now established FIRST, explicitly)

    /// The fix the device log forced: AVAudioEngine's AURemoteIO cannot create
    /// its proxy session implicitly in this app ("-50 Session lookup failed"
    /// at connect time, even fully up and rendering). So establish the session
    /// ourselves, before the engine, and the engine finds it instead of trying
    /// to make one. setActive's old -50 was a boot-timing artefact; this runs
    /// well after launch. Returns false on a clean failure (caller retries).
    private func establishSession() -> Bool {
        let s = AVAudioSession.sharedInstance()
        step("session: setCategory(.playback)...")
        do {
            try s.setCategory(.playback, mode: .default, options: [])
        } catch {
            step("session: setCategory FAILED: \(error)"); return false
        }
        step("session: setActive(true)...")
        do {
            try s.setActive(true)
        } catch {
            step("session: setActive FAILED: \(error)"); return false
        }
        step("session: ACTIVE ok")
        return true
    }

    // MARK: - Session-only probe

    private func runSessionProbe() {
        if establishSession() {
            step("session: established and idle; the -50 is NOT the session itself")
        } else {
            step("session: could NOT be established -- this is the -50 at its source")
        }
        finishAttempt(running: false)
    }

    // MARK: - Engine bring-up (tone and real sink share this)

    /// Runs on a BACKGROUND thread (session work is proven safe there and
    /// setActive succeeds). The ENGINE bring-up is then handed to the MAIN
    /// thread, because that is where the fix lives: AURemoteIO failed with
    /// "-50 ... no reporter associated with ... session" at connect, which is
    /// the signature of an audio unit registering property listeners on a
    /// thread with no run loop. A GCD global queue has none; the main thread
    /// does. So: session off-main, engine on-main.
    private func runEngine(tone: Bool, attempt: Int, maxAttempts: Int) {
        let what = tone ? "tone" : "sink"
        step("\(what): attempt \(attempt)/\(maxAttempts)")

        guard establishSession() else {
            step("\(what): session not ready on attempt \(attempt)")
            scheduleRetryOrGiveUp(tone: tone, attempt: attempt, maxAttempts: maxAttempts,
                                  why: "session -50")
            return
        }

        DispatchQueue.main.async { [weak self] in
            self?.buildEngineOnMain(tone: tone, attempt: attempt, maxAttempts: maxAttempts)
        }
    }

    /// MAIN THREAD. Builds, connects and starts the engine where AURemoteIO has
    /// a run loop to attach its session reporter to. The prior -50 came from
    /// doing exactly this on a run-loop-less background queue.
    private func buildEngineOnMain(tone: Bool, attempt: Int, maxAttempts: Int) {
        let what = tone ? "tone" : "sink"
        let rate = tone ? 48000.0 : Double(sampleRate)
        let channels: AVAudioChannelCount = tone ? 2 : AVAudioChannelCount(configChannels)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate,
                                      channels: channels) else {
            step("\(what): no standard format at \(rate) Hz; giving up")
            finishAttempt(running: false); return
        }

        let newEngine = AVAudioEngine()
        let srcNode = tone ? makeToneNode(format: fmt) : makeSinkNode(format: fmt)
        guard let srcNode else {
            step("\(what): no render config; aborting"); finishAttempt(running: false); return
        }

        step("\(what): [main] attach + connect to mainMixer...")
        // connect raises an ObjC NSException (not a Swift error) when AURemoteIO
        // has failed its session -- that is the "kills the app" crash. Catch it.
        var exReason: NSString?
        let connected = QAVPTry({
            newEngine.attach(srcNode)
            newEngine.connect(srcNode, to: newEngine.mainMixerNode, format: fmt)
        }, &exReason)
        guard connected else {
            let r = (exReason as String?) ?? "unknown"
            step("\(what): connect RAISED [\(r)] -- caught; this is the AURemoteIO "
                + "-50, the app survives it now")
            scheduleRetryOrGiveUp(tone: tone, attempt: attempt, maxAttempts: maxAttempts,
                                  why: "connect exception")
            return
        }

        step("\(what): [main] engine.start()...")
        var startError: Error?
        let startedOk = QAVPTry({
            do { try newEngine.start() } catch { startError = error }
        }, nil)
        if !startedOk || startError != nil {
            let r = startError.map { "\($0)" } ?? "ObjC exception"
            step("\(what): start FAILED [\(r)]")
            QAVPTry({ newEngine.detach(srcNode) }, nil)
            scheduleRetryOrGiveUp(tone: tone, attempt: attempt, maxAttempts: maxAttempts,
                                  why: "start failed")
            return
        }

        lock.lock()
        self.engine = newEngine
        self.node = srcNode
        if !tone { observeInterruptionsLocked() }
        lock.unlock()
        finishAttempt(running: true)

        let real = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        if tone {
            step("tone: PLAYING 440 Hz at device \(Int(real)) Hz -- if you HEAR this, "
                + "the engine works and the real sink (QAVP_AUDIO=on) will too")
        } else {
            step("sink: device UP, \(Int(rate)) Hz requested / device \(Int(real)) Hz")
            startDiagTimer()
        }
    }

    /// Reports the render-block diagnostics every 2s, so a detached launch can
    /// show whether the device is pulling (`calls`) and whether the ring the
    /// mixer fills actually has audio (`peak`). Reads are racy against the
    /// realtime writes, which is fine for a coarse health indicator.
    private func startDiagTimer() {
        DispatchQueue.main.async { [weak self] in
            let timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                self.lock.lock()
                guard let cfg = self.config, self.engineRunning else { self.lock.unlock(); t.invalidate(); return }
                let calls = cfg.calls.pointee
                let peak = cfg.peak.pointee
                let pos = cfg.cursor.pointee
                cfg.calls.pointee = 0
                cfg.peak.pointee = 0
                self.lock.unlock()
                self.step("diag: \(calls) callbacks/2s, ring peak \(peak)/32767, cursor \(pos) "
                    + "-- peak 0 = mixer is not filling the ring; peak>0 + silence = output")
            }
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    /// Clears the in-flight latch and, if attempts remain, schedules another a
    /// second later. The -50 may be the session server not yet ready for this
    /// process even past launch; a few spaced retries cost nothing and tell us
    /// whether it is transient or permanent.
    private func scheduleRetryOrGiveUp(tone: Bool, attempt: Int, maxAttempts: Int, why: String) {
        finishAttempt(running: false)
        guard attempt < maxAttempts else {
            step("\((tone ? "tone" : "sink")): gave up after \(attempt) attempts (\(why)); "
                + "if every one was -50, the session server is refusing this app a "
                + "session -- not an in-process fix")
            return
        }
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            [weak self] in
            guard let self else { return }
            self.kick { self.runEngine(tone: tone, attempt: attempt + 1,
                                       maxAttempts: maxAttempts) }
        }
    }

    private var configChannels: Int {
        lock.lock(); defer { lock.unlock() }
        return config?.channels ?? 2
    }

    /// The real sink's render block. Captures RenderConfig by value.
    private func makeSinkNode(format: AVAudioFormat) -> AVAudioSourceNode? {
        lock.lock(); let maybe = config; lock.unlock()
        guard let cfg = maybe else { return nil }
        return AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            let pos = Int(cfg.cursor.pointee)
            let mask = cfg.monoSamples - 1
            let scale = Float(1.0 / 32768.0)
            var localPeak: Int32 = 0
            cfg.buffer.withMemoryRebound(to: Int16.self,
                                         capacity: cfg.monoSamples) { ring in
                for (ch, out) in buffers.enumerated() {
                    guard let raw = out.mData else { continue }
                    let dst = raw.assumingMemoryBound(to: Float.self)
                    let maxFrames = min(frames, Int(out.mDataByteSize) / 4)
                    if ch < cfg.channels {
                        for i in 0..<maxFrames {
                            let idx = (pos + i * cfg.channels + ch) & mask
                            let s = ring[idx]
                            let a = Int32(s < 0 ? -Int32(s) : Int32(s))
                            if a > localPeak { localPeak = a }
                            dst[i] = Float(s) * scale
                        }
                    } else {
                        for i in 0..<maxFrames { dst[i] = 0 }
                    }
                }
            }
            cfg.cursor.pointee = Int32((pos + frames * cfg.channels) & mask)
            cfg.calls.pointee = cfg.calls.pointee &+ 1
            if localPeak > cfg.peak.pointee { cfg.peak.pointee = localPeak }
            return noErr
        }
    }

    /// The tone's render block. A phase accumulator by value, nothing else.
    private func makeToneNode(format: AVAudioFormat) -> AVAudioSourceNode {
        let rate = format.sampleRate
        let inc = Float(2.0 * Double.pi * 440.0 / rate)
        let phase = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        phase.pointee = 0
        return AVAudioSourceNode(format: format) { _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            let frames = Int(frameCount)
            for out in buffers {
                guard let raw = out.mData else { continue }
                let dst = raw.assumingMemoryBound(to: Float.self)
                let maxFrames = min(frames, Int(out.mDataByteSize) / 4)
                var local = phase.pointee
                for i in 0..<maxFrames {
                    dst[i] = sinf(local) * 0.2
                    local += inc
                    if local > .pi { local -= 2 * .pi }
                }
            }
            phase.pointee = (phase.pointee + inc * Float(frames))
                .truncatingRemainder(dividingBy: 2 * .pi)
            return noErr
        }
    }

    // MARK: - On-demand tone (Debug button, any launch where the app loaded)

    /// Runs the tone probe on demand, so the device can be proven from a Home
    /// View launch where env vars cannot be set. Only meaningful when the app
    /// actually loaded, i.e. with QAVP_AUDIO unset/off.
    func requestToneTest() {
        lock.lock()
        if engineRunning { lock.unlock(); step("device already up; silence is the mixer, not the device"); return }
        lock.unlock()
        // kick() guards inFlight; a prior FAILED attempt has cleared it, so a
        // second press genuinely retries rather than printing "already in flight".
        kick { self.runEngine(tone: true, attempt: 1, maxAttempts: 2) }
    }

    // MARK: - Engine thread / interruptions

    var samplePosition: Int {
        lock.lock(); defer { lock.unlock() }
        guard let cfg = config else { return 0 }
        return Int(cfg.cursor.pointee)
    }

    func setRunning(_ running: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let engine else { return }
        if running {
            do { try engine.start() } catch { step("resume failed: \(error)") }
        } else {
            engine.pause()
        }
    }

    /// Caller holds `lock`.
    private func observeInterruptionsLocked() {
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began:
                self.setRunning(false)
            case .ended:
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                if opts.contains(.shouldResume) { self.setRunning(true) }
                else { self.step("interruption ended without shouldResume; staying paused") }
            @unknown default:
                break
            }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        if let interruption {
            NotificationCenter.default.removeObserver(interruption)
            self.interruption = nil
        }
        engine?.stop()
        if let node, let engine { engine.detach(node) }
        node = nil
        engine = nil
        // config, and the memory it points at, are intentionally retained.
    }
}

// MARK: - C shim

@_cdecl("QC_AudioOpen")
public func QC_AudioOpen(_ speed: Int32, _ channels: Int32, _ bits: Int32,
                         _ buffer: UnsafeMutablePointer<UnsafeMutablePointer<UInt8>?>?,
                         _ monoSamples: UnsafeMutablePointer<Int32>?) -> Int32 {
    guard let got = AudioSink.shared.open(speed: Int(speed), channels: Int(channels),
                                          bits: Int(bits)) else { return 0 }
    buffer?.pointee = got.buffer
    monoSamples?.pointee = Int32(got.monoSamples)
    return 1
}

@_cdecl("QC_AudioSamplePos")
public func QC_AudioSamplePos() -> Int32 { Int32(AudioSink.shared.samplePosition) }

@_cdecl("QC_AudioClose")
public func QC_AudioClose() { AudioSink.shared.close() }

@_cdecl("QC_AudioSetRunning")
public func QC_AudioSetRunning(_ running: Int32) {
    AudioSink.shared.setRunning(running != 0)
}
