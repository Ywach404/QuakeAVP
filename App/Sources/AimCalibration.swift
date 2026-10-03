//
//  AimCalibration.swift
//
//  "Sight in": point your arm where your head is facing, tap once, and both
//  aim trims are computed to cancel the difference. Replaces fishing with two
//  sliders -- the arm aim is THE aim, so calibrating it should be one action.
//
//  It works because the aim and the head are already expressed in the same
//  body-relative convention: yaw CCW/left-positive about room forward, pitch
//  positive-DOWN. The trim is then just head minus arm, averaged over a short
//  hold so hand tremor does not land in the result.
//
//  Calibrates against the HEAD, not the eyes: visionOS gives apps no gaze, for
//  privacy. Head-forward is the natural sighting posture anyway, but it does
//  mean "look straight at the thing you are pointing at", not "glance at it".
//
//  Samplers run on the render and hand-tracking threads; the window reads the
//  result on the main actor. Lock-guarded, no allocation in the feed path.
//

import Foundation

final class AimCalibration: @unchecked Sendable {

    static let shared = AimCalibration()

    /// A trim larger than this is not a resting-posture bias, it is a bug --
    /// most likely the head and the aim arriving in different frames. Refusing
    /// is much kinder than writing it: a bad trim makes the game unaimable and
    /// the only way back is finding the reset button while unable to aim at it.
    private static let sane: Float = 45

    private let lock = NSLock()
    private var headYaw: Float = 0
    private var headPitch: Float = 0
    private var headFresh = false
    private var sampling = false
    private var sumYaw: Float = 0
    private var sumPitch: Float = 0
    private var count = 0

    /// Called from the immersive render thread beside QC_InputSetHeadYaw/Pitch.
    func noteHead(yaw: Float, pitch: Float) {
        lock.lock()
        headYaw = yaw; headPitch = pitch; headFresh = true
        lock.unlock()
    }

    /// Called from TrackRecorder.feedAim, the single road into QC_InputSetAim,
    /// with the RAW angles -- before the engine adds vr_aimpitch/vr_aimyaw,
    /// which is exactly what the trims have to cancel.
    func noteAim(valid: Bool, yaw: Float, pitch: Float) {
        lock.lock(); defer { lock.unlock() }
        guard sampling, valid, headFresh else { return }
        sumYaw += headYaw - yaw
        sumPitch += headPitch - pitch
        count += 1
    }

    /// Start a hold. Head staleness is reset too, so leaving the immersive
    /// space mid-calibration cannot contribute a frozen pose.
    func begin() {
        lock.lock()
        sampling = true; sumYaw = 0; sumPitch = 0; count = 0; headFresh = false
        lock.unlock()
    }

    enum Result {
        case ok(yaw: Float, pitch: Float, samples: Int)
        /// Too few paired samples: not immersed, hand not tracked, or the hold
        /// was too short.
        case notEnoughData(samples: Int)
        /// Measured, but implausible. Carries the numbers so the log can say
        /// what it saw rather than just refusing.
        case implausible(yaw: Float, pitch: Float)
    }

    func finish(minimumSamples: Int = 10) -> Result {
        lock.lock(); defer { lock.unlock() }
        sampling = false
        guard count >= minimumSamples else { return .notEnoughData(samples: count) }
        let yaw = sumYaw / Float(count)
        let pitch = sumPitch / Float(count)
        guard abs(yaw) <= Self.sane, abs(pitch) <= Self.sane else {
            return .implausible(yaw: yaw, pitch: pitch)
        }
        return .ok(yaw: yaw, pitch: pitch, samples: count)
    }
}
