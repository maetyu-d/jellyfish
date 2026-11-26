#include "BubbleMissions.hpp"

#include <algorithm>
#include <cstdio>
#include <ranges>

namespace pelagic::missions {
namespace {
using infinity::StoryKind;

std::uint64_t seed(BubbleId bubble) {
    const std::uint64_t domain=bubble.kind==BubbleKind::Region ? 0x524547494f4eULL : 0x53595354454dULL;
    return infinity::mix64(domain^bubble.id);
}

constexpr std::uint64_t edition(BubbleId bubble) {
    // Reserve stable IDs separate from the normal encounter and clock-driven Dispatch cases.
    return 300'000'000ULL+bubble.id+(bubble.kind==BubbleKind::Region ? systemCells : 0);
}
} // namespace

BubbleMissions::BubbleMissions(const Ocean& ocean,infinity::XalariaStories& stories) : stories_(stories) {
    const auto assign=[&](BubbleId bubble,unsigned layer,std::vector<unsigned> targets) {
        const auto salt=seed(bubble);
        const auto rank=[&](unsigned id) { return infinity::mix64(salt^infinity::mix64(id)); };
        std::ranges::sort(targets,std::less<>{},rank);
        auto& roster=rosters_[bubble];
        roster.count=2+unsigned(salt%5);
        roster.layer=layer;
        constexpr auto kinds=unsigned(StoryKind::Count);
        const unsigned first=unsigned((salt>>8)%kinds);
        const unsigned stride=(salt&(1ULL<<24)) ? 1 : kinds-1;
        for (unsigned i=0;i<roster.count;++i) {
            const auto system=targets[i%targets.size()];
            const auto variant=1+unsigned(infinity::mix64(salt+i)%infinity::storyVariantsPerKind);
            roster.keys[i]={system,edition(bubble),StoryKind((first+stride*i)%kinds),0,variant,false};
        }
    };
    const auto systems=ocean.systemBubbleIds();
    for (const auto& region:ocean.regions()) {
        const auto local=systems.subspan(region.firstSystem,region.systems);
        assign({BubbleKind::Region,region.cell},region.scale,{local.begin(),local.end()});
        for (const unsigned system : local) assign({BubbleKind::System,system},region.scale,{system});
    }
    if (const auto first=rosters_.find({BubbleKind::System,openingSignalSystemId}); first!=rosters_.end()) {
        auto& roster=first->second;
        const auto ordered=std::span(roster.keys).first(roster.count);
        const auto rank=[](infinity::StoryKey key) {
            return key.kind==StoryKind::Science ? 0 : key.kind==StoryKind::Distress ? 1 : 2;
        };
        std::ranges::sort(ordered,std::less<>{},rank);
        if (ordered.size()>=3 && ordered[0].kind==StoryKind::Science && ordered[1].kind==StoryKind::Distress)
            stories_.setOpeningAssignments(ordered[0],ordered[1]);
    }
}

std::span<const infinity::StoryKey> BubbleMissions::assignments(BubbleId bubble) const {
    const auto found=rosters_.find(bubble);
    if (found==rosters_.end()) return {};
    return {found->second.keys.data(),found->second.count};
}

std::optional<BubbleId> BubbleMissions::owner(infinity::StoryKey key) const {
    constexpr auto base=edition({BubbleKind::System,0});
    if (key.edition<base || key.edition>=base+systemCells+regionCells) return {};
    const auto index=unsigned(key.edition-base);
    const BubbleId owner=index<systemCells ? BubbleId{BubbleKind::System,index}
                                          : BubbleId{BubbleKind::Region,index-systemCells};
    const auto keys=assignments(owner);
    return std::ranges::find(keys,key)==keys.end() ? std::nullopt : std::optional{owner};
}

std::string BubbleMissions::detail(const infinity::XalariaStory& mission) const {
    const auto key=mission.key;
    if (stories_.result(key)) return "Report filed";
    if (const auto* caseFile=stories_.investigation(key); caseFile && stories_.evidenceComplete(key))
        return "Report ready";
    if (mission.site!=infinity::StorySite::Survey)
        return stories_.openingAssignment(key) ? "Dock with freighter" : "Investigation / Docking required";
    return stories_.openingAssignment(key) ? "Orbital scan" : "Orbital investigation";
}

unsigned BubbleMissions::completed(BubbleId bubble) const {
    return unsigned(std::ranges::count_if(assignments(bubble),
        [&](auto key) { return stories_.result(key).has_value(); }));
}

std::string BubbleMissions::label(BubbleId bubble) const {
    if (bubble.kind==BubbleKind::System) {
        const auto found=stories_.catalog().stars.find(bubble.id);
        return found==stories_.catalog().stars.end() ? "System Bubble" : found->second.name;
    }
    char name[32];
    std::snprintf(name,sizeof(name),"Region %02u, %02u",bubble.id%regionGrid+1,bubble.id/regionGrid+1);
    return name;
}

missionui::Snapshot BubbleMissions::snapshot(BubbleId bubble,std::size_t selection) const {
    using namespace missionui;
    Snapshot view;
    view.page=bubble.kind==BubbleKind::System ? Page::SystemBubble : Page::RegionBubble;
    view.location=label(bubble);
    const auto keys=assignments(bubble);
    if (keys.empty()) {
        view.empty="No bubble selected.";
        return view;
    }
    view.selection=std::min(selection,keys.size()-1);
    const unsigned filed=completed(bubble);
    view.message=std::to_string(filed)+" / "+std::to_string(keys.size())+" reports filed";
    for (const auto key:keys) {
        const auto mission=stories_.generate(key);
        view.rows.push_back({mission.headline,stories_.catalog().star(mission.system).name,
                              stories_.result(key) ? "Filed" : stories_.tracked()==key ? "Tracked" : "Open",
                              detail(mission)});
    }
    const auto mission=stories_.generate(keys[view.selection]);
    view.title=mission.headline;
    view.subtitle=detail(mission)+" · "+mission.place;
    view.body=mission.report;
    view.body+=filed ? "\n\nColour restored." :
        "\n\nFile your first report on this board to restore the bubble’s colour.";
    const bool filedSelected=stories_.result(mission.key).has_value();
    const bool tracked=stories_.tracked()==mission.key;
    if (!filedSelected && !tracked)
        view.buttons.push_back({{Input::Track},"Track assignment",true,'\r'});
    view.buttons.push_back({{Input::Primary},"Open in Dispatch",true,(!filedSelected && !tracked) ? 'd' : '\r'});
    return view;
}

BubbleProgress BubbleMissions::synchronize(Ocean& ocean,bool animate, std::span<const BubbleId> waiting) const {
    BubbleProgress progress;
    for (const auto& [bubble,roster] : rosters_) {
        const unsigned filed = completed(bubble);
        progress.completed += filed;
        progress.restoredBubbles += filed!=0;
        auto& layer = progress.layers[roster.layer];
        layer.completed += filed;
        layer.total += roster.count;
        if (filed && std::ranges::find(waiting,bubble)==waiting.end() && ocean.restoreBubbleColour(bubble,animate))
            progress.restored.push_back(bubble);
    }
    return progress;
}

} // namespace pelagic::missions
