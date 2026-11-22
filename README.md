# Pelagic Orbits

A native C++ exploration game. You are a giant jellyfish swimming beneath the light of a nearby star. Moving ribbons and plankton trace the water that carries you. Follow a broad stream, circle an eddy, rest in its still centre, or slip into one of the four giants’ gold wakes.

The jellyfish have iridescent, scalloped bells, internal anatomy and branching canals. Folded oral arms grow from the web beneath the bell, and fine tentacles emerge in clusters under its scalloped edge. Their membranes bend the colours in nearby starlight, streams and trails by different amounts. Comb jellies carry rippling rows of light along their bodies, and suspended light drifts past at different depths as you swim.

The eight named currents are entry points into 7,714 solar systems. Press N within the atlas to enter the uncharted catalogue. The water colours, light and planets morph continuously, reaching a new environment every 30–60 seconds. Selecting a current from the atlas starts a 12-second morph. You can keep swimming through both changes, and the shoal and its trails stay in place.

## Playing

Open **PelagicOrbits.app** on an Apple Silicon Mac running macOS 15 or later. Its bundled SuperCollider engine synthesises the score and creature sounds live and works offline.

The swim view is text-free. Open the atlas with **Tab** to see the named currents.

Sink into dark water with **Q** or rise into richer colour with **E**. Look up to see the moon through the illuminated water.

| Control | Action |
| --- | --- |
| Arrow keys | Swim forward, back or sideways |
| B | Hold to brake and drift with the water |
| Q / E | Sink / rise |
| Move the mouse or use I / J / K / L | Look around |
| Esc | Release the pointer. Click the water to look with the mouse again. |
| Tap F or click | Send a quick pulse through the shoal |
| Hold and release F or the mouse button | Contract your bell and call a nearby crown jellyfish alongside |
| N | Move to the next current |
| Tab | Open or close the atlas. Choose a current by clicking it or pressing 1–8. Press N here for an uncharted system. |
| D | Toggle hands-free drift. Swim or brake to take over. |
| Space | Pause / resume |
| P | Cycle through the four graphics modes |
| V | View the enclosing jellyfish from outside or return to your swimmer |
| M | Mute / unmute audio |

**Hybrid Water** is selected at launch. It layers the original water at 50% opacity over a brushed ground. Turquoise, violet and pink travel through the painted currents and the jellyfish catch shifting iridescence. Choose **Original Graphics** or **Painted World** from the **View** menu to compare the looks.

**View → Adaptive Resolution** is on at launch. It adjusts the resolution and mesh detail underwater to reduce GPU load. Turn it off for the full-detail view.

**View → Ultra High Graphics** uses native drawable resolution, finer bell and tentacle meshes, and four-sample antialiasing for jellyfish on supported GPUs.

You start in the violet water of Lantern Basin, inside the largest jellyfish and facing the amber bell of the next giant. Look up to see the outer bell's luminous canals or press **V** to view it from the space-like water with its planets and stars. Follow the current through five progressively smaller bells, passing from the Amber Garden into the Cobalt Gloam, the Viridian Fold and the Carmine Deep. Follow the gold current into the cyan water of the smallest bell. A vertical shaft rises from the final whirlpool and grows brighter and taller as you approach. Its eye kindles your jellyfish’s solar system and grows brighter as you stay inside. Hold your position for two seconds to grow into the largest jellyfish. Three contractions send luminous wakes and clouds of plankton curling out from its rim. A current carries you through the bell membrane and back to the original swimmer in Lantern Basin. The system you kindled becomes the next cycle’s sky. You can swim back through the same openings or turn away from the first bell to explore the Narrows. Press **D** to follow the whole cycle hands-free.

Near the start, the amber giant contracts and sends a wave out into the basin. Let the crest pass and ride the water it draws back towards the bell. The Amber Garden lifts you, the Cobalt Gloam carries you sideways, and the shoals in the Viridian Fold bend the flow around them. The water rolls down through the Carmine Deep and settles around the eye. The planet that forms there keeps its ring tilt and tint when it becomes part of the next cycle's sky. Listen for the same three notes as you return.

Moon jellyfish relay a quick pulse to their neighbours. Comb jellyfish answer with a slower ripple. A held call draws one nearby crown across your path and alongside for a while. Its reply sounds from the side where it is swimming. As you pass close to each other, your wakes leave a pair of braided filaments.

Your bell contracts more strongly as you swim, and your body banks as you turn. Release the controls to glide or hold **B** to shed speed and match the local current. Moving plankton and pulses of light show which way the water runs. Tentacles lag behind changes in speed and direction and leave luminous streaks that soften over about six seconds. The camera can orbit independently while the jellyfish turns towards its swimming direction.

## Music

The embedded score shifts its tuning and colour as you cross between the nested and open waters. The current changes its texture, a quick pulse rings a bell, a held call produces a lower gliding tone, and shoal replies echo across the stereo field.

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
