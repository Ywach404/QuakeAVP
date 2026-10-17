# Feet on the real floor — design

Status: proposed, 2026-10-17. Not built. The second design,
`2026-10-17-room-obstacles.md`, depends on this one.

## Intent

When the world phases out to passthrough, the Quake floor and the real
floor should be the same plane, by default, for every player and every
posture. The enemies stand on the Quake floor, so once the floor is right
the enemies stand on your carpet. Today that only happens by luck or by
sliding a trim until it looks right, and it breaks the next time you
recenter from a different height.

## Where the floor lands today

Verified against `Sources/QuakeRenderer/ImmersiveRenderer.swift` (the
anchor at :655-664, the recenter correction at :2479-2487) and the
engine's numbers.

The mapping is eye-locked. The Quake eye (`vieworg`, which is the player
origin plus viewheight 22 plus bob) is pinned to the headset's position at
the last recenter, and the recenter correction zeroes the full head
translation, height included. Nothing reads the real floor. So the Quake
floor sits at

    H_recenter - 46 * world_scale - heightOffset

above the real floor, where `H_recenter` is the eye height at the moment
of recenter, 46 units is Quake's eye height above its feet (viewheight 22
plus hull bottom 24), and `heightOffset` is the Comfort slider, default
0.40 m. At the defaults that is `H_recenter - 1.57 m`:

| eye height at recenter | Quake floor vs real floor |
|---|---|
| 1.55 m | 2 cm below |
| 1.65 m | 8 cm above |
| 1.75 m | 18 cm above |
| 1.20 m, seated | 37 cm below |

Open the space seated, stand up, and the whole level rises with you until
the next recenter. Recenter seated and the enemies' feet sink into the
floor. The phase sphere makes this maximally visible: at its near radius
it already reaches below your feet, and monsters do not phase, so the
floor dissolves out from under fully drawn enemies at the wrong height.

A floor-locked mapping was tried once and reverted; the code comment at
`ImmersiveRenderer.swift:2470-2478` records why: it assumed the tracking
origin was at floor level, which did not hold on device. The missing
ingredient was a measured floor. The app runs no plane detection today.

## Goals

- The player's feet are on the real floor whenever a floor has been
  measured, in every posture, with no slider.
- Recentering never moves the floor. It still fixes yaw and horizontal
  position.
- Enemies stand on the real floor during phase, by construction: they
  share the player's Quake floor.
- Head height above the floor is the player's real height. A tall player
  looks down on a grunt the way the scale says they should.

## Non-goals

- Aligning the level's walls, doors or stairs to the room. This is the
  floor only.
- Changing how far the player box walks after the head, or any of the
  room-scale head-follow contract. Horizontal stays as it is.
- Choosing the world scale for the player. `vr_worldscale` stays a knob;
  this design only decides where the floor is at any scale.

## Anti-goals

Anything that makes the floor wrong in one posture to make it right in
another. The reverted attempt did that. If no floor has been measured,
the mapping must fall back to today's behaviour, not to a guess.

## The design

### Measure the floor

Run a `PlaneDetectionProvider` for horizontal planes in a sibling ARKit
session of its own, supervised the way `DeviceAnchorSource` supervises
world tracking, not in the world-tracking session. That session's
supervisor retries a failed `run` forever; a refused world-sensing
permission inside it would take head tracking down with it. The sensing
session is the one the obstacles design later adds scene reconstruction
to.
Take the lowest horizontal plane classified `floor` that is at least
0.5 m² and within 2.5 m horizontally of the head. Its height in the raw
tracking frame, `floorY_raw`, is the measurement. Keep it across frames;
replace it only when a floor plane with a lower height or a larger area
arrives, and never from a plane above the head.

Plane detection requires world-sensing permission, which the app does not
ask for today. `NSWorldSensingUsageDescription` goes into `project.yml`
and the player sees one new prompt, once. If permission is refused or no
floor plane has arrived yet, the mapping is exactly today's.

### Anchor the feet, not the eye

The immersive anchor is the Quake point placed at the tracking origin.
Today it is the eye. It becomes the player's feet, placed at the measured
floor:

    anchor_z = vieworg_z - viewheight - bob - (floorY_room / world_scale) + trim

where `vieworg_z - viewheight - bob` is the hull bottom reconstructed from
the eye rather than read from the entity origin, `floorY_room` is the
floor height after the recenter correction, and `trim` is the Comfort
slider in Quake units, now defaulting to zero and meaning "raise the world
this much relative to the measured floor" rather than "guess my height".

The eye, not the entity origin, because upstream smooths stairs on the
eye only: `view.c` eases `vieworg` up a step at 80 units a second, capped
at 12, while the origin snaps. Anchoring to the origin would snap the
whole level and the passthrough floor by up to 30 cm on every stair. The
packet gains one float, `viewheight`, which the client already holds
(`cl.viewheight`, server-fed, 22 standing and -8 dead). The death camera
no longer sinks: the camera is the real head, and dropping a VR camera to
the floor on death is not a feature worth keeping.

The camera then sits at `anchor + head_room / world_scale`, so its height
is the player's real head height above the real floor, divided by the
scale. Vertical head motion keeps working as it does today. The player
box still does not move vertically with the head; that is unchanged and
correct.

Horizontal composition is untouched: `vieworg` minus the absorbed offset
minus the clamped lean, yaw from `body_yaw`.

### Recenter keeps the floor

The recenter correction zeroes yaw and the horizontal translation only.
Vertical translation is left alone, because the floor measurement defines
vertical. Today it zeroes all three, which is what resamples the floor
every recenter.

### Bob

`cl_bob` is live and never set by the port. The anchor subtracts bob, so
the world does not oscillate with it; but bob still rides in `vieworg`,
which the wheel, the hands and the HUD are placed from. Set `cl_bob 0` as
the port's default in the immersive space so those stop bobbing too. The
flat window may keep it.

### What the engine is told

`QC_InputSetHeightTrim` is fed the effective offset, camera height minus
`vieworg` height in Quake units, not the slider value. Every engine-side
reconstruction of the eye (the hand origin, the wheel, the head-locked
prompts, the hand-anchored gun) adds that trim to `vieworg`, and under a
floor-anchored frame the slider alone would put the menu and the hands at
the feet. Feeding the effective offset keeps those call sites unchanged
and keeps old `.vrtrack` sidecars replaying as they did.

### Scale

`vr_worldscale` stays the single scale knob, default 0.0254 m per unit,
clamped to ±20 %. At that default a grunt's hull is 1.42 m tall and an
ogre's 2.24 m, standing on your floor. Players who want enemies bigger or
smaller next to them turn the knob; the floor stays put at every setting
because the anchor formula divides by the same scale.

### What the slider becomes

The Comfort slider "Eye height" is renamed "Floor trim", range ±0.3 m,
default 0, with the caption "Nudge the floor if it sits above or below
your real floor." It is one global value, not per input profile: the
floor does not depend on whether a controller is connected. Old saved
profiles carry a 0.40 default that must not be read into the new trim;
the setting gets a new key.

### Fallback and transitions

- No floor measured yet, or permission refused: today's eye-locked
  mapping with the old 0.40 m baked in as a constant, plus the trim. The
  slider means the same thing in both states, raise or lower the world,
  so its caption holds and a player who refuses the prompt keeps a knob.
- Floor arrives mid-session: switch the anchor over a short eased
  transition, about a second, so the world does not jump. The transition
  runs on the render thread in the anchor computation; nothing engine-side
  changes.
- Provider rebuilt after an interruption (Developer Capture is one): the
  new provider may carry a new tracking origin, so the kept height is in
  the wrong frame. Reset the selection: keep the old anchor until the
  first floor plane from the new provider arrives, then switch to it with
  the same eased transition. The lower-or-larger rule applies only within
  one provider's life.

## Verification

Host and simulator cannot see a floor. The criterion is on device:

- Standing, phase out on a flat part of a level. The real floor appears
  exactly where the virtual floor dissolves, no step up or down at the
  rim. Sit down, recenter, and it is still exactly there.
- A grunt in the phased room stands with its feet on your floor, not
  floating and not sunk to the ankles.
- Walk with the stick while phased: the floor does not bob.

Numbers to log alongside: `floorY_raw`, the chosen plane's area, and the
anchor's vertical offset from the old eye-locked value, so a wrong floor
can be told from a wrong formula.

## Decisions made here

- Feet anchored to a measured floor, not the eye to the head. The head
  carries the player's real height.
- Plane detection, not scene reconstruction, measures the floor. It is
  lighter, gives a classified plane directly, and the obstacles design can
  share the same session later.
- Recenter stops resampling height.
- `cl_bob 0` in the immersive space.
- The slider becomes a trim from the measured floor, global, default 0.

## Left to the builder

- The plane selection rule's exact thresholds, and whether to average two
  overlapping floor planes.
- Where the eased switch-over lives in `ImmersiveRenderer`.
- Logging format.
- How the old per-profile `heightOffset` field is retired without a read
  of its 0.40 default into the new trim.

## For A.

- Whether the trim should still be per input profile. This design says
  global.
- Whether the world-scale default should move once the floor is right.
  The data suggests not; the floor fix removes the reason the eye height
  felt wrong.
