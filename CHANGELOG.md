# Changelog

All notable changes to this project are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and the versions
follow [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.0] - Unreleased

First public alpha. Everything below is new; there is no earlier release to
compare against.

### Added

- The world, in stereo. QuakeSpasm 0.97's engine core with a native Metal
  renderer: textured lightmapped BSP with PVS culling, sky, warping liquids,
  brush and alias entities with lit lerped models, particles, dynamic lights
  and lightstyles, sprites, fog and polyblend.
- A mixed `ImmersiveSpace` at the device's 90 Hz — single-pass stereo through
  vertex amplification, foveated, with the head pose late-latched at encode.
- Hands as a first-class input: aim, fire, movement and the gestures around
  them, with no controller required. PSVR2 Sense controllers are supported as
  an alternative, with haptics.
- The aim/body split. The gun fires where you point while the camera stays the
  head and movement stays the body, and projectiles spawn at the muzzle rather
  than the chest.
- The weapon wheel: turn the off wrist over and the owned weapons ring that
  wrist as live spinning models while simulation time crawls; reach or point
  to highlight one, then turn the palm back to take it.
- The power gauntlet and the modular HUD: the status bar whole, or split
  into tiles you place and pin yourself, with a live in-headset editor.
- The phase dissolve — `phase 1` melts the world to passthrough around you and
  leaves the level's monsters, pickups and doors standing in your room.
- Sound, including the CD soundtrack, through an `AVAudioEngine` source node
  over the engine's own mixer. Stereo as Quake mixes it; not yet
  spatialized to the headset.
- Game menus in the SwiftUI window rather than in the world: new game,
  save and load against the engine's own `.sav` files, direct connect, and a
  LAN server browser.
- Capture and export. Record writes a Quake demo plus a `.vrtrack` sidecar;
  export replays it in lock step and renders offscreen to `.mov` at up to 4K
  and 120 fps, with slow motion, motion blur, five cameras, an optional burnt-
  in HUD and a per-frame `.csv`.
- `make ipa`, which packages an unsigned sideload build.

### Fixed

- The immersive session survives ARKit interruptions (Developer Capture,
  FaceTime, Guest Mode): world tracking rebuilds itself, frames skip cleanly
  instead of violating the compositor's contract, and the view re-seats with
  a recenter rather than shoving the player.
- Developer Capture records the game: every drawable a frame carries is now
  rendered and presented -- the recorder target included -- so starting a
  capture neither crashes the session nor produces an empty recording.

### Known gaps

- The rerelease episodes (`dopa`, `mg1`, `mg3`) do not load yet.
- Console text entry goes through the window's command bar, not the in-world
  console.
- Colormapped player skins, texture animation past frame 0, and the small
  `gl_screen.c` overlays are still stubbed. `README.md` lists the rest.
