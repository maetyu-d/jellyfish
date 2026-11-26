#include "MissionDispatch.hpp"
#include "MissionRuntime.hpp"

#include "infinity/Planetology.hpp"
#include "infinity/TerrainMaterial.hpp"
#include "infinity/XalariaTraffic.hpp"

#include <algorithm>
#include <cmath>
#include <utility>

namespace pelagic::missions {
namespace {

using infinity::StoryPage;
using missionui::Input;
using missionui::Page;

Page viewOf(StoryPage page) {
    switch (page) {
    case StoryPage::Nearby: return Page::Nearby;
    case StoryPage::News: return Page::News;
    case StoryPage::Feed: return Page::LocalLeads;
    case StoryPage::FollowUps: return Page::FollowUps;
    case StoryPage::Journal: return Page::Journal;
    case StoryPage::Archive: return Page::Discoveries;
    }
    return Page::Nearby;
}

std::optional<StoryPage> nativePage(Page page) {
    switch (page) {
    case Page::Nearby: return StoryPage::Nearby;
    case Page::News: return StoryPage::News;
    case Page::LocalLeads: return StoryPage::Feed;
    case Page::FollowUps: return StoryPage::FollowUps;
    case Page::Journal: return StoryPage::Journal;
    case Page::Discoveries: return StoryPage::Archive;
    default: return {};
    }
}

Position positionOf(glm::dvec3 p) {
    return {p.x,p.y,p.z};
}

glm::dvec3 pointInFrame(const NativeRuntime& runtime, const infinity::Address& source, glm::dvec3 metres,
                         const infinity::Address& destination) {
    if (source==destination) return metres;
    return runtime.universe.pointRelative(source,metres/
        std::pow(10.,runtime.universe.describe(source).frame.logRadius),destination,0.);
}

bool onSensors(const NativeRuntime& runtime,const infinity::CombatPlayer& player,
               const infinity::ActivityBody& body) {
    const auto observer=pointInFrame(runtime,player.frame,player.position,body.id.home);
    const auto delta=body.position-observer;
    const auto separation=glm::length(delta);
    if (!std::isfinite(separation) || separation>=infinity::trafficRadioRange) return false;
    if (body.id.home.kind()!=infinity::Kind::Planet || separation<=0.) return true;
    const auto closest=glm::clamp(-glm::dot(observer,delta)/(separation*separation),0.,1.);
    const auto planetRadius=std::pow(10.,runtime.universe.describe(body.id.home).frame.logRadius);
    return glm::length(observer+delta*closest)>=planetRadius;
}

Contact viewContact(const NativeRuntime& runtime,const infinity::ActivityBody& body,ContactKind kind) {
    Contact contact;
    contact.id=runtime.actor(body.id);
    contact.position=positionOf(body.position);
    contact.velocity=positionOf(body.velocity);
    contact.orientation={body.orientation.w,body.orientation.x,body.orientation.y,body.orientation.z};
    contact.radius=body.radius;
    contact.hull=body.hull;
    contact.kind=kind;
    contact.disabled=body.disabled;
    contact.name=body.name;
    contact.status=body.status;
    return contact;
}

bool witnessReached(const infinity::XalariaStory& story,const infinity::StoryContext& context,
                    const infinity::XalariaStories& stories) {
    if (story.system!=context.system) return false;
    if (story.site==infinity::StorySite::Station)
        return story.port && context.boardedStation==story.port;
    if (story.site==infinity::StorySite::Vessel) {
        const auto vessel=stories.vessel(story);
        return vessel && context.boardedVessel==vessel;
    }
    return false;
}

bool assignmentOrbit(const infinity::XalariaStory& story,const infinity::StoryContext& context) {
    return story.system==context.system && (story.world ? context.orbit==story.world : context.stellarOrbit);
}

std::string routeLabel(const infinity::XalariaStory& story,const infinity::StoryContext& context,
                       const infinity::XalariaStories& stories) {
    if (stories.result(story.key))
        return stories.continuation(story.key) ? "Next chapter" : "";
    if (!stories.actionable(story.key) || stories.ready(story,context)) return {};
    if (const auto* state=stories.investigation(story.key);
        !story.key.chapter && state && !stories.evidenceComplete(story.key)) {
        if (state->evidence==7 && witnessReached(story,context,stories))
            return "Take witness statement";
        if (assignmentOrbit(story,context) && stories.investigationWaypoint(story.key)) return "Approach search area";
    }
    if (!assignmentOrbit(story,context)) return "Plot in atlas";
    if (story.site==infinity::StorySite::Vessel) return "Find freighter";
    if (story.site==infinity::StorySite::Station) return "Dock at station";
    return {};
}

std::string filedNext(const infinity::XalariaStories& stories,infinity::StoryKey key) {
    return stories.continuation(key) ? "The next chapter is in Follow-ups or Journal." : "Case closed.";
}

} // namespace

MissionDispatch::MissionDispatch(NativeRuntime& runtime) : runtime_(runtime) {}

bool MissionDispatch::handles(Page page) {
    return bool(nativePage(page));
}

void MissionDispatch::open(std::optional<std::uint32_t> atlasSystem, std::optional<Actor> radioContact) {
    auto& stories=runtime_.stories;
    const auto local=runtime_.storyContext().system;
    const bool fromAtlas=atlasSystem && runtime_.catalog->stars.contains(*atlasSystem);
    const auto system=fromAtlas ? *atlasSystem : local;
    const auto now=runtime_.seconds();
    std::optional<infinity::StoryKey> lead;
    if (!fromAtlas && radioContact && radioContact->frame.system==local) {
        lead=runtime_.heardStory(*radioContact);
        if (!lead) {
            const auto distress=stories.distressAt(local,now);
            if (distress && stories.known(*distress) &&
                stories.vessel(stories.generate(*distress))==runtime_.native(*radioContact) &&
                stories.tracked()!=distress)
                lead=distress;
        }
    }
    stories.evidenceOpen=false;
    stories.show(system,now);
    stories.showPage(!fromAtlas && stories.tracked() ? StoryPage::Journal : StoryPage::Nearby,now);
    if (lead) stories.openReport(*lead,now);
}

void MissionDispatch::close() {
    runtime_.stories.open=false;
}

bool MissionDispatch::isOpen() const {
    return runtime_.stories.open;
}

void MissionDispatch::refresh() {
    auto& stories=runtime_.stories;
    if (stories.open) stories.refresh(runtime_.seconds());
}

missionui::Snapshot MissionDispatch::snapshot() const {
    const auto& stories=runtime_.stories;
    const auto context=runtime_.storyContext();
    const auto now=runtime_.seconds();
    const auto page=stories.page();
    missionui::Snapshot view;
    view.page=viewOf(page);
    view.location=systemName(stories.system);
    view.selection=stories.row;
    view.sheet=stories.sheet();
    view.sheetCount=stories.sheetCount();
    view.message=stories.message;
    for (const auto& story:stories.entries()) {
        std::string category(infinity::storyKindName(story.key.kind));
        if (story.key.chapter) category+=" / Chapter "+std::to_string(story.key.chapter+1);
        else if (story.key.live && stories.incident(story.key,now).urgent) category+=" / Urgent";
        if (stories.result(story.key)) category+=" / Reported";
        else if (stories.tracked()==story.key) category+=" / Tracked";
        auto location=story.place;
        if (story.key.live && !story.key.chapter) {
            const auto hops=stories.hops(story.key);
            location=systemName(story.system)+" / "+std::to_string(hops)+(hops==1 ? " jump" : " jumps");
        }
        view.rows.push_back({story.headline,std::move(location),std::move(category)});
    }
    const auto* story=stories.selected();
    if (!story) {
        view.title="Dispatch";
        if (page==StoryPage::News) view.empty="No reports on your discoveries yet.";
        else if (page==StoryPage::FollowUps) view.empty="Follow-ups must be earned.";
        else view.empty="No discovered leads here yet.";
        view.body="Scan worlds from the helm. Hail crews or board a station to find local contacts.";
        if ((context.orbit || context.stellarOrbit) && !stories.tracked())
            view.buttons.push_back({{Input::Scan},"Scan current orbit"});
        return view;
    }
    const auto key=story->key;
    const auto result=stories.result(key);
    const auto available=stories.actionable(key);
    const auto tracked=stories.tracked()==key;
    const double reportTime=now-(page==StoryPage::News ? stories.hops(key)*120. : 0.);
    const bool living=key.live && !key.chapter;
    const auto stage=stories.stage(key,now);
    const auto* state=stories.investigation(key);
    const bool ready=tracked && available && stories.ready(*story,context);
    view.title=story->headline;
    view.subtitle=std::string(infinity::storyKindName(key.kind))+" / "+systemName(story->system)+" / "+story->place;
    if (key.chapter)
        view.subtitle+=" / Chapter "+std::to_string(key.chapter+1)+" of "+std::to_string(infinity::storyChapterCount);
    else if (result) view.subtitle+=" / Filed";
    else if (living) view.subtitle+=" / "+std::string(infinity::incidentPhaseName(stories.incident(key,reportTime).phase));
    else view.subtitle+=" / "+std::string(infinity::storyStageName(stage));
    if (const auto* discovery=stories.discovery(key))
        view.body="Found through "+std::string(infinity::storyOriginName(
            key.chapter ? infinity::StoryOrigin::FollowUp : discovery->origin))+"\n\n";
    if (state && stories.evidenceOpen && !stories.openingAssignment(key)) {
        constexpr std::array labels{"Signal bearing","Physical trace","Recovered recorder","Independent account"};
        const auto notes=stories.evidenceNotes(key);
        for (unsigned i=0;i<labels.size();++i) {
            view.body+=(state->evidence&(1u<<i)) ? "Recorded / " : "Pending / ";
            view.body+=std::string(labels[i])+"\n"+notes[i]+"\n\n";
        }
    } else {
        view.body+=story->report+"\n\n";
        if (result) view.body+=story->outcomes[*result];
        else if (state && !key.chapter) view.body+=stories.investigationTask(key);
        else if (living) view.body+=stories.incidentReport(key,reportTime);
        else view.body+=stage==infinity::StoryStage::FollowUp ? story->followUp : story->development;
        view.body+="\n\n";
    }
    if (living) {
        if (page==StoryPage::News) {
            const auto delay=stories.hops(key)*2;
            view.body+=delay ? "Report delayed by "+std::to_string(delay)+" minutes.\n" : "Local dispatch report.\n";
        } else {
            const auto remaining=stories.incident(key,now).endsAt-now;
            view.body+=remaining>0. ? "Response window / "+std::to_string(int(std::ceil(remaining/60.)))+
                                      " min remaining.\n" : "Response window ended.\n";
        }
    }
    if (result) view.body+=filedNext(stories,key);
    else if (!available) view.body+="Response window closed.";
    else if (ready) view.body+="Choose how to file the report.";
    else if (state && !key.chapter && !stories.evidenceComplete(key))
        view.body+="Open the case file or scan for evidence.";
    else if (story->site==infinity::StorySite::Vessel) view.body+="Resolve aboard the target freighter.";
    else if (story->site==infinity::StorySite::Station) view.body+="Resolve inside the target station.";
    else view.body+="Resolve from the target orbit.";

    const auto route=routeLabel(*story,context,stories);
    if (!route.empty()) view.buttons.push_back({{Input::Route},route});
    if (state && !stories.openingAssignment(key))
        view.buttons.push_back({{Input::CaseFile},stories.evidenceOpen ? "Read brief" : "Case file"});
    if (!result) {
        view.buttons.push_back({{Input::Track},tracked ? "Tracked" : "Track lead",available && !tracked});
        if (tracked && available && state && !key.chapter && !stories.evidenceComplete(key) &&
            context.system==story->system && (context.orbit || context.stellarOrbit || witnessReached(*story,context,stories)))
            view.buttons.push_back({{Input::Scan},"Scan evidence"});
        view.buttons.push_back({{Input::Primary},story->decisions[0],ready});
        view.buttons.push_back({{Input::Secondary},story->decisions[1],ready});
    }
    return view;
}

Action MissionDispatch::dispatch(missionui::Action input) {
    auto& stories=runtime_.stories;
    switch (input.kind) {
    case Input::Close: close(); break;
    case Input::ShowPage:
        if (const auto p=nativePage(static_cast<Page>(input.value)))
            stories.showPage(*p,runtime_.seconds());
        break;
    case Input::SelectRow:
        if (input.value>=0) stories.select(std::size_t(input.value));
        break;
    case Input::PreviousSheet: stories.changeSheet(-1,runtime_.seconds()); break;
    case Input::NextSheet: stories.changeSheet(1,runtime_.seconds()); break;
    case Input::Track:
        if (const auto* story=stories.selected()) stories.track(story->key);
        break;
    case Input::Route: return route();
    case Input::Primary: resolve(0); break;
    case Input::Secondary: resolve(1); break;
    case Input::Scan: scan(); break;
    case Input::CaseFile:
        if (!stories.open) {
            open();
            if (stories.tracked()) stories.openReport(*stories.tracked(),runtime_.seconds());
            else stories.showPage(StoryPage::Archive,runtime_.seconds());
            stories.evidenceOpen=true;
        } else stories.evidenceOpen=!stories.evidenceOpen;
        break;
    default: break;
    }
    return {};
}

bool MissionDispatch::resolve(unsigned choice) {
    auto& stories=runtime_.stories;
    const auto* selected=stories.selected();
    if (!selected) return false;
    const auto key=selected->key;
    if (stories.resolve(key,runtime_.storyContext(),choice,runtime_.economy)) {
        notice_=stories.message;
        return true;
    }
    if (!stories.result(key)) {
        stories.message=!stories.actionable(key) ? "The response window has closed. Read the outcome in News." :
            stories.tracked()!=key ? "Track this lead first." :
            !stories.evidenceComplete(key) ? stories.investigationTask(key) :
            "Reach the assignment site to file the report.";
        notice_=stories.message;
    }
    return false;
}

Action MissionDispatch::route() {
    auto& stories=runtime_.stories;
    const auto* story=stories.selected();
    if (!story) return {};
    const auto key=story->key;
    if (const auto next=stories.continuation(key)) {
        stories.openReport(*next,runtime_.seconds());
        return {};
    }
    const auto context=runtime_.storyContext();
    if (!stories.actionable(key) || stories.ready(*story,context)) return {};
    if (!key.chapter && stories.investigation(key) && !stories.evidenceComplete(key)) {
        if (stories.tracked()!=key && !stories.track(key)) return {};
        if (stories.investigation(key)->evidence==7 && witnessReached(*story,context,stories)) {
            scanEvidence();
            stories.evidenceOpen=true;
            return {};
        }
        if (const auto target=stories.investigationWaypoint(key); target && assignmentOrbit(*story,context)) {
            if (runtime_.location().aboardDockside || runtime_.location().docking || runtime_.location().clamped) {
                stories.message="Return to the helm and clear the berth to search.";
                return {};
            }
            close();
            return {ActionKind::Approach,runtime_.point(*target)};
        }
    }
    if (story->port && assignmentOrbit(*story,context)) {
        Action action;
        if (story->site==infinity::StorySite::Vessel) {
            const auto id=stories.vessel(*story);
            if (!id) return {};
            const auto vessel=runtime_.actor(*id);
            if (runtime_.location().clamped==vessel) {
                stories.message="Go beyond the airlock to board the freighter.";
                return {};
            }
            const auto player=runtime_.combatPlayer();
            const auto contact=infinity::xalariaTrafficContact(runtime_.economy,*id,player.gate,runtime_.seconds());
            if (!contact) return {};
            if (onSensors(runtime_,player,contact->body)) {
                runtime_.hearStory(*contact);
                action=runtime_.vesselAction(vessel);
            } else if (auto hold=infinity::xalariaTrafficRendezvous(runtime_.economy,*contact)) {
                hold->velocity={};
                hold->label="Distress contact / "+contact->body.name;
                action={ActionKind::Approach,runtime_.point(*hold)};
                notice_="Approaching distress signal. Reopen Dispatch to hail.";
            } else stories.message="No safe approach available. Hail when the vessel comes into range.";
        } else {
            if (runtime_.economy.dockedPlace()==story->port) {
                stories.message="Go beyond the airlock to board the station.";
                return {};
            }
            action=runtime_.stationAction(runtime_.place(*story->port));
        }
        if (action.kind!=ActionKind::None) close();
        return action;
    }
    RoutePoint target;
    target.frame={story->system,story->world};
    target.label=story->headline;
    if (story->port) target.place=runtime_.place(*story->port);
    close();
    return {ActionKind::Plot,std::move(target)};
}

bool MissionDispatch::scanEvidence() {
    auto& stories=runtime_.stories;
    if (!stories.tracked() || !stories.investigation(*stories.tracked())) return false;
    const auto key=*stories.tracked();
    const auto context=runtime_.storyContext();
    if (stories.openingAssignment(key)) {
        if (stories.scanEvidence(context,runtime_.native(Frame{key.system,{}}),{},{},runtime_.seconds())) {
            refresh();
            return true;
        }
        notice_=stories.investigationTask(key);
        return false;
    }
    const auto plan=stories.investigationPlan(key);
    const auto player=runtime_.combatPlayer();
    if (context.system==plan.key.system && player.frame.kind()>=infinity::Kind::System) {
        const auto differentFrame=player.frame!=plan.frame;
        const auto eye=pointInFrame(runtime_,player.frame,player.position,plan.frame);
        const auto velocity=differentFrame ? runtime_.universe.relative(player.frame,plan.frame,0.).orientation*
            player.velocity : player.velocity;
        if (stories.scanEvidence(context,plan.frame,eye,velocity,runtime_.seconds())) {
            refresh();
            return true;
        }
    }
    notice_=stories.investigationTask(key);
    return false;
}

bool MissionDispatch::scan() {
    auto& stories=runtime_.stories;
    const auto tracked=stories.tracked();
    if (tracked && stories.actionable(*tracked) && !tracked->chapter && !stories.evidenceComplete(*tracked))
        return scanEvidence();
    if (stories.survey(runtime_.storyContext(),runtime_.seconds())) {
        refresh();
        return true;
    }
    notice_="Survey / No new lead here. Hail crews or explore another world.";
    return false;
}

bool MissionDispatch::hear(Actor id) {
    const auto context=runtime_.storyContext();
    if (context.system!=id.frame.system || !context.stellarOrbit) return false;
    const auto player=runtime_.combatPlayer();
    const auto now=runtime_.seconds();
    const auto contact=infinity::xalariaTrafficContact(runtime_.economy,runtime_.native(id),player.gate,now);
    if (!contact || !onSensors(runtime_,player,contact->body) || !runtime_.hearStory(*contact)) return false;
    refresh();
    return true;
}

std::string MissionDispatch::takeNotice() {
    auto discovered=runtime_.stories.takeDiscoveryNotice();
    if (!discovered.empty()) {
        notice_.clear();
        return discovered;
    }
    return std::exchange(notice_,{});
}

std::optional<DispatchObjective> MissionDispatch::objective() const {
    const auto& stories=runtime_.stories;
    const auto tracked=stories.tracked();
    if (!tracked) return {};
    const auto story=stories.generate(*tracked);
    DispatchObjective result;
    result.frame={story.system,story.world};
    result.headline=story.headline;
    result.destination=story.place;
    if (!stories.actionable(*tracked)) result.task="Response window closed.";
    else if (stories.openingAssignment(*tracked)) result.task=stories.investigationTask(*tracked);
    else if (tracked->chapter || stories.evidenceComplete(*tracked))
        result.task=story.site==infinity::StorySite::Survey ? "Reach the target orbit and file the report." :
                    "Board the assignment site and file the report.";
    else result.task=stories.investigationTask(*tracked);
    if (story.port) result.port=runtime_.place(*story.port);
    if (const auto vessel=stories.vessel(story)) result.vessel=runtime_.actor(*vessel);
    if (const auto mark=stories.investigationWaypoint(*tracked)) result.search=runtime_.point(*mark);
    return result;
}

std::vector<Contact> MissionDispatch::evidence(Frame frame) const {
    std::vector<Contact> result;
    const auto found=runtime_.catalog->stars.find(frame.system);
    if (found==runtime_.catalog->stars.end() || (frame.world && !found->second.worlds.contains(*frame.world))) return result;
    for (const auto& body:runtime_.stories.evidenceBodies(runtime_.native(frame)))
        result.push_back(viewContact(runtime_,body,ContactKind::Evidence));
    return result;
}

std::optional<Contact> MissionDispatch::distress() const {
    const auto context=runtime_.storyContext();
    if (!context.stellarOrbit || !runtime_.catalog->stars.contains(context.system)) return {};
    const auto& stories=runtime_.stories;
    const auto now=runtime_.seconds();
    const auto call=stories.distressAt(context.system,now);
    const auto vessel=call ? stories.vessel(stories.generate(*call)) : std::nullopt;
    if (!vessel) return {};
    const auto contact=infinity::xalariaTrafficContact(runtime_.economy,*vessel,runtime_.combatPlayer().gate,now);
    if (!contact) return {};
    auto item=viewContact(runtime_,contact->body,ContactKind::Distress);
    item.canDock=bool(infinity::xalariaVesselBerth(contact->body));
    item.port=runtime_.place(contact->port);
    item.status="Distress broadcast / "+item.status;
    return item;
}

std::string MissionDispatch::systemName(std::uint32_t id) const {
    const auto it=runtime_.catalog->stars.find(id);
    return it==runtime_.catalog->stars.end() ? std::string{} : it->second.name;
}

std::vector<DispatchWorld> MissionDispatch::worlds(std::uint32_t system) const {
    std::vector<DispatchWorld> result;
    const auto found=runtime_.catalog->stars.find(system);
    if (found==runtime_.catalog->stars.end()) return result;
    const auto address=runtime_.catalog->address(system);
    result.reserve(found->second.worlds.size());
    for (const auto& [id,w]:found->second.worlds) {
        DispatchWorld item;
        item.id=id;
        if (w.primary>=0) item.primary=std::uint64_t(w.primary);
        item.name=w.name;
        item.radius=w.radius;
        item.distance=w.distance;
        item.period=w.period;
        item.tilt=w.tilt;
        item.tiltRotation=w.tiltRotation;
        item.temperature=w.temperature;
        item.clouds=w.cloudCover;
        item.gas=w.composition==0;
        const auto node=runtime_.universe.describe(address.child(infinity::Kind::Planet,id));
        const auto traits=infinity::planetTraits(node);
        const auto material=infinity::terrainMaterial(node);
        const bool solid=infinity::hasSolidSurface(node);
        const auto low=solid ? glm::mix(traits.low,material.bedrock,.45f) : traits.low;
        const auto high=solid ? glm::mix(traits.high,material.sediment,.50f) : traits.high;
        const auto& rings=traits.rings;
        item.appearance={
            {low.x,low.y,low.z,float(traits.phase)},
            {high.x,high.y,high.z,float(unsigned(traits.type)+1)},
            {solid ? float(node.geology->terrain.type) : float(traits.jetBands),
             solid ? material.sedimentCover : float(traits.bandContrast),
             solid ? float(node.environment.waterActivity) : float(traits.haze),
             solid ? std::max(material.frozen,float(traits.iceCoverage)) : float(rings.iceFraction)},
            {float(rings.innerRadius),float(rings.outerRadius),float(rings.opticalDepth),float(rings.seed%10000)/10000.f},
            {float(traits.axis.x),float(traits.axis.y),float(traits.axis.z),
             solid ? float(node.environment.pressureGPa*10000.) : 0.f},
        };
        result.push_back(std::move(item));
    }
    return result;
}

} // namespace pelagic::missions
