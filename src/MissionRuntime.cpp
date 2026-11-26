#include "MissionRuntime.hpp"

#include <algorithm>
#include <array>
#include <charconv>
#include <cmath>
#include <ctime>
#include <iomanip>
#include <locale>
#include <map>
#include <sstream>

namespace pelagic::missions {
namespace {
using namespace infinity;

constexpr std::uint32_t ziksa = 14538;
constexpr std::uint64_t phehmyar = 1;
constexpr std::uint64_t xUniverseSeed = 0x58414c4152494101ULL;

glm::dvec3 vector(const Position& p) { return {p[0], p[1], p[2]}; }
Position position(glm::dvec3 p) { return {p.x, p.y, p.z}; }
Orientation orientation(glm::dquat q) { return {q.w, q.x, q.y, q.z}; }

ContactKind contactKind(const ActivityBody& body) {
    if (isInvestigationEvidence(body.id)) return ContactKind::Evidence;
    if (body.kind==ActivityKind::Harbour || body.kind==ActivityKind::SurfacePort) return ContactKind::Station;
    if (body.hostile || body.kind==ActivityKind::Raider) return ContactKind::Hostile;
    if (body.kind==ActivityKind::Freighter || body.kind==ActivityKind::Ferry) return ContactKind::Freight;
    if (body.kind==ActivityKind::Patrol) return ContactKind::Patrol;
    return ContactKind::Other;
}

double currentTime() { return double(std::time(nullptr)); }
} // namespace

NativeRuntime::NativeRuntime(const std::filesystem::path& catalogPath)
    : catalog(std::make_shared<const XalariaCatalog>(catalogPath)),
      universe(xUniverseSeed, catalog), nav(universe), cache(universe),
      controller(universe, nav, cache), pilot(universe, nav, controller),
      economy(universe), course(universe, nav, pilot), combat(universe, economy, pilot),
      stories(economy, *catalog) {
    economy.setStories(&stories);
    economy.setCombat(&combat);
    course.setEconomy(&economy);
    auto system=catalog->stars.contains(ziksa) ? ziksa : catalog->stars.begin()->first;
    location_.frame.system=system;
    if (catalog->star(system).worlds.contains(phehmyar))
        location_.frame.world=phehmyar;
    nav.anchor=native(location_.frame);
    nav.logDistance=nav.targetLogDistance=universe.describe(nav.anchor).frame.logRadius;
    nav.offset={0.,0.,1.};
    pilot.synchronizeFrame();
    location_.eye=position(nav.cameraPosition()*std::pow(10.,nav.logDistance));
    lastFlight_=location_;
    economy.sync(nav,pilot);
    course.selectFromFlight(nav.anchor);
}

Address NativeRuntime::native(const Frame& value) const {
    auto address=catalog->address(value.system);
    if (value.world) address=address.child(Kind::Planet,*value.world);
    return address;
}

ActivityId NativeRuntime::native(const Actor& value) const { return {native(value.frame),value.slot}; }
XPlace NativeRuntime::native(const Place& value) const { return {value.system,value.world,value.station,value.city}; }

Frame NativeRuntime::frame(const Address& value) const {
    Frame result;
    for (const auto segment:value.path) {
        if (segment.kind==Kind::System) result.system=std::uint32_t(segment.id);
        if (segment.kind==Kind::Planet) result.world=segment.id;
    }
    return result;
}

Actor NativeRuntime::actor(const ActivityId& value) const { return {frame(value.home),value.slot}; }
Place NativeRuntime::place(const XPlace& value) const { return {value.system,value.world,value.station,value.city}; }

RoutePoint NativeRuntime::point(const FlightWaypoint& value) const {
    RoutePoint out;
    out.frame=frame(value.reference);
    out.position=position(value.metres);
    out.velocity=position(value.velocity);
    out.standOff=value.standOff;
    out.label=value.label;
    if (value.berth) {
        out.orientation=orientation(value.berth->orientation);
        out.berth=actor(value.berth->id);
        out.berthRadius=value.berth->radius;
        if (const auto port=economy.orbitalPlace(value.berth->id)) out.place=place(*port);
    }
    return out;
}

std::optional<DockingBerth> NativeRuntime::berth(const Actor& id) const {
    const auto target=native(id);
    if (const auto port=economy.orbitalPlace(target)) {
        if (!combat.permits(*port)) return {};
        return dockingBerth(economy.portBody(*port,seconds_));
    }
    const auto traffic=xalariaVesselApproach(economy,target,course.view.wormhole,seconds_);
    return traffic ? traffic->berth : std::nullopt;
}

void NativeRuntime::synchronize(const PlayerLocation& incoming) {
    if (!incoming.active) {
        if (location_.active) {
            pilot.docking_.cancel();
            pilot.waypoint_.reset();
            pilot.ship_.landed=pilot.instruments_.landed=false;
            pilot.instruments_.docking={};
            economy.sync(nav,pilot);
        }
        location_.active=false;
        location_.inTransit=true;
        location_.landed=location_.docking=location_.aboardDockside=false;
        location_.clamped.reset();
        return;
    }
    const auto system=catalog->stars.find(incoming.frame.system);
    if (system==catalog->stars.end() ||
        (incoming.frame.world && !system->second.worlds.contains(*incoming.frame.world))) return;
    const auto eye=vector(incoming.eye);
    const auto velocity=vector(incoming.velocity);
    const auto& axes=incoming.orientation;
    auto attitude=glm::dquat(axes[0],axes[1],axes[2],axes[3]);
    if (!std::isfinite(glm::length(eye)) || !std::isfinite(glm::length(velocity)) ||
        !std::isfinite(glm::length(attitude)) || glm::length(attitude)<1.e-8) return;
    attitude=glm::normalize(attitude);
    const auto newFrame=native(incoming.frame);
    const bool switchedSystem=location_.frame.system!=incoming.frame.system;
    location_=incoming;
    location_.orientation=orientation(attitude);
    nav.anchor=newFrame;
    if (pilot.ship_.frame!=newFrame)
        nav.logDistance=nav.targetLogDistance=universe.describe(newFrame).frame.logRadius;
    nav.orientation=attitude;
    nav.offset=eye/std::pow(10.,nav.logDistance)-attitude*glm::dvec3(0.,0.,1.);
    nav.transitioning=false;
    pilot.ship_.frame=newFrame;
    pilot.ship_.positionResidual={};
    pilot.ship_.velocity=velocity;
    location_.landed=incoming.landed && incoming.frame.world && hasSolidSurface(universe.describe(newFrame));
    pilot.ship_.landed=pilot.ship_.gear=pilot.instruments_.landed=location_.landed;
    if (location_.landed) {
        pilot.landingPlanet_=newFrame;
        pilot.landingDirection_=glm::length(eye)>1.e-8 ? glm::normalize(eye) : glm::dvec3(0.,1.,0.);
    } else {
        pilot.landingPlanet_.reset();
    }
    pilot.instruments_.warp=incoming.inTransit ? WarpPhase::Route : WarpPhase::Off;
    if (incoming.clamped && incoming.clamped->frame==incoming.frame && !incoming.inTransit && !location_.landed) {
        if (auto target=berth(*incoming.clamped)) {
            // A confirmed host clamp uses the native berth and readout. A target
            // undergoing combat interdiction cannot silently become an open berth.
            DockingReadout accepted;
            accepted.available=true;
            pilot.docking_.resumeClamp(accepted);
            pilot.waypoint_=FlightWaypoint{target->id.home,target->metres,target->velocity,0.,"",false,target};
            pilot.instruments_.docking.phase=DockingPhase::Docked;
            pilot.instruments_.docking.docked=pilot.instruments_.docking.active=true;
        } else {
            location_.clamped.reset();
        }
    } else {
        location_.clamped.reset();
    }
    if (!location_.clamped) {
        location_.aboardDockside=false;
        if (pilot.clampedHarbour()) {
            pilot.docking_.cancel();
            pilot.waypoint_.reset();
        }
        pilot.instruments_.docking={};
        pilot.instruments_.docking.active=incoming.docking;
    }
    if (incoming.target && incoming.target->frame.system==incoming.frame.system)
        combat.target=native(*incoming.target);
    economy.sync(nav,pilot);
    if (switchedSystem) course.selectFromFlight(newFrame);
    course.view.current=incoming.frame.system;
    course.view.currentWorld=incoming.frame.world;
    lastFlight_=location_;
}

StoryContext NativeRuntime::storyContext() const {
    StoryContext context;
    context.system=economy.currentSystem();
    const bool normal=location_.active && !location_.inTransit && !location_.landed && pilot.ship().hull>0.;
    if (normal && economy.nearOrbit()) context.orbit=economy.currentWorld();
    context.stellarOrbit=normal;
    if (location_.active && location_.aboardDockside && pilot.clampedHarbour()) {
        context.boardedStation=economy.dockedPlace();
        if (isXalariaTraffic(*pilot.clampedHarbour())) context.boardedVessel=*pilot.clampedHarbour();
    }
    return context;
}

CombatPlayer NativeRuntime::combatPlayer() const {
    CombatPlayer player;
    player.frame=nav.anchor;
    player.position=nav.cameraPosition()*std::pow(10.,nav.logDistance);
    player.velocity=pilot.ship().velocity;
    player.orientation=nav.orientation;
    player.forward=nav.orientation*glm::dvec3(0.,0.,-1.);
    player.seconds=seconds_;
    player.sheltered=!location_.active || location_.landed || bool(pilot.clampedHarbour());
    player.transit=!location_.active || location_.inTransit || pilot.ship().hull<=0.;
    player.weaponsInhibited=location_.aboardDockside || location_.docking || bool(pilot.clampedHarbour());
    if (const auto* target=pilot.clampedHarbour()) player.clamped=*target;
    player.gate=course.view.wormhole;
    return player;
}

void NativeRuntime::advance(const PlayerLocation& where,double dt) {
    synchronize(where);
    if (!std::isfinite(dt) || dt<=0.) return;
    dt=std::min(dt,.25);
    if (location_.active) economy.useManualFuel(dt,location_.thrust,location_.manualWarp);
    economy.advance(dt);
    pilot.setCargoMass(economy.cargoKg());
    double remaining=dt;
    while (remaining>1.e-8) {
        const double tick=std::min(remaining,.1);
        combat.advance(combatPlayer(),tick);
        seconds_+=tick;
        pilot.ship_.flightSeconds=seconds_;
        remaining-=tick;
    }
    stories.advance(seconds_);
    stories.observe(storyContext(),seconds_,dt);
    economy.expireTrafficRecovery(seconds_);
}

FlightStatus NativeRuntime::status() const {
    const bool incoming=location_.active && !combat.incomingFire.empty() && seconds_-combat.incomingAt<3.;
    return {pilot.ship().hull,economy.fuel(),economy.fuelCapacity(),economy.credits(),
            economy.cargoUnits(),economy.holdCapacity(),economy.technology(),economy.culture(),
            incoming,incoming ? combat.incomingFire : std::string{}};
}

bool NativeRuntime::fire() {
    return location_.active && combat.fire(combatPlayer());
}

bool NativeRuntime::hearStory(const infinity::XalariaTrafficContact& contact) {
    if (const auto rumor=stories.hear(contact,seconds_)) {
        heardStory_=std::pair{actor(contact.body.id),*rumor};
        return true;
    }
    return false;
}

std::optional<infinity::StoryKey> NativeRuntime::heardStory(const Actor& source) const {
    if (heardStory_ && heardStory_->first==source) return heardStory_->second;
    return {};
}

std::vector<Contact> NativeRuntime::contacts() const {
    if (!location_.active || location_.inTransit) return {};
    auto nearby=combat.localBodies(combatPlayer());
    auto evidence=stories.evidenceBodies(nav.anchor);
    nearby.insert(nearby.end(),std::make_move_iterator(evidence.begin()),std::make_move_iterator(evidence.end()));
    std::map<Actor,Contact> indexed;
    for (const auto& body:nearby) {
        const auto id=actor(body.id);
        std::optional<Place> port;
        if (const auto nativePort=economy.orbitalPlace(body.id)) port=place(*nativePort);
        const bool canDock=port ? bool(dockingBerth(body)) && combat.permits(native(*port)) :
            isXalariaTraffic(body.id) && bool(xalariaVesselBerth(body)) && combat.mayDock(body);
        indexed.try_emplace(id,Contact{id,position(body.position),position(body.velocity),orientation(body.orientation),
              body.radius,body.hull,contactKind(body),canDock,body.disabled,body.name,body.status,port});
    }
    std::vector<Contact> result;
    result.reserve(indexed.size());
    for (auto& entry:indexed) result.push_back(std::move(entry.second));
    return result;
}

Action NativeRuntime::stationAction(const Place& port) const {
    const auto system=catalog->stars.find(port.system);
    if (system==catalog->stars.end() || !system->second.worlds.contains(port.world)) return {};
    RoutePoint destination;
    destination.frame={port.system,port.world};
    destination.place=port;
    const auto venue=native(port);
    const auto venues=economy.venues(port.system,port.world);
    if (std::find(venues.begin(),venues.end(),venue)==venues.end()) return {};
    destination.label=economy.placeName(venue);
    if (!location_.active || location_.frame.system!=port.system ||
        economy.currentWorld()!=port.world || !economy.nearOrbit())
        return {ActionKind::Plot,destination};
    if (port.city) {
        if (location_.landed) return {};
        const auto world=universe.describe(native(destination.frame));
        if (!hasSolidSurface(world)) return {};
        const auto eye=combatPlayer().position;
        const auto direction=glm::length(eye)>1.e-8 ? glm::normalize(eye) : glm::dvec3(0.,1.,0.);
        const auto radius=std::pow(10.,world.frame.logRadius)+universe.terrainHeight(world,direction);
        destination.position=position(direction*radius);
        return {ActionKind::Land,destination};
    }
    const auto id=economy.orbitalStationId(venue);
    const auto target=id ? berth(actor(*id)) : std::nullopt;
    if (!target) return {};
    const FlightWaypoint approach{target->id.home,target->metres,target->velocity,0.,destination.label,false,target};
    return {ActionKind::Dock,point(approach)};
}

Action NativeRuntime::vesselAction(const Actor& target) const {
    if (!location_.active || location_.frame.system!=target.frame.system) return {};
    const auto approach=xalariaVesselApproach(economy,native(target),course.view.wormhole,seconds_);
    if (approach) return {ActionKind::Dock,point(*approach)};
    return {};
}

Action NativeRuntime::currentPoseAction() const {
    RoutePoint result;
    const auto p=combatPlayer();
    result.frame=frame(p.frame);
    result.position=position(p.position);
    result.velocity=position(p.velocity);
    result.orientation=orientation(p.orientation);
    result.label="Emergency recovery";
    return {ActionKind::Recover,std::move(result)};
}

std::optional<RoutePoint> NativeRuntime::resumeDock(const PlayerLocation& where) const {
    if (!where.clamped || where.clamped->frame!=where.frame || !catalog->stars.contains(where.frame.system) ||
        (where.frame.world && !catalog->star(where.frame.system).worlds.contains(*where.frame.world))) return {};
    const auto target=berth(*where.clamped);
    if (!target) return {};
    const auto& q=where.orientation;
    const auto readout=dockingReadout(*target,vector(where.eye),vector(where.velocity),glm::dquat(q[0],q[1],q[2],q[3]));
    const bool vessel=target->vessel();
    if (!(readout.range<(vessel?10.:2.5) && readout.relativeSpeed<(vessel?8.:.85) &&
          readout.heading<(vessel?.25:.10) && std::abs(readout.roll)<(vessel?.25:.10))) return {};
    const auto port=economy.orbitalPlace(target->id);
    const auto label=port ? economy.placeName(*port) : std::string{"Vessel transfer bay"};
    return point(FlightWaypoint{target->id.home,target->metres,target->velocity,0.,label,false,target});
}

std::string NativeRuntime::serialize() const {
    std::ostringstream out;
    out.imbue(std::locale::classic());
    out<<"PELAGIC_XALARIA_MISSIONS 2 "<<std::quoted(catalog->fingerprint);
    for (const auto& item:std::array{nav.serialize(),pilot.serialize(),course.serialize(),
          economy.serialize(std::int64_t(currentTime())),stories.serialize(),combat.serialize(),
          economy.serializeTraffic(seconds_),combat.convoys().serialize(),combat.strategy().serialize()})
        out<<' '<<std::quoted(item);
    const auto dock=resumeDock(lastFlight_);
    out<<' '<<lastFlight_.landed<<' '<<bool(dock && lastFlight_.aboardDockside)<<' '
       <<std::quoted(dock && dock->berth ? native(*dock->berth).str() : std::string{});
    return out.str();
}

bool NativeRuntime::restore(std::string_view ledger) {
    if (ledger.empty()) return true;
    if (ledger.size()>64u*1024u*1024u) return false;
    std::istringstream in{std::string(ledger)};
    in.imbue(std::locale::classic());
    std::string label,fingerprint;
    unsigned version{};
    std::array<std::string,9> records;
    if (!(in>>label>>version>>std::quoted(fingerprint)) || label!="PELAGIC_XALARIA_MISSIONS" ||
        (version!=1 && version!=2) || fingerprint!=catalog->fingerprint) return false;
    for (auto& record:records) if (!(in>>std::quoted(record))) return false;
    bool landed{},aboard{};
    std::optional<Actor> clamp;
    if (version==2) {
        std::string id;
        if (!(in>>landed>>aboard>>std::quoted(id)) || (landed && !id.empty()) || (aboard && id.empty())) return false;
        if (!id.empty()) {
            constexpr std::string_view activityTag="@activity1:";
            const auto separator=id.rfind(activityTag);
            if (separator==std::string::npos) return false;
            std::uint32_t slot{};
            const auto end=id.data()+id.size();
            const auto parsed=std::from_chars(id.data()+separator+activityTag.size(),end,slot);
            if (parsed.ec!=std::errc{} || parsed.ptr!=end) return false;
            try { clamp=Actor{frame(Address::parse(id.substr(0,separator))),slot}; }
            catch (const std::exception&) { return false; }
        }
    }
    if ((in>>std::ws).peek()!=std::char_traits<char>::eof()) return false;

    const std::array backup{nav.serialize(),pilot.serialize(),course.serialize(),economy.serialize(),
        stories.serialize(),combat.serialize(),economy.serializeTraffic(seconds_),
        combat.convoys().serialize(),combat.strategy().serialize()};
    const bool wasFollowing=combat.convoys().following;
    const auto apply=[&](const auto& state) {
        if (!nav.restore(state[0]) || !pilot.restore(state[1]) || !economy.restore(state[3]) ||
            !stories.restore(state[4])) return false;
        seconds_=pilot.ship().flightSeconds;
        if (!combat.restore(state[5],seconds_) || !economy.restoreTraffic(state[6],seconds_) ||
            !combat.convoys().restore(state[7],seconds_) || !combat.strategy().restore(state[8],seconds_) ||
            !course.restore(state[2])) return false;
        return true;
    };
    if (!apply(records)) {
        apply(backup);
        combat.convoys().following=wasFollowing;
        if (location_.active) synchronize(location_);
        return false;
    }
    stories.advance(seconds_);
    economy.catchUp(std::int64_t(currentTime()));
    economy.sync(nav,pilot);
    const auto p=combatPlayer();
    location_.frame=frame(p.frame);
    location_.eye=position(p.position);
    location_.velocity=position(p.velocity);
    location_.orientation=orientation(p.orientation);
    location_.forward=position(p.forward);
    location_.active=false;
    location_.inTransit=true;
    location_.docking=false;
    location_.target.reset();
    location_.landed=(landed || pilot.ship().landed) && location_.frame.world &&
        glm::length(p.velocity)<2. && hasSolidSurface(universe.describe(p.frame));
    location_.clamped=clamp;
    if (!resumeDock(location_)) location_.clamped.reset();
    location_.aboardDockside=location_.clamped && aboard;
    pilot.ship_.landed=pilot.instruments_.landed=false;
    economy.sync(nav,pilot);
    lastFlight_=location_;
    heardStory_.reset();
    return true;
}

} // namespace pelagic::missions
