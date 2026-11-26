# Pelagic Spheres

Pelagic Spheres is a native C++ exploration game based on Pelagic Orbits v0.10.31. You pilot a small ship through a chain of six translucent bubbles. Their iridescent films flex in the current and bend the light around them. Each contains its own miniature solar system.

The eight named currents are entry points into 7,714 solar systems. Press N within the atlas to enter the uncharted catalogue. The water colours, light and planets morph continuously, reaching a new environment every 30–60 seconds. Selecting a current from the atlas starts a 12-second morph. You can keep flying through both changes, and the shoal and its trails stay in place.

## Playing

Open **PelagicSpheres.app** on an Apple Silicon Mac running macOS 15 or later. Its bundled SuperCollider engine synthesises the score and creature sounds live and works offline.

In the bubble world, the camera follows just above and behind your ship. The crosshair follows the ship's aim as the camera trails behind. Open the atlas with **Tab** to see the named currents.

Sink into dark water with **Q** or rise into richer colour with **E**. Look up to see the moon through the illuminated water.

| Control | Action |
| --- | --- |
| Arrow keys | Thrust forward, reverse or sideways |
| W / S | Alternate forward and reverse thrust |
| B | Hold to brake and drift with the water |
| Option / Control | Hold for forward boost or fine thrust and steering |
| Q / E | Sink / rise |
| Move the mouse or use I / J / K / L | Pitch and yaw |
| Esc | Release the pointer. Click the water to steer with the mouse again. |
| Tap F or left-click | Send a pulse wave. Each unstrung bubble it reaches rings once. |
| Hold and release F or the mouse button | Send a sustained call to draw a nearby crown sphere alongside |
| Return or right-click | Fire the selected tool |
| T | Return to the string tools or switch between String and Disconnect |
| Z | Select Harpoon or return to the string tools |
| O | Toggle the nose searchlight |
| U | Hold the ship and chase camera in place while the mission wheel is open. Press again to release. |
| C | Release the first anchor before completing a string |
| N | Move to the next current |
| Tab | Open or close the atlas. Choose a current by clicking it or pressing 1–8. Press N here for an uncharted system. |
| R | Open or close the Xalaria Region Atlas. Click a region to inspect its stars and mark its bubble. |
| H | Toggle the flight guide |
| Y | Mark a nearby region bubble. Press again to clear the mark if still aimed at the same bubble. |
| X | Inspect the marked or nearest region, or return to flight |
| D | Toggle hands-free drift. Apply thrust or brake to take over. |
| Space | Pause / resume flight, including the searchlight scan and tool effects |
| P | Cycle through the four graphics modes |
| G | Open the Ziksa cockpit or return to the chase view from a cockpit |
| V | View the enclosing sphere from outside or return to the chase view |
| M | Mute / unmute audio |

## Cockpit

Press **G** or choose **View → Ziksa Cockpit** to start on approach to Phehmyar. Ziksa contains one star, seven planets, five moons and planetary rings. Use the harpoon to enter other bubbles. The cockpit instruments track velocity, stopping distance, throttle, assist and the selected body. Press **Y** to select a destination and **J** to warp within the current star system. The drive lines up the ship and brakes automatically on approach. Warp is locked in regional space and while under attack. An attack also cancels a warp in progress. Use ordinary thrust for close flight.

| Control | Action |
| --- | --- |
| W / S | Raise or lower the throttle. It holds its setting when you release the key. |
| A / D, Q / E | Strafe and move vertically |
| Arrow keys or mouse | Pitch and yaw |
| Z / V | Roll |
| R | Level the horizon |
| F | Switch between flight assist and inertial flight |
| Option / Control | Hold for boost or precision |
| Shift + mouse | Look around the cockpit |
| B | Cut the throttle, cancel warp and brake |
| Y | Select the next planet, moon or star |
| J | Warp to a destination in the current system when clear of attack, or cancel warp |
| C or Esc | Release the mouse. Click the window to recapture it. |
| G | Return to the chase view |
| M | Mute / unmute audio |

The port uses the seated Xalaria cockpit, deck, hatch, glazing, yoke and throttle. The yoke and throttle move as you fly, and the seated view responds to acceleration. Infinity's flight assist, velocity limits and angular momentum integration operate on physical distances. The chase camera follows the Xalaria Patrol hull with Pelagic's current-driven steering. The bubble film limits cockpit flight, and solid celestial bodies deflect the ship on contact.

## Xalaria missions

Enter a star system's cockpit with **G** from the starting bubble or by boarding a system bubble with the harpoon. Press **F7** to open Dispatch. Scan a world in orbit, hail a nearby ship or board at a station to discover leads. Track a lead in its dossier, visit the marked site, collect evidence when required and file a report. Decisions affect subsequent reports and follow-up chapters.

| Control | Mission board |
| --- | --- |
| F7 | Dispatch for nearby assignments, news, local leads, follow-ups, the journal and discoveries |
| F4 | Charters for parcel contracts, deliveries and freight transfers |
| F8 | Combat for nearby targets, weapons, repairs, warrants and recovery after hull destruction |
| F9 | Convoys for escort contracts, distress calls and prize operations |
| F10 | Fleet Command for assigning captains and ship orders, earned intelligence and discovered campaigns |

Use the app's **Missions** menu to open the same boards. Click a page or use **Tab** to move between pages on the current board. Select a row to read its dossier and see the available actions. **Esc** closes the board.

| Control | In the cockpit |
| --- | --- |
| N | Scan the selected world or local activity and collect evidence when in range |
| T | Cycle traffic targets |
| I | Hail the selected contact |
| H | Approach the next wormhole ring on a plotted route |
| Return | Request docking, return to the helm or depart a secured berth |
| E | Board a clamped ship or station, or interact at an accessible site |
| U | Arm or safe the weapons. The Combat board has the same action. |
| 1 / 2 / 3 | Select Pulse, Ion or Torpedo when the ship's fit and ammunition allow it |
| Space | Fire when armed. Pause or resume when weapons are safe. |
| Shift + Space | Pause or resume with either weapon state |

For an assignment in another system, plot its route on the board, then approach and fly through the wormhole rings. **J** warps between bodies in your current system and remains locked while under attack. Docking and landing use physical approaches. Once secured, **E** opens the dockside interaction for passengers, witnesses or freight.

Pelagic uses Xalaria–Infinity 0.68.0's native mission, economy, traffic, combat and strategy logic. Mission locations use the same catalogue IDs as the bubble atlas and the cockpit. Progress autosaves to `Xalaria Missions.session` in the game's Application Support directory.

To choose a fleet order destination, inspect a region's systems with **X**, select a system with the arrow keys and press **Shift + Return**.

### Restoring Bubble Colour

Press **F6** for **Bubble Missions**. A system bubble or region bubble has two to six assignments generated from its catalogue ID. Region assignments take place in systems inside that region. You can open the board for the current system from the cockpit, a highlighted system from the survey, or a marked region from the region atlas. The **System Bubble** and **Region Bubble** tabs show the separate lists.

Each layer has its own monochrome shade for locked bubbles, including their planets and the space seen through the cockpit glass.

| Layer | Locked shade |
| --- | --- |
| Lantern Basin | Midnight Slate `#1B3644` |
| Amber Garden | Sulphur Gold `#F4B21B` |
| Cobalt Gloam | Electric Cobalt `#1F4ECE` |
| Viridian Fold | Acid Lime `#8FD217` |
| Carmine Deep | Scorched Violet `#522B91` |
| Whirlpool | Crimson `#DC143C` |

Choose a petal to read its brief and destination, then select **Track assignment**. Collect the required evidence and file in **F7 Dispatch** at the assignment site. Each listed report counts once. When you file a bubble's first report from the cockpit, its transition to full colour plays when you return to Bubble World. Mission saves retain completed reports and the colour they restore.

## Bubble World

**Hybrid Water** is selected at launch. It layers luminous currents over a brushed charcoal ground. The bubble films catch flashes of hot magenta, ember orange and sulphur yellow. Choose **Original Graphics** or **Painted World** from the **View** menu to compare the looks.

**View → Adaptive Resolution** is on at launch. It starts the underwater renderer at 1280 pixels wide, or at native resolution for a smaller window. It steps toward native resolution when the GPU has time to spare and reconstructs the frame directly at display resolution. Turn it off to render at native resolution in any graphics mode.

**View → Ultra High Graphics** uses native drawable resolution, finer membrane meshes, and four-sample antialiasing on supported GPUs.

Press **O** in bubble view to toggle the ship's nose searchlight. Its beam follows the ship's heading and lights nearby membranes and suspended particles. Nearby bubbles also cast their colour onto the hull. The **Tools → Searchlight** menu and chase HUD show the lamp state.

Hold the beam on the same bubble for one second to see its missions. An arc at the point of impact fills as you aim. The mission petals unfold around small bubbles and centre on large ones. Completed assignments have a checkmark. You can keep flying while the wheel is open. Press **U** to hold the ship, camera and selected bubble in place and pin the menu on screen. If you select a star system, the enclosing region holds its position too. The membranes still flex and the planets keep orbiting. The lock frees the pointer so you can click a petal and stays engaged while you read the mission. Use **Shift + 1–6** to open a mission by keyboard. Press **U** or **Esc** from the wheel to resume flight. Switching views or turning off the searchlight releases the lock. **F6** opens the board for the lit bubble.

Your ship starts in Lantern Basin, just inside the outermost layer, facing a faint distress signal from Groepai. Press **O**, hold the beam on Groepai and open **Reflected beacon** with **Shift + 1**. Press **Return** to track, then **Z** and **Return** to harpoon into the bubble. Press **N** to scan from the cockpit, **F7** to file the report and **G** to return to the same position in Bubble World. Groepai also offers a freighter rendezvous and a longer investigation.

The Bubble World flight HUD shows live heading, speed, pitch and bank. Its lower readouts show the tracked objective, passage progress, tool mode, searchlight and position lock. The region atlas (**R**) shows completed and total assignments for each layer.

Each inward passage requires a total number of distinct restored bubbles and a local string pattern. Amber Garden requires **5–8 restored bubbles**, and each passage adds another **5–8** to the cumulative target. A system or region counts once when its first report restores its colour. Saved completions count toward the target.

Each passage rolls a pattern with exactly as many colour bubbles as its cumulative target, separated by one to three monochrome bubbles. The HUD uses **C×3** for three consecutive colour bubbles and **M** for one monochrome bubble. For a six-bubble colour target, **C×2 – M – C×4** means two colour bubbles, then one monochrome bubble, then four more colour bubbles. Build one unbranched chain of distinct bubbles in the current layer, working from either end. Saved patterns stay the same when you relaunch.

When the HUD reads **F Pulse chain**, fly within pulse range and tap **F**. A hit on any bubble in the matching chain starts a bell melody from its nearer end. Each note sends a burst of iridescent colour and sparks from its bubble, and light runs along the link to the next one. The final note makes a bigger burst as the passage opens and its rim glows in the next layer's monochrome colour. The bursts fade back to the bubbles' mission colours.

### Connecting bubbles

With **String** selected, aim until the reticule turns mint and fire at a bubble. A gold anchor marks the hit. Fire at a second bubble to join the two. You can link free-floating bubbles, region shells and individual system bubbles when they are large enough to aim at. The strands lift away from small, luminous joins in the film and bow in the current. The joins follow the flex of the membranes as the bubbles move. Completed links are saved across relaunches.

Press **T** for **Disconnect**, aim at the string until it highlights in coral, then fire to cut it.

### Boarding with the harpoon

Press **Z** in the chase view, aim at a smaller bubble and fire. A bright blue reticule shows a surface you can board. The cockpit opens just inside the skin at the impact side. A region shell opens into the region's cluster of system bubbles. To board one of those individual systems directly, fly inside the region shell in the chase view and aim at its skin. That cockpit contains the system's star and up to nine planets.

The harpoon stops at the first skin it hits. The current enclosing skin and outward layers cannot be boarded. Press **G** to return to the position where you fired.

### Xalaria regions

Each of the 82 occupied Xalaria map regions has its own outer bubble. Inside are individual bubbles for every system in that region. Across the six layers there are 7,714 system bubbles, each with its own star and up to nine planets from the bundled catalogue. They retain their catalogue positions on the region grid, staggered in depth. Fly close to see their iridescent rims and planets in orbit. The region assignment sweeps back and forth across the rows of the Xalaria map, from the largest bubble scale to the smallest.

| Bubble scale | Layer | Region bubbles |
| --- | --- | ---: |
| Largest | Lantern Basin | 14 |
| 2 | Amber Garden | 14 |
| 3 | Cobalt Gloam | 14 |
| 4 | Viridian Fold | 14 |
| 5 | Carmine Deep | 13 |
| 6 (smallest) | The Whirlpool | 13 |

Press **R** to see the distribution. Click an occupied cell to mark its bubble. In flight, the gold guide follows a marked region in the active layer. The usual opening guide returns when you clear the mark.

Press **X** in flight to inspect a nearby region, or select any region in the atlas and press **X**. The ship holds its position while you inspect. Click a system on the region grid or use **← / →** to browse the systems. The large bubble shows its star and planets in motion, with orbital paths, the system name and its catalogue ID. Press **X** to go back or **R** to return to the atlas.

### Following the current

In Lantern Basin, the amber giant compresses and sends a wave into the basin. Let the crest pass and ride the water it draws back towards the membrane. The Amber Garden lifts you, the Cobalt Gloam carries you sideways, and the shoals in the Viridian Fold bend the flow around them. The water rolls down through the Carmine Deep and settles around the eye.

A vertical shaft rises from the final whirlpool. Hold your position in its eye for two seconds to kindle a solar system and watch a new bubble expand into the largest sphere. Three compressions throw off luminous wakes and clouds of plankton. A current carries you back through the membrane to Lantern Basin, where the system you kindled becomes the next cycle's sky. You can also fly back through the openings or turn away from the first membrane to explore the Narrows. Press **D** to follow the current hands-free.

Some spheres relay a quick pulse to their neighbours. Others answer with a slower ripple. A held call draws a nearby crown sphere across your path and alongside for a while. Its reply sounds from the side where it is swimming. Small bubbles rise and fade in the wakes of the surrounding spheres.

The ship banks into turns as the camera trails behind it. The camera pulls back gently at speed, and the twin exhausts brighten and lengthen under thrust. Hold **B** to cancel thrust and slow to the speed of the local current.

## Music

The embedded score shifts its tuning and colour as you cross between the nested and open waters. The current changes its texture, a quick pulse rings a bell, a held call produces a lower gliding tone, and shoal replies echo across the stereo field.

The ocean responds to three frequency bands in the engine’s stereo output, using the approach developed for Crimson Mirror / Prism Currents. Bass swells the water ribbons, mids bend them, treble brings out fine detail in the spheres and wakes, and attacks send brief glints along the current. **Music → Music-Reactive Ocean** toggles the visual response.

## Building

The simulation and host adapter use C++20. The macOS shell uses Objective-C++, AppKit, MetalKit and AVFoundation. The Metal shaders compile on launch. The project includes the source of SuperCollider App Engine 0.2.0 and its matching arm64 runtime. The engine compiles the SynthDefs in `audio/` with the embedded language library, creates one private SuperCollider World in the game process, and fills the host's stereo output callback through its C API.

Engine provenance, runtime build details and licenses are in [vendor/sc-app-engine/README.md](vendor/sc-app-engine/README.md).

With CMake 3.24 or newer and Apple Command Line Tools installed:

```sh
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_DEPLOYMENT_TARGET=15.0
cmake --build build --parallel
codesign --force --sign - build/PelagicSpheres.app
open build/PelagicSpheres.app
```

## Orbital and visual sources

The bundled catalogue comes from the Infinity / Xalaria 0.68.0 checkout, based on the published [Xalaria Universe index](https://www.xalaria.com/universe/). The bubble world, survey and cockpit use the same region coordinates, system identities and orbit clock. In the cockpit, planets and moons use their physical radii, orbital distances and periods. Regional space uses Infinity's interstellar grid spacing. The cockpit shows distant contacts in AU or light-years. The bubble world and survey show these systems as miniatures. The catalogue keeps stellar radii and temperatures, plus the names, surface parameters and ring tilts of up to nine primary planets per system. The four survey stars use their native stellar radii, temperatures and photosphere parameters. Ziksa's five moons are visible through its film and from its cockpit.

The cockpit uses the Xalaria 70° seated projection, four physical instrument surfaces and the Infinity flight HUD grid. Its Inter distance-field atlas is used by both the dashboard and the HUD. Flight readouts use Pelagic's live ship and catalogue state, including the occupied systems shown on the region map. The font licence is bundled in `licenses/Inter-OFL.txt`.

Planet and moon appearance comes from the v0.68.0 generator's `planetTraits`, `geologySample` and `terrainMaterial` functions. The cockpit streams Xalaria's adaptive terrain tiles around the flight reference or a nearby surface. It uses the original metre-scale triplanar texture, mesoscopic strata, water normals, weather wetting, terrain shadows and Acid Etch material scale. Orbital wisps use the original atmospheric thresholds. Up close, a depth-composited volumetric shell uses time-interpolated weather fields for cloud banks and their shadows.

`tools/export_xalaria_worlds.cpp` produces the traits table from a build of the original generator. Run `tools/derive_catalog.py catalog.tsv world-traits.tsv data/orbits.txt src/ZiksaAppearance.hpp` to join it to the catalogue and regenerate the five Ziksa moon profiles alongside the planets. The companion terrain and weather exporters prepare the seeded geology and climate tables bundled in `data/`.

The Metal renderer ports the Hyperion regional skies and starfield, stellar photospheres, prominences, gas-giant clouds and ring density from version 0.68.0. The exterior stays in HDR through Charred Glass refraction, depth-based Verdant Fog, ring compositing, atmospheric scattering and a 48-tap aperture gather. The regional film curve, halation and stellar flare run before the cabin and HUD. Charred Glass, Verdant Fog, Tidal Blue and Acid Etch follow the original Xalaria region assignments and share its galaxy seed. The cockpit geometry and Patrol hull were exported from that checkout. The export and catalogue scripts are in `tools/`. Pelagic's currents, membrane geometry and score are generated at runtime.
