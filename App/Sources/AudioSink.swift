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
//  path. A weak-self capture there would be a runtime side-table lock, which
//  is exactly what the realtime rule forbids -- and the failure is an audible
//  glitch rather than a crash, so it would be hard to find.
//
//  WHY THIS WAS SHELVED, AND WHAT CHANGED
//  --------------------------------------
//  Four device failures were recorded before this rewrite: session config on
//  the engine thread gave OSStatus -50 "Session lookup failed"; on main it gave
//  -50 and froze the UI (setActive is synchronous XPC); deferred to the main
//  queue it hung with no output; and a background-thread start crashed with
//  EXC_BAD_ACCESS at 0x10.
//
//  The crash was a publication bug -- the render block read self.config before
//  it was visible to the audio thread -- and the by-value RenderConfig capture
//  below is its fix. The other three were all ONE bug: the device was brought
//  up during Host_Init, which runs from the console window's onAppear at launch,
//  BEFORE visionOS has registered this app's audio session with mediaserverd.
//  "Session lookup failed / -50" is exactly what touching the session that
//  early looks like, and relying on AVAudioEngine's implicit session reached
//  the same unready machinery and wedged instead of erroring.
//
//  So the device no longer comes up from the engine's boot path at all. open()
//  (engine thread, inside SNDDMA_Init) only allocates the ring and returns;
//  QuakeAVPApp calls sceneDidActivate() when scenePhase first reaches .active,
//  and THAT is what starts the device -- with the audio session explicitly
//  configured (.playback, setActive) and the whole bring-up on a background
//  thread, so even a hard wedge leaks one thread and logs rather than freezing
//  the UI. A 10s watchdog says so out loud.
//
//  PROVE IT IN ISOLATION. Launch with QAVP_AUDIO_TONE=1 and the sink is bypassed
//  entirely for a 440 Hz sine straight out of AVAudioEngine. If you hear it, the
//  engine, the session and the lifecycle are all good and any remaining silence
//  is the mixer/ring, not the device. If you do NOT hear it, the log line after
//  "[audio] tone: starting" is the diagnosis. QAVP_AUDIO_OFF=1 forces the old
//  snd_null.c behaviour (boots silent, never touches the device).
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

    /// Forces the old snd_null.c behaviour: SNDDMA_Init fails cleanly and the
    /// game boots silent. The escape hatch, now an env var rather than a
    /// recompile -- the device path is the default again.
    static let disabled = ProcessInfo.processInfo.environment["QAVP_AUDIO_OFF"] == "1"

    /// Bypass the whole mixer for a bare 440 Hz sine out of AVAudioEngine, to
    /// prove the engine + session + lifecycle independently of Quake's ring.
    static let toneTest = ProcessInfo.processInfo.environment["QAVP_AUDIO_TONE"] == "1"

    /// Guards the non-realtime paths only (engine thread + main actor). The
    /// render block never takes it.
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    private var config: RenderConfig?
    private var interruption: NSObjectProtocol?
    private var sampleRate = 44100

    /// Lifecycle gates, both under `lock`. The device starts only once BOTH the
    /// ring exists (open() ran) and the scene is active (sceneDidActivate ran),
    /// in whichever order those happen. `deviceStarting` latches so the two
    /// triggers cannot both kick a bring-up.
    private var sceneActive = false
    private var deviceStarting = false

    private init() {}

    // MARK: - Engine thread (SNDDMA_Init)

    /// Called on the ENGINE THREAD inside SNDDMA_Init, in the middle of
    /// Host_Init. Does nothing that can block and nothing that touches the audio
    /// session: it allocates the ring and the cursor (pure memory) and hands
    /// them to Quake. The DEVICE is started later, from sceneDidActivate(), once
    /// visionOS has actually registered our session.
    ///
    /// Until the device comes up the cursor never advances -- the mixer paints a
    /// little ahead and waits, which is silence, not a fault. If the device
    /// never comes up at all, the game plays on silently, which beats not
    /// playing.
    func open(speed: Int, channels: Int, bits: Int)
        -> (buffer: UnsafeMutablePointer<UInt8>, monoSamples: Int)? {

        if Self.disabled {
            print("[audio] QAVP_AUDIO_OFF set; booting silent")
            return nil
        }
        if Self.toneTest {
            // The tone bypasses the ring entirely; refuse the sink so the mixer
            // runs in null mode and cannot fight the tone for the device.
            print("[audio] QAVP_AUDIO_TONE set; sink not opened, tone owns the device")
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

        config = RenderConfig(buffer: buf, monoSamples: monoSamples,
                              channels: channels, bytesPerSample: bps,
                              cursor: cursor)
        sampleRate = speed

        // open() may run AFTER the scene is already active (the engine boots a
        // beat into the window being up). If so, the scene-active trigger has
        // already fired and found no ring; start now. Otherwise sceneDidActivate
        // will start us.
        if sceneActive {
            kickBringUpLocked()
        } else {
            print("[audio] ring ready (\(monoSamples) mono samples); waiting for scene-active")
        }
        return (buf, monoSamples)
    }

    // MARK: - Main actor (scene lifecycle)

    /// Called from QuakeAVPApp when scenePhase first reaches .active. This is
    /// the moment the audio session is actually reachable -- the whole reason
    /// the device start moved here. Safe to call more than once; it latches.
    func sceneDidActivate() {
        if Self.disabled { return }
        lock.lock()
        sceneActive = true
        if Self.toneTest {
            let go = !deviceStarting
            if go { deviceStarting = true }
            lock.unlock()
            if go {
                DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                    self?.startTone()
                }
            }
            return
        }
        // Real sink: start only once the ring also exists.
        if config != nil {
            kickBringUpLocked()
        }
        lock.unlock()
    }

    /// Caller holds `lock`. Kicks the device bring-up on a background thread,
    /// once. A wedge inside AVAudioEngine leaks that thread and logs; main and
    /// the engine thread are never the ones that block.
    private func kickBringUpLocked() {
        guard !deviceStarting else { return }
        deviceStarting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startDevice(attempt: 1)
        }
    }

    // MARK: - Device bring-up (background thread)

    /// Set once an attempt completes (started or failed), read by the watchdog.
    /// Guarded by `lock`.
    private var startOutcome = "pending"

    /// Configure and activate the audio session. ON THE BACKGROUND THREAD: a
    /// -50 here used to come back only because the session was touched during
    /// Host_Init, before the app was registered; from scene-active it should
    /// succeed, and if it still wedges, it wedges a disposable thread. Returns
    /// false on a clean failure (caller retries); a wedge never returns at all
    /// and the watchdog reports it.
    private func configureSession() -> Bool {
        let session = AVAudioSession.sharedInstance()
        do {
            // .playback: a game owns its audio; it should play regardless of
            // other apps and route to the headset. Plain options -- no
            // mixWithOthers, the world should not duck to someone else's music.
            try session.setCategory(.playback, mode: .default, options: [])
            try session.setActive(true)
            return true
        } catch {
            print("[audio] session setup failed: \(error)")
            return false
        }
    }

    private func startDevice(attempt: Int) {
        lock.lock()
        guard engine == nil, let cfg = config else { lock.unlock(); return }
        let rate = Double(sampleRate)
        startOutcome = "pending"
        lock.unlock()

        // Printed BEFORE anything that can wedge, so a silent log after this
        // line is itself the diagnosis. The watchdog says so out loud: if the
        // attempt has not completed in 10s, the thread is gone.
        print("[audio] starting device, attempt \(attempt)...")
        armWatchdog(attempt: attempt)

        guard configureSession() else {
            lock.lock(); startOutcome = "failed"; lock.unlock()
            retryOrGiveUp(attempt: attempt, why: "session")
            return
        }

        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate,
                                      channels: AVAudioChannelCount(cfg.channels)) else {
            lock.lock(); startOutcome = "failed"; lock.unlock()
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
            lock.lock(); startOutcome = "failed"; lock.unlock()
            newEngine.detach(node)
            retryOrGiveUp(attempt: attempt, why: "start: \(error)")
            return
        }

        lock.lock()
        self.engine = newEngine
        self.node = node
        startOutcome = "started"
        observeInterruptionsLocked()
        lock.unlock()

        let real = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        print("[audio] device up on attempt \(attempt): float32 deinterleaved, "
            + "\(Int(rate)) Hz requested, device \(Int(real)) Hz, \(cfg.monoSamples) samples")
    }

    /// 10s watchdog. If the attempt has not reported started/failed, the thread
    /// is wedged inside AVAudioEngine/AVAudioSession and there is nothing to do
    /// but say so -- a retry would leak another thread into the same wall.
    private func armWatchdog(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self else { return }
            self.lock.lock(); let outcome = self.startOutcome; self.lock.unlock()
            if outcome == "pending" {
                print("[audio] attempt \(attempt) WEDGED inside AVAudioEngine/"
                    + "AVAudioSession after 10s; audio stays off, the game plays "
                    + "on. This is a platform/session problem, not a mixer one.")
            }
        }
    }

    private func retryOrGiveUp(attempt: Int, why: String) {
        if attempt < 3 {
            print("[audio] attempt \(attempt) failed cleanly (\(why)); retrying in 2s")
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 2) {
                [weak self] in self?.startDevice(attempt: attempt + 1)
            }
        } else {
            print("[audio] giving up after \(attempt) attempts (\(why)); "
                + "the game plays on silent")
        }
    }

    // MARK: - Tone self-test

    /// On-demand version of the tone, for a Debug-tab button -- so the device
    /// can be proven from a Home View launch, where env vars cannot be set and
    /// where the original -50/wedge failures actually happened. If the real
    /// device is already up, says so: then any silence is the mixer, not the
    /// device, and the tone would only fight it for the output.
    func requestToneTest() {
        if Self.disabled { print("[audio] QAVP_AUDIO_OFF set; tone refused"); return }
        lock.lock()
        if engine != nil {
            lock.unlock()
            print("[audio] device already running; if you hear nothing it is the "
                + "mixer/ring, not the device")
            return
        }
        guard !deviceStarting else { lock.unlock(); print("[audio] start already in flight"); return }
        deviceStarting = true
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.startTone()
        }
    }

    /// A bare 440 Hz sine straight out of AVAudioEngine, no ring, no mixer. If
    /// this is audible on device, the engine, the session and the lifecycle are
    /// all working and any remaining silence is upstream. Realtime block: a
    /// phase accumulator by value, nothing else.
    private func startTone() {
        print("[audio] tone: starting")
        armWatchdog(attempt: 0)
        lock.lock(); startOutcome = "pending"; lock.unlock()

        guard configureSession() else {
            lock.lock(); startOutcome = "failed"; lock.unlock()
            print("[audio] tone: session setup failed; cannot prove the engine")
            return
        }

        let rate = 48000.0
        guard let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else {
            print("[audio] tone: no format"); return
        }
        let newEngine = AVAudioEngine()
        let twoPiFOverRate = Float(2.0 * Double.pi * 440.0 / rate)
        let phase = UnsafeMutablePointer<Float>.allocate(capacity: 1)
        phase.pointee = 0
        let node = AVAudioSourceNode(format: fmt) { _, _, frameCount, abl in
            let buffers = UnsafeMutableAudioBufferListPointer(abl)
            var ph = phase.pointee
            let frames = Int(frameCount)
            for out in buffers {
                guard let raw = out.mData else { continue }
                let dst = raw.assumingMemoryBound(to: Float.self)
                let maxFrames = min(frames, Int(out.mDataByteSize) / 4)
                var local = ph
                for i in 0..<maxFrames {
                    dst[i] = sinf(local) * 0.2
                    local += twoPiFOverRate
                    if local > .pi { local -= 2 * .pi }
                }
            }
            ph += twoPiFOverRate * Float(frames)
            ph = ph.truncatingRemainder(dividingBy: 2 * .pi)
            phase.pointee = ph
            return noErr
        }
        newEngine.attach(node)
        newEngine.connect(node, to: newEngine.mainMixerNode, format: fmt)
        do {
            try newEngine.start()
        } catch {
            lock.lock(); startOutcome = "failed"; lock.unlock()
            print("[audio] tone: start failed (\(error))")
            return
        }
        lock.lock(); self.engine = newEngine; self.node = node
        startOutcome = "started"; lock.unlock()
        let real = newEngine.outputNode.outputFormat(forBus: 0).sampleRate
        print("[audio] tone: PLAYING 440 Hz at device \(Int(real)) Hz -- if you hear "
            + "this, the engine/session/lifecycle are all good")
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
    /// close() is reachable only from S_Shutdown at app teardown, so the memory
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
