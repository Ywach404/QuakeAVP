# Decision log

Running record of design choices and *why*. Roughly chronological. A decision
belongs here when someone could reasonably have chosen otherwise and the reason
isn't obvious from the code.

---

## 2026-10-01 — Hand aim is the forearm alone; the finger blend is gone

**Choice.** `aimDir` is the forearm bone (elbow joint → wrist joint) and nothing
else. The wrist→knuckle-centroid component and the `aimBlend` / "Aim finger-mix"
slider that mixed it in are deleted, along with the orange debug line that drew
it.

**Why.** The blend existed to pick up wrist flex, so pointing the hand down
aimed down. But it was built from the knuckle joints, and ARKit abandons those
under exactly the occlusion a shooting pose creates — the same discovery that
broke the prayer sign (`visionos-hand-gestures.md` §1). The component therefore
did not degrade gracefully, it *vanished mid-gesture* and took the aim with it
in a visible jump. A blend whose input intermittently disappears is worse than
the steady input alone. Forearm-only was tried on device and is materially more
consistent.

**Cost accepted.** No wrist-flex aiming: the gun points where the forearm
points, so aiming down means dropping the elbow, not breaking the wrist.

## 2026-10-01 — One aim-height trim, not two

**Choice.** `vr_aimpitch` carries the entire aim-height correction, default 8.
The hidden `aimPitchTrimDeg = 8` constant in `HandInput.feedAim` is deleted.

**Why.** Two knobs for one quantity, one of them invisible: the effective trim
was `8 + slider`, so the number on screen never matched the correction being
applied and could not be reasoned about. Two knobs for one quantity, one of
them invisible: there must be exactly one definition of a correction.

**Migration.** `InputProfile` gained a `schema` marker; profiles written before
this fold the 8 into their stored `aimPitch` once on load. Without it, an
existing profile pushes `vr_aimpitch 0` and the aim silently rises 8 degrees.

---

## 2026-09-30 — Unit selection picks in Swift, engine only classifies

*Designed ahead of the build: the packet fields and the selection core
described here are not in the tree yet. The enemy-targeting feature is on the
roadmap; this entry records the design it will follow.*

**Choice.** For the Fable II-style soft-target lock-on, the engine publishes two
new per-entity fields in the frame packet — a stable `id` (the entity number,
which the server already keeps stable) and a `selectable` flag set for live
monsters. The cone-picking logic then lives in a **pure Swift value type** over
those reduced facts. The renderer highlights the entity whose id matches the
selection itself, so Phase 1 adds no cross-thread traffic at all.

**Rejected: picking engine-side in C.** `qr_bridge.c` already walks the visible
entities each frame and holds the aim ray, the edicts, and the only knowledge of
what counts as a monster. Picking there would have been roughly 100 lines, no
packet change, and `make check` would cover it.

**Why the Swift side won.** The selection core is engine-agnostic by design.
The actions (kill, infight) are Quake/progs specifics; the layer above —
*cone → candidate set → pick → stable id → highlight* — has no Quake in it at
all. As a pure Swift type with no engine or ARKit dependency it stands on its
own, and its fiddly parts (hysteresis, tie-breaks, cycling) get host tests via
`swiftc` instead of a device round trip. That matches the pattern established
the same day by `PrayerPose`/`GestureDwell` (see
`visionos-hand-gestures.md` §3).

**Cost accepted.** Two extra packet fields, and the picking is one layer removed
from the data it selects over.

**Structure.** Hard seam between the *selection core* (modality, candidates,
identity, highlight, selection state — engine-agnostic) and the *engine
adapter* (what a unit is, what can be done to it). Split into phases:

- **Phase 1** — selection core. Point, highlight, selection persists across
  frames and survives the target moving.
- **Phase 2** — actions and attribute toggles (the progs VM work: `ED_FindFunction`,
  set globals, `PR_ExecuteProgram`; infighting started faithfully by applying
  damage with another monster as the attacker). Designed *after* Phase 1 has
  been felt on device, because how selection feels will change what actions
  want to be.

Selection modality chosen: **soft-target cone** (nearest valid enemy within a
cone around the aim, hysteresis to stop flicker between two grunts, flick to
cycle). Forgiving in VR where holding a precise ray is hard, and it needs no
ray/AABB intersection — just angle tests against entity origins.

---

## 2026-09-29 — The console summon is the prayer sign, not palm-up

**Choice.** A two-handed prayer sign opens the console window. The original
aim-hand palm-up dwell survives only as a Comfort-menu fallback, labelled in the
UI as the compromised option.

**Why.** visionOS *reserves the open palm*: palm toward the face raises the Home
View dot, palm away raises the status bar into Control Center.
`.persistentSystemOverlays(.hidden)` is a preference the system overrides when
the user looks and pinches, so a palm-up gesture permanently competes with the
OS. Prayer holds both palms edge-on to the face — a pose the system makes no
claim on. Detail in `visionos-hand-gestures.md` §2.

**Also chosen:** open-only, not a toggle. The sign summons the window; it never
dismisses it.

## 2026-09-29 — The sign's "palms face each other" check was dropped

**Choice.** `PrayerPose.matches` tests gap, opposed normals and fingers-up. It
does *not* check that each palm faces the other, so hands held back-to-back
would also register.

**Why.** That check needs the sign of the palm normal, and the device
contradicted every convention derived on paper — it reported the normals
pointing apart (dot −0.90, rock steady) through a genuine held sign while every
other condition passed. The guard defended against a pose (fingers up, backs
touching, inside 16 cm) that does not occur while playing, and it was the only
thing standing between a correct detector and a working one. Restorable later:
100+ logged samples say negating the normal *and* the across-palm axis flips
`toward` to +0.89 while leaving `forward` correct.

## 2026-09-29 — Input moved off the view; console became a `Window`

**Choice.** `HandInput` and `GameControllerInput` are owned by `InputHost.shared`
for the life of the app, and the console is a unique `Window` scene rather than
a `WindowGroup` with manual presence counting.

**Why.** Both were load-bearing bugs, not cleanups. Input in `@State` died with
the window, so closing the console killed *all* input including controllers —
fatal for a gesture whose only job is recovering the window. And `.onDisappear`
does not fire when a visionOS window closes, so the duplicate-prevention counter
only ever incremented and suppressed every summon after the first. Detail in
`visionos-hand-gestures.md` §5 and §6.

## 2026-10-04 — The vendored tree took a fourth hunk, for the lightning beam

**Choice.** `cl_tent.c`'s `CL_UpdateTEnts` now calls `QR_HandOrigin` to start
the player's own lightning beam, falling back to upstream's
`cl_entities[cl.viewentity].origin` when the hand aim isn't live. Guarded by
`#ifdef QAVP_PLATFORM` with the original line preserved in the `#else`, so an
upstream merge re-applies one hunk rather than reading a rewrite.

**Why.** Upstream overwrites the beam's start every frame, unconditionally,
because on a flat screen the gun *is* the player's centre. In the headset the
gun is in your hand roughly 24 units away, so the bolt erupted out of the
player model's chest while the barrel it supposedly left pointed somewhere
else.

**Why not a shim.** The other three departures from upstream were absorbable
because something downstream could be intercepted: `R_RenderView` is ours, so
the paused refdef recompute lands there; the audio listener basis is ours, so
the head overwrite lands there. This one has no such seam. The override runs
inside the beam loop before anything leaves the function, and the entities it
feeds are ordinary `bolt.mdl` alias entities with no marker distinguishing them
from any other model in `cl_visedicts`. Catching them later would mean
pattern-matching on a model name.

**Known approximation.** `CL_UpdateTEnts` runs before `V_CalcRefdef`, so
`QR_HandOrigin` reads the previous frame's `r_refdef.vieworg` — one frame of
head motion, a unit or two, against the ~24 the body origin was wrong by. The
beam's *end* still comes from the server's trace, which still originates at the
body, so the drawn bolt is the arm's parallax away from the damage ray. That is
the same approximation the hand-anchored weapon model already makes.

## 2026-10-04 — My own missiles are drawn onto the bore line, perpendicular only

**Choice.** `CL_RelinkEntities` hands every relinked origin to
`QR_ProjectileViewOffset` (fifth vendored hunk). For missiles the local server
says I own, the component of (hand − spawn) **perpendicular to the aim** is
added to the drawn origin, folding away over the first `vr_projconverge` units
of travel (default 96). `vr_projhand 0` turns it off.

**Why perpendicular only.** The along-aim part of the offset is not an error. A
rocket covers ~11 units in the frame it is born, so by the time anything can
draw it, it genuinely *is* downrange of the muzzle. Cancelling that would make
the first frames of flight look slow — inventing an artifact to fix one. The
perpendicular part is the whole of what reads wrong: the shot not leaving the
barrel. A host probe confirmed the drawn position sits exactly on the bore line
at spawn, that the weight falls monotonically, that it never overshoots the
server's own offset, and that past the converge distance the drawn path is the
server path exactly.

**Why it folds away.** A constant shift would fly a line parallel to the real
one and explode a hand's width from where it appeared to be going. The weight
follows the *furthest* the missile has been from its spawn rather than its
current distance, so a grenade bouncing back toward you cannot make the shift
grow again, and a 0.5 s age cap retires a grenade that comes to rest short of
converging.

**Why a vendored hunk, when the beam's shim argument said to avoid one.** This
one is the opposite case to `cl_tent.c`'s: there are *three* consumers, not
none. The muzzle-flash dlight, `R_RocketTrail` and the emitted model all read
`ent->origin` within thirty lines of the assignment. Correcting it once at the
assignment is the only way they agree. Our own code could reach the model (the
bridge emits it) and the dlight (`cl_dlights` is walkable after relink), but
not the trail: `R_RocketTrail` is ours yet receives only two positions, and the
bridge runs *after* the trails for that frame, so any table it built would be a
frame stale — wrong for a projectile that is only offset for two frames.

**Known cost.** The drawn missile disagrees with the one the server collides
with, by up to the perpendicular offset, for the first ~0.1 s of flight. The
convergence introduces about 7° of curve at the default distance for a 12-unit
miss, which is why the distance is a cvar and not a constant.

## 2026-10-04 — Three fixes to the missile shift, found from one symptom

**Symptom.** On device, the grenade launcher and both nailguns flung their
projectile *models* around — snapping to the aim beam — while the projectiles
themselves went where they should. The rocket launcher looked correct.

**That weapon split was the diagnosis.** The shift's slot table retired a slot
only when a *visited* missile converged. A missile that dies before converging —
a nail into a near wall, any grenade that explodes — is never visited again, so
its slot leaked, holding its edict number, shift vector, spawn point and
accumulated travel. When the server handed that number to the next missile, the
new one inherited all of it. Rockets escaped because at 1000 u/s they almost
always clear the converge distance before dying, so their slots retired cleanly.
Nothing about the fast weapons was special except how often they die early.

**Fix 1 — sweep every frame.** Release any slot whose edict is no longer a live
missile of mine. `CL_RelinkEntities` calls us every frame regardless of what
exists, and `ED_Alloc` will not reuse an edict for 0.5 s, so a per-frame sweep
always wins the race. A host probe reproduces the inheritance on the old code
and shows it gone on the new.

**Fix 2 — fold on travel *or* age.** The weight followed travel alone, so a
grenade that came to rest froze mid-fold, sat about 9 units from its real
position, and then teleported when the age cap fired: a 9.2-unit jump in one
frame, measured. Taking the minimum of the travel and age weights converges it
smoothly instead — 0.8 units per frame worst case at 90 Hz. The age cap came
down from 0.5 s to 0.25 s with it: the shift exists to cover a launch, and
nothing may sit visibly misplaced for half a second.

**Fix 3 — only shift a missile caught at birth.** Capture compares the current
hand against the missile's position, so a missile first seen well clear of the
player yields an offset that is mostly its own flight rather than the launch
error — a model teleport, not a correction. Capture now requires the missile be
within `QR_PROJ_BIRTHDIST` of the player.

**Lesson.** The numeric acceptance criteria in the previous commit all passed:
on-bore at spawn, monotonic weight, no overshoot, exact convergence. Every one
of them was about a *single* missile in isolation, and all three bugs were about
missiles in sequence. The probes that found them had to model a frame loop with
death and reuse, not one flight.

## 2026-10-04 — The missile shift moved to the spawn, and the hack came out

**The symptom was the design.** On device, every projectile except the
lightning gun left the muzzle of the gun and then, shortly after, self-corrected
back to the body line. That was not a bug: the client-side shift folded away over
the first ~96 units so the explosion would not land a hand's width from the
model. The trade was a visible drift near the player against an invisible
mismatch far from it, and the drift was the more noticeable half.

**Choice.** Correct the position where it is *decided*: `PF_setorigin`, the
builtin QuakeC calls to place a freshly spawned missile, before `SV_LinkEdict`
and before any physics. `QR_MuzzleSpawn` rewrites the origin to the tracked
hand, having traced the short hop out from the body spawn point so a missile
can never start inside geometry.

**What this buys.** The missile *is* at the gun rather than being drawn there,
so the trail starts at the gun, the model is at the gun, the flight path is
true from the gun, and the explosion lands on the model. There is nothing to
fold, so there is no fold to see. It also deleted the `cl_main.c` hunk, the
slot table, `vr_projconverge` and ~170 lines: the vendored hunk count is
unchanged at five, with `pr_cmds.c` replacing `cl_main.c`. (A sixth,
`net_dgrm.c`, was added later — see UPSTREAM.md for the current list.)

**What it costs.** Collision now originates at the hand, not only the picture.
A rocket can clear a ledge the body cannot; a gun poked through a wall fires on
the far side. For a port where you aim with your arm that is the intended
behaviour, and it is a design call rather than a correctness one.

**Why the gates are generous.** `QR_MuzzleSpawn` declines unless the edict is a
player-owned missile, its origin is still zero (first placement after
`ED_ClearEdict`, so a teleporter moving a live grenade is untouched), the
requested position is near the player, a hand is tracked, the muzzle is within
arm's reach of the body (`r_refdef.vieworg` holds nothing meaningful before a
map's first rendered frame), and the trace out to it is clear. Declining is the
*normal* path, not an error path — which is also what makes a wrong recollection
of vanilla's QuakeC harmless: if `owner` or `movetype` are not yet set when
`setorigin` runs, nothing happens and upstream's spawn stands.

**Generalisable lesson.** Prefer the hunk that fixes a thing at its source over
the one that fixes what is drawn. Three successive versions of the client-side
shift each had to undo their own correction, and each version's artifacts were
about missiles in sequence rather than one in flight. The source-side fix has
no correction to undo.

## 2026-10-05 — The muzzle spawn keeps the weapon's firing pattern

**The overcorrection.** The regular nailgun had become a single stream on
device. It fires two: `W_FireSpikes` is called with `ox = +4` from one attack
frame and `-4` from the other, so the nails spawn at `self.origin + '0 0 16' +
v_right*±4`. `QR_MuzzleSpawn` replaced the position outright and threw that
away. (The *super* nailgun, by contrast, fires one superspike with no lateral
offset.)

**Choice.** Replace only the part of the spawn offset that centres the missile
on the body. Decompose `org − player.origin` against the aim's **horizontal**
right vector and carry that component over to the muzzle:

    IN_YawVectors (player->v.v_angle[YAW], fwd, right);
    VectorMA (muzzle, DotProduct (org - player.origin, right), right, want);

**Why that split is exact rather than a heuristic.** `'0 0 16'` is vertical and
`v_forward*8` lies in the vertical plane through the aim, so neither has any
component along a horizontal right vector. Only a deliberate `v_right*n` term
does. A probe swept pitch from −60° to +60° and roll to 10° against all four
vanilla offsets: the nailgun's ±4 comes back as 4.00 (3.94 at 10° of roll) and
the other three come back as 0.00.

**Why yaw alone, not the full `v_angle`.** `AngleVectors` on a pitched or
rolled `v_angle` gives a right vector with a Z component, which would leak the
chest lift into the lateral term and make the correction depend on where you
are looking. `IN_YawVectors` is horizontal by construction.

**Lesson.** The spawn offset was never one thing. "Where the weapon fires from"
and "how the weapon patterns its shots" were summed into a single vector, and
replacing the sum destroyed the second. Before overwriting a value the engine
computed, ask which of its summands you actually mean to own.

## 2026-10-05 — Per-weapon gun placement is pulled, not pushed

**Symptom.** On device, placement still behaved globally: swapping weapons let
one gun's placement affect the next, while the per-weapon *trim* was fine. The sliders showed per-weapon values correctly, so the store was
right and the delivery was wrong.

**What was wrong structurally.** Placement was stored per (input mode, weapon)
in Swift but expressed as four global cvars that had to be rewritten on every
weapon switch, over the console queue:

    WeaponTrim.frame (render thread) → sendCommand → Task @MainActor
      → engine.send → console queue → engine thread, next Host_Frame

Three defects fall out of that shape. The gun's placement is computed in
`qr_bridge.c` while the frame is built, so the packet announcing weapon B was
already drawn with A's cvars — the correction arrived a frame or two late, which
is exactly when you are looking at the swap. `engine.send` drops silently unless
`status == .running`. And `frame` only pushes when the weapon *changes*, so a
dropped push is never retried: that weapon keeps the other gun's placement until
you cycle away and back, which is indistinguishable from placement being global.

**Choice.** Swift publishes the whole 8-slot table for the active input mode
through a new any-thread setter, `QC_SetWeaponPlacement`, and `qr_bridge.c`
reads the entry for the weapon it is actually drawing, at the moment it places
it. There is no switch event to miss, nothing in flight, and the first frame of
a swap is already correct. `QR_WheelSlot` is now shared by the wheel and the
placement lookup so the two cannot disagree about weapon ordering. The
`vr_weapon*` cvars stay as the global fallback for an untuned weapon and as the
console's way in.

**What was not proved.** The Swift store, the command route and the engine read
are each correct in isolation; the single reported instance was never isolated.
The fix removes the whole class rather than one case, which is
why it is a redesign and not a one-liner. A Swift probe did clear one suspect:
the NaN "never tuned" marker round-trips through UserDefaults intact, so
persistence was not losing the table.

**Lesson, same as the missile fix.** State that depends on "which weapon is
being drawn" belongs where that is known — at draw time — not shuttled ahead of
it through a queue. Trim still works the old way and was left alone because it
works, but it carries the same latent fragility.

## 2026-10-05 — The held weapon comes from the drawn model, not STAT_ACTIVEWEAPON

**Symptom.** On device, the axe alone ignored its placement sliders, while its
trim front/rear still worked.

**Root cause.** `sv_main.c:972` writes `ent->v.weapon` with `MSG_WriteByte`, and
`IT_AXE` is 4096 — `4096 & 0xFF == 0`. So `cl.stats[STAT_ACTIVEWEAPON]` reads
**zero** for the whole time the axe is held. Upstream only uses that stat to
light a statusbar icon, and the axe's icon is driven from `cl.items`, so the
truncation never mattered there.

It explains every detail of the symptom:

- `WeaponTrim.frame` has `guard activeWeapon != 0` and bailed, so `current`
  stayed on the previously held weapon. The axe's placement edits were written
  into *that* weapon's slot.
- `QR_WheelSlot(0)` returns −1, so the drawn axe fell back to the global cvars
  and could not move.
- The trim sliders push `vr_weaponclip` / `vr_weaponclipback` as live cvars the
  moment they move, so they visibly affected whatever was on screen — including
  the axe — while being *stored* against the wrong weapon.

**Choice.** `QR_ActiveWeaponBit` resolves the held weapon from the view model
being drawn, matched against `qr_wheel_modelnames`, falling back to the stat for
anything outside the wheel table. It feeds both the placement lookup and the
packet's `active_weapon`, so the Swift side gets a real `IT_` bit too. The drawn
model is the more direct answer regardless: it is the thing whose placement is
being decided.

**Collateral to check.** Any trim or placement set *while holding the axe*
before this fix went into whichever weapon was held previously, so a
neighbouring weapon's stored values may be contaminated. Added a "Dump all
weapon values"
button that prints the whole table to the console, both to check that and
because device UserDefaults is the only copy of a tuning session — a reinstall
takes it with it.

**Lesson.** A stat that crosses the network is not the same value the server
set. Before keying behaviour on `cl.stats[...]`, check the width it was written
at; upstream tolerating a truncation says nothing about whether we can.

## 2026-10-05 — Grip is global; back/up/side stay per weapon

**Why this came up.** The question was whether the per-weapon placement
parameters could be cut down, on the guess that grip was the only one worth
keeping. The dump of all eight tuned weapons said the opposite:

| | axe | SSG | nailgun | SNG | GL | RL | LG | shotgun |
|---|---|---|---|---|---|---|---|---|
| back | 7.52 | 3.45 | 7.08 | 9.59 | 9.80 | 8.28 | 15.8 | 18.4 |
| up | +6.91 | −1.66 | −1.39 | −1.94 | −1.40 | −4.94 | −1.90 | +0.08 |
| side | −4.13 | 0 | 0 | 0 | 0 | 3.16 | 0 | 0 |
| grip | 0.15 | 0.15 | 0.15 | 0.15 | 0.15 | 0.15 | 0.15 | 0.159 |

Grip is the default on seven of eight. `back` spans 3.45 to 18.4 and does
almost all the work. (Those numbers came back through OCR with most zeroes
read as eights, so individual digits are unreliable — but the conclusion is
not: every `8` could be a `0` and `back` would still span 3.45 to 15.)

**Why grip went unused.** Grip and `back` move the gun along the *same axis* —
grip as a fraction of the trimmed model length, `back` in absolute Quake units.
Two knobs over one degree of freedom, and the one with comprehensible units
won. `up` and `side` are independent axes with no substitute: `up` spans −4.94
to +6.91, and `side` is zero for six weapons but genuinely needed for the axe
and the rocket launcher.

**Choice.** Grip drops out of `qc_weapon_placement_t`, the Swift `Placement`
struct, the persisted table and the Weapon tab. It survives as the single
global `vr_weapongrip`, pushed from the active profile — so the console can
still reach it and its one useful property is kept: being a *fraction*, it
adapts to each model's length and re-seats when the trim planes move, which is
why one value fits every gun.

**Persistence.** The stored table went from four floats per slot to three, so
`load` reads `weaponPlacement.v2` and folds `weaponPlacement.v1` down when only
that exists. A Swift probe checked the fold against all eight tuned weapons
before any of this shipped: hand-tuned values that exist nowhere but one
device are not something to migrate hopefully.

**Lesson.** Two parameters acting on one axis is not twice the control, it is
one control and one trap. The tell was in the data — the knob nobody moves in
eight attempts is not a knob.

## 2026-10-06 — The hands weapon tuning is now the shipped default

All eight weapons were tuned in the headset and the table read back out through
the Xcode-copyable dump. Those numbers are now `WeaponTrim`'s defaults, so a
reinstall starts where the tuning session ended instead of at a guess.

**Trim rear**, replacing a flat 0.79 on every projectile weapon: axe 1.0 (no
round to hide), shotgun 0.657, super shotgun 0.500, nailgun 0.733, super
nailgun 0.500, grenade launcher 0.500, rocket launcher 0.522, lightning gun
0.851. The spread is the point — one guess could not fit eight models whose
rounds sit at eight different depths. The lightning gun needing a shave was the
surprise: it loads no round, but its model's rear end still reaches into the
hand.

**Placement**, hands only: `back` 7.510 / 10.406 / 3.452 / 7.078 / 9.592 /
9.796 / 8.276 / 15.841, `up` +6.913 / 0.071 / −1.651 / −1.392 / −1.941 /
−1.401 / −4.937 / −1.900, `side` −4.132 and 3.161 for the axe and rocket
launcher, zero for the rest. PSVR2's eight slots stay nil: where a gun is held
differs between bare hands and a controller, and copying hands values across
would be inventing numbers rather than promoting measured ones.

**"Reset gun" now restores the shipped tuning** rather than the profile global.
For hands the shipped value *is* the good answer, so dropping to the global was
a downgrade dressed as a reset. A weapon with no shipped default still falls
back to the global, which is what nil means.

**On not guessing.** The first dump was read off the headset display and OCR'd,
turning most zeroes into eights. Three values would have been wrong had that
transcription been taken as data: global `back` is 10.351 not 18.351, shotgun
`back` is 10.406 not 18.4, and shotgun `up` is 0.071 not 0.079. Values
transcribed from a headset display are not data; the cost of waiting for a
copyable dump was one round trip, and the cost of guessing would have been a
silently wrong rig that looked plausible.

## 2026-10-06 — The input profile must follow the hardware without a window

**What happened.** The gun rig was tuned with the PSVR2 controllers and the
dump did not appear in Xcode's console. Two separate faults behind that.

**Fault 1: `print` needs Xcode to have launched the process.** Build, then tap
the app on the Home View, and stdout is captured by nobody. The first dump
worked only because that session happened to be a Run. The button now also
writes through `os_log` (reaches Console.app with no debugger attached) and
puts the whole table on the clipboard (reaches the Mac through Universal
Clipboard). Four channels, because which one works depends on how the app was
launched — and a finished tuning session is too expensive to strand on a
device.

**Fault 2, the serious one: the profile switch lived on the console window.**
`ProfileStore.refreshActiveFromInput()` was called from
`.onChange(of: gamepad.hasPhysicalController)` on the console view. Connect the
controllers while that window is closed and the *hands* profile stayed active,
so `WeaponTrim.mode` stayed 0 and every placement edit made with a controller
in hand was written into the **hands** slots — silently overwriting the tuning
shipped that morning.

`GameControllerInput` already had `onControllerChange` for precisely this
reasoning: its own comment says "a controller connecting has to take over even
with no window open to notice it." Input activation used it; the profile did
not. It does now. And `WeaponTrim.setMode` is driven from
`ProfileStore.active`'s `didSet` rather than from `applyRig`, which returns
early before the console has ever been opened — so the mode follows the profile
by construction instead of by remembering to call something.

**Recovery exists because the values were baked in.** "Reset gun" restores the
shipped hands tuning per weapon, so clobbered hands slots are recoverable from
code rather than lost. That is the second time promoting measured values to
defaults has paid for itself.

**Lesson, for the third time in this rig.** State that must follow a condition
should be derived from that condition, not pushed by whoever noticed it
changing. Window-scoped observers miss events by design: the window is closed
for most of the session.

## 2026-10-06 — Clip trim is per input mode too, and both modes are shipped

**What the PSVR2 dump revealed.** The tuning landed in `mode=1`, so the profile
fix held. But the rear trim values came back different from the hands pass:
shotgun 0.632 against 0.657, super nailgun 0.543 against 0.500, and the
lightning gun 0.608 against 0.851. Clip was indexed by weapon alone —
`front[current]`, no mode — so tuning it with a controller **overwrote the hands
values in place**.

**The old reasoning was half right.** Clip was deliberately not per-mode because
it describes where a model's baked-in round sits, which is a property of the
model. But the trim planes also feed `QR_WeaponClip`, which re-seats the
**grip** — so the right trim depends on how the gun is held, not only on the
model. Two tuning passes by hand settled it: a 0.24 difference on the lightning
gun is not noise.

Clip is now keyed by (input mode, weapon), 16 slots, exactly like placement.

**Both modes' measured values are the defaults**, hands and PSVR2, from the two
passes. The legacy eight-value keys are deliberately *not* migrated: whichever
mode they were last written from, restoring them would put one mode's numbers
over the other's, and both sets are now in code. Nothing is lost by dropping
them.

**PSVR2 placement is shipped too.** Its shape differs from hands in a way that
reads as real rather than arbitrary: `up` is ~0 across the board where hands
wanted −1.4 to −1.9, because the controller already puts the model's anchor at
about the right height. The rocket launcher is the outlier in both.

**And the dump was printing twice.** stdout is also captured by the unified log,
so `print` alongside `Logger` showed every line in Console.app twice. `Logger`
reaches Xcode's console as well, so `print` bought nothing and is gone.

**Lesson.** "This parameter describes the model, so it cannot depend on the
input" was a plausible argument that happened to be wrong, because the parameter
had a second effect nobody was thinking about when the comment was written. The
dump caught it only because it printed both halves of the state next to each
other.

## 2026-10-06 — Audio un-shelved: the device start was always too early

**Background.** The SNDDMA sink was shipped working on the host but shelved
behind `AudioSink.disabled = true` after four device failures: session config
on the engine thread gave OSStatus -50 "Session lookup failed"; on main, -50
plus a frozen UI; deferred to the main queue, a hang; and a background-thread
start crashed with EXC_BAD_ACCESS at 0x10. The shelf note's own prescription
was "prove a bare AVAudioEngine can play a tone in this app before trusting the
full path."

**Root cause.** Three of the four were one bug. The crash (0x10) was a
publication race -- the render block read `self.config` before it was visible to
the audio thread -- already fixed by capturing an immutable RenderConfig by
value. The other three all came from bringing the device up during `Host_Init`,
which runs from the console window's `onAppear` at launch, BEFORE visionOS has
registered the app's audio session with mediaserverd. "-50 / Session lookup
failed" is exactly what touching the session that early looks like, and the
code's reliance on AVAudioEngine's implicit session reached the same unready
machinery and wedged instead of erroring. The mixer, the ring and the render
block were never the problem.

**Fix.**
1. The device no longer starts from the engine boot path. `open()` (engine
   thread, inside `SNDDMA_Init`) only allocates the ring and returns.
2. `QuakeAVPApp` calls `AudioSink.sceneDidActivate()` when `scenePhase` first
   reaches `.active` -- the moment the session is actually reachable -- and that
   starts the device.
3. The session is now explicitly configured (`.playback`, `setActive(true)`)
   instead of relying on the implicit reach that wedged.
4. The whole bring-up runs on a disposable background thread with a 10s
   watchdog, so even a hard wedge leaks one thread and logs; boot and the UI
   can no longer stall -- the single most damaging symptom on device, since a
   stalled boot takes the whole app with it. `open()` is pure memory,
   `sceneDidActivate` only dispatches.

**Proof instrument.** `QAVP_AUDIO_TONE=1`, or a "Audio self-test (440 Hz tone)"
button on the Debug tab, bypasses the mixer for a bare sine straight out of
AVAudioEngine. Audible = engine + session + lifecycle all good, and any game
silence is upstream; silent = the log line after "[audio] tone: starting" is
the diagnosis. `QAVP_AUDIO_OFF=1` forces the old snd_null.c silence.

**Verified without the device.** `make check` (58 TUs, clean link), `make
device` (BUILD SUCCEEDED), and a host probe that drives the mixer's
`S_TransferStereo16` write convention against the render block's read and
confirms they agree sample-for-sample including across the ring wrap -- ruling
out "silent static." What needs the headset: whether the session actually comes
up at scene-active. The architecture guarantees it cannot stall if it does not.

**Lesson.** Every prior attempt assumed the engine could make sound and varied
the thread. The variable that mattered was the lifecycle phase, not the thread:
an audio session is a per-process resource the OS registers on its own schedule,
and nothing you do on any thread reaches it before then.

## 2026-10-06 (correction) — Scene-active alone did not fix it; setActive is the suspect

The earlier fix today (device start moved to scene-active WITH an explicit
AVAudioSession) did NOT work: on device the app hung at launch, last log line
"[audio] starting device, attempt 1..." -- which prints immediately before
`setActive(true)`. That lines up exactly with the original shelf note's own
account of setActive: "a synchronous XPC call that... never returned."

Two things were wrong with that attempt. Claiming an architectural win without
device confirmation was the first; this is the fifth failed attempt and every
one assumed the engine could make sound. The second: the real path called
setActive, the one call with a recorded hang.

**New stance: instrument, do not assume.** `QAVP_AUDIO` selects a mode, each
isolating one variable, every sub-step logged BEFORE its call so the last line
printed names the hang from a single launch:
- `off` (default): silent, app loads -- known good, so the default is never a
  broken-loading build again.
- `session`: setCategory + setActive only. Confirms whether setActive is the hang.
- `tone`: AVAudioEngine + 440 Hz, IMPLICIT session (no setActive). Proves the
  engine at scene-active on its own.
- `on`: the real sink, also implicit session -- same bring-up as `tone`.

The real sink now never calls setActive; only the `session` diagnostic does.
The Debug-tab "Audio self-test (440 Hz tone)" button runs the `tone` path
on demand, so the device can be bisected from a normal Home View launch with no
scheme edit. Next step is a single device launch plus the tone button; the
result picks the fix, it is not guessed.

## 2026-10-06 (device evidence) — the -50 is at connect, not setActive; session goes first

The tone-button launch on device gave the first real diagnosis. Two facts:

1. The app did NOT hang -- the immersive space rendered at 120fps straight
   through the attempt. The -50 fails FAST. "Stalls on the AVP" was the XPC
   round-trip plus no sound plus repeated button presses, not a true hang.
2. The failure is `AVAudioSession_iOS.mm:643 Creating proxy session failed ...
   -50 Session lookup failed`, hit by AURemoteIO at `connect` time -- with the
   IMPLICIT session (setActive was removed in that build). So with no session
   established, the engine cannot create one itself.

That inverts the previous theory. setActive's old -50 was boot timing; the
standing problem is that nobody establishes the session, so establish it FIRST:
`setCategory(.playback)` + `setActive(true)` before building the engine, run
well past launch, with spaced retries and per-step logging. Default is now `on`
(the -50 is fast and harmless to the app), first attempt delayed 2s past
scene-active so session ops run settled rather than mid-handshake.

This build is decisive either way:
- "session: ACTIVE ok" then a tone/sound -> fixed.
- "session: setActive FAILED ... -50" -> the server refuses this app a session
  outright; not an in-process fix, and the next lever is a clean Home View
  launch (lldb is a known source of proxy-session -50) and then
  entitlement/Info.plist review.

## 2026-10-06 (two bugs, isolated) — SNDDMA_Init=true hangs boot, separately from the -50

Defaulting to `on` re-hung the app at launch (IP at the "Audio: %d bit" line,
same as the first un-shelf). Cross-referencing all three device runs:
SNDDMA_Init returning TRUE hangs boot; returning FALSE loads. The hang happens
during Host_Init, BEFORE any session/device bring-up (which is scene-active or
later). So there are TWO independent bugs:

1. Quake's own sound subsystem hangs when it first truly initialises on device:
   S_Init runs S_PrecacheSound (file I/O), S_CodecInit, and then S_Update every
   frame -- none ever executed on device before, since sound was always
   disabled. Cannot be reproduced off-device or pinned by reading.
2. AVAudioEngine's AURemoteIO gets "-50 Creating proxy session failed" (the
   earlier device finding).

Default is back to `off` (app loads; breaking the loadable build twice was the
mistake). New `ring` mode allocates the ring so the mixer runs but brings up NO
device -- isolating bug 1 from bug 2 in one launch:
- ring loads  -> Quake sound path is fine; the hang is the AVAudioEngine bring-up.
- ring hangs  -> the hang is S_Init/precache/S_Update; AVAudioSession is innocent.

Protocol: default launch + tone button tests bug 2; QAVP_AUDIO=ring tests bug 1.
No more default changes until both are green on device.

## 2026-10-06 (the -50 is a run-loop problem) — build the engine on the main thread

The tone-button log was decisive: "session: ACTIVE ok" (setActive SUCCEEDS),
then at connect "-50 Creating proxy session failed ... no reporter associated
with ... session". So setActive was never the issue. "no reporter associated"
is the signature of a CoreAudio unit (AURemoteIO) trying to register property
listeners on a thread with NO RUN LOOP -- the engine was being built on a bare
GCD global queue. The "kills the app" is the uncatchable ObjC exception connect
throws once that fails.

Fix: keep session work (setCategory/setActive) on the background thread where it
is proven safe and successful, but hand the ENGINE bring-up (attach/connect/
start) to the MAIN thread, which has a run loop. runEngine -> buildEngineOnMain.
Retry counts cut (5 -> 2/3) so a failure no longer thrashes the session five
times, which is likely what felt like the app dying.

If the -50 persists even on main: it is not the run loop, and the next levers
are the immersive-context audio restriction and the debugger (clean Home View
launch). But "no reporter" + "no run loop on the calling thread" is a tight
match.

## 2026-10-06 (RESOLVED) — it was the debugger all along; audio defaults on

A detached Home View launch (no Xcode) plays the tone: 440 Hz at 48000 Hz, no
-50. So the entire saga was lldb: ptracing the process disrupted the audio XPC
(the "-50 Creating proxy session failed / no reporter associated") and, almost
certainly, the compositor XPC too (the "loads forever" boot hang was the
immersive layer stalling, not Quake's S_Init). Every failed test had Xcode
attached; the one detached test worked. The code was correct for several
iterations -- the debugger was poisoning it.

Resolution:
- Default is now `on`. It MUST be, because env vars only reach launches started
  from Xcode; a Home View (shipping) launch never sees QAVP_AUDIO, so audio
  cannot be opt-in. The env var still overrides from Xcode for dev/recovery.
- Recovery hatch without env vars: a persisted "Game audio (next launch)" Debug
  toggle (UserDefaults audioEnabled), so if a launch ever misbehaves it can be
  turned off from inside the app. Mode is read once per launch, hence "next
  launch."
- The connect NSException is caught (QAVPExceptionShim) and the trace mirrors to
  the in-headset console, both of which made the detached test possible and both
  of which stay as permanent robustness.

Lesson, in one line: on visionOS, audio and compositor XPC can fail under the
debugger in ways that look like app bugs. Test audio/immersive with a detached
Home View launch before concluding the code is wrong.

## 2026-10-06 (sound works) — the bug was a NULL shm, not any of the suspects

Game sound plays on device. The actual bug: `SNDDMA_Init` in snd_avp.c filled
the `dma` struct but never set the engine global `shm = dma`. Upstream's
platform SNDDMA_Init does that as its first action; ours omitted it. So `shm`
stayed NULL, and the first mixer access -- S_Startup's
`Con_Printf("Audio: %d bit", shm->samplebits, ...)` -- dereferenced NULL and
crashed with signal 11 the instant the sound subsystem went active. That single
omission explains the ENTIRE history: audio-off always loaded (shm untouched),
audio-on always died, and under the debugger the crash presented as a hang.

What actually found it: `make run` (detached, --console) turned the "hang" into
a clean reproducible SIGSEGV, and synchronous stderr brackets around the init
pinned it to the exact line between "SNDDMA_Init returning true" and the first
precache. Everything before that -- the -50, setActive, threads, immersive, the
debugger -- was real but SECONDARY: the debugger genuinely does break the audio
XPC (the tone only ever worked detached), but the sink would have crashed on
NULL shm regardless.

Final state: audio defaults on (proven). snd_dma.c is pristine upstream again;
the shm fix lives in snd_avp.c (platform, not a vendored hunk). Kept as
permanent robustness: QAVPExceptionShim (catches connect's ObjC exception), the
in-headset log mirror, `make run`, and the QAVP_AUDIO / "Game audio" recovery
hatch.

Two lessons worth the scars: (1) test audio/immersive with a DETACHED launch
before suspecting the code -- the debugger masks crashes as hangs and breaks
XPC. (2) when porting a platform backend, diff it against the upstream one for
omitted global wiring like `shm = dma`; a missing one-liner read as five
different exotic failures.

## 2026-10-14 — The window replaces the engine menu; the engine menu is a console-only vestige

**Choice.** The SwiftUI console/settings window is the product's entire
out-of-game surface. It gains a Game tab with savegame slots, direct connect
and the LAN server browser, so there is nothing left that only the engine
menu could do. Both hardware routes into that menu are re-pointed at the
window: the gauntlet's sixth off-wrist cell (still labelled MENU) and the
PSVR2 Sense right-hand Options button. `menu.c` stays compiled and reachable
through the console's `togglemenu`, for development and as the escape hatch
if something in the window is wrong on device.

**Why.** Three reasons, in order of weight.

The input we actually have is hands. Quake's menu is a keyboard list: arrow
keys, Enter, Escape, a text field for a server address. Everything that
drives it here is emulated — `in_null.c` already turns a pad bit into
`K_ESCAPE` and stick deflections into arrow keys — and none of it exists on
a bare hand at all. The window is touchable by the thing the player has.

The window is already the surface. Every comfort, weapon, HUD, capture and
admin setting is there; sound is there. A player who wants to save would
have had to leave a native panel to drive an emulated keyboard list for the
one task that was still missing. Splitting the settings across two menus in
two input idioms is worse than either menu alone.

The sound sliders set the precedent, and it is the binding one: window
controls mirror engine truth rather than keeping a parallel copy. That is
what makes this safe to do. The save button's enablement and its refusal
text come from `Host_Savegame_f`'s own guard order, computed engine-side; the
slot list is a scan of the live `com_gamedir`; the connection badge is
`cls.state`; the server rows are `slist`'s own hostcache. Every action is an
ordinary console command. The window is a second *view* of the engine, never
a second *model*, so there is nothing here that can disagree with it.

**Rejected: port the engine menu to Metal.** The 2D layer can draw it — the
HUD, console and centerprints already go through it. But that would have
reproduced a 1996 keyboard menu in a headset with no keyboard, and then the
settings would have been in two places anyway. The 2D milestone is considered
met on this basis, with the exception recorded here.

**Cost accepted.** The menu is now app-side, so a build with the window
closed and no hands tracked has only the console to reach it — which is why
the Sense Options button and the MENU key both summon the window rather than
one of them keeping the old behaviour. `vr_wristcomm_off_cmd5` is
`CVAR_ARCHIVE` and rebinding it to `togglemenu` restores the engine menu on
that key for anyone who wants it.

**Mechanism worth knowing.** The MENU cell's default is `qavp_window`, which
is NOT a console command: `WristCommStore.fire` recognises it and calls the
summon closure before the send, so it never reaches `Cbuf` and can never
print "Unknown command". It carries the project prefix so an upstream merge
cannot collide with it, and both the C cvar default and the Swift constant
are pinned by tests, because a typo on either side of that contract presents
as a dead key rather than an error.
