// SPDX-License-Identifier: GPL-2.0-or-later
// Copyright (C) 2026 A. Cervantez
//
//  GripLatch.swift
//
//  Whether the off hand is still gripping the grappling rope. Pure, with no
//  ARKit in it, so tools/check-swift-grip.sh can drive it on the host -- what
//  is worth asserting is a SEQUENCE of hand updates, most of the interesting
//  ones having never measured the hand at all, and that needs no device.
//  HandInput classifies each update and calls in; nothing else does.
//

/// What one hand update managed to find out about the off hand.
///
/// The three cases are not three degrees of confidence, they are a
/// measurement and two kinds of silence, and the whole point of the type is
/// that silence is not evidence.
enum GripUpdate {

	/// ARKit reported the finger joints as tracked and `FistMath` read them.
	/// This is the only case that carries news about what the hand is doing.
	case measured(fistClosed: Bool)

	/// A skeleton arrived, but the joints the fist is measured from came back
	/// untracked, so the straightness fed to `FistMath` was ARKit's guess at
	/// where hidden fingers probably are rather than an observation of them.
	///
	/// This is the case the old code could not see. It kept no record of
	/// whether a joint was tracked (the inferred reader deliberately discards
	/// that, which is right for DRAWING a hand and wrong for deciding one),
	/// so a hidden hand whose guessed fingers drifted straight arrived
	/// indistinguishable from a hand that had opened.
	case untrusted

	/// No usable skeleton: the anchor was removed, or arrived without one.
	case lost
}

/// The rope's grip, held across updates that did not see the hand.
///
/// The gesture and the geometry are in conflict and cannot both be moved. The
/// rope is gripped by the OFF hand, and a turn is led with the DOMINANT arm,
/// which sweeps across the off hand and hides it from the cameras. So the
/// single most routine thing a player does while swinging is also the thing
/// that blinds the sensor the swing depends on. Occlusion here is not an
/// error case to tolerate, it is the main sequence.
///
/// What makes it costly is on the engine side: the hook is not a latch but a
/// live bit re-read every tick, and it disengages on the first tick that
/// reads false. One unreadable update used to wipe the hand's whole state,
/// which published a false bit, which dropped the player out of mid air.
///
/// So the rule is that the grip changes on OBSERVATIONS and never on their
/// absence. A hand nobody can see is doing exactly what it was doing before.
///
/// The asymmetry in the other direction is not a symmetry at all and matters
/// more: an unreadable hand must never CREATE a grip. `FistMath.unknown`
/// already takes that position for a half-seen hand, so that the cameras
/// losing an open hand cannot throw a hook by itself. Holding a grip you can
/// no longer see costs nothing (keep swinging, and let go when your hand is
/// back in view). Inventing one costs a rope you did not ask for.
///
/// There is deliberately no timeout. Every duration that could expire here is
/// wrong, because no amount of elapsed time makes falling off the rope the
/// right answer: the player can always release by showing an open hand, and
/// the hand becomes visible the moment they use it for anything at all. The
/// paths that still end a swing are the ones that always did, dying,
/// teleporting, `vr_grapple 0`, and the hands standing down as an input
/// source when tracking ends altogether.
struct GripLatch {

	/// Whether the rope is held as of the last update.
	private(set) var gripping = false

	/// Fold one update in, and answer with the grip the engine should be told
	/// about. Discardable because `gripping` says the same thing.
	@discardableResult
	mutating func update(_ u: GripUpdate) -> Bool {
		if case .measured(let closed) = u {
			gripping = closed
		}
		return gripping
	}
}
