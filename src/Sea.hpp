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
};
struct Scene {
    Quad screen;    // Aspect, time, pulse age, migration
    Quad eye, right, up, forward;
    Quad deep, water, bright, contrast;
    Quad sun, sunlight, tide;
    std::array<Planet, 3> planets;
    Quad player;
    Quad call;      // Charge, held call, wave speed, music-driven phase
    Quad music;     // Low, middle, high and transient envelopes
    Quad habitat;   // Opening route, narrows, basin, local current strength
    Quad eclipse;   // Bell centre and radius of the overhead giant
};
struct Jelly {
    Quad position;  // World centre and size
    Quad pigment;   // Hue seed, phase, response, species
    Quad flow;      // Sway, yaw, player marker, variation
    Quad trail;     // Relative water velocity and shared rhythm
    float presence{};
    float eclipsing{}, basinLight{}, basinTone{-1.f};
};
struct Tracer { Quad head, tail; float wake{}, current{}; };
constexpr std::size_t planktonCount = 1000;
struct FlowNode {
    Quad point;     // World centre and half-width
    Quad light;     // Downstream coordinate, water type, speed (bank side for banks), presence
};
constexpr std::size_t giantCount = 4;
constexpr std::size_t jellyfishCount = 58;
constexpr std::size_t linesPerStream = 7, linesPerEddy = 6;
constexpr std::size_t streamLines = 2*linesPerStream, eddyLines = 4*linesPerEddy, wakeLines = giantCount*3;
constexpr std::size_t flowLines = streamLines+eddyLines+wakeLines, flowNodes = 40;
constexpr std::size_t guideLines = linesPerStream, sheetLines = 3, bankLines = 4;
constexpr std::size_t routeLines = flowLines+guideLines+sheetLines+bankLines;
constexpr std::size_t sheetColumns = 9;
struct TrailPose { Jelly jelly; Quad time; };
constexpr std::size_t trailActors = jellyfishCount+1, trailSamples = 72;
constexpr std::size_t trailLines = trailActors+giantCount+2+2;
constexpr float trailLifetime = 6.3f;

enum class WaterKind { Open, Stream, Eddy, Still, Wake };
struct Water { Vec drift; WaterKind kind; float stream, eddy, wake; };
enum class Call { Pulse, Draw };
enum class Encounter { None, Calling, Approaching, Alongside };
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

class Ocean {
public:
    explicit Ocean(const std::filesystem::path& catalogue);
    void step(float dt, Vec swim, float panX, float panY);
    bool pulse(Call type = Call::Pulse);
    bool beginCall();
    bool releaseCall();
    void cancelCall() { callStart = -1.f; }
    float callCharge() const;
    void voyage(unsigned destination);
    void next();
    void uncharted();
    Scene scene(float aspect) const;
    std::vector<Jelly> shoal(float aspect = 1.6f) const;
    std::span<const Jelly> shoal(const Scene& view, std::span<Jelly,trailActors> storage) const;
    Water waterAt(Vec p, bool withWake = true, std::size_t ignoreGiant = giantCount) const;
    WaterKind localWater() const { return waterAt(player).kind; }
    const char* habitatName() const;
    bool openingRoute() const { return active == 0; }
    float basinAmount() const;
    Vec position() const { return player; }
    Encounter encounter() const { return meeting; }
    bool crownInRange() const;
    std::span<const Reply> takeReplies();
    const auto& tracers() const { return planktonView; }
    const auto& ribbons() const { return flowView; }
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
    unsigned featured() const { return active < currents.size() ? active : 8; }
    unsigned look() const { return palette; }
    float age() const { return clock; }
    float eventStrength() const { return note; }
    bool migrating() const { return transition >= 0; }
    bool paused{};
    bool demo{};

private:
    struct Animal {
        Vec p, velocity, slip;
        Vec home;
        unsigned seed{};
        float size{}, phase{}, hue{}, heading{};
        unsigned kind{}, cohort{}, answered{}, relay{};
        float response{-30.f}, due{-1.f};
        float joinedUntil{-1.f}, synchrony{};
        bool meeting{};
    };
    struct Plankter {
        Vec p, tail;
        unsigned seed{};
        float age{}, lifetime{}, width{};
    };
    struct WakeFlow {
        Vec axis, side;
        float presence{}, thrust{};
    };
    std::vector<System> systems;
    std::array<Animal, jellyfishCount> animals{};
    std::array<WakeFlow,giantCount> wakeFlow{};
    std::array<Plankter, planktonCount> plankton{};
    std::array<Tracer, planktonCount> planktonView{};
    std::array<FlowNode, routeLines*flowNodes> flowView{};
    std::array<TrailPose, trailActors*trailSamples> trailHistory{};
    std::vector<std::uint8_t> visited;
    std::array<Reply,jellyfishCount> replies{};
    std::size_t replyCount{};
    Vec player{}, velocity{}, eye{}, pulseOrigin{}, tailSlip{};
    double physicsRemainder{};
    float clock{}, yaw{}, pitch{}, lookYaw{}, lookPitch{}, bodyYaw{}, nextFlow{};
    float lastPulse{-20.f}, transition{-1.f}, demoSoon{11.f};
    float note{}, accent{}, callStart{-1.f};
    unsigned active{}, target{}, palette{}, index{}, answers{}, generation{}, callNumber{};
    unsigned companions{}, synchronised{};
    unsigned nextTrailSlot{}, trailCount{}, trailTicks{};
    std::size_t crownGuest{jellyfishCount};
    float encounterUntil{}, alongsideSince{}, guestSide{};
    Encounter meeting{Encounter::None};
    bool demoCalled{};
    Call lastCall{Call::Pulse};
    void arrive(unsigned destination);
    void population();
    void updateWake(std::size_t index);
    void plantPlankter(std::size_t slot, bool arriving);
    void advancePlankton(float dt);
    void advanceShoal(float dt);
    void answerCalls();
    void integrate(float dt, Vec swim);
    void buildRibbons();
    void buildBanks();
    Vec eclipseWash(Vec point) const;
    void driftOpening(float dt, Vec& swim);
    std::size_t nearestCrown() const;
    Jelly bodyView() const;
    Jelly animalView(const Animal& jelly) const;
    void recordTrails();
};

} // namespace pelagic
