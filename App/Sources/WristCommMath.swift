//
//  WristCommMath.swift
//
//  Pure wrist-communicator math: the 2x3 action grid seated below the HUD,
//  its touch hit-test, the edge/cooldown fire state machine, and the
//  reveal-on-glance decision. No engine, ARKit, or UI imports, so the
//  tools/check-swift-wristcomm.sh host harness compiles and runs it alone
//  (with HudEditorMath.swift, whose WristFrame/offsetInFrame/gridHalfY it
//  reuses).
//

import simd
import Foundation

enum WristComm {

    static let cols = 3, rows = 2
    static let cellSize: Float = 0.034     // metres, one action cell
    static let cellGap: Float = 0.006
    static let cellPitch: Float = cellSize + cellGap
    static let bezelPad: Float = 0.006     // bezel margin around the grid
    static let gridHalfX: Float = (Float(cols) * cellSize + Float(cols - 1) * cellGap) * 0.5
    static let gridHalfY: Float = (Float(rows) * cellSize + Float(rows - 1) * cellGap) * 0.5
    static let hudGap: Float = 0.012       // separation from the HUD grid above
    static let touchDepth: Float = 0.025   // fingertip must be this close to the plane
    static let hoverDepth: Float = 0.08    // approach band: highlight before the touch
    static let cooldown: Double = 0.6      // per-cell re-fire gate, seconds
    static let revealOnCos: Float = 0.88   // ~28 deg: reveal when gaze this centred
    static let revealOffCos: Float = 0.82  // ~35 deg: hide past this (hysteresis)
    static let fireRevealFloor: Float = 0.6
    static let revealRate: Float = 8       // opacity lerp rate, 1/s
    /// How long a revealed side keeps using its last valid wrist frame after
    /// the live one goes invalid, seconds. The arm reaching to press a cell
    /// is exactly what hides that wrist from the cameras, and the editor's
    /// own latch in `wristFrames()` does not apply outside an edit session --
    /// so without this the panel fades out from under the fingertip. Bounded
    /// (not a permanent latch) because a wrist that has genuinely been
    /// lowered must still hide, and only ever applied while the side is above
    /// `fireRevealFloor`: a stale frame plus a blind touch must not fire.
    static let occlusionHold: Double = 0.25
    /// How long a fired key stays lit, seconds -- the press flash window
    /// `WristCommFeedback`'s last fire is read against. Shorter than
    /// `cooldown` deliberately: the flash must have finished before the
    /// same key can fire again, so two presses read as two flashes.
    static let pressFlash: Double = 0.25

    /// Cell N's centre in the comm's local right/up plane (row-major 2x3).
    static func cellCenter(_ index: Int) -> SIMD2<Float> {
        let row = index / cols, col = index % cols
        return SIMD2((Float(col) - Float(cols - 1) * 0.5) * cellPitch,
                     (Float(rows - 1) * 0.5 - Float(row)) * cellPitch)
    }

    /// The communicator's centre, seated below the HUD grid on the wrist
    /// plane -- `hudGap` clear of the grid above it, whichever way the unit
    /// is turned.
    ///
    /// That last clause is the whole of `rollDegrees` here. The drop is the
    /// HUD's own half-height, the gap, and then the unit's HALF-EXTENT ALONG
    /// THE DROP -- and that extent depends on how far `orientedFrame` has
    /// turned the unit in its own plane. The panel's corners sit at
    /// +-gridHalfX along the turned `right` and +-gridHalfY along the turned
    /// `up`; projecting those four corners back onto the wrist's own `up`
    /// and taking the largest gives
    ///
    ///     |sin t| * gridHalfX + |cos t| * gridHalfY
    ///
    /// -- the supporting half-width of the rotated rectangle in the drop
    /// direction. This is the ACROSS view's own seating; the along view never
    /// calls this function -- it drops down the ARM instead, from its own
    /// `alongSeatDistance` below, which is this same derivation on the other
    /// axis. At t = 0 that is the two-row short half (`gridHalfY`,
    /// the panel square to the wrist); at t = +-90 the three-key long half
    /// (`gridHalfX`, the panel turned on its side); in between it sweeps
    /// smoothly, so the unit starts under the HUD at EVERY angle rather than
    /// overlapping the grid part-way through a turn. The absolute values are
    /// why -45 seats exactly like +45: an extent does not care which way the
    /// panel was spun.
    ///
    /// The angle is REQUIRED, not defaulted: a caller that seats the unit
    /// without saying which way it is turned is the bug this signature
    /// exists to make impossible.
    static func commOrigin(wrist: HudEditor.WristFrame, rollDegrees: Float) -> SIMD3<Float> {
        let t = rollDegrees * .pi / 180
        let extent = abs(sin(t)) * gridHalfX + abs(cos(t)) * gridHalfY
        return wrist.origin - wrist.up * (HudEditor.gridHalfY + hudGap + extent)
    }

    /// The ALONG-ARM view's seat: how far DOWN THE ARM, from the wrist joint
    /// toward the elbow, the unit's centre sits so it clears the HUD grid.
    ///
    /// `commOrigin`'s derivation on the other axis -- one seating rule, two
    /// drop directions. The across unit drops down the billboarded wrist
    /// plane's own `up`; this one backs along the forearm, because that is
    /// the only direction a unit riding the arm can move without leaving it.
    ///
    /// WHY IT IS DERIVED AND NOT DIALLED. The HUD grid is billboarded AT the
    /// wrist joint (`ImmersiveRenderer.wristFrame`: origin = wrist + a 3 cm
    /// lift, half-extents `HudEditor.gridHalfX`/`gridHalfY`), so in the
    /// NOMINAL glance pose -- forearm roughly in the view azimuth -- its
    /// reach along the arm is its LONG half, `gridHalfX`. The along unit
    /// used to be seated at the forearm MIDPOINT with nothing clearing that
    /// grid at all, which is why no combination of the placement dials could
    /// get it out from under the modular HUD's wrist tiles: the two were
    /// seated off different things and converged near the wrist. Now the
    /// clearance is the seat and the dials move the unit FROM it.
    ///
    /// The three terms: the HUD's own reach along the arm, the gap, and then
    /// the unit's own supporting half-extent along that same axis --
    ///
    ///     |cos t| * gridHalfX + |sin t| * gridHalfY
    ///
    /// -- the largest projection of the panel's four corners back onto the
    /// drop direction, which is `commOrigin`'s term with the two halves
    /// swapped because the drop here is along the panel's LONG axis instead
    /// of across it. At t = 0 the panel is end-on and its long half
    /// (`gridHalfX`) supports it; at t = +-90 the three-key run lies across
    /// the arm and only the short half (`gridHalfY`) does; in between it
    /// sweeps smoothly. The absolute values are why -45 seats exactly like
    /// +45: an extent does not care which way the panel was spun.
    ///
    /// THAT TERM WAS FLAT FOR ONE ROUND, and the reason it is back is the
    /// reason this view changed. While the along panel was STRAPPED TO THE
    /// SKIN, `rollDegrees` rolled it ABOUT THE ARM -- the long axis was the
    /// rotation axis itself, so the extent along the arm could not move and
    /// the rotated-rectangle form was simply wrong, seating the unit 2 cm
    /// too close at a quarter turn. The panel now BILLBOARDS to the eye
    /// (`alongBaseFrame`) and Rotate is once more an IN-PLANE spin applied
    /// by the shared `orientedFrame`, so the corners genuinely swing and the
    /// rotated-rectangle support is the right model again. One dial name,
    /// two geometries, and the seat has to follow whichever is live.
    ///
    /// STILL A NOMINAL, NOT A BOUND, for two separate reasons worth keeping
    /// apart:
    ///
    ///  * The HUD grid is billboarded, so its true projection onto the arm
    ///    -- `gridHalfX` plus whatever the 3 cm wrist lift contributes at
    ///    the current head yaw -- varies with every head movement, peaking
    ///    around 0.109 m, past the 0.0875 m this seat clears against nominal
    ///    `gridHalfX`. At an adversarial ~46 deg head yaw the two can
    ///    overlap again, by about 2 cm. Accepted: a seat that chased the
    ///    exact projection would slide the keys out from under the player's
    ///    finger as he looked around, and stable keys beat an occasional
    ///    graze.
    ///  * The unit's own long axis is the PROJECTED arm (the arm direction
    ///    as seen in the panel plane), not the bone, so the extent above is
    ///    the arm-perpendicular-to-the-eye case. Every other pose foreshortens
    ///    it, by exactly the sine of the arm-to-eye angle -- which only ever
    ///    makes the real extent SMALLER than this one, so this reason costs
    ///    clearance in no direction. `runAlongSeatTests` sweeps eye
    ///    directions to pin that.
    ///
    /// Static seat, stable keys.
    static func alongSeatDistance(rollDegrees: Float) -> Float {
        let t = rollDegrees * .pi / 180
        return HudEditor.gridHalfX + hudGap
            + abs(cos(t)) * gridHalfX + abs(sin(t)) * gridHalfY
    }

    /// The communicator ROTATED IN ITS OWN PLANE by `rollDegrees`: a rotation
    /// of the panel's in-plane axes about its own normal (`forward`), so the
    /// face keeps pointing at the eye and only the key run turns.
    ///
    ///     right' = right cos t + up sin t
    ///     up'    = up cos t - right sin t
    ///
    /// It is a frame rotation and nothing else, which is what keeps the rest
    /// of this file out of it: `cellCenter`, `touchedCell`/`hoveredCell` and
    /// the renderer's quads are all PANEL-LOCAL (right/up multiples of a
    /// cell), so turning the frame turns the drawn unit, the hover
    /// highlight, the hit-test and the published `WristCommGeometry`
    /// together, with no second opinion to keep in step. The renderer
    /// applies it in its ONE placement chain, between the occlusion-held
    /// wrist frame and the user's dials.
    ///
    /// ZERO IS A BIT-IDENTICAL EARLY RETURN, not a rotation by zero: the
    /// across-wrist unit A. tuned on device is the 0 deg case, and
    /// `simd_normalize` of a cos/sin combination at t = 0 is not guaranteed
    /// to hand back the same floats it was given. The across view's default
    /// is therefore literally today's frame.
    ///
    /// +90 WAS THE OLD `alongArm: true` MAPPING, EXACTLY -- `right' = +up`,
    /// `up' = -right` -- back when this one function also supplied the
    /// along view's orientation. That history is why the sign-choice
    /// reasoning below still lives here (handedness forces the two halves
    /// to move together, `right' x up' == forward`, which leaves exactly
    /// two candidates, this and its opposite, and `right' = +up` made the
    /// along-arm key run and its legends read from the elbow end toward the
    /// wrist): it is DEVICE-DECIDED, not derived, and that is the part worth
    /// keeping. The mapping itself is no longer reachable from here --
    /// `orientedFrame` is ACROSS-ONLY now, the along view builds its own
    /// basis directly in `forearmFrame` below with its own `rollDegrees`
    /// (its default is 0, not +90; see that function's doc for the sign
    /// choice it makes on its own terms) -- and the across view's own
    /// default is 0 (above), so there is no live +90 default anywhere any
    /// more.
    ///
    /// Why a free angle rather than two states, for the ACROSS view: wrist
    /// mounting is never exactly square to the billboarded panel, and the
    /// error is a few tens of degrees, not a quarter turn. A quantised flip
    /// cannot express that; this can, and the seating in `commOrigin`
    /// follows the angle so the unit stays clear of the HUD all the way
    /// round. (The along view's forearm strap has the same kind of skew and
    /// the same fix, but its own: a continuous `rollDegrees` in
    /// `forearmFrame`, not this one.)
    ///
    /// Because the rotation lands BEFORE `adjustedFrame`, the ACROSS view's
    /// dials then act in the turned unit's own axes: the tilt pitches about
    /// the new `right`, and the Side/Height offsets run along the turned
    /// axes too. Deliberate, and stated in the settings caption so the
    /// sliders cannot read as broken. (The along view's dials run in
    /// `forearmFrame`'s own axes instead -- see `resolveCommPlacement`,
    /// the one place that applies either.)
    ///
    /// An invalid (untracked) frame passes through whole, the same contract
    /// `adjustedFrame` keeps: there is no plane to rotate.
    static func orientedFrame(_ frame: HudEditor.WristFrame,
                              rollDegrees: Float) -> HudEditor.WristFrame {
        guard frame.valid, rollDegrees != 0 else { return frame }
        let t = rollDegrees * .pi / 180
        let c = cos(t), s = sin(t)
        var turned = frame
        // Re-normalised because the hit-test projects onto these axes
        // (`HudEditor.offsetInFrame` assumes unit length): a basis that
        // drifted short would silently widen the grid's bounds.
        turned.right = simd_normalize(frame.right * c + frame.up * s)
        turned.up = simd_normalize(frame.up * c - frame.right * s)
        return turned
    }

    /// The ALONG-ARM view's panel basis: ANCHORED TO THE FOREARM, FACING THE
    /// EYE. The unit rides the arm -- lift it into the Buzz L and the panel
    /// goes with it -- but its face is billboarded, so it reads square from
    /// wherever the head happens to be rather than presenting whatever angle
    /// the skin is at.
    ///
    /// WHY THIS AND NOT `forearmFrame` (below, which is what the renderer
    /// used to call). That one put the face on the forearm itself, which is
    /// geometrically honest and unusable: in any natural glance pose the
    /// inner forearm is nearly edge-on to the eye, so the panel came up as a
    /// horizontal line on device, and the Angle/Rotate gimbal cannot recover
    /// it -- turning a panel the head is looking along the PLANE of just
    /// turns the line. Position and orientation were coupled; this splits
    /// them. The seat still rides the arm, the face no longer does.
    ///
    /// THE BASIS:
    ///
    ///  * `forward = normalize(eye - wrist)` -- the panel's normal points at
    ///    the eye. The seat point for this is the WRIST JOINT, not the
    ///    panel's own (seated, dialled) centre, which is not known yet at
    ///    this stage of the chain. BE HONEST ABOUT WHAT THAT COSTS: the seat
    ///    is 0.1445 m down the arm and a glance is about 0.45 m, so the
    ///    direction to the eye from the wrist and from the panel's centre
    ///    differ by as much as atan(0.1445 / 0.45), roughly 18 degrees --
    ///    not the few degrees it would be flattering to claim, and more at
    ///    a dialled-out Forward. Accepted, for two reasons: 18 degrees off
    ///    square is still a plainly readable panel (the failure this round
    ///    exists to fix was 80-odd degrees off, an edge-on line), and a face
    ///    that chased the dialled centre would rock as the dials moved it,
    ///    turning every placement tweak into a reorientation. Expect a
    ///    visibly non-square panel at wide Forward settings; expect it never
    ///    to go edge-on.
    ///  * `right` = the arm axis Gram-Schmidt'd against `forward` -- the
    ///    arm's direction AS SEEN IN THE PANEL PLANE. `right` is the axis
    ///    the three key columns run along and the axis
    ///    `RendererCore.textQuads` lays glyphs along, so this is what keeps
    ///    the unit reading down the forearm, elbow toward hand, instead of
    ///    becoming an ordinary wrist billboard with no arm in it.
    ///  * `up = cross(forward, right)`, the order forced by the invariant
    ///    every frame in this file keeps, `right x up == forward`:
    ///    r x (f x r) = f(r.r) - r(r.f) = f for a unit r perpendicular to f.
    ///    The opposite order reads every legend mirrored while all three dot
    ///    products still come out zero.
    ///
    /// THE DEGENERATE ARM FALLS BACK, IT DOES NOT INVALIDATE. When the bone
    /// points at the eye there is no arm direction left in the panel plane
    /// to lay the keys along, and the Gram-Schmidt residual goes to zero.
    /// Refusing the frame there would blank the unit every time the arm
    /// swung through the view axis -- a flicker in the middle of a reach,
    /// and at exactly the moment the panel is biggest on screen. So this
    /// falls back to the plain worldUp billboard basis instead, the same
    /// construction `RendererCore.billboardBasis` uses (including its
    /// (1, 0, 0) escape for a face straight up the world axis), inlined
    /// rather than called because this file compiles alone in the host test
    /// harness with no renderer beside it. The result is a readable,
    /// upright, valid panel that has merely lost its arm-following reading
    /// direction for the moment the arm is pointed at the player's face.
    ///
    /// NO ROLL PARAMETER. Rotate is applied downstream by the shared
    /// `orientedFrame(_:rollDegrees:)`, exactly as the across view does --
    /// an IN-PLANE spin about this `forward`, which turns the key run and
    /// leaves the face on the eye. That shared step is the point: both views
    /// are now one chain shape (base frame -> `orientedFrame` -> seated
    /// origin -> `adjustedFrame`), differing only in the base frame and the
    /// seating axis.
    ///
    /// `origin` is set to the wrist joint and `anchor` to -1 for
    /// completeness; the renderer overwrites both, the same convention
    /// `forearmFrame` keeps. The unit's real centre is the separate seated
    /// origin the caller computes (`alongSeatDistance` down the arm), which
    /// is the only point the hit-test projects against.
    ///
    /// DEGENERATE INPUTS come back `invalid`, never a NaN basis: a collapsed
    /// forearm (both joints at one point, which is what an untracked pair
    /// reports) and an eye at the wrist (an unresolved head pose). Both
    /// divide by zero in a normalisation, so both are refused before the
    /// division rather than after it.
    static func alongBaseFrame(wrist: SIMD3<Float>, elbow: SIMD3<Float>,
                               eye: SIMD3<Float>) -> HudEditor.WristFrame {
        let bone = wrist - elbow
        let toEye = eye - wrist
        guard simd_length(bone) > 1e-4, simd_length(toEye) > 1e-4 else {
            return HudEditor.WristFrame.invalid
        }
        let armAxis = simd_normalize(bone)
        let forward = simd_normalize(toEye)

        let perp = armAxis - forward * simd_dot(armAxis, forward)
        // 1e-3: a sine threshold, both inputs being unit -- about 0.06 deg
        // off the line of sight. Below it the normalised residual is noise,
        // not a reading direction, so the worldUp billboard takes over.
        var right: SIMD3<Float>
        if simd_length(perp) > 1e-3 {
            right = simd_normalize(perp)
        } else {
            right = simd_cross(SIMD3<Float>(0, 1, 0), forward)
            right = simd_length(right) < 1e-4 ? SIMD3<Float>(1, 0, 0) : simd_normalize(right)
        }
        let up = simd_cross(forward, right)
        return HudEditor.WristFrame(anchor: -1, origin: wrist, right: right,
                                    up: up, forward: forward, valid: true)
    }

    /// The ALONG-ARM view's panel basis, STRAPPED TO THE FOREARM: built from
    /// the two forearm joints and one lateral axis, with no eye, no billboard
    /// and no HUD plane anywhere in it. Lift the arm into the Buzz L and the
    /// unit rides it; roll the arm and the unit rolls with it.
    ///
    /// NOT CURRENTLY CALLED BY THE RENDERER. The along view now uses
    /// `alongBaseFrame` above, which keeps this one's forearm ANCHORING and
    /// hands its ORIENTATION to the eye -- because flat to the skin reads
    /// edge-on from every natural glance pose, which is the device finding
    /// that retired this path (see `alongBaseFrame`'s own doc). It stays in
    /// the file, tested and correct, because the skin-locked construction is
    /// a plausible future OPTION rather than a mistake: it is the right
    /// answer the moment the panel is something the hand grips or the arm
    /// occludes, and deleting a correct derivation of a forearm basis to
    /// re-derive it later is the trade this file has already lost once.
    ///
    /// `wrist`/`elbow` are the `.forearmWrist`/`.forearmArm` joint positions
    /// and `lateral` is a direction out of the INNER forearm face, all in
    /// corrected tracking space -- see `ForearmPose` (HudEditorInput.swift),
    /// which documents which joint-rotation column `lateral` is and how it
    /// is mirrored between hands so one sign serves both.
    ///
    /// THE BASIS, and why each axis is where it is:
    ///
    ///  * `right = normalize(wrist - elbow)` -- the arm's long axis, pointing
    ///    toward the HAND. `right` is the axis the three key columns run
    ///    along AND the axis `RendererCore.textQuads` lays glyphs along, so
    ///    this one assignment is what makes the unit a strap: three keys
    ///    long down the forearm, two across, legends reading from the elbow
    ///    toward the wrist -- a reading direction this view derives on its
    ///    own, from its own joints, and keeps regardless of what the
    ///    across view's `rot` dial is set to (its default is 0, a
    ///    billboarded panel with no elbow to read from, so there is no
    ///    shared default for this one to match).
    ///  * `forward` = `lateral` orthonormalised against `right`
    ///    (Gram-Schmidt) -- the surface normal off the inner forearm, i.e.
    ///    the face the unit presents to a head looking down at it.
    ///  * `up = forward x right`, which is the order forced by the
    ///    invariant every frame in this file keeps, `right x up == forward`:
    ///    r x (f x r) = f(r.r) - r(r.f) = f for a unit r perpendicular to f.
    ///    The opposite order would read every legend mirrored while all
    ///    three dot products still came out zero.
    ///
    /// READING DIRECTION is derived, not guessed, and pinned in
    /// `runForearmFrameTests`: for a right-handed player's LEFT forearm held
    /// across the chest (+Y up, facing -Z, so the arm runs +X) with `lateral`
    /// = +Y, this gives `up` = -Z -- exactly the head-up vector of a head
    /// that has tipped down from facing -Z to look at its own arm. Legends
    /// upright for the wearer, by construction rather than by screenshot.
    /// The across view's equivalent choice had to be called off a device
    /// screenshot after shipping upside down; this one has an on-device
    /// lever instead (below).
    ///
    /// `rollDegrees` ROLLS THE UNIT AROUND THE ARM, rotating the
    /// (`up`, `forward`) pair about `right` -- it picks which face of the
    /// forearm the unit sits on, and it is the one dial that recovers a
    /// wrong answer from the two things here that cannot be verified without
    /// hardware (which joint column `lateral` is, and its chirality sign).
    /// A half turn puts the unit on the opposite face; anything between
    /// walks it round. A rotation about `right` leaves `right` alone and
    /// preserves cross products, so the long axis and the handedness both
    /// survive any angle. ZERO IS AN EARLY RETURN, not a rotation by zero,
    /// for the same reason `orientedFrame`'s is: 0 is this view's default
    /// and must be bit-exact.
    ///
    /// THE ORIGIN IS NOT HERE. The caller seats the unit -- the wrist joint
    /// backed off down the arm by `alongSeatDistance`, plus the placement
    /// dials along these axes (Forward along the arm, Side across it,
    /// Height off the skin) -- and hit-tests against that separate point,
    /// exactly as the across view does with `commOrigin`. The seat IS this
    /// view's HUD clearance: the grid is billboarded at the wrist joint, so
    /// a unit on the arm has to back away from that joint just as the
    /// across unit drops below it. `frame.origin` is set to the wrist joint
    /// for completeness and is read by no communicator consumer.
    ///
    /// DEGENERATE INPUTS come back `invalid`, never a NaN basis: a collapsed
    /// forearm (both joints at one point, which is what an untracked pair
    /// can report), a zero lateral, and a lateral parallel to the bone --
    /// that last one being exactly what a WRONGLY CHOSEN joint-rotation
    /// column looks like. Gram-Schmidt divides by zero on all three, so they
    /// are refused before the division rather than after it.
    static func forearmFrame(wrist: SIMD3<Float>, elbow: SIMD3<Float>,
                             lateral: SIMD3<Float>,
                             rollDegrees: Float) -> HudEditor.WristFrame {
        let bone = wrist - elbow
        guard simd_length(bone) > 1e-4, simd_length(lateral) > 1e-4 else {
            return HudEditor.WristFrame.invalid
        }
        let right = simd_normalize(bone)
        // Normalised here, right after the length guard above, rather than
        // trusted from the caller: the 1e-3 threshold below is a SINE
        // threshold only when `lateral` is unit-length, and nothing at this
        // function's boundary enforced that -- it held only because
        // `ForearmPose`'s joint column happens to arrive unit and the
        // tracking-space correction applied to it is rigid. Normalising
        // makes the threshold true BY CONSTRUCTION for any caller, unit or
        // not. No behavior change for today's caller, which already passes
        // a unit `lateral`.
        let lateral = simd_normalize(lateral)
        let perp = lateral - right * simd_dot(lateral, right)
        // 1e-3: a sine threshold now that `lateral` is normalised above --
        // about 0.06 degrees off the bone. Below it the normalised result
        // is noise, not a face.
        guard simd_length(perp) > 1e-3 else { return HudEditor.WristFrame.invalid }
        let forward = simd_normalize(perp)
        let up = simd_cross(forward, right)

        guard rollDegrees != 0 else {
            return HudEditor.WristFrame(anchor: -1, origin: wrist, right: right,
                                        up: up, forward: forward, valid: true)
        }
        // Rodrigues about `right`, written out rather than via simd_quatf for
        // the same reason `adjustedFrame` writes it out: the host test
        // harness links nothing but simd's free functions.
        let angle = rollDegrees * .pi / 180
        let c = cos(angle), s = sin(angle)
        func roll(_ v: SIMD3<Float>) -> SIMD3<Float> {
            simd_normalize(v * c + simd_cross(right, v) * s)
        }
        return HudEditor.WristFrame(anchor: -1, origin: wrist, right: right,
                                    up: roll(up), forward: roll(forward), valid: true)
    }

    /// The communicator's player-adjusted placement: `origin` shifted along
    /// the wrist frame's own axes and the frame pitched about its `right`,
    /// from the four `VRSettings.wristComm*` dials.
    ///
    /// Both halves come back TOGETHER, as one resolved pair, because they are
    /// only ever correct together: the renderer feeds this single result to
    /// the drawn quads, to the hover highlight and to the published
    /// `WristCommGeometry` side, so a dialled panel is hit-tested where the
    /// eye sees it. (The same three-path discipline `commPose`'s doc
    /// comment states for the occlusion hold -- the dials are a second way to
    /// move the plane, and would break it exactly as a stale frame would.)
    ///
    /// Sign conventions, both chosen for how the dial reads in the headset:
    ///
    ///  * `fwd`/`side`/`up` are metres along `forward`/`right`/`up`. `forward`
    ///    is the unit vector from the wrist TOWARD the eye (see the renderer's
    ///    `wristFrame`), so +fwd brings the unit closer to your face.
    ///  * `tiltDegrees` is a POSITIVE rotation about `right`, which pitches
    ///    the TOP of the panel toward the viewer (at +90 the panel's `up`
    ///    lies along `forward`). That is the direction a forearm-strapped
    ///    unit has to lean to face a head looking down at it.
    ///
    /// `right` is deliberately untouched: it is the tilt axis, and it is also
    /// the axis the six keys are laid out along, so leaving it alone keeps the
    /// grid's columns where the hand learned them. `frame.origin` is untouched
    /// too -- that is the WRIST plane's own origin (the HUD tiles hang off it);
    /// the communicator's centre is the separate `origin` returned here, which
    /// is the only point the hit-test projects against.
    ///
    /// An invalid (untracked) frame passes through whole, dials ignored: there
    /// is no plane to move, and translating a zero frame would hand the touch
    /// loop a grid floating where no wrist is. At all-zero dials this is the
    /// identity, so the tuned-on-device behaviour is literally unchanged until
    /// a dial moves.
    static func adjustedFrame(_ frame: HudEditor.WristFrame, origin: SIMD3<Float>,
                              tiltDegrees: Float, fwd: Float, side: Float,
                              up: Float) -> (frame: HudEditor.WristFrame, origin: SIMD3<Float>) {
        guard frame.valid else { return (frame, origin) }

        let moved = origin + frame.right * side + frame.up * up + frame.forward * fwd
        guard tiltDegrees != 0 else {
            return (frame, moved)
        }

        // Rodrigues about `right`, written out rather than via simd_quatf so
        // the host test harness needs nothing but simd's free functions: for a
        // unit axis perpendicular to v, v' = v cos + (axis x v) sin.
        let angle = tiltDegrees * .pi / 180
        let c = cos(angle), s = sin(angle)
        func rotate(_ v: SIMD3<Float>) -> SIMD3<Float> {
            simd_normalize(v * c + simd_cross(frame.right, v) * s)
        }
        var tilted = frame
        tilted.up = rotate(frame.up)
        tilted.forward = rotate(frame.forward)
        return (tilted, moved)
    }

    /// The hovered cell AND which fingertip produced it, from one entry per
    /// tracked tip (`nil` = that tip is not over the grid; index 0 = left,
    /// 1 = right, the order `FingerTips` publishes).
    ///
    /// The cell is the MINIMUM hovered cell, which is exactly what the
    /// renderer's previous `.min()` picked, so the drawn highlight is
    /// unchanged by this existing; the point of the helper is the second
    /// half, the tip, which is the hand the solid finger model is drawn on. A
    /// tie on one cell breaks to the lower tip index, so two hands over the
    /// same key cannot alternate the finger between them frame to frame --
    /// deterministic for the same reason the `.min()` was.
    static func hoverPick(_ cells: [Int?]) -> (cell: Int, tip: Int)? {
        var best: (cell: Int, tip: Int)?
        for (tip, cell) in cells.enumerated() {
            guard let cell else { continue }
            if best == nil || cell < best!.cell { best = (cell, tip) }
        }
        return best
    }

    /// The cell a world point lands on within `depth` of the grid plane, or
    /// nil (untracked wrist, off the grid laterally, or too far off the
    /// plane). The ONE hit-test body: `touchedCell` and `hoveredCell` are
    /// the same test at two depths, so a change to the grid's lateral
    /// bounds or its row/column rounding can never apply to the press but
    /// not the highlight -- which would light one key and fire another.
    private static func cell(_ p: SIMD3<Float>, commOrigin: SIMD3<Float>,
                             frame: HudEditor.WristFrame, depth: Float) -> Int? {
        guard frame.valid else { return nil }
        let local = HudEditor.offsetInFrame(point: p, origin: commOrigin,
                                            right: frame.right, up: frame.up, forward: frame.forward)
        guard abs(local.x) <= gridHalfX, abs(local.y) <= gridHalfY,
              abs(local.z) <= depth else { return nil }
        let col = min(max(Int((local.x / cellPitch + Float(cols - 1) * 0.5).rounded()), 0), cols - 1)
        let row = min(max(Int((Float(rows - 1) * 0.5 - local.y / cellPitch).rounded()), 0), rows - 1)
        return row * cols + col
    }

    /// The cell a world point touches, or nil (off the grid or off the plane).
    static func touchedCell(_ p: SIMD3<Float>, commOrigin: SIMD3<Float>,
                            frame: HudEditor.WristFrame) -> Int? {
        cell(p, commOrigin: commOrigin, frame: frame, depth: touchDepth)
    }

    /// The cell a world point is APPROACHING -- the same grid test as
    /// `touchedCell`, bounded by the wider `hoverDepth` instead. Feedback
    /// only: the renderer brightens this key so a fingertip on its way in
    /// can see which one it is about to press, several centimetres before
    /// `touchedCell` (and therefore the fire gate) agrees. `touchDepth` is
    /// a strict subset of `hoverDepth`, so a key being pressed is always
    /// also hovered and never flickers un-highlighted on the way down.
    static func hoveredCell(_ p: SIMD3<Float>, commOrigin: SIMD3<Float>,
                            frame: HudEditor.WristFrame) -> Int? {
        cell(p, commOrigin: commOrigin, frame: frame, depth: hoverDepth)
    }

    /// Edge/cooldown fire gate. `touched` holds the cell under each tracked
    /// fingertip this tick (nil = none). A cell fires on a fingertip's rising
    /// edge into it, only while revealed; its cooldown then blocks re-fires,
    /// and holding never repeats.
    ///
    /// At most ONE cell fires per tick, deliberately: two fingertips entering
    /// two different cells within the same 90 Hz tick is not an interaction a
    /// hand can aim, and one command per tick keeps a fire unambiguously
    /// attributable to a single touch (the second entry is still recorded in
    /// `wasIn`, so it is consumed rather than deferred into a later tick).
    struct TouchState {
        var wasIn: [Int?] = [nil, nil]
        var cooldownUntil: [Double] = Array(repeating: 0, count: 6)
        /// False until this state's first `updateTouch` call. A fresh state
        /// arms wherever the fingers already happen to be (editor-close,
        /// idle->active, startup) -- without this, a finger already resting
        /// in a cell at that instant reads as a rising edge against `wasIn
        /// == nil` and fires the bound command unintended. The first call
        /// instead just RECORDS the current touches as the baseline.
        var seeded: Bool = false
    }

    static func updateTouch(state: TouchState, touched: [Int?], now: Double,
                            revealed: Bool) -> (state: TouchState, fire: Int?) {
        var next = state
        if next.wasIn.count != touched.count { next.wasIn = Array(repeating: nil, count: touched.count) }
        guard next.seeded else {
            next.wasIn = touched
            next.seeded = true
            return (next, nil)
        }
        var fire: Int? = nil
        for (i, cell) in touched.enumerated() {
            let was = i < state.wasIn.count ? state.wasIn[i] : nil
            next.wasIn[i] = cell
            guard revealed, let cell, cell != was, cell >= 0, cell < 6,
                  now >= next.cooldownUntil[cell], fire == nil else { continue }
            fire = cell
            next.cooldownUntil[cell] = now + cooldown
        }
        return (next, fire)
    }

    /// Reveal decision with hysteresis: ON past revealOnCos, OFF past
    /// revealOffCos, holds the current state in between.
    static func revealTarget(headPos: SIMD3<Float>, headForward: SIMD3<Float>,
                             commOrigin: SIMD3<Float>, wasRevealed: Bool) -> Bool {
        let to = commOrigin - headPos
        let len = simd_length(to)
        guard len > 1e-4 else { return wasRevealed }
        let aim = simd_dot(simd_normalize(headForward), to / len)
        if aim >= revealOnCos { return true }
        if aim <= revealOffCos { return false }
        return wasRevealed
    }

    static func smoothedOpacity(current: Float, target: Float, dt: Float) -> Float {
        let t = min(max(revealRate * dt, 0), 1)
        return current + (target - current) * t
    }

    /// The touch loop's fire gate: a cell with no bound command (or one
    /// that's only whitespace -- the same "unset" reading `WristCommStore.
    /// fire` already applies) is a no-op touch, not a blank line sent to
    /// the engine. Pure so the loop can check it before ever hopping to
    /// the main actor.
    static func shouldFire(_ command: String) -> Bool {
        !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// A RESERVED binding that is handled app-side and never reaches the
    /// engine: it summons the SwiftUI window, which is now the product's
    /// whole out-of-game surface. `WristCommStore.fire` compares the cell's
    /// trimmed command against this and calls the summon closure instead of
    /// sending; the sixth off-wrist cell ships bound to it (see
    /// `vr_wristcomm_off_cmd5` in platform/r_null.c).
    ///
    /// It is spelled with the project's own prefix precisely so it cannot
    /// collide with a console command now or after an upstream merge -- if
    /// it ever did leak to the engine, the engine would print "Unknown
    /// command" and the key would look broken. Named here, in the pure file,
    /// so there is one definition and the host test can pin it.
    static let summonWindowCommand = "qavp_window"

    /// True when a cell's binding is the reserved summon rather than a
    /// console command. Trimmed, because `shouldFire` already treats
    /// surrounding whitespace as insignificant and the two must agree.
    static func isSummonWindow(_ command: String) -> Bool {
        command.trimmingCharacters(in: .whitespacesAndNewlines) == summonWindowCommand
    }

    /// The one "panel in use" predicate for a single published side: up
    /// (`enabled`) and faded in at least to the fire floor. Both
    /// `WristCommInput.anySideQualifies` and `HandInput.wristCommInUse`
    /// `.contains` their own `WristCommGeometry.Side` arrays through this,
    /// so there is exactly one definition of "the panel is up" -- a second
    /// opinion here would hold turning on frames where no key could be
    /// pressed, or free it on frames where one could.
    static func sideQualifies(enabled: Bool, opacity: Float) -> Bool {
        enabled && opacity >= fireRevealFloor
    }
}
