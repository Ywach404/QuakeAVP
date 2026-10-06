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
//  WHY THIS IS A PROBE, NOT A CLAIM
//  --------------------------------
//  Five device attempts have now failed to produce sound, four of them with the
//  shelf note's own warning unheeded: "prove a bare AVAudioEngine can play a
//  tone before trusting the full path." The most recent attempt started the
//  device at scene-active with an explicit AVAudioSession, and the app hung at
//  launch ("loading forever") with the last log line being "[audio] starting
//  device, attempt 1..." -- which prints immediately before setActive(). That
//  points hard at session activation, whose own history is "a synchronous XPC
//  call that never returns."
//
//  So this file no longer assumes anything. QAVP_AUDIO selects a mode, each
//  isolating ONE variable, and every sub-step logs BEFORE the call it is about
//  to make -- so the LAST line printed names the call that stalled, from a
//  single launch:
//
//    off      (default) SNDDMA_Init fails, the game boots silent. Known good.
//    session  ONLY AVAudioSession.setCategory + setActive, then idle. If the
//             app stalls, session activation is the culprit, full stop.
//    tone     AVAudioEngine + a 440 Hz sine, IMPLICIT session (no setActive).
//             If audible, the engine works at scene-active without touching the
//             session -- which is the real sink's path too.
//    on       The real sink: ring + render block, implicit session. Same engine
//             bring-up as `tone`; only `session` mode ever calls setActive.
//
//  The real sink deliberately does NOT call setActive: AVAudioEngine reaches a
//  session implicitly, and setActive is the one call with a proven hang. The
//  `session` mode exists only to confirm that is the right call to avoid.
//
//  The ring is allocated once and NEVER freed. close() is reachable only from
//  S_Shutdown at app teardown, so freeing it would mean proving the render
//  block has returned, which AVAudioEngine does not document for
//  AVAudioSourceNode. Leaking 32 KB on the way out beats a use-after-free on
//  the audio thread.
//

import AVFoundation

final class AudioSink: @unchecked Sendable {

    static let shared = AudioSink()

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

    /// QAVP_AUDIO selects the mode; default `off`.
    ///
    /// `off` is the default on purpose, and the hard lesson behind it: enabling
    /// the real sink (`on`) makes Quake's S_Init actually initialise and run its
    /// mixer on device for the FIRST time ever -- precache, codec init, and the
    /// per-frame S_Update -- and something in that path hangs the engine thread
    /// before it reaches the frame loop, so the immersive space never gets a
    /// frame and the app "loads forever." That is a SEPARATE bug from the -50
    /// AudioSession failure, and it must not hold the whole app hostage. So the
    /// default boots silent and loads, and audio is proven in stages:
    ///   tone     -> does AVAudioEngine make sound at all (session + engine)?
    ///   session  -> does setActive succeed, in isolation?
    ///   on       -> the real sink (only once tone works AND S_Init is fixed).
    /// The Debug-tab tone button runs `tone` on demand from this default launch.
    static let mode: Mode = {
        let raw = ProcessInfo.processInfo.environment["QAVP_AUDIO"]?
            .lowercased() ?? "off"
        return Mode(rawValue: raw) ?? .off
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

    /// Step trace. Printed BEFORE the call it names, so a silent log after a
    /// step line is that step hanging -- the whole point of the probe.
    private func step(_ s: String) { print("[audio] \(s)") }

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

        config = RenderConfig(buffer: buf, monoSamples: monoSamples,
                              channels: channels, bytesPerSample: bps,
                              cursor: cursor)
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
            kick { self.runEngine(tone: true, attempt: 1, maxAttempts: 5) }
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
            self.kick { self.runEngine(tone: false, attempt: 1, maxAttempts: 8) }
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

    private func runEngine(tone: Bool, attempt: Int, maxAttempts: Int) {
        let what = tone ? "tone" : "sink"
        step("\(what): attempt \(attempt)/\(maxAttempts)")

        // Session FIRST. The whole point of the fix.
        guard establishSession() else {
            step("\(what): session not ready on attempt \(attempt)")
            scheduleRetryOrGiveUp(tone: tone, attempt: attempt, maxAttempts: maxAttempts,
                                  why: "session -50")
            return
        }

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

        step("\(what): attach + connect to mainMixer...")
        newEngine.attach(srcNode)
        newEngine.connect(srcNode, to: newEngine.mainMixerNode, format: fmt)

        step("\(what): engine.start()...")
        do {
            try newEngine.start()
        } catch {
            step("\(what): start FAILED: \(error)")
            newEngine.detach(srcNode)
            scheduleRetryOrGiveUp(tone: tone, attempt: attempt, maxAttempts: maxAttempts,
                                  why: "start \(error)")
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
            cfg.buffer.withMemoryRebound(to: Int16.self,
                                         capacity: cfg.monoSamples) { ring in
                for (ch, out) in buffers.enumerated() {
                    guard let raw = out.mData else { continue }
                    let dst = raw.assumingMemoryBound(to: Float.self)
                    let maxFrames = min(frames, Int(out.mDataByteSize) / 4)
                    if ch < cfg.channels {
                        for i in 0..<maxFrames {
                            let idx = (pos + i * cfg.channels + ch) & mask
                            dst[i] = Float(ring[idx]) * scale
                        }
                    } else {
                        for i in 0..<maxFrames { dst[i] = 0 }
                    }
                }
            }
            cfg.cursor.pointee = Int32((pos + frames * cfg.channels) & mask)
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
        kick { self.runEngine(tone: true, attempt: 1, maxAttempts: 5) }
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
