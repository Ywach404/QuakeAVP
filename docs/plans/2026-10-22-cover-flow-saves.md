# Cover Flow Save Browser Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the save-slot rows with a Cover Flow carousel whose cards are screenshots of the world you were standing in when you saved.

**Architecture:** Six tasks in two independent halves. Tasks 1–2 are pure SwiftUI and ship on their own — the carousel works with every save that already exists, showing a plain card. Tasks 3–6 add the picture: a `worldOnly` path through the existing encode, a remembered head pose, one offscreen mono pass at save time, and a backfill on first load. The halves meet at one optional file per save, so neither blocks the other.

**Tech Stack:** SwiftUI (visionOS), Metal via `RendererCore`/`ExportRenderer`, the pure-C renderer bridge, `swiftc` host tests.

**Spec:** `docs/designs/2026-10-22-save-browser.md`

## Status

- [x] **Task 1 — DONE, device-verified** · [x] **Task 2 — DONE, device-verified** · [ ] Task 3 · [ ] Task 4 · [ ] Task 5 · [ ] Task 6

## Task 1 outcome

Built, and confirmed working on device by A. Four defects found only by
putting it on the headset, all fixed:

1. **Tapping the hero card loaded it, and fired by accident.** The summon
   gesture releases over the window the instant it appears and landed as a
   tap, silently discarding the running game. Tapping now only selects; Load
   is the explicit button the rows always had.
2. **The flankers were clipped.** The content inset deliberately shrinks the
   measured region to one card, so every flanker lies outside it and the
   scroll view cut them. `scrollClipDisabled()`.
3. **A new save's card did not appear** until something forced a rebuild. The
   deck sorts newest-first, so a save prepends and every index shifts;
   `ForEach` diffs on name while `scrollPosition` is keyed on Int. The source
   component's `id()` on the scroll view existed for exactly this and was
   noted as needed when sorting by mtime -- and dropped anyway. Restored, and
   a new save now takes the selection.
4. **Overwrite was unreachable** except by typing an existing name. It is a
   button on the selected card now, naming what it replaces. The name field
   is gone: typing in a headset is miserable and the deck chooses the slot.

Lesson for the remaining tasks: both 2 and 3 were hazards handed over in the
reconnaissance and lost between reading them and writing the code. Re-read
the hazard list in each task immediately before implementing it, not before
planning it.

## Task 2 outcome

Built and confirmed on device 2026-10-22, by pushing real JPEGs onto the
headset by hand -- which is the whole reason this task was split out. The
cover path is proven end to end before anything exists that can produce one,
so any problem in Task 5 is in the capture, not the display.

Verified on device: a save with a cover shows it; a save with a ZERO-BYTE
cover shows the plain card (the mid-write guard); saves with no cover are
unaffected; a `.jpg` with no `.sav` produces no card.

One defect found, and only because the test images were deliberately the
wrong shape: `aspectRatio(contentMode: .fill)` may report a size LARGER than
the one it is offered, and a ZStack takes its largest child, so the card's
own frame could not clamp it -- a frame positions an oversized child, it does
not shrink one. A wide cover made a wide card. The image is pinned and
clipped now.

Worth keeping: real covers will be close to the card's aspect, where this
would have read as a design choice rather than a bug. Testing with
deliberately wrong-shaped inputs is what made it visible.

## Global Constraints

- **Never edit `Sources/QuakeCore/engine/`.** Nothing here needs to. `Sources/QuakeRenderer/bridge/qr_bridge.c` and `Sources/QuakeCore/include/QuakeCore.h` are ours and are fair game.
- **The cover is the WORLD only.** No SwiftUI panel, virtual hands, view weapon, reticle, arc gauges, wrist HUD tiles, wrist communicator, world-placed console plane, wheel ring, centerprint text or phase-ground grid. A cover with the gun in it is a **failed test**, not a matter of taste (A., 2026-10-22: "Just the world").
- **Thread rule.** `RendererCore.withConsumer` is an `NSLock`, not thread-affine. The cover pass runs on a **background thread** — never the CompositorServices render thread (THE RULE, `ImmersiveRenderer.swift:280-335`, four device SIGABRTs) and never the main actor. `cb.waitUntilCompleted()` goes **outside** the lock.
- **Input is hands and Sense controllers only.** Every affordance needs both. There is no pointer; gaze does not set SwiftUI focus and does not fire `onHover`.
- **Covers live beside their save**: `<name>.jpg` next to `<name>.sav` in `com_gamedir`, which is `Application Support/QuakeAVP/id1`. Swift learns it live from `qc_session_state_t.gamedir` → `SessionState.gameDirectory`.
- **`make device` is the only proof of the real target** and must pass before every commit. `make check` and `tools/check-unit.sh` must stay green. Say which was run.
- Window floor is 1100x900; the panel column is 560–680pt. The carousel must work at 560.

## Review Focus

Input classes the spec implies that no task's happy-path test covers. Each gets its test in the owning task.

1. **A save being written while the carousel is reading it.** `fopen(…,"w")` truncates before stdio flushes, so a mid-write scan reads zero bytes; the rows already hold a stale entry in place for this. A cover JPEG is a *second* mid-write file, so a half-written or zero-byte `.jpg` must show the plain card, never a broken image or a crash. → Task 2.
2. **A cover whose save has been deleted**, and a `.jpg` with no `.sav` at all. Must not appear as a card. → Task 2.
3. **Saving with no immersive space ever opened** — no remembered pose exists. Must write the save and simply no cover, not fail the save. → Task 5.
4. **The engine stopped.** Delete and Rescan are deliberately enabled with no engine running, and Load is deliberately *not* gated on `saveBlock` so a cold resume works. A carousel that gates these on `running` is a regression. → Task 1.
5. **Zero saves, and no game directory yet.** Two different empty strings today ("No saved games yet." / "Waiting for the engine."); a carousel with no cards must still say which. → Task 1.

---

### Task 1: The carousel replaces the rows

**Files:**
- Create: `App/Sources/SaveCoverFlow.swift`
- Modify: `App/Sources/ContentView.swift` — replace `saveLoadSection` (`:1165-1238`) and delete `saveSlotRow` (`:1240-1273`)
- Test: `tools/swifttest/session_test.swift`

**Interfaces:**
- Consumes: `SaveGameSlot` (with `difficulty`, `isLoadable`, `isAddressable`, `displayText`), `SessionState` (`slots`, `saveBlock`, `canSave`, `isSaving`, `save`, `load`, `delete`, `refreshSlots`).
- Produces: `SaveCoverFlow` view taking `slots: [SaveGameSlot]`, `selection: Binding<Int>`, and closures for load/delete. `CoverFlowMetrics` holding the five constants. `enum CoverBadge { case versionMismatch(Int), unaddressable }` with the exact caption text.

Port from `swiftui-gallery-seed/CoverFlowAssetBrowser` — these blocks are the component and are worth lifting with their comments:
`CoverFlowCarouselView.swift:24-42` (constants, including the sign-bug history at `:36-42`), `:129-141` (the `GeometryReader` + ScrollView chain), `:196-208` (the per-card transform), `:101-111` (the `scrollID`↔`selectedIndex` two-way sync with a guard on each side).
`AssetCardView.swift:27-46` (face, minus the favourite star), `:117-130` (the reflection strip).

Port hazards, all established — do not rediscover them:
- **`.contentMargins(.horizontal, (width - cardWidth)/2, for: .scrollContent)` is load-bearing and is NOT centring.** It shrinks the measured visible region to one card so only the centre card reaches `.identity`. Remove it and several cards sit flat with no Cover Flow at all.
- `ScrollTransitionPhase` is **three keyframes** (-1/0/+1), not a continuous value, so no easing can live in that closure. The five constants are the entire design surface.
- **`onMoveCommand` is `@available(visionOS, unavailable)`** — a hard compile error. Delete it.
- `rotation3DEffect`'s `perspective:` label decides the overload: with it, the flat macOS projection; without it, a **true depth rotation** in the window's volume. Keep `perspective: 0.7` for this task; the depth variant is a device-check option in Task 1's notes, not a default.
- `.ultraThinMaterial` is near-invisible on visionOS glass — re-derive the card fill as a dark solid.
- Drop the focus plumbing (`.focusable`/`.focused`, the auto-focus `onChange`, the `simultaneousGesture(TapGesture())`). Gaze does not set SwiftUI focus. For gaze response use `.contentShape(.hoverEffect, RoundedRectangle(cornerRadius: 10))` + `.hoverEffect()` on the card face, applied **before** the `scrollTransition` transform so the highlight follows the rotated geometry.
- `cardHeight: 170` is arithmetic off the source's 260pt drawer — re-derive for this column. Every horizontal number is a fraction of `cardWidth`, so the look is width-adaptive. At `cardWidth 150` the deck is five cards at 560pt.
- `ScrollStepAccumulator` has **zero callers on visionOS** (its producer is an AppKit `NSEvent` monitor). Do not port it and do not port its six tests; a green suite with nothing on screen is the trap `working-notes.md` names twice.

**Behaviour that must survive**, from the row inventory — each one is a regression if lost:

| Must keep | Detail |
|---|---|
| Delete + its confirmation | `role: .destructive`, dialog titled "Delete this saved game?", message `"<name> — <displayText>"`, buttons "Delete"/"Cancel". **No `.disabled`** — works with the engine stopped |
| Rescan | **Never disabled** |
| Load gating | `!running \|\| !isLoadable \|\| !isAddressable` — **not** gated on `saveBlock` |
| Save gating | `!running \|\| !canSave \|\| !isValidSavegameName`. Silently overwrites, no confirmation |
| Quick slots | 12 buttons `s0…s11`, save-only, and each **writes `saveName`** as a side effect |
| Name field | Live-filtered through `ConsoleArgument.sanitizedSavegameName`, 24-char cap |
| `saveBlock` caption | All six cases, exact text, `exclamationmark.circle` |
| "Saving…" | Section-level `ProgressView` + text, gated on `session.isSaving` |
| Two empty states | "No saved games yet." / "Waiting for the engine." |
| Both orange badges | Verbatim text in the Interfaces block above |
| `session.load` only | Never a raw `load` send — it calls `difficultyWatcher.markLoad()` first |

- [ ] **Step 1: Write the failing tests**

`CoverFlowMetrics` arithmetic, which is what the port can silently get wrong: `pitch == cardWidth * (1 - overlapFraction)`; `contentMargin(forWidth: 560) == (560 - cardWidth)/2`; `contentMargin(forWidth: 100) == 0` (never negative); `visibleCardCount(forWidth: 560) == 5` and `== 3` at 300.
`CoverBadge.caption` returns exactly the two strings in the table.
`badges(for:)` on a slot returns both when a save is *both* a version mismatch and unaddressable, since they are independent.
`emptyMessage(gameDirectory: nil) == "Waiting for the engine."` and `emptyMessage(gameDirectory: someURL) == "No saved games yet."` (Review Focus 5).

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/check-swift-session.sh` — add `App/Sources/SaveCoverFlow.swift` to its compile list. Expected: no `CoverFlowMetrics` in scope. Keep the view itself out of the harness; only the pure helpers are tested there.

- [ ] **Step 3: Implement `SaveCoverFlow.swift` and swap it into `gameContent`**

Put the pure helpers (`CoverFlowMetrics`, `CoverBadge`, `badges(for:)`, `emptyMessage(gameDirectory:)`) at the top of the file with no SwiftUI dependency, so the harness compiles them. `gameContent` keeps its `.onAppear { session.refreshSlots() }`; the poll lifecycle lives at window level and must not move back.

- [ ] **Step 4: Run to verify they pass, then build**

Run: `./tools/check-swift-session.sh` → PASS. `make device` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/SaveCoverFlow.swift App/Sources/ContentView.swift tools/swifttest/session_test.swift tools/check-swift-session.sh
git commit -m "feat(saves): a Cover Flow carousel in place of the slot rows"
```

---

### Task 2: Show a cover when one exists

**Files:**
- Modify: `App/Sources/SaveGames.swift` (`SaveGameSlot`, `list(in:)`)
- Modify: `App/Sources/SaveCoverFlow.swift` (the card face)
- Test: `tools/swifttest/session_test.swift`

**Interfaces:**
- Produces: `SaveGameSlot.coverURL: URL?` — the sibling `<name>.jpg`, non-nil **only when the file exists and is non-empty**. `SaveGameHeader.coverURL(forSave:)` as the pure path derivation.

- [ ] **Step 1: Write the failing tests**

`coverURL(forSave: …/s3.sav)` ends in `s3.jpg` and sits in the same directory.
A name with a dot in it (`my.save.sav`) derives `my.save.jpg` — `deletingPathExtension` once, not greedily.
Over a temporary directory: a `.sav` with a sibling non-empty `.jpg` lists with `coverURL != nil`; with **no** `.jpg`, `coverURL == nil`; with a **zero-byte** `.jpg`, `coverURL == nil` (Review Focus 1 — a mid-write cover must read as absent, not as a broken image).
A `.jpg` with **no** `.sav` produces no slot at all (Review Focus 2).

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/check-swift-session.sh`. Expected: no `coverURL` member.

- [ ] **Step 3: Implement**

`coverURL` is resolved during `list(in:)` using the directory listing already in hand, so it costs no extra `stat` per slot. The card face shows the image when `coverURL != nil` and the plain dark card otherwise; decode failure falls back to the plain card rather than an empty frame.

- [ ] **Step 4: Verify**

`./tools/check-swift-session.sh` → PASS. `make device` → BUILD SUCCEEDED. Then, by hand: drop any JPEG into the game directory named after an existing save, open the Game tab, and the card shows it. That is the whole of Task 2's device check and it needs no capture.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/SaveGames.swift App/Sources/SaveCoverFlow.swift tools/swifttest/session_test.swift
git commit -m "feat(saves): show a cover beside the save when one is there"
```

---

### Task 3: A world-only path through the encode

**Files:**
- Modify: `Sources/QuakeCore/include/QuakeCore.h` — one new `QC_ENTFLAG_*` bit near `:165-173`; two new `qc_frame_t` fields
- Modify: `Sources/QuakeRenderer/bridge/qr_bridge.c` — set the flag at `:4174`; publish the laser's vertex range beside `QR_EmitLaser` (`:7841`)
- Modify: `Sources/QuakeRenderer/RendererCore.swift` — `worldOnly: Bool = false` on `encode` (`:383-391`)
- Test: `tools/unittest/` (new C test)

**Interfaces:**
- Produces: `QC_ENTFLAG_HANDWEAPON`; `qc_frame_t.laser_first_vert` / `.laser_vert_count`; `RendererCore.encode(..., worldOnly: Bool = false)`.

Five things still draw inside `core.encode` and each must be skipped when `worldOnly`. Everything Swift-side (`drawVirtualHand`, `drawHandDebug`, `drawOverlay`, `drawWristGrid`, `drawHudTiles`, `drawWristComm`, `drawScreen2D`) is already absent from this path — those are called only from `ImmersiveRenderer`.

1. **The hand weapon.** `qr_bridge.c:7892-7894` emits `cl.viewent` through the ordinary alias path with `qr_handweapon = 1`, and `:4167` *suppresses* `QC_ENTFLAG_VIEWMODEL` for it — so the existing `drawsViewmodel: false` does **not** skip it, and `clip`/`dbg` are not a reliable trace. Hence the new flag bit.
2. **The aiming laser.** `QR_EmitLaser` (`:7841`) writes particle verts with no published range; add the pair. **Do not** fold it into the reticle range — that one is drawn `depthAlways`, and widening it would change the live laser.
3. **Reticle and arc gauges.** Already skippable: `frame.reticle_first_vert` / `.reticle_vert_count`.
4. **The world text run.** `frame.num_text_verts` — wheel labels and centerprints. Skip the whole run.
5. **Wheel guide ring and comfort vignette.** `frame.wheel_frac`, `frame.vignette`. Both zero at save by construction; skip anyway rather than rely on that.

Also skip the **phase-ground grid** (`ground_first_vert`/`count`) — it is room furniture, not world. Keep world, sky and liquid batches, brush/alias/sprite entities and particles proper.

- [ ] **Step 1: Write the failing test**

A C unit test asserting the flag's independence and the range's defaults: `QC_ENTFLAG_HANDWEAPON` does not collide with any other `QC_ENTFLAG_*` bit (bitwise-and each against it); a zeroed `qc_frame_t` has `laser_vert_count == 0` so a frame that never emitted a laser skips nothing.

- [ ] **Step 2: Run to verify it fails**

Run: `./tools/check-unit.sh`. Expected: `QC_ENTFLAG_HANDWEAPON` undeclared.

- [ ] **Step 3: Implement**

Header, bridge, then the `worldOnly` branches in `RendererCore.encode`. Default `false`, so every existing caller is unchanged by construction.

- [ ] **Step 4: Verify**

`make check` → 62+ TUs, no undefined symbols. `./tools/check-unit.sh` → green. `make device` → BUILD SUCCEEDED. The live view must be untouched: this task adds a parameter nobody passes yet.

- [ ] **Step 5: Commit**

```bash
git add Sources/QuakeCore/include/QuakeCore.h Sources/QuakeRenderer/bridge/qr_bridge.c Sources/QuakeRenderer/RendererCore.swift tools/unittest/
git commit -m "feat(renderer): a world-only encode path, for a cover with no gun in it"
```

---

### Task 4: Remember the pose from before the panel

**Files:**
- Create: `App/Sources/HeadPoseRing.swift`
- Modify: `Sources/QuakeRenderer/ImmersiveRenderer.swift` (publish beside `:887`)
- Modify: `App/Sources/ContentView.swift` (freeze in the `respawn` closure, `:331-350`)
- Test: `tools/swifttest/session_test.swift`

**Interfaces:**
- Produces: `HeadPoseRing` with `note(_ m: simd_float4x4, at: TimeInterval)`, `freeze(at:)`, and `pose(secondsBefore: TimeInterval) -> simd_float4x4?`.

`quakeFromOrigin * originFromDevice` already exists at `ImmersiveRenderer.swift:887` as a `simd_float4x4` handed to `TrackRecorder.noteFrame(quakeFromHead:)` — eye→world in tracking axes, exactly what `ExportRenderer.viewProjection(camera: .head(…))` consumes. Publish it to the ring at the same site.

**A ring, not a single slot, on purpose.** Both summon gestures route through one choke point (the `respawn` closure; prayer via `HandInput.swift:355-386`, wrist MENU via `WristCommStore.swift:123-132`), but the prayer sign has a **0.6 s dwell** (`HandInput.swift:142`) during which the player is looking at their own palms. Freezing the instant of summon captures that. One second of poses at 90 Hz is 90 × 64 bytes ≈ 5.7 KB, and lets the cover come from ~0.8 s *before* the gesture started.

- [ ] **Step 1: Write the failing tests**

`pose(secondsBefore:)` on an empty ring is `nil` (Review Focus 3).
Noting three poses at t=0, 0.5, 1.0 then `freeze(at: 1.0)`: `pose(secondsBefore: 0.5)` returns the t=0.5 matrix; `secondsBefore: 0` returns t=1.0; `secondsBefore: 99` returns the oldest held rather than nil.
The ring overwrites rather than growing: note 200 poses into a 90-slot ring and the count stays 90 with the newest retained.
`freeze` is idempotent and a second `freeze` without new notes does not move the answer.

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/check-swift-session.sh` (add the file). Expected: no `HeadPoseRing`.

- [ ] **Step 3: Implement**

A fixed array with a write index and an `NSLock`; the writer is the render thread and the reader is the summon, so it must be lock-guarded and allocation-free on the write path.

- [ ] **Step 4: Verify**

`./tools/check-swift-session.sh` → PASS. `make device` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/HeadPoseRing.swift Sources/QuakeRenderer/ImmersiveRenderer.swift App/Sources/ContentView.swift tools/swifttest/session_test.swift tools/check-swift-session.sh
git commit -m "feat(saves): keep a second of head poses, so a cover predates the gesture"
```

---

### Task 5: Render and write the cover at save time

**Files:**
- Create: `App/Sources/CoverRenderer.swift`
- Modify: `App/Sources/SessionState.swift` (`save(_:)`, `:242-251`)
- Test: by device check; the pass itself is not host-testable

**Interfaces:**
- Consumes: `worldOnly` (Task 3), `HeadPoseRing` (Task 4), `SessionState.gameDirectory`.
- Produces: `CoverRenderer.shared.write(coverFor name: String, into directory: URL, pose: simd_float4x4)` — async, returns nothing, never throws into the save path.

Copy `ExportRenderer`'s shape; it is already mono and already un-foveated (plain `texture2D`, no `rasterizationRateMap`, `amplified: false`). Build its textures and pipelines **once and cache** — not per save. Use `PhaseParams(radius: 0, skyFade: 1)` as `ExportRenderer.accumulate` does, so a save taken mid-melt still gets a solid world.

Call sequence, modelled on `DemoExporter.swift:169-250`:

```
core.withConsumer(.immersive) {
    guard let f = QC_RendererAcquireFrame() else { return }
    defer { QC_RendererReleaseFrame() }
    accumulate(frame: f.pointee, camera: .head(pose), worldOnly: true, into: cb)
}
resolve(into: shared)      // outside the lock
cb.commit(); cb.waitUntilCompleted()
```

**Build the cover pipelines with `colorFormat: .rgba8Unorm`, not `.bgra8Unorm`.** A blit needs matching formats, so choosing the render target's format is how the channel order is settled — not a CPU swizzle afterwards.

**Write the JPEG in Swift, not through `Image_WriteJPG`.** The C function exists and is callerless, but using it would mean a new `platform/` shim, a `QuakeCore.h` declaration, an engine-thread hop and care over `bpp`/stride/flip — all to write a file from bytes Swift is already holding. `UIImage` is already used in this target to read map previews (`ContentView.swift:1154`), so `UIImage(cgImage:).jpegData(compressionQuality: 0.7)` then `data.write(to:)` is fewer moving parts and no new C surface. Write to a temporary name and move into place, so a half-written cover is never visible (Review Focus 1).

**Culling needs no handling.** The immersive consumer sets `QC_RendererSetCullingFov(360, 360)` once in `run()` (`ImmersiveRenderer.swift:207`) → `qr_cull_omni`, PVS-only with no frustum, so the packet holds the whole visible level regardless of where the head is pointing now.

`save(_:)` keeps its existing guards and its `pendingSave` bookkeeping untouched; the cover is kicked off after the command is sent and **must not** be able to fail the save (Review Focus 3: no pose, no immersive space, no directory → no cover, and the save still lands).

- [ ] **Step 1: Implement**

- [ ] **Step 2: Verify**

`make check`, `./tools/check-unit.sh`, all five Swift checks, `make device` → all green. Then the device checks below.

- [ ] **Step 3: Commit**

```bash
git add App/Sources/CoverRenderer.swift App/Sources/SessionState.swift
git commit -m "feat(saves): render the cover from the pose you had before the panel"
```

---

### Task 6: Heal a coverless save on first load

**Files:**
- Modify: `App/Sources/SessionState.swift` (`load(_:)`)
- Test: `tools/swifttest/session_test.swift`

**Interfaces:**
- Produces: `SessionState.pendingCoverBackfill: String?` — the save name owed a cover.

- [ ] **Step 1: Write the failing test**

The pure decision: `shouldBackfill(name:hasCover:)` is true only when the save has no cover; false when it has one. A load of a save that already has a cover must not re-render one.

- [ ] **Step 2: Run to verify it fails, then implement**

On load of a slot whose `coverURL == nil`, record the name. `Host_Loadgame_f` leaves `sv.paused` engaged until the manual Resume, so the pose to use is the first one the ring sees **after** the level is actually running — not at the moment the load command is sent, when the world is still the old one. `load` keeps calling `difficultyWatcher.markLoad()` first.

- [ ] **Step 3: Verify and commit**

`./tools/check-swift-session.sh` → PASS. `make device` → BUILD SUCCEEDED.

```bash
git add App/Sources/SessionState.swift tools/swifttest/session_test.swift
git commit -m "feat(saves): an old save takes a cover the first time you load it"
```

---

## Device checks, for A. — none of these can pass on a host test

After Task 1: the carousel shows every existing save as a card with its level, difficulty pip, kills and date; Delete asks first and works with the engine stopped; Load is refused with the right orange text on a foreign-version save.

After Task 2: a JPEG dropped in by hand appears as that save's cover.

After Task 5, the criterion the whole feature rests on:
- Save mid-level. The cover is the room you were standing in, and **there is no gun, no hand, no reticle and no gauge in the picture.**
- Summon the panel with the **prayer sign**, then save. The cover is the room, **not your palms** — this is what the pose ring buys.
- Save while phased out. The cover is sparse where your room is. Expected and accepted.
- Save with the immersive space never opened. The save still lands; there is simply no cover.

After Task 6: load a save that has no cover; once the level is up, its card has one.

Optional device experiment, Task 1: drop the `perspective:` argument from `rotation3DEffect` and the tilt becomes a true depth rotation in the window's volume rather than a flat projection. It may read far better in a headset, or be clipped by the window's depth budget. Worth one look.
