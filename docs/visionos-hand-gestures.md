# Bare-hand gestures and windows on visionOS

Portable notes from building the prayer-sign console summon in quake-avp
(September 2026, visionOS 26/27, Vision Pro hardware). Everything here was paid
for on device — each section marks what was **measured** versus what is
judgement, because most of the cost came from confusing the two.

Nothing in this file is quake-avp specific. The implementations live in
`App/Sources/PrayerPose.swift`, `GestureDwell.swift` and `InputHost.swift`.

---

## 1. ARKit does not report the finger joints you expect

**Measured.** `HandSkeleton.Joint.isTracked` is false far more often than the
docs suggest, and it degrades with occlusion in exactly the poses a two-handed
gesture creates. Logging tracked-ness per joint while bringing both hands
together gave:

| Wrists apart | Untracked |
|---|---|
| 0.31 m | `indexFingerKnuckle` |
| 0.24 m | `middleFingerKnuckle`, `littleFingerKnuckle` |
| 0.09 m | all three knuckles, plus `middleFingerTip` |

Never once untracked across a whole session: **`wrist`, `forearmWrist`, and
every `...Metacarpal`.**

The reason is structural. Knuckles and tips are derived from *finger
articulation*, which needs the fingers visible. Metacarpals are the palm bones,
fixed relative to the hand's rigid pose, so ARKit reports them from the hand's
gross position alone.

> **Rule: build hand poses from `wrist` + metacarpals.** Treat every
> `...Knuckle`, `...IntermediateBase` and `...Tip` as optional, especially for
> any gesture where the hands touch, overlap, or turn away from the cameras.

This bit twice: first by reading `middleFingerKnuckle` for a finger direction,
then by falling back to the index/little *knuckles*. Both produced a pose that
was nil in 100% of frames while a visually perfect gesture was held.

### Palm plane from three reliable joints

```swift
init?(wrist: SIMD3<Float>, indexMetacarpal: SIMD3<Float>,
      littleMetacarpal: SIMD3<Float>, isLeft: Bool) {
    var n = simd_cross(indexMetacarpal - wrist, littleMetacarpal - wrist)
    // Across the palm, index side to little side. Both this and the normal
    // mirror between hands, so one flip serves both.
    var across = indexMetacarpal - littleMetacarpal
    if !isLeft { n = -n; across = -across }
    let len = simd_length(n), acrossLen = simd_length(across)
    guard len > 0, acrossLen > 0 else { return nil }
    let normal = n / len
    self.init(center: (wrist + indexMetacarpal + littleMetacarpal) / 3,
              normal: normal,
              forward: simd_cross(normal, across / acrossLen))
}
```

The finger direction is the **third axis of the palm frame**, not a vector to a
fingertip. That is the whole trick: it survives the fingers being invisible.

**Do not trust a normal's sign derived by reasoning.** On device this normal
points out the *back* of the hand, not the palm — measured as a steady
`dot(leftNormal, normalize(rightCentre - leftCentre)) = -0.89` across 100+
frames of a genuine prayer sign. Anatomy worked out at a desk got this backwards
three times. If a gesture needs the outward direction, measure the sign on
hardware first and write the measurement into the comment.

---

## 2. visionOS reserves the palm; you cannot have it

**Measured/documented.** Palm toward the face raises the Home View dot; palm
away raises the status bar into Control Center. `.persistentSystemOverlays(.hidden)`
is a *preference* — Apple's own forum guidance points at it, but the overlay
still appears when the user looks at their palm and pinches, and developers have
reported it unfixed for over a year.

> **Rule: never design a bare-hand gesture around an open palm facing toward or
> away from the face.** You are competing with the OS and you lose.

A prayer sign works precisely because both palms are edge-on to the face —
a pose the system makes no claim on. Other safe territory: hands below the
sightline, fingers interlocked, hands touching each other.

---

## 3. Gesture detectors: pure geometry, injected clock

Split every gesture into two testable value types and one thin ARKit adapter.

**Shape** — pure geometry over reduced facts, no ARKit types:

```swift
struct PalmPose { var center, normal, forward: SIMD3<Float> }

static func matches(left: PalmPose?, right: PalmPose?) -> Bool {
    guard let l = left, let r = right else { return false }   // nil = untracked
    guard simd_distance(l.center, r.center) <= gapMax else { return false }
    guard simd_dot(l.normal, r.normal) <= facingDotMax else { return false }
    return l.forward.y >= fingersUpMin && r.forward.y >= fingersUpMin
}
```

**Timing** — hold-to-fire with the clock passed in, so it tests without waiting:

```swift
mutating func update(active: Bool, now: Double) -> Bool {
    guard active else { heldSince = nil; firedThisHold = false; return false }
    guard let since = heldSince else { heldSince = now; return false }
    guard !firedThisHold, now - since >= dwell else { return false }
    if let last = lastFired, now - last < cooldown {
        firedThisHold = true          // consume, so releasing and re-holding
        return false                  // cannot queue a fire for later
    }
    firedThisHold = true; lastFired = now
    return true
}
```

Two properties worth testing explicitly: **one fire per hold**, and **a flicker
must not accumulate** toward a trigger.

### Test what the hardware supplies, not just the maths

Both types above had full passing suites while the feature was completely dead,
because every test fed the detector synthetic joints the hardware never
supplies. Unit tests prove the geometry; they cannot prove the inputs exist.
Budget one on-device run before believing any of it.

For pure geometry, skip Xcode entirely — compile the real source on the host and
run it in seconds:

```sh
swiftc -O App/Sources/PrayerPose.swift main.swift -o probe && ./probe
```

This also catches stale-build false failures, which cost a full cycle here.

---

## 4. Instrument every condition with its measured value

The single highest-leverage thing in this whole effort. Print each condition
against its threshold with a pass/fail mark:

```
[summon] prayer=0 gap=0.08<=0.16 ok | face=-0.63<=-0.4 ok | toward=-0.88>0 NO | up=0.83/0.82>=0.5 ok
```

One line identifies the blocking condition *and* hands you the number to set it
to. Every threshold in the shipped detector came from these logs:

| Threshold | Desk guess | Measured reality |
|---|---|---|
| palm gap | 0.12 m | 0.07–0.16 m while held → **0.16** |
| normals opposed | −0.6 | −0.41 to −0.95 while held → **−0.4** |
| fingers up | 0.5 | 0.53–0.94 while held → 0.5 holds |

Also log the *absence* of inputs, and arm that log off a joint that stays
tracked (the wrist), not the one you are testing. Gating the diagnostic on the
palm plane would have hidden the missing-palm case — the actual bug — entirely.

---

## 5. Never own input in a SwiftUI view

**Measured.** `@State private var hands = HandInput(...)` on the main view means
the ARKit session dies when that window closes. For an in-game gesture that
summons a window, this is fatal by construction: the gesture only matters when
no window exists, which is exactly when nothing is left to detect it. It also
silently killed *controller* input.

> **Rule: ARKit sessions, GameController observers and anything else with a
> process-long lifetime belong in a shared owner, never in view state.** Drive
> activation from something that also outlives windows.

```swift
@MainActor @Observable
final class InputHost {
    static let shared = InputHost()
    let gamepad = GameControllerInput()
    let hands: HandInput
    private init() {
        hands = HandInput(aggregator: gamepad.aggregator)
        gamepad.onControllerChange = { [weak self] in self?.refreshActive() }
        RendererCoordinator.shared.onImmersiveChanged = { [weak self] _ in self?.refreshActive() }
        gamepad.start()
        refreshActive()
    }
}
```

Views then only *read* it. A bonus fix: `start()` had been re-running on every
window reopen, stacking duplicate `NotificationCenter` observers.

---

## 6. `Window`, not `WindowGroup`, for a singleton surface

**Measured.** `.onDisappear` does **not** fire when the user closes a visionOS
window. Any presence tracking built on `onAppear`/`onDisappear` counting only
ever increments, so a "don't open a duplicate" guard suppresses the feature
permanently after first use.

> **Rule: if a window is conceptually unique, declare it `Window(_:id:)`.**
> `openWindow(id:)` then reopens it or brings it forward, duplicates are
> impossible, and no presence tracking is needed.

`WindowGroup` is for documents you legitimately want several of. Reaching for a
manual counter to stop it duplicating is the signal you picked the wrong scene
type.

An `OpenWindowAction` captured from `@Environment(\.openWindow)` **does** remain
valid after its own view is torn down — confirmed on device.

---

## Checklist for the next gesture

1. Does the pose keep both palms off-axis from the face? (§2)
2. Does it read only `wrist` + metacarpals? (§1)
3. Is the geometry a pure function over reduced facts, with an injected clock
   for timing? (§3)
4. Does the diagnostic log print every condition with its measured value, armed
   off a joint that stays tracked? (§4)
5. Does anything stateful live in view state that shouldn't? (§5)
6. Have you run it on hardware before believing the green suite? (§3)
