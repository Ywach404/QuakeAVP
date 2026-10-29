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

### Third-party packs: Brutalist Jam III RUNS, 2026-10-28

Its own page says it requires Ironwail 0.8.1+ and that other engines should
"expect issues". It loaded and played on our QuakeSpasm 0.97 base
(`qbj3_devroom`). That claim is about LIMITS its biggest maps hit, not about
engine features, which matters for every other pack with the same warning:
treat "needs Ironwail" as a thing to test rather than a closed door.

The formats were never the problem. Of 92 levels, 52 are BSP29 and 40 are
BSP2, both of which we handle. What is hard is bulk: 5.9 GB uncompressed, of
which 812 MB is `mapsrc` (`.map` sources), 398 MB an art vault and 407 MB
music, none of it needed to play. The playable content is about 250 MB.

How it was installed, which is the reusable part: a trimmed `pak0.pak` built
locally from `progs`, `sound`, `textures`, `gfx`, `progs.dat` and four small
levels, 794 MB as ONE file. Pushing 1,448 loose files over devicectl is not
practical; building a pak and pushing one is. The builder is a dozen lines of
Python over the zip, and the format is twelve bytes of header plus 64-byte
directory entries.

**What breaks on a mod with its own arsenal, and why.** `QR_WeaponName` in
qr_bridge.c is a switch over vanilla's eight `IT_*` bits, so a mod's weapons
fall through to "(none)" and the wheel emits nothing. The per-weapon placement
table published through `QC_SetWeaponPlacement` is the same eight slots. A.
confirmed on device: the wheel does not work at all, the hand and weapon
models sit wrong, and the modular HUD's glyphs do not match the new arsenal.

This is [[weapon-wheel-slot-count]] arriving for real. The fix is to stop
deriving the ring from a hardcoded bit table and take it from what the player
actually owns plus the view models the server names, so a mod or a mission
pack brings its own weapons. That is a feature, not a patch, and it is NOT
release work: nothing on the release-1 checklist needs it.

### The last Episodes item: the mg3 laser cannon, fully specified

Scoped on 2026-10-28 and NOT built: the C half was written, found to force a
Swift migration bigger than judged, and reverted so the tree stays consistent.
Everything below is established fact, so this should be a short job with a
fresh context.

**What the weapon is.** mg3 reuses Scourge of Armagon's laser cannon outright:
its `progs.dat` contains `IT_LASER_CANNON`, `HIP_FireLaser`, `HIP_LaunchLaser`
and `HIP_LaserThink`. The engine already defines the bit in `quakedef.h` as
`HIT_LASER_CANNON (1<<23)`. One new slot therefore covers BOTH hipnotic and
mg3. Note the engine's `hipnotic` global is only set by the `-hipnotic`
launch argument, so mg3 does not get `sbar.c`'s hipnotic HUD path; the wheel
must carry it independently.

**The C half (done once, reverted, straightforward).** `QC_WEAPON_SLOTS` in
QuakeCore.h goes 8 to 9. Four parallel tables in `qr_bridge.c` gain a ninth
entry and should be declared `[QC_WEAPON_SLOTS]` rather than `[8]`:
`qr_wheel_bits` (`HIT_LASER_CANNON`), `qr_wheel_modelnames`
(`progs/v_laserg.mdl`), `qr_wheel_pickupnames` (`progs/g_laserg.mdl`) and
`qr_wheel_labels` ("LASER CANNON"). `models[8]`/`models_isview[8]` likewise.
Five loops are bounded by a literal 8 and were verified to be slot walks:
lines near 5595, 5646, 7098, 7131 and 7314. `make check` links clean after.
Put the new slot LAST so the vanilla eight keep their ring order.

**The Swift half, which is the real work.** `WeaponTrim.swift` holds three
parallel arrays strided by `variant * 8` across four variants: `front`, `rear`
and `place`, 32 entries each, with `defaultPlace32` carrying A.'s
DEVICE-TUNED values baked into code. Widening the stride to 9 means:

- `defaultPlace32`/`defaultFront32`/`defaultRear32` become 36, with the new
  slot inserted at index 8 of EACH variant, not appended to the end.
- `place` for the laser cannon starts untuned (nil) so it falls back to the
  global cvars, which is what an unmeasured weapon should do.
- `publish()` builds `count: 8` and must build `QC_WEAPON_SLOTS`. Until it
  does, C reads a ninth entry Swift never wrote.
- Persistence needs a `.v4` key with migration from `.v3`, following the
  v2-to-v3 precedent already in `load()`: count checks (32, 16) and an
  explicit remap. Inserting a slot per variant is NOT a length check away
  from being safe, so the migration has to be written, not inferred.
- `WheelState.swift`'s `bits` is `[4096, 1, 2, 4, 8, 16, 32, 64]` and
  `impulseForOwnedIndex` returns `i + 1`, deriving the impulse from ring
  POSITION. That breaks at nine. Give each entry an explicit impulse instead.

**The one unknown.** Which impulse selects the laser cannon in mg3. Its own
help text says "impulse 1-8 changes weapons", which cannot be the whole story
for a ninth weapon. Determine it on device by typing `impulse 9` while holding
one, before wiring the ring to it. Do not guess it into the table.

### Weapon wheel: the newer weapons, and the bit collision that governs it

The laser cannon is one slot and is safe. The OTHER mission pack weapons are
not, and the reason is that hipnotic reuses bits vanilla already spends:

    HIT_MJOLNIR        1<<7   = 128     == IT_SUPER_LIGHTNING
    HIT_PROXIMITY_GUN  1<<16  = 65536   == IT_SUPERHEALTH
    HIT_LASER_CANNON   1<<23  = 8388608 == (unused in vanilla)

Add all three unconditionally and the wheel grows a Mjolnir every time the
player picks up a megahealth in stock Quake. Only the laser cannon's bit is
free, which is why it can be added on its own and the other two cannot.

The engine already solves this: `common.h` exports the globals
`standard_quake, rogue, hipnotic`, and `sbar.c` gates its mission pack HUD on
them. The bridge can read the same globals, so a bit means a weapon only in
the game that defines it.

That works BECAUSE of the game picker added the same day: `COM_Game_f` only
sets `hipnotic` when given `-hipnotic`, and the picker now passes it for the
hipnotic and rogue directories. The flag added for HUD correctness turns out
to be the signal the wheel needs.

Note mg3 is a third case: it uses hipnotic's laser cannon CODE but is not
launched as hipnotic, so its `hipnotic` global is false. Bit 23 is free
everywhere, so an unconditional laser cannon entry covers mg3 and hipnotic
both. Rogue's own weapons are a separate set and have not been surveyed.

### CORRECTION: rogue renumbers the bits, so the wheel needs TABLES, not slots

Confirmed on device 2026-10-28: the wheel is visibly glitched under
Dissolution of Eternity. The cause is that rogue does not extend vanilla's
item bits, it reassigns them from 128 upward:

    RIT_AXE           = 2048    <- vanilla IT_CELLS
    RIT_LAVA_NAILGUN  = 4096    <- vanilla IT_AXE
    RIT_SHELLS        = 128     <- vanilla IT_SUPER_LIGHTNING

Our ring table begins `[4096, 1, 2, ...]` and calls 4096 the axe. Under rogue
4096 is the LAVA NAILGUN, so the ring shows that weapon in the axe's slot
wearing the axe's label and model, while the real axe at 2048 never appears.
Bits 1 through 64 are unchanged, which is why it reads as partly wrong rather
than wholly wrong, and why it was not obvious.

**This supersedes the "add a ninth slot" plan above.** Three games mean three
different readings of the same `cl.items` word:

    vanilla / mg1 / mg3   IT_*   8 weapons, + laser cannon at 1<<23 for mg3
    hipnotic              IT_*   8 + Mjolnir (1<<7) + proximity gun (1<<16)
    rogue                 RIT_*  a DIFFERENT axe bit + 5 new weapons

So the bits, model names, pickup names and labels all become per-game tables
chosen by the `standard_quake`/`rogue`/`hipnotic` globals, rather than one
table with entries appended. Slot COUNT must then cover the largest game
(rogue reaches 13), which makes the Swift stride `variant * 8` wrong by more
than one and the `.v4` persistence migration correspondingly larger.

Do this as a designed change with its own document, not as an increment. The
device test is already described below and detects exactly this: a count per
game, with vanilla the case that catches a leak.

### How to TEST the wheel, which already exists

`Documents/id1/autoexec.cfg` holds exactly:

    map range
    impulse 9

That is the devtest rig: load the test range, grant every weapon. It fires on
startup AND on every `game` change, which makes it the harness this work
needs rather than the nuisance it was mistaken for earlier the same day (it
was stomping deliberate `map` commands during episode testing, and was twice
recommended for removal -- do not remove it).

`range` lives in `id1/pak2.pak` and stays reachable from every game, because
id1 remains in the search path beneath whatever mod directory is selected.

So the three cases come for free, and the expected answer is a COUNT, which is
why this catches the bit collision rather than merely exercising it:

    game id1        -> wheel shows 8   (vanilla)
    game mg3        -> wheel shows 9   (+ laser cannon)
    game hipnotic   -> wheel shows 11  (+ Mjolnir, + proximity gun)

The vanilla case is the important one, not the control. `impulse 9` in stock
Quake grants `IT_SUPER_LIGHTNING`, which is the very bit Mjolnir collides on,
so a naive implementation shows NINE weapons in vanilla and that is the
failure announcing itself. Admin's "All weapons + ammo" button sends the same
`impulse 9` if the rig is wanted mid-session.

### Performance sweep: the maps to measure, and how

The renderer already prints what is wanted, once every 300 frames:

    [immersive] 93.8 fps over 300 frames, gpu avg 6.76 ms worst 23.14 ms

It is a raw `print`, so it reaches stdout rather than the in-headset console.
`tools/run-device.sh` launches with `--console` and streams stdout to its log,
so a session started that way captures the whole sweep for later parsing. Note
the WORST column rather than only the average: a 90 Hz frame budget is 11.1 ms,
and the figure above already shows a 23 ms spike on a vanilla map.

Sizes span two orders of magnitude, measured from the paks on 2026-10-28:

    e1m1        1.3 MB  v29    vanilla baseline
    hip1m3      2.1 MB  v29    Scourge of Armagon, biggest
    r2m7        2.2 MB  v29    Dissolution of Eternity, biggest
    e5sm1       3.5 MB  BSP2   Dimension of the Past, biggest
    mg3 hub     3.7 MB  BSP2
    mg3 start   7.7 MB  BSP2
    mg3 map1   12.5 MB  BSP2
    mg1 hub    31.4 MB  BSP2   Dimension of the Machine, biggest
    mg3 map6   30.3 MB  BSP2
    qbj3_jm   122.7 MB  BSP2   Brutalist Jam III, biggest (A. reports a
                               definite performance hit here, 2026-10-28)

The official content tops out around 31 MB, so anything above that is
third-party and not release-blocking. The useful question is where inside the
official range the frame budget starts being missed, because that is the range
release 1 has to hold.

### Should we move to Ironwail? Measured 2026-10-29: NO. Raise one constant.

Asked because several third-party packs say they require it. The answer is
evidence rather than taste.

Ironwail is a QuakeSpasm fork, so the lineage matches: all 47 of our vendored
`.c` files exist there. The structure its GPU renderer removed, `glpoly_t`, is
touched in only SIX places across qr_bridge.c's 8,590 lines, and its
`msurface_t` still carries `vbo_firstvert`, the field we set. So a migration
would be mechanically thinner than it sounds.

It is still not worth it, because the limits are nearly identical:

    MAX_EDICTS           32000   32000
    MAX_MODELS            4096    4096
    MAX_STATIC_ENTITIES   4096    4096
    MAX_DLIGHTS             64      64
    MAX_VISEDICTS         4096   16384   <- the only meaningful difference

One constant. Raising `MAX_VISEDICTS` to 16384 buys what "requires Ironwail"
actually refers to, for one line, with no migration at all.

The reason the gain is so small is that we already took the thing Ironwail
exists for. Its value is its renderer -- GPU-driven culling, a rewritten draw
path -- and this project did not vendor QuakeSpasm's renderer either:
`gl_rmain.c`, `r_world.c`, `r_alias.c` and the rest were replaced by Metal.
Migrating would mean inheriting a renderer to throw away immediately, while
re-porting six engine hunks, reworking `r_null.c` against a different `gl_*`
API, redoing UPSTREAM.md's provenance and carrying 88 files instead of 47.

It also explains why Brutalist Jam III ran despite its own warning: that
warning is about ceilings, not features, and ceilings are one-line changes.

**What would flip this:** a pack needing an Ironwail FEATURE rather than a
ceiling -- an extended protocol or a QuakeC builtin. No evidence of that yet.
If it happens, port the feature, not the engine.

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
