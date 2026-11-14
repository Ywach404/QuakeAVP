# C-native grappling hook implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move the grappling hook off rogue's compiled QuakeC and into platform
C, so that one hook works in all six games, the player's gun stays drawn and
firing through a swing, and the rope leaves the off hand.

**Architecture:** The hook stops being a server entity driven by progs and
becomes platform-C state in `grapple_avp.c`: a position and velocity advanced
each frame by `SV_Move`, an anchor latched where the trace stops short, and the
existing pendulum reading that anchor instead of a hook edict. The hook head and
rope are drawn Swift-side from the late-latched hand pose, with the hook tip
crossing in the frame packet. Nothing is written to `player->v.weapon` any more,
which is what frees the gun and the off hand.

**Tech Stack:** C99 (QuakeSpasm 0.97 engine, `platform/` shim layer), Swift 6 /
CompositorServices / Metal for the renderer, host test drivers in C linked
against the `make check` objects.

**Spec:** `docs/designs/2026-11-14-c-native-grappling-hook.md` (committed at
aafed25). The plan argues from that document; read both.

## Global Constraints

- `Sources/QuakeCore/engine/` is vendored QuakeSpasm 0.97. Exactly six patched
  hunks exist, all listed in `UPSTREAM.md`. **This plan adds none.** If a
  seventh looks necessary, stop: it means the rope or the pose went to the wrong
  layer.
- `make check` after every C change. It is a **host compile, not a visionOS
  build**, and every report must say which was run.
- Unit tests run with `tools/check-unit.sh`, which compiles and runs every
  `tools/unittest/*.c` against the `make check` objects minus `hostmain.o`.
- Everything named `QC_*` runs on the engine thread except the documented
  any-thread setters. `QC_Renderer*` is the render thread's half and is only
  called inside `RendererCore.withConsumer`.
- Numeric acceptance criteria pass on a black screen. Every task that changes
  what is on screen needs one criterion that cannot pass unless something
  visibly correct is drawn.
- No em dashes and no en dashes in any file, commit message or comment. Use a
  comma, a colon, parentheses, a full stop, or `--`.
- Commits are Conventional Commits: type prefix, summary, body with the
  reasoning. No attribution trailers of any kind.
- C style is upstream QuakeSpasm: tabs, `Function_Name (args)` with the space,
  K&R braces on their own line. Match the file you are in.
- Cvar defaults stay byte-identical to what ships today. The eleven
  `vr_grapple_*` values are not retuned by this work.

## Review Focus

Five failure modes the design implies that no task's happy path exercises. Each
line names the test that pins it and the task that owns it.

1. **The anchored entity is freed mid-swing** (a hooked monster dies or gibs).
   Reading a freed edict's origin is a crash or garbage. Expected: the rope
   converts to a static anchor at the last known world position and the swing
   continues. Pinned in Task 2, Step 3.
2. **The hook hits sky.** `CONTENTS_SKY` must not anchor. Expected: the throw
   is abandoned and, with the grip still held, re-arms for a fresh throw rather
   than ending the engagement. Pinned in Task 1, Step 7.
3. **A level load or `game` switch while swinging.** `sv_friction` is a global
   this module borrows, and `Grapple_ResolveProgs` is today the only thing that
   releases it on a game switch. Expected: friction restored and all state
   cleared, with no stale anchor surviving into the new map. Pinned in Task 2,
   Step 9.
4. **The grip held through death and respawn.** Expected: no throw on the first
   spawned frame; the player must release and re-press. This is a measured
   historical bug (a player dragged across a map they had just arrived in).
   Pinned in Task 2, Step 7.
5. **A long frame.** Both `QC_Frame` and `Host_FilterTime` permit 0.1 s.
   Expected: the flight step cannot tunnel through a wall at any `dt`, and the
   spring cannot diverge. Pinned in Task 1, Step 5 and Task 2, Step 5.

---

## File Structure

**Modified:**

- `Sources/QuakeCore/platform/grapple_avp.c` (1079 lines today). Owns the whole
  feature: state machine, flight, anchor, pendulum, damage. Stays one file
  because every part of it reads the same file-scope state, and splitting would
  mean publishing those statics. Expect it to lose roughly 150 lines of progs
  plumbing and gain roughly 250 of flight and anchor.
- `Sources/QuakeCore/platform/grapple_avp.h`. Loses `Grapple_Active`, gains
  `QR_GrappleState`.
- `Sources/QuakeCore/platform/in_null.c`. Gains `QR_OffHandOrigin` and the
  off-hand pose drain. The `Grapple_Frame` call site is unchanged.
- `Sources/QuakeCore/include/QuakeCore.h`. Two new `qc_frame_t` fields and one
  new input setter.
- `Sources/QuakeRenderer/bridge/qr_bridge.c`. Publishes the grapple state into
  the packet. One call, in the packet builder.
- `Sources/QuakeRenderer/RendererCore.swift`. Draws the rope and hook head
  beside `drawVirtualHand`.
- `App/Sources/HandInput.swift`. The fist gesture and its suppression.
- `App/Sources/ImmersiveRenderer.swift`. Publishes the off-hand pose to the
  engine and passes the rope to the renderer.

**Created:**

- `tools/unittest/grapple_anchor_test.c`. Pure decisions over a hand-built
  `trace_t`: anchor, keep flying, refuse sky.
- `tools/unittest/grapple_swing_test.c`. The pendulum's numbers, with no world.
- `tools/range/gymtest.c`. Boots the engine on the gym map and drives a real
  throw, modelled on `tools/range/rangetest.c`.

**Deliberately untouched:** `App/Sources/GameControllerInput.swift`. The
physically-left grapple bind is a real bug and is deferred to its own item by
the design; do not half-fix it here.

---

## Task 1: The hook flies and anchors, in C

The hook stops being an edict. In this task the flight exists and is proven but
is **not yet wired into `Grapple_Frame`**, so the shipped behaviour is
byte-identical and the build works at every commit.

That is not a stylistic choice. Wiring it in now would mean rogue throwing its
progs hook and this code flying a second one from the same grip, and it could
not be tested anyway: the gym lives in `pak2` which is seeded into `id1`, and
`grapple_supported` is false in `id1`, so a pad-driven grip does nothing there
until Task 2 removes that gate. The gym driver therefore calls the throw
directly through a `QAVP_HOSTCHECK` entry point, and the pad path arrives in
Task 2.

**Files:**
- Modify: `Sources/QuakeCore/platform/grapple_avp.c`
- Create: `tools/unittest/grapple_anchor_test.c`
- Create: `tools/range/gymtest.c`

**Interfaces:**
- Consumes: `SV_Move (vec3_t start, vec3_t mins, vec3_t maxs, vec3_t end, int type, edict_t *passedict)` and `trace_t` from `Sources/QuakeCore/engine/world.h:28-71`; `SV_PointContents (vec3_t p)` from the same header; `QR_HandOrigin (vec3_t out)` from `Sources/QuakeCore/platform/in_null.c:1364`.
- Produces, all in `grapple_avp.c` and all `static` except where noted:
  - `typedef enum { GRAPPLE_IDLE = 0, GRAPPLE_FLYING = 1, GRAPPLE_ANCHORED = 2 } grapple_state_t;`
  - `static grapple_state_t qr_grapple_state;`
  - `static vec3_t qr_grapple_tip;` the hook head's world position, valid in `GRAPPLE_FLYING` and `GRAPPLE_ANCHORED`
  - `static vec3_t qr_grapple_fly_vel;`
  - `static float qr_grapple_fly_ttl;` seconds of flight remaining
  - `static int qr_grapple_anchor_num;` edict number of the anchor entity, 0 for world
  - `static vec3_t qr_grapple_anchor_ofs;` the anchor in the anchor entity's local frame
  - `static int Grapple_AnchorFromTrace (const trace_t *tr, const vec3_t start);` returns `1` anchor here, `0` keep flying, `-1` abandon the throw
  - `static void Grapple_Throw (edict_t *player);`
  - `static void Grapple_FlightFrame (edict_t *player, float dt);`
  - `static void Grapple_AnchorOrigin (vec3_t out);` resolves a moving anchor to world space

- [ ] **Step 1: Write the failing unit test for the anchor decision**

Create `tools/unittest/grapple_anchor_test.c` with the file's standard header
(SPDX, copyright, a comment saying what invariant it proves), the four
`QC_Audio*` stand-ins copied from `tools/range/rangetest.c:15-27`, and the
`CHECK` macro idiom from `tools/unittest/turn_pivot_test.c:27`. Declare the
function under test as a non-static extern (Step 3 exposes it).

Assertions, with these exact cases:

```c
/* fraction 1.0, nothing hit: keep flying */
tr.fraction = 1.f; tr.ent = NULL; tr.allsolid = false; tr.startsolid = false;
CHECK (Grapple_AnchorFromTrace (&tr, start) == 0, "a clear trace keeps flying");

/* stopped short on the world: anchor */
tr.fraction = 0.4f; tr.ent = EDICT_NUM (0);
CHECK (Grapple_AnchorFromTrace (&tr, start) == 1, "a world hit anchors");

/* stopped short, but the surface is sky: abandon */
/* sky is detected by SV_PointContents just past the impact, so this case is
   driven by placing tr.endpos inside a CONTENTS_SKY leaf; see Step 7 */

/* started inside solid: abandon rather than anchor inside a wall */
tr.startsolid = true; tr.fraction = 0.f;
CHECK (Grapple_AnchorFromTrace (&tr, start) == -1, "a throw from inside solid is abandoned");

/* allsolid: abandon */
tr.allsolid = true;
CHECK (Grapple_AnchorFromTrace (&tr, start) == -1, "an all-solid trace is abandoned");
```

- [ ] **Step 2: Run it and watch it fail to link**

Run: `tools/check-unit.sh 2>&1 | grep -A5 grapple_anchor`
Expected: `LINK FAIL: grapple_anchor_test.c` with an undefined symbol for
`Grapple_AnchorFromTrace`.

- [ ] **Step 3: Implement `Grapple_AnchorFromTrace`**

In `grapple_avp.c`, immediately above `Grapple_Throw`. Signature exactly as in
the Interfaces block. It is a pure decision over the trace and takes no
globals, which is what makes it unit-testable without a world, and that is the
reason it is a separate function rather than inline in the flight step.

Expose it to the test the way `qr_bridge.c` already exposes its test hooks: wrap
the `static` qualifier so it is external under `QAVP_HOSTCHECK` only. Follow the
pattern at `Sources/QuakeRenderer/bridge/qr_bridge.c:6174-6199`.

Order of tests inside it matters: `allsolid` and `startsolid` are checked before
`fraction`, because a trace that began in solid reports `fraction` 0 and would
otherwise read as a legitimate point-blank anchor.

- [ ] **Step 4: Run the unit test and watch it pass**

Run: `tools/check-unit.sh 2>&1 | grep -A8 grapple_anchor`
Expected: every `ok:` line, no `FAIL:`.

- [ ] **Step 5: Implement the flight step**

`Grapple_FlightFrame (edict_t *player, float dt)` in `grapple_avp.c`:

- Trace the whole step, `SV_Move (qr_grapple_tip, vec3_origin, vec3_origin, end, MOVE_MISSILE, player)` where `end = tip + vel * dt`. **`MOVE_MISSILE`, not `MOVE_NORMAL`**, which corrects the design document: `SV_PushEntity` uses `MOVE_MISSILE` for a `MOVETYPE_FLYMISSILE` entity, so this is what rogue's hook edict was actually traced with, and it is the type that clips to monsters. A point hull (`vec3_origin` mins and maxs) matches the hook's own zero-size bbox.
- Because the whole step is traced, no `dt` can tunnel. That is Review Focus 5 for this task and needs no clamp.
- Apply the `Grapple_AnchorFromTrace` result: `1` latches the anchor (see Step 6), `0` advances `qr_grapple_tip` to `tr.endpos`, `-1` sets `qr_grapple_state = GRAPPLE_IDLE` and leaves the engagement alive so a held grip re-throws.
- Decrement `qr_grapple_fly_ttl` by `dt`; at or below zero, abandon exactly as `-1` does. The ttl is seeded in `Grapple_Throw` from `range / speed`, which is the same arithmetic `Grapple_TuneHook` used for `hook->v.nextthink` and preserves what `vr_grapple_range` means.

- [ ] **Step 6: Implement `Grapple_Throw` and the anchor latch**

`Grapple_Throw (edict_t *player)`:

- Origin: `QR_HandOrigin (qr_grapple_tip)`; if it returns 0, fall back to
  `player->v.origin` with `z += player->v.view_ofs[2]`, which is where vanilla
  spawns a projectile and is the same degradation `QR_MuzzleSpawn` already makes
  when the aim channel is dead.
- Direction: `AngleVectors (player->v.v_angle, fwd, right, up)` and throw along
  `fwd`. This is what rogue's `W_FireGrapple` used, so the aim is unchanged.
- Speed: `vr_grapple_speed.value`, clamped to `[100, 30000]` exactly as
  `Grapple_TuneHook` clamps it today. **`sv_maxvelocity` is no longer touched
  at all**: that write existed only because `SV_CheckVelocity` clamped the hook
  edict's velocity per component, and a C-owned hook never goes through
  `SV_CheckVelocity`. Delete `Grapple_TuneHook` entirely in Task 2 and say so in
  its commit, because the cvar's comment block explains that raise and the
  explanation is now wrong.
- The anchor latch, in `Grapple_FlightFrame`: store `qr_grapple_anchor_num = NUM_FOR_EDICT (tr.ent)` and `VectorSubtract (tr.endpos, tr.ent->v.origin, qr_grapple_anchor_ofs)`, so a moving platform carries the anchor with it. For the world edict (number 0) the offset is the absolute position, which needs no special case since the world's origin is always zero.

- [ ] **Step 7: Write the gym driver, including the sky case**

Create `tools/range/gymtest.c` on the model of `tools/range/rangetest.c`: the
same `QC_Audio*` stand-ins, `QC_ExecuteCommand ("map gym\n")`, a
`frames (int n)` helper calling `QC_Frame (1.0/72.0)`, and the `CHECK` macro.

Drive the throw through a `QAVP_HOSTCHECK`-only entry point added in this step,
`void Grapple_TestThrow (void);`, which resolves the player and calls
`Grapple_Throw`, plus `int Grapple_TestState (float tip[3]);` to read the state
and tip back. The pad path cannot be used yet, for the reason given at the head
of this task.

Assertions:

```
ok: the gym loaded                      (cl.worldmodel->name == "maps/gym.bsp")
ok: a throw puts the hook in flight     (state == GRAPPLE_FLYING after the call)
ok: the hook travels                    (tip moved > 100 units from the hand)
ok: the hook anchors on a column        (state == GRAPPLE_ANCHORED within 60 frames)
ok: the anchor is on a surface          (SV_PointContents (tip) is not CONTENTS_SOLID)
ok: a throw at the sky lid never anchors (aim straight up, state returns to IDLE)
ok: a second throw after a sky miss flies again (re-arming is not blocked)
```

The sky case needs the aim pointed at the gym's sky lid, which is reached by
writing `player->v.v_angle[PITCH] = -89.f` before the throw. The chained
re-throw under a held grip belongs to the state machine and is pinned in Task 2
Step 6; what this step proves is only that a sky miss leaves the module able to
throw again.

- [ ] **Step 8: Run both and verify**

```sh
make check                    # host compile, NOT a visionOS build
tools/check-unit.sh
O=${TMPDIR:-/tmp}/quakecore-hostbuild
cc -std=gnu99 -DQAVP_PLATFORM -DQAVP_HOSTCHECK -DUSE_CODEC_WAVE=1 -DUSE_CODEC_VORBIS=1 \
   -ISources/QuakeCore/engine -ISources/QuakeCore/platform \
   -ISources/QuakeCore/include -ISources/QuakeRenderer/bridge \
   -o build/gymtest tools/range/gymtest.c $(ls $O/*.o | grep -v hostmain.o) -lm
build/gymtest <basedir>       # <basedir>/id1 holds pak0, pak1 and pak2
```

Expected: `make check` links with no new undefined symbols, every unit `ok:`,
and every `gymtest` line `ok:`.

- [ ] **Step 9: Commit**

```bash
git add Sources/QuakeCore/platform/grapple_avp.c tools/unittest/grapple_anchor_test.c tools/range/gymtest.c
git commit -m "feat(grapple): fly and anchor the hook in C instead of in progs"
```

---

## Task 2: The swing reads the C anchor, and rogue's path is deleted

**Files:**
- Modify: `Sources/QuakeCore/platform/grapple_avp.c`
- Modify: `Sources/QuakeCore/platform/grapple_avp.h`
- Create: `tools/unittest/grapple_swing_test.c`
- Modify: `tools/range/gymtest.c`

**Interfaces:**
- Consumes: everything Task 1 produced.
- Produces: `Grapple_SwingFrame (edict_t *player)`, one argument instead of two, reading the anchor through `Grapple_AnchorOrigin`. `Grapple_Active` is removed from the header: it is exported today with no callers anywhere, so nothing is broken by its going, and nothing should start suppressing the gun during a swing.

- [ ] **Step 1: Write the failing pendulum test**

Create `tools/unittest/grapple_swing_test.c`. No world and no `sv`: build an
`edict_t` on the stack, set `qr_grapple_state = GRAPPLE_ANCHORED` and the anchor
statics through the `QAVP_HOSTCHECK` accessors, and call `Grapple_SwingFrame`.

The two numbers to pin, both measured on the current build and both of which the
rewrite must reproduce, are the gravity-compensation identity and the
length scaling:

```c
/* An overhead rope nets the full accel, not accel minus gravity. */
/* dir[2] == 1, accel 1500, sv_gravity 800: the frame's budget is 1500 + 800 */
CHECK (fabsf (measured_accel - 1500.f) < 1.f,
       "an overhead rope delivers the whole accel (%.2f)", measured_accel);

/* A rope at accelref earns all of accel; one at a third of it earns a third. */
CHECK (fabsf (accel_at (1536.f) - 1500.f) < 1.f, "accelref earns the whole accel");
CHECK (fabsf (accel_at (512.f) - 500.f) < 1.f, "a third of accelref earns a third");

/* accelmin is a floor, not a scale: a very short rope still gets 0.2. */
CHECK (fabsf (accel_at (16.f) - 300.f) < 1.f, "accelmin floors the short-rope pull");

/* A slack rope does nothing at all: velocity is untouched. */
CHECK (VectorCompare (vel_before, vel_after), "a slack rope is an ordinary fall");
```

- [ ] **Step 2: Run it and watch it fail**

Run: `tools/check-unit.sh 2>&1 | grep -A10 grapple_swing`
Expected: FAIL or LINK FAIL, because `Grapple_SwingFrame` still takes a hook
edict.

- [ ] **Step 3: Rewire the swing onto the C anchor, with freed-entity safety**

Change `Grapple_SwingFrame` to one argument and replace
`VectorSubtract (hook->v.origin, player->v.origin, rope)` with
`Grapple_AnchorOrigin (anchor); VectorSubtract (anchor, player->v.origin, rope)`.
Everything from `rope[2] -= GRAPPLE_ROPE_UP;` onward is unchanged, which is the
point: the feel is the code, and the code is not being rewritten.

`Grapple_AnchorOrigin (vec3_t out)`:
- `qr_grapple_anchor_num == 0`: copy `qr_grapple_anchor_ofs` out.
- otherwise `ed = EDICT_NUM (qr_grapple_anchor_num)`; if `ed->free`, convert the
  anchor to a static one by writing the last resolved world position into
  `qr_grapple_anchor_ofs`, setting `qr_grapple_anchor_num = 0`, and continuing
  the swing. **This is Review Focus 1.** The residual risk is accepted and
  belongs in a comment: an edict number freed and reused inside one swing would
  move the anchor to a new entity, which is a rope that follows the wrong thing
  rather than a crash, and no cheaper check exists that does not cost a field.
- otherwise `VectorAdd (ed->v.origin, qr_grapple_anchor_ofs, out)`.

Add the test for it in this step:

```c
/* a freed anchor entity converts to a static anchor and keeps swinging */
ed->free = true;
Grapple_SwingFrame (&player);
CHECK (qr_grapple_anchor_num == 0, "a freed anchor entity falls back to world");
CHECK (qr_grapple_state == GRAPPLE_ANCHORED, "the swing survives its anchor dying");
```

- [ ] **Step 4: Delete the progs path**

Remove from `grapple_avp.c`: `GRAPPLE_ITEM_BIT`, `grapple_supported`,
`grapple_setammo`, `grapple_reset`, `grapple_ofs_hook_out`,
`grapple_ofs_on_hook`, `grapple_ofs_hook`, `Grapple_FieldOfs`, `Grapple_Hook`,
`Grapple_SetKey`, `qr_grapple_key`, `qr_grapple_prev_weapon`, `Grapple_Engage`'s
weapon write and `W_SetCurrentAmmo` call, `Grapple_AssertBind`,
`Grapple_TuneHook`, `qr_grapple_thrown`, `Grapple_Active`, and the
`GRAPPLE_FLOAT` / `GRAPPLE_EDICT` macros.

Keep in reduced form: `Grapple_FuncByName`, `Grapple_Call`,
`Grapple_ResolveProgs` and `grapple_crc_key` / `grapple_progs_key`, which Task 3
needs for the one optional `T_Damage` lookup. `Grapple_ResolveProgs` keeps its
CRC key and its state reset, and the comment explaining why the key is the CRC
and not the pointer stays exactly as it is: it documents a measured SIGSEGV and
a still-latent bug in `admin_avp.c:57`.

Rewrite the file's header comment. It currently opens by explaining that rogue
ships a hook which is unreachable, which stops being what this file is about.
Keep the historical record of why the rails model was abandoned and why the
pendulum is the 1997 model, because that reasoning still governs the code.

- [ ] **Step 5: Keep every cancel path, and the long frame**

The `Grapple_Frame` state machine keeps: `qr_grapple_locked` and its
re-press rule, the `key_dest == key_game` gate on the press, the `sv.paused`
guard, the friction borrow and release, and the chained re-throw. Two of its
branches have nothing left to test and go: the weapon-stolen branch, and the
`!usable` branch's `grapple_supported` term.

The paused guard is now wider than it was and the comment must say so: with a
C-owned hook, a paused frame would advance both the flight trace and the spring
on a frozen `sv.time`.

Add to `grapple_swing_test.c`:

```c
/* a 0.1 s frame, which both QC_Frame and Host_FilterTime permit, must not
   diverge: stiff is clamped at 1/(dt*dt) */
host_frametime = 0.1;
CHECK (speed_after_one_frame < 2.f * vr_grapple_haul_value,
       "a long frame cannot outrun haul (%.1f)", speed_after_one_frame);
```

- [ ] **Step 6: Reimplement the chained re-throw deliberately**

The automatic re-throw while the grip stays held after a miss or a timeout is
currently rogue's `W_FireGrapple` re-firing on its own. It is part of the feel
and it disappears silently with the progs path. In `Grapple_Frame`, when the
state is `GRAPPLE_IDLE` and the engagement is live and the grip is still held
and the lock is clear, call `Grapple_Throw` again.

- [ ] **Step 7: Pin the respawn case**

Add to `gymtest.c`: hold the grip, `QC_ExecuteCommand ("kill\n")`, run 60
frames, and assert the state is `GRAPPLE_IDLE` on every frame after the
respawn until the grip is released and re-pressed. **This is Review Focus 4**,
and it is a measured historical bug rather than a hypothetical.

- [ ] **Step 8: Run everything**

```sh
make check                    # host compile, NOT a visionOS build
tools/check-unit.sh
build/gymtest <basedir>       # rebuild it first, as in Task 1 Step 8
```

Expected: all `ok:`. In particular `gymtest` must still show the hook
anchoring, and must now also show the player's velocity changing after the
anchor, which is the swing running on C state.

- [ ] **Step 9: Pin the game-switch case and commit**

Add to `gymtest.c`: anchor a swing, then `QC_ExecuteCommand ("map gym\n")` to
force a respawn of the server, run 30 frames, and assert `sv_friction` is back
to its pre-swing value and `qr_grapple_state == GRAPPLE_IDLE`. **This is Review
Focus 3.**

```bash
git add Sources/QuakeCore/platform/grapple_avp.c Sources/QuakeCore/platform/grapple_avp.h tools/unittest/grapple_swing_test.c tools/range/gymtest.c
git commit -m "feat(grapple): swing on a C anchor and delete the progs driver"
```

---

## Task 3: The hook hurts what it hits

**Files:**
- Modify: `Sources/QuakeCore/platform/grapple_avp.c`
- Modify: `tools/range/gymtest.c`

**Interfaces:**
- Consumes: `Grapple_FuncByName`, `Grapple_Call` and `Grapple_ResolveProgs` as reduced in Task 2. `PR_ExecuteProgram (func_t fnum)` from `Sources/QuakeCore/engine/progs.h:76`; `G_FLOAT(o)`, `G_INT(o)` and `EDICT_TO_PROG(e)` from `progs.h:105-113`; `OFS_PARM0` through `OFS_PARM3` from `Sources/QuakeCore/engine/pr_comp.h:45-48`.
- Produces: `static func_t grapple_damage;` and `static void Grapple_Damage (edict_t *player, edict_t *targ, float damage);`

- [ ] **Step 1: Resolve `T_Damage` optionally**

In `Grapple_ResolveProgs`, add
`grapple_damage = Grapple_FuncByName ("T_Damage");` and nothing else. It is
**not** part of any capability gate. The comment must say why, and say it the
way `grapple_ofs_tptime`'s comment already does at `grapple_avp.c:228-233`: a
progs without the function loses the damage, not the hook.

- [ ] **Step 2: Implement `Grapple_Damage`**

`T_Damage (entity targ, entity inflictor, entity attacker, float damage)`, so
four parameters. Set them with `G_INT (OFS_PARM0) = EDICT_TO_PROG (targ)`,
`OFS_PARM1` and `OFS_PARM2` likewise with the player as both inflictor and
attacker, and `G_FLOAT (OFS_PARM3) = damage`. Then run it with `self` and
`other` saved and restored, on the model of `admin_avp.c:254-259`, because
`IN_Commands` runs inside `Host_Frame`'s error frame and a QuakeC runaway in
here must unwind as a think would.

Return early when `grapple_damage` is 0, when `targ` is NULL or free, or when
`targ->v.takedamage` is 0.

Damage amount: a new cvar `vr_grapple_damage`, default `"10"`, `CVAR_NONE`,
registered in `Grapple_Init` beside the others and added to
`Grapple_ForceDefaults`. 10 is rogue's own hook damage per hit and is therefore
the value that changes nothing for a player who already knows the weapon.

- [ ] **Step 3: Call it from the anchor latch, once**

In `Grapple_FlightFrame`, where the anchor is latched and `tr.ent` is not the
world. Once per throw, not per frame: a rope that keeps hurting what it is tied
to is a different weapon and nobody asked for it.

- [ ] **Step 4: Verify in the gym**

Add to `gymtest.c`: the gym has no monsters, so spawn one with
`QC_ExecuteCommand ("impulse 101\n")` if the gym provides a spawner, and
otherwise assert the negative case only, which is cheap and still worth
pinning:

```
ok: a world anchor calls no progs function  (grapple_damage unused, no PR error)
ok: an anchor on a non-damageable entity is harmless
```

Then assert the monster case on device, where a real map has monsters, and say
in the report that the damage path was verified on device rather than on the
host.

- [ ] **Step 5: Run and commit**

```sh
make check                    # host compile, NOT a visionOS build
tools/check-unit.sh
build/gymtest <basedir>
```

```bash
git add Sources/QuakeCore/platform/grapple_avp.c tools/range/gymtest.c
git commit -m "feat(grapple): hooking a monster hurts it, through an optional T_Damage"
```

---

## Task 4: The rope and hook head reach the screen

The first task with a criterion that cannot pass on a black screen.

**Files:**
- Modify: `Sources/QuakeCore/include/QuakeCore.h`
- Modify: `Sources/QuakeCore/platform/grapple_avp.h`
- Modify: `Sources/QuakeCore/platform/grapple_avp.c`
- Modify: `Sources/QuakeRenderer/bridge/qr_bridge.c`
- Modify: `Sources/QuakeRenderer/RendererCore.swift`
- Modify: `App/Sources/ImmersiveRenderer.swift`

**Interfaces:**
- Produces, in `QuakeCore.h` as new `qc_frame_t` fields placed beside the existing laser and reticle vertex ranges so the packet's grouping stays readable:
  - `int grapple_state;` 0 idle, 1 flying, 2 anchored
  - `float grapple_tip[3];` world position of the hook head, in the same space as an entity origin in this packet
- Produces, in `grapple_avp.h`, engine-thread only, called from the packet builder: `int QR_GrappleState (float tip[3]);` returns the state and fills `tip`.
- Produces, in `RendererCore.swift`: `func drawGrappleRope (tip: SIMD3<Float>, handTransform: simd_float4x4, anchored: Bool)`, called from the same place and under the same conditions as `drawVirtualHand`. It draws **both** ends: the rope from the hand to `tip`, and the hook head at `tip`, oriented along the rope. Whether the head is an alias model loaded with `Mod_ForName (name, false)` from a candidate list or generated geometry is the builder's call, per the design. If it is an alias model, note that `COM_AddGameDirectory (com_basedir, GAMENAME)` always mounts `id1` first, so `progs/spike.mdl` is loadable in every pack regardless of what the current map precached; resolve it once and keep the pointer rather than loading on a throw.

- [ ] **Step 1: Add the packet fields and the reader**

`QR_GrappleState` returns `qr_grapple_state` and copies `qr_grapple_tip`, except
in `GRAPPLE_ANCHORED` where it must return `Grapple_AnchorOrigin`'s result
rather than the stale latch position, or the rope's far end will not follow a
moving platform.

- [ ] **Step 2: Publish it from the packet builder**

One call in `QR_BuildFramePacket` in `qr_bridge.c`, beside where the laser and
reticle ranges are set. Zero both fields in the same place the packet's other
per-frame ranges are reset, so a frame with no grapple cannot inherit the last
one's tip.

- [ ] **Step 3: Run the host compile**

Run: `make check`
Expected: links clean. New undefined symbols here would mean the renderer
boundary moved and `r_null.c` needs a stub, which it should not for a reader
this shape.

- [ ] **Step 4: Draw the rope Swift-side**

In `RendererCore.swift`, beside `drawVirtualHand`, which is the model to follow
for the whole pipeline: the same overlay pass, the same per-eye uniform scheme,
the same vertex buffer discipline.

The rope is drawn from the **live render-time hand transform**, not from the
packet, and this is the single most important line in the task. The off hand is
late-latched and the gun is not; a rope anchored to the packet's drained pose
would separate from the drawn fist on every hand movement. The hand end comes
from the same pose that draws the fist in the same frame; only the far end comes
from the packet.

In `ImmersiveRenderer.swift`, call it where the off-hand model is already
published, gated on `packet.grapple_state != 0`.

- [ ] **Step 5: Verify on device, visibly**

Launch detached, no debugger: `make run`, then tap the app in the headset.
Audio and the immersive space both break under lldb, so this cannot be a
debugger run.

The criteria that cannot pass on a black screen, all four reported as described
frames or captures:

```
the hook head is visible leaving the hand, not the chest
the rope connects the hand to the hook head for the whole flight
the rope stays attached to the fist while the hand is moved quickly
                              (this is the late-latch criterion: watch the joint)
the rope's far end sits on the surface the hook stuck to, and tracks a
                              moving platform if one is hooked
```

- [ ] **Step 6: Commit**

```bash
git add Sources/QuakeCore/include/QuakeCore.h Sources/QuakeCore/platform/grapple_avp.h Sources/QuakeCore/platform/grapple_avp.c Sources/QuakeRenderer/bridge/qr_bridge.c Sources/QuakeRenderer/RendererCore.swift App/Sources/ImmersiveRenderer.swift
git commit -m "feat(grapple): draw the rope and hook with the hand that threw them"
```

**Report to A. at the end of this task:** this is the first step that looks
different in the headset, so it owes a line of its own telling him to capture
device footage before the next task churns it.

---

## Task 5: The throw moves to the off hand, and the gun stays live

**Files:**
- Modify: `Sources/QuakeCore/include/QuakeCore.h`
- Modify: `Sources/QuakeCore/platform/in_null.c`
- Modify: `Sources/QuakeCore/platform/grapple_avp.c`
- Modify: `App/Sources/ImmersiveRenderer.swift`
- Modify: `tools/range/gymtest.c`

**Interfaces:**
- Produces, in `QuakeCore.h` and `in_null.c`: `void QC_InputSetOffAim (int valid, float fwd, float right, float up, float yaw, float pitch);` an any-thread producer mirroring `QC_InputSetAim` at `in_null.c:286-297` exactly, writing `qc_offaim_*_shared` under `qc_input_lock`, drained by `IN_SnapshotInputs` into `qr_offaim_*`.
  - A dedicated setter rather than the reserved `QC_InputSetTeleport` org/yaw/pitch channel. That channel was named for this and either is defensible, but it is also live plumbing for the teleport commit, and a feature that reads half of a struct another feature writes is the kind of coupling this project has already paid for once. Say so in the comment and delete the "kept in the pipe for a future PSVR dual-wield" notes at `in_null.c:1601-1603` and `App/Sources/HandInput.swift:933-934,950`, which this makes obsolete.
- Produces, in `in_null.c`: `int QR_OffHandOrigin (vec3_t out);` the twin of `QR_HandOrigin` at `in_null.c:1364-1381`, same body-frame math against `qr_offaim_org` and gated on `qr_offaim_active`.

- [ ] **Step 1: Add the setter and the drain**

Mirror `QC_InputSetAim`. Reject non-finite values the way
`QC_ExportSetBodyYaw` does at `in_null.c:131-132`.

- [ ] **Step 2: Add `QR_OffHandOrigin`**

Identical to `QR_HandOrigin` except for which staging variables it reads.
Factor the shared body-frame math into one static helper taking the origin and
the active flag, so the two cannot drift: that drift is exactly what a reviewer
will look for.

- [ ] **Step 3: Publish the off-hand pose from Swift**

In `ImmersiveRenderer.swift`, at the place the off-hand pose is already resolved
for the hand model, call `QC_InputSetOffAim` with it, in the same body-frame
form `feedAim` uses. `TrackRecorder.feedAim` is documented as the single road
into `QC_InputSetAim`; do not route the off-hand ray through it, because the
`.vrtrack` sidecar carries exactly one ray and export replay is explicitly out
of scope. Leave a comment saying that, so the next person does not read the
asymmetry as an oversight.

- [ ] **Step 4: Throw from the off hand**

In `Grapple_Throw`, replace `QR_HandOrigin` with `QR_OffHandOrigin` and take the
direction from `qr_offaim_yaw` / `qr_offaim_pitch` instead of `player->v.v_angle`.
Fall back to `QR_HandOrigin`, then to the body offset, so a session with no
off-hand pose still throws rather than doing nothing.

- [ ] **Step 5: Prove the gun survives, on the host**

Add to `gymtest.c`, and this is the assertion the whole milestone exists for:

```
ok: the weapon is unchanged across a whole engagement
        (player->v.weapon equals its pre-throw value on every frame)
ok: cl.viewent.model is still the gun's model while anchored
        (not v_grpple.mdl, and not null)
ok: firing while anchored still fires
        (fire the gun mid-swing and assert the shot count rises)
```

- [ ] **Step 6: Run and verify on device**

```sh
make check                    # host compile, NOT a visionOS build
tools/check-unit.sh
build/gymtest <basedir>
make run                      # then tap the app in the headset, detached
```

Visible criteria:

```
the rope leaves the off hand, and the gun is still in the other one
shooting works through a whole swing
the rope tracks the off-hand fist, not the gun
```

- [ ] **Step 7: Commit**

```bash
git add Sources/QuakeCore/include/QuakeCore.h Sources/QuakeCore/platform/in_null.c Sources/QuakeCore/platform/grapple_avp.c App/Sources/ImmersiveRenderer.swift App/Sources/HandInput.swift tools/range/gymtest.c
git commit -m "feat(grapple): throw from the off hand and leave the gun alone"
```

---

## Task 6: The weapon wheel may open mid-swing

**Files:**
- Modify: `Sources/QuakeCore/platform/grapple_avp.c`
- Modify: `tools/range/gymtest.c`

**Interfaces:**
- Consumes: `Grapple_Frame (uint32_t padbits, int wheel_open)`, whose second argument stops being a cancel and becomes a hold.

- [ ] **Step 1: Write the failing assertion**

In `gymtest.c`: anchor a swing, open the wheel, run 60 frames.

```
ok: the wheel does not cancel an anchored swing   (state stays ANCHORED)
ok: the rope does not advance under time dilation (rope rest length unchanged)
ok: the swing resumes when the wheel closes       (velocity changes again)
```

- [ ] **Step 2: Run it and watch it fail**

Expected: the first line fails, because `wheel_open` disengages today.

- [ ] **Step 3: Make the wheel a hold rather than a cancel**

Remove `!wheel_open` from the `want` expression in `Grapple_Frame`. Instead,
while `wheel_open` is set, skip `Grapple_SwingFrame` and `Grapple_FlightFrame`
exactly as the `sv.paused` branch already does, and for the same reason: the
wheel's time dilation eases `host_frametime`, every grapple number was tuned at
full rate, and an un-integrated spring impulse on a slowed frame is the near
neighbour of the measured pause catapult (two seconds of pause took the player
from 393 to 7036 u/s).

Hold, not scale. The comment should say that bullet-time swinging was
considered and rejected as a separate tuning problem, so that the next reader
does not think it was missed.

- [ ] **Step 4: Run and commit**

```sh
make check                    # host compile, NOT a visionOS build
build/gymtest <basedir>
```

```bash
git add Sources/QuakeCore/platform/grapple_avp.c tools/range/gymtest.c
git commit -m "feat(grapple): the ring no longer cancels a swing, it pauses the rope"
```

---

## Task 7: Predicted hand and controller poses

A prerequisite for the fist, not a nice-to-have: hand tracking drops joints on a
closed fist, so the gesture that throws the hook is the gesture that loses the
hand. It is also the unfixed half of the 2026-11-13 slideshow diagnosis, where
the engine pacer was fixed and the hand was not.

**Files:**
- Modify: `App/Sources/SpatialControllerTracker.swift`
- Modify: `App/Sources/HandInput.swift`
- Modify: `Sources/QuakeRenderer/ImmersiveRenderer.swift`

- [ ] **Step 1: Measure before writing anything**

Add a temporary per-second count and `anchor.timestamp` delta print to
`SpatialControllerTracker.store`, launch detached, and read it in Console.app.
**Do not implement prediction blind.** The question the number answers is
whether the accessory stream is slow or whether the consumer is sampling a
stale pose, and those have different fixes.

Report the measured rate before Step 2.

- [ ] **Step 2: Predict in the render loop**

Use `AccessoryAnchor.predictAnchor(for:at:)` with the render frame's
`timing.presentationTime`, which is what the head pose already uses, and
`HandTrackingProvider.handAnchors(at:)` for the bare-hand path. All four of
those APIs have zero usages in the repo today.

- [ ] **Step 3: Verify on device, visibly**

```
the hand model keeps up with a fast wave (no slideshow)
a closed fist does not drop the hand
the hand and the gun move at the same apparent rate
```

Per the project's own rule: if a rate is ever in question, watch the gun and not
the fps tile, which reads the compositor's presented rate and not the packet's.

- [ ] **Step 4: Commit**

```bash
git commit -m "fix(hands): predict the hand pose to the frame it is drawn in"
```

---

## Task 8: The bare-hands fist throws the hook

**Files:**
- Modify: `App/Sources/HandInput.swift`

**Interfaces:**
- Consumes: Task 7's predicted poses; `QC_PAD_RSHOULDER` from `Sources/QuakeCore/include/QuakeCore.h:613`.

- [ ] **Step 1: Detect a closed fist on the off hand**

A new gesture class, not a fifth pinch: the off hand's four pinches are all
spent (index walk forward, middle walk back, pinky crouch, ring teleport
commit). `HandInput.swift` sets only two pad bits in the whole file today; this
adds the third, `QC_PAD_RSHOULDER`, which is the bit `Grapple_Frame` reads.

- [ ] **Step 2: Suppress the off hand's other gestures while the fist is held**

Follow the existing precedent for a whole-hand gesture rather than inventing
one. **The suppression must clear edge latches, not merely mask the bits:**
releasing a fist passes through the ring pinch's release edge, which is the
teleport commit, so a masked-only implementation ends every swing in a
teleport.

The player has air control only during a bare-hands swing, which is A.'s
decision and needs no movement remap. Say so in a comment, because a reader
will otherwise read the lost bindings as a bug.

- [ ] **Step 3: Verify on device**

```
a fist throws the hook, with no controllers connected
releasing the fist lets go of the rope
releasing the fist does NOT teleport
walking still works once the fist is open
```

- [ ] **Step 4: Commit**

```bash
git add App/Sources/HandInput.swift
git commit -m "feat(grapple): a closed off hand throws the hook with no controllers"
```

---

## Task 9: All six games, and the documentation that is owed

**Files:**
- Modify: `Sources/QuakeCore/platform/grapple_avp.c`
- Modify: `tools/range/gengym.py`
- Modify: `tools/range/genrange.py`
- Modify: `tools/range/README.md`
- Modify: `README.md`
- Modify: `docs/decisions.md`

- [ ] **Step 1: Add the capability print**

A `Con_Printf` on the first engage after a progs change, naming the game
directory and whether `T_Damage` resolved. This is the cheap observation that
would refute the prediction that every id1-derived progs carries it, and the
project's standing rule after the hook-spawns-at-the-chest miss is that a claim
an existing mechanism already covers a new case is a prediction until the new
case has run through it.

- [ ] **Step 2: Verify each game on device**

`id1`, `hipnotic`, `rogue`, `dopa`, `mg1`, `mg3`, switched through the window's
Game tab, which is the in-session switch that has broken this feature before.
For each: throw, anchor, swing, release, and confirm the gun is untouched.

Report a table of six rows with the resolved `T_Damage` state per game. A game
where it does not resolve is not a failure, it is a hook that does no damage,
and the print is what tells the difference between that and a broken hook.

- [ ] **Step 3: Fix the stale comments**

- `tools/range/gengym.py:23-26` and `tools/range/genrange.py:179-182` both size
  the column spacing against `vr_grapple_range 1600`. The shipped default is
  24000; 800 and 1600 were rogue's and were abandoned.
- `tools/range/gengym.py:275` says the grapple is reached through the ring. It
  is not on the ring in any game and never was.
- `tools/range/README.md` is missing `-subdivide 480`, which is load-bearing:
  following the README literally produces a map over `MAX_MAP_LIGHTING`.

- [ ] **Step 4: Write the decision entry**

`docs/decisions.md` has had nothing added since 2026-10-23, across the grapple,
the test range and the pacer fix. Add one entry for this work: that the hook
moved into platform C, and the three things that bought (the off hand, the other
five games, and the removal of the `1<<23` collision with `HIT_LASER_CANNON`).

- [ ] **Step 5: Update the README**

The README's controls table says the weapon wheel rings the off wrist, which
stopped being true when the ring moved to the right to free the left grip for
the hook. The grapple is not in the README at all. **`README.md` is published to
GitHub, so it is vetted by A. before it is pushed:** show him the full text and
wait for an explicit yes, and do the one protective wording pass at that moment.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuakeCore/platform/grapple_avp.c tools/range/gengym.py tools/range/genrange.py tools/range/README.md docs/decisions.md README.md
git commit -m "feat(grapple): one hook in all six games, and say so"
```

---

## Notes for whoever executes this

**The feel is the acceptance test, and it is device-only.** Tasks 1 through 3
can be fully proven on the host, and none of them proves the thing that
matters. A. has twice called the current swing perfect; the pendulum code is
reused unchanged specifically so that parity is plausible, but plausible is not
measured. Before Task 1 begins, A. should have captured device footage of the
current swing, because that clip is the only durable record of the bar.

**Do not change the hand and the mechanism in one device session.** Task 4 ends
with the hook working in the dominant hand. Task 5 moves it. If both land before
a single test, a feel regression cannot be attributed.

**The host harness is more capable than it looks.** `tools/hostmain.c` runs ten
frames and anything with a ramp needs 30 to 40, which has twice been
misdiagnosed as "this needs the headset". `tools/range/rangetest.c` is the
working precedent for a driver that boots the engine, loads a map and asserts
against real geometry. Before concluding something needs the device, check
whether the loop is simply too short.

**`Grapple_ForceDefaults` stays for now** and comes out when the numbers settle,
at which point the eleven cvars go back to `CVAR_ARCHIVE`. It exists because
`CVAR_ARCHIVE` controls whether a value is written to `config.cfg`, not whether
one is read, and eight sessions of tuning were silently reverted by a
`config.cfg` written before any of them existed.
