#pragma once

#include "MissionSessionTypes.hpp"
#include "infinity/Navigation.hpp"
#include "infinity/World.hpp"
#include "infinity/XalariaCombat.hpp"
#include "infinity/XalariaNavigation.hpp"
#include "infinity/XalariaStories.hpp"

#include <filesystem>
#include <memory>
#include <string_view>
#include <vector>

namespace pelagic::missions {

// Owns the original mission-bearing simulation. Pelagic supplies the current
// physical observation; dispatch, cargo, trade and combat all share these instances.
class NativeRuntime {
public:
    explicit NativeRuntime(const std::filesystem::path& catalogPath);

    std::shared_ptr<const infinity::XalariaCatalog> catalog;
    infinity::Universe universe;
    infinity::Navigation nav;
    infinity::RegionCache cache;
    infinity::FlightController controller;
    infinity::Pilot pilot;
    infinity::XalariaEconomy economy;
    infinity::XalariaNavigation course;
    infinity::XalariaCombat combat;
    infinity::XalariaStories stories;

    double seconds() const noexcept { return seconds_; }
    const PlayerLocation& location() const noexcept { return location_; }
    void synchronize(const PlayerLocation&);
    void advance(const PlayerLocation&,double seconds);
    infinity::StoryContext storyContext() const;
    infinity::CombatPlayer combatPlayer() const;
    FlightStatus status() const;
    bool fire();
    bool hearStory(const infinity::XalariaTrafficContact&);
    std::optional<infinity::StoryKey> heardStory(const Actor&) const;

    infinity::Address native(const Frame&) const;
    infinity::ActivityId native(const Actor&) const;
    infinity::XPlace native(const Place&) const;
    Frame frame(const infinity::Address&) const;
    Actor actor(const infinity::ActivityId&) const;
    Place place(const infinity::XPlace&) const;
    RoutePoint point(const infinity::FlightWaypoint&) const;
    std::vector<Contact> contacts() const;
    Action stationAction(const Place&) const;
    Action vesselAction(const Actor&) const;
    Action currentPoseAction() const;
    std::optional<RoutePoint> resumeDock(const PlayerLocation&) const;

    std::string serialize() const;
    bool restore(std::string_view);

private:
    PlayerLocation location_;
    PlayerLocation lastFlight_;
    double seconds_{};
    std::optional<std::pair<Actor,infinity::StoryKey>> heardStory_;
    std::optional<infinity::DockingBerth> berth(const Actor&) const;
};

} // namespace pelagic::missions
