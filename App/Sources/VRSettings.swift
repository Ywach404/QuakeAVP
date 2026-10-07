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

/// How the console window is summoned from inside the game. prayer = the
/// two-handed sign (default); palmUp = the original aim-hand palm-up dwell.
///
/// These are not equal choices. visionOS reserves the palm: palm toward your
/// face raises the Home View dot, palm away raises the status bar into Control
/// Center, and `persistentSystemOverlays(.hidden)` is only a preference the
/// system still overrides when the user looks and pinches. So palmUp competes
/// with the OS for the same pose and is kept only as a fallback. Prayer holds
/// both palms edge-on to the face, which the system makes no claim on.
enum SummonGesture: Int, CaseIterable, Sendable { case prayer, palmUp }

/// Which hand SELECTS on the weapon wheel, independent of which hand summons it.
/// offHand (default) = the hand that holds the wheel open also selects, the
/// original one-handed flow. dominant = the off hand holds it open while the
/// gun hand reaches to select (the two-handed feel the Sense controllers use).
/// Kept in dominant/off terms so it is correct for either handedness.
enum WheelSelectHand: Int, CaseIterable, Sendable { case offHand, dominant }

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

    /// Off-hand controller presence-model rotation offset, degrees, in the
    /// controller-local frame. The rigid hand is modelled reaching forward;
    /// these dial it to a handshake angle on device (hard to predict off the
    /// headset). Read on the render thread, so lock-guarded like the rest.
    private var _offHandPitch: Float = 0
    private var _offHandYaw: Float = 0
    private var _offHandRoll: Float = 0
    var offHandPitch: Float {
        get { lock.lock(); defer { lock.unlock() }; return _offHandPitch }
        set { lock.lock(); _offHandPitch = newValue; lock.unlock() }
    }
    var offHandYaw: Float {
        get { lock.lock(); defer { lock.unlock() }; return _offHandYaw }
        set { lock.lock(); _offHandYaw = newValue; lock.unlock() }
    }
    var offHandRoll: Float {
        get { lock.lock(); defer { lock.unlock() }; return _offHandRoll }
        set { lock.lock(); _offHandRoll = newValue; lock.unlock() }
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

    /// Which hand selects on the weapon wheel; default the summoning (off) hand,
    /// i.e. today's behaviour unchanged unless opted in.
    private var _wheelSelectHand: WheelSelectHand = .offHand
    var wheelSelectHand: WheelSelectHand {
        get { lock.lock(); defer { lock.unlock() }; return _wheelSelectHand }
        set { lock.lock(); _wheelSelectHand = newValue; lock.unlock() }
    }

    /// Live gesture-tuning knobs (Comfort-menu sliders), read per input frame so
    /// the hand-input feel is dialable on device without a rebuild.

    /// One-pole aim low-pass: higher = snappier (less smoothing / more jitter).
    private var _aimSmooth: Float = 0.4
    var aimSmooth: Float {
        get { lock.lock(); defer { lock.unlock() }; return _aimSmooth }
        set { lock.lock(); _aimSmooth = newValue; lock.unlock() }
    }

    /// Fingertip-to-thumb distance (METRES) at which a pinch closes. Release
    /// is this + 1.5 cm of hysteresis, so one knob sets both.
    ///
    /// This was hardcoded at 2.5 cm, which is "close but not touching" -- it
    /// fired before the fingers met. It was loosened to that on purpose once,
    /// because the middle-finger movement pinch kept dropping out, so tightening
    /// it trades false triggers for missed ones. That trade is the player's to
    /// make on device, which is why it is a slider now and not a constant.
    private var _pinchClose: Float = 0.015
    var pinchClose: Float {
        get { lock.lock(); defer { lock.unlock() }; return _pinchClose }
        set { lock.lock(); _pinchClose = newValue; lock.unlock() }
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

    /// Weapon-wheel ring plane trims (degrees off the body basis) and a scale
    /// on its radius. WheelState mirrors the three angles into its selection
    /// math; the engine reads the matching vr_wheel* cvars. Radius is safe to
    /// move alone -- selection is angle-only.
    private var _wheelPitch: Float = 0
    var wheelPitch: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wheelPitch }
        set { lock.lock(); _wheelPitch = newValue; lock.unlock() }
    }
    private var _wheelYaw: Float = 0
    var wheelYaw: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wheelYaw }
        set { lock.lock(); _wheelYaw = newValue; lock.unlock() }
    }
    private var _wheelRoll: Float = 0
    var wheelRoll: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wheelRoll }
        set { lock.lock(); _wheelRoll = newValue; lock.unlock() }
    }

    /// Console summon gesture; default the prayer sign. See SummonGesture for
    /// why palm-up is the compromised option rather than an equal one.
    private var _summonGesture: SummonGesture = .prayer
    var summonGesture: SummonGesture {
        get { lock.lock(); defer { lock.unlock() }; return _summonGesture }
        set { lock.lock(); _summonGesture = newValue; lock.unlock() }
    }

    /// Print the aim-hand gesture signals to the console (~7 Hz) for tuning:
    /// straightness, thumb angle, aim validity, fire. Off by default.
    private var _inputLog = false
    var inputLog: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _inputLog }
        set { lock.lock(); _inputLog = newValue; lock.unlock() }
    }

    /// Debug-HUD dock: where the on-arm meters sit. Offsets are metres in the
    /// forearm frame (Forward along the arm, Up out of it, Side across it);
    /// pitch/roll are degrees; faceMe blends 0 = rigidly arm-locked → 1 = fully
    /// eye-facing; scale sizes the panel. Read live by the meter builders.
    private var _hudForward: Float = 0
    var hudForward: Float { get { lock.lock(); defer { lock.unlock() }; return _hudForward }
                            set { lock.lock(); _hudForward = newValue; lock.unlock() } }
    private var _hudUp: Float = 0.14
    var hudUp: Float { get { lock.lock(); defer { lock.unlock() }; return _hudUp }
                       set { lock.lock(); _hudUp = newValue; lock.unlock() } }
    private var _hudSide: Float = 0
    var hudSide: Float { get { lock.lock(); defer { lock.unlock() }; return _hudSide }
                         set { lock.lock(); _hudSide = newValue; lock.unlock() } }
    private var _hudPitch: Float = 0
    var hudPitch: Float { get { lock.lock(); defer { lock.unlock() }; return _hudPitch }
                          set { lock.lock(); _hudPitch = newValue; lock.unlock() } }
    private var _hudRoll: Float = 0
    var hudRoll: Float { get { lock.lock(); defer { lock.unlock() }; return _hudRoll }
                         set { lock.lock(); _hudRoll = newValue; lock.unlock() } }
    private var _hudYaw: Float = 0
    var hudYaw: Float { get { lock.lock(); defer { lock.unlock() }; return _hudYaw }
                        set { lock.lock(); _hudYaw = newValue; lock.unlock() } }
    private var _hudFaceMe: Float = 0.8
    var hudFaceMe: Float { get { lock.lock(); defer { lock.unlock() }; return _hudFaceMe }
                           set { lock.lock(); _hudFaceMe = newValue; lock.unlock() } }
    private var _hudScale: Float = 1
    var hudScale: Float { get { lock.lock(); defer { lock.unlock() }; return _hudScale }
                          set { lock.lock(); _hudScale = newValue; lock.unlock() } }

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
