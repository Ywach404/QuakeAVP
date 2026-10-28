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

## THE ORDERING CONSTRAINT -- RESOLVED 2026-10-28, same day. Kept for the
## reasoning; it no longer gates anything.

**The merge is done.** It was one line. `LOC_LoadFile` was already vendored
(our commit is 2026-08-08, past the 2026-08-07 the checklist names), and the
only vendored-relevant change in the four commits since was `MAXALIASVERTS`
2000 -> 2400 in `gl_model.h`, which touches none of the six hunks. Landed in
139d495; the engine is now at upstream HEAD `c9c8ee9`.

So the seventh hunk has nothing to wait for, and the two tracks are now fully
independent. The constraint below is left in place because the reasoning is
still correct and will apply at the NEXT upstream merge.

## The ordering constraint as originally written

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

## Two decisions A. owed -- BOTH SETTLED 2026-10-28

A. delegated them ("go with what you think is best"). Recorded in full, with
reasoning, at the foot of the obstacles design under "For A.". Either can be
overruled. In short: **Sight A first, then B**, because B is a seventh engine
hunk and paying a permanent merge cost before the boxes are seen working on
device is backwards; and **unknown-class geometry included by default**, with
a cvar to exclude it, because Apple's classifier fails on exactly the
furniture this demo is about.

Obstacles is therefore unblocked.

The original framing, for context:

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

**The merge is DONE** (139d495, 2026-10-28): one line, no conflicts, engine
now at upstream HEAD. The first bullet of this track is closed.

**Next move is therefore BSP2.** Load an `mg3` map and see what breaks. The
size of this track is now entirely determined by whether BSP2 sizes overflow
the world vertex arrays and lightmap atlases, which is not knowable from here.
Worth knowing before starting: `MAXALIASVERTS` was raised because
`Mod_LoadAliasModel` calls `Sys_Error` on an oversized model and `Sys_Error`
calls `exit()`, so this class of failure takes the app down rather than
drawing wrong. Expect other limits to behave the same way, and read the error
rather than assuming a crash is a renderer bug.

`make check` compiles all ~57 translation units in a couple of seconds and is
the fast signal that the tree still builds. A passing `make check` is
necessary and NOT sufficient, per working-notes, so the real proof is
`make compile` for visionOS and then the device.

**For the NEXT upstream merge, not this one.** The hunks live in
`quakedef.h`, `miniz.h`, `cl_tent.c`, `pr_cmds.c` and `net_dgrm.c`. Two of the
three behavioural ones are about where a shot comes from and are load-bearing
for the aim/body split; do not let a merge quietly drop them. `vr_projdebug 1`
prints the residual hand-to-missile offset per weapon and is the check that
`pr_cmds.c` survived: perp should sit near zero, not the 10-20 units it reads
with the fix off.

### BSP2 pre-flight, audited 2026-10-28 (static, no device)

The engine side is fine: BSP2 / `2PSB` / RMQ constants are in `bspfile.h` and
the vendored loader handles them, as QuakeSpasm 0.97 does. The risk is our own
ported bridge, which is what `release-1.md` suspected.

Four fixed limits exist in `qr_bridge.c`, and they fail in two different ways.
That difference is the useful part, because it tells you how a failure will
present on device:

- **`QR_MAX_GLTEXTURES` 4096 -- FATAL.** `QR_TexMgr_NewTexture` calls
  `Sys_Error` when the cache fills, and `Sys_Error` calls `exit()`. The
  mission packs are texture-heavy, so this is the single most likely way
  loading `mg1`/`mg3` kills the app. If an episode map quits the app during
  load, look here FIRST and read the console: the error names itself. Raising
  it is a one-line change in a static array's size.
- **`MAXALIASVERTS` 2400 -- FATAL, already raised.** Was 2000; upstream bumped
  it and we took it on 2026-10-28 (139d495). `MAXALIASTRIS` sits beside it and
  upstream did NOT raise that, which is weak evidence it is sufficient.
- **`QR_MAX_SECRET_SUBMODELS` 256 -- BENIGN.** Guarded by
  `count < QR_MAX_SECRET_SUBMODELS`, so extra secrets are silently dropped.
  A big map's 257th secret will not dissolve; nothing crashes. Worth knowing
  so it is not chased as a phase bug.
- **`QR_MAX_PARTICLES` 8192 and `QR_MAX_CACHED_PICS` 128** -- no concern.

So the expected first failure is a hard exit during load with a named
`Sys_Error`, not a render fault. Read the console before theorising.

### Episodes: what the first device run established, 2026-10-28

Far better than the checklist feared. `game mg3` works, the 468 MB pak reads,
`hub.bsp` (genuine `BSP2` magic, 3.7 MB) and `map6` (30.3 MB) both LOAD AND
PLAY. None of the fatal caps fired: no texture-cache exit, no vertex overflow.
BSP2 is not the problem the item assumed.

One real bug found and fixed: fog was 64x too dense, rendering episode maps as
a flat beige wall (7529b0a). `gl_fog.c`'s `Fog_SetupFrame` divides by 64 on
its way to `GL_FOG_DENSITY` and the port dropped that at the single point the
value leaves the engine. Invisible for the whole project because no stock
Quake map sets fog. The tell was that it looked right paused and flooded on
Resume: `Fog_GetDensity` resolves its fade against `cl.time`, frozen while
paused.

Known cosmetic, NOT our bug: episode hint text shows raw tokens
(`$mg3_hub_rune1_hint`). The re-release stores hints as localization keys and
QuakeSpasm substitutes them from `localization/loc_english.txt`. A.'s dump has
no real copy -- the only one, inside `QuakeEX.kpf`, is a 27-byte placeholder.
Stock QuakeSpasm behaves identically. Needs a real loc file at
`Documents/localization/loc_english.txt`; map titles are literals and already
read correctly.

Still to do on this track: the game-directory picker, and the mg3 laser cannon
HUD slot. The picker grew in value -- `UIFileSharingEnabled` and
`LSSupportsOpeningDocumentsInPlace` are both already true, so a user can drop
ANY mod folder into Documents from the Files app and `game <dir>` it. Third
party packs (A. asked about the Brutalist Quake series, 2026-10-28) therefore
already work by console today; what is missing is only the UI to find them.

Watch out: `Documents/id1/autoexec.cfg` contains `map range` and runs on every
`game` change, so it stomps whatever map you just asked for. Comment it out
before episode testing.

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
