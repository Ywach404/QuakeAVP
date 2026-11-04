# Per-game weapon tables Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the weapon wheel read `cl.items` correctly in id1, dopa, mg1, mg3, hipnotic and rogue, by keying every weapon on its view model instead of on a bit or a ring position.

**Architecture:** C becomes the sole owner of the bit tables. A new translation unit holds 17 weapon identities, each with a list of acceptable view-model names, and one row per game mapping bit to identity, selected by the engine's `rogue`/`hipnotic` globals plus the `com_gamedir` basename. The bridge resolves bit to identity before publishing, so the frame packet carries an owned-identity mask and an active identity rather than raw bits, and Swift keeps no bit table at all. Placement becomes per identity, widening the persisted stride from 8 to 17 through a pure, host-tested migration.

**Tech Stack:** C (QuakeSpasm 0.97 style, tabs, `Function_Name (args)`), Swift 6 with `@Observable`, `swiftc` host harness for pure Swift units, `make check` for all ~62 C translation units, `make compile` for the real visionOS target.

**Spec:** `docs/designs/2026-10-30-per-game-weapon-tables.md`

## Global Constraints

- **Do not edit `Sources/QuakeCore/engine/`.** There are exactly six patched hunks and this work needs no seventh. Everything here lives in `platform/`, `bridge/` or Swift.
- **`make check` after every C change.** It compiles every translation unit and links, in seconds. New undefined symbols mean the renderer boundary moved. Never silence it with `-Wl,--allow-undefined`.
- **`make check` is not a visionOS build.** Say which one was run. `make compile` is the only thing that proves the real target short of the device.
- **Thread rule.** Every `QC_*` call is engine-thread except the `QC_Renderer*` consumer API (exactly one render thread at a time, only inside `RendererCore.withConsumer`) and the documented any-thread setters. `QC_SetWeaponPlacement` stays any-thread: whole table under `qc_place_lock`, replaced outright, drained on the engine thread.
- **Cvar defaults stay byte-identical to upstream.** `vr_weapon{back,up,side,grip}` remain the global fallback and the console's way in.
- **Stubs must be honest.** Anything that consumes network bytes or is read back by the sim must be correct, not a no-op.
- **No attribution trailers, no em dashes, no en dashes**, in code, comments, commit messages or documents. Conventional Commits: type prefix, summary, body with the reasoning.
- **Exact values from the spec:** `QC_WEAPON_SLOTS` = 17. Stride 17, arrays 68 (4 variants x 17). Identities 0 to 7 are the vanilla eight in their existing order. Expected ring counts: id1/dopa/mg1 = 8, mg3 = 10, hipnotic = 11, rogue = 13. Rogue's weapon map is masked to bits 0 through 16. Active identity publishes as **identity plus one**, 0 meaning none. Persisted key counts: placement v3 = 96, v2 = 48, v1 = 64; front/rear v3 = 32, v2 = 16, no v1.
- **No impulse number or kind is committed that was not read off the device.** Zero means unmeasured.

## Review Focus

Five conditions the spec implies that no task's happy path exercises, most likely to bite first:

1. **An unrecognised game directory** (a third-party mod, or `ctf`, which A. ruled out). Must fall to the vanilla row and show exactly the vanilla eight, never a phantom and never a crash. Host-tested in Task 3 Step 4.
2. **An owned weapon whose model fails to resolve.** The ring and the commit must agree it is absent, or the commit selects the wrong weapon. One published mask makes this structural rather than testable, so it is verified by instrument: `weapontable` prints bit-set and model-resolved per entry, and Task 8 Step 5 confirms such an entry is excluded from the count.
3. **A device still holding v2, or holding v1 placement only.** The chains differ in length: placement reaches v1, front and rear stop at v2. Unit-tested in Task 1.
4. **`game` switched twice in one session.** `Mod_ResetAll` reuses `mod_known[0]`, so a worldmodel-only cache key silently serves the previous game's models. Not unit-testable: verified on device by Task 8 Step 5, whose five `game` switches through the autoexec rig are exactly this sequence.
5. **The axe held as the active weapon.** Identity 0 plus the existing `!= 0` guard would starve it of its trim in every game. Unit-tested in Task 6 Step 1.

---

### Task 1: The pure persistence migration

The only genuinely unit-testable piece, and the one whose silent failure destroys A.'s hand-tuned numbers. It lands first and depends on nothing.

**Files:**
- Create: `App/Sources/WeaponTrimMigration.swift`
- Create: `tools/swifttest/weapons_test.swift`
- Create: `tools/check-swift-weapons.sh`

**Interfaces:**
- Consumes: nothing. Imports `Foundation` only, so `swiftc` can compile it alone.
- Produces:
  - `enum WeaponTrimMigration`
  - `static let identityCount = 17`
  - `static let variantCount = 4`
  - `static func widen(_ old: [Float], oldStride: Int) -> [Float]` for front/rear, returning `variantCount * identityCount` entries, old entries index-preserved per variant, new tail filled with `fill`
  - `static func widen(_ old: [Placement?], oldStride: Int) -> [Placement?]` for placement, new tail `nil`
  - `static func decodePlacement(flat: [Double], stride: Int, columns: Int) -> [Placement?]?` returning nil on a count mismatch, NaN meaning untuned
  - `struct Placement: Equatable { var back, up, side: Float }`

- [ ] **Step 1: Write the failing test**

In `tools/swifttest/weapons_test.swift`, a `main`-style runner matching `session_test.swift`'s existing shape (a `check(_:_:)` helper that prints and exits non-zero on failure). Assertions:

```swift
// identity-preserving widening, per variant
let old: [Float] = (0..<32).map { Float($0) }
let new = WeaponTrimMigration.widen(old, oldStride: 8)
check(new.count == 68, "widened front/rear is 4 * 17")
check(new[0]  == 0,  "variant 0 slot 0 preserved")
check(new[7]  == 7,  "variant 0 slot 7 preserved")
check(new[17] == 8,  "variant 1 slot 0 lands at 17, not 8")
check(new[51] == 24, "variant 3 slot 0 lands at 51")
check(new[16] == 1,  "variant 0 new tail is the fill value")

// placement decode: NaN is untuned, not zero
let flat = [1.0, 2.0, 3.0] + Array(repeating: Double.nan, count: 93)
let pl = WeaponTrimMigration.decodePlacement(flat: flat, stride: 32, columns: 3)
check(pl?.count == 32, "v3 placement decodes 32 slots from 96 doubles")
check(pl?[0] == .init(back: 1, up: 2, side: 3), "slot 0 decoded")
check(pl?[1] == nil, "NaN decodes to nil, meaning follow the cvars")

// the count gates, which are what stop a v2 blob being read as v3
check(WeaponTrimMigration.decodePlacement(flat: flat, stride: 16, columns: 3) == nil,
      "a 96-double blob is rejected as v2 (48)")
check(WeaponTrimMigration.decodePlacement(flat: [], stride: 32, columns: 3) == nil,
      "empty is rejected, not treated as all-untuned")

// Review Focus 3: v1 carries a fourth grip column, and front/rear have no v1
let v1 = (0..<64).map { Double($0) }
let p1 = WeaponTrimMigration.decodePlacement(flat: v1, stride: 16, columns: 4)
check(p1?.count == 16, "v1 decodes 16 slots from 64 doubles at stride 4")
check(p1?[1] == .init(back: 4, up: 5, side: 6), "v1 skips the grip column")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tools/check-swift-weapons.sh`
Expected: FAIL at compile, "cannot find 'WeaponTrimMigration' in scope".

- [ ] **Step 3: Write `tools/check-swift-weapons.sh`**

Copy `tools/check-swift-session.sh` exactly, including the GPL SPDX header and the copyright line, changing only the `OUT` name, the comment describing what it compiles, and the file list, which is `tools/swifttest/weapons_test.swift` plus `App/Sources/WeaponTrimMigration.swift` and nothing else. The point of the harness is that the migration compiles with no app module, no Observation and no bridge.

- [ ] **Step 4: Implement `WeaponTrimMigration` in `App/Sources/WeaponTrimMigration.swift`**

Both `widen` overloads take the fill for new slots as a parameter defaulted per type (`1` for front/rear keep-fractions, `nil` for placement), because a new slot must mean "untuned", never zero. `decodePlacement` returns nil unless `flat.count == stride * columns`.

- [ ] **Step 5: Run the test to verify it passes**

Run: `sh tools/check-swift-weapons.sh`
Expected: PASS, all checks printed.

- [ ] **Step 6: Commit**

```bash
git add App/Sources/WeaponTrimMigration.swift tools/swifttest/weapons_test.swift tools/check-swift-weapons.sh
git commit -m "feat(trim): pure weapon-trim migration, widened to 17 identities"
```

---

### Task 2: The ABI, widened to identities

**Files:**
- Modify: `Sources/QuakeCore/include/QuakeCore.h:723-731` (placement block), and the frame packet near `:405-412`
- Modify: `Sources/QuakeCore/platform/in_null.c:43-50`, `:211-247`

**Interfaces:**
- Produces:
  - `typedef enum { QC_WEAPON_AXE = 0, ... QC_WEAPON_GRAPPLE = 16, QC_WEAPON_IDENTITIES = 17 } qc_weapon_identity_t` with the 17 names from the spec's identity table, in that order
  - `#define QC_WEAPON_SLOTS QC_WEAPON_IDENTITIES`
  - `void QC_SetWeaponPlacement (const qc_weapon_placement_t *slots, int count);`
  - `int QR_WeaponPlacement (int identity, float *back, float *up, float *side);`
  - `const char *QC_WeaponLabel (int identity);` an any-thread accessor over immutable static data, so Swift can name a weapon without keeping a label table of its own. This is how the spec's "prefer reading labels over mirroring them" is satisfied without putting 17 strings in the frame packet. Document it as any-thread in the header, alongside the existing any-thread list.
  - `qc_frame_t` gains `uint32_t owned_identities;` (bit N set means identity N is owned and drawable) and `uint32_t active_identity;` (identity plus one, 0 meaning none)

- [ ] **Step 1: Add the identity enum, widen `QC_WEAPON_SLOTS`, and add the count parameter**

Rewrite the placement block comment: it currently names the eight weapons in wheel order and says "one entry per weapon slot in wheel order", which stops being true. It must now say one entry per weapon IDENTITY, that identities are game-independent, and why (a weapon's placement is a property of its model, not of which bit carries it in which game). Keep the existing paragraphs about grip and about pulled-not-pushed; they are still correct and still earn their place.

- [ ] **Step 2: Add the two frame fields**

Document `owned_identities` as superseding `items` as the wheel's source of truth, and say why in one line: `cl.items` means different things in different games, so the bridge resolves it. Leave `items` in place, still published, since the HUD and the export path read it.

Document `active_identity` as identity plus one, naming the reason: identity 0 is the axe and the consumer's "nothing held" test is a zero check.

- [ ] **Step 3: Widen the store and switch the reader to identities in `in_null.c`**

`qc_place_shared[QC_WEAPON_SLOTS]` follows the constant. `QC_SetWeaponPlacement` takes the count and copies `MIN(count, QC_WEAPON_SLOTS)` entries, zeroing any remainder, so a stale or short caller can no longer read past the end. `QR_WeaponPlacement`'s parameter is renamed `identity` and its bounds check follows the constant.

- [ ] **Step 4: Run the C check**

Run: `make check`
Expected: compiles every translation unit and links with no undefined symbols. The only expected warnings are the three pre-existing unknown-warning-option notes and the `AngleVectors` const-qualifier warnings in `qr_bridge.c`.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuakeCore/include/QuakeCore.h Sources/QuakeCore/platform/in_null.c
git commit -m "feat(abi): weapon placement keyed by identity, 17 slots with a count"
```

---

### Task 3: The identity table and the per-game bit maps

**Files:**
- Create: `Sources/QuakeRenderer/bridge/qr_weapons.c`
- Create: `Sources/QuakeRenderer/bridge/qr_weapons.h`
- Modify: the Makefile's translation unit list, only if it does not glob the bridge directory

**Interfaces:**
- Consumes: `qc_weapon_identity_t` from Task 2.
- Produces:
  - `typedef struct { uint32_t bit; uint8_t identity; uint8_t impulse; uint8_t kind; } qr_weapon_entry_t` with kind one of `QR_SELECT_DIRECT`, `QR_SELECT_TOGGLE`, `QR_SELECT_CYCLE`
  - `const qr_weapon_entry_t *QR_WeaponRow (void);` zero-bit terminated, selected for the current game
  - `const char *QR_WeaponLabel (int identity);`
  - `const char *const *QR_WeaponViewModels (int identity);` NULL-terminated list of acceptable view-model names
  - `const char *QR_WeaponPickupModel (int identity);` NULL when the game ships none
  - `int QR_WeaponRearClip (int identity);` the per-identity flag replacing the raw index test
  - `int QR_WeaponIdentityForBit (uint32_t bit);`
  - `uint32_t QR_WeaponGameKey (void);` a cheap stable token for the selected row, for cache keys
  - **`const char *QC_WeaponLabel (int identity);` must be DEFINED here.** Task 2 declared it in the header but deliberately left the definition out, because a label table in `in_null.c` would mirror the one this file owns. Define it here, as `QR_WeaponLabel` itself or a one-line forwarder. Without it Task 6's Swift link fails on an undefined symbol, and `make check` will not catch that because no C translation unit calls it.

- [ ] **Step 1: Write the identity table and the four per-game rows**

The 17 identities with their model-name lists, labels and pickup models come verbatim from the spec's identity table. Every name is under `progs/`. Identity 1 lists `v_shot.mdl` and `v_bloodshot.mdl`; identity 2 lists `v_shot2.mdl` and `v_bloodshot2.mdl`; identity 9 lists `v_hammer.mdl` and `v_hammer_glow.mdl`.

The four rows are vanilla, mg3, hipnotic and rogue. The **vanilla eight carry impulses 1 through 8 as `QR_SELECT_DIRECT`**, in the existing table order (axe 1, shotgun 2, super shotgun 3, nailgun 4, super nailgun 5, grenade launcher 6, rocket launcher 7, thunderbolt 8), because that is what the current `impulse b + 1` already does and it is therefore measured by shipped behaviour rather than assumed. They carry the same numbers in every row.

**Every other entry is impulse 0**, awaiting Task 8. That includes rogue's axe: it keeps a different bit from vanilla's, so whether it is still impulse 1 is not something shipped behaviour has ever established. Treat 1 as the expectation to confirm, not as a value to commit.

Rogue's row stops at bit `1<<16`. Put a comment on it naming why, because it looks like an omission: `sv_main.c` ORs `items2 << 23` into the published word for any progs defining an `items2` field, and rogue is that game, so bits 23 and up are armour and powerups rather than weapons.

- [ ] **Step 2: Write the selector**

`QR_WeaponRow` tests `rogue`, then `hipnotic`, then looks the `com_gamedir` basename up in a short name list holding only `mg3`, falling through to vanilla. `rogue`, `hipnotic` and `com_gamedir` come by `extern` from `common.h`, which `quakedef.h` already pulls in. Cache the resolved row against `QR_WeaponGameKey` so the basename comparison is not done per frame.

- [ ] **Step 3: Add the console command that reads the table on device**

`QR_WeaponTable_f`, registered as `weapontable`, printing one line per row entry: identity, label, bit, whether the bit is currently set in `cl.items`, whether a model resolved, impulse and kind. Then a final line giving the ring count. This is the instrument Task 8 and every open question are measured with, and it is also the only way to read a count without trusting the ring's own arithmetic.

- [ ] **Step 4: Verify the new translation unit is compiled, and Review Focus 1**

Run: `make check`
Expected: the translation unit count rises by one from 62 to 63, and the link is clean. If the count stays at 62 the Makefile does not glob and needs the file added.

Then, with a host boot (`make check` accepts a basedir), run `weapontable` under a directory not in the name list and confirm the vanilla row is selected and the count is 8.

- [ ] **Step 5: Add `QC_WeaponLabel` to the thread rule's any-thread list**

`docs/working-notes.md` enumerates the any-thread `QC_*` functions by name. `QC_WeaponLabel` belongs on it, since it reads immutable static data and the consumer calls it off the engine thread. A function that is any-thread in practice but absent from that list is how the next person reasons about it wrongly.

- [ ] **Step 6: Commit**

```bash
git add Sources/QuakeRenderer/bridge/qr_weapons.c Sources/QuakeRenderer/bridge/qr_weapons.h docs/working-notes.md
git commit -m "feat(wheel): per-game weapon rows and 17 identities"
```

---

### Task 4: Rework the wheel to resolve and publish identities

**Files:**
- Modify: `Sources/QuakeRenderer/bridge/qr_bridge.c` at the four tables (`:5580-5615`), `QR_WheelSlot` (`:5587`), `QR_ActiveWeaponBit` (`:5620-5644`), `QR_EmitWheel`'s statics and resolution pass (`:7064-7122`), the owned count (`:7123-7128`), the emit loop (`:7307`), the rear clip (`:7383`), the spin (`:7343`), the placement pull (`:7778-7793`) and the packet (`:8245-8249`)

**Interfaces:**
- Consumes: everything Task 3 produces, and Task 2's frame fields.
- Produces: `uint32_t QR_OwnedIdentities (void);` an engine-thread global holding the resolved owned set from the last frame build, for Task 5's commit to read.

- [ ] **Step 1: Delete the four hardcoded tables and point their readers at Task 3**

`qr_wheel_bits`, `qr_wheel_modelnames`, `qr_wheel_pickupnames` and `qr_wheel_labels` all go. `QR_WheelSlot` becomes `QR_WeaponIdentityForBit`. `QR_ActiveWeaponBit` becomes `QR_ActiveIdentity`, matching the drawn view model against each identity's name LIST rather than one name, and falling back to resolving the raw stat through the current row. Move the `QR_MENU_SPACING` define out from between two of the departing tables and up with the other defines.

- [ ] **Step 2: Resolve models per identity, and fix the cache key (Review Focus 4)**

The resolution pass walks the current row rather than `0..<8`, and tries each name in an identity's list in order, preferring the pickup model as today. Size the statics by `QC_WEAPON_IDENTITIES`. The cache key becomes the pair `(cl.worldmodel, QR_WeaponGameKey ())`, and the comment must say why the worldmodel alone is not enough: `COM_Game_f` calls `Mod_ResetAll`, which memsets every `qmodel_t` and resets `mod_numknown` to 0, so the next world lands back at the same address and a pointer comparison cannot see the change.

- [ ] **Step 3: Publish one owned set, and close the enumeration gap (Review Focus 2)**

Two housekeeping items that belong in this step because they are in these exact lines. The frame reset near `qr_bridge.c:7992` clears the packet field by field rather than with a `memset`, so `owned_identities` and `active_identity` must be added to it or they carry across a reset. And the `extern` at `qr_bridge.c:90` still spells `QR_WeaponPlacement`'s first parameter `slot`; it compiles either way, but rename it to `identity` since this task is already in the file.


Compute the owned-identity mask once, requiring both the bit in `cl.items` and a resolved model, store it for `QR_OwnedIdentities`, and publish it in the packet along with the active identity plus one. The emit loop and the owned count both read that one mask, so the drawn ring and anything counting it cannot disagree.

- [ ] **Step 4: Per-identity rear clip and a spin that follows the count**

The rear clip reads `QR_WeaponRearClip (identity)` instead of testing `i != 0 && i != 7`. The spin stagger uses the `step` already computed from the owned count instead of a hardcoded 45 degrees.

- [ ] **Step 5: Feed `QR_WeaponName`'s one caller the identity**

It is only reached from the `vr_projdebug` print, and it is currently handed the raw truncated stat, which is why the axe prints "(none)" in the diagnostic that working-notes names as the check that the projectile-spawn hunk survived. Give it the identity and have it return `QR_WeaponLabel`.

- [ ] **Step 6: Run the C check**

Run: `make check`
Expected: clean link, 63 translation units. New undefined symbols here would mean a `QR_Weapon*` entry point is missing from Task 3.

- [ ] **Step 7: Commit**

```bash
git add Sources/QuakeRenderer/bridge/qr_bridge.c
git commit -m "feat(wheel): resolve and publish weapon identities, not raw item bits"
```

---

### Task 5: Move the ring commit to the input drain

Separate from Task 4 because it has its own failure mode: a commit that cannot be missed must not become one that can.

**Files:**
- Modify: `Sources/QuakeCore/platform/in_null.c` at the wheel-highlight drain (near `:600`)
- Modify: `Sources/QuakeRenderer/bridge/qr_bridge.c`, removing the full-menu gaze commit at `:7270-7283`

- [ ] **Step 1: Move the commit**

The drain reads `QR_OwnedIdentities`, turns the released highlight index into an identity by walking that mask, looks the identity's entry up in the current row, and issues the selection. The commit leaves `QR_EmitWheel` entirely, so weapon selection no longer depends on the renderer having built a frame.

- [ ] **Step 2: Implement the three selection kinds**

`QR_SELECT_DIRECT` sends `impulse N`. `QR_SELECT_CYCLE` and `QR_SELECT_TOGGLE` send `impulse 10` and re-check on the next drain, stopping when `QR_ActiveIdentity` equals the target, bounded by the owned count so a weapon that cannot be reached cannot spin forever. Impulse 0, meaning unmeasured, prints a one-line console notice naming the identity and sends nothing.

- [ ] **Step 3: Run the C check**

Run: `make check`
Expected: clean link, 63 translation units.

- [ ] **Step 4: Commit**

```bash
git add Sources/QuakeCore/platform/in_null.c Sources/QuakeRenderer/bridge/qr_bridge.c
git commit -m "fix(wheel): commit selection on the input drain, not during frame build"
```

---

### Task 6: WeaponTrim on identities

**Files:**
- Modify: `App/Sources/WeaponTrim.swift` throughout: the `bits` table (`:44`), the baked defaults (`:55-110`), the stride (`:163-191`), `summary()` (`:158-186`), `resetCurrentPlacement` (`:264-267`), `publish()` (`:281-291`), `save()` (`:351-364`), `load()` (`:366-410`), `legacyLoad()` (`:412-426`), `frame(activeWeapon:)` (`:306-320`)
- Modify: `tools/swifttest/weapons_test.swift`, adding the Review Focus 5 case

**Interfaces:**
- Consumes: `WeaponTrimMigration` from Task 1, `QC_SetWeaponPlacement(_:_:)`, `QC_WeaponLabel(_:)` and `qc_frame_t.active_identity` from Task 2.
- Note: `WeaponTrim` already declares its own `struct Placement`, and Task 1 declares one too. Do not keep both. `WeaponTrim` takes `typealias Placement = WeaponTrimMigration.Placement` and its own definition goes, so the migration and its caller cannot drift in field order.

- [ ] **Step 1: Write the failing test for Review Focus 5**

The axe is identity 0 and the existing guard is a zero check, so the decode from the published value is what must be tested, not the whole class:

```swift
check(WeaponTrimMigration.identity(fromPublished: 1) == 0, "published 1 decodes to identity 0, the axe")
check(WeaponTrimMigration.identity(fromPublished: 0) == nil, "published 0 means nothing held")
check(WeaponTrimMigration.identity(fromPublished: 17) == 16, "published 17 decodes to the last identity")
```

- [ ] **Step 2: Run it to verify it fails**

Run: `sh tools/check-swift-weapons.sh`
Expected: FAIL, no `identity(fromPublished:)`.

- [ ] **Step 3: Add `static func identity(fromPublished: UInt32) -> Int?` to `WeaponTrimMigration`**

Returns nil for 0, else `Int(published) - 1`, rejecting anything at or above `identityCount + 1`.

- [ ] **Step 4: Run it to verify it passes**

Run: `sh tools/check-swift-weapons.sh`
Expected: PASS.

- [ ] **Step 5: Widen `WeaponTrim` to the 17-identity stride**

Delete the `bits` table outright; nothing in Swift maps a bit any more. Keep the three 8-stride baked literals **exactly as they are**, rename them to say 8 rather than 32 if it reads better, and expand them through `WeaponTrimMigration.widen` at init. Do not retype the numbers; they are A.'s device tuning and hand-restriping is where it gets lost. `slot` becomes `variant * 17 + identity`. `index(for:)` goes, replaced by the published identity, and the no-slot case must be nil rather than falling back to slot 1, which is the live bug where an unrecognised weapon wears the shotgun's tuning and overwrites it. `publish()` builds `QC_WEAPON_SLOTS` entries and passes the count. `frame` takes the published identity and decodes it through Step 3, so the zero guard keeps meaning "nothing held" and the axe survives. `summary()` drives its loop off the stride and takes its names from the labels the frame carries rather than its own array.

- [ ] **Step 6: Write the v4 keys and the full chains**

`save()` writes `weaponTrimFront.v4`, `weaponTrimRear.v4` (68 each) and `weaponPlacement.v4` (204 doubles). `load()` tries v4 first, then falls through: placement to v3 (96), v2 (48) and v1 (64), front and rear to v3 (32) and v2 (16) with no v1, each gated on an exact count, each widened through Task 1, and each leaving slots the old format cannot speak to at the code default. Keep the two chains independent, because a device can be mid-chain on one and not the other, and keep the early `return` on placement so a v3 hit does not fall through to v2.

- [ ] **Step 7: Verify**

Run: `sh tools/check-swift-weapons.sh` then `make compile`
Expected: the harness passes; `make compile` builds for visionOS. `make check` alone cannot see a Swift error, so `make compile` is the gate here and the report must say which was run.

- [ ] **Step 8: Commit**

```bash
git add App/Sources/WeaponTrim.swift App/Sources/WeaponTrimMigration.swift tools/swifttest/weapons_test.swift
git commit -m "feat(trim): key placement and trim by weapon identity, v4 persistence"
```

---

### Task 7: WheelState on the published owned set

**Files:**
- Modify: `App/Sources/WheelState.swift`: the `bits` table (`:35`), `ownedCount()` (`:227-229`), `impulseForOwnedIndex` (`:231-238`), `setHold` (`:86-113`), the header invariant comment (`:14-18`)
- Modify: `Sources/QuakeRenderer/ImmersiveRenderer.swift:686-688` and `Sources/QuakeRenderer/WorldRenderer.swift:85`, for the changed `frame` signatures

- [ ] **Step 1: Replace the bit table with the published mask**

`bits` goes. `ownedCount()` becomes the mask's population count, which closes the Swift half of the enumeration gap: C already excluded identities whose model did not resolve, so the two sides now count the same set by construction rather than by coincidence. `frame` takes `ownedIdentities` and `activeIdentity` instead of `items`.

- [ ] **Step 2: Drop the impulse derivation**

`impulseForOwnedIndex` goes entirely, along with `setHold`'s `sendCommand` of an impulse string. The commit now lives in C (Task 5); `pushLocked` already ships only the highlight index, which becomes the whole contract.

- [ ] **Step 3: Correct the header comment**

It currently asserts the two sides "cannot disagree about what the ring contains" because both derive the owned set from `cl.items`. That reasoning is now wrong even though the conclusion is now stronger: there is one enumeration, computed in C and published, and Swift derives nothing. Say that instead.

- [ ] **Step 4: Verify**

Run: `make compile`
Expected: builds for visionOS. State plainly that this is not a device run.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/WheelState.swift Sources/QuakeRenderer/ImmersiveRenderer.swift Sources/QuakeRenderer/WorldRenderer.swift
git commit -m "refactor(wheel): consume the published owned-identity set"
```

---

### Task 8: Device measurement, and the counts

Nothing in Tasks 1 to 7 can fill the impulse column or answer the spec's three open questions. This task is a headset session, and it is the only thing that makes the feature usable rather than merely correct.

**Files:**
- Modify: `Sources/QuakeRenderer/bridge/qr_weapons.c`, filling the impulse and kind columns with measured values only
- Modify: `docs/designs/2026-10-30-per-game-weapon-tables.md`, recording the answers in its open-questions section

- [ ] **Step 1: Install and launch detached**

Run: `make run`. Launch without the debugger: lldb's ptrace disrupts the audio and compositor XPC and can hang the immersive layer, which looks exactly like an app bug. Read the log via `tools/run-device.sh --console` or Console.app.

- [ ] **Step 2: Answer open question 1, which the whole alarm rests on**

Under `game id1`, run `impulse 9` then `weapontable`. Record whether bit 7 is set. If it is not, the "a vanilla ring of 9 is the failure announcing itself" alarm is silent and the spec's anti-goal needs a different test, which must be written before trusting any count below.

- [ ] **Step 3: Answer open question 3, which sizes the rogue row**

Under `game rogue -rogue`, `impulse 9` then `weapontable`. Record which of bits 11 through 16 are set in `cl.items`. If the five powered-up bits are not ownership bits, rogue's row shrinks to the axe plus the base seven and the expected count becomes 8, not 13. Settle this from the printed word, not from the previously observed glitched ring, which the Task 4 cache-key bug also explains.

- [ ] **Step 4: Measure the ten impulses and their kinds**

For each of hipnotic's three, mg3's two and rogue's five: hold the weapon, try the candidate impulse, and record whether it selects directly, toggles against another weapon, or is reachable only by cycling. mg3's help text offers nothing beyond impulse 8, so expect cycle or toggle there. Write the measured number and kind into the row. Leave anything unmeasured at 0.

- [ ] **Step 5: Confirm the counts, and the one the count cannot catch**

Per game, `weapontable` and read the ring total: id1, dopa, mg1 = 8; mg3 = 10; hipnotic = 11; rogue = 13 or the Step 3 answer. The autoexec rig fires `map range` then `impulse 9` on every `game` change, which is what makes this five switches rather than five launches. **Leave `Documents/id1/autoexec.cfg` exactly as it is.** Then, under rogue, pick up a green armour and confirm the count does not move: that is the regression test for the `items2` overlay, and it is the one no count alone can catch.

- [ ] **Step 6: Report the visible criterion alongside the numbers**

Per working-notes, a count can be right while every model is the axe. For each game, describe or capture a frame showing each weapon on the ring wearing its own model and its own label, and the held gun sitting correctly in the hand.

- [ ] **Step 7: Commit**

```bash
git add Sources/QuakeRenderer/bridge/qr_weapons.c docs/designs/2026-10-30-per-game-weapon-tables.md
git commit -m "feat(wheel): measured selection impulses for the mission packs"
```

---

## Notes for whoever executes this

- Tasks 1 and 2 are independent of each other. Tasks 3, 4 and 5 are a chain. Tasks 6 and 7 both need Task 2's ABI and cannot land before it.
- A passing `make check` is necessary and not sufficient. Green unit tests have twice hidden live failures in this repo: a shader wrapper that passed while emitting GLSL that would not compile, and a rate limiter that passed while charging an attacker-supplied IP. For anything spanning C and Swift, the device is the proof.
- The publish flow's modals (`NSOpenPanel`, `NSSavePanel`, `NSAlert`) block on human input and cannot be driven. Nothing in this plan touches them, but the weapon tuning UI is reached through the window, so expect a human to click it.
- When this lands, four games' rings will look different in the headset for the first time, including six rogue models this project has never drawn. That is footage worth capturing the day it lands.
