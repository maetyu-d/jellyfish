#pragma once

#include "MissionPresentation.hpp"
#include "MissionSessionTypes.hpp"

#include <cstdint>
#include <optional>
#include <string>
#include <vector>

namespace pelagic::missions {

class NativeRuntime;

struct ConvoyKey {
    std::uint32_t service{};
    std::uint64_t cycle{};
    auto operator<=>(const ConvoyKey&) const = default;
};

enum class ConvoyDuty { None, Escort, Pirate };

enum class CharterState { Active, Delivered, Expired };
struct CharterJob {
    std::uint64_t id{};
    Place origin, destination;
    std::int64_t deadline{}, reward{}, units{};
    CharterState state{};
};

class MissionTransport {
public:
    explicit MissionTransport(NativeRuntime& runtime) : runtime_(runtime) {}

    missionui::Snapshot snapshot(missionui::Page);
    Action dispatch(missionui::Page,missionui::Action);
    std::vector<CharterJob> charters() const;
    std::optional<CharterJob> offer(Place) const;
    std::vector<Place> localPlaces() const;
    std::vector<ConvoyKey> convoys() const;

    bool accept(Place);
    bool collectFreight();
    bool deliver();
    bool refuel();
    bool interact();
    bool hail(const Actor&);
    bool join(ConvoyKey,ConvoyDuty);
    bool report(ConvoyKey);
    bool seize(const Actor&);
    Action follow(ConvoyKey);
    Action followAction() const;
    void cancelFollow();
    const std::string& message() const noexcept { return message_; }

private:
    struct CharterRow {
        Place place;
        std::optional<CharterJob> charter;
    };
    NativeRuntime& runtime_;
    std::size_t charterRow_{}, charterSheet_{}, convoyRow_{}, convoySheet_{};
    std::string message_;
    std::vector<CharterRow> charterRows() const;
    bool communicate(const Actor&,bool freight);
};

} // namespace pelagic::missions
