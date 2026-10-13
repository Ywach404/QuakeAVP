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
// Hammer (thumb cock-and-drop) was removed -- unintuitive and finicky. Curl is
// kept: it feels good and suits a limited-control scheme (a Killer7-style mode).
enum FireMode: Int, CaseIterable, Sendable { case pinch, curl }

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

    /// Controllerless (hands) only: draw the 3D hand model on the OFF hand
    /// alone, leaving the gun hand as just the weapon -- mirrors how the PSVR
    /// controllers only model the off hand. Default on: a bare gun with no
    /// hand on it reads better in-headset than two hands clipping the model.
    private var _offHandModelOnly = true
    var offHandModelOnly: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _offHandModelOnly }
        set { lock.lock(); _offHandModelOnly = newValue; lock.unlock() }
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


    // MARK: - Wrist communicator

    /// Wrist-communicator placement dials: a tilt about the panel's own
    /// `right` axis (degrees, + leans the TOP toward you) and three offsets
    /// along its forward/right/up (metres). They re-seat the unit on the
    /// forearm, which is a per-player, per-posture matter of feel -- the same
    /// kind of knob `offHandPitch` above is, and declared the same way: a
    /// lock-guarded backing store, because the RENDER thread reads these
    /// every frame (`ImmersiveRenderer.updateWristComm`) while the window
    /// drags the slider on the main actor.
    ///
    /// They live here rather than in `vr_wristcomm_*` cvars on purpose. A
    /// cvar would mean a main-actor hop to write and an engine round trip to
    /// read back, and the value the renderer sampled would lag the slider by
    /// a frame or more -- the stale-read the enable-toggle fix already had to
    /// work around (see `WristCommStore.setEnabled`). Here the setter and the
    /// renderer's read are the same lock.
    ///
    /// Persisted directly to `UserDefaults` (NOT through `InputProfile`):
    /// these are a one-time physical fit of the unit to the player's arm, not
    /// part of a swappable control profile, and A. must not have to re-dial
    /// them after every launch.
    static let commTiltLimit: Float = 45        // degrees, either way
    static let commOffsetLimit: Float = 0.10    // metres, either way

    private static let commTiltKey = "wristCommTilt"
    private static let commFwdKey = "wristCommFwd"
    private static let commSideKey = "wristCommSide"
    private static let commUpKey = "wristCommUp"
    private static let commNoTurnKey = "wristCommNoTurn"

    private var _wristCommTilt: Float = 0
    private var _wristCommFwd: Float = 0
    private var _wristCommSide: Float = 0
    private var _wristCommUp: Float = 0
    /// Default TRUE: reaching across with the gun hand to press a key kept
    /// triggering that hand's own turn gesture, which is never what a reach
    /// for a key meant. Opt OUT from the Comfort menu.
    private var _wristCommNoTurn = true

    var wristCommTilt: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommTilt }
        set { store(Self.clamp(newValue, Self.commTiltLimit), Self.commTiltKey) { $0._wristCommTilt = $1 } }
    }
    var wristCommFwd: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommFwd }
        set { store(Self.clamp(newValue, Self.commOffsetLimit), Self.commFwdKey) { $0._wristCommFwd = $1 } }
    }
    var wristCommSide: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommSide }
        set { store(Self.clamp(newValue, Self.commOffsetLimit), Self.commSideKey) { $0._wristCommSide = $1 } }
    }
    var wristCommUp: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommUp }
        set { store(Self.clamp(newValue, Self.commOffsetLimit), Self.commUpKey) { $0._wristCommUp = $1 } }
    }
    var wristCommNoTurn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommNoTurn }
        set {
            lock.lock(); _wristCommNoTurn = newValue; lock.unlock()
            UserDefaults.standard.set(newValue, forKey: Self.commNoTurnKey)
        }
    }

    /// All four placement dials in one lock take, for the render thread: it
    /// needs them as a SET (they are applied together by
    /// `WristComm.adjustedFrame`), and reading them one property at a time
    /// would let a slider drag land between two of the reads and seat the
    /// unit at a placement no dial ever described.
    var wristCommPlacement: (tilt: Float, fwd: Float, side: Float, up: Float) {
        lock.lock(); defer { lock.unlock() }
        return (_wristCommTilt, _wristCommFwd, _wristCommSide, _wristCommUp)
    }

    /// Reset all four placement dials to zero in ONE lock take -- the write
    /// side of the same atomicity `wristCommPlacement` reads with: four
    /// separate setters would let the render thread's own single-lock read
    /// land between two of them and sample a torn placement for a frame.
    /// Persisted after the lock is released, same discipline as `store`.
    func resetWristCommPlacement() {
        lock.lock()
        _wristCommTilt = 0; _wristCommFwd = 0; _wristCommSide = 0; _wristCommUp = 0
        lock.unlock()
        let d = UserDefaults.standard
        d.set(Double(0), forKey: Self.commTiltKey)
        d.set(Double(0), forKey: Self.commFwdKey)
        d.set(Double(0), forKey: Self.commSideKey)
        d.set(Double(0), forKey: Self.commUpKey)
    }

    /// Clamped at the SETTER, not at the reader: a value out of range must
    /// never reach the store, so every reader (and the persisted default
    /// restored next launch) is in range by construction.
    private static func clamp(_ v: Float, _ limit: Float) -> Float {
        v.isFinite ? min(max(v, -limit), limit) : 0
    }

    /// Assign under the lock, persist outside it -- `UserDefaults` is its own
    /// synchronisation and has no business running inside a lock the render
    /// thread is waiting on.
    private func store(_ value: Float, _ key: String,
                       _ assign: (VRSettings, Float) -> Void) {
        lock.lock(); assign(self, value); lock.unlock()
        UserDefaults.standard.set(Double(value), forKey: key)
    }

    private init() {
        let d = UserDefaults.standard
        _wristCommTilt = Self.clamp(Float(d.double(forKey: Self.commTiltKey)), Self.commTiltLimit)
        _wristCommFwd = Self.clamp(Float(d.double(forKey: Self.commFwdKey)), Self.commOffsetLimit)
        _wristCommSide = Self.clamp(Float(d.double(forKey: Self.commSideKey)), Self.commOffsetLimit)
        _wristCommUp = Self.clamp(Float(d.double(forKey: Self.commUpKey)), Self.commOffsetLimit)
        // `bool(forKey:)` answers false for an absent key, which would invert
        // this flag's documented default on a fresh install -- hence the
        // explicit presence check (the same shape `AudioSink` uses for its
        // own default-on flag).
        _wristCommNoTurn = d.object(forKey: Self.commNoTurnKey) == nil
            ? true : d.bool(forKey: Self.commNoTurnKey)
    }

    /// True when `chirality` is the hand that aims / fires / points the
    /// wheel. The off hand moves and anchors the wheel.
    func isDominant(left: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _rightHanded ? !left : left
    }
}
