# Pelagic Orbits

A native C++ exploration game. You are a giant jellyfish swimming beneath the light of a nearby star. Moving ribbons and plankton trace the water that carries you. Follow a broad stream, circle an eddy, rest in its still centre, or slip into one of the four giants’ gold wakes.

The jellyfish have iridescent, scalloped bells, internal anatomy and branching canals. Folded oral arms grow from the web beneath the bell, and fine tentacles emerge in clusters under its scalloped edge. Their membranes bend the colours in nearby starlight, streams and trails by different amounts. Comb jellies carry rippling rows of light along their bodies, and suspended light drifts past at different depths as you swim.

The eight named currents are entry points into 7,714 solar systems. Press N within the atlas to enter the uncharted catalogue. The atmosphere evolves as you swim, with different kinds of jellyfish, orbital bodies, and a continuously synthesised score in each of four waters.

## Playing

Open **PelagicOrbits.app** on an Apple Silicon Mac running macOS 15 or later. Its bundled SuperCollider engine synthesises the score and creature sounds live and works offline.

| Control | Action |
| --- | --- |
| Arrow keys | Swim forward, back or sideways |
| Q / E | Sink / rise |
| Move the mouse or use I / J / K / L | Look around |
| Esc | Release the pointer. Click the water to look with the mouse again. |
| Tap F or click | Send a quick pulse through the shoal |
| Hold and release F or the mouse button | Contract your bell and call a nearby crown jellyfish alongside |
| N | Move to the next current |
| Tab | Open or close the atlas. Choose a current by clicking it or pressing 1–8. Press N here for an uncharted system. |
| D | Toggle hands-free drift. In Noctiluca this follows the opening swim. |
| Space | Pause / resume |
| H | Hide / show the HUD |
| M | Mute / unmute audio |

Noctiluca opens in quiet water with a solitary crown. Follow the fine cyan strands of the current through the Narrows. A giant crown crosses overhead near the mouth of the passage, hiding the star behind its bell and bending the water below. Look up as the light travels from its rim into its tentacles. Lantern Basin opens in layers as you swim forward. The nearest shoals light up in yellow-green, then turquoise and blue shoals appear deeper in the water. Look past the small jellyfish towards the dark bell at the far end of the basin. You can swim out to it and pass beneath its tentacles. The hands-free route takes about three minutes, including time to drift among the shoals after the encounter.

Moon jellyfish relay a quick pulse to their neighbours. Comb jellyfish answer with a slower ripple. A held call draws one nearby crown across your path and alongside for a while. Its reply sounds from the side where it is swimming. As you pass close to each other, your wakes leave a pair of braided filaments.

Swimming builds momentum with each bell contraction. Moving plankton and pulses of light show which way the current runs. Release the controls inside the stream and the water carries you through the bends. Tentacles lag behind a change of speed or direction and leave luminous streaks at their previous positions. The streaks soften and fade over about six seconds. The camera can orbit independently while the jellyfish turns towards its swimming direction.

## Music

The embedded score shifts its tuning and colour as you cross between the four waters. The current changes its texture, a quick pulse rings a bell, a held call produces a lower gliding tone, and shoal replies echo across the stereo field.

The ocean responds to three frequency bands in the engine’s stereo output, using the approach developed for Crimson Mirror / Prism Currents. Bass swells the water ribbons, mids bend them, treble brings out fine detail in the jellyfish and wakes, and attacks send brief glints along the current. **Music → Music-Reactive Ocean** toggles the visual response.

## Building

The simulation and host adapter use C++20. The macOS shell uses Objective-C++, AppKit, MetalKit and AVFoundation. The Metal shaders compile on launch. The project includes the source of SuperCollider App Engine 0.2.0 and its matching arm64 runtime. The engine compiles the SynthDefs in `audio/` with the embedded language library, creates one private SuperCollider World in the game process, and fills the host's stereo output callback through its C API.

Engine provenance, runtime build details and licenses are in [vendor/sc-app-engine/README.md](vendor/sc-app-engine/README.md).

With CMake 3.24 or newer and Apple Command Line Tools installed:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build --parallel
codesign --force --sign - build/PelagicOrbits.app
open build/PelagicOrbits.app
```

## Orbital and visual sources

The bundled numeric catalogue was reduced from the user's Infinity / Xalaria 0.68.0 checkout, whose underlying published data comes from [Xalaria's Universe index](https://www.xalaria.com/universe/). It keeps stellar radii and temperatures and up to three primary planets per system with orbital and material parameters. Four survey stars use representative radii and temperatures, with their orbital distances retained. Celestial positions, apparent sizes and orbital time are compressed for framing. Pelagic Orbits has its own names, voyages and visual compositions.

The four regional looks from Infinity / Xalaria informed the new scene shaders. Tidal Blue uses layered swells and light caustics, Verdant Fog uses green suspension, Charred Glass uses deep reds and violet highlights, and Acid Etch combines hot pinks and sulphur yellows. The jellyfish meshes, their membranes and tentacles, the water optics, and the score are generated by this game.
