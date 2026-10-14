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
    /// The in-plane Rotate dial's range: a full turn either way, because the
    /// angle that reads right on a forearm is not near any particular one and
    /// -90 is a legitimate answer (it is the mapping that shipped first).
    static let commRotLimit: Float = 180
    /// The ALONG view's rotation default: 0, because
    /// `WristComm.alongBaseFrame` already lays the key run along the arm's
    /// apparent direction, cell 0 at the elbow end. The dial does not pick a
    /// FACE of the forearm any more -- that was the flat-to-skin
    /// construction's job for `rot`, and it is retired along with it. The
    /// panel billboards at the eye, so Rotate is an IN-PLANE spin
    /// of the key run, the same thing it means in the across view. Zero is
    /// the derived reading direction -- the key run laid along the arm's
    /// apparent direction, cell 0 at the elbow end -- and the dial is there
    /// for the few tens of degrees of skew between that and however the
    /// player wants to read it, not for a quarter or half turn.
    ///
    /// It has been 0 through two constructions and for two different
    /// reasons, which is why the keys below are versioned rather than
    /// reused: under the flat-to-skin panel 0 meant "the inner face", and a
    /// stored 90 meant "stood on the arm's edge". Under this one 90 means
    /// "the key run across the arm instead of along it". Same number, three
    /// different placements.
    static let commRotAlongDefault: Float = 0
    /// The ALONG view's Height default, in metres. One centimetre, and it
    /// still means "just off the arm toward you" -- but by a different axis
    /// than it used to: Height now runs along the billboarded panel's
    /// `forward`, which points AT THE EYE, rather than out of the forearm's
    /// skin. Over a forearm glanced at from above the two are close enough
    /// that the number carries over unchanged: enough clearance that the
    /// unit reads as sitting ON the arm rather than sunk into it, small
    /// enough that it still reads as worn rather than floating.
    ///
    /// IT IS CLEARANCE, NOT DECORATION, which is why it is the one along
    /// dial with a non-zero default and why `resolveCommPlacement` permutes
    /// it onto the right axis explicitly. At 0 the panel's plane -- the
    /// plane the touch test projects against -- lies on the bone, several
    /// centimetres inside the arm, and a fingertip stopped by the skin can
    /// be outside `WristComm.touchDepth` (0.025 m) altogether: the keys
    /// light and do not fire. The other four along dials default to 0 --
    /// seated under the HUD, centred, untilted, key run along the arm.
    static let commUpAlongDefault: Float = 0.01

    // TWO SETS OF THE SAME FIVE DIALS, one per orientation view. On device
    // the two layouts want genuinely different seatings -- the across-wrist
    // unit sits on the back of the wrist, the along-arm one runs down a
    // forearm that is not square to it -- and sharing one set meant dialling
    // the height for one view dragged the other out of place ("changing
    // height shouldn't effect the other way to view"). So each view owns its
    // own {tilt, fwd, side, up, rot}.
    //
    // THE EXISTING KEYS ARE THE ACROSS SET, unrenamed: A.'s current tuning is
    // stored under them and must survive this change untouched, so there is
    // no migration to get wrong. The along set's keys and defaults are
    // documented at the versioned block below, where they actually live now.
    private static let commTiltKey = "wristCommTilt"
    private static let commFwdKey = "wristCommFwd"
    private static let commSideKey = "wristCommSide"
    private static let commUpKey = "wristCommUp"
    private static let commRotKey = "wristCommRotAcross"
    // THE ALONG KEYS ARE VERSIONED, and `...3` is the SECOND one-way bump,
    // for the same reason the first was: the along view's five dials changed
    // meaning again, so a stored number describes a placement that no longer
    // exists.
    //
    //   `...` (unversioned) -> `...2`: the view went from a billboarded
    //     panel to one strapped flat on the forearm. Rotate became a roll
    //     AROUND THE ARM, the offsets moved into the arm's axes.
    //   `...2` -> `...3`: the panel keeps its forearm ANCHOR but billboards
    //     its face at the eye again. Rotate is an in-plane spin once more
    //     (so a stored roll of 90, which used to pick a FACE of the arm, now
    //     stands the key run across it), the offsets ride the billboarded
    //     panel's axes rather than the bone's, and Height is "toward you"
    //     rather than "off the skin". A. tuned the `...2` values against the
    //     flat panel; carried over, they would mis-place this one and read
    //     as the fix not working.
    //
    // New keys mean the new view starts from its own documented defaults;
    // the superseded keys are simply left behind, unread and harmless. The
    // ACROSS keys above are untouched through both bumps, because that view
    // has not changed.
    private static let commTiltAlongKey = "wristCommTiltAlong3"
    private static let commFwdAlongKey = "wristCommFwdAlong3"
    private static let commSideAlongKey = "wristCommSideAlong3"
    private static let commUpAlongKey = "wristCommUpAlong3"
    private static let commRotAlongKey = "wristCommRotAlong3"
    private static let commNoTurnKey = "wristCommNoTurn"
    private static let commAlongArmKey = "wristCommAlongArm"

    private var _wristCommTilt: Float = 0
    private var _wristCommFwd: Float = 0
    private var _wristCommSide: Float = 0
    private var _wristCommUp: Float = 0
    private var _wristCommRot: Float = 0
    private var _wristCommTiltAlong: Float = 0
    private var _wristCommFwdAlong: Float = 0
    private var _wristCommSideAlong: Float = 0
    private var _wristCommUpAlong: Float = VRSettings.commUpAlongDefault
    private var _wristCommRotAlong: Float = VRSettings.commRotAlongDefault
    /// Default TRUE: reaching across with the gun hand to press a key kept
    /// triggering that hand's own turn gesture, which is never what a reach
    /// for a key meant. Opt OUT from the Comfort menu.
    private var _wristCommNoTurn = true
    /// Which way the unit is turned on the forearm: false (the default) is
    /// ACROSS the wrist, the layout already tuned on device; true lays it
    /// ALONG the arm, three keys down the forearm. Default false is the
    /// zero-state the whole option is built around -- off, the placement
    /// chain is the identity and the unit is bit-for-bit today's.
    private var _wristCommAlongArm = false

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
    /// The ACROSS view's in-plane rotation, degrees about the panel normal.
    var wristCommRot: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommRot }
        set { store(Self.clamp(newValue, Self.commRotLimit), Self.commRotKey) { $0._wristCommRot = $1 } }
    }

    // The ALONG view's own five. Same shape, same clamps, separate storage --
    // the settings window binds the meter rows to one set or the other by the
    // `wristCommAlongArm` toggle, so a dial only ever moves the view it is
    // shown in.
    var wristCommTiltAlong: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommTiltAlong }
        set { store(Self.clamp(newValue, Self.commTiltLimit), Self.commTiltAlongKey) { $0._wristCommTiltAlong = $1 } }
    }
    var wristCommFwdAlong: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommFwdAlong }
        set { store(Self.clamp(newValue, Self.commOffsetLimit), Self.commFwdAlongKey) { $0._wristCommFwdAlong = $1 } }
    }
    var wristCommSideAlong: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommSideAlong }
        set { store(Self.clamp(newValue, Self.commOffsetLimit), Self.commSideAlongKey) { $0._wristCommSideAlong = $1 } }
    }
    var wristCommUpAlong: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommUpAlong }
        set { store(Self.clamp(newValue, Self.commOffsetLimit), Self.commUpAlongKey) { $0._wristCommUpAlong = $1 } }
    }
    var wristCommRotAlong: Float {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommRotAlong }
        set { store(Self.clamp(newValue, Self.commRotLimit), Self.commRotAlongKey) { $0._wristCommRotAlong = $1 } }
    }
    var wristCommNoTurn: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommNoTurn }
        set {
            lock.lock(); _wristCommNoTurn = newValue; lock.unlock()
            UserDefaults.standard.set(newValue, forKey: Self.commNoTurnKey)
        }
    }
    /// Which of the two placement sets is live. The render thread no longer
    /// reads this directly: it is the SELECTOR inside `wristCommPlacement`,
    /// so the choice of set and the five values that set holds come out of
    /// one lock take and cannot disagree. Flipping the toggle therefore
    /// swaps the whole placement atomically -- never one view's rotation
    /// against the other view's offsets for a frame.
    ///
    /// Still lock-guarded and still persisted here (the window writes it on
    /// the main actor while the renderer reads it inside that same lock).
    var wristCommAlongArm: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _wristCommAlongArm }
        set {
            lock.lock(); _wristCommAlongArm = newValue; lock.unlock()
            UserDefaults.standard.set(newValue, forKey: Self.commAlongArmKey)
        }
    }

    /// The ACTIVE view's five placement dials in ONE lock take, for the
    /// render thread: it needs them as a SET (applied together, in
    /// `ImmersiveRenderer.resolveCommPlacement` -- across via
    /// `WristComm.orientedFrame` + `WristComm.commOrigin` +
    /// `WristComm.adjustedFrame`, along via `WristComm.alongBaseFrame` +
    /// `WristComm.orientedFrame` + `WristComm.alongSeatDistance` +
    /// `WristComm.adjustedFrame`), and reading them one property at a time
    /// would let a slider drag land between two of the reads and seat the
    /// unit at a placement no dial ever described.
    ///
    /// `rot` joined the tuple rather than being read beside it for exactly
    /// that reason: it now drives BOTH the frame's rotation and the seating
    /// drop, so a rot sampled apart from the offsets would mean a frame
    /// turned to one angle and seated for another -- the unit visibly
    /// jumping off the HUD for a frame mid-drag.
    ///
    /// The view selector is read inside the same take (see
    /// `wristCommAlongArm`), so a toggle landing mid-read can never hand
    /// back one view's rotation with the other view's offsets.
    ///
    /// It is also RETURNED, not just consulted. Since the along view became
    /// forearm-locked, the selector picks the renderer's POSE SOURCE as well
    /// as its dials -- a billboarded wrist plane or the arm itself -- and a
    /// selector sampled in a second lock take could pair one view's source
    /// with the other view's numbers for a frame, which is a panel visibly
    /// jumping off the arm mid-toggle.
    var wristCommPlacement: (alongArm: Bool, tilt: Float, fwd: Float,
                             side: Float, up: Float, rot: Float) {
        lock.lock(); defer { lock.unlock() }
        return _wristCommAlongArm
            ? (true, _wristCommTiltAlong, _wristCommFwdAlong, _wristCommSideAlong,
               _wristCommUpAlong, _wristCommRotAlong)
            : (false, _wristCommTilt, _wristCommFwd, _wristCommSide,
               _wristCommUp, _wristCommRot)
    }

    /// Reset the ACTIVE view's five placement dials to that VIEW'S DEFAULTS
    /// in ONE lock take -- the write side of the same atomicity
    /// `wristCommPlacement` reads with: five separate setters would let the
    /// render thread's own single-lock read land between two of them and
    /// sample a torn placement for a frame.
    ///
    /// Per-view, and defaults rather than zeros: the along view's Height
    /// default is 1 cm TOWARD YOU, off the arm, so resetting it to 0 would
    /// leave the panel's plane on the bone -- inside the forearm, where a
    /// fingertip stopped by the skin never reaches `WristComm.touchDepth`.
    /// Resetting one view deliberately leaves the other view's tuning alone
    /// -- that separation is the whole point of the two sets.
    ///
    /// Reads its numbers from `wristCommDefaults`, which the settings
    /// window's Reset button also mirrors into its sliders: ONE statement
    /// of what a reset produces, so the UI and the store cannot disagree.
    ///
    /// Persisted after the lock is released, same discipline as `store`.
    func resetWristCommPlacement() {
        lock.lock()
        let along = _wristCommAlongArm
        let d0 = Self.wristCommDefaults(alongArm: along)
        if along {
            _wristCommTiltAlong = d0.tilt; _wristCommFwdAlong = d0.fwd
            _wristCommSideAlong = d0.side; _wristCommUpAlong = d0.up
            _wristCommRotAlong = d0.rot
        } else {
            _wristCommTilt = d0.tilt; _wristCommFwd = d0.fwd
            _wristCommSide = d0.side; _wristCommUp = d0.up
            _wristCommRot = d0.rot
        }
        lock.unlock()
        let d = UserDefaults.standard
        d.set(Double(d0.tilt), forKey: along ? Self.commTiltAlongKey : Self.commTiltKey)
        d.set(Double(d0.fwd), forKey: along ? Self.commFwdAlongKey : Self.commFwdKey)
        d.set(Double(d0.side), forKey: along ? Self.commSideAlongKey : Self.commSideKey)
        d.set(Double(d0.up), forKey: along ? Self.commUpAlongKey : Self.commUpKey)
        d.set(Double(d0.rot), forKey: along ? Self.commRotAlongKey : Self.commRotKey)
    }

    /// The per-view defaults the window's Reset button mirrors into its own
    /// slider state, and the same ones `resetWristCommPlacement` writes --
    /// one statement, two readers.
    ///
    /// The along view's one non-zero default is a forearm fact, not taste:
    /// Height lifts the unit 1 cm off the arm toward you
    /// (`commUpAlongDefault`). Rotate is 0 because the base frame already
    /// lays the key run along the arm (`commRotAlongDefault`). Forward 0 is
    /// the DERIVED SEAT -- `WristComm.alongSeatDistance` down the arm from
    /// the wrist joint, just clear of the HUD grid billboarded there -- not
    /// a point on the bone, so the dial slides from a clearance rather than
    /// from the forearm midpoint.
    static func wristCommDefaults(alongArm: Bool)
        -> (tilt: Float, fwd: Float, side: Float, up: Float, rot: Float) {
        alongArm ? (0, 0, 0, commUpAlongDefault, commRotAlongDefault) : (0, 0, 0, 0, 0)
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
        _wristCommRot = Self.clamp(Float(d.double(forKey: Self.commRotKey)), Self.commRotLimit)
        _wristCommTiltAlong = Self.clamp(Float(d.double(forKey: Self.commTiltAlongKey)), Self.commTiltLimit)
        _wristCommFwdAlong = Self.clamp(Float(d.double(forKey: Self.commFwdAlongKey)), Self.commOffsetLimit)
        _wristCommSideAlong = Self.clamp(Float(d.double(forKey: Self.commSideAlongKey)), Self.commOffsetLimit)
        // Presence-checked, unlike the dials above it: this one's documented
        // default is +1 cm toward you, not 0, and `double(forKey:)` answers
        // 0 for an absent key -- which would sink the unit into the forearm
        // on first launch after the update. That absent key is the NORMAL
        // case on the launch after a version bump, not an edge case.
        _wristCommUpAlong = d.object(forKey: Self.commUpAlongKey) == nil
            ? Self.commUpAlongDefault
            : Self.clamp(Float(d.double(forKey: Self.commUpAlongKey)), Self.commOffsetLimit)
        // Presence-checked too, although this view's default is 0 and a plain
        // read would answer 0 anyway. Kept explicit because the default is
        // the documented on-device lever for this view's reading direction
        // (see `commRotAlongDefault`): the day it moves off 0, this line must
        // already be the one that honours it.
        _wristCommRotAlong = d.object(forKey: Self.commRotAlongKey) == nil
            ? Self.commRotAlongDefault
            : Self.clamp(Float(d.double(forKey: Self.commRotAlongKey)), Self.commRotLimit)
        // `bool(forKey:)` answers false for an absent key, which would invert
        // this flag's documented default on a fresh install -- hence the
        // explicit presence check (the same shape `AudioSink` uses for its
        // own default-on flag).
        _wristCommNoTurn = d.object(forKey: Self.commNoTurnKey) == nil
            ? true : d.bool(forKey: Self.commNoTurnKey)
        // No presence check needed on this one, unlike the flag above: its
        // documented default IS false, which is exactly what `bool(forKey:)`
        // answers for an absent key -- so a fresh install restores the
        // across-the-wrist layout by the plain read.
        _wristCommAlongArm = d.bool(forKey: Self.commAlongArmKey)
    }

    /// True when `chirality` is the hand that aims / fires / points the
    /// wheel. The off hand moves and anchors the wheel.
    func isDominant(left: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return _rightHanded ? !left : left
    }
}
