# Aligning the level to the room — design

Status: built on `feat/room-align`, 2026-10-20. Not proven on device. An
experiment with a known exit; see "Failsafes" and "The risk, stated plainly".

## Intent

When the world melts to passthrough, the level should look like it belongs
in the room you are standing in rather than lying across it at a random
angle. If the corridor you are in runs parallel to your living room, the
whole thing reads as mapped. If it runs diagonally through your sofa, it
reads as a hologram.

## What can actually be fixed

Three things could be matched between the level and the room. Only one of
them is worth doing, and saying why is most of this document.

**Orientation can be fixed, and it is the one that matters.** Quake's
brushwork is overwhelmingly axis aligned, and rooms are overwhelmingly
rectangular, so both have a dominant pair of perpendicular directions.
Rotating one to match the other is a single angle, bounded by 45 degrees
because beyond that the next wall is a better match.

**Position cannot usefully be fixed.** Matching a wall's position means
moving the player, which is a teleport, and a teleport chosen by a
heuristic can drop you somewhere worse than where you were. It also cannot
succeed: a Quake room is typically much larger than a living room, so the
far wall will not line up wherever you stand.

**Scale cannot be fixed either.** `vr_worldscale` is clamped to twenty
percent either way, deliberately, because beyond that the world reads as a
model or as a cathedral. Stretching a Quake room onto a living room needs
far more than twenty percent.

So: rotation only. The honest claim is "your corridor runs the way your
room runs", not "that wall is your wall".

## The constraint that shapes the implementation

The alignment has to be a **real turn**, applied to the body heading, not a
rotation of the camera. Rotating only the camera would decouple what you
see from where you walk and where you shoot, because movement and the aim
are composed in the body basis.

The body heading already has exactly one sanctioned writer for a
deliberate turn: `IN_SnapTurn` in `platform/in_null.c`, which adds to
`qr_body_yaw` and rotates the head-absorption ledger by the same angle so
the player box stays under the head. The alignment calls that and nothing
else.

This matters more than it looks. `IN_Move` keeps `qr_expected_yaw` and
treats any unexplained change in `cl.viewangles[YAW]` as a server
setangle, adopting it into the body so that spawns and teleports face the
right way. A turn written directly into `qr_body_yaw` outside that path
would either be mistaken for a teleport or would desynchronise the ledger.
Going through `IN_SnapTurn` keeps both correct by construction.

## When it is applied

On the phase sweep, in the direction that melts the world away.

That moment is already a deliberate two second transition with a dissolve
covering it, which is the only time a 45 degree turn can happen without
being unpleasant. Outside it, turning in the game would drift you back out
of alignment within seconds, and continuously correcting for that would
spin the room under you, which is worse than no alignment at all.

Rephasing does not turn you back. The alignment is a turn like any other
and the world is where you left it.

## How the two directions are found

**The room.** The sensing session the floor already owns asks for vertical
planes as well as horizontal. Each vertical plane's normal, projected onto
the horizontal, is a wall direction. They are binned modulo 90 degrees and
weighted by area, and the heaviest bin is the room's direction. A room
with one large wall and three small ones still answers correctly.

**The level.** Cast rays horizontally from the player at 15 degree
intervals, using the same hull trace the aim reticle already uses, and
take the surface normal of each hit within a few metres. Bin and weight
those the same way, by nothing more than hit count, since a long wall is
hit by more rays than a short one. This samples the room you are standing
in rather than the level as a whole, which is the right scope: it is the
local geometry that has to match.

**The angle.** The difference between the two dominant directions, reduced
into plus or minus 45 degrees. If either set is too weak to call, for
example standing in the open or in a round room, the alignment does
nothing and says so.

## Goals

- While phased, the level's local walls run parallel to the room's walls.
- Applied once per melt, masked by the sweep, never during play.
- Off unless asked for, and recoverable by a single turn if it picks badly.

## Non-goals

- Matching wall positions, or any movement of the player.
- Matching scale.
- Keeping alignment while the player turns in the game.
- Doing anything at all when the world is solid.

## Anti-goals

An automatic turn the player did not ask for, outside the melt. That is
motion sickness and a lost firefight.

## Failsafes

These are part of the first commit, not added later.

- `vr_align_room`, default 0. Nothing changes for anyone until it is on.
- The whole effect is one rotation and it persists nothing. Undoing it is
  a turn of the stick, to within `vr_snapturn` degrees. **Not**
  `vr_recenter`: that zeroes the head pose and the absorption ledger and
  does not touch the body heading, so it leaves the alignment exactly
  where it was. An earlier draft of this document claimed otherwise.
- No save state, no level data, no engine files touched. The vendored
  hunk count does not move.
- It lives on its own branch. If the result is flat, the branch is deleted
  and main never carried it.

## The risk, stated plainly

This may simply not feel like anything. Matching direction without
matching position gives you a level that runs the same way as your room
but is still the wrong size and in the wrong place, and the mind may not
grant the rest. Nobody can answer that from a document; it is cheap to try
and cheap to abandon, which is the only reason it is worth trying.

The second risk is a bad pick. A level corner with equal wall evidence in
both directions, or a room whose dominant wall is a window the detector
sees poorly, can produce a 45 degree turn that makes things worse. The
confidence threshold is there for that, and doing nothing must always be
the fallback.

## The assumption that was removed

An earlier draft took a vertical plane anchor's normal to be the Y axis
of its own frame, consistent with how the floor path treats those anchors
but established nowhere in this repository. That assumption is gone.

A wall's frame has exactly one vertical axis -- up the wall -- and two
horizontal ones: the normal, and the direction the wall runs. Those two
are ninety degrees apart, and this feature works modulo ninety because
walls are square to each other, so the two are the SAME answer. Taking
the flattest of the three axes therefore cannot be wrong, whichever
convention the platform uses.

That mattered more than a tidy-up. Picking the vertical axis by mistake
fails silently in the worst possible way: the tilt filter drops every
wall, and the room reports having no walls at all while plane detection
is working perfectly.

## Verification

Host: the binning and the angle reduction are pure maths over a set of
directions, so they are host-tested the way `FloorMath` is. Cases that
matter: a clean rectangle, a room with one dominant wall, two directions
of equal weight (must refuse), evidence below threshold (must refuse), and
an angle just over 45 degrees (must reduce the short way).

Device, the criterion that cannot pass on a black screen: stand in a
corridor at a visible angle to the room, phase out, and watch the corridor
swing to run with the room. Then do it in a round room or the open, and
watch nothing happen, with the log saying why.

**That angle must be near 20 or 30 degrees, not 0 and not 45.** The turn
is taken modulo 90, so an inverted sign is indistinguishable from a
correct one at both of those, and a test run in a corridor that happens to
sit square or diagonal to the room passes either way.

**Do the room-only check first.** It needs no level, no melt and no
corridor, and it is the only thing that proves the consumer chain and the
plane-normal assumption above. Turn on `vr_align_debug 1`, then press
**Align now** in the window; the first line printed is the room's side and
it prints before anything can refuse.

1. Stand square to a real wall, facing it. Recenter. Press Align now. The
   `anchor` figure should read near 0 (the normal faces back at you at
   180 degrees, and 180 modulo 90 is 0).
2. Turn 20 degrees to your LEFT. Recenter. Align now. It should read
   near 70.
3. Turn 20 degrees to your RIGHT instead. Recenter. Align now. It should
   read near 20.

Steps 2 and 3 are the whole point: left and right must give DIFFERENT
numbers. If they come out swapped, the angle's sign is inverted somewhere
in the consumer chain. If the figure is unstable or unrelated to where you
are standing, the wrong column of the plane anchor is being read as its
normal. Either way the level side is irrelevant until this passes.

Only then the corridor test, and expect the level side to refuse in open
space: six of twenty-four rays must find geometry, and the Quake rooms
that dwarf a living room are exactly the ones with nothing within range.
`QR_ALIGN_RANGE` is the first number to tune, and the refusal says which
gate stopped it.

## Settled by the builder

- 24 rays at 15 degrees, out to 160 units (~4 m). A long wall is hit by
  several and outvotes a short one by hit count alone, which is why the
  level side needs no area term.
- Only rays whose hit normal is within 0.3 of horizontal vote. Ramps,
  stair lips and sloped ceilings all have normals that are not a wall's.
  The fan starts 16 units above the player's origin: under a railing,
  above a step riser.
- No bins. A weighted circular mean taken at FOUR TIMES the angle, since
  the period of "which way does this room run" is 90 degrees and not 360.
  Binning splits a plain rectangle between two bins and then has to decide
  a tie; at 4x a rectangle is the maximally confident case, which is what
  it should be. The confidence is the resultant's length over the total
  weight.
- Thresholds: 2 square metres of detected wall, 6 ray hits, and 0.5
  confidence on each side. The last one is what refuses a round room and
  a 45-degree tie, both of which cancel to zero.
- Applied at the start of the melt, in one `IN_SnapTurn`. Easing it across
  the sweep would mean a per-frame heading correction competing with the
  player's own turning.

  Honest caveat on "masked by the sweep", which this document says
  elsewhere: at the cvar's edge the eased phase is still near zero and the
  world is fully opaque, so what the player sees is a plain snap turn, the
  same motion the stick makes. The dissolve is not covering it. That may
  well be the better behaviour -- a snap turn is a motion this game already
  asks for and the player is used to reading -- but the third option exists
  and is untried: fire on the eased value crossing part-way through the
  sweep, where the noise really is hiding the walls. Decide it after the
  first device run, not before.
- Refusals print under `vr_align_debug`, and always for the manual
  `align_room` console command. `vr_align_debug 1` also prints all five
  numbers on every attempt, which is how the sign gets checked.

## Decided while building

**The frame contract lives on the consumer side.** The engine is handed
angles in the ANCHOR frame -- the Quake world rotated by `body_yaw` -- so
its whole conversion is one addition. Swift owns the matrix that defines
the frame and already composes it every frame; a second statement of the
axis and sign conventions in C is how the two halves drift apart. The
formula is spelled out on `QC_SetRoomWalls` rather than named, because
"compass angle" is ambiguous in exactly the way that matters.

**Normals are stored raw and corrected at publish time.** The recenter
correction carries a yaw, and it changes whenever the player recentres,
while a wall anchor can sit untouched for minutes. A direction baked at
detection time goes stale there with nothing to invalidate it.

**The turn's sign is derived, not tried.** The reduction modulo 90 makes
an inverted sign agree at exactly 0 and 45 degrees and be wrong by twice
the angle everywhere else, so a square room cannot tell the two apart.
This also raises the bar on the device criterion below.

**A level change loses the alignment, and does not redo it.** This
document originally claimed the turn survives a map change. It does not.
The server sends a `setangle` on spawn, and `IN_Move`'s adopt guard takes
any unexplained change in the view yaw as exactly that and writes it into
the body heading -- which overwrites the alignment turn. Nothing writes
the phase cvar on a map load either, so no edge fires on arrival: you
come through the slipgate already melted, facing the spawn angle, with
the level lying across the room at whatever angle it happens to lie at.
`phase 0` then `phase 1` re-aligns.

Fixing that means re-aligning on the spawn edge rather than only the melt
edge, which is a turn the player did not ask for at a moment when the
dissolve is not covering anything. That is this document's own anti-goal,
so it is left alone and raised as a question for A. instead.

## Known rough edges, deliberately left

- The engine keeps its wall table while the immersive space is open and is
  handed an empty one when it closes, so `align_room` typed from the flat
  window with the space shut always refuses. That is the honest answer
  (there is no live room measurement then), but it means the window's
  button only works with the space open.
- Vertical-plane updates now run the floor re-selection, which takes a
  lock the render thread takes twice a frame. Cheap per update, and plane
  churn settles once a room is scanned, but it is worth watching in a
  fully scanned room.
- A ray from the fan is a point, not the player's hull, so it slips
  through a railing or a doorway the player cannot and can vote for the
  next room's wall.

## For A.

- Whether a refusal should say so visibly in the headset, or only log. It
  logs today, and the window has an "Align now" button that always says
  why it refused.
- Whether "Align now" should stay in the shipped panel or be a debug-only
  control once the automatic path is trusted.
- Whether coming through a slipgate already melted should re-align on the
  spawn, given that the spawn `setangle` wipes the previous alignment.
  Doing it means an unrequested turn with nothing covering it, which this
  document calls an anti-goal; not doing it means every level change
  leaves the world lying across the room until you rephase.
