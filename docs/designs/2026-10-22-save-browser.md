# A Cover Flow save browser, and a difficulty that sticks — design

Status: proposed, 2026-10-22. Not built. Two features in one document because
the cover shows the difficulty, so the browser wants the difficulty work to
exist first.

## Intent

Saves are currently rows of text. You read a level name and a date and guess
which one you want. A save is a *place you were standing*, and the thing that
tells you which one it is, is the picture.

So: every save keeps a screenshot of what you last saw in the headset, and the
save area becomes a Cover Flow carousel of those screenshots, carrying the
level, the kill count, the date and the **difficulty** on the face of each
cover. Difficulty is on there because it changes what loading that save means,
and because there is currently no way to see it at all.

Which surfaced the second half: there is no way to *set* difficulty either,
beyond walking a door on the `start` map or typing `skill 2` in the console.
The value also resets to Normal on every launch. That gets fixed here.

## What exists today

Verified against the engine and the app.

**Difficulty is already written into every save.** `Host_Savegame_f`
(`engine/host_cmd.c:1145`) writes `current_skill` on a fixed line: version,
comment, sixteen `spawn_parms` floats, then skill, then the map name, then
`sv.time`. So the difficulty of a save is the 19th line of the file and needs
no new plumbing to read.

**The two ways of setting it already agree.** `current_skill` is taken from the
`skill` cvar once per level spawn (`engine/sv_main.c:1489`, clamped 0..3). The
hub doors on `start` are QuakeC `trigger_setskill`, which reaches
`PF_cvar_set` (`engine/pr_cmds.c:962`) and sets that same cvar. There is
nothing to reconcile: the console, the hub and any new picker are all writing
one value.

**What is missing is persistence and a control.** `skill` is declared
`CVAR_NONE` (`engine/host.c:74`), so it reverts to `"1"` every launch, and the
window has no difficulty control anywhere — its only mention of the subject is
a comment about the `start` map being "Quake's in-game hub for difficulty"
(`App/Sources/ContentView.swift:1051`).

**The save list reads two lines.** `App/Sources/SaveGames.swift:96-98` parses
`lines[0]` for the version and `lines[1]` for the comment, and stops.

**Loading already restores difficulty.** `host_cmd.c:1245-1246` sets both
`current_skill` and the `skill` cvar from the file.

## Goals

- Every save made from now on carries a screenshot of the last thing seen in
  the headset, with the app's own window not in it.
- The save area is a Cover Flow carousel of those covers, each one carrying
  its level, difficulty, kill count and date on its face.
- Difficulty is one persistent value, settable from the window or by walking a
  hub door, surviving relaunch, and visible before you load anything.
- A save with no cover is never hidden or broken, and fills itself in.

## Non-goals

- Thumbnails for anything other than saves. This is not a file browser.
- Folder navigation, breadcrumbs, favourites or drag-out. The source component
  has all four; none of them mean anything for a flat list of saves.
- Changing the save file format. Covers live beside the file, not in it.
- Changing difficulty mid-level. The engine reads `skill` once at spawn; this
  design does not fight that.
- Exposing the engine's own menu. It stays console-only (`togglemenu`).

## Anti-goals

- A cover that is a picture of the window. If the screenshot shows the panel
  you were looking at when you pressed Save, the feature is pointless.
- A shelf of identical empty cards. The fallback has to look deliberate.
- Losing the version refusal. A foreign `.sav` must still be visibly refused
  with Load disabled; a prettier browser that silently drops it is worse than
  the rows.
- A seventh vendored engine hunk for persistence. One word in `host.c` is not
  worth the merge cost; the platform absorbs it.

## Constraints

- The capture must come from the immersive layer, not a window snapshot: the
  SwiftUI panel is a separate layer, so capturing the game drawable omits it
  for free. That is also the only way to get "what you last saw".
- Passthrough is composited by the system and is **not** in the app's
  drawable. A shot taken while phased out shows the game's own pixels only,
  with nothing where the room is. Covers of phased moments will look sparse
  and that is unavoidable. Raised with A. and accepted: it does not matter,
  so no effort goes into disguising it.
- Stereo: the immersive renderer draws two eyes per frame. A cover is one
  image, so one eye is chosen.
- `QC_*` thread rules apply. Reading the engine's skill value is a read-only
  snapshot, any-thread, in the shape of `QC_AdminCopyState`.
- The window is the only on-device debug surface and is now resizable with a
  1100x900 floor; the panel column is 560-680. The browser has to work at the
  floor.
- Input is hands and Sense controllers only. Every affordance needs both.

## The design

### Capture

The immersive renderer keeps the **most recent completed frame** as a small
JPEG, one eye, downscaled to cover size (my call: 480x320, quality 0.7,
re-encoded at most twice a second so it is never on the hot path). It is held
in memory, not written, until something asks for it.

Pressing Save in the window writes the engine's save, then writes that held
frame beside it. Because the window being open pauses the world and the
immersive layer stops producing new frames, the held frame is already the last
thing seen *before the panel appeared*, which is exactly what is wanted and
needs no special casing.

A save made from the console (`save s3`) while the immersive space is running
gets the same held frame. A save made with no immersive space ever opened gets
none, and falls back below.

### Where covers live

`<save>.jpg` beside `<save>.sav` in the same directory. Deleting a save takes
its cover with it, nothing needs a database or an index, and a missing file
means no cover. This is my call; the alternative, one sidecar index, buys
nothing and can disagree with the directory.

### The fallback, and healing

A save with no cover shows a plain dark card carrying all the same words.
Then: **the first time that save is loaded, a cover is captured for it** once
the level is running and a frame exists. Old saves fill themselves in as they
are actually played, the gap closes without any cover-drawing code, and a save
you never load keeps a plain card forever, which is honest.

### The browser

Cover Flow **replaces the save area entirely**; the rows go. Per cover, on the
face, bottom-aligned over a dark gradient:

- the level's full name
- a difficulty pip, coloured, four states
- kill count, secrets, and the date

Covers are self-describing so three can be read at once rather than swiping to
find out. Beneath the carousel: the slot-name field, Save, Load.

Carried over from `CoverFlowAssetBrowser`: `CoverFlowCarouselView`'s carousel
geometry and its wheel accumulator (which has its own tests and compiles
alone), and `AssetCardView` restyled. **Not** carried: the folder rail,
breadcrumbs, the thumbnail store and its QuickLook renderer, security-scoped
bookmarks, and `AssetDragProvider` — all of which exist for files on disk. The
`nothingElseIsFirstResponder()` guard is AppKit and has no visionOS meaning;
it goes.

Refusals keep their current behaviour and become cover states: a foreign
version shows the cover greyed with the orange version warning and Load
disabled, and "Start a level to save" / "Can't save during the intermission"
still gate Save.

### Difficulty: one value, two ways in, persisted outside the engine

Four buttons in the window (Easy, Normal, Hard, Nightmare) send `skill N`.
That is all the window does; it does not own the value.

Swift owns **persistence**. The stored difficulty is pushed as `skill N` once
at launch, before any map starts. The engine's live value is read back through
a read-only snapshot; when it differs from what is stored — which is what a
hub door or a console `skill` does — the new value is stored. So the hub door
keeps working untouched and still "sets a true flag", and neither route is
privileged.

No engine edit. `skill` stays `CVAR_NONE` in `host.c` and the platform carries
the archiving, which is the shim-instead-of-a-hunk rule in `working-notes.md`.

Nightmare is shown as an ordinary fourth button rather than hidden the way
vanilla hides it behind a secret route. **This is my call, flagged for A.** —
the hub's secret is still there for anyone who finds it, and a settings panel
that hides a setting is a worse settings panel.

The pip reads the save's own difficulty from line 19 of the file, not from the
current setting, so a cover always says what *that* save is.

## Verification

Host: the save-file parse (line 19 into a difficulty, bad and short files
refused), the cover path derivation, and the carousel's wheel accumulator,
which already has a suite. A fixture directory of `.sav` files with and
without covers, including a version-4 file and a truncated one.

Device, the criteria that cannot pass on a black screen:

- Save mid-level. The new cover shows the room you were standing in, and
  **the SwiftUI panel is not in the picture.**
- The pip matches: start a level on Hard, save, and the cover says HARD.
- Set Nightmare in the window, start a level, and the monsters behave like
  Nightmare — the setting reached the engine, not just the label.
- Set Hard in the window, relaunch the app, and it is still Hard.
- Walk a hub door on `start` to Easy, then open the window: it shows Easy.
- Load a pre-existing save with no cover; it shows a plain card, and after
  loading, its cover is there.
- A version-4 `.sav` shows a greyed cover with the warning and Load disabled.

## Consequence for the gate document

`.superpowers/sdd/window-menu-report.md` §6 items 1-4 and 11 are written
against rows ("the row must appear", "the orange version warning and a
disabled Load"). Those checks all still apply but have to be restated against
covers. **That is a rewrite of part of the release-1 gate, not just new UI**,
and release-1's "2D layer" box should not be ticked against the old wording.

## Decisions made here

- Cover Flow replaces the save rows; it is not an alternative view.
- Facts live on the cover, not in a text block beside it.
- Covers are JPEGs beside the save file, same basename.
- The capture is the last completed immersive frame, held in memory, one eye.
- Missing covers show a plain card and heal on first load.
- Difficulty is persisted platform-side, not by archiving the engine cvar.
- The window sends `skill N` and does not own the value; the hub door is equal.
- Only the carousel and the card come from the source component.

Three of these were put to A. as the builder's calls and confirmed by him on
2026-10-22, so they are settled rather than assumed:

- **Nightmare is visible**, an ordinary fourth button, not hidden behind the
  hub's secret route the way vanilla hides it.
- **Overwriting a slot re-captures its cover**, silently. The cover always
  matches the save it sits on; there is no way to keep an old picture against
  new state.
- **No delete affordance.** The rows have none today and this adds none. Noted
  as the obvious next thing to want once the browser is something you can
  actually look at.

## Left to the builder

- Cover pixel size, JPEG quality, and the re-encode interval.
- Which eye, and whether to crop or letterbox to the cover aspect.
- The read-back cadence for the engine's skill value.
- Carousel feel: how many covers visible at the panel's 560pt floor, and the
  swipe-to-index mapping for hands versus Sense.
- Pip colours, within the four-state scheme.

## For A.

Nothing outstanding. The three open calls (Nightmare's visibility, re-capture
on overwrite, and a delete affordance) were put to him on 2026-10-22 and are
recorded above under decisions. The sparse phased-out cover was raised as a
consequence and accepted.
