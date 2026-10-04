//
//  AudioSink.swift
//
//  The device half of Quake's sound: an AVAudioSourceNode whose render block
//  copies from the dma_t ring the engine's mixer writes into. Everything above
//  it -- channels, spatialisation, ambients, looping -- is upstream snd_dma.c
//  and snd_mix.c, untouched. Only the sink was ever missing.
//
//  The render block runs on a realtime audio thread. It may touch ONLY the
//  ring and the cursor: no locks, no allocation, no engine calls. Anything
//  else is an audible glitch rather than a crash, which is worse to diagnose.
//

import AVFoundation

final class AudioSink: @unchecked Sendable {

    static let shared = AudioSink()

    private var engine: AVAudioEngine?
    private var node: AVAudioSourceNode?
    /// The ring Quake mixes into. Raw memory handed to C, freed only in
    /// close() once the node has stopped.
    private var buffer: UnsafeMutablePointer<UInt8>?
    private var ring: AudioRing?
    private var channels = 2
    private var bytesPerSample = 2
    private var interruption: NSObjectProtocol?

    private init() {}

    /// Returns the ring and its size, or nil if the device would not start.
    func open(speed: Int, channels: Int, bits: Int)
        -> (buffer: UnsafeMutablePointer<UInt8>, monoSamples: Int)? {

        // A fifth of a second, rounded DOWN to a power of two because
        // snd_mix.c masks with this. Big enough to ride a frame hitch, small
        // enough that a sound does not lag visibly behind its muzzle flash --
        // very obvious in VR.
        let target = speed * channels / 5
        var monoSamples = 1
        while monoSamples * 2 <= target { monoSamples *= 2 }
        guard let ring = AudioRing(monoSamples: monoSamples, channels: channels) else { return nil }

        let bps = bits / 8
        let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: monoSamples * bps)
        buf.initialize(repeating: 0, count: monoSamples * bps)

        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                      sampleRate: Double(speed),
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: true) else {
            buf.deallocate()
            return nil
        }

        let engine = AVAudioEngine()
        let node = AVAudioSourceNode(format: fmt) { [weak self] _, _, frameCount, abl in
            guard let self,
                  let out = UnsafeMutableAudioBufferListPointer(abl).first,
                  let dst = out.mData else { return noErr }
            self.render(into: dst, frames: Int(frameCount))
            return noErr
        }

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: fmt)
        do {
            try engine.start()
        } catch {
            print("[audio] engine failed to start: \(error)")
            engine.detach(node)
            buf.deallocate()
            return nil
        }

        self.engine = engine
        self.node = node
        self.buffer = buf
        self.ring = ring
        self.channels = channels
        self.bytesPerSample = bps
        observeInterruptions()

        // Report the rate the device ACTUALLY runs at next to the one we asked
        // for: a silent mismatch plays the whole game at the wrong pitch, and
        // nothing else would ever say so.
        let real = engine.outputNode.outputFormat(forBus: 0).sampleRate
        print("[audio] \(bits) bit, \(channels == 2 ? "stereo" : "mono"), "
            + "\(speed) Hz requested, device \(Int(real)) Hz, \(monoSamples) samples")
        return (buf, monoSamples)
    }

    /// REALTIME THREAD. Two memcpys and a cursor bump, nothing else.
    private func render(into dst: UnsafeMutableRawPointer, frames: Int) {
        guard let src = buffer, var r = ring else {
            // Starved or closed: silence, never stale samples -- a looping
            // stale buffer reads as a stuck buzz rather than as nothing.
            memset(dst, 0, frames * channels * bytesPerSample)
            return
        }
        let (a, b) = r.readOffsets(frames: frames)
        let bps = bytesPerSample
        memcpy(dst, src + a.lowerBound * bps, a.count * bps)
        if !b.isEmpty {
            memcpy(dst + a.count * bps, src + b.lowerBound * bps, b.count * bps)
        }
        r.advance(frames: frames)
        ring = r
    }

    var samplePosition: Int { ring?.samplePosition ?? 0 }

    func setRunning(_ running: Bool) {
        guard let engine else { return }
        if running { try? engine.start() } else { engine.pause() }
    }

    /// A call, Control Center, or the space tearing down can stop the engine
    /// underneath us. Without this the mixer keeps painting into a ring nobody
    /// reads and the game goes permanently silent, with no error anywhere.
    private func observeInterruptions() {
        guard interruption == nil else { return }
        interruption = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self,
                  let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
            switch type {
            case .began: self.engine?.pause()
            case .ended: try? self.engine?.start()
            @unknown default: break
            }
        }
    }

    /// Stop the node BEFORE freeing the ring: releasing memory a realtime
    /// thread is mid-copy of is a crash, not a glitch.
    func close() {
        if let interruption {
            NotificationCenter.default.removeObserver(interruption)
            self.interruption = nil
        }
        engine?.stop()
        if let node, let engine { engine.detach(node) }
        node = nil
        engine = nil
        ring = nil
        buffer?.deallocate()
        buffer = nil
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
