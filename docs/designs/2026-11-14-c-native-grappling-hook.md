# A C-native grappling hook -- design

Written 2026-11-14. Supersedes the mechanism (not the feel) of
`Sources/QuakeCore/platform/grapple_avp.c` as shipped in 7d51933.

Scope set by A. on 2026-11-14: the hook moves off rogue's compiled QuakeC and
into platform C, so that one hook serves all six games, the gun stays in the
player's hand through a swing, and the rope leaves the off hand. The swing
itself does not change.

## Why, in one paragraph

The hook that ships today is not an implementation, it is a driver for rogue's
progs. To throw it, `Grapple_Engage` (`grapple_avp.c:842-854`) writes
`player->v.weapon = GRAPPLE_ITEM_BIT` (`1<<23`, `grapple_avp.c:66`), calls
rogue's `W_SetCurrentAmmo` so the drawn gun becomes `v_grpple.mdl`, and raises a
synthetic held `+attack` through `Key_Event (K_RSHOULDER, ...)`
(`grapple_avp.c:431-437`) so that rogue's own `W_FireGrapple` runs on the server's
next frame. Three things A. wants are each blocked by that one mechanism, and all
three come free once it is gone.

1. **The hook cannot be in the other hand.** While it is out, the player's
   `.weapon` *is* the grapple and `cl.viewent` is `v_grpple.mdl`. There is no gun
   left to hold in the dominant hand, and any other weapon write cancels the
   swing outright (`grapple_avp.c:927-941`).
2. **The hook cannot exist in the other packs.** `grapple_supported`
   (`grapple_avp.c:400-405`) requires six things out of the loaded progs:
   the functions `W_FireGrapple`, `GrappleReset` and `W_SetCurrentAmmo`, and the
   field offsets `hook_out`, `on_hook` and `hook`. Only `W_SetCurrentAmmo` exists
   outside rogue. In id1, hipnotic, dopa, mg1 and mg3 the button is correctly
   inert and does nothing at all.
3. **The bit is a landmine.** `1<<23` is `HIT_LASER_CANNON` under hipnotic
   (`Sources/QuakeCore/engine/quakedef.h:182-185`) and is also mg3's and
   hipnotic's laser cannon in the wheel's own rows (`qr_weapons.c:359`, `:405`).
   Today `grapple_supported` is the only thing stopping that write from landing
   somewhere it would hand the player a laser cannon. Any design that loosens
   that gate without removing the write is a bug waiting on a date.

Taking the progs half into C removes the `.weapon` write, the synthetic
`+attack`, the bind assertion (`Grapple_AssertBind`, `grapple_avp.c:359-366`),
the progs-function resolution, the `pr_crc` invalidation dance
(`grapple_avp.c:209-221`, `:368-375`) and the six-condition gate. What is left
is a rope, an anchor and the pendulum that A. already called perfect.

## Goals

- One hook, identical in id1, hipnotic, rogue, dopa, mg1 and mg3, asking of a
  pack's progs exactly one thing: `T_Damage`, and degrading to a hook that does
  no damage if even that is missing. See the damage decision below for why that
  is a different order of dependency from the six rogue-only things it replaces.
- The dominant hand keeps its gun, drawn and firing, for the whole engagement.
- The rope leaves the off hand, visibly, from the fist itself.
- Feel parity with 7d51933. The pendulum, the reel, the length-scaled haul, the
  gravity compensation, the friction borrow, the pause guard and every cancel
  path are reused unchanged. **The chained-swing rhythm is part of the feel and
  has to be reimplemented, not just preserved:** the automatic re-throw while
  the grip stays held after a miss or a timeout is currently rogue's
  `W_FireGrapple` re-firing on its own, so it is a behaviour that disappears
  silently with the progs path unless it is rebuilt deliberately.
- Zero new game assets, and nothing added to any pak.

## Non-goals

- A held weapon model for the hook. A. does not care about the gun model that is
  notionally firing the hook, and with the `.weapon` write gone there is no
  longer one to show. The off hand shows the existing virtual hand.
- A second *drawn weapon*. A. chose rope-plus-live-gun first and a real second
  weapon later as its own milestone, so the extraction of the hand-weapon draw
  path (`qr_bridge.c:7822-8032`), a second laser and reticle vertex range
  (`QuakeCore.h:480-481`, `:499-500`) and a per-hand entity flag are all out of
  scope here and are what that later milestone is made of.
- ctf. Still out, per `docs/designs/2026-10-30-per-game-weapon-tables.md:363-370`.
- Replaying a swing in an in-app export. A. put this out of scope on 2026-11-14,
  as a follow-up. Consequence, stated rather than discovered: the hook is
  client-side state, so during `playdemo` nothing exists (`sv.active` is false
  and `Grapple_Player()` returns NULL), and a swing therefore will not appear in
  footage produced by `DemoExporter` until the sidecar records the simulation
  result. That is a `.vrtrack` v2, not a second input ray: `VRTrack.swift` is
  version 1 with a fixed 20-float record, and the anchor, the rope state and the
  hook-head position all have to be written, with v1 files still replaying.
  Device capture is unaffected and remains the route for interaction footage.
- Shipping any pack's data. The payload guard (`Makefile:28-35`) refuses it and
  that is correct.
- Retuning the swing. The eleven `vr_grapple_*` cvars keep their current
  defaults and meanings.

## Anti-goals

Things that would make this a failure even if it worked:

- **A seventh patched engine hunk.** The tree has exactly six
  (`UPSTREAM.md`, `docs/working-notes.md`). This design is built to add none,
  and the rope is drawn render-side specifically so that the vendored
  `cl_tent.c` beam relocation does not have to learn to tell a rope from a
  lightning bolt.
- **A per-pack code path.** If the answer involves `if (rogue)` anywhere, the
  mechanism is still asking the game for something and the work is not done.
- **A feel regression.** A. has said twice that the swing is right. A change
  that improves the architecture and costs the feel is a net loss and should be
  reverted rather than tuned around.
- **A model lookup that can kill the process.** `SV_ModelIndex` calls
  `Sys_Error` on a miss and `Sys_Error` calls `exit()`.

## What A. decided, in his words where it matters

Settled 2026-11-14, in this order.

**The hook is a rope out of your hand, not a weapon in it.** "I just want the
rope to spawn from there, the rope or chain to spawn from there as soon as you do
the fist." And, on the model: "You should still see the hook shooting out of your
fist, but you just see the rope go behind it, following it until it hits its
target. I don't care about the gun model for the hook." So the flying hook head
and its trailing rope are both visible; the held weapon model is not wanted and
does not exist any more.

**Dual wield means rope plus live gun, first.** A real second drawn weapon is a
later milestone of its own.

**The bare-hands throw is a closed fist on the off hand.** Chosen knowing it
makes the fist-dropout hand-tracking fix a prerequisite.

**The hook anchors to a monster and hurts it.** This is the one answer that
costs something, and it is taken deliberately. The honest consequence: damage in
Quake is `T_Damage`, a QuakeC function with no engine-side equivalent, so one
progs call survives and `Grapple_FuncByName` cannot be deleted after all.

It is a much smaller dependency than the one being removed, and that is why the
answer is affordable. `T_Damage` is defined in id1's `combat.qc` and every pack
here is id1-derived, so unlike `W_FireGrapple` it is expected everywhere;
confirmed present in A.'s own `id1/pak0.pak` progs by reading the string table.
Two rules keep it from becoming a per-pack branch again. The lookup is
**optional**, exactly as `teleport_time` already is (`grapple_avp.c:228-233`):
if `T_Damage` does not resolve, the hook anchors and does no damage, and nothing
else changes. And the lookup result must never gate whether the hook works, only
whether it hurts. The flight trace is therefore `MOVE_NORMAL` so monsters are hit
at all, and an anchor that is a monster has to survive that monster dying,
gibbing or being freed mid-swing, which means validating the stored edict every
frame and falling back to the last known anchor position rather than reading a
freed edict.

**The weapon wheel may open mid-swing and no longer cancels it.** While the
wheel's time dilation is on, the rope is **held**, not simulated on the slowed
frame time, on the same reasoning as the existing pause guard
(`grapple_avp.c:990-1006`), where two seconds of pause took the player from 393
to 7036 u/s. The grapple numbers were all tuned at full rate and a slowed frame
is the near neighbour of that bug.

**During a bare-hands swing the player has air control only.** The fist
suppresses the off hand's other gestures for the duration. Note the sharp edge:
releasing a fist passes through the ring pinch's release edge, which is the
teleport commit, so the suppression has to **clear edge latches** rather than
merely mask the bits, or every swing ends in a teleport.

## The design

### The hook is client-side state, not a server entity

No `ED_Alloc`, no `setmodel`, no precache, no network traffic. The hook is a
position, a velocity and an anchor held in `grapple_avp.c`, advanced each frame
by `SV_Move` from the code that already runs each frame (`Grapple_Frame`, called
from `IN_Commands` at `in_null.c:1252-1254`). It anchors where the trace stops
short.

Two reasons this is the right shape rather than a shortcut. First, `touch` and
`think` are `func_t` indices into progs, so a C-spawned edict could not be given
C callbacks anyway and would need driving by hand regardless. Second,
`PF_precache_model` refuses outside `sv.state == ss_loading`
(`Sources/QuakeCore/engine/pr_cmds.c:1124-1172`), so a server-side hook entity
would need either a model the pack happens to have precached or a platform-side
injection into `sv.model_precache` during spawn. Owning the hook client-side
makes the whole question disappear.

Where the hook hits a moving entity, the anchor stores that edict and tracks its
origin, which is what rogue's hook edict got for free by being parented.

### The hook head and the rope are drawn Swift-side, with the late-latched hand

My first draft put both in `qr_bridge.c` "on the precedent of the laser sight"
(`qr_bridge.c:7944-7990`). **That premise does not survive the code and the
builder review was right to kill it.** The laser can live engine-side only
because the view weapon is deliberately NOT late-latched, which is the whole
reason it is excluded from the move-lerp by name and the reason a late-latched
gun would separate from its own beam every frame. The off hand is the opposite
case: its visible model is published through `VirtualHand.shared.publish(...)`
and drawn by `RendererCore.drawVirtualHand` in the Swift render loop from the
live render-time pose, so it IS late-latched. A rope emitted engine-side from the
drained off-hand pose would detach from the drawn fist whenever the hand moved,
which is precisely the thing this milestone exists to show.

So: the rope and the hook head are drawn **Swift-side, in the existing
`drawVirtualHand` overlay pipeline**, from the same render-time pose that draws
the fist. The anchor position, the hook-head position and the engagement state
cross from the engine in `qc_frame_t` as new packet fields; the hand end of the
rope is taken render-side so it tracks the fist exactly. This is my call, not
A.'s, and the reasoning is the one above: the rope must share a latch with the
hand it comes out of.

The hook head's model, if it is drawn as an alias model rather than as geometry,
is resolved client-side with `Mod_ForName (name, false)`,
non-fatal, from a candidate list. Because `COM_AddGameDirectory (com_basedir,
GAMENAME)` always mounts id1 first (`Sources/QuakeCore/engine/common.c:2447`),
id1's own models are loadable in every pack regardless of what the current map
precached. Verified against A.'s own `pak0.pak`: `progs/spike.mdl` and
`progs/bolt2.mdl` are both present. Resolve once and keep the pointer rather than
loading at fire time, so that a fire never pays for a model load.

**The rope is not a `TE_BEAM`, deliberately.** `CL_ParseBeam` keys beams on the
entity number and its first loop overrides any beam already held by that entity
(`Sources/QuakeCore/engine/cl_tent.c:76-86`). The rope and the thunderbolt would
both be player-entity beams, so with the gun live during a swing, firing lightning
would replace the rope and every rope refresh would kill the bolt. Drawing the
rope ourselves avoids that, needs no beam slot, needs no network message, and
lets the rope start at the off hand rather than at `QR_HandOrigin`, which the
vendored hunk at `cl_tent.c:313-331` hardwires to the dominant hand.

It also means rogue stops using `progs/beam.mdl`, so **the rope in rogue will look
different than it does today**. A. has been told. The replacement should aim at
rogue's chain rather than at something new, since that is the look A. has been
swinging on.

### A second hand pose has to reach C

`QR_HandOrigin` (`in_null.c:1364-1381`) is the only "where is my hand" function
in the engine and it is hardwired to `qr_aim_org`, the dominant hand. An off-hand
twin is needed beside it, with identical math on an off-hand body-frame offset.

The channel for the pose already exists and is dead: `QC_InputSetTeleport`
(`in_null.c:299-312`) carries org, yaw and pitch, is drained at
`in_null.c:649-653`, and is read by nobody. `IN_Teleport` says so in a comment at
`in_null.c:1600-1606`, and the Swift side passes literal zeros
(`App/Sources/HandInput.swift:957`). The off-hand ray is already computed in
`ingest` and thrown away (`HandInput.swift:949-950`), and the off-hand pose is
already published render-side for the hand model
(`Sources/QuakeRenderer/ImmersiveRenderer.swift:764-786`). Whether to feed the
existing channel or add a dedicated setter is the builder's call; the reserved
channel was named for this and either is defensible.

Known cost, to be stated and not discovered: `App/Sources/VRTrack.swift:33`
carries exactly one aim ray and `DemoExporter.swift:298` replays it, so a second
ray into the engine is a `.vrtrack` schema change if exports have to replay the
rope.

### Input

**Controllers.** Keep the off-hand grip.

There is a handedness bug next to it, and my first draft called it a one-line fix
in passing. It is not, so it is **deferred to its own item** rather than
half-fixed here. That is my call. `GameControllerInput.swift:413` sets
`QC_PAD_RSHOULDER` from the *physically* left controller rather than from
`VRSettings.rightHanded`, so a left-handed player gets the grapple on their gun
hand. But `left` in that file is already name-or-position XOR
`VRSettings.swapSenseHands`, a separate user-facing override, and the same branch
carries the wheel hold, the slow-motion toggle, the prev/next weapon cycle and
recenter. Flipping only the grapple bit lands the grapple and the wheel on one
grip, which the code's own comment says cannot work; flipping the whole branch is
a five-control remap that needs its own device pass and risks double-swapping
against `swapSenseHands`. Fixing it properly means deciding whether
`rightHanded` drives the entire Sense split. That is a real question and it does
not belong inside this milestone's device test.

**Bare hands.** There is no grapple gesture at all today; `HandInput.swift` sets
only two pad bits in the whole file (`:414`, `:418`). A. chose a **closed fist on
the off hand**. The off hand's four pinches are all spent already (index walk
forward, middle walk back, pinky crouch, ring teleport commit), so a fist is a
new gesture class rather than a fifth pinch.

A fist makes the hand-tracking dropout a prerequisite rather than an annoyance:
see the standing note that a closed fist is exactly where joint tracking is lost
and that predicted `handAnchors(at:)` in the render loop is the fix. This design
does not get to assume that is already done. It is also the same unfixed
prediction gap behind the controller-pose slideshow diagnosed on 2026-11-13, so
the two share a fix.

This is in scope, not optional: every interactive feature needs a hands path and
a Sense path, and gamepad-only is a bug.

### What becomes simpler, and should actually be deleted

Not left in place behind a flag. Once the C hook works, `grapple_supported`,
`Grapple_FieldOfs`, `Grapple_AssertBind`, `GRAPPLE_ITEM_BIT`,
`qr_grapple_prev_weapon`, the `W_SetCurrentAmmo` call and the synthetic
`Key_Event` all go. `Grapple_Active()` goes with them: it is exported but has no
callers anywhere, which is incidentally good news for the live gun, since nothing
currently hides the gun or the laser during a swing.

`Grapple_FuncByName`, `Grapple_Call` and `Grapple_ResolveProgs` **survive in
reduced form**, because of the damage decision: one optional `T_Damage` lookup,
re-resolved on a `pr_crc` change for the reason recorded at
`grapple_avp.c:209-221` (`SV_SpawnServer` reloads progs at the same hunk address,
so a pointer key never invalidates, and reading one game's field offsets out of
another game's edict was a measured SIGSEGV). The same bug is still latent in
`admin_avp.c:57` and is not this work's to fix.

Keeping rogue's path as a fallback would preserve
every problem this design exists to remove, and would reintroduce the per-pack
branch named as an anti-goal.

`QC_WEAPON_GRAPPLE` (`QuakeCore.h:797`) should stay as an identity. It is in no
game's row and never was (`qr_weapons.c:416-424`), and the ring is not how the
hook is reached.

## Constraints the builder does not get to trade away

- `Sources/QuakeCore/engine/` is vendored QuakeSpasm 0.97. Six patched hunks,
  all listed in `UPSTREAM.md`. Prefer a shim in `platform/`. This design is
  built to add none, and if a seventh looks necessary, that is a signal the rope
  or the pose went to the wrong layer.
- `make check` after every C change, and say that it is a host compile and not a
  visionOS build.
- Everything `QC_*` runs on the engine thread except the documented any-thread
  setters. `QC_Renderer*` is the render thread's half and only inside
  `withConsumer`.
- Audio and the immersive space need a detached launch, no lldb.
- Numeric acceptance criteria pass on a black screen. At least one criterion per
  step has to be unable to pass unless something visibly correct is on screen.
- If the sim rate is ever in question, watch the gun and not the fps tile.

## Order of work, and how each step is judged

The order matters because the acceptance test for step 1 is feel, feel is
device-only, and changing the hand in the same device session would confound it.

1. **C-native hook, dominant hand, in `gym`.** Replace rogue's progs path
   outright. Judged by feel parity against 7d51933, on device, plus a host
   harness run proving the trace anchors and that `player->v.velocity` changes.
2. **Move the throw to the off hand**, gun drawn and firing throughout. Includes
   the `QR_OffHandOrigin` twin, the second pose into C, and the
   `GameControllerInput.swift:413` handedness fix.
3. **The bare-hands fist**, with the hand-pose prediction it depends on.
4. **All six packs**, with a one-line console print naming which hook model was
   resolved, because "every id1-derived progs has the model" is a prediction
   until mg3, dopa, mg1 and hipnotic have each actually run through it.

Step 4's print is the cheap observation that would refute the prediction, which
is the standing rule after the hook-spawns-at-the-chest miss: a claim that an
existing mechanism already covers a new case is a prediction, not a finding,
until the new case has run through it.

Host harness notes, so they are not rediscovered: `tools/hostmain.c` runs ten
frames and anything with a ramp needs 30 to 40; link a driver against
`$TMPDIR/quakecore-hostbuild/*.o` minus `hostmain.o`; drive the throw by setting
`QC_PAD_RSHOULDER` through `QC_InputSetGamepad`; `+map gym` via `stuffcmds` beats
the attract loop where a bare `map` command loses to `startdemos`.

## Left to the builder

- Whether the second pose feeds the reserved `QC_InputSetTeleport` org/yaw/pitch
  channel or a dedicated `QC_InputSetOffAim`. Note that the pose is still needed
  engine-side even though the rope is drawn in Swift, because the throw ray has
  to be traced where the physics lives.
- The exact shape of the new `qc_frame_t` fields carrying the anchor, the
  hook-head position and the engagement state, and whether the hook head is an
  alias model or generated geometry.
- The candidate list and order for the hook head model, and what the rope is
  built from geometrically.
- Whether the swing's attachment point stays body-centred. It is
  `player->v.origin` with `z -= GRAPPLE_ROPE_UP` (16) today
  (`grapple_avp.c:710-711`), which is hand-agnostic and probably correct, since
  the rope pulls the body and not the wrist. Changing it is a feel change and
  belongs in its own device test if it happens at all.
- Whether the flight keeps the current `vr_grapple_speed 9000` and
  `vr_grapple_range 24000`. A. was asked whether the reach should stay and did
  not say otherwise, so treat keeping them as the default.
- Whether an anchor sound is worth adding. `weapons/tink1.wav` is in id1 and
  would be available everywhere by the same search-path argument.

## Two stale comments to fix in passing

- `tools/range/gengym.py:23-26` and `tools/range/genrange.py:179-182` both size
  the gym's column spacing against `vr_grapple_range 1600`. The shipped default
  is 24000; 800 and 1600 were rogue's originals and were abandoned
  (`grapple_avp.c:84-89`).
- `tools/range/gengym.py:275` says the grapple is reached through the ring. It
  is not on the ring in any game and never was.

## Also owed, and not part of this

`tools/range/README.md` is missing `-subdivide 480`, which is load-bearing:
following the README literally produces a map over `MAX_MAP_LIGHTING`.
`Grapple_ForceDefaults` (`grapple_avp.c:1050-1063`) comes out when the numbers
settle, at which point the cvars go back to `CVAR_ARCHIVE`.
