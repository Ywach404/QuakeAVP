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
        case off, session, tone, on
    }

    /// QAVP_AUDIO selects the mode; default off, so a launch with no scheme
    /// change loads the game silent exactly as the shelved build did. Audio is
    /// opt-in until a device launch proves which path works.
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

    /// Lifecycle gates, both under `lock`. The real device starts only once BOTH
    /// the ring exists (open ran) and the scene is active (sceneDidActivate ran).
    /// `started` latches so nothing kicks a second bring-up.
    private var sceneActive = false
    private var started = false

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

        guard Self.mode == .on else {
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

        if sceneActive { kickLocked() }
        else { step("ring ready (\(monoSamples) mono samples); waiting for scene-active") }
        return (buf, monoSamples)
    }

    // MARK: - Main actor (scene lifecycle)

    /// From QuakeAVPApp at scenePhase == .active -- the moment the session is
    /// reachable. Latches. For `on` it waits for the ring; the probes run
    /// straight away.
    func sceneDidActivate() {
        switch Self.mode {
        case .off:
            return
        case .session:
            kickOnce { self.runSessionProbe() }
        case .tone:
            kickOnce { self.runEngine(tone: true) }
        case .on:
            lock.lock()
            sceneActive = true
            if config != nil { kickLocked() }
            lock.unlock()
        }
    }

    /// Caller holds `lock`. Real-sink bring-up, once.
    private func kickLocked() {
        guard !started else { return }
        started = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runEngine(tone: false)
        }
    }

    /// Probe bring-up, once, off the main thread so a hang leaks a disposable
    /// thread rather than freezing the UI.
    private func kickOnce(_ body: @escaping () -> Void) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async(execute: body)
    }

    // MARK: - Session probe (isolates setActive)

    /// ONLY the audio session, so a stall here indicts setActive by itself. This
    /// is the one place setActive is called at all; the real sink never does.
    private func runSessionProbe() {
        let session = AVAudioSession.sharedInstance()
        step("session: setCategory(.playback)...")
        do {
            try session.setCategory(.playback, mode: .default, options: [])
        } catch {
            step("session: setCategory FAILED: \(error)"); return
        }
        step("session: setActive(true)...  (if the log stops here, THIS is the hang)")
        do {
            try session.setActive(true)
        } catch {
            step("session: setActive FAILED: \(error)"); return
        }
        step("session: ACTIVE and idle -- setActive returns fine here, so the "
            + "stall is elsewhere. Try QAVP_AUDIO=tone next.")
    }

    // MARK: - Engine bring-up (tone and real sink share this)

    private func runEngine(tone: Bool) {
        let what = tone ? "tone" : "sink"
        step("\(what): building engine (implicit session, no setActive)...")

        let rate = tone ? 48000.0 : Double(sampleRate)
        let channels: AVAudioChannelCount = tone ? 2 : AVAudioChannelCount(configChannels)
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate,
                                      channels: channels) else {
            step("\(what): no standard format at \(rate) Hz; giving up"); return
        }

        let newEngine = AVAudioEngine()
        let srcNode = tone ? makeToneNode(format: fmt) : makeSinkNode(format: fmt)
        guard let srcNode else { step("\(what): no render config; aborting"); return }

        step("\(what): attach + connect to mainMixer...  (this reaches the audio "
            + "graph; a stall here is the engine, not the session)")
        newEngine.attach(srcNode)
        newEngine.connect(srcNode, to: newEngine.mainMixerNode, format: fmt)

        step("\(what): engine.start()...  (if the log stops here, start() is the hang)")
        do {
            try newEngine.start()
        } catch {
            step("\(what): start FAILED cleanly: \(error)")
            newEngine.detach(srcNode)
            return
        }

        lock.lock()
        self.engine = newEngine
        self.node = srcNode
        if !tone { observeInterruptionsLocked() }
        lock.unlock()

        let real = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        if tone {
            step("tone: PLAYING 440 Hz at device \(Int(real)) Hz -- if you HEAR this, "
                + "the engine/lifecycle are good and the real sink will work too")
        } else {
            step("sink: device UP, \(Int(rate)) Hz requested / device \(Int(real)) Hz")
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
        if engine != nil { lock.unlock(); step("device already up; silence is the mixer, not the device"); return }
        guard !started else { lock.unlock(); step("a start is already in flight"); return }
        started = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.runEngine(tone: true)
        }
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
