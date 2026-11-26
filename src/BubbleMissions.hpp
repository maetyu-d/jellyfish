#pragma once

#include "MissionPresentation.hpp"
#include "Sea.hpp"
#include "infinity/XalariaStories.hpp"

namespace pelagic::missions {

struct LayerMissionCount {
    unsigned completed{}, total{};
    bool operator==(const LayerMissionCount&) const = default;
};

struct BubbleProgress {
    unsigned completed{};
    unsigned restoredBubbles{};
    std::array<LayerMissionCount,regionScales> layers{};
    std::vector<BubbleId> restored;
};

class BubbleMissions {
public:
    BubbleMissions(const Ocean&, infinity::XalariaStories&);

    std::span<const infinity::StoryKey> assignments(BubbleId) const;
    std::optional<BubbleId> owner(infinity::StoryKey) const;
    unsigned completed(BubbleId) const;
    std::string label(BubbleId) const;
    missionui::Snapshot snapshot(BubbleId, std::size_t selection) const;
    BubbleProgress synchronize(Ocean&, bool animate, std::span<const BubbleId> waiting = {}) const;

private:
    struct Roster {
        std::array<infinity::StoryKey,6> keys{};
        unsigned count{}, layer{};
    };
    infinity::XalariaStories& stories_;
    std::map<BubbleId,Roster> rosters_;
    std::string detail(const infinity::XalariaStory&) const;
};

} // namespace pelagic::missions
