#pragma once

#include "MissionPresentation.hpp"
#include "MissionSessionTypes.hpp"
#include "Sea.hpp"

#include <string_view>

namespace pelagic::missions {

class NativeRuntime;

struct DispatchWorld {
    std::uint64_t id{};
    std::optional<std::uint64_t> primary;
    std::string name;
    double radius{}, distance{}, period{}, tilt{}, tiltRotation{}, temperature{}, clouds{};
    bool gas{};
    WorldAppearance appearance;
};

struct DispatchObjective {
    Frame frame;
    std::string headline, task, destination;
    std::optional<RoutePoint> search;
    std::optional<Place> port;
    std::optional<Actor> vessel;
};

class MissionDispatch {
public:
    explicit MissionDispatch(NativeRuntime&);
    void open(std::optional<std::uint32_t> atlasSystem = std::nullopt,
              std::optional<Actor> radioContact = std::nullopt);
    void close();
    bool isOpen() const;
    void refresh();

    static bool handles(missionui::Page);
    missionui::Snapshot snapshot() const;
    Action dispatch(missionui::Action);
    bool scan();
    bool hear(Actor);
    std::string takeNotice();
    std::optional<DispatchObjective> objective() const;
    std::vector<Contact> evidence(Frame) const;
    std::optional<Contact> distress() const;

    std::string systemName(std::uint32_t) const;
    std::vector<DispatchWorld> worlds(std::uint32_t) const;

private:
    Action route();
    bool scanEvidence();
    bool resolve(unsigned choice);

    NativeRuntime& runtime_;
    std::string notice_;
};

} // namespace pelagic::missions
