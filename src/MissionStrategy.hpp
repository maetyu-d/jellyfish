#pragma once

#include "MissionPresentation.hpp"
#include "MissionSessionTypes.hpp"

namespace pelagic::missions {

class NativeRuntime;

class MissionStrategy {
public:
    explicit MissionStrategy(NativeRuntime& runtime) : runtime_(runtime) {}

    missionui::Snapshot snapshot(missionui::Page page, std::optional<std::uint32_t> plottedSystem);
    Action dispatch(missionui::Page page, missionui::Action input, std::optional<std::uint32_t> plottedSystem);

    std::optional<Actor> target() const;
    std::optional<Actor> cycleTarget();
    void selectTarget(std::optional<Actor> actor);
    void toggleArmed();
    void selectWeapon(unsigned weapon);
    bool fire();
    bool underAttack() const;
    bool localScan();
    bool heard(const Actor& actor);

private:
    NativeRuntime& runtime_;
    std::size_t combatSheet_=0;
};

} // namespace pelagic::missions
