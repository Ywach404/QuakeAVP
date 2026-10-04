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

    /// Returns the ring and its size, or nil if the device would not start.
    func open(speed: Int, channels: Int, bits: Int)
        -> (buffer: UnsafeMutablePointer<UInt8>, monoSamples: Int)? {

        lock.lock()
        defer { lock.unlock() }
        // Not idempotent by design, but refuse rather than leak: a second open
        // would strand the first ring and leave two nodes racing one cursor.
        guard engine == nil else { return nil }

        // A fifth of a second, rounded DOWN to a power of two because
        // snd_mix.c masks with this.
        let target = speed * channels / 5
        var monoSamples = 1
        while monoSamples * 2 <= target { monoSamples *= 2 }
        guard let probe = AudioRing(monoSamples: monoSamples, channels: channels) else {
            print("[audio] refusing a \(monoSamples)-sample ring (floor is "
                + "\(AudioRing.minimumMonoSamples)); check sndspeed")
            return nil
        }

        let bps = bits / 8
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: monoSamples * bps)
        buf.initialize(repeating: 0, count: monoSamples * bps)
        let cursor = UnsafeMutablePointer<Int32>.allocate(capacity: 1)
        cursor.pointee = 0

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: Double(speed),
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: true) else {
            buf.deallocate(); cursor.deallocate()
            return nil
        }

        let cfg = RenderConfig(buffer: buf, monoSamples: probe.monoSamples,
                               channels: channels, bytesPerSample: bps, cursor: cursor)

        let engine = AVAudioEngine()
        // Captures cfg BY VALUE. No self, no ARC, no locks on this path.
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl in
            guard let out = UnsafeMutableAudioBufferListPointer(abl).first,
                  let dst = out.mData else { return noErr }

            let frames = Int(frameCount)
            // Clamp to what the output buffer actually holds as well as to what
            // we were asked for: if the negotiated layout is ever not the
            // int16-interleaved one we requested, writing our idea of the size
            // into it is loud garbage with no diagnostic.
            var wantBytes = frames * cfg.channels * cfg.bytesPerSample
            wantBytes = min(wantBytes, Int(out.mDataByteSize))
            let bps = cfg.bytesPerSample
            let wantSamples = wantBytes / bps

            let pos = Int(cfg.cursor.pointee)
            let mask = cfg.monoSamples - 1
            let firstCount = min(wantSamples, cfg.monoSamples - pos)
            memcpy(dst, cfg.buffer + pos * bps, firstCount * bps)
            let rest = wantSamples - firstCount
            if rest > 0 {
                memcpy(dst + firstCount * bps, cfg.buffer, rest * bps)
            }
            cfg.cursor.pointee = Int32((pos + wantSamples) & mask)
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        do {
            try engine.start()
        } catch {
            print("[audio] engine failed to start: \(error)")
            engine.detach(node)
            buf.deallocate(); cursor.deallocate()
            return nil
        }

        self.engine = engine
        self.node = node
        self.config = cfg
        observeInterruptionsLocked()

        // The device's real rate beside the one we asked for. The mixer node
        // converts between them, so a difference is expected rather than a
        // fault -- but a silent one would be indistinguishable from a bug.
        let real = engine.outputNode.outputFormat(forBus: 0).sampleRate
        print("[audio] \(bits) bit, \(channels == 2 ? "stereo" : "mono"), "
            + "\(speed) Hz requested, device \(Int(real)) Hz, \(monoSamples) samples")
        return (buf, monoSamples)
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
