#pragma once

#include <array>
#include <bitset>
#include <compare>
#include <cstdint>
#include <filesystem>
#include <optional>
#include <span>
#include <string>
#include <vector>

namespace pelagic {

struct Vec {
    float x{}, y{}, z{};
    Vec operator+(Vec other) const;
    Vec operator-(Vec other) const;
    Vec operator*(float scalar) const;
    Vec& operator+=(Vec other);
};

struct alignas(16) Quad { float x{}, y{}, z{}, w{}; };
struct Planet {
    Quad position;  // Direction and angular radius
    Quad material;  // Type, clouds, ring angle and ring width
    Quad pigment;   // Linear RGB and rotation
    float ringOpacity{};
    float opacity{};
};
struct BellSystem {
    Quad sun, sunlight; // Sunlight's last component seeds the local stars.
    std::array<Planet,3> planets;
    std::array<Quad,3> skyPositions; // World-space bearings when swimming inside this bell.
    Quad region; // Linear palette tint and one-based Xalaria map cell.
};
enum class GraphicsStyle : std::uint32_t { Original, Hybrid, Painted, Ultra };
constexpr unsigned bubbleShell = UINT32_MAX;
enum class XalariaLook { CharredGlass, VerdantFog, TidalBlue, AcidEtch };
XalariaLook xalariaLook(unsigned regionCell);
constexpr std::size_t bellPassageCount = 5;
constexpr std::size_t regionScales = bellPassageCount+1;
constexpr unsigned allPassages = (1u<<bellPassageCount)-1u;
constexpr unsigned openingSignalSystemId = 7084;
constexpr std::array<Quad,regionScales> layerMonochrome{{
    {27.f/255.f,54.f/255.f,68.f/255.f},    // Midnight Slate, outermost
    {244.f/255.f,178.f/255.f,27.f/255.f},  // Sulphur Gold
    {31.f/255.f,78.f/255.f,206.f/255.f},   // Electric Cobalt
    {143.f/255.f,210.f/255.f,23.f/255.f},  // Acid Lime
    {82.f/255.f,43.f/255.f,145.f/255.f},   // Scorched Violet
    {220.f/255.f,20.f/255.f,60.f/255.f},   // Crimson, centre
}};
constexpr unsigned regionGrid = 10, regionSide = 20;
constexpr unsigned regionCells = regionGrid*regionGrid, regionArea = regionSide*regionSide;
constexpr unsigned systemCells = regionCells*regionArea;
constexpr unsigned ziksaSystemId = 14538;
constexpr float bubbleColourFade = 2.5f;
enum class BubbleKind { System, Region };
struct BubbleId {
    BubbleKind kind;
    unsigned id;
    auto operator<=>(const BubbleId&) const = default;
};
constexpr unsigned regionOfSystem(unsigned id) {
    const unsigned side = regionGrid*regionSide;
    return (id/side/regionSide)*regionGrid+id%side/regionSide;
}
using RegionStars = std::array<std::uint8_t,regionCells*regionArea>;
struct Region {
    unsigned cell{}, scale{}, systems{}, firstSystem{};
};
constexpr unsigned systemPlanetLimit = 9;
// Generated binding of Xalaria PlanetTraits and TerrainMaterial in shader order.
struct WorldAppearance {
    Quad dark;     // Low albedo and immutable planet seed phase.
    Quad light;    // High albedo and Xalaria PlanetType plus one.
    Quad features; // Solid terrain, sediment, water, ice or giant jets, contrast, haze, ring ice.
    Quad annulus;  // Inner/outer radii in body radii, optical depth, ring phase.
    Quad pole;     // Original rotation axis and pressure in bar.
};
struct SystemBubble {
    Quad position; // Centre and radius in the enclosing region's unit sphere.
    Quad star;     // Colour and radius in units of this bubble's radius.
    std::array<Quad,systemPlanetLimit> orbits;  // Distance, initial phase, speed and planet radius.
    std::array<Quad,systemPlanetLimit> colours; // Planet colour and ring opacity.
    std::array<Quad,systemPlanetLimit> materials; // Gas, clouds, ring tilt and ring node.
    Quad catalogue; // System ID, regional look, primary planet count and stellar temperature.
    std::array<WorldAppearance,systemPlanetLimit> appearances;
};
struct Scene {
    Quad screen;    // Aspect, time, pulse age, Noctiluca lighting
    Quad eye, right, up, forward;
    Quad deep, water, bright, contrast;
    Quad sun, sunlight, tide;
    std::array<Planet, 3> planets;
    Quad player;
    Quad call;      // Charge, held call, wave speed, music-driven phase
    Quad music;     // Low, middle, high and transient envelopes
    Quad habitat;   // Opening route, narrows, basin, local current strength
    Quad eclipse;   // Bell centre and radius of the overhead giant
    Quad basinWave; // Crest position and strength of the opening giant's stroke
    Quad paletteMix{1.f,0.f,0.f,0.f};
    Quad innerOcean; // Blended depth, membrane light, exterior camera, player system emergence
    std::array<Quad,bellPassageCount> passages; // Bell openings in world space and their radii
    std::array<Quad,bellPassageCount> passageColours; // Bioluminescence of each bell and its entrance.
    Quad enclosingBell; // World centre and radius of the bell containing the starting ocean
    Quad enclosingShape; // Membrane radii along x, y and z, and exterior visibility.
    Quad whirlpool; // Centre of the final whirlpool and the radius of its eye
    Quad cycle; // Eye dwell, transformation, exterior transition and arrival progress
    Quad returnPassage; // Centre of the bell's inlet and the strength of its flow
    Quad passageFlow; // World-space current axis and its continuous time through the crossing
    Quad enclosedOrbits; // The system's centre and orbital distance, both in bell radii
    GraphicsStyle graphicsStyle{GraphicsStyle::Original};
    float enclosingSky{}; // Camera immersion across the membrane.
    float celestialTime{}; // Continuous orbital time across voyages and cycles.
    float skyDepth{}; // The slower celestial transition through each bell.
    float orbitalPixel{.0018f}; // Angular footprint independent of adaptive scene resolution.
    float whirlpoolApproach{}; // Proximity of the swimmer to the eye.
    float basinArrival{1.f}; // Strength of nearby water and life on the return to the swimmer.
    float playerSystem{}; // One-based slot for the orbit taking shape in the whirlpool.
    // Locked tint in RGB, progress towards full colour in w.
    Quad enclosingPalette, interiorPalette, birthPalette;
    Quad searchlightOrigin; // Nose position and range in world units. Zero range means off.
    Quad searchlightAxis;   // Forward direction and visibility.
    Quad heldBubbleCentre; // World centre and blend weight for the held membrane.
    Quad heldSystemCentre; // Fixed centre of the selected system within a held region.
    unsigned heldBubble{}, heldSystem{bubbleShell};
    unsigned lockedPassage{}; // One-based index of the current sealed inward passage.
    unsigned openPassage{}; // One-based index of the next traversable inward passage.
    Quad pulseAxis; // Ship heading when the player fired, and resonant pulse lifetime.
};
struct Bubble {
    Quad position;  // World centre and size
    Quad pigment;   // Hue seed, phase, response, species
    Quad flow;      // Sway, yaw, special shell (-1 Ziksa, +1 Whirlpool birth), variation
    Quad trail;     // Relative water velocity and compression
    float presence{};
    float eclipsing{}, basinLight{}, basinTone{-1.f};
    float pitch{};  // Forward tilt in radians
    float membraneAnchor{}; // One-based passage whose entrance anchors this bell.
    float bellSystem{}; // One-based index into the orbital records. Zero denotes the analytic outer bell mesh.
    float bellSystemVisibility{1.f};
    Quad palette{};
};
struct ShipPose {
    Quad position; // World centre and scale.
    Quad right, up, forward;
    Quad drive;    // Throttle and visibility.
};
struct FlightTelemetry {
    float speed; // Bubble World units per second.
    float heading, pitch, bank; // Degrees in the Bubble World frame.
    bool operator==(const FlightTelemetry&) const = default;
};
// RGB irradiance from the positive and negative directions of each world axis.
using HullLight = std::array<Quad,6>;
struct Tracer { Quad head, tail; float wake{}, current{}; };
constexpr std::size_t planktonCount = 1000;
struct FlowNode {
    Quad point;     // World centre and half-width
    Quad light;     // Downstream coordinate, water type, speed (bank side for banks), presence
};
constexpr std::size_t giantCount = 4;
constexpr std::size_t bubbleCount = 58;
constexpr std::size_t shoalCapacity = bubbleCount+2+regionCells;
constexpr std::size_t residentSystemCount = bubbleCount+2; // Shoal, Whirlpool birth and enclosing bell.
constexpr std::size_t bellSystemCount = residentSystemCount+regionCells;
using VisibleSystems = std::bitset<bellSystemCount>;
constexpr std::size_t linesPerStream = 7, linesPerEddy = 6;
constexpr std::size_t streamLines = 2*linesPerStream, eddyLines = 4*linesPerEddy, wakeLines = giantCount*3;
constexpr std::size_t flowLines = streamLines+eddyLines+wakeLines, flowNodes = 40;
constexpr std::size_t guideLines = linesPerStream, sheetLines = 3;
constexpr std::size_t routeLines = flowLines+guideLines+sheetLines;
constexpr std::size_t sheetColumns = 9;
struct TrailPose { Quad position, light, palette; };
constexpr std::size_t trailSamples = 72;

enum class WaterKind { Open, Stream, Eddy, Still, Wake };
struct Water { Vec drift; WaterKind kind; float stream, eddy, wake; };
enum class Call { Pulse, Draw, Resonance };
constexpr float pulseDuration = 3.4f;
enum class Encounter { None, Calling, Approaching, Alongside };
enum class VoyageSound { None, OpeningStroke, SystemBirth, SystemReturn };
struct VoyageCue { VoyageSound sound{}; unsigned system{}; };
struct Reply { Vec position; bool crown; unsigned sequence; };

struct Orbit {
    float radius{}, distance{}, period{}, heat{};
    int material{};
    float clouds{}, rings{}, tilt{}, node{};
    std::string name;
    WorldAppearance appearance{};
    double orbitalTilt{}, orbitalHeading{}, orbitalPhase{-1.};
};
struct System {
    unsigned id{};
    float radius{}, temperature{};
    unsigned count{};
    std::array<Orbit,systemPlanetLimit> orbits{}; // Up to three featured planets, then the additional bodies.
    std::string name;
};
SystemBubble systemModel(const System& system);
struct Current {
    const char* title;
    const char* water;
    unsigned id;
    unsigned palette;
};
extern const std::array<Current, 8> currents;

enum class OceanStart { OpenWater, ColossalBell, WhirlpoolApproach };
enum class ThrustMode { Normal, Boost, Precision };

class Ocean {
public:
    explicit Ocean(const std::filesystem::path& catalogue, unsigned initial = 0,
                   OceanStart start = OceanStart::OpenWater);
    void step(float dt, Vec thrust, float panX, float panY, bool brake = false,
              ThrustMode mode = ThrustMode::Normal, bool stationKeeping = false);
    void holdBubble(unsigned slot, unsigned system, Vec shellCentre, Vec centre);
    void releaseBubble();
    bool pulse(Call type = Call::Pulse);
    bool beginCall();
    bool releaseCall(Call tap = Call::Pulse);
    void cancelCall() { callStart = -1.f; }
    float callCharge() const;
    void voyage(unsigned destination);
    void next();
    void uncharted();
    Scene scene(float aspect, bool exteriorView = false) const;
    ShipPose shipPose(const Scene& view) const;
    Quad flightGuide(const Scene& view) const;
    void writeBellSystems(std::span<BellSystem,bellSystemCount> output,
                          VisibleSystems visible = VisibleSystems{}.set()) const;
    std::span<const Region> regions() const { return regionMap; }
    const RegionStars& regionStars() const { return starsByRegion; }
    std::span<const SystemBubble> systemBubbles() const { return nestedSystems; }
    std::span<const unsigned> systemBubbleIds() const { return nestedSystemIds; }
    const Region* regionAt(unsigned cell) const;
    const Region* selectedRegion() const { return regionAt(markedRegion); }
    const Region* nearbyRegion(const Scene& view, bool preferMarked = false) const;
    Quad regionTint(const Region& region) const;
    const Region* bubbleRegion(unsigned slot) const;
    const System* bubbleSystem(unsigned slot) const;
    const System& residentSystem(unsigned slot) const;
    const System* systemById(unsigned id) const;
    bool restoreBubbleColour(BubbleId bubble, bool animate);
    float bubbleColour(BubbleId bubble) const;
    bool bubbleColourRestored(BubbleId bubble) const;
    Quad bubblePalette(BubbleId bubble) const;
    Quad bubblePalette(BubbleId bubble, unsigned layer) const;
    std::span<const float> systemColourTimes() const { return {colourTimes.data(),systemCells}; }
    unsigned colourRevision() const { return paletteRevision; }
    void setUnlockedPassages(unsigned mask) { unlockedPassages=mask&allPassages; }
    unsigned unlockedPassageMask() const { return unlockedPassages; }
    bool passageLocked() const;
    bool bubbleEntryLocked(unsigned slot) const;
    bool canBoardBubble(unsigned slot) const;
    std::optional<unsigned> bubbleFlightLayer(unsigned slot) const;
    std::optional<Bubble> stringBubble(unsigned slot, const Scene& view) const;
    void markRegion(unsigned cell) { markedRegion = cell; }
    std::vector<Bubble> shoal(float aspect = 1.6f) const;
    std::span<const Bubble> shoal(const Scene& view, std::span<Bubble,shoalCapacity> storage,
                                 HullLight* hullLight = nullptr) const;
    Water waterAt(Vec p, bool withWake = true, std::size_t ignoreGiant = giantCount) const;
    WaterKind localWater() const { return waterAt(player).kind; }
    const char* habitatName() const;
    bool openingRoute() const { return hasOpeningRoute; }
    float basinAmount() const;
    Vec position() const { return player; }
    FlightTelemetry flightTelemetry() const;
    void holdShip();
    unsigned oceanDepth() const { return depth; }
    bool transforming() const { return transformationStart >= 0.f; }
    bool returning() const;
    float passageResonance() const;
    float transformationProgress() const;
    Encounter encounter() const { return meeting; }
    bool crownInRange() const;
    std::span<const Reply> takeReplies();
    VoyageCue takeVoyageCue();
    const auto& tracers() const { return planktonView; }
    const std::array<FlowNode,routeLines*flowNodes>& ribbons();
    const auto& trailPoses() const { return trailHistory; }
    unsigned trailHead() const { return nextTrailSlot; }
    unsigned trailsRecorded() const { return trailCount; }
    std::string title() const;
    const char* waterName() const;
    unsigned systemCount() const { return static_cast<unsigned>(systems.size()); }
    unsigned visitedCount() const;
    unsigned echoes() const { return answers; }
    unsigned calls() const { return callNumber; }
    unsigned accompanying() const { return companions; }
    unsigned inStep() const { return synchronised; }
    bool drawnCall() const { return lastCall == Call::Draw; }
    bool resonantCall() const { return lastCall == Call::Resonance; }
    unsigned featured() const { return current.number < currents.size() ? current.number : currents.size(); }
    unsigned look() const;
    bool choosingCurrent() const { return manualMorph; }
    float age() const { return clock; }
    double orbitalTime() const { return orbitalEpoch+double(clock); }
    void advanceOrbits(double seconds) { orbitalEpoch += seconds; }
    float eventStrength() const { return note; }
    bool paused{};
    bool demo{};

private:
    struct Animal {
        Vec p, velocity, slip;
        Vec home;
        unsigned seed{};
        float size{}, phase{}, hue{}, heading{};
        unsigned kind{}, cohort{}, realm{}, answered{}, relay{};
        float response{-30.f}, due{-1.f};
        float joinedUntil{-1.f}, synchrony{};
        bool meeting{};
    };
    struct Plankter {
        Vec p, tail, drift;
        unsigned seed{};
        float age{}, lifetime{}, width{};
    };
    struct WakeFlow {
        Vec axis, side;
        float presence{}, thrust{};
    };
    struct Destination {
        unsigned number{}, system{}, palette{};
    };
    struct Atmosphere {
        Quad deep, water, bright, contrast, sun, sunlight, paletteMix;
        std::array<Planet,3> planets{};
        float seed{}, noctiluca{};
    };
    std::vector<System> systems;
    struct RegionBubble {
        Vec home;
        float size{};
    };
    std::array<unsigned,residentSystemCount> bellCatalogues{};
    std::vector<Region> regionMap;
    std::vector<RegionBubble> regionBubbles;
    std::vector<SystemBubble> nestedSystems;
    std::vector<unsigned> nestedSystemIds;
    struct BubbleHold { unsigned slot, system; Vec shellCentre, centre; float releasedAt = -1.f; };
    std::optional<BubbleHold> bubbleHold;
    RegionStars starsByRegion{};
    std::array<float,systemCells+regionCells> colourTimes;
    unsigned paletteRevision{};
    unsigned markedRegion{regionCells};
    std::array<Animal, bubbleCount> animals{};
    std::array<WakeFlow,giantCount> wakeFlow{};
    std::array<Vec,2> viridianShoals{};
    std::array<Plankter, planktonCount> plankton{};
    std::array<Tracer, planktonCount> planktonView{};
    std::array<FlowNode, routeLines*flowNodes> flowView{};
    std::array<TrailPose, bubbleCount*trailSamples> trailHistory{};
    std::vector<std::uint8_t> visited;
    std::array<Reply,bubbleCount> replies{};
    std::size_t replyCount{};
    Vec player{}, velocity{}, eye{}, pulseOrigin{}, pulseDirection{};
    double physicsRemainder{}, orbitalEpoch{};
    float clock{}, yaw{}, pitch{}, lookYaw{}, lookPitch{}, nextFlow{};
    float chaseYaw{}, chasePitch{}, chasePullback{}, shipBank{}, engineLoad{}, engineBoost{};
    float depthBlend{}, skyDepthBlend{};
    unsigned depth{};
    unsigned unlockedPassages=allPassages;
    float playerSystemBirth{-1.f};
    float openingStroke{-1.f};
    Quad openingWave{};
    VoyageCue voyageCue{};
    bool inheritedSky{};
    bool launchHold{};
    float eyeEntered{-1.f}, transformationStart{-1.f}, returnFlight{};
    float lastPulse{-10.f}, demoSoon{11.f};
    float note{}, accent{}, callStart{-1.f};
    unsigned answers{}, generation{}, callNumber{};
    Destination current, incoming;
    Atmosphere manualSource;
    float morphStart{}, morphEnd{};
    unsigned morphCount{};
    bool manualMorph{}, hasOpeningRoute{};
    unsigned companions{}, synchronised{};
    unsigned nextTrailSlot{}, trailCount{}, trailTicks{};
    std::size_t crownGuest{bubbleCount};
    float encounterUntil{}, alongsideSince{}, guestSide{};
    Encounter meeting{Encounter::None};
    bool demoCalled{};
    Call lastCall{Call::Pulse};
    Destination destination(unsigned number) const;
    Ocean(std::vector<System> catalogue, unsigned initial, OceanStart start);
    unsigned unchartedDestination();
    void startAutomaticMorph();
    Atmosphere atmosphereAt(Destination location) const;
    Atmosphere atmosphere() const;
    void population(unsigned seed);
    void placeRegions();
    void updateWake(std::size_t index);
    void updateViridianShoals();
    Vec viridianWash(Vec point) const;
    void updateOpeningStroke();
    void plantPlankter(std::size_t slot, bool arriving);
    void advancePlankton(float dt);
    void advanceShoal(float dt);
    void answerCalls();
    void integrate(float dt, Vec thrust, bool brake, ThrustMode mode, bool stationKeeping);
    void steerPlayer(float dt, Vec swim, bool brake, ThrustMode mode);
    void buildRibbons();
    Vec eclipseWash(Vec point) const;
    Vec whirlpoolCentre() const;
    float systemEmergence() const;
    void restartCycle();
    void driftOpening(float dt, Vec& swim);
    void crossBell(Vec previous, float dt);
    std::size_t nearestCrown() const;
    Bubble birthBubble() const;
    Bubble ziksaBubble(const Scene& view) const;
    Bubble regionView(std::size_t index, const Scene& view) const;
    Bubble animalView(const Animal& jelly) const;
    void recordTrails();
};

} // namespace pelagic
