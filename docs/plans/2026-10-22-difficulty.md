# Difficulty Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make difficulty a persistent value with a control in the window, settable equally by the window or a hub door, and readable off any save file.

**Architecture:** The engine keeps owning `skill`; nothing in `Sources/QuakeCore/engine/` changes. Swift stores the value, pushes it once at launch from the engine-thread bootstrap, and adopts engine-side changes by polling `QC_CvarValue("skill")` — except while a load is in flight, because `Host_Loadgame_f` writes that cvar too. The save-file difficulty is a separate pure parse used only for display.

**Tech Stack:** Swift 6 / SwiftUI, `QC_*` C bridge, `swiftc` host tests via `tools/check-swift-session.sh`.

**Spec:** `docs/designs/2026-10-22-save-browser.md` (difficulty half only; the Cover Flow browser and its render pass are explicitly out of scope here)

## Global Constraints

- **Never edit `Sources/QuakeCore/engine/`.** `skill` stays `cvar_t skill = {"skill","1",CVAR_NONE}` at `engine/host.c:74`. Persistence is platform-side. A seventh vendored hunk for this is refused by the spec's anti-goals.
- **Thread rule.** `QC_CvarValue` is any-thread (`QuakeCore.h:531-535`). `QC_ExecuteCommand` goes through `QuakeEngineHost.execute(_:)`, the only sanctioned way in from the UI. Nothing here touches the render thread.
- **Input is hands and Sense controllers only.** Every control needs both; no gamepad-only affordance.
- **Skill range is 0...3** — clamped by the engine at `engine/sv_main.c:1489-1492`. Labels, in order: Easy, Normal, Hard, Nightmare. Nightmare is visible, not hidden.
- **`autoexec.cfg` wins.** It is a sanctioned escape hatch (`in_null.c:1341`); the launch push must not override a `skill` set there.
- **Save file layout** (`engine/host_cmd.c:1140-1148`, `NUM_SPAWN_PARMS` = 16 at `engine/server.h:86`): line 1 version, line 2 comment, lines 3–18 spawn parms, **line 19 `current_skill`**, line 20 map name, line 21 `sv.time`. Zero-indexed, skill is element 18.
- `make check` and `tools/check-unit.sh` must stay green; `make device` is the only proof of the real target and must be run before each commit that touches Swift.

## Review Focus

Input classes the spec implies that no task's own happy-path test exercises. Each has its test added to the owning task.

1. **A save file with fewer than 19 lines** (truncated, or an unrelated file renamed `.sav`). Must yield no difficulty rather than crash or report Easy. → Task 1.
2. **A skill line that is not 0–3** — a mod, a hand-edited file, or a float like `2.000000`. Must clamp or refuse, never index a label array out of bounds. → Task 1.
3. **A stored skill outside 0–3** reaching `VRSettings` from a corrupt defaults domain. Must clamp on read, not trust the store. → Task 2.
4. **The window pressed mid-level.** The engine reads `skill` once per level spawn, so the press cannot take effect now; the UI must say so rather than imply it did. → Task 4.
5. **A load that changes difficulty** must not rewrite the stored preference, including a load the window did not initiate. → Task 3 (with its known gap stated).

---

### Task 1: Read a save's difficulty

**Files:**
- Modify: `App/Sources/SaveGames.swift` (`SaveGameSlot`, `SaveGameHeader.parse`, `readHeader`, `headerBytes` at `:75`)
- Test: `tools/swifttest/session_test.swift`

**Interfaces:**
- Produces: `enum Difficulty: Int, CaseIterable { case easy = 0, normal, hard, nightmare }` with `var label: String` ("Easy"/"Normal"/"Hard"/"Nightmare") and `static func from(skillLine: String) -> Difficulty?`. `SaveGameSlot.difficulty: Difficulty?`. `SaveGameHeader.parse` returns `(version: Int, comment: String, difficulty: Difficulty?)`.

- [ ] **Step 1: Write the failing tests** in `tools/swifttest/session_test.swift`

Cover, with the layout above (a helper that builds a header from version, comment, 16 parm lines and a skill line):
`parse` on a well-formed 21-line header returns `.hard` for a skill line of `"2"`; returns `.nightmare` for `"3"`; returns `.easy` for `"0"`.
`Difficulty.from(skillLine: "2.000000")` is `.hard` (a float-formatted line still parses).
`Difficulty.from(skillLine: "7")` and `("-1")` are `nil` — out of range is refused, never clamped into a wrong label.
`Difficulty.from(skillLine: "")` and `("x")` are `nil`.
`parse` on a header truncated after line 3 returns a non-nil version and comment with `difficulty == nil` — a short file still lists, it just has no pip.
`Difficulty.allCases.count == 4` and labels are exactly the four strings above.

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/check-swift-session.sh`
Expected: compile failure, no `Difficulty` in scope.

- [ ] **Step 3: Implement**

Add `Difficulty` to `SaveGames.swift`. `from(skillLine:)` trims whitespace, parses as `Double` (so `"2.000000"` works), rejects a non-integral or out-of-range value, then `Difficulty(rawValue:)`.
Change `parse`'s split from `maxSplits: 2` to no limit and index element 18, guarding `lines.count > 18`. Keep the existing leniency: a bad or missing skill line must not fail the whole parse.
Raise `headerBytes` from 256 to 512 — 19 lines of `%f` spawn parms plus a 39-char comment is ~190 bytes, which 256 covers with no margin for a longer comment.

- [ ] **Step 4: Run to verify they pass**

Run: `./tools/check-swift-session.sh`
Expected: all pass, including the pre-existing cases.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/SaveGames.swift tools/swifttest/session_test.swift
git commit -m "feat(saves): read a save's difficulty off line 19"
```

---

### Task 2: Store it, and push it at launch

**Files:**
- Modify: `App/Sources/VRSettings.swift` (follow the `floorTrim` property shape at `:384-387`)
- Modify: `App/Sources/QuakeEngineHost.swift` (bootstrap block, `:288-316`)
- Test: `tools/swifttest/session_test.swift`

**Interfaces:**
- Consumes: `Difficulty` from Task 1.
- Produces: `VRSettings.shared.skill: Int`, clamped 0...3 on both get and set, defaulting to 1 (Normal, matching the engine's own default).

- [ ] **Step 1: Write the failing test**

A pure test over the clamp alone, since `VRSettings` is not in the session harness: add `static func clampSkill(_ v: Int) -> Int` to `SaveGames.swift` beside `Difficulty` and test it — `clampSkill(-3) == 0`, `clampSkill(9) == 3`, `clampSkill(2) == 2`. `VRSettings.skill` uses it so the clamp has one definition and a host test.

- [ ] **Step 2: Run to verify it fails**

Run: `./tools/check-swift-session.sh`
Expected: no `clampSkill` in scope.

- [ ] **Step 3: Implement**

`clampSkill` in `SaveGames.swift`. `VRSettings.skill` in the established `store(...)`/lock shape, keyed `"vr.skill"`, routed through `clampSkill` on read as well as write (Review Focus 3).
In `QuakeEngineHost`'s bootstrap, after the `volume`/`bgmvolume` forces and **before** the `map range` block, push `skill \(VRSettings.shared.skill)`. It must sit in that engine-thread block because no main-actor `send` can get ahead of it on a dev build.

- [ ] **Step 4: Verify**

Run: `./tools/check-swift-session.sh` → pass. Then `make device` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/VRSettings.swift App/Sources/QuakeEngineHost.swift App/Sources/SaveGames.swift tools/swifttest/session_test.swift
git commit -m "feat(difficulty): persist the chosen skill and push it at launch"
```

---

### Task 3: Adopt a hub door's change, ignore a load's

**Files:**
- Create: `App/Sources/DifficultyWatch.swift`
- Modify: `App/Sources/SessionState.swift` (wherever `load` is issued — mark a load in flight)
- Test: `tools/swifttest/session_test.swift`

**Interfaces:**
- Consumes: `clampSkill`, `VRSettings.shared.skill`.
- Produces: `DifficultyWatch`, with `func sample(engineSkill: Int, loadInFlight: Bool) -> Int?` — the pure decision, returning the value to store or `nil` for "leave it alone" — and a `@MainActor` wrapper that polls `QC_CvarValue("skill")` on a 1 s timer and calls `markLoad()` from `SessionState`'s load path, holding the mask for 2 s.

- [ ] **Step 1: Write the failing tests**

`sample` is where the rule lives, so it is tested alone:
engine 2, stored 2, no load → `nil` (nothing to do).
engine 3, stored 1, no load → `3` (a hub door or a console `skill`: adopt).
engine 0, stored 3, **load in flight** → `nil` (Review Focus 5: loading an Easy save must not rewrite a persisted Nightmare).
engine 9, stored 1, no load → `nil` (never store an out-of-range engine value).
engine 1, stored 1, load in flight → `nil`.

- [ ] **Step 2: Run to verify they fail**

Run: `./tools/check-swift-session.sh`
Expected: no `DifficultyWatch` in scope. Add the new file to that script's compile list.

- [ ] **Step 3: Implement**

`sample` is pure and total: ignore anything outside 0...3, return `nil` while `loadInFlight`, otherwise return the engine value when it differs from stored.
The wrapper polls with a `Task` and `Task.sleep`, reads `QC_CvarValue("skill")` (any-thread, safe), and writes `VRSettings.shared.skill` on a non-nil result. `SessionState`'s load path calls `markLoad()` immediately before issuing the command.

Document the known gap in the file header: a `load` typed directly into the console is not seen by `markLoad`, so that one case is adopted as if it were a preference. Masking it properly needs an engine-side signal, which is not worth a hunk.

- [ ] **Step 4: Verify**

Run: `./tools/check-swift-session.sh` → pass. `make device` → BUILD SUCCEEDED.

- [ ] **Step 5: Commit**

```bash
git add App/Sources/DifficultyWatch.swift App/Sources/SessionState.swift tools/swifttest/session_test.swift tools/check-swift-session.sh
git commit -m "feat(difficulty): adopt a hub door's skill change, ignore a load's"
```

---

### Task 4: The picker

**Files:**
- Modify: `App/Sources/ContentView.swift` (`gameContent`, near the episode picker and the `start`-map note at `:1051`)

**Interfaces:**
- Consumes: `Difficulty`, `VRSettings.shared.skill`, `engine.send`.

- [ ] **Step 1: Implement the control**

A four-segment picker over `Difficulty.allCases`, labelled by `label`, bound to a `@State` mirror seeded from `VRSettings.shared.skill` (there is no live cvar read-back in the view layer, matching the existing `vr_hud` comment's reasoning). On change: write `VRSettings.shared.skill`, then `engine.send("skill \(raw)")`.

Beneath it, a caption that is **conditional on a level running**: when one is, it reads that the change takes effect on the next level, because the engine samples `skill` once per spawn (`sv_main.c:1489`). Review Focus 4 — a control that looks like it did something it did not is worse than no control. Use the same enabled/disabled idiom the Save button already uses for "Start a level to save".

- [ ] **Step 2: Verify**

Run: `make device` → BUILD SUCCEEDED. Then `make check` and `./tools/check-unit.sh` → unchanged and green (no C touched, so this is a regression check only).

- [ ] **Step 3: Commit**

```bash
git add App/Sources/ContentView.swift
git commit -m "feat(difficulty): four difficulties in the window, honest about when they apply"
```

---

## Device checks, for A. (cannot pass on a host test)

- Set Nightmare in the window, start a level: the monsters behave like Nightmare. The setting reached the engine, not just the label.
- Set Hard, relaunch the app: still Hard.
- Walk a hub door on `map start` to Easy, then open the window: it shows Easy.
- Load an Easy save while set to Nightmare, then open the window: **still Nightmare**.
- Press a difficulty mid-level: the caption says it applies next level, and the level you are in does not change.
