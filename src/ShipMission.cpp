#include "ShipFlight.hpp"
#include "MissionDispatch.hpp"
#include "XalariaTerrain.hpp"

#include <algorithm>
#include <cmath>
#include <limits>
#include <numbers>

namespace pelagic {
namespace {

using Point = simd_double3;
using missions::ActionKind;

constexpr double tau = 2.*std::numbers::pi;
constexpr double hullRadius = 6.;
constexpr double surfaceEntryHeight = 1500.;

Point vector(const missions::Position& p) { return {p[0],p[1],p[2]}; }
missions::Position position(Point p) { return {p.x,p.y,p.z}; }
simd_quatd attitude(const missions::Orientation& q) { return simd_quaternion(q[1],q[2],q[3],q[0]); }

bool finite(const missions::Position& p) { return std::ranges::all_of(p,[](double a){return std::isfinite(a);}); }
bool valid(const missions::RoutePoint& p) {
    return finite(p.position) && finite(p.velocity) && std::isfinite(p.standOff) && p.standOff>=0. &&
           std::isfinite(simd_length(attitude(p.orientation).vector)) &&
           std::abs(simd_length(attitude(p.orientation).vector)-1.)<1.e-5;
}

Point limited(Point v,double cap) {
    const double length=simd_length(v);
    return length>cap ? v*(cap/length) : v;
}

bool isVessel(const missions::RoutePoint& p) {
    return p.berth && (p.berth->slot&0xb0000000u)!=0;
}

double dockingLane(const missions::RoutePoint& p) {
    return isVessel(p) ? std::clamp(p.berthRadius*1.45,55.,115.) : std::max(600.,p.berthRadius*3.);
}

Point localCorridor(const missions::RoutePoint& p) { return {0.,0.,dockingLane(p)}; }

std::pair<double,double> dockingAngles(simd_quatd from,simd_quatd target) {
    const auto relative=simd_mul(simd_inverse(from),target);
    const auto forward=simd_act(relative,Point{0.,0.,-1.});
    const auto up=simd_act(relative,Point{0.,1.,0.});
    return {std::acos(std::clamp(-forward.z,-1.,1.)),std::atan2(up.x,up.y)};
}

bool settledAtBerth(double range,double velocity,double heading,double roll,bool vessel) {
    return range<(vessel ? 1.9 : .45) && velocity<(vessel ? 2.4 : .18) &&
           heading<(vessel ? .105 : .035) && std::abs(roll)<(vessel ? .11 : .045);
}

} // namespace

void ShipFlight::bindMissionWorlds(std::span<const missions::DispatchWorld> worlds) {
    if (region_) return;
    for (unsigned i=1; i<bodyCount_; ++i) {
        const auto world=std::ranges::find(worlds,bodyNames_[i],&missions::DispatchWorld::name);
        if (world!=worlds.end()) missionWorldIds_[i]=world->id;
    }
}

std::optional<unsigned> ShipFlight::missionBody(std::optional<uint64_t> world) const {
    if (region_) return {};
    if (!world) return 0u;
    for (unsigned i=1; i<bodyCount_; ++i) if (missionWorldIds_[i]==world) return i;
    return {};
}

bool ShipFlight::exposeMissionWorld(uint64_t id,std::span<const missions::DispatchWorld> worlds) {
    if (region_) return false;
    bindMissionWorlds(worlds);
    if (missionBody(id)) return true;
    ShipFlight updated(*this);
    const auto install=[&](auto&& self,uint64_t requested,unsigned depth) -> std::optional<unsigned> {
        if (depth>=ziksaBodyCount) return {};
        if (const auto existing=updated.missionBody(requested)) return existing;
        const auto world=std::ranges::find(worlds,requested,&missions::DispatchWorld::id);
        if (world==worlds.end() || world->name.empty() || !(world->radius>0.) || !(world->distance>0.) ||
            world->period<0. || !std::isfinite(world->radius+world->distance+world->period+
                                               world->tilt+world->tiltRotation+world->temperature+world->clouds))
            return {};
        const auto parent=world->primary ? self(self,*world->primary,depth+1) : std::optional<unsigned>{};
        if (world->primary && !parent) return {};
        const auto primaryCount=std::count_if(updated.orbits_.begin()+1,updated.orbits_.begin()+updated.bodyCount_,
                                              [](const PhysicalOrbit& orbit){return orbit.parent<0;});
        unsigned slot=unsigned(updated.bodyCount_);
        if (slot>=ziksaBodyCount || (!parent && primaryCount>=systemPlanetLimit)) {
            while (slot>1) {
                --slot;
                if (slot==updated.target_ || slot==updated.localFrame_ || slot==parent ||
                    (!parent && updated.orbits_[slot].parent>=0) ||
                    (parent && updated.orbits_[slot].parent<0))
                    continue;
                const bool dependent=std::any_of(updated.orbits_.begin()+1,updated.orbits_.begin()+updated.bodyCount_,
                                                [&](const PhysicalOrbit& orbit){return orbit.parent==int(slot);});
                if (!dependent) break;
            }
            if (!slot || slot==updated.target_ || slot==updated.localFrame_ || slot==parent ||
                (bool(parent)!=(updated.orbits_[slot].parent>=0)) ||
                std::any_of(updated.orbits_.begin()+1,updated.orbits_.begin()+updated.bodyCount_,
                            [&](const PhysicalOrbit& orbit){return orbit.parent==int(slot);}))
                return {};
        }
        const double phase=world->period>0. ? std::fmod(1700000000./world->period,1.)*tau : 0.;
        updated.orbits_[slot]={world->radius,world->distance,world->period>0. ? tau/world->period : 0.,
                               phase,world->tilt,world->tiltRotation,parent ? int(*parent) : -1};
        auto& body=updated.bodies_[slot];
        body={};
        body.appearance=world->appearance;
        const auto& low=body.appearance.dark;
        const auto& high=body.appearance.light;
        body.colour={std::lerp(low.x,high.x,.54f),std::lerp(low.y,high.y,.54f),
                     std::lerp(low.z,high.z,.54f),float(world->temperature)};
        body.surface=physicalSurface(world->gas ? 1.f : 0.f,float(world->clouds),world->radius,body.appearance);
        updated.bodyNames_[slot]=world->name;
        updated.missionWorldIds_[slot]=world->id;
        if (slot==updated.bodyCount_) ++updated.bodyCount_;
        return slot;
    };
    if (!install(install,id,0)) return false;
    const double previousScale=metresPerUnit_, previousLimit=flightLimit_;
    updated.setFlightScale();
    updated.metresPerUnit_=std::max(previousScale,updated.metresPerUnit_);
    updated.flightLimit_=std::max(previousLimit,updated.flightLimit_);
    updated.updateOrbits();
    *this=std::move(updated);
    return true;
}

std::optional<uint64_t> ShipFlight::targetMissionWorld() const {
    return region_ || target_>=bodyCount_ ? std::nullopt : missionWorldIds_[target_];
}

bool ShipFlight::selectMissionWorld(std::optional<uint64_t> world) {
    const auto body=missionBody(world);
    if (!body) return false;
    cancelMissionApproach();
    target_=*body;
    warpNotice_=0.;
    return true;
}

std::optional<uint64_t> ShipFlight::missionOrbit() const {
    std::optional<uint64_t> result;
    double nearest=std::numeric_limits<double>::infinity();
    for (unsigned i=1; i<bodyCount_; ++i) {
        if (!missionWorldIds_[i]) continue;
        const double distance=simd_length(position_-centres_[i]);
        const double radius=orbits_[i].radius;
        if (distance<=6.*radius && distance-radius<nearest) {
            nearest=distance-radius;
            result=missionWorldIds_[i];
        }
    }
    return result;
}

Point ShipFlight::relativeVelocity(unsigned body) const {
    return velocity_+orbitVector(unsigned(localFrame_.value_or(0)),true)-orbitVector(body,true);
}

missions::PlayerLocation ShipFlight::missionLocation(std::optional<missions::Frame> reference) const {
    missions::PlayerLocation local{};
    local.frame.system=systemId();
    if (region_) return local;
    const auto orbit=missionOrbit();
    local.frame.world=orbit;
    if (missionApproach_) {
        const auto& approach=*missionApproach_;
        if (approach.phase==MissionDockPhase::Clamped) {
            local.clamped=approach.point.berth;
            local.landed=approach.kind==ActionKind::Land;
            local.aboardDockside=approach.aboard;
            local.frame=approach.point.frame;
        } else local.docking=approach.kind==ActionKind::Dock;
    }
    if (reference) {
        if (reference->system!=systemId()) return {};
        local.frame=*reference;
    }
    const auto body=missionBody(local.frame.world);
    if (!body) return {};
    local.active=true;
    local.inTransit=warp_;
    local.nearOrbit=local.frame.world && local.frame.world==orbit;
    local.thrust=missionApproach_ ? throttle_ : simd_length(thrusters_);
    local.manualWarp=warp_ && !missionApproach_;
    local.eye=position(position_-centres_[*body]);
    local.velocity=position(relativeVelocity(*body));
    local.forward=position(simd_act(attitude_,Point{0.,0.,-1.}));
    local.orientation={attitude_.vector.w,attitude_.vector.x,attitude_.vector.y,attitude_.vector.z};
    return local;
}

std::optional<Quad> ShipFlight::missionRenderPoint(missions::Frame frame,missions::Position p,
                                                  double physicalRadius) const {
    if (frame.system!=systemId() || !finite(p) || !std::isfinite(physicalRadius) || physicalRadius<0.) return {};
    const auto body=missionBody(frame.world);
    if (!body) return {};
    const auto point=(centres_[*body]-position_+vector(p))/metresPerUnit_;
    return Quad{float(point.x),float(point.y),float(point.z),float(physicalRadius/metresPerUnit_)};
}

Point ShipFlight::missionCoursePosition() const {
    const auto& approach=*missionApproach_;
    const auto body=missionBody(approach.point.frame.world).value_or(0);
    const auto& p=approach.point;
    if (approach.kind==ActionKind::Land) return centres_[body]+approach.surfaceOffset;
    return centres_[body]+vector(p.position)+vector(p.velocity)*std::clamp(time_-approach.sampleTime,0.,.25);
}

Point ShipFlight::warpCentre() const {
    if (!missionApproach_) return contact(unsigned(target_)).centre;
    const auto goal=missionCoursePosition();
    const auto& p=missionApproach_->point;
    if (missionApproach_->kind==ActionKind::Land)
        return goal+simd_normalize(missionApproach_->surfaceOffset)*surfaceEntryHeight;
    return missionApproach_->kind==ActionKind::Dock ? goal+simd_act(attitude(p.orientation),localCorridor(p)) : goal;
}

Point ShipFlight::missionSurfacePoint(unsigned body,Point direction) const {
    const auto unit=simd_normalize(direction);
    const double terrainHeight=terrain_ ? terrain_->surfaceHeight(systemId(),bodyNames_[body],
                               {float(unit.x),float(unit.y),float(unit.z)}) : 0.;
    return unit*(orbits_[body].radius*(1.+terrainHeight)+hullRadius+.035);
}

bool ShipFlight::clearMissionLeg(Point destination) const {
    if (simd_length(destination)>flightLimit_-hullRadius) return false;
    const auto delta=destination-position_;
    const double length=simd_length_squared(delta);
    if (length<1.e-12) return true;
    for (unsigned i=0; i<bodyCount_; ++i) {
        const auto body=surfaceContact(i);
        const auto relative=body.centre-position_;
        const double along=std::clamp(simd_dot(relative,delta)/length,0.,1.);
        if (simd_length(relative-delta*along)<body.radius+hullRadius-.001) return false;
    }
    return true;
}

bool ShipFlight::beginMissionApproach(const missions::RoutePoint& p,ActionKind kind) {
    if (region_ || p.frame.system!=systemId() || !valid(p) ||
        (kind!=ActionKind::Approach && kind!=ActionKind::Dock && kind!=ActionKind::Follow && kind!=ActionKind::Land) ||
        (kind==ActionKind::Dock && (!p.berth || p.berth->frame!=p.frame ||
                                  !(p.berthRadius>0.) || !std::isfinite(p.berthRadius))) ||
        (missionApproach_ && missionApproach_->phase==MissionDockPhase::Clamped))
        return false;
    const auto body=missionBody(p.frame.world);
    if (!body) return false;
    Point destination=vector(p.position);
    Point surface{};
    if (kind==ActionKind::Land) {
        if (*body==0 || bodies_[*body].surface.x>.5f || simd_length(destination)<1.) return false;
        surface=missionSurfacePoint(*body,destination);
        destination=surface+simd_normalize(surface)*surfaceEntryHeight;
    } else if (kind==ActionKind::Dock) destination+=simd_act(attitude(p.orientation),localCorridor(p));
    const auto goal=centres_[*body]+destination;
    if (simd_length(goal)>flightLimit_-hullRadius) return false;
    const double jump=simd_length(goal-position_)-(kind==ActionKind::Dock ? 0. : p.standOff);
    if (jump>100000. && !warpAvailable()) return false;
    cancelMissionApproach();
    target_=*body;
    warpNotice_=0.;
    missionApproach_=MissionApproach{.point=p,.kind=kind,.sampleTime=time_,.surfaceOffset=surface,.bypass={}};
    if (jump>100000.) startWarp();
    else {
        velocity_=relativeVelocity(*body);
        localFrame_=*body;
    }
    return true;
}

bool ShipFlight::refreshMissionApproach(const missions::RoutePoint& p) {
    if (!missionApproach_ || missionApproach_->point.frame!=p.frame ||
        missionApproach_->point.berth!=p.berth || !valid(p))
        return false;
    auto& active=*missionApproach_;
    if (active.kind==ActionKind::Dock && (!std::isfinite(p.berthRadius) || !(p.berthRadius>0.))) return false;
    active.point=p;
    active.sampleTime=time_;
    return true;
}

bool ShipFlight::setMissionAboard(bool aboard) {
    if (!missionApproach_ || missionApproach_->kind!=ActionKind::Dock ||
        missionApproach_->phase!=MissionDockPhase::Clamped) return false;
    missionApproach_->aboard=aboard;
    return true;
}

bool ShipFlight::leaveMissionDock() {
    if (!missionApproach_ || missionApproach_->phase!=MissionDockPhase::Clamped || missionApproach_->aboard)
        return false;
    missionApproach_->phase=MissionDockPhase::Departure;
    return true;
}

void ShipFlight::cancelMissionApproach() {
    if (missionApproach_ && missionApproach_->phase==MissionDockPhase::Clamped) return;
    cancelWarp();
    missionApproach_.reset();
}

bool ShipFlight::enterMissionPose(const missions::Frame& frame,missions::Position eye,
                                  missions::Orientation attitudeValue,missions::Position velocity) {
    const auto body=missionBody(frame.world);
    const auto orientation=attitude(attitudeValue);
    if (!body || frame.system!=systemId() || !finite(eye) || !finite(velocity) ||
        !std::isfinite(simd_length(orientation.vector)) || std::abs(simd_length(orientation.vector)-1.)>1.e-5)
        return false;
    const auto destination=centres_[*body]+vector(eye);
    if (simd_length(destination)>flightLimit_-hullRadius) return false;
    for (unsigned i=0;i<bodyCount_;++i) {
        const auto obstacle=surfaceContact(i,destination);
        if (simd_distance(destination,obstacle.centre)<obstacle.radius+hullRadius) return false;
    }
    cancelWarp();
    missionApproach_.reset();
    position_=destination;
    velocity_=vector(velocity);
    attitude_=simd_normalize(orientation);
    localFrame_=*body;
    target_=*body;
    spin_=thrusters_=rcs_=headShift_=headLean_=leanVelocity_=shiftVelocity_={};
    engine_=boundaryLoad_=lookYaw_=lookPitch_=throttle_=boost_=warpVisual_=warpNotice_=0.;
    return true;
}

bool ShipFlight::restoreMissionDock(const missions::RoutePoint& p,bool aboard) {
    const auto body=missionBody(p.frame.world);
    if (!body || p.frame.system!=systemId() || !valid(p) || !p.berth || p.berth->frame!=p.frame ||
        !(p.berthRadius>0.) || !std::isfinite(p.berthRadius)) return false;
    const auto dock=attitude(p.orientation);
    const auto berth=centres_[*body]+vector(p.position);
    const auto [heading,roll]=dockingAngles(attitude_,dock);
    if (!settledAtBerth(simd_distance(position_,berth),simd_distance(relativeVelocity(*body),vector(p.velocity)),
                         heading,roll,isVessel(p))) return false;
    cancelWarp();
    localFrame_=target_=*body;
    position_=berth;
    velocity_=vector(p.velocity);
    attitude_=dock;
    missionApproach_=MissionApproach{.point=p,.kind=ActionKind::Dock,.phase=MissionDockPhase::Clamped,
                                     .sampleTime=time_,.bypass={},.aboard=aboard};
    return true;
}

bool ShipFlight::restoreMissionLanding(const missions::PlayerLocation& saved) {
    const auto body=missionBody(saved.frame.world);
    if (!body || !*body || saved.frame.system!=systemId() || !saved.landed ||
        bodies_[*body].surface.x>.5f || simd_length(relativeVelocity(*body))>=2.) return false;
    const auto offset=position_-centres_[*body];
    if (simd_length(offset)<1.) return false;
    const auto surface=missionSurfacePoint(*body,offset);
    if (simd_distance(offset,surface)>.25 || simd_dot(simd_normalize(surface),simd_act(attitude_,Point{0.,1.,0.}))<.9664)
        return false;
    cancelWarp();
    localFrame_=target_=*body;
    position_=centres_[*body]+surface;
    velocity_={};
    const missions::RoutePoint p{.frame=saved.frame,.position=position(surface),.label=bodyName(*body)};
    missionApproach_=MissionApproach{.point=p,.kind=ActionKind::Land,.phase=MissionDockPhase::Clamped,
                                     .sampleTime=time_,.surfaceOffset=surface,.bypass={}};
    return true;
}

Point ShipFlight::missionLandingVelocity(double dt,Point surface) {
    auto& active=*missionApproach_;
    const auto up=simd_normalize(active.surfaceOffset);
    const auto offset=position_-surface;
    const double altitude=simd_dot(offset,up);
    const auto crossTrack=offset-up*altitude;
    const auto upNow=simd_act(attitude_,Point{0.,1.,0.});
    const auto alignment=simd_quaternion(upNow,up);
    attitude_=simd_normalize(simd_mul(simd_slerp(simd_quaternion(0.,0.,0.,1.),alignment,
                                               1.-std::exp(-dt*3.5)),attitude_));
    switch (active.phase) {
    case MissionDockPhase::Arrival: {
        const auto delta=surface+up*surfaceEntryHeight-position_;
        if (simd_length(delta)<3. && simd_length(velocity_)<2.) active.phase=MissionDockPhase::Align;
        return limited(delta*.28,200.);
    }
    case MissionDockPhase::Align:
        if (simd_dot(up,upNow)>.997) active.phase=MissionDockPhase::Glide;
        return limited((surface+up*surfaceEntryHeight-position_)*.28,8.);
    case MissionDockPhase::Glide:
        if (altitude<38.) active.phase=MissionDockPhase::Capture;
        return limited(-crossTrack*.5,8.)-up*std::clamp((altitude-26.)*.18,1.25,44.);
    case MissionDockPhase::Capture:
        if (altitude<.09 && simd_length(crossTrack)<.35 && simd_length(velocity_)<2. &&
            simd_dot(up,upNow)>.9664) active.phase=MissionDockPhase::Clamped;
        return limited(-crossTrack*.55,.6)-up*std::clamp(altitude*.5,-1.5,1.5);
    case MissionDockPhase::Clamped: return {};
    case MissionDockPhase::Departure:
        if (altitude>60.) missionApproach_.reset();
        return up*18.;
    }
    return {};
}

void ShipFlight::integrateMission(double dt) {
    auto& active=*missionApproach_;
    const auto berth=missionCoursePosition();
    const auto& p=active.point;
    const auto baseVelocity=vector(p.velocity);
    const auto orientation=attitude(p.orientation);
    const auto rotateTo=[&](simd_quatd q) {
        attitude_=simd_normalize(simd_slerp(attitude_,q,1.-std::exp(-dt*3.5)));
    };
    const auto toPoint=[&](Point goal) {
        const auto from=attitude_;
        aimAt(goal);
        const auto toward=attitude_;
        attitude_=from;
        rotateTo(toward);
    };
    Point wanted{};
    if (active.kind==ActionKind::Land) {
        wanted=missionLandingVelocity(dt,berth);
        if (missionApproach_ && missionApproach_->phase==MissionDockPhase::Clamped) {
            position_=berth;
            velocity_=thrusters_={};
            engine_=throttle_=0.;
            return;
        }
    } else if (active.kind!=ActionKind::Dock) {
        const auto offset=berth-position_;
        const double range=simd_length(offset);
        const double gap=std::max(0.,range-p.standOff);
        if (range>1.) toPoint(berth);
        wanted=baseVelocity+(range>1.e-6 ? offset/range : Point{})*
                           std::min({1600.,std::sqrt(gap*18.),gap*.65});
        if (active.kind==ActionKind::Approach && gap<.25 && simd_length(velocity_-baseVelocity)<.6) {
            missionApproach_.reset();
            warpBlocked_=false;
            warpNotice_=3.2;
            return;
        }
    } else if (active.phase==MissionDockPhase::Clamped) {
        position_=berth;
        velocity_=baseVelocity;
        attitude_=orientation;
        return;
    } else {
        const auto inverse=simd_inverse(orientation);
        const auto offset=simd_act(inverse,position_-berth);
        const double range=simd_length(offset);
        const double relativeSpeed=simd_length(velocity_-baseVelocity);
        const auto [heading,roll]=dockingAngles(attitude_,orientation);
        const auto lane=localCorridor(p);
        const double radius=p.berthRadius;
        const bool vessel=isVessel(p);
        Point goal=lane;
        if (active.phase==MissionDockPhase::Arrival && !active.checkedApproach) {
            const Point hull=vessel ? Point{-1.2*radius-8.,0.,6.87} : Point{0.,-.18*radius,-1.45*radius};
            const auto path=goal-offset;
            const auto nearest=offset+path*std::clamp(simd_dot(hull-offset,path)/std::max(1.,simd_length_squared(path)),0.,1.);
            if (simd_length(nearest-hull)<radius*(vessel ? 1.2 : 1.9))
                active.bypass=hull+(vessel ? Point{4.,1.6,2.7} : Point{offset.x<0. ? -4. : 4.,2.,2.})*radius;
            active.checkedApproach=true;
        }
        if (active.bypass && simd_distance(offset,*active.bypass)<std::max(40.,radius*.25)) active.bypass.reset();
        if (active.bypass) goal=*active.bypass;
        if (active.phase==MissionDockPhase::Arrival && !active.bypass &&
            simd_distance(goal,offset)<25. && relativeSpeed<6.)
            active.phase=MissionDockPhase::Align;
        if (active.phase==MissionDockPhase::Align && simd_distance(goal,offset)<(vessel ? 6. : 3.) &&
            relativeSpeed<(vessel ? 2.5 : .7) && heading<(vessel ? .086 : .045) &&
            std::abs(roll)<(vessel ? .08 : .06))
            active.phase=MissionDockPhase::Glide;
        if (active.phase==MissionDockPhase::Glide && range<28.) active.phase=MissionDockPhase::Capture;
        if (active.phase==MissionDockPhase::Capture) {
            const bool settled=settledAtBerth(range,relativeSpeed,heading,roll,vessel);
            active.captureSeconds=settled ? active.captureSeconds+dt : 0.;
            if (active.captureSeconds>=1.6) {
                active.phase=MissionDockPhase::Clamped;
                position_=berth;
                velocity_=baseVelocity;
                attitude_=orientation;
                return;
            }
        }
        if (active.phase==MissionDockPhase::Departure) {
            if (offset.z>lane.z+30.) {
                missionApproach_.reset();
                return;
            }
            const auto nose=simd_act(orientation,Point{0.,0.,1.});
            toPoint(position_+nose*400.);
            const double alignment=simd_dot(simd_act(attitude_,Point{0.,0.,-1.}),nose);
            const double speed=alignment>.985 ? std::min(32.,4.+std::max(0.,offset.z)*.10) : 0.;
            const auto lateral=limited(Point{-offset.x,-offset.y,0.}*.6,3.);
            wanted=baseVelocity+simd_act(orientation,lateral+Point{0.,0.,speed});
        } else if (active.phase==MissionDockPhase::Glide || active.phase==MissionDockPhase::Capture) {
            rotateTo(orientation);
            const bool final=active.phase==MissionDockPhase::Capture;
            const auto lateral=limited(Point{-offset.x,-offset.y,0.}*.55,final ? .8 : 5.);
            const double width=vessel ? std::clamp(radius*.13,6.,13.) : std::clamp(radius*.14,32.,64.);
            const bool aligned=heading<=.12 && std::abs(roll)<=.18 && std::hypot(offset.x,offset.y)<=width*.8;
            const double closing=aligned ? std::min(final ? 1.8 : 24.,std::max(0.,offset.z)*(final ? .45 : .20)) : 0.;
            wanted=baseVelocity+simd_act(orientation,lateral+Point{0.,0.,
                                         offset.z<0. ? std::min(1.,-offset.z*.4) : -closing});
        } else {
            const bool align=active.phase==MissionDockPhase::Align;
            if (align) rotateTo(orientation);
            else toPoint(berth+simd_act(orientation,goal));
            wanted=baseVelocity+simd_act(orientation,limited((goal-offset)*(align ? .5 : .23),align ? 6. : 150.));
        }
    }
    velocity_+=limited(wanted-velocity_,30.*dt);
    const auto destination=position_+velocity_*dt;
    if (!clearMissionLeg(destination)) {
        velocity_=thrusters_={};
        missionApproach_.reset();
        warpBlocked_=true;
        warpNotice_=3.2;
        return;
    }
    position_=destination;
    const double thrust=std::clamp(simd_length(wanted-velocity_)/30.,0.,1.);
    engine_+=(thrust-engine_)*(1.-std::exp(-dt*8.));
    throttle_=thrust;
}

} // namespace pelagic
