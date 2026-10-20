# Feet on the real floor — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Quake floor sits on the real floor in every posture, measured by plane detection, with today's eye-locked mapping as the fallback.

**Architecture:** A new `FloorSource` owns a `PlaneDetectionProvider` in its own supervised ARKit session and publishes one lock-guarded floor height per provider life. Pure math in `FloorMath.swift` (simd only, host-testable) turns packet fields, the floor height and the trim into the immersive anchor and the effective trim the engine is told. `ImmersiveRenderer` wires the two in and stops zeroing vertical at recenter once a floor is known. The packet gains `viewheight`; the bridge zeroes `cl_bob` while the immersive space is up.

**Tech Stack:** Swift (ARKit `PlaneDetectionProvider`, simd), C (bridge and platform), `tools/check-swift-*.sh` host tests, `make check`, `make device`.

**Spec:** `docs/designs/2026-10-17-phase-floor.md`

## Global Constraints

- No edits under `Sources/QuakeCore/engine/`. `cl_bob` is driven from the bridge through `extern cvar_t cl_bob;`, on the engine thread only.
- `make check` after every C change; `make device` is the only real target build. Say which ran.
- Cvars are not thread safe: any `Cvar_Set*` runs on the engine thread. The any-thread set stays as listed in `docs/working-notes.md`; this plan adds no any-thread entry point.
- Thread rule for ARKit: `anchor(at:)`-style queries are render thread only; a supervisor task never queries, it only publishes under a lock. `FloorSource` follows `DeviceAnchorSource` exactly.
- Fallback when no floor is measured or permission is refused: today's mapping, with 0.40 m baked as a constant plus the trim.
- No attribution trailers or tool mentions anywhere.
- British spelling in code comments is fine; public prose is American.

## Review Focus

1. The floor plane arrives while the player is mid-air (a jump, a lift). `anchorZ` must use the smoothed eye minus viewheight, never the entity origin, so the switch-over does not snap. Pinned in Task 2's test `anchorZ_usesEyeNotOrigin`.
2. A table at 0.7 m comes back classified `floor` by a mis-read. The selection rule must reject a plane above the head minus 0.5 m and prefer the lowest qualifying plane. Pinned in Task 2's test `select_rejectsPlaneAboveHead`.
3. Provider rebuilt after Developer Capture, new origin lower by 10 cm. The old height must not survive the rebuild's lower-only rule. Pinned in Task 3's reset on rebuild and Task 2's `select_freshLifeTakesFirstPlane`.
4. Permission refused: head tracking must still come up. Pinned by the separate session in Task 3 and the device check in Task 6.
5. A saved profile with the old 0.40 slider value must not become a 0.40 floor trim. Pinned in Task 5: the trim has its own key and `heightOffset` is no longer read into anything.

---

### Task 1: Publish `viewheight`, zero bob in the immersive space

**Files:**
- Modify: `Sources/QuakeCore/include/QuakeCore.h` (after `world_scale`, around :309)
- Modify: `Sources/QuakeRenderer/bridge/qr_bridge.c` (packet write at :7870-7872, no-world zeroing at :7743, the `qr_cull_omni` read at :7822-7832, externs near :45)
- Test: `make check` plus `tools/unittest/viewheight_test.c`

**Interfaces:**
- Produces: `float viewheight;` on `qc_frame_t`, Quake units, `cl.viewheight` as the client holds it (22 standing, -8 dead), 0 with no world. Read by Task 2 and Task 4.
- Produces: `qr_bridge.c` sets `cl_bob` to 0 while `qr_cull_omni` is true and restores the value it found when it turns false.

- [ ] **Step 1: Write the failing test** `tools/unittest/viewheight_test.c`, in the style of `hud_tile_test.c`: declare `extern cvar_t cl_bob;` and a new hostcheck hook `void QR_TestBobGate (int omni);` that runs the same code the `qr_cull_omni` read site runs. Assert: with `cl_bob.value = 0.02f`, `QR_TestBobGate (1)` leaves `cl_bob.value == 0`; `QR_TestBobGate (0)` restores `0.02f`; two consecutive `QR_TestBobGate (1)` calls then a `(0)` still restore `0.02f` (the saved value is captured once on entry, not overwritten by the zero). Also `_Static_assert (offsetof (qc_frame_t, viewheight) > offsetof (qc_frame_t, world_scale), "viewheight follows world_scale")` as a compile-time check that the field exists.

- [ ] **Step 2: Run** `tools/check-unit.sh` → expect `LINK FAIL: viewheight_test.c` on the missing hook and field.

- [ ] **Step 3: Implement.** Add `float viewheight; /* cl.viewheight, Quake units: the eye above the hull bottom. vieworg already includes it; the consumer subtracts it to find the floor. 0 with no world. */` to `qc_frame_t`. Publish it beside `vieworg` and zero it in the no-world path. Factor the bob gate into `static void QR_BobGate (int omni)` with `static float saved_bob; static int bob_zeroed;`, called from the omni read site, and expose `QR_TestBobGate` under `QAVP_HOSTCHECK`. Register the cvar in the test? `cl_bob` is registered by `V_Init`, not run in the hostcheck binary; the hook must therefore write `cl_bob.value` directly when `!(cl_bob.flags & CVAR_REGISTERED)` and use `Cvar_SetValueQuick` otherwise, so the gate is testable and correct on device.

- [ ] **Step 4: Run** `make check` → links; `tools/check-unit.sh` → the new test passes and the harness exits 0.

- [ ] **Step 5: Commit** `feat(immersive): publish viewheight, hold cl_bob at zero while immersive`.

### Task 2: Floor math, pure and host-tested

**Files:**
- Create: `App/Sources/FloorMath.swift` (imports `simd` only)
- Create: `tools/swifttest/floor_test.swift`, `tools/check-swift-floor.sh` (copy of `check-swift-math.sh` with the file list `floor_test.swift FloorMath.swift`, output name `floortest`)

**Interfaces:**
- Produces, all `enum FloorMath` static functions, `Float` in metres unless named `Z` (Quake units):
  - `struct FloorCandidate { var y: Float; var area: Float; var horizontalDistance: Float }`
  - `static func select(_ candidates: [FloorCandidate], current: Float?, headY: Float) -> Float?` — the rule: drop candidates with `area < 0.5`, `horizontalDistance > 2.5`, or `y > headY - 0.5`; of the rest take the lowest `y`; if `current` is non-nil and no candidate is lower than `current - 0.02` or has area larger than the current's recorded area, return `current`. Candidates carry area so "larger area" is decidable; the caller keeps the current plane's area alongside `current`.
  - `static func anchorZ(vieworgZ: Float, viewheight: Float, floorYRoom: Float, worldScale: Float, trimMetres: Float) -> Float` = `vieworgZ - viewheight - floorYRoom / worldScale + trimMetres / worldScale`.
  - `static func fallbackAnchorZ(vieworgZ: Float, worldScale: Float, trimMetres: Float) -> Float` = `vieworgZ + (0.4 + trimMetres) / worldScale`.
  - `static func effectiveTrim(anchorZ: Float, cameraYRoom: Float, vieworgZ: Float, worldScale: Float) -> Float` = `anchorZ + cameraYRoom / worldScale - vieworgZ` (Quake units, what `QC_InputSetHeightTrim` is fed).
  - `static func correction(zeroing pose: simd_float4x4, keepHeight: Bool) -> simd_float4x4` — the existing `ImmersiveRenderer.correction(zeroing:)` body, moved here, with `keepHeight` leaving `columns.3.y` at 0 in `neutral` so the inverse does not subtract it.
  - `static func eased(from a: Float, to b: Float, progress t: Float) -> Float` smoothstep between the two.

- [ ] **Step 1: Write the failing tests** in `floor_test.swift` with the repo's `check(_:_:)` helper:
  - `select_rejectsPlaneAboveHead`: candidates `[(y: 0.7, area: 2, dist: 1), (y: 0.0, area: 4, dist: 1)]`, `headY: 1.1` → `0.0`.
  - `select_prefersLowest`: `[(0.1, 3, 1), (0.0, 1, 1)]`, head 1.6 → `0.0`.
  - `select_rejectsSmallAndFar`: `[(0.0, 0.3, 1), (0.0, 3, 3.0)]`, head 1.6 → `nil`.
  - `select_keepsCurrentUnlessLowerOrLarger`: current `0.0` with its area 2 (caller passes the current plane as a candidate too); new `(0.01, 1, 1)` → stays `0.0`; new `(-0.05, 1, 1)` → `-0.05`.
  - `select_freshLifeTakesFirstPlane`: current `nil`, one candidate `(0.12, 1, 1)` → `0.12`.
  - `anchorZ_usesEyeNotOrigin`: `vieworgZ 146, viewheight 22, floorYRoom 0, scale 0.0254, trim 0` → `124`; with `floorYRoom -0.0254` → `125`.
  - `fallbackAnchorZ_matchesToday`: `vieworgZ 100, scale 0.0254, trim 0` → `100 + 0.4/0.0254` within 1e-3.
  - `effectiveTrim_isCameraAboveVieworg`: `anchorZ 124, cameraYRoom 1.65, vieworgZ 146, scale 0.0254` → `124 + 64.96 - 146` within 1e-2.
  - `correction_keepHeightLeavesY`: a pose translated `(1, 1.6, 2)` yawed 30°: with `keepHeight: false` the corrected pose's translation is `(0,0,0)`; with `keepHeight: true` it is `(0, 1.6, 0)` within 1e-4.
  - `eased_endpoints`: `eased(0, 10, 0) == 0`, `eased(0, 10, 1) == 10`, `eased(0, 10, 0.5) == 5`.

- [ ] **Step 2: Run** `tools/check-swift-floor.sh` → compile error, `FloorMath` undefined.

- [ ] **Step 3: Implement `FloorMath`** as specified. Document in the file header that it is compiled alone by `tools/check-swift-floor.sh` and must import only `simd`.

- [ ] **Step 4: Run** `tools/check-swift-floor.sh` → `PASSED`.

- [ ] **Step 5: Commit** `feat(immersive): floor math, host-tested`.

### Task 3: `FloorSource`

**Files:**
- Create: `Sources/QuakeRenderer/FloorSource.swift`
- Modify: `project.yml` (add `NSWorldSensingUsageDescription: Plane detection finds your floor so the game floor sits on it.` beside the two existing keys; regenerate with `xcodegen`)

**Interfaces:**
- Consumes: `FloorMath.select`, `FloorMath.FloorCandidate`.
- Produces: `final class FloorSource: @unchecked Sendable` with `init()`, `start()`, `stop()`, `func floorYRaw() -> Float?` (lock-guarded read, any thread), and `var onRebuilt: (@Sendable () -> Void)?`. Height is in the raw tracking frame of the provider that produced it. The selection state resets to nil whenever a provider is rebuilt, and the last value is kept readable until the new provider's first qualifying plane arrives, at which point `floorYRaw()` returns the new one.

- [ ] **Step 1: Write** the class by mirroring `DeviceAnchorSource` (`ImmersiveRenderer.swift:2571-2890`): the same `lock`, `live`, `supervisor`, registry, `retryDelay`, `maxBackoff`, `stableGrace`, `pollInterval`, `pausedGrace`, `supervise()`, `watch(_:)`, `adopt`/`retire`. Differences: the provider is `PlaneDetectionProvider(alignments: [.horizontal])`; `isSupported` guard uses it; the session is its own; beside the `errors` task, a `drain` task `for await update in provider.anchorUpdates` that on `.added`/`.updated` with `anchor.alignment == .horizontal && anchor.surfaceClassification == .floor` computes the candidate `y` as `(anchor.originFromAnchorTransform * anchor.geometry.extent.anchorFromExtentTransform).columns.3.y`, `area` as `extent.width * extent.height`, `horizontalDistance` from the latest head position the renderer passes in through `func noteHead(xz: SIMD2<Float>)` (lock-guarded), and on `.removed` drops that anchor id; it keeps a dictionary `[UUID: FloorCandidate]` of live floor anchors and recomputes `selected = FloorMath.select(Array(dict.values), current: selected, headY: headY)` after each change. On rebuild: `dict = [:]`, `selected = nil` for the new life but `published` (what `floorYRaw()` returns) holds the old value until `selected` becomes non-nil again. `onRebuilt` fires like the device source's.
  There is no test harness for ARKit; the class is verified by the device log lines it prints: `[floor] plane detection running`, `[floor] floor at <y> m, area <a> m²`, `[floor] permission denied -- eye-locked mapping stays`, `[floor] rebuilt -- waiting for a fresh floor`.

- [ ] **Step 2: Build** `make device` → succeeds (the class is not yet used).

- [ ] **Step 3: Commit** `feat(immersive): a floor source over plane detection, in its own session`.

### Task 4: Wire the anchor, the recenter and the trim

**Files:**
- Modify: `Sources/QuakeRenderer/ImmersiveRenderer.swift`: properties near :41-61; the `.running` tick at :193-199; the correction call sites at :530-546; the anchor block at :655-670; the stop tail at :205-230; `correction(zeroing:)` at :2478-2495 (delete, now in `FloorMath`).
- Modify: `App/Sources/VRSettings.swift`: add `floorTrim: Float` (metres, default 0, lock-guarded, persisted through the existing UserDefaults helpers at :553-563 under key `floorTrim.v1`); leave `heightOffset` in place for Task 5 to remove.

**Interfaces:**
- Consumes: Task 1's `packet.viewheight`; Task 2's `FloorMath`; Task 3's `FloorSource`.
- Produces: the new anchor; `QC_InputSetHeightTrim` fed `FloorMath.effectiveTrim(...)`; the correction keeps height whenever `floor.floorYRaw() != nil`.

- [ ] **Step 1: Add** `private let floor = FloorSource()` with `floor.onRebuilt` left nil (the device source already requests the recenter), `private var startedFloor = false`, `private var floorSwitch: (from: Float, to: Float, startedAt: Double)?`, `private var anchorMode: enum { eye, floor }` for logging the switch.

- [ ] **Step 2: Start and stop.** In the `.running` tick beside `anchors.start()`: `floor.start()`. In the stop tail beside `anchors.stop()`: `floor.stop()`.

- [ ] **Step 3: Correction.** Replace both `Self.correction(zeroing: rawOriginFromDevice)` calls with `FloorMath.correction(zeroing: rawOriginFromDevice, keepHeight: floor.floorYRaw() != nil)`. With height kept, `originFromDevice.columns.3.y` is the raw tracking height, and the floor's raw height is in the same frame, so `floorYRoom == floorYRaw`.

- [ ] **Step 4: Anchor.** Replace the `heightTrim`/`anchor` lines with: read `let trim = VRSettings.shared.floorTrim`; if `let fy = floor.floorYRaw()` then `targetZ = FloorMath.anchorZ(vieworgZ: packet.vieworg.2, viewheight: packet.viewheight, floorYRoom: fy, worldScale: s, trimMetres: trim)` else `targetZ = FloorMath.fallbackAnchorZ(vieworgZ: packet.vieworg.2, worldScale: s, trimMetres: trim)`. If the mode changed since the last frame, set `floorSwitch = (from: lastAnchorZ - packet.vieworg.2, to: targetZ - packet.vieworg.2, startedAt: now)` and log `[floor] anchor switching to <mode>`; while a switch is younger than 1.0 s, `anchorZ = packet.vieworg.2 + FloorMath.eased(from:to:progress:)` of the stored offsets, else `anchorZ = targetZ`. Offsets are stored relative to `vieworg.2` so the ease survives the player walking. Then `anchor = SIMD3(x, y, anchorZ)` as today. Feed the engine `QC_InputSetHeightTrim(FloorMath.effectiveTrim(anchorZ: anchorZ, cameraYRoom: originFromDevice.columns.3.y, vieworgZ: packet.vieworg.2, worldScale: s))`, and pass the same value to `TrackRecorder.shared.noteFrame(... heightTrim:)` so sidecars replay unchanged. Call `floor.noteHead(xz:)` with the head's raw x/z once per frame.

- [ ] **Step 5: Build** `make device` → succeeds. Check the Swift pieces that still referenced `heightOffset` compile (they do; the property still exists).

- [ ] **Step 6: Commit** `feat(immersive): anchor the feet to the measured floor, keep height across recenter`.

### Task 5: The slider becomes a floor trim

**Files:**
- Modify: `App/Sources/ContentView.swift:578-596` (the Eye height block)
- Modify: `App/Sources/VRSettings.swift` (remove `heightOffset` and its backing var and doc comment)
- Modify: `App/Sources/InputProfile.swift` (:46 keep the stored field with a comment "retired 2026-10-17: the floor is measured now; decoded for compatibility, never read"; delete the `apply()` line at :314 that copies it; keep :167 so old profiles decode)
- Modify: `docs/decisions.md` (new dated entry: eye-locked to floor-locked, why the first attempt failed and what differs now)
- Modify: `README.md` M6 row: "world-scale tuning" stays; add nothing else. `CHANGELOG.md` Added: one bullet.

- [ ] **Step 1: Rewrite the slider.** Title `Floor trim  <sign><cm> cm`, caption `Nudge the floor if it sits above or below your real floor.`, range `-0.3...0.3`, binding to `VRSettings.shared.floorTrim` and a local `@State floorTrim`, Reset to `0`. The Recenter button stays.

- [ ] **Step 2: Remove `heightOffset`** from `VRSettings`; fix the two other readers (`ImmersiveRenderer` no longer reads it after Task 4; `InputProfile.apply()` line deleted). Grep `heightOffset` across `App/ Sources/ tools/ Tests/`: the only survivors are the two `InputProfile` lines and their comments.

- [ ] **Step 3: Docs.** `docs/decisions.md` entry; changelog bullet: "The game floor sits on your real floor, measured by plane detection, in every posture; the eye-height slider is now a small floor trim."

- [ ] **Step 4: Build** `make device` → succeeds; `tools/check-swift-session.sh` and `tools/check-swift-input.sh` still pass (they compile `InputProfile`'s neighbours).

- [ ] **Step 5: Commit** `feat(app): the eye-height slider becomes a floor trim`.

### Task 6: Device verification

**Files:** none. The results go in the merge request description.

- [ ] **Step 1: First run.** The world-sensing prompt appears once. Allow it. Log shows `[floor] plane detection running` then `[floor] floor at … m`.
- [ ] **Step 2: Standing.** Phase out on a flat floor: the real floor appears exactly where the virtual floor dissolves at the rim, no step. Note the logged floor height and the anchor switch line.
- [ ] **Step 3: Seated.** Sit, `vr_recenter`. The floor does not move. Stand, recenter again. Still does not move.
- [ ] **Step 4: Enemy.** A grunt in the phased room stands with its feet on the carpet.
- [ ] **Step 5: Walking.** Stick-walk while phased: no bob of the floor.
- [ ] **Step 6: Permission refused.** Reset the permission in Settings, relaunch, deny. Head tracking runs; the log says `[floor] permission denied -- eye-locked mapping stays`; the trim slider still raises and lowers the world.
- [ ] **Step 7: Capture.** Developer Capture of the standing phase-out. After the capture ends the log shows `[floor] rebuilt -- waiting for a fresh floor` followed by a new floor line, and the floor is still right.
