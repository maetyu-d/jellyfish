#include "MissionTransport.hpp"
#include "MissionRuntime.hpp"

#include <algorithm>
#include <cmath>
#include <locale>
#include <sstream>

namespace pelagic::missions {
namespace {
constexpr std::size_t rowsPerSheet=8;

infinity::ConvoyKey native(ConvoyKey key) { return {key.service,key.cycle}; }
ConvoyKey key(infinity::ConvoyKey value) { return {value.service,value.cycle}; }

CharterJob charter(const NativeRuntime& runtime,const infinity::XContract& contract) {
    return {contract.id,runtime.place(contract.origin),runtime.place(contract.destination),contract.deadline,
            contract.reward,contract.units,CharterState(contract.state)};
}

std::string charterState(CharterState state) {
    switch (state) {
    case CharterState::Active: return "Active";
    case CharterState::Delivered: return "Delivered";
    case CharterState::Expired: return "Expired";
    }
    return {};
}

std::string portName(const NativeRuntime& runtime,Place place) {
    return runtime.economy.placeName(runtime.native(place));
}

std::optional<infinity::XPlace> localMarket(const NativeRuntime& runtime) {
    const auto& here=runtime.location();
    if (!here.active) return {};
    if (const auto dock=runtime.economy.dockedPlace()) return dock;
    if (!here.landed || !here.frame.world) return {};
    const infinity::XPlace city{here.frame.system,*here.frame.world,0,true};
    return runtime.economy.canTrade(city) ? std::optional{city} : std::nullopt;
}

std::optional<infinity::XalariaTrafficContact> trafficContact(const NativeRuntime& runtime,const Actor& target) {
    if (!runtime.location().active || runtime.location().inTransit || runtime.location().frame.system!=target.frame.system ||
        !runtime.catalog->stars.contains(target.frame.system) ||
        (target.frame.world && !runtime.catalog->star(target.frame.system).worlds.contains(*target.frame.world)))
        return {};
    return infinity::xalariaTrafficContact(runtime.economy,runtime.native(target),runtime.course.view.wormhole,runtime.seconds());
}

double radioRange(const NativeRuntime& runtime,const infinity::XalariaTrafficContact& contact) {
    const auto p=runtime.combatPlayer();
    const double units=std::pow(10.,runtime.universe.describe(p.frame).frame.logRadius);
    const auto local=runtime.universe.pointRelative(p.frame,p.position/units,contact.body.id.home,0.);
    return glm::distance(local,contact.body.position);
}

std::string countdown(double time) {
    const auto seconds=std::int64_t(std::max(0.,std::ceil(time)));
    const auto minutes=seconds/60;
    return std::to_string(minutes)+":"+(seconds%60<10?"0":"")+std::to_string(seconds%60);
}

void paginate(missionui::Snapshot& out,std::size_t entries,std::size_t& sheet,std::size_t& cursor) {
    out.sheetCount=std::max<std::size_t>(1,(entries+rowsPerSheet-1)/rowsPerSheet);
    sheet=std::min(sheet,out.sheetCount-1);
    out.sheet=sheet;
    cursor=std::min(cursor,entries>sheet*rowsPerSheet ?
        std::min(rowsPerSheet,entries-sheet*rowsPerSheet)-1 : 0u);
    out.selection=cursor;
}
} // namespace

std::vector<CharterJob> MissionTransport::charters() const {
    std::vector<CharterJob> result;
    const auto& records=runtime_.economy.contracts();
    result.reserve(records.size());
    for (auto row=records.rbegin();row!=records.rend();++row) result.push_back(charter(runtime_,*row));
    return result;
}

std::optional<CharterJob> MissionTransport::offer(Place place) const {
    const auto system=runtime_.catalog->stars.find(place.system);
    if (system==runtime_.catalog->stars.end() || !system->second.worlds.contains(place.world)) return {};
    const auto venues=runtime_.economy.venues(place.system,place.world);
    if (std::find(venues.begin(),venues.end(),runtime_.native(place))==venues.end()) return {};
    const auto job=runtime_.economy.offer(runtime_.native(place));
    if (!job.units) return {};
    return charter(runtime_,job);
}

std::vector<Place> MissionTransport::localPlaces() const {
    std::vector<Place> result;
    const auto& site=runtime_.location().frame;
    const auto sys=runtime_.catalog->stars.find(site.system);
    if (sys==runtime_.catalog->stars.end()) return result;
    if (site.world && sys->second.worlds.contains(*site.world))
        for (const auto& venue:runtime_.economy.venues(site.system,*site.world))
            result.push_back(runtime_.place(venue));
    for (const auto& [id,world]:sys->second.worlds) {
        if (site.world==id) continue;
        for (const auto& venue:runtime_.economy.venues(site.system,id))
            result.push_back(runtime_.place(venue));
    }
    if (const auto dock=runtime_.economy.dockedPlace()) {
        const auto found=std::find(result.begin(),result.end(),runtime_.place(*dock));
        if (found!=result.end()) std::rotate(result.begin(),found,std::next(found));
    }
    return result;
}

std::vector<MissionTransport::CharterRow> MissionTransport::charterRows() const {
    std::vector<CharterRow> result;
    for (const auto& job:charters())
        if (job.state==CharterState::Active) result.push_back({job.destination,job});
    for (const auto& port:localPlaces()) result.push_back({port,{}});
    for (const auto& job:charters())
        if (job.state!=CharterState::Active) result.push_back({job.destination,job});
    return result;
}

std::vector<ConvoyKey> MissionTransport::convoys() const {
    std::vector<ConvoyKey> result;
    for (auto row:runtime_.combat.convoys().known()) result.push_back(key(row));
    return result;
}

bool MissionTransport::accept(Place place) {
    if (!runtime_.location().active || !offer(place)) {
        message_="No open charter at this venue.";
        return false;
    }
    auto& economy=runtime_.economy;
    economy.view.place=runtime_.native(place);
    const bool accepted=economy.acceptContract();
    message_=economy.view.message;
    return accepted;
}

bool MissionTransport::collectFreight() {
    const auto& where=runtime_.location();
    if (!where.active || !where.aboardDockside || !where.clamped || !runtime_.pilot.clampedHarbour()) {
        message_="Secure the clamps and enter the loading or transfer bay.";
        return false;
    }
    auto& economy=runtime_.economy;
    bool loaded{};
    if (economy.dockedPlace()) {
        loaded=economy.collectLoadingBayFreight();
    } else if (const auto traffic=trafficContact(runtime_,*where.clamped)) {
        loaded=economy.collectTrafficFreight(*traffic,runtime_.pilot);
    }
    message_=loaded || !economy.view.message.empty() ? economy.view.message : "No freight on board.";
    return loaded;
}

bool MissionTransport::deliver() {
    if (!runtime_.location().active) return false;
    const bool paid=runtime_.economy.deliverContracts();
    message_=runtime_.economy.view.message;
    return paid;
}

bool MissionTransport::refuel() {
    const auto port=localMarket(runtime_);
    if (!port) {
        message_="Dock at a station or land to refuel at a city exchange.";
        return false;
    }
    runtime_.economy.view.place=*port;
    const bool fuelled=runtime_.economy.refuel();
    message_=runtime_.economy.view.message;
    return fuelled;
}

bool MissionTransport::interact() {
    const auto& where=runtime_.location();
    if (!where.active || (!where.clamped && !where.landed)) return false;
    const auto& economy=runtime_.economy;
    const bool due=std::any_of(economy.contracts().begin(),economy.contracts().end(),[&](const auto& job) {
        return job.state==infinity::XContract::State::Active && economy.canTrade(job.destination);
    });
    if (due) return deliver();
    if (where.clamped && where.aboardDockside) {
        const auto actor=runtime_.native(*where.clamped);
        if (runtime_.combat.shieldsLowered(actor) && runtime_.combat.prizeCargo(actor)>0)
            return seize(*where.clamped);
        return collectFreight();
    }
    return false;
}

bool MissionTransport::hail(const Actor& target) {
    return communicate(target,false);
}

bool MissionTransport::communicate(const Actor& target,bool freight) {
    const auto contact=trafficContact(runtime_,target);
    if (!contact || radioRange(runtime_,*contact)>infinity::trafficRadioRange) {
        message_="Move within 100 km of the ship to open a channel.";
        return false;
    }
    const auto player=runtime_.combatPlayer();
    const auto& body=contact->body;
    const auto units=std::pow(10.,runtime_.universe.describe(player.frame).frame.logRadius);
    const auto at=runtime_.universe.pointRelative(player.frame,player.position/units,body.id.home,0.);
    const auto local=runtime_.universe.relative(player.frame,body.id.home,0.).orientation*player.velocity;
    const auto direction=body.position-at;
    const auto distance=glm::length(direction);
    const auto closing=distance>1.e-8 ? glm::dot(local-body.velocity,direction/distance) : 0.;
    const auto request=freight ? infinity::TrafficRequest::FreightWork : infinity::TrafficRequest::Hail;
    message_=infinity::xalariaTrafficReply(*runtime_.catalog,runtime_.economy,*contact,request,closing);
    if (freight) return true;
    runtime_.combat.target=body.id;
    auto& convoys=runtime_.combat.convoys();
    if (infinity::isConvoyActor(body.id)) convoys.hear(body.id,runtime_.seconds());
    runtime_.hearStory(*contact);
    return true;
}

bool MissionTransport::join(ConvoyKey assigned,ConvoyDuty duty) {
    if (!runtime_.location().active || runtime_.location().inTransit) {
        message_="Reach the convoy or its departure berth.";
        return false;
    }
    auto& convoys=runtime_.combat.convoys();
    const bool joined=convoys.join(native(assigned),infinity::ConvoyDuty(duty),runtime_.combatPlayer());
    message_=convoys.message;
    return joined;
}

bool MissionTransport::report(ConvoyKey assigned) {
    auto& convoys=runtime_.combat.convoys();
    if (!runtime_.location().active || convoys.tracked()!=native(assigned)) {
        message_="Select your tracked escort to file its report.";
        return false;
    }
    const bool paid=convoys.report();
    message_=convoys.message;
    return paid;
}

bool MissionTransport::seize(const Actor& actor) {
    const auto context=runtime_.storyContext();
    if (context.boardedVessel!=runtime_.native(actor)) {
        message_="Board the vessel before transferring the manifest.";
        return false;
    }
    const bool took=runtime_.combat.seize(runtime_.native(actor),context);
    message_=runtime_.combat.message;
    return took;
}

Action MissionTransport::follow(ConvoyKey assigned) {
    auto& convoys=runtime_.combat.convoys();
    if (!convoys.followAssignment(native(assigned))) {
        message_=convoys.message;
        return {};
    }
    const auto& here=runtime_.location();
    message_=(here.clamped || here.docking || here.landed) ?
        "Clear the berth before joining the convoy formation." : "Following convoy.";
    return followAction();
}

Action MissionTransport::followAction() const {
    const auto& convoys=runtime_.combat.convoys();
    const auto key=convoys.tracked();
    if (!convoys.following || !key || !runtime_.location().active ||
        runtime_.location().clamped || runtime_.location().docking || runtime_.location().landed)
        return {};
    const auto pose=convoys.stage(*key,runtime_.seconds());
    if (pose.phase>=infinity::ConvoyPhase::Delivered) return {};
    const auto system=runtime_.location().frame.system;
    if (const auto target=convoys.waypoint(runtime_.combatPlayer())) {
        auto point=runtime_.point(*target);
        if (pose.system!=system) {
            const auto& route=convoys.plan(*key).route;
            const auto here=std::find(route.begin(),route.end(),system);
            if (here!=route.end() && std::next(here)!=route.end()) point.connection=*std::next(here);
        }
        return {ActionKind::Follow,std::move(point)};
    }
    if (pose.system!=system) {
        RoutePoint point;
        point.frame=runtime_.frame(pose.frame);
        point.label="Convoy rendezvous";
        return {ActionKind::Plot,std::move(point)};
    }
    return {};
}

void MissionTransport::cancelFollow() { runtime_.combat.convoys().following=false; }

missionui::Snapshot MissionTransport::snapshot(missionui::Page page) {
    using UI=missionui::Input;
    missionui::Snapshot out;
    out.page=page;
    out.message=message_;
    out.location=runtime_.catalog->star(runtime_.location().frame.system).name;
    const auto status=runtime_.status();
    out.subtitle=infinity::xMoney(status.credits)+"  ·  Hold "+std::to_string(status.cargoUnits)+"/"+
                 std::to_string(status.holdCapacity)+"  ·  Fuel "+std::to_string(int(status.fuel))+
                 "/"+std::to_string(int(status.fuelCapacity));
    if (page==missionui::Page::Charters) {
        out.title="Charters";
        out.empty="Find charter work at a station, a city exchange or a crewed ship.";
        const auto rows=charterRows();
        paginate(out,rows.size(),charterSheet_,charterRow_);
        const auto first=out.sheet*rowsPerSheet;
        for (std::size_t i=first;i<std::min(first+rowsPerSheet,rows.size());++i) {
            const auto& row=rows[i];
            if (row.charter) {
                out.rows.push_back({"Sealed parcel",portName(runtime_,row.place),charterState(row.charter->state)});
            } else {
                const auto docked=runtime_.economy.canTrade(runtime_.native(row.place));
                out.rows.push_back({portName(runtime_,row.place),out.location,docked?"Berth secured":"Charter board"});
            }
        }
        const auto& loc=runtime_.location();
        const auto market=localMarket(runtime_);
        out.buttons={{{UI::Interact,0},"Transfer freight",loc.active && loc.aboardDockside,'e'},
                     {{UI::Report,0},"Deliver parcels",bool(market),'r'},
                     {{UI::Auxiliary,0},"Refuel",bool(market),'u'}};
        if (loc.target && trafficContact(runtime_,*loc.target))
            out.buttons.push_back({{UI::Hail,0},"Ask about freight work",true,'i'});
        if (rows.empty()) return out;
        const auto& row=rows[first+charterRow_];
        const auto job=row.charter ? row.charter : offer(row.place);
        const bool claimed=!row.charter && job && runtime_.economy.charterClaimed(job->id);
        const auto heading=portName(runtime_,row.place);
        if (job) {
            out.body=portName(runtime_,job->origin)+" → "+portName(runtime_,job->destination)+"\n"+
                std::to_string(job->units)+" sealed hold units  ·  "+infinity::xMoney(job->reward)+
                "  ·  Deadline day "+std::to_string(job->deadline)+"\n"+
                (row.charter ? charterState(job->state) : claimed ? "Already collected" : "Available at this venue");
        } else {
            out.body=heading+"\nNo charter available from this venue today.";
        }
        out.buttons.insert(out.buttons.begin(),{{UI::Route,0},row.charter?"Plot delivery":"Approach venue",true,0});
        const bool canCollect=!row.charter && job && !claimed &&
                              loc.active && runtime_.economy.canTrade(runtime_.native(row.place));
        out.buttons.push_back({{UI::Primary,0},"Accept charter",canCollect,'a'});
        return out;
    }

    out.title="Convoy Operations";
    out.empty="Hail a convoy, hear its distress call, or dock for the local departures.";
    if (out.message.empty()) out.message=runtime_.combat.convoys().message;
    const auto keys=convoys();
    paginate(out,keys.size(),convoySheet_,convoyRow_);
    const auto first=out.sheet*rowsPerSheet;
    const auto& convoy=runtime_.combat.convoys();
    for (std::size_t i=first;i<std::min(first+rowsPerSheet,keys.size());++i) {
        const auto k=native(keys[i]);const auto& plan=convoy.plan(k);
        out.rows.push_back({"Convoy "+std::to_string(k.service)+"-"+std::to_string(k.cycle%1000),
            runtime_.economy.placeName(plan.origin)+" → "+runtime_.economy.placeName(plan.destination),
            std::string(infinity::convoyPhaseName(convoy.stage(k,runtime_.seconds()).phase))});
    }
    if (keys.empty()) return out;
    const auto k=native(keys[first+convoyRow_]);
    const auto& plan=convoy.plan(k);
    const auto* record=convoy.record(k);
    const auto pose=convoy.stage(k,runtime_.seconds());
    const bool available=record && record->duty==infinity::ConvoyDuty::None &&
                         pose.phase<infinity::ConvoyPhase::Delivered && runtime_.location().active;
    out.body=convoy.summary(k,runtime_.seconds())+"\n"+
             std::string(infinity::xFactionName(plan.faction))+"  ·  Arrival in "+
             countdown(convoy.arrival(k)-runtime_.seconds());
    out.body+="\nRoute  ";
    for (std::size_t i=0;i<plan.route.size();++i) {
        if (i) out.body+=" → ";
        out.body+=runtime_.catalog->star(plan.route[i]).name;
    }
    if (record && record->duty==infinity::ConvoyDuty::Escort)
        out.body+="\nEscort  "+std::to_string(int(record->accompanied))+"/45 s  ·  "+
            (record->claimed?"Report paid":record->betrayed?"Assignment void":"Report at the destination berth");
    if (record && record->duty==infinity::ConvoyDuty::Pirate)
        out.body+="\nPrize marked  ·  Disable the freighter, secure its collar and enter its transfer bay";
    out.buttons={{{UI::Primary,0},"Accept escort",available,'e'},{{UI::Secondary,0},"Mark prize",available,'p'},
                 {{UI::Follow,0},"Follow convoy",pose.phase<infinity::ConvoyPhase::Delivered,'f'},
                 {{UI::Hail,0},"Hail freighter",runtime_.location().frame.system==pose.system,'i'},
                 {{UI::Report,0},"File escort report",convoy.tracked()==k && record && !record->claimed,'r'}};
    const auto goods=std::size_t(plan.good);
    if (const auto stolen=runtime_.combat.stolen()[goods]; stolen>0) {
        const auto market=localMarket(runtime_);
        const auto carried=runtime_.economy.cargo()[goods];
        const auto name=infinity::xGoodInfo(plan.good).name;
        out.body+="\nStolen freight in hold  "+std::to_string(stolen)+" "+std::string(name)+
                  "  ·  Independent or Rebel markets only";
        out.buttons.push_back({{UI::Auxiliary,0},"Sell all "+std::string(name),
            market && runtime_.combat.maySell(*market,plan.good,carried),'s'});
    }
    return out;
}

Action MissionTransport::dispatch(missionui::Page page,missionui::Action input) {
    using UI=missionui::Input;
    const auto view=snapshot(page);
    auto& sheet=page==missionui::Page::Charters ? charterSheet_ : convoySheet_;
    auto& cursor=page==missionui::Page::Charters ? charterRow_ : convoyRow_;
    const auto pageOffset=view.sheet*rowsPerSheet;
    const auto adjust=[&] {
        if (input.kind==UI::NextSheet) sheet=std::min(sheet+1,view.sheetCount-1);
        else if (input.kind==UI::PreviousSheet && sheet>0) --sheet;
        cursor=0;
    };
    if (input.kind==UI::NextSheet || input.kind==UI::PreviousSheet) {
        adjust();
        return {};
    }
    if (input.kind==UI::SelectRow) {
        if (input.value>=0 && std::size_t(input.value)<view.rows.size()) cursor=std::size_t(input.value);
        return {};
    }
    if (page==missionui::Page::Charters) {
        if (input.kind==UI::Report) deliver();
        if (input.kind==UI::Interact) interact();
        if (input.kind==UI::Auxiliary) refuel();
        if (input.kind==UI::Hail && runtime_.location().target) communicate(*runtime_.location().target,true);
        const auto rows=charterRows();
        if (pageOffset+cursor>=rows.size()) return {};
        const auto row=rows[pageOffset+cursor];
        if (input.kind==UI::Route) return runtime_.stationAction(row.place);
        if (input.kind==UI::Primary && !row.charter) accept(row.place);
        return {};
    }
    const auto keys=convoys();
    if (pageOffset+cursor>=keys.size()) return {};
    const auto selected=keys[pageOffset+cursor];
    switch (input.kind) {
    case UI::Primary: join(selected,ConvoyDuty::Escort); break;
    case UI::Secondary: case UI::Mark: join(selected,ConvoyDuty::Pirate); break;
    case UI::Follow: case UI::Route: return follow(selected);
    case UI::Hail: {
        const auto& convoys=runtime_.combat.convoys();
        const auto k=native(selected);
        const auto pose=convoys.stage(k,runtime_.seconds());
        hail(runtime_.actor(convoys.id(k,0,pose.frame)));
        break;
    }
    case UI::Report: report(selected); break;
    case UI::Auxiliary: {
        const auto market=localMarket(runtime_);
        const auto good=runtime_.combat.convoys().plan(native(selected)).good;
        if (market && runtime_.combat.stolen()[std::size_t(good)]>0) {
            auto& economy=runtime_.economy;
            economy.view.place=*market;
            economy.sell(good,economy.cargo()[std::size_t(good)]);
            message_=economy.view.message;
        }
        break;
    }
    default: break;
    }
    return {};
}

} // namespace pelagic::missions
