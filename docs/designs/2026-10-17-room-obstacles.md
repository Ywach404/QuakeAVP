# Real furniture, solid to monsters — design

Status: proposed, 2026-10-17. Not built. Depends on
`2026-10-17-phase-floor.md`: the boxes stand on the Quake floor,
and that floor must be the real floor first.

## Intent

The showcase moment: the world is phased out, a grunt is coming at you
across your living room, and you push the ottoman into its path. It stops,
goes round, and if you are behind the sofa it has to come round that too.
The real room shapes how the enemies move.

## What the engine gives for free

Verified against `Sources/QuakeCore/engine/world.c`, `sv_move.c`,
`pr_cmds.c` and `pr_edict.c`.

Quake monsters have no pathfinding. `SV_movestep` tries a step and asks
the collision system whether it fits; when it does not, `SV_NewChaseDir`
tries the eight compass directions in turn until one works. Collision
comes from `SV_Move`, which clips against the level and against every
linked entity whose `solid` is not `SOLID_NOT`. The clip loop reads only
`solid`, the absolute box, `size`, `owner` and the monster flag. It never
looks at a classname or a model. So an entity that is nothing but a
`SOLID_BBOX` with `mins`, `maxs` and `size` set is a wall to a walking
monster, to a projectile, to the player's hitscan and to the player's own
head-follow trace, and the monster walks round it with the behaviour it
already has.

Such an entity is never sent to clients: `SV_WriteEntitiesToClient` skips
anything with no model index. It costs no bandwidth and draws nothing.

One thing the engine does not give. The monster's sight test, `visible()`
in the game code, calls `traceline` with the no-monsters flag, and under
that flag `SV_ClipToLinks` skips every entity that is not `SOLID_BSP`,
not just monsters. So out of the box the grunt cannot reach you behind the
sofa but knows you are there and keeps firing. That split is addressed
below as a decision, not papered over.

Platform code has never allocated a server entity. Everything it does
today moves or reads existing ones. This would be the first `ED_Alloc`
outside the engine, and the rules it has to follow are in the mechanics
section.

## Goals

- Furniture at and above seat height blocks monster movement, projectiles
  and shots while the world is phased out.
- Boxes appear when phase starts and vanish when it ends, with enough lag
  that a quick phase toggle does not churn them.
- Moving a real object moves its box within the time scene reconstruction
  takes to notice, a few seconds.
- No engine edits for the movement half. The sight half is one decision.

## Non-goals

- Making the level's own walls match the room's walls.
- Real walls blocking monsters. Off by default. Most levels are larger
  than the room, and a room-sized cage round the player changes every
  encounter, not just the one with the ottoman. A cvar can turn walls on
  for players who want the cage.
- Furniture that is solid while the world is not phased. The level and
  the room would fight for the same space.
- Monsters standing on furniture.

## Anti-goals

- A monster trapped in a pocket between a sofa and a level wall,
  oscillating. Boxes must stay convex and coarse enough that the eight-way
  search finds a way out.
- Boxes that persist into a saved game as nameless solids. A save taken
  while phased must not come back haunted.

## The design

### Sense the room

Run a `SceneReconstructionProvider` with classification in the sensing
session the floor design creates beside plane detection, not in the
world-tracking session, so a refused permission cannot take head tracking
down. Mesh
anchors arrive in the raw tracking frame as chunks of roughly a metre.
Each face carries a class: floor, wall, ceiling, table, seating, window,
door, stairs, bed, plant, screen, unknown.

### Voxelize what matters

Per mesh update, rasterize faces into a horizontal grid of 0.25 m cells
over a column from the measured floor plus 0.05 m up to 1.2 m. A cell is
occupied if any face of an included class crosses it. Included by default:
seating, table, bed, stairs, unknown. Excluded by default: floor, ceiling,
wall, window, door, screen, plant. The include list is a cvar string so
the defaults can be argued with from the console.

Merge occupied cells into axis-aligned boxes by run-length along one axis
then the other, in the raw frame. Cap the result at 256 boxes; past that,
drop the smallest. Publish the box list through a new any-thread setter in
the shape of `QC_SetWeaponPlacement`: a fixed array under a mutex, whole
table replaced each time.

Each box is published as a horizontal rectangle in the corrected room
frame (metres, after the recenter correction, the same frame the hands
use) plus a bottom and top height in metres above the measured floor.
Horizontal and vertical are published in different references on
purpose. The room frame to Quake frame mapping is re-derived every frame
from the player's view origin and body yaw and changes on every turn and
teleport, so horizontal is converted on the engine thread each tick, with
the same arithmetic `QR_HandOrigin` uses: the box's offset from the
head's room position, scaled into units and rotated by the body yaw, added
to the view origin. Vertical is placed against the player's hull bottom,
`origin_z - 24`, which is the Quake floor the player stands on and the one
the floor design puts on the real floor. The measured floor height itself
never has to reach the engine; the publisher subtracts it.

### Place them on the engine thread

A pool of up to 256 entities, allocated once per map with `ED_Alloc` from
`IN_Commands`, which is where the other engine-thread input work already
runs, under the same `sv.active` and client-active guards
`IN_AbsorbHeadOffset` uses. Each is `SOLID_BBOX`, `MOVETYPE_NONE`, no
model, no think, with `classname` set to an engine string
`"qavp_obstacle"` so it can be found again. Every tick while phase is
active, for each published box: convert the room-frame corners to Quake
units in the body basis through the same arithmetic as `QR_HandOrigin`,
take the axis-aligned bounds, write `origin`, `mins`, `maxs` and `size`,
and `SV_LinkEdict`. Unused pool entries are set `SOLID_NOT` and unlinked,
never freed: a freed slot is refused for half a second of server time and
the pool would churn.

### Make furniture a wall, not a step

A monster steps over anything lower than 18 units, 0.46 m, which is seat
height. Every box's bottom is pushed down to 8 units below the floor and
its top raised to at least 32 units above it, so a sofa reads as a wall
to the step logic. Its horizontal extent is the voxel extent, so a
monster that would have passed beside it still does.

### Never box the player in

A player sitting on the sofa, or standing where a moved ottoman's ghost
still lingers in the mesh, would start inside a box the moment phase
begins. The engine does not refuse that like a wall; it freezes the body:
`SV_FlyMove` zeroes velocity for an entity that starts inside a solid,
and the head-follow trace never advances. So on the engine thread, any
box whose bounds intersect the player's hull expanded by 16 units is set
`SOLID_NOT` for that tick. Step off the sofa and its box returns. The
sofa stops monsters while you stand beside it and lets you sit on it,
which is the showcase both ways. The voxelizer does not need to know
where the player is; the pool does, and it already runs with the player
entity in hand.

### Single player only

Boxes are server entities shaped like one room. A guest connected to a
hosted game would walk into invisible walls shaped like the host's
living room, and the host joining a desktop server would get no boxes at
all. The pool is gated on `svs.maxclients == 1` beside the `sv.active`
guard. Lifting that for co-op is a later decision.

### Phase gating

Boxes are solid while the phase target cvar is above zero, read directly
on the engine thread. When it drops to zero they stay for one second,
then go `SOLID_NOT`. When it rises they appear as soon as the next mesh
update lands, which is the same moment the room becomes visible.

### Saves and map changes

`sv.edicts` is reallocated on every map change, so the pool is rebuilt
from nothing each map. On load game the pool first walks the entity list
for `"qavp_obstacle"` classnames and reclaims them, so a save taken while
phased comes back with its boxes owned again, and the next phase-off
clears them.

### Sight

Option A, ship first: accept that monsters see through furniture. They
cannot reach you, which is the showcase, and a grunt firing at a sofa is
not wrong in Quake's terms.

Option B, the seventh engine patch: in `SV_ClipToLinks`, let the
no-monsters skip pass an entity flagged as an obstacle, so `traceline`
with no-monsters stops at the sofa. One line inside the existing guard,
under `QAVP_PLATFORM`, in the file that already holds the hunk count's
argument: it corrects the thing at its source, nothing downstream can do
it, and it is read by every sight check in every game. The flag is a
spare bit in `v.flags`. This is the version where hiding behind the sofa
works.

The decision is A.'s; the recommendation is to ship A, then add B once
the boxes are seen behaving on device, because B is the one piece that
cannot be reverted by a cvar.

## Risks

- Scene reconstruction lags a moved object by seconds, and leaves a ghost
  of its old position for a while. Expect the ottoman to be solid in two
  places briefly. The cap and the merge keep that cheap; it cannot be made
  instant.
- Classification is imperfect. An ottoman may come back `unknown`, which
  is included, or `floor`, which is not. The include list is the tuning
  surface.
- The player's own head-follow trace respects the boxes. Leaning over a
  real table while phased is refused, like leaning into a level wall.
  That is correct and may surprise.
- Entity count: 256 boxes against `max_edicts` 8192 is nothing; the cost
  is in `SV_Move` visiting more links. Keep boxes coarse.
- World sensing permission is a new prompt, shared with the floor design.

## Verification

Host: a unit test drives the voxelizer with synthetic faces and asserts
box counts, merge results and the step-height padding. A second test
exercises the pool against a booted engine on the registered pak data:
allocate, place a box between a spawned monster and the player, step the
server, and assert the monster's origin went round rather than through.
`tools/range` is the precedent for a host test that loads a map and
asserts on world state.

Device, the one that cannot pass on a black screen: phase out, stand with
a sofa between you and a grunt, and watch it come round the end of the
sofa. Then push an ottoman into its path and watch it stop and reroute.
Record it.

## Decisions made here

- Boxes, not meshes. Quake collides with boxes natively.
- Horizontal published in the corrected room frame and converted on the
  engine thread every tick, because the mapping moves; vertical published
  above the measured floor and placed against the hull bottom, so the
  floor measurement stays render-side.
- Boxes intersecting the player's hull are suppressed for the tick.
- Single player only for now.
- Walls off by default.
- Sight is a separate decision with a recommended order.
- First platform-side entity allocation, pooled, never freed per update,
  reclaimed by classname after a load.

## Left to the builder

- Grid cell size and column height, within the stated ranges.
- The merge algorithm's axis order.
- Hysteresis timings.

## For A.

- Sight: A then B, or B from the start.
- Whether unknown-class geometry is included by default. This design says
  yes, because an unclassified ottoman is the whole demo.
