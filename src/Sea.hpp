#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
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
};
enum class GraphicsStyle : std::uint32_t { Original, Hybrid, Painted, Ultra };
constexpr std::size_t bellPassageCount = 5;
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
    Quad enclosingShape; // Bell width, dome height, underside depth, exterior visibility
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
};
struct Jelly {
    Quad position;  // World centre and size
    Quad pigment;   // Hue seed, phase, response, species
    Quad flow;      // Sway, yaw, player marker, variation
    Quad trail;     // Relative water velocity and shared rhythm or player stroke effort
    float presence{};
    float eclipsing{}, basinLight{}, basinTone{-1.f};
    float pitch{};  // Forward tilt in radians
    float membraneAnchor{}; // One-based passage whose entrance anchors this bell.
    float bellSystem{}; // One-based index into the orbital records. Zero denotes the analytic outer bell mesh.
    float bellSystemVisibility{1.f};
};
struct Tracer { Quad head, tail; float wake{}, current{}; };
constexpr std::size_t planktonCount = 1000;
struct FlowNode {
    Quad point;     // World centre and half-width
    Quad light;     // Downstream coordinate, water type, speed (bank side for banks), presence
};
constexpr std::size_t giantCount = 4;
constexpr std::size_t jellyfishCount = 58;
constexpr std::size_t bellSystemCount = jellyfishCount+2; // Shoal, swimmer and enclosing bell.
constexpr std::size_t linesPerStream = 7, linesPerEddy = 6;
constexpr std::size_t streamLines = 2*linesPerStream, eddyLines = 4*linesPerEddy, wakeLines = giantCount*3;
constexpr std::size_t flowLines = streamLines+eddyLines+wakeLines, flowNodes = 40;
constexpr std::size_t guideLines = linesPerStream, sheetLines = 3;
constexpr std::size_t routeLines = flowLines+guideLines+sheetLines;
constexpr std::size_t sheetColumns = 9;
struct TrailPose { Jelly jelly; Quad time; };
constexpr std::size_t trailActors = jellyfishCount+1, trailSamples = 72;
constexpr std::size_t trailLines = trailActors+giantCount+2+2;
constexpr float trailLifetime = 6.3f;

enum class WaterKind { Open, Stream, Eddy, Still, Wake };
struct Water { Vec drift; WaterKind kind; float stream, eddy, wake; };
enum class Call { Pulse, Draw };
enum class Encounter { None, Calling, Approaching, Alongside };
enum class VoyageSound { None, OpeningStroke, SystemBirth, SystemReturn };
struct VoyageCue { VoyageSound sound{}; unsigned system{}; };
struct Reply { Vec position; bool crown; unsigned sequence; };

struct Orbit {
    float radius{}, distance{}, period{}, heat{};
    int material{};
    float clouds{}, rings{}, tilt{};
};
struct System {
    unsigned id{};
    float radius{}, temperature{};
    unsigned count{};
    std::array<Orbit, 3> orbits{};
};
struct Current {
    const char* title;
    const char* water;
    unsigned id;
    unsigned palette;
};
extern const std::array<Current, 8> currents;

enum class OceanStart { OpenWater, ColossalBell };

class Ocean {
public:
    explicit Ocean(const std::filesystem::path& catalogue, unsigned initial = 0,
                   OceanStart start = OceanStart::OpenWater);
    void step(float dt, Vec swim, float panX, float panY, bool brake = false);
    bool pulse(Call type = Call::Pulse);
    bool beginCall();
    bool releaseCall();
    void cancelCall() { callStart = -1.f; }
    float callCharge() const;
    void voyage(unsigned destination);
    void next();
    void uncharted();
    Scene scene(float aspect, bool exteriorView = false) const;
    void writeBellSystems(std::span<BellSystem,bellSystemCount> output, std::uint64_t visible = UINT64_MAX) const;
    std::vector<Jelly> shoal(float aspect = 1.6f) const;
    std::span<const Jelly> shoal(const Scene& view, std::span<Jelly,trailActors> storage) const;
    Water waterAt(Vec p, bool withWake = true, std::size_t ignoreGiant = giantCount) const;
    WaterKind localWater() const { return waterAt(player).kind; }
    const char* habitatName() const;
    bool openingRoute() const { return hasOpeningRoute; }
    float basinAmount() const;
    Vec position() const { return player; }
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
    void captureTrailRow(TrailPose* row) const;
    std::string title() const;
    const char* waterName() const;
    unsigned systemCount() const { return static_cast<unsigned>(systems.size()); }
    unsigned visitedCount() const;
    unsigned echoes() const { return answers; }
    unsigned calls() const { return callNumber; }
    unsigned accompanying() const { return companions; }
    unsigned inStep() const { return synchronised; }
    bool drawnCall() const { return lastCall == Call::Draw; }
    unsigned featured() const { return current.number < currents.size() ? current.number : currents.size(); }
    unsigned look() const;
    bool choosingCurrent() const { return manualMorph; }
    float age() const { return clock; }
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
    std::array<unsigned,bellSystemCount> bellCatalogues{};
    std::array<Animal, jellyfishCount> animals{};
    std::array<WakeFlow,giantCount> wakeFlow{};
    std::array<Vec,2> viridianShoals{};
    std::array<Plankter, planktonCount> plankton{};
    std::array<Tracer, planktonCount> planktonView{};
    std::array<FlowNode, routeLines*flowNodes> flowView{};
    std::array<TrailPose, trailActors*trailSamples> trailHistory{};
    std::vector<std::uint8_t> visited;
    std::array<Reply,jellyfishCount> replies{};
    std::size_t replyCount{};
    Vec player{}, velocity{}, eye{}, pulseOrigin{}, tailSlip{};
    double physicsRemainder{}, orbitalEpoch{};
    float clock{}, yaw{}, pitch{}, lookYaw{}, lookPitch{}, bodyYaw{}, nextFlow{};
    float swimPhase{}, strokeEffort{}, bodyBank{}, bodyPitch{};
    float depthBlend{}, skyDepthBlend{};
    unsigned depth{};
    float playerSystemBirth{-1.f};
    float openingStroke{-1.f};
    Quad openingWave{};
    VoyageCue voyageCue{};
    bool inheritedSky{};
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
    std::size_t crownGuest{jellyfishCount};
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
    void updateWake(std::size_t index);
    void updateViridianShoals();
    Vec viridianWash(Vec point) const;
    void updateOpeningStroke();
    void plantPlankter(std::size_t slot, bool arriving);
    void advancePlankton(float dt);
    void advanceShoal(float dt);
    void answerCalls();
    void integrate(float dt, Vec swim, bool brake);
    void buildRibbons();
    Vec eclipseWash(Vec point) const;
    Vec whirlpoolCentre() const;
    float systemEmergence() const;
    void restartCycle();
    void driftOpening(float dt, Vec& swim);
    void crossBell(Vec previous, float dt);
    std::size_t nearestCrown() const;
    Jelly bodyView() const;
    Jelly animalView(const Animal& jelly) const;
    void recordTrails();
};

} // namespace pelagic
