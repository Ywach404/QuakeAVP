//
//  AudioRing.swift
//
//  The dma_t ring's cursor arithmetic, kept pure so it can be tested without
//  an audio device -- this is where sinks usually break, and the failure is
//  audible rather than diagnosable.
//
//  Mono samples, not frames: shm->samples counts mono samples and
//  SNDDMA_GetDMAPos returns a mono sample position, so the whole type speaks
//  that unit and converts only at the frame boundary.
//

import Foundation

struct AudioRing {

    /// Total MONO samples in the ring. A power of two, because snd_mix.c uses
    /// it as a bitmask (`out_mask = shm->samples - 1`); a non-power-of-two
    /// corrupts audio silently rather than failing.
    let monoSamples: Int
    let channels: Int

    private(set) var samplePosition = 0

    /// snd_mix.c needs `shm->samples >> 1` to be a usable power of two too, so
    /// "a power of two" is not sufficient on its own: `sndspeed 4` drives the
    /// size to 1, which passes a bare power-of-two test and then makes
    /// S_TransferStereo16 compute `(shm->samples >> 1) - 1 == -1` and blast a
    /// negative count. One console typo away, so the floor is enforced here.
    static let minimumMonoSamples = 1024

    init?(monoSamples: Int, channels: Int) {
        guard monoSamples >= Self.minimumMonoSamples,
              monoSamples & (monoSamples - 1) == 0,
              channels == 1 || channels == 2 else { return nil }
        self.monoSamples = monoSamples
        self.channels = channels
    }

    /// Advance the play cursor by whole frames, wrapping.
    ///
    /// The cursor is monotonic MODULO the ring, so it does decrease across a
    /// lap -- and must: snd_dma.c's GetSoundtime detects a wrap by exactly
    /// that decrease. An earlier comment here claimed it never runs backwards,
    /// which was both false and the opposite of what the mixer needs.
    mutating func advance(frames: Int) {
        samplePosition = (samplePosition + frames * channels) & (monoSamples - 1)
    }

    /// Where `frames` of audio live, as up to two ranges of MONO sample
    /// offsets. The second is empty unless the read straddles the end, so the
    /// caller always does two memcpys and never a special case.
    /// Clamped to the ring's size: the caller memcpys these ranges straight
    /// out of an allocation of exactly `monoSamples`, so a request bigger than
    /// the ring must describe less audio, never more memory. Unclamped, a
    /// 4096-frame read on a 4096-sample ring described 8192 samples -- an
    /// 8000-byte heap overread on the realtime thread.
    func readOffsets(frames: Int) -> (first: Range<Int>, second: Range<Int>) {
        let want = min(max(frames, 0) * channels, monoSamples)
        let end = samplePosition + want
        if end <= monoSamples {
            return (samplePosition..<end, 0..<0)
        }
        return (samplePosition..<monoSamples, 0..<(end - monoSamples))
    }
}
