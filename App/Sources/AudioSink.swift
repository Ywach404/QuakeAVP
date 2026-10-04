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
//  - The MAIN queue delivers audio-session interruptions.
//  - The AUDIO thread runs the render block, which is realtime.
//
//  The first two share `lock`. The render block takes NO lock and touches NO
//  property of this class: it captures an immutable RenderConfig by value, so
//  there is no `self`, no ARC traffic, and no optional loads on the realtime
//  path. A weak-self capture there would be a runtime side-table lock, which
//  is exactly what the realtime rule forbids -- and the failure is an audible
//  glitch rather than a crash, so it would be hard to find.
//
//  NOTE: this deliberately does NOT configure AVAudioSession. Both attempts
//  made things worse. From the engine thread it failed with OSStatus -50
//  "Session lookup failed"; moved to the main thread it failed the same way
//  AND blocked the UI -- setActive is a synchronous XPC call, and with the
//  session machinery erroring it never returned, so the app reported running
//  while nothing ever appeared on the device. AVAudioEngine creates a session
//  implicitly in any case (AURemoteIO reaches one either way). If a category
//  is genuinely needed, it must go through the ASYNCHRONOUS activate API, off
//  the launch path, and only after proving AVAudioEngine can make a sound in
//  this app at all.
//
//  The ring is allocated once and NEVER freed. close() is reachable only from
//  S_Shutdown at app teardown, so the lifetime question buys nothing; freeing
//  it would mean proving the render block has returned, which AVAudioEngine
//  does not document for AVAudioSourceNode.
//

import AVFoundation

final class AudioSink: @unchecked Sendable {

    static let shared = AudioSink()

    /// Everything the render block needs, by value. Immutable, so it can be
    /// captured once and read with no synchronisation at all.
    private struct RenderConfig {
        let buffer: UnsafeMutablePointer<UInt8>
        let monoSamples: Int
        let channels: Int
        let bytesPerSample: Int
        /// Play cursor in mono samples. The render block writes it, the engine
        /// thread reads it through QC_AudioSamplePos. A naturally-aligned
        /// 32-bit word: single loads and stores do not tear on arm64, which is
        /// all this needs -- there is no read-modify-write across threads.
        let cursor: UnsafeMutablePointer<Int32>
    }

    /// Guards the non-realtime paths only (engine thread + main queue). The
    /// render block never takes it.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private var config: RenderConfig?
    private var interruption: NSObjectProtocol?

    private init() {}

    /// Escape hatch, proven useful once: with this true the sink never runs
    /// and SNDDMA_Init fails cleanly (the old snd_null.c behaviour). The
    /// 2026-10-04 experiment: the app stalled at boot with the device starting
    /// inside SNDDMA_Init, and launched perfectly with this true ("[audio]
    /// sink disabled by kill switch" in the log, 120fps session after it).
    /// That is why open() below no longer starts the device at all.
    static let disabled = false

    /// Called on the ENGINE THREAD inside SNDDMA_Init, in the middle of
    /// Host_Init. Therefore it does nothing that can block: it allocates the
    /// ring and the cursor (pure memory) and hands them to Quake, then
    /// schedules the DEVICE to start later, asynchronously, on the main queue.
    ///
    /// Starting AVAudioEngine here hung the whole boot on device: the audio
    /// session machinery is not up that early (-50 "Session lookup failed"
    /// over XPC), and whatever start() blocks on, it blocks the engine thread
    /// and the game never finishes initialising. Until the device comes up the
    /// cursor simply never advances -- the mixer paints a little ahead and
    /// waits, which is silence, not a fault. If the device never comes up, the
    /// game plays on silently, which beats not playing.
    func open(speed: Int, channels: Int, bits: Int)
        -> (buffer: UnsafeMutablePointer<UInt8>, monoSamples: Int)? {

        if Self.disabled {
            print("[audio] sink disabled by kill switch; booting silent")
            return nil
        }

        lock.lock()
        defer { lock.unlock() }
        guard config == nil else { return nil }   // refuse a second ring

        // A fifth of a second, rounded DOWN to a power of two because
        // snd_mix.c masks with this.
        let target = speed * channels / 5
        var monoSamples = 1
        while monoSamples * 2 <= target { monoSamples *= 2 }
        guard AudioRing(monoSamples: monoSamples, channels: channels) != nil else {
            print("[audio] refusing a \(monoSamples)-sample ring (floor is "
                + "\(AudioRing.minimumMonoSamples)); check snd_mixspeed")
            return nil
        }

        let bps = bits / 8
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: monoSamples * bps)
        buf.initialize(repeating: 0, count: monoSamples * bps)
        let cursor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cursor.pointee = 0

        let cfg = RenderConfig(buffer: buf, monoSamples: monoSamples,
                               channels: channels, bytesPerSample: bps,
                               cursor: cursor)
        config = cfg
        sampleRate = speed

        DispatchQueue.main.async { [weak self] in self?.startDevice(attempt: 1) }
        return (buf, monoSamples)
    }

    /// Device-side sample rate requested by the engine; set once in open().
    private var sampleRate = 44100

    /// MAIN QUEUE, after launch. Builds and starts the device against the ring
    /// open() already handed to Quake. Uses the STANDARD format (deinterleaved
    /// float32) because that is the one format every AVAudioEngine graph
    /// accepts -- connect() raises an uncatchable ObjC exception on a format
    /// it dislikes, and int16-interleaved is exactly the kind it might. The
    /// render block converts from the int16 ring per sample; arithmetic only,
    /// still realtime-safe.
    ///
    /// Retries: the session machinery that fails at boot may simply need the
    /// app to finish coming up, so a refusal here is retried a few times
    /// rather than treated as final. Every attempt logs its outcome.
    private func startDevice(attempt: Int) {
        lock.lock()
        guard engine == nil, let cfg = config else { lock.unlock(); return }
        let rate = Double(sampleRate)
        lock.unlock()

        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate,
                                      channels: AVAudioChannelCount(cfg.channels)) else {
            print("[audio] no standard format at \(rate) Hz; giving up")
            return
        }

        let newEngine = AVAudioEngine()
        // Captures cfg BY VALUE. No self, no ARC, no locks on the render path.
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl in
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

        newEngine.attach(node)
        newEngine.connect(node, to: newEngine.mainMixerNode, format: fmt)
        do {
            try newEngine.start()
        } catch {
            newEngine.detach(node)
            if attempt < 5 {
                print("[audio] start attempt \(attempt) failed (\(error)); retrying in 5s")
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                    self?.startDevice(attempt: attempt + 1)
                }
            } else {
                print("[audio] giving up after \(attempt) attempts (\(error)); the game plays on silent")
            }
            return
        }

        lock.lock()
        self.engine = newEngine
        self.node = node
        observeInterruptionsLocked()
        lock.unlock()

        let real = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        print("[audio] device up on attempt \(attempt): float32 deinterleaved, "
            + "\(Int(rate)) Hz requested, device \(Int(real)) Hz, \(cfg.monoSamples) samples")
    }

    var samplePosition: Int {
        lock.lock(); defer { lock.unlock() }
        guard let cfg = config else { return 0 }
        return Int(cfg.cursor.pointee)
    }

    func setRunning(_ running: Bool) {
        lock.lock(); defer { lock.unlock() }
        guard let engine else { return }
        if running {
            do { try engine.start() } catch { print("[audio] resume failed: \(error)") }
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
                // Resume ONLY when the system grants it. Starting unasked throws,
                // and swallowing that throw is how a session goes permanently
                // silent -- the exact failure this observer exists to prevent.
                let opts = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map(AVAudioSession.InterruptionOptions.init(rawValue:)) ?? []
                if opts.contains(.shouldResume) {
                    self.setRunning(true)
                } else {
                    print("[audio] interruption ended without shouldResume; staying paused")
                }
            @unknown default:
                break
            }
        }
    }

    /// Stops the device. Deliberately does NOT free the ring or the cursor:
    /// close() is reachable only from S_Shutdown at app teardown, so the 8 KB
    /// is a process-lifetime allocation either way, and freeing it would mean
    /// proving the realtime block has returned -- which AVAudioEngine does not
    /// document for AVAudioSourceNode. Leaking it on the way out is strictly
    /// cheaper than a use-after-free on the audio thread.
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
