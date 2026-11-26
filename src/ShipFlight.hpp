#pragma once

#include "Sea.hpp"
#include "MissionSessionTypes.hpp"

#include <simd/simd.h>
#include <string_view>

namespace pelagic {

class XalariaTerrain;
namespace missions { struct DispatchWorld; }

constexpr std::size_t ziksaBodyCount = 13;

struct FlightBody {
    Quad position; // Bubble-local centre and solid radius.
    Quad colour;
    Quad surface;  // Gas, cloud, ring inner radius, ring outer radius.
    Quad axis;     // Ring normal and rotation phase.
    WorldAppearance appearance;
};

struct FlightScene {
    Quad eye, right, up, forward;
    Quad ship, shipRight, shipUp, shipForward;
    Quad cabinRight, cabinUp, cabinForward;
    Quad water, accent;
    Quad screen;  // Aspect, time, engine strength, boundary load.
    Quad navigation; // Radar target, speed, orbital body count and region system count.
    Quad cabinOffset, controls;
    Quad optics; // Regional look, stellar wind, cabin illumination and stellar angular radius.
    Quad drive; // Metres per render unit, warp field, stellar spin frequency and galaxy phase.
    Quad stellar; // Family, convection scale, spot strength and seed phase.
    Quad stellarImage; // Projected centre, vertical angular scale and image visibility.
    Quad atmosphere; // Body index, relative scale height, optical strength and radius in km.
    Quad cloudShell; // Base and top in body radii, pressure, optical blend.
    Quad cloudOptics; // Weather atlas interpolation, seed phase, moisture and lightning.
    Quad cloudMotion; // Physical cloud drift and deck thickness in km.
    Quad cloudProjection; // Body index, cloud render-target texel size and radius in km.
    std::array<float,16> cloudDeckPhases{}; // Inherited Hyperion phase for orbital decks.
    Quad terrainView; // Local frame, resident terrain body, and padding.
    Quad terrainEye, terrainEyeResidual; // Body-local eye in metres, split into high and low parts.
    std::array<FlightBody,ziksaBodyCount> bodies;
};

struct Helm {
    double strafe{}, lift{}, thrust{}, pitch{}, yaw{}, roll{};
    double mouseX{}, mouseY{};
    bool boost{}, precise{}, brake{}, lookAround{}, level{};
};

class ShipFlight {
public:
    ShipFlight();
    ShipFlight(const SystemBubble& system, unsigned id, double time, Vec entry, const System* record = nullptr);
    ShipFlight(const Ocean& ocean, const Region& region, double time, Vec entry);
    void enterAtFilm(Vec entry);
    void holdEntryHeading(Vec heading);
    void approachHomeWorld();
    void step(double seconds, const Helm& helm, bool atHelm);
    void syncOrbits(double time);
    void setTerrain(const XalariaTerrain* terrain) { terrain_ = terrain; }
    void toggleAssist() { assist_ = !assist_; }
    bool assisted() const { return assist_; }
    FlightScene scene(float aspect, Quad water = {}, Quad accent = {}) const;
    FlightScene overviewScene(float aspect) const;
    void setUnderAttack(bool active);
    void setMissionHull(double percent);
    double missionHull() const { return missionHull_; }
    void setMissionFuel(double units);
    void engageWarp();
    void cancelWarp();
    bool warpAvailable() const { return !region_ && !underAttack_ && missionFuel_>.001; }
    bool warping() const { return warp_; }
    std::string_view warpStatus() const;
    double warpEta() const;
    Quad contactPosition(unsigned index) const;
    double contactRange(unsigned index) const;
    void nextTarget();
    std::string targetName() const;
    std::optional<unsigned> regionTargetSystem() const {
        return region_ && target_<regionIds_.size() ? std::optional{regionIds_[target_]} : std::nullopt;
    }
    bool selectRegionTarget(unsigned system);
    std::string bodyName(unsigned i) const;
    float hudVisibility() const;
    unsigned regionCell() const;
    const std::string& locationName() const { return location_; }
    const Region* region() const { return region_; }
    void setBubbleTint(Quad tint) { bubbleTint_ = tint; }
    std::optional<Quad> bubbleTint() const { return bubbleTint_; }
    unsigned systemId() const { return system_ ? unsigned(system_->catalogue.x) : ziksaSystemId; }
    double systemTime() const { return time_; }
    double targetRange() const;
    double speed() const;
    double stoppingDistance() const;
    bool nearFilm() const;
    void bindMissionWorlds(std::span<const missions::DispatchWorld> worlds);
    bool exposeMissionWorld(uint64_t world, std::span<const missions::DispatchWorld> worlds);
    bool selectMissionWorld(std::optional<uint64_t> world);
    std::optional<uint64_t> targetMissionWorld() const;
    missions::PlayerLocation missionLocation(std::optional<missions::Frame> reference = {}) const;
    std::optional<Quad> missionRenderPoint(missions::Frame frame, missions::Position position,
                                            double physicalRadius = 0.) const;
    bool beginMissionApproach(const missions::RoutePoint&, missions::ActionKind = missions::ActionKind::Approach);
    bool refreshMissionApproach(const missions::RoutePoint&);
    bool setMissionAboard(bool aboard);
    bool leaveMissionDock();
    void cancelMissionApproach();
    bool enterMissionPose(const missions::Frame&, missions::Position eye,
                          missions::Orientation orientation, missions::Position velocity);
    bool restoreMissionDock(const missions::RoutePoint&, bool aboard);
    bool restoreMissionLanding(const missions::PlayerLocation&);
    const missions::RoutePoint* missionApproachPoint() const {
        return missionApproach_ ? &missionApproach_->point : nullptr;
    }

private:
    std::optional<Quad> bubbleTint_;
    struct PhysicalOrbit {
        double radius{}, distance{}, rate{}, phase{}, inclination{}, heading{};
        int parent{-1};
    };
    struct Contact {
        simd_double3 centre;
        double radius;
    };
    enum class MissionDockPhase { Arrival, Align, Glide, Capture, Clamped, Departure };
    struct MissionApproach {
        missions::RoutePoint point;
        missions::ActionKind kind;
        MissionDockPhase phase{MissionDockPhase::Arrival};
        double sampleTime{}, captureSeconds{};
        simd_double3 surfaceOffset{};
        std::optional<simd_double3> bypass;
        bool checkedApproach{}, aboard{};
    };
    void updateOrbits();
    void setFlightScale();
    void integrate(double dt, const Helm& helm);
    void integrateWarp(double dt);
    void startWarp();
    void arriveFromWarp(simd_double3 centre);
    void aimAt(simd_double3 target);
    Contact contact(unsigned index) const;
    Contact surfaceContact(unsigned index) const;
    Contact surfaceContact(unsigned index, simd_double3 point) const;
    static Quad physicalSurface(float gas, float clouds, double radius, const WorldAppearance&,
                                bool legacyRings = false);
    double warpGap() const;
    double operatingClearance() const;
    double warpStandOff() const;
    simd_double3 warpCentre() const;
    std::optional<unsigned> missionBody(std::optional<uint64_t> world) const;
    std::optional<uint64_t> missionOrbit() const;
    simd_double3 orbitVector(unsigned body, bool velocity) const;
    simd_double3 relativeVelocity(unsigned body) const;
    simd_double3 missionCoursePosition() const;
    simd_double3 missionSurfacePoint(unsigned body, simd_double3 direction) const;
    bool clearMissionLeg(simd_double3 destination) const;
    simd_double3 missionLandingVelocity(double dt, simd_double3 surface);
    void integrateMission(double dt);

    std::array<FlightBody,ziksaBodyCount> bodies_{};
    std::array<PhysicalOrbit,ziksaBodyCount> orbits_{};
    std::array<simd_double3,ziksaBodyCount> centres_{};
    Quad stellar_{}, stellarLight_{};
    double stellarSpin_{}, stellarMass_{};
    float stellarWind_{};
    std::optional<SystemBubble> system_;
    const Region* region_{};
    const XalariaTerrain* terrain_{};
    std::span<const SystemBubble> regionSystems_;
    std::span<const unsigned> regionIds_;
    std::array<std::string,ziksaBodyCount> bodyNames_;
    std::array<std::optional<uint64_t>,ziksaBodyCount> missionWorldIds_;
    std::string location_{"Ziksa"};
    simd_double3 position_{}, velocity_{}, spin_{}, thrusters_{}, rcs_{};
    simd_double3 headShift_{}, headLean_{}, leanVelocity_{}, shiftVelocity_{};
    simd_quatd attitude_{};
    double time_{}, lookYaw_{}, lookPitch_{}, boundaryLoad_{}, engine_{}, throttle_{}, boost_{};
    double metresPerUnit_{}, flightLimit_{}, stellarGravity_{};
    double warpTime_{}, warpVisual_{}, warpNotice_{};
    double missionHull_{100.}, missionFuel_{80.};
    std::optional<std::size_t> localFrame_;
    std::optional<simd_double3> warpWaypoint_;
    std::optional<MissionApproach> missionApproach_;
    bool warp_{}, warpBlocked_{}, underAttack_{};
    XalariaLook look_{xalariaLook(36)}; // Ziksa's catalogue region.
    bool assist_{true};
    std::size_t bodyCount_{ziksaBodyCount};
    std::size_t target_{3};
};

struct CabinVertex {
    float x, y, z;
    std::uint32_t color;
    float nx, ny, nz;
};
struct XalariaMeshes {
    std::vector<CabinVertex> cabin, hatch, deck, yoke, throttle, glazing, ship;
};
XalariaMeshes readXalariaMeshes(const std::filesystem::path& path);

} // namespace pelagic
