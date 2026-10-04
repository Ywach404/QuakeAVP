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

    init?(monoSamples: Int, channels: Int) {
        guard monoSamples > 0, monoSamples & (monoSamples - 1) == 0,
              channels == 1 || channels == 2 else { return nil }
        self.monoSamples = monoSamples
        self.channels = channels
    }

    /// Advance the play cursor by whole frames, wrapping. Never runs
    /// backwards: a cursor that does makes the mixer paint nothing.
    mutating func advance(frames: Int) {
        samplePosition = (samplePosition + frames * channels) & (monoSamples - 1)
    }

    /// Where `frames` of audio live, as up to two ranges of MONO sample
    /// offsets. The second is empty unless the read straddles the end, so the
    /// caller always does two memcpys and never a special case.
    func readOffsets(frames: Int) -> (first: Range<Int>, second: Range<Int>) {
        let want = frames * channels
        let end = samplePosition + want
        if end <= monoSamples {
            return (samplePosition..<end, 0..<0)
        }
        return (samplePosition..<monoSamples, 0..<(end - monoSamples))
    }
}
