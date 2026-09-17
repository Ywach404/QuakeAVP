//
//  VRSettings.swift
//
//  Comfort and handedness knobs the render thread and input sources read
//  without a round trip through the engine. Lock-guarded so the window
//  (main actor) can flip them while the render thread samples them.
//
//  Handedness is one switch consulted everywhere a hand has a role: the
//  dominant hand aims and works the wheel pointer / fire; the off hand
//  moves and anchors the wheel. Default right-dominant.
//

import Foundation

/// Aim-hand fire gesture. pinch = index->thumb (proven default); curl = index
/// flexes toward the palm (thumb-free trigger pull); hammer = the finger-gun
/// "bang" (index extended as the barrel, thumb drops from cocked to fire).
enum FireMode: Int, CaseIterable, Sendable { case pinch, curl, hammer }

/// Snap-turn style. stick = pinchless off-hand lateral displacement; clutch =
/// hold the aim-hand middle pinch and drag (Metroid Prime Hunters stylus feel);
/// flick = whip the gun hand. All accumulate into comfort snaps.
enum TurnStyle: Int, CaseIterable, Sendable { case stick, clutch, flick }

final class VRSettings: @unchecked Sendable {

    static let shared = VRSettings()

    private let lock = NSLock()
    private var _rightHanded = true
    /// Eye-height trim in metres, applied on top of the recenter baseline.
    /// Calibrated live from the Comfort menu because the right value is a
    /// matter of feel per player and posture -- floor detection proved
    /// unreliable, so this is the honest knob. Vertical head motion still
    /// tracks naturally on top of it (stand up and you rise).
    private var _heightOffset: Float = 0.4

    var rightHanded: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _rightHanded }
        set { lock.lock(); _rightHanded = newValue; lock.unlock() }
    }

    var heightOffset: Float {
        get { lock.lock(); defer { lock.unlock() }; return _heightOffset }
        set { lock.lock(); _heightOffset = newValue; lock.unlock() }
    }

    /// Swap which physical Sense controller is treated as left vs right.
    /// Chirality auto-detection is a vendor-name/connection-order guess that
    /// can land backwards; this is the honest override. Read live at slice
    /// build so toggling corrects the hands without reconnecting.
    /// NOT persisted: name detection ("(L)"/"(R)") is correct now, so this
    /// defaults OFF every launch. Persisting it inverted the correct detection
    /// from a stale ON set during the old coin-flip era.
    private var _swapSenseHands = false
    var swapSenseHands: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _swapSenseHands }
        set { lock.lock(); _swapSenseHands = newValue; lock.unlock() }
    }

    /// Weapon menu as a fixed gaze-selected panel (controllers) instead of the
    /// wrist ring. The engine owns the full-menu selection/commit; this flag
    /// just tells WheelState to stand down so it doesn't also fire.
    private var _fullMenu = false
    var fullMenu: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fullMenu }
        set { lock.lock(); _fullMenu = newValue; lock.unlock() }
    }

    /// Aim-hand fire gesture. Exactly one is live at a time so the gestures
    /// can't collide. See FireMode.
    private var _fireMode: FireMode = .pinch
    var fireMode: FireMode {
        get { lock.lock(); defer { lock.unlock() }; return _fireMode }
        set { lock.lock(); _fireMode = newValue; lock.unlock() }
    }

    /// Snap-turn style; default the pinchless off-hand stick.
    private var _turnStyle: TurnStyle = .stick
    var turnStyle: TurnStyle {
        get { lock.lock(); defer { lock.unlock() }; return _turnStyle }
        set { lock.lock(); _turnStyle = newValue; lock.unlock() }
    }

    /// Live gesture-tuning knobs (Comfort-menu sliders), read per input frame so
    /// the hand-input feel is dialable on device without a rebuild.

    /// One-pole aim low-pass: higher = snappier (less smoothing / more jitter).
    private var _aimSmooth: Float = 0.4
    var aimSmooth: Float {
        get { lock.lock(); defer { lock.unlock() }; return _aimSmooth }
        set { lock.lock(); _aimSmooth = newValue; lock.unlock() }
    }
    /// Aim blend: 0 = pure forearm bone (steady), 1 = pure knuckle-centroid
    /// (follows wrist flex but couples finger motion into the aim).
    private var _aimBlend: Float = 0.35
    var aimBlend: Float {
        get { lock.lock(); defer { lock.unlock() }; return _aimBlend }
        set { lock.lock(); _aimBlend = newValue; lock.unlock() }
    }
    /// Curl-fire sensitivity: index straightness at/below which the trigger
    /// pulls. Higher = fires on a lighter curl. (Open/release is +0.10.)
    private var _curlSensitivity: Float = 0.72
    var curlSensitivity: Float {
        get { lock.lock(); defer { lock.unlock() }; return _curlSensitivity }
        set { lock.lock(); _curlSensitivity = newValue; lock.unlock() }
    }
    /// Hammer drop angle (degrees): thumb-to-barrel angle at/below which the
    /// finger-gun hammer fires. Higher = fires on a shallower thumb drop.
    private var _hammerDropDeg: Float = 45
    var hammerDropDeg: Float {
        get { lock.lock(); defer { lock.unlock() }; return _hammerDropDeg }
        set { lock.lock(); _hammerDropDeg = newValue; lock.unlock() }
    }

    /// Print the aim-hand gesture signals to the console (~7 Hz) for tuning:
    /// straightness, thumb angle, aim validity, fire. Off by default.
    private var _inputLog = false
    var inputLog: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _inputLog }
        set { lock.lock(); _inputLog = newValue; lock.unlock() }
    }

    /// Gun-hand flick snap-turn ABSOLUTE floor, m/s of body-right wrist motion:
    /// the minimum whip speed that can ever trigger, below which motion is
    /// treated as tracking jitter. The live per-direction trigger auto-balances
    /// above this (see HandInput.flickFraction). Higher = fewer accidental
    /// turns. Tuned live from the Comfort menu against the on-hand turn gauge.
    private var _turnFlickSpeed: Float = 0.35
    var turnFlickSpeed: Float {
        get { lock.lock(); defer { lock.unlock() }; return _turnFlickSpeed }
        set { lock.lock(); _turnFlickSpeed = newValue; lock.unlock() }
    }

    /// True when `chirality` is the hand that aims / fires / points the
    /// wheel. The off hand moves and anchors the wheel.
    func isDominant(left: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _rightHanded ? !left : left
    }
}
