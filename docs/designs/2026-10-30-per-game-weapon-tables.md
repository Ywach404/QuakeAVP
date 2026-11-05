# Per-game weapon tables for the wheel -- design

Written 2026-10-30. Supersedes the "add a ninth slot" plan in
`docs/plans/2026-10-28-episodes-and-obstacles.md` and the CORRECTION section
that followed it.

Four of that plan's premises are wrong, and a fifth claim of mine was wrong
until a builder review caught it. All of them were settled by reading the games'
own compiled QuakeC and the engine's server code, not the engine's headers. The
corrections come first, because they change the shape of the work.

## What was measured, and what it corrects

Every bit value below was read out of the `progs.dat` globals table in A.'s dump
(`avp-pomodoro/QuakeDump/`, classic and `rerelease/` both). The engine's
`IT_`/`HIT_`/`RIT_` defines describe what upstream expects; the progs describe
what a game actually ships. Where the two disagree, the progs win.

Scope, set by A. on 2026-10-30: **the packs and the expansions, not ctf.** So
id1, dopa, mg1, mg3, hipnotic and rogue, all in one pass. ctf is left out
deliberately and the consequence is recorded under scope below.

| game | weapons beyond the vanilla seven | ring total |
|---|---|---|
| `id1`, `dopa`, `mg1` | axe `1<<12` | 8 |
| `mg3` | axe `1<<12`, **Mjolnir `1<<7`**, laser cannon `1<<23` | **10** |
| `hipnotic` | axe `1<<12`, Mjolnir `1<<7`, proximity gun `1<<16`, laser cannon `1<<23` | 11 |
| `rogue` | **axe `1<<11`**, lava nailgun `1<<12`, lava super nailgun `1<<13`, multi grenade `1<<14`, multi rocket `1<<15`, plasma gun `1<<16` | 13 |

**Correction 1: mg3 has the Mjolnir, so it is a ten-weapon game, not nine.**
Its progs define `IT_MJOLNIR = 128` alongside `IT_LASER_CANNON`, and it ships
`progs/v_hammer.mdl`. It has no proximity gun. The plan's expected device count
of 9 for mg3 is wrong.

**Correction 2: the three engine globals cannot select the table.** The plan
proposed keying off `standard_quake` / `rogue` / `hipnotic`, reasoning that "a
bit means a weapon only in the game that defines it". That holds for hipnotic
and rogue. It fails for mg3, and it would fail for ctf too if ctf were in scope.
`COM_Game_f` only sets `hipnotic` when given `-hipnotic`, and mg3 is launched as
a bare `game mg3`, so it reports `standard_quake` exactly as id1 does. Its
Mjolnir sits on bit `1<<7`, which is `IT_SUPER_LIGHTNING` in vanilla: the very
bit `impulse 9` grants. Select on the globals alone and vanilla grows a phantom
Mjolnir, which is the plan's own announcing-itself failure arriving through the
door it thought was shut. **The selector needs the game directory as well as the
flags.**

**Correction 3: rogue's grapple exists, but its ownership cannot be read from
`cl.items`, so it does not go on the ring.** Rogue's progs define
`IT_GRAPPLE = 1<<23` and ship `progs/v_grpple.mdl`. An earlier draft of this
document put it on the ring as rogue's fourteenth weapon. That was wrong, and
the reason is in the server, not the progs. `sv_main.c:883`:

    val = GetEdictFieldValue(ent, "items2");
    if (val)
        items = (int)ent->v.items | ((int)val->_float << 23);
    else
        items = (int)ent->v.items | ((int)pr_global_struct->serverflags << 28);

Rogue is the game that defines `items2`, so under rogue **`cl.items` bits 23 and
up carry `items2`, not the progs' own items word.** Bit 23 is `items2` bit 0,
which upstream's own statusbar reads as `RIT_ARMOR1`, green armour
(`sbar.c:973`, `quakedef.h:167`). The grapple and green armour therefore alias
onto one published bit and cannot be told apart. Put the grapple on the ring and
rogue grows a phantom grapple every time the player picks up green armour.

So: **rogue's weapon map is masked to bits 0 through 16**, and the grapple keeps
an identity so it can be drawn and tuned if it is ever held, but it has no
ownership bit and never joins the ring. Rogue's ring total is 13, which is the
number the plan guessed; it is right for a different reason than the plan's
arithmetic, which counted the axe plus five and stopped.

**Correction 4, now out of scope but recorded so it is not rediscovered: ctf is
a nine-weapon game with a grappling hook.** Its progs define `IT_HOOK = 128` and
it precaches `progs/v_star.mdl`. ctf does not define `items2`, so its sigils ride
the `serverflags << 28` branch above and bits 23 to 27 stay clear. A. has ruled
ctf out of this work, so there is no ctf row; see scope.

**Aside worth recording:** between rogue's grapple and ctf's hook, a grappling
hook already ships in two games in A.'s dump, with models, needing no custom
`progs.dat`. ctf's is the one that is actually readable from `cl.items`, which
is worth knowing if a grappling hook is ever wanted for its own sake.

## Intent

One `cl.items` word means different things in different games. Make the wheel
read it correctly in each, so a mission pack or a re-release episode brings its
own arsenal without the ring showing the wrong gun under the wrong label.

## Goals

- The ring shows the weapons the player owns, in every game in the dump, with
  the right model, label and placement.
- A.'s device-tuned placement and trim survive, and extend themselves to the
  games that share a weapon's model.
- One owner for each fact. No value restated on both sides of the C/Swift
  boundary.

## Non-goals

- Deriving an arsenal dynamically from arbitrary mod content. The plan is right
  that this is a feature and not release work. This design covers the known
  games.
- The modular HUD's ammo tile and the controller feel tables. See the scope
  section.
- Any upstream engine hunk. Nothing here needs one, and there are six.

## Anti-goal

Shipping a count that looks right in vanilla. A vanilla ring of 9 is the
failure, and this design is wrong if it produces one. Note the alarm itself
needs confirming: see open question 1.

## The designed change: key everything by weapon IDENTITY

Today three separate things index the same eight slots: the item bit, the ring
position, and the placement row. All three break at once under rogue. Replace
them with one stable identity, defined as **the weapon's view model**.

Identity is the right key because it is what the tuning is physically about. A.
tuned where `progs/v_shot.mdl` sits in his hand. That stays true in vanilla, in
hipnotic, in rogue and in mg3, whichever bit happens to carry it.

The payoff is concrete: **rogue's axe is the same axe.** Rogue's pak contains no
`v_axe.mdl` and its progs precache `progs/v_axe.mdl`, so it resolves from id1
through the search path that keeps `id1` beneath the mod directory. Under
identity keying, rogue's axe at `1<<11` inherits A.'s tuned axe placement with
no migration entry and no second tuning session. Under index keying it would
start from nothing.

An identity owns a **list** of acceptable view-model names, not one name. mg3
swaps `v_shot.mdl` for `v_bloodshot.mdl` under its bloody-nightmare mode
(`impulse 227`/`228`/`223` in its own help strings) and also ships
`v_hammer_glow.mdl`. Those are the same weapons wearing another model, so they
alias to the same identity and keep A.'s tuning. Two extra identities would
split it in half.

### The identity table

Seventeen identities. The vanilla eight keep indices 0 to 7, which is what makes
the persistence migration a widening rather than a remap.

| id | weapon | view model(s) | pickup model | games |
|---|---|---|---|---|
| 0 | axe | `v_axe.mdl` | none | all |
| 1 | shotgun | `v_shot.mdl`, `v_bloodshot.mdl` | none | all |
| 2 | super shotgun | `v_shot2.mdl`, `v_bloodshot2.mdl` | `g_shot.mdl` | all |
| 3 | nailgun | `v_nail.mdl` | `g_nail.mdl` | all |
| 4 | super nailgun | `v_nail2.mdl` | `g_nail2.mdl` | all |
| 5 | grenade launcher | `v_rock.mdl` | `g_rock.mdl` | all |
| 6 | rocket launcher | `v_rock2.mdl` | `g_rock2.mdl` | all |
| 7 | thunderbolt | `v_light.mdl` | `g_light.mdl` | all |
| 8 | laser cannon | `v_laserg.mdl` | `g_laserg.mdl` | hipnotic, mg3 |
| 9 | mjolnir | `v_hammer.mdl`, `v_hammer_glow.mdl` | `g_hammer.mdl` | hipnotic, mg3 |
| 10 | proximity gun | `v_prox.mdl` | `g_prox.mdl` | hipnotic |
| 11 | lava nailgun | `v_lava.mdl` | none | rogue |
| 12 | lava super nailgun | `v_lava2.mdl` | none | rogue |
| 13 | multi grenade | `v_multi.mdl` | none | rogue |
| 14 | multi rocket | `v_multi2.mdl` | none | rogue |
| 15 | plasma gun | `v_plasma.mdl` | none | rogue |
| 16 | grapple | `v_grpple.mdl` | none | rogue, held only |

All paths are under `progs/`. Every name was listed out of the pak directories,
not guessed, which matters more than it looks: ring membership requires a
*resolved* model, so a wrong name does not error, it silently drops the weapon
out of the wheel.

Rogue ships no `g_*` pickup models at all, so its weapons fall back to their
view models and take the rear vertex clip, which is per-identity trim and
therefore already handled.

### Selecting the per-game bit map

One table per game mapping bit to identity, chosen by:

1. `rogue` set, use the rogue row, **masked to bits 0 through 16** per
   Correction 3.
2. `hipnotic` set, use the hipnotic row. This also covers Quoth, which both
   `COM_InitArgv` (launch argument) and `COM_Game_f` (console) fold into
   `hipnotic`.
3. Otherwise look the `com_gamedir` basename up in a short name list. `mg3` gets
   its own row. Anything unrecognised gets vanilla.

Step 3 is what the plan did not have, and it exists because mg3 is a
`standard_quake` game with a non-vanilla arsenal. Keep the list in C beside the
tables; it is a property of the shipped games, not configuration. A bare `game
rogue` or `game hipnotic` does set the globals through QuakeSpasm's
`-missionpack` extension (`common.c:2378-2385`), so only the `standard_quake`
games need naming. The list is where a ctf row would go if ctf is ever wanted.

The bridge can read all three globals and `com_gamedir` today by `extern` from
`common.h`, with no new plumbing.

## The ABI: publish identities, not bits

C becomes the sole owner of every bit table. `qc_frame_t` gains an
owned-identity mask and the active identity; the bridge resolves bit to identity
per game before publishing. Swift keeps no bit table at all.

This is a deliberate departure from the current shape, where `WheelState.bits`
and `WeaponTrim.bits` each restate the engine's table. `WheelState.swift`'s
header asserts the two sides "cannot disagree about what the ring contains",
which is true only while the tables are byte-identical. Per-game tables would
falsify that invariant five ways at once. Publishing identities makes it true by
construction rather than by discipline, and it is the same lesson as the
per-weapon placement table: the drawn weapon is known where it is drawn, so pull
the fact instead of mirroring it.

Consequences, with the decisions made:

- `QC_WEAPON_SLOTS` becomes **17** and means identities, not the biggest game's
  weapon count. Placement is per identity and game-independent.
- `QC_SetWeaponPlacement` **gains a count parameter.** Today it takes a bare
  pointer and the setter does `memcpy (qc_place_shared, slots, sizeof
  qc_place_shared)` against the destination's size, while Swift publishes a bare
  `count: 8`. Widening one side without the other is a 144-byte out-of-bounds
  read. This is latent today and goes live the moment the widths differ.
- **The active identity publishes as identity plus one, 0 meaning none.**
  `WeaponTrim.frame` guards on `activeWeapon != 0` (`WeaponTrim.swift:308`), so
  a raw index would make identity 0, the axe, indistinguishable from "nothing
  held" and the axe would silently never receive its trim, in every game. Plus
  one keeps the existing guard correct with no change at the call sites in
  `WorldRenderer` and `ImmersiveRenderer`. The in-comment claim at
  `WeaponTrim.swift:142` that every value fits in a byte is already false and
  should go.
- **The owned-identity mask is a single `uint32_t`.** Seventeen identities fit a
  word with room to spare.
- **The ring commit moves to the engine thread's input drain, not into frame
  emission.** The bridge computes the resolved owned set during the frame build
  and stores it in an engine-thread global; the drain in `in_null.c` reads that
  and issues the commit. Putting the commit inside `QR_EmitWheel` instead would
  couple weapon selection to the renderer and inherit a sampling hole, because
  the highlight is drained once per engine frame and an open-and-release inside
  one interval would never show an `open` edge. Swift's commit is synchronous
  today and must not get worse.

## Impulse: a measured column whose SHAPE is also unknown

Both sides currently derive the impulse from ring position: C emits `impulse
b + 1`, Swift's `impulseForOwnedIndex` returns `i + 1`. That is a vanilla
coincidence, where table order happens to equal impulse order 1 to 8, and it
cannot survive a ninth weapon.

The plan treats this as one missing number per weapon. It is worse than that.
mg3's own help strings enumerate what it supports:

    impulse 1-8 changes weapons
    impulse 255 also changes weapons
    impulse 10 cycles weapons
    impulse 12 cycles weapons backwards

There is no dedicated impulse for a ninth or tenth weapon. So the laser cannon
and the Mjolnir are reachable only by cycling, or by a toggle that shares one of
the 1 to 8 impulses. **A toggle is not a selector:** sending `impulse 1` while
holding the Mjolnir hands you the axe, so a per-identity integer is the wrong
model, not merely an unfilled one.

The impulse therefore lives in the **per-game row**, not in the identity table,
because the same weapon may be selected differently in two games: the laser
cannon is hipnotic's and mg3's, and mg3 is not launched as hipnotic. Each
per-game entry is `{ bit, identity, impulse, kind }` where kind is one of
`direct`, `toggle` (shares an impulse with another identity, so pressing it from
the wrong weapon gives you the wrong weapon) or `cycle`. Zero impulse still
means unmeasured.

**Decision, mine, for ratification:** the commit path for anything that is not
`direct` is to cycle with `impulse 10` and stop when the drawn view model
resolves to the target identity, bounded by the owned count so it cannot spin.
Identity-by-model is exactly what makes that checkable, which is a second reason
to key by it. An unmeasured identity is shown in the ring so A. can see it is
recognised, and selecting it logs and does nothing rather than firing a guess at
the server.

**No number and no kind goes into this table that was not read off the headset.**

## Persistence: a v4 widening, migrated per identity

`WeaponTrim` holds `front`, `rear` and `place` as flat 32-entry arrays strided
`variant * 8`, four variants of mode times limbs, with A.'s device tuning baked
into `defaultPlace32` and `defaultRear32`. The stride becomes 17 and the arrays
become 68.

The migration is one index-preserving widening per variant:

    new[v * 17 + w] = old[v * 8 + w]      for v in 0..3, w in 0..7

Identities 8 to 16 start with no placement, which means `nil`, which means fall
back to the global `vr_weapon*` cvars. That is what an unmeasured weapon should
do and it is the existing meaning of `nil`, not a new one.

**Widen the baked tables programmatically.** Keep the three 8-stride literals
exactly as they are and expand them to the new stride in a loop at init. Hand
restriping 68 entries across four variants is where the tuning gets lost, and
those numbers are the asset.

Properties of the existing v2-to-v3 precedent the v4 loader must keep:

- Each key gated on an **exact count**, falling through to the older key on a
  mismatch rather than reshaping.
- Slots the old format cannot speak to left at the **code default**, never
  zeroed.
- `load()` never writes back, so a live device can still be holding v2 when v4
  ships. The chains must be walked in full, and they are **not the same length**:
  placement runs v4, v3 (96), v2 (48), v1 (64); front and rear run v4, v3 (32),
  v2 (16) and have **no v1 key at all**. They migrate independently today and
  must continue to.

Write the remap as a **pure free function** and test it in the `tools/swifttest`
host harness, the way `GameDirectories` is tested. `WeaponTrim` touches
`UserDefaults` and calls into C from `init`, so it cannot be tested as it
stands; factoring the remap out is what makes the migration checkable before it
meets a device. This is the one place here where a test is worth more than a
device run, because a bad migration destroys A.'s tuning silently and a device
run would not notice.

`summary()` must grow with the stride too. It hardcodes an 8-entry `names`
array, `base = variant * 8` and three `0..<8` loops, and it is the only route by
which a tuning session becomes a code default, so it is not cosmetic. Drive it
off the stride and take the names from the C label table through the frame.

## Bugs to fix in the same pass

- **`models[]`'s cache key is a live stale-pointer bug, and the test rig
  triggers it.** `COM_Game_f` calls `Mod_ResetAll` (`common.c:2400`), which
  memsets every `qmodel_t` and sets `mod_numknown = 0` (`gl_model.c:249-253`).
  The next world therefore lands back at `mod_known[0]`, the same address, so
  the `cachekey != cl.worldmodel` test is false and the stale model pointers get
  reused: wrong models at best, `Mod_Extradata` on a zeroed model at worst. This
  is exactly the harness sequence, since the autoexec fires `map range` on every
  `game` change. Add the game to the key. The adjacent `qr_conchars_texnum` is
  correctly reset, so the model cache is the odd one out rather than the pattern.
- **The gaze commit and the drawn ring enumerate differently.** Ring membership
  requires `cl.items & bit` *and* a resolved model; the full-menu commit loop
  tests only `cl.items`, so a weapon whose model fails to resolve shifts the two
  apart and the commit fires at the wrong weapon. `WheelState.ownedCount()` has
  the same gap. Publishing one owned-identity mask from C closes both.
- **`WeaponTrim.index(for:)` falls back to slot 1 on an unknown bit**, so an
  unrecognised weapon wears the shotgun's tuning and overwrites it when a slider
  moves. Under rogue today the real axe does exactly this. It must return
  no-slot.
- **The rear clip identifies the axe and thunderbolt by raw index**
  (`i != 0 && i != 7`). Becomes a per-identity flag.
- **`QR_WeaponName` is fed the raw truncated stat**, so the axe already prints
  "(none)" in `vr_projdebug` output, which working-notes names as the check that
  the projectile-spawn hunk survived. Feed it the identity.
- **Ring spin stagger** is `k * 45` degrees, hardcoded as 360 over 8. Use the
  `step` already computed from the owned count.

### A premise of the plan to retract, not inherit

The plan states that `QR_WeaponName` is why "a mod's weapons fall through to
'(none)' and the wheel emits nothing". That is false. `QR_WeaponName` has one
caller, the `vr_projdebug` print, and is nowhere near the wheel. The wheel emits
nothing for a mod's weapons because its bit table does not contain their bits.
Same conclusion, different mechanism, and the stated mechanism would send a
builder to the wrong function.

The plan's list of slot-walking loops is also short by one: there are **six**,
and the one it omits is the full-menu gaze commit, which is precisely the one
this design changes. A builder following the plan's list would widen five of six.

## Out of scope, recorded so it is not chased later

- **ctf.** A. ruled it out on 2026-10-30: the packs and the expansions, not ctf.
  The consequence is honest and worth stating rather than hiding: ctf is a
  `standard_quake` game whose hook sits on bit `1<<7`, so with no ctf row it
  falls to the vanilla table and anyone loading `game ctf` sees a phantom
  thunderbolt-bit weapon, which is the same class of fault this design exists to
  remove. It is one row and one identity whenever it is wanted, and Correction 4
  above holds the measured facts so nothing needs rediscovering. Leaving the
  stride at 17 means adding it later costs a v5 migration, which is the trade A.
  accepted.

- `HudOverlay.activeAmmo` and the three `ControllerOutput` feel tables are
  id1-only bit switches, and they are **already wrong under rogue**, which
  shifts the four ammo bits down one so `IT_SHELLS` is rogue's nails. The weapon
  *label* comes from the new table, since A. saw wrong HUD glyphs on device; the
  ammo tile and the haptics are a follow-up unless they fall out of identity
  keying for free.
- Under `standard_quake` the server sends `STAT_ACTIVEWEAPON` as a raw byte, so
  mg3's laser cannon and Mjolnir arrive truncated. The bridge already resolves
  the held weapon from the drawn view model, which is the identity key this
  design adopts, so the wheel is fine. The fire-detection path still reads the
  raw stat and will treat those weapons as it treats the axe. Pre-existing, not
  made worse here.
- The engine's `HIT_WETSUIT` and `HIT_EMPATHY_SHIELDS` defines disagree with
  `sbar.c`'s own draw loop by one bit. Powerups, not weapons, and upstream has
  the same discrepancy.

## Verification

`make check` is the fast signal and is necessary and not sufficient. The real
proof is on device, and per working-notes every milestone needs a criterion that
cannot pass on a black screen.

**The rig already exists and stays exactly as it is.**
`Documents/id1/autoexec.cfg` holds `map range` then `impulse 9`: load the test
range, grant every weapon. It fires on startup and on every `game` change, which
is what makes it the harness for a per-game change. It was twice recommended for
removal earlier in this work because it stomps deliberate `map` commands during
episode testing. **Do not remove it.** `range` lives in `id1/pak2.pak` and stays
reachable from every game.

The acceptance criterion is a count per game, plus eyes on the ring:

| `game` | expected ring | measured on device 2026-11-05 | note |
|---|---|---|---|
| `id1` | 8 | **8, row vanilla** | the important case |
| `dopa` | 8 | **8, row vanilla** | fell through to vanilla by directory name |
| `mg1` | 8 | **8, row vanilla** | same |
| `mg3` | 10 | **10, row mg3** | corrected from the plan's 9 |
| `hipnotic` | 11 | **11, row hipnotic** | |
| `rogue` | 13 | **13, row rogue, axe on 2048** | and **pick up a green armour: the count must not change.** That is the Correction 3 regression test, and it is the one the count alone cannot catch. Still outstanding. |

**All six rows confirmed on device, every identity resolving a model.** Two
results are worth stating as more than ticks.

mg3 selected the **mg3** row rather than vanilla, carrying the Mjolnir on bit
128. That is Correction 2 proved rather than argued: mg3 reports
`standard_quake`, so the engine globals alone would have handed it the vanilla
row, and bit 128 is the one that makes a phantom appear in id1.

The vanilla row *contains* eight entries, so a phantom in id1 is impossible by
construction rather than merely absent on the day. That is stronger than the
count test this section originally specified, and it means open question 1
(whether `impulse 9` sets bit 7 in id1) no longer gates the anti-goal: the row
has no entry for that bit to land in.

Rogue reading its axe from 2048 is the original bug dead at the source.

Alongside the counts, not instead of them: a described frame per game showing
each weapon on the ring wearing its own model and its own label, and the held
gun sitting correctly in the hand. A count can be right while every model is the
axe.

## Open questions that must be answered on device, not guessed

1. **Does id1's `impulse 9` actually set bit 7?** The whole "a vanilla ring of 9
   is the failure announcing itself" alarm rests on it. id1's progs *define*
   `IT_EXTRA_WEAPON = 128`, but defined is not granted, and that cannot be
   settled from the globals table. If the cheat does not set it, the primary
   alarm is silent even with a fully broken table. Print `cl.items` after
   `impulse 9` in id1. One line, and it either confirms the net or replaces it.
2. **Every non-vanilla impulse, and its kind.** Ten measurements across three
   games: hipnotic's three (laser cannon, Mjolnir, proximity gun), mg3's two
   (laser cannon, Mjolnir, which may differ from hipnotic's), and rogue's five
   powered-up weapons. Hold the weapon, try the candidate, record whether it
   selects directly, toggles, or only cycles.
3. **ANSWERED on device 2026-11-05: yes, they are ownership bits. Rogue's row
   stays at 13.** Under Dissolution of Eternity with everything granted, all
   five came up owned with their models resolved, filling ring slots 8 to 12:
   lava nailgun `1<<12`, lava super nailgun `1<<13`, multi grenade `1<<14`,
   multi rocket `1<<15`, plasma gun `1<<16`. Thirteen entries, thirteen
   drawable.

   Worth keeping as a lesson rather than deleting. The doubt was reasonable and
   wrong: upstream never tests those five against `cl.items`, drawing them from
   `STAT_ACTIVEWEAPON` alone, so reading the ENGINE suggested they might be
   current-weapon identities rather than ownership flags. But what the engine
   chooses to read is not what the PROGS choose to set, and rogue's progs set
   them. That is the same rule as Correction 1: for what a game actually does,
   the game's own compiled code beats the engine's treatment of it, and a
   measurement beats both.

## What is left to the builder

- The exact shape of the per-game bit map. One zero-terminated
  `{ bit, identity }` array per game plus a `{ dir, row }` name list, sitting
  with the four existing tables. Move the `QR_MENU_SPACING` define currently
  wedged between two of those tables up with the other defines while there.
- Whether the Swift wheel keeps a label table or reads labels from the frame.
  Prefer reading, on the same no-mirrors reasoning as the bits.
- The spelling of the identity enum across the ABI, given the plus-one decision
  above.
