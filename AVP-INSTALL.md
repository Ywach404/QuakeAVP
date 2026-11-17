# Installing QuakeAVP on Apple Vision Pro

**Want to see it running before you build it? [Watch the devlog](https://www.youtube.com/watch?v=-G4lDuGikJI) -- the port on a real Vision Pro, played with bare hands.**

QuakeAVP is a native visionOS port built on QuakeSpasm's engine core, with a
Metal renderer written where the OpenGL one used to be. It ships no game data.

## Requirements

- A Mac with Xcode and the visionOS 26 SDK or later.
- Apple Vision Pro running visionOS 26 or later.
- An Apple ID. A free one works, and sideloaded apps then have to be re-signed
  every 7 days. That is Apple's limit on free provisioning, not something this
  project can work around.
- `xcodegen` (`brew install xcodegen`). The Xcode project is generated from
  `project.yml` and is not checked in, so this is required rather than optional.
- Your own copy of Quake, and its game files. See **Game files** below.

There is no App Store build and there will not be one: GPL-2.0 is widely held
to be incompatible with the App Store's terms. This installs to a device you
own.

## Game files

You need to supply your own game files, legally obtained from a copy you own.
This repository contains none, and never will.

- **Required:** `pak0.pak`, placed in an `id1` folder.
- **Optional:** `pak1.pak` in the same folder. Without it you have episode 1
  only, and the engine runs unregistered, which also means a loose `music`
  folder is not read.
- **Optional:** the mission packs, each in its own folder beside `id1`:
  `hipnotic` for Scourge of Armagon, `rogue` for Dissolution of Eternity.

Where they go, once the app has been installed and launched once:

```
On My Apple Vision Pro / QuakeAVP / id1 / pak0.pak
```

The app creates `id1` on first launch, so the folder is already waiting for
you in the Files app. QuakeAVP appears there by name.

To check it worked: the app tests for `id1/pak0.pak` before it boots and says
so plainly if the file is missing, rather than letting the engine die on you.
The missing-data panel has a **Check again** button, so you can drop the files
in and retry without relaunching.

The 2021 rerelease episodes (`dopa`, `mg1`, `mg3`) do not load yet.

## Build

Start from a checkout of this repository. Every step below runs from the
repository root, and none of them fetches anything except the one Homebrew
install above.

1. Generate the Xcode project:

   ```sh
   make gen
   ```

2. Set your signing team. The `DEVELOPMENT_TEAM` tracked in `project.yml` is
   the author's and will not work for you. Either edit that one line, which is
   the only thing that survives a regeneration, or open the project and set it
   in the UI:

   ```sh
   open QuakeAVP.xcodeproj
   ```

   In Xcode, select the **QuakeAVP** target, then Signing & Capabilities, then
   set **Team** to your own. Note that `make gen` rewrites the project, so a
   team set this way has to be set again after any later `make`.

3. Build and run to the headset from Xcode, or use the one-step route below.

To check the engine compiles without Xcode at all, which takes seconds:

```sh
make check
```

## Install on Apple Vision Pro

Pair the headset with Xcode first, if you have not already.

With the headset connected, from the repository root:

```sh
make run
```

That builds, installs and launches on the device. It launches **without** the
debugger attached, deliberately: the debugger disrupts the audio and
compositor services on visionOS, and with it attached you get silence and
sometimes an immersive space that never finishes loading. Neither is a bug in
the app, so prefer `make run` over Run in Xcode.

On first launch you may need to trust the developer profile on the device,
under Settings, General, VPN & Device Management.

Then put your game files in place as described above, and press **Check
again**.

## Controls and known issues

Plays with bare hands, and with PSVR2 Sense controllers.

With bare hands: your dominant forearm aims, pinches fire and move, turning
your off wrist over opens the weapon wheel, and a closed off-hand fist throws
the grappling hook. The full control reference, including diagrams, is in the
repository's `README.md`.

Known gaps:

- The 2021 rerelease episodes (`dopa`, `mg1`, `mg3`) do not load yet.
- Console text entry goes through the flat window's command bar rather than
  the in-world console.
- Texture animation past the first frame and some small 2D overlays are still
  stubbed.

The flat window is the launcher and a mono debug view. Play happens in the
immersive space, which opens by itself once the engine is up.

## Licence

GPL-2.0-or-later, inherited from QuakeSpasm. See `LICENSE.txt` and
`UPSTREAM.md`.
