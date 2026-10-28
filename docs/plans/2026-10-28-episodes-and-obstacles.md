# Episodes and room obstacles, in parallel -- kickoff plan

Written 2026-10-28, after the 2D-layer box was ticked. NOT a task-level plan:
each track gets one of those when it starts, because Episodes cannot be
decomposed honestly until the upstream merge's conflicts are seen. This
document is the sequencing, the hazards and the decisions, so a session
starting cold knows what it is walking into.

## The two tracks

**Episodes** is release-1 item 2, and the last required engineering item:
Online was demoted to not-required on 2026-10-28, so after this only
Distribution stands between the project and a release.

**Room obstacles** is the ottoman demo: real furniture solid to monsters while
the world is phased out. It is NOT on the release-1 checklist and does not
block the release. It is the portfolio piece, and `docs/release-1.md` is
explicit that scope outside the checklist is what caused the doubt before. It
runs in parallel because it is the showcase footage, not because it is
required.

Its design is already written and thorough:
`docs/designs/2026-10-17-room-obstacles.md`. Do not re-derive it. Its
dependency shipped on 2026-10-21 (the phase floor), and plane data is
flowing: a device session logged 13 usable walls of 19.

## THE ORDERING CONSTRAINT, which is the whole reason to plan these together

Both tracks reach into the vendored engine, and one ordering is much cheaper
than the other.

`Sources/QuakeCore/engine/` is QuakeSpasm 0.97 with exactly SIX patched hunks,
all `#ifdef QAVP_PLATFORM`, all listed in `UPSTREAM.md`. `docs/working-notes.md`
is blunt that every hunk costs on the next upstream merge.

- Episodes REQUIRES an upstream merge past 2026-08-07, for `LOC_LoadFile` in
  `common.c`.
- Obstacles MAY add a seventh hunk, in `SV_ClipToLinks` (the Sight decision
  below).

So: **land the upstream merge before the seventh hunk exists.** Merging six
hunks is cheaper than merging seven, and the seventh lands cleanly onto a
freshly merged tree. If the Sight decision comes back as "B from the start",
hold B until the merge is done rather than reordering the merge around it.
Nothing else in either track collides: obstacles is otherwise platform and
renderer code, Episodes is engine, model and BSP loading.

## Two decisions A. owes before obstacles can start

Both are at the foot of the obstacles design, under "For A.".

1. **Sight: A then B, or B from the start?**
   Out of the box a monster's `visible()` calls `traceline` with the
   no-monsters flag, and `SV_ClipToLinks` then skips everything that is not
   `SOLID_BSP`. So the grunt cannot REACH you behind the sofa but knows you
   are there and keeps firing. Option A ships that and accepts it. Option B is
   the seventh hunk: one line inside the existing guard letting an
   obstacle-flagged entity stop that trace, so hiding behind the sofa works.
   The design recommends A first, then B once boxes are seen behaving on
   device, because B is the one piece no cvar can revert.

2. **Is unknown-class geometry included by default?**
   The design says yes, and says why: an unclassified ottoman is the whole
   demo. Saying no makes the showcase depend on Apple's scene classifier
   recognising furniture it often does not.

## Episodes: what is known, and the first move

From `docs/release-1.md`:

- Merge upstream QuakeSpasm master past 2026-08-07 for the game-directory
  localization lookup (`LOC_LoadFile` in `common.c`).
- A game-directory picker. The console `game mg3` already works, so this is
  UI over an existing mechanism, not new engine work.
- Load an `mg3` map and fix whatever BSP2 sizes break in the world vertex
  arrays and lightmap atlases.
- The mg3 laser cannon gets a HUD slot and a binding.
- MD5 models stay unsupported. QuakeSpasm has none and the originals load.

Data is not a blocker: dopa, mg1, mg3 and both mission packs are already in
A.'s QuakeDump.

**First move, before any code:** do the merge in a scratch worktree and read
the conflicts. The size of this track is entirely determined by what the merge
does to the six hunks and whether BSP2 actually breaks, and neither is
knowable from here. `make check` compiles all ~57 translation units in a couple
of seconds and is the fast signal that the merged tree still builds; a passing
`make check` is necessary and NOT sufficient, per working-notes, so the real
proof is `make compile` for visionOS and then the device.

**Expected to bite:** the hunks in `quakedef.h`, `miniz.h`, `cl_tent.c`,
`pr_cmds.c` and `net_dgrm.c`. Two of the three behavioural ones are about where
a shot comes from and are load-bearing for the aim/body split; do not let a
merge quietly drop them. `vr_projdebug 1` prints the residual hand-to-missile
offset per weapon and is the check that `pr_cmds.c` survived: perp should sit
near zero, not the 10-20 units it reads with the fix off.

## Obstacles: the shape, from its design

Read the design; this is only the spine.

- Boxes, not meshes. Quake collides with boxes natively.
- Horizontal extents published in the corrected room frame and converted on
  the engine thread every tick, because the mapping moves. Vertical published
  above the measured floor and placed against the hull bottom, so the floor
  measurement stays render-side.
- Boxes that intersect the player's hull are suppressed for that tick, so the
  player can never be boxed in.
- Appear on phase start, vanish on phase end, with hysteresis so a quick
  toggle does not churn them.
- Single player only. Walls off by default.
- This would be the FIRST `ED_Alloc` from platform code. Pooled, never freed
  per update, reclaimed by classname after a load.

**The known risk, from the design:** scene reconstruction lags a moved object
by seconds and leaves a ghost at its old position. The ottoman will be solid in
two places for a moment. That is Apple's pipeline, not a bug to fix, and the
demo should be shot knowing it.

## Verification both tracks owe

`docs/working-notes.md`: every milestone needs at least one criterion that
cannot pass unless something visibly correct is on screen, reported alongside
the numbers rather than instead of them.

- Episodes: an `mg3` map loaded and played on device, with the frame rate
  visible. A BSP2 level that loads but renders wrong is the failure mode to
  look for, and it will not show up in a host test.
- Obstacles: the design's own verification -- phase out, walk a grunt at
  yourself, step behind the sofa, then push an ottoman into its path and watch
  it stop and reroute. Record it.

Device work is unblocked: the paid Apple Developer Program landed 2026-10-28
and the profile now runs to 2027-10-28, so the seven-day expiry that killed
builds and the installed app is gone.

## What NOT to do

- Do not start obstacles before the two decisions are answered. The Sight
  answer changes whether a seventh engine hunk exists, which changes the merge.
- Do not add the seventh hunk before the upstream merge lands.
- Do not treat obstacles as release work. It is portfolio work running
  alongside; if the two compete, Episodes wins, because it is the last
  required item.
- Do not re-plan the obstacles design. It is written, it is detailed, and two
  of its sections exist specifically to record decisions already made.
