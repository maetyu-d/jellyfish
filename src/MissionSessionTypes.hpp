#pragma once

#include <array>
#include <compare>
#include <cstdint>
#include <optional>
#include <string>

namespace pelagic::missions {

using Position = std::array<double, 3>;
using Orientation = std::array<double, 4>; // w, x, y, z.

struct Frame {
    std::uint32_t system{};
    std::optional<std::uint64_t> world;
    auto operator<=>(const Frame&) const = default;
};

struct Place {
    std::uint32_t system{};
    std::uint64_t world{};
    std::uint32_t station{};
    bool city{};
    auto operator<=>(const Place&) const = default;
};

struct Actor {
    Frame frame;
    std::uint32_t slot{};
    auto operator<=>(const Actor&) const = default;
};

struct PlayerLocation {
    Frame frame;
    Position eye{}, velocity{}, forward{0., 0., -1.};
    Orientation orientation{1., 0., 0., 0.};
    bool active{}, inTransit{}, nearOrbit{}, landed{}, docking{};
    std::optional<Actor> clamped;
    std::optional<Actor> target;
    bool aboardDockside{};
    double thrust{};
    bool manualWarp{};
};

struct RoutePoint {
    Frame frame;
    Position position{}, velocity{};
    Orientation orientation{1., 0., 0., 0.};
    double standOff{};
    std::string label;
    std::optional<Actor> berth;
    std::optional<Place> place;
    double berthRadius{420.};
    std::optional<std::uint32_t> connection;
};

enum class ActionKind { None, Plot, Approach, Dock, Target, Launch, Follow, Recover, Land };

struct Action {
    ActionKind kind{ActionKind::None};
    RoutePoint point;
};

enum class ContactKind { Station, Freight, Patrol, Hostile, Evidence, Distress, Other };

struct Contact {
    Actor id;
    Position position{}, velocity{};
    Orientation orientation{1., 0., 0., 0.};
    double radius{}, hull{};
    ContactKind kind{ContactKind::Other};
    bool canDock{}, disabled{};
    std::string name, status;
    std::optional<Place> port;
};

struct FlightStatus {
    double hull{100.}, fuel{80.}, fuelCapacity{80.};
    std::int64_t credits{}, cargoUnits{};
    unsigned holdCapacity{}, technology{}, culture{};
    bool underAttack{};
    std::string incomingFire;
};

} // namespace pelagic::missions
