#pragma once

#include "MissionSessionTypes.hpp"

namespace pelagic::missions {

class NativeRuntime;

struct MissionPassage {
    RoutePoint entrance;
    RoutePoint exit;
    double radius{};
    unsigned remaining{};
};

struct MissionArrival {
    Frame frame;
    Position eye{}, velocity{};
    Orientation orientation{};
};

std::optional<MissionPassage> missionPassage(NativeRuntime&, std::uint32_t current, std::uint32_t destination);
std::optional<MissionArrival> crossMissionPassage(const MissionPassage&, Position before,
                                                  const PlayerLocation& current, double hullRadius);

} // namespace pelagic::missions
