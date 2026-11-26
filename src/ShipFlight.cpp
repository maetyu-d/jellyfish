#include "ShipFlight.hpp"
#include "XalariaTerrain.hpp"
#include "ZiksaAppearance.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <limits>
#include <numbers>
#include <string_view>

namespace pelagic {
namespace {

using Point = simd_double3;
constexpr double tau = 2.*std::numbers::pi;
constexpr double hullRadius = 6.;
constexpr double regionMetresPerUnit = 1.e15/.052; // Native Xalaria atlas spacing in metres.
constexpr double preferredSpeed = 85000.;
constexpr double brakeAcceleration = 32.;
constexpr double warpCruiseFraction = .21;
constexpr double warpApproachRate = .72;
// Galaxy zero derived by Infinity's seedOf from the seed in XalariaMain.cpp.
constexpr auto xalariaGalaxyKey=10361706550335624619ULL;
static_assert(ziksaWorlds.size()==ziksaBodyCount);

std::uint64_t xalariaMix(std::uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

struct StellarStyle {
    double spin, mass;
    float wind;
    Quad features, light;
};

StellarStyle stellarStyle(unsigned id, double temperature) {
    // Xalaria Core.cpp and StellarEvolution.cpp, for the single catalogue galaxy.
    const auto key=xalariaMix(xalariaGalaxyKey^xalariaMix(0x102)^xalariaMix(id));
    const float phase=float(double(xalariaMix(key^xalariaMix(3)) >> 11)*0x1.0p-53);
    Quad parameters{1.f,58.f,.1f,phase};
    double spin=1./2160000.;
    double mass=0.;
    float wind=.2f;
    // The four survey systems use the native stellarEvolution recipes.
    switch (id) {
    case 14941:
        parameters={3.f,10.f,.08f,phase}; spin=1.21489912507115e-7; mass=1.10264808820546; wind=.4f;
        break;
    case 15140:
        parameters={8.f,0.f,0.f,phase}; spin=3.22254931738225; mass=1.68316655649369; wind=.1f;
        break;
    case 14539:
        parameters={9.f,12.f,.4f,phase}; spin=2.47606445184168e-5; mass=.038527351694322; wind=0.f;
        break;
    case 14738:
        parameters={10.f,6.f,.08f,phase}; spin=1.13678360927337e-8; mass=.831305497315234; wind=.8f;
        break;
    }
    const double t=std::clamp(temperature,1000.,40000.)/100.;
    const auto channel=[](double value) { return float(std::clamp(value/255.,0.,1.)); };
    const double r=t<=66. ? 255. : 329.698727446*std::pow(t-60.,-.1332047592);
    const double g=t<=66. ? 99.4708025861*std::log(t)-161.1195681661 : 288.1221695283*std::pow(t-60.,-.0755148492);
    const double b=t>=66. ? 255. : t<=19. ? 0. : 138.5177312231*std::log(t-10.)-305.0447927307;
    Quad light{channel(r),channel(g),channel(b),float(temperature)};
    if (id==14738) { light.y*=.64f; light.z*=.38f; }
    if (id==14539) {
        const float attenuation=float(std::clamp(std::pow(temperature/2400.,2.),.025,1.));
        light.x*=attenuation; light.y*=attenuation; light.z*=attenuation;
    }
    return {spin,mass,wind,parameters,light};
}

Point orbitPosition(double distance,double phase,double inclination,double heading) {
    return distance*Point{std::cos(phase),inclination*std::sin(phase+heading),std::sin(phase)};
}

Point regionCentre(const SystemBubble& system) {
    const unsigned id=unsigned(system.catalogue.x);
    constexpr unsigned side=regionGrid*regionSide;
    const double x=id%side, y=id/side;
    const double lift=1.5*std::sin(x*.105+1.3)*std::cos(y*.083)+.7*std::sin((x+y)*.047+.4);
    return regionMetresPerUnit*Point{system.position.x,.052*lift,system.position.y};
}

simd_quatd facing(Point aim) {
    const double yaw=std::atan2(-aim.x,-aim.z);
    return simd_mul(simd_quaternion(yaw,Point{0.,1.,0.}),
                    simd_quaternion(std::asin(std::clamp(aim.y,-1.,1.)),Point{1.,0.,0.}));
}
double eased01(double x) { x=std::clamp(x,0.,1.); return x*x*(3.-2.*x); }

double visibleDiscFraction(double star, double body, double separation) {
    // Intersection of the apparent discs, as in Xalaria's StellarOptics.cpp.
    if (separation>=star+body) return 1.;
    if (separation+star<=body) return 0.;
    if (separation+body<=star) return 1.-(body/star)*(body/star);
    const double d2=separation*separation, s2=star*star, b2=body*body;
    const double a=std::acos(std::clamp((d2+s2-b2)/(2.*separation*star),-1.,1.));
    const double b=std::acos(std::clamp((d2+b2-s2)/(2.*separation*body),-1.,1.));
    const double triangle=(star+body-separation)*(separation+star-body)*
                          (separation+body-star)*(separation+star+body);
    const double overlap=s2*a+b2*b-.5*std::sqrt(std::max(0.,triangle));
    return std::clamp(1.-overlap/(std::numbers::pi*s2),0.,1.);
}

constexpr Point inertia{153000.,160000.,25000.};
constexpr Point torqueCaps{994500.,1040000.,237500.};
constexpr Point manualRates{1.20,1.10,1.80};

Quad quad(Point v, float w = 0.f) { return {float(v.x),float(v.y),float(v.z),w}; }
Point limit(Point p, double cap) { return p*std::min(1.,cap/std::max(1e-12,simd_length(p))); }
double response(double dt,double seconds) { return -std::expm1(-dt/seconds); }
std::string systemName(unsigned id) {
    char label[32];
    std::snprintf(label,sizeof(label),"Xalaria %05u",id);
    return label;
}

// Infinity's normalized wrench allocation. The main engine has its own forward
// limit; reverse thrust, steering and lateral translation share RCS authority.
double rcsLoad(Point force, Point angular) {
    const double reverse = std::max(0.,force.z);
    return force.x*force.x+force.y*force.y+reverse*reverse+simd_dot(angular,angular);
}

// Infinity's support-first allocation in the bubble's normalized units.
void allocate(Point& force, Point& angular, Point support = {}) {
    support.z = std::clamp(support.z,-1.,1.);
    const double load = rcsLoad(support,{});
    if (load > 1.) support /= std::sqrt(load);
    angular = limit(angular,std::sqrt(std::max(0.,1.-rcsLoad(support,{}))));
    double lo = 0., hi = 1.;
    if (rcsLoad(support+force,angular) <= 1.) {
        lo = 1.;
    } else {
        for (unsigned i = 0; i < 18; ++i) {
            const double scale = (lo+hi)*.5;
            (rcsLoad(support+force*scale,angular) <= 1. ? lo : hi) = scale;
        }
    }
    force = support+force*lo;
    force.z = std::clamp(force.z,-1.,1.);
}

void spring(Point& position, Point& velocity, Point target, double omega, double damping, double dt) {
    const double decay = std::exp(-damping*omega*dt);
    const double frequency = omega*std::sqrt(1.-damping*damping);
    const double c = std::cos(frequency*dt), s = std::sin(frequency*dt);
    const auto error = position-target;
    const auto b = (velocity+damping*omega*error)/frequency;
    position = target+(error*c+b*s)*decay;
    velocity = ((-error*frequency*s+b*frequency*c)-damping*omega*(error*c+b*s))*decay;
}

// Port of Infinity's midpoint angular-momentum integrator in ShipDynamics.cpp.
void integrateRotation(simd_quatd& attitude, Point& spin, Point torque, double dt) {
    const Point momentum = simd_act(attitude,inertia*spin);
    Point midpoint = spin, next = momentum;
    for (unsigned i=0;i<4;++i) {
        const double speed = simd_length(midpoint);
        const auto half = speed > 1e-12 ?
            simd_normalize(simd_mul(attitude,simd_quaternion(speed*dt*.5,midpoint/speed))) : attitude;
        next = momentum+simd_act(half,torque)*dt;
        midpoint = simd_act(simd_inverse(half),(momentum+next)*.5)/inertia;
    }
    const double speed = simd_length(midpoint);
    if (speed > 1e-12)
        attitude = simd_normalize(simd_mul(attitude,simd_quaternion(speed*dt,midpoint/speed)));
    spin = simd_act(simd_inverse(attitude),next)/inertia;
}

} // namespace

Quad ShipFlight::physicalSurface(float gas,float clouds,double radius,const WorldAppearance& look,
                                 bool legacyRings) {
    if (look.light.w == 0.f)
        return {gas,clouds,float(radius*1.32),legacyRings ? float(radius*1.96) : 0.f};
    const auto& ring = look.annulus;
    if (ring.z <= 0.f || ring.y <= ring.x) return {gas,clouds,0.f,0.f};
    return {gas,clouds,float(radius*ring.x),float(radius*ring.y)};
}

ShipFlight::ShipFlight() : attitude_(simd_quaternion(0.,Point{0.,1.,0.})) {
    for (std::size_t i=0; i<ziksaWorlds.size(); ++i) {
        const auto& world=ziksaWorlds[i];
        bodyNames_[i]=world.name;
        orbits_[i]={world.radius,world.distance,i ? tau/world.period : 0.,world.phase,
                    world.inclination,world.heading,world.parent};
        auto& body=bodies_[i];
        body.appearance=world.look;
        if (!i) body.colour={1.f,.43f,.12f,float(world.temperature)};
        else {
            const auto& low=world.look.dark;
            const auto& high=world.look.light;
            body.colour={std::lerp(low.x,high.x,.54f),std::lerp(low.y,high.y,.54f),
                         std::lerp(low.z,high.z,.54f),float(world.temperature)};
            body.surface=physicalSurface(high.w>=7.f ? 1.f : 0.f,world.clouds,world.radius,world.look);
        }
    }
    const auto star=stellarStyle(ziksaSystemId,ziksaWorlds[0].temperature);
    stellar_=star.features;
    stellarLight_=star.light;
    stellarSpin_=star.spin;
    stellarMass_=star.mass;
    stellarWind_=star.wind;
    setFlightScale();
    updateOrbits();
    approachHomeWorld();
}

void ShipFlight::approachHomeWorld() {
    const auto planet=centres_[target_];
    const auto outward=simd_normalize(-planet+Point{0.,orbits_[target_].distance*.25,0.});
    position_=planet+outward*orbits_[target_].radius*3.35;
    localFrame_=target_;
    velocity_={};
    aimAt(planet);
}

ShipFlight::ShipFlight(const SystemBubble& system,unsigned id,double time,Vec entry,const System* record)
    : system_(system), location_(systemName(id)), time_(time),
      look_(static_cast<XalariaLook>(unsigned(system.catalogue.y))), bodyCount_(1), target_(0) {
    if (record && !record->name.empty()) location_=record->name+"  ["+systemName(id)+"]";
    auto planets=record ? record->orbits : std::array<Orbit,systemPlanetLimit>{};
    if (record && record->count>3)
        std::stable_sort(planets.begin(),planets.begin()+record->count,
                         [](const Orbit& a,const Orbit& b) { return a.distance<b.distance; });
    constexpr double legacyScale=180000000.;
    bodyNames_[0]="Star";
    orbits_[0].radius=record ? std::pow(10.,double(record->radius)) : system.star.w*legacyScale;
    bodies_[0].colour={system.star.x,system.star.y,system.star.z,system.catalogue.w};
    const auto star=stellarStyle(id,system.catalogue.w);
    stellar_=star.features;
    stellarLight_=star.light;
    stellarSpin_=star.spin;
    stellarMass_=star.mass;
    stellarWind_=star.wind;
    for (unsigned i=0; i<system.orbits.size() && system.orbits[i].w>0.f; ++i) {
        const auto orbit=system.orbits[i];
        const auto material=system.materials[i];
        const auto& catalogue=planets[i];
        const auto& appearance=system.appearances[i];
        const bool physical=record && catalogue.orbitalPhase>=0.;
        if (record) bodyNames_[i+1]=catalogue.name;
        auto& data=orbits_[i+1];
        data={record ? std::pow(10.,double(catalogue.radius)) : orbit.w*legacyScale,
              record ? std::pow(10.,double(catalogue.distance)) : orbit.x*legacyScale,
              physical ? tau/std::pow(10.,double(catalogue.period)) : orbit.z,
              physical ? catalogue.orbitalPhase : orbit.y,
              physical ? catalogue.orbitalTilt : .43, physical ? catalogue.orbitalHeading : 0.,-1};
        auto& body=bodies_[i+1];
        body.colour=system.colours[i];
        body.appearance=appearance;
        body.surface=physicalSurface(material.x,material.y,data.radius,appearance,body.colour.w>0.f);
        if (record) body.colour.w=catalogue.heat;
        if (appearance.light.w==0.f) {
            const double tilt=material.z, node=material.w;
            body.appearance.pole={float(std::sin(tilt)*std::cos(node)),float(std::cos(tilt)),
                                  float(std::sin(tilt)*std::sin(node)),0.f};
        }
        ++bodyCount_;
    }
    setFlightScale();
    updateOrbits();
    enterAtFilm(entry);
}

ShipFlight::ShipFlight(const Ocean& ocean,const Region& region,double time,Vec entry)
    : region_(&region), regionSystems_(ocean.systemBubbles().subspan(region.firstSystem,region.systems)),
      regionIds_(ocean.systemBubbleIds().subspan(region.firstSystem,region.systems)),
      location_("Region "+std::to_string(region.cell%regionGrid+1)+", "+std::to_string(region.cell/regionGrid+1)),
      time_(time), look_(xalariaLook(region.cell)), bodyCount_(0), target_(0) {
    setFlightScale();
    enterAtFilm(entry);
}

void ShipFlight::setFlightScale() {
    if (region_) {
        metresPerUnit_=regionMetresPerUnit;
    } else {
        double span=orbits_[0].radius*12.;
        for (std::size_t i=1; i<bodyCount_; ++i) {
            const auto& body=orbits_[i];
            const double parent=body.parent<0 ? 0. : orbits_[body.parent].distance;
            const double extent=(parent+body.distance)*std::hypot(1.,body.inclination)+
                                std::max(body.radius,double(bodies_[i].surface.w));
            span=std::max(span,extent);
        }
        metresPerUnit_=std::max(1.e8,span*1.50);
        const double luminosity=std::pow(orbits_[0].radius/6.957e8,2)*
                                std::pow(std::max(1800.f,bodies_[0].colour.w)/5772.,4);
        const double mass=stellarMass_>0. ? stellarMass_ : std::clamp(std::pow(luminosity,1./3.5),.08,80.);
        stellarGravity_=1.32712440018e20*mass;
    }
    flightLimit_=metresPerUnit_*.978;
}

void ShipFlight::aimAt(Point target) {
    const Point delta=target-position_;
    attitude_=facing(simd_length(delta)>1.e-6 ? simd_normalize(delta) : Point{0.,0.,-1.});
}

void ShipFlight::enterAtFilm(Vec entry) {
    Point outward{entry.x,entry.y,entry.z};
    outward=simd_length(outward)>.000001 ? simd_normalize(outward) : Point{0.,0.,1.};
    localFrame_.reset();
    cancelWarp();
    missionApproach_.reset();
    warpVisual_=warpNotice_=0.;
    position_=outward*(metresPerUnit_*.948);
    velocity_=spin_=thrusters_=rcs_={};
    engine_=boundaryLoad_=lookYaw_=lookPitch_=throttle_=boost_=0.;
    headShift_=headLean_=leanVelocity_=shiftVelocity_={};
    if (region_ && !regionSystems_.empty()) {
        const auto nearest=std::min_element(regionSystems_.begin(),regionSystems_.end(),[&](const auto& a,const auto& b) {
            return simd_distance_squared(regionCentre(a),position_)<simd_distance_squared(regionCentre(b),position_);
        });
        target_=std::size_t(nearest-regionSystems_.begin());
    }
    aimAt(contact(unsigned(target_)).centre);
}

void ShipFlight::holdEntryHeading(Vec heading) {
    const Point direction{heading.x,heading.y,heading.z};
    if (simd_length_squared(direction)>1.e-8) attitude_=facing(simd_normalize(direction));
}

bool ShipFlight::selectRegionTarget(unsigned system) {
    if (!region_) return false;
    const auto target=std::ranges::find(regionIds_,system);
    if (target==regionIds_.end()) return false;
    target_=std::size_t(target-regionIds_.begin());
    return true;
}

void ShipFlight::updateOrbits() {
    if (region_) return;
    const auto prior=localFrame_ ? centres_[*localFrame_] : Point{};
    for (unsigned i=1; i<bodyCount_; ++i) centres_[i]=orbitVector(i,false);
    if (localFrame_) position_+=centres_[*localFrame_]-prior;
}

Point ShipFlight::orbitVector(unsigned body,bool velocity) const {
    Point result{};
    for (std::size_t depth=0; body>0 && body<bodyCount_ && depth<bodyCount_; ++depth) {
        const auto& orbit=orbits_[body];
        const double phase=std::remainder(orbit.phase+time_*orbit.rate,tau);
        if (velocity)
            result+=orbit.distance*orbit.rate*Point{-std::sin(phase),
                orbit.inclination*std::cos(phase+orbit.heading),std::cos(phase)};
        else result+=orbitPosition(orbit.distance,phase,orbit.inclination,orbit.heading);
        body=orbit.parent>0 ? unsigned(orbit.parent) : 0u;
    }
    return result;
}

void ShipFlight::syncOrbits(double time) {
    time_ = time;
    updateOrbits();
}

void ShipFlight::step(double seconds,const Helm& helm,bool atHelm) {
    const double dt = std::clamp(seconds,0.,.1);
    if (dt <= 0.) return;
    const auto steps = std::max(1u,unsigned(std::ceil(dt*120.)));
    const double tick = dt/steps;
    Helm input = atHelm ? helm : Helm{.brake=true};
    if (input.lookAround) {
        lookYaw_ = std::remainder(lookYaw_+input.mouseX,tau);
        constexpr double verticalLimit = 78.*std::numbers::pi/180.;
        lookPitch_ = std::clamp(lookPitch_+input.mouseY,-verticalLimit,verticalLimit);
        input.mouseX = input.mouseY = 0.;
    } else {
        lookYaw_ *= std::exp(-dt/.11);
        lookPitch_ *= std::exp(-dt/.11);
    }
    input.yaw += std::clamp(input.mouseX/(dt*1.8),-.92,.92);
    input.pitch += std::clamp(input.mouseY/(dt*1.8),-.92,.92);
    const bool steering=input.brake || input.thrust || input.strafe || input.lift ||
                        input.pitch || input.yaw || input.roll;
    if (missionApproach_ && missionApproach_->phase!=MissionDockPhase::Clamped && (!atHelm || steering))
        cancelMissionApproach();
    for (unsigned i=0;i<steps;++i) {
        time_ += tick;
        updateOrbits();
        if (warp_ && !input.brake && atHelm) integrateWarp(tick);
        else {
            if (warp_) cancelWarp();
            warpVisual_*=std::exp(-tick*2.5);
            warpNotice_=std::max(0.,warpNotice_-tick);
            if (missionApproach_) integrateMission(tick);
            else integrate(tick,input);
        }
    }
}

void ShipFlight::integrate(double dt,const Helm& helm) {
    const auto inverse = simd_inverse(attitude_);
    const double fine = helm.precise ? .35 : 1.;
    double roll = helm.roll;
    if (helm.level && roll == 0.) {
        const auto localUp = simd_act(inverse,Point{0.,1.,0.});
        roll = std::clamp(std::atan2(localUp.x,localUp.y)*1.7,-1.,1.);
    }
    const Point desired = simd_clamp(Point{helm.pitch,-helm.yaw,-roll},-1.,1.)*manualRates*fine;
    const Point gain{desired.x*spin_.x <= 0. ? 18. : 11.,desired.y*spin_.y <= 0. ? 18. : 11.,
                     desired.z*spin_.z <= 0. ? 22. : 14.};
    const bool assisted = assist_ || helm.brake;
    Point torque = assisted ? (inertia*(desired-spin_)*gain+simd_cross(spin_,inertia*spin_))/torqueCaps :
                              (desired/manualRates)*.55;
    throttle_ = helm.brake ? 0. : std::clamp(throttle_+helm.thrust*dt*.36,0.,1.);
    boost_ += ((helm.boost && !helm.precise && !helm.brake ? 1. : 0.)-boost_)*response(dt,.18);
    const double clearance=operatingClearance();
    const double speedLimit=std::clamp(.32*clearance,350.,preferredSpeed)*(1.+1.4*boost_)*
                            (helm.precise ? .18 : 1.);
    const double mainDrive = 52.*(1.+1.4*boost_);
    const Point delta=-position_;
    const double range=std::max(orbits_[0].radius,simd_length(delta));
    Point gravity=region_ ? Point{} : delta*(stellarGravity_/(range*range*range));
    if (localFrame_ && *localFrame_!=0) {
        // The parked frame already follows the planet's stellar orbit.
        const unsigned i=unsigned(*localFrame_);
        const Point away=centres_[i]-position_;
        const double radius=orbits_[i].radius;
        const double distance=std::max(radius,simd_length(away));
        const double density=bodies_[i].surface.x>0.5f ? 1100. : 4200.;
        const double mu=6.67430e-11*4.188790204786391*density*radius*radius*radius;
        gravity=away*(mu/(distance*distance*distance));
    }
    const auto normalizeForce = [&](Point acceleration) {
        return acceleration/Point{44.,48.,acceleration.z < 0. ? mainDrive : brakeAcceleration};
    };
    const Point wanted = helm.brake ? Point{} : Point{helm.strafe*speedLimit*.28,helm.lift*speedLimit*.30,-throttle_*speedLimit};
    const Point localVelocity = simd_act(inverse,velocity_);
    Point force = assisted ? normalizeForce((wanted-localVelocity)*Point{2.4,2.4,helm.brake ? 4.8 : 1.6}) :
                             Point{helm.strafe*(helm.precise ? .18 : 1.),helm.lift*(helm.precise ? .18 : 1.),-throttle_};
    const Point support = assisted ? normalizeForce(simd_act(inverse,-gravity)) : Point{};
    allocate(force,torque,support);
    thrusters_ += (force-thrusters_)*response(dt,.12);
    for (unsigned axis = 0; axis < 3; ++axis)
        rcs_[axis] += (torque[axis]-rcs_[axis])*response(dt,gain[axis] >= 18. ? .015 : .06);
    allocate(thrusters_,rcs_);
    integrateRotation(attitude_,spin_,rcs_*torqueCaps,dt);
    const double engineAuthority=missionFuel_>.001 ? 1. : .15;
    const Point localAcceleration = thrusters_*Point{44.,48.,engineAuthority*(thrusters_.z < 0. ? mainDrive : brakeAcceleration)};
    const Point thrust = simd_act(attitude_,localAcceleration);
    const Point g = limit(localAcceleration/9.80665,8.);
    spring(headLean_,leanVelocity_,limit(Point{-g.y*.0007,g.x*.00065,-g.x*.0009}-spin_*.0018,.0065),13.,.82,dt);
    spring(headShift_,shiftVelocity_,limit(-g*.00135,.007),15.,.85,dt);
    velocity_ += (thrust+gravity)*dt;
    if (helm.brake && simd_length(velocity_)<.08) velocity_={};
    velocity_=limit(velocity_,preferredSpeed*2.4);
    position_ += velocity_*dt;
    const double speed = simd_length(velocity_);
    engine_ += (std::clamp(std::max(-thrusters_.z,0.)*(helm.boost ? 1.2 : 1.),0.,1.)-engine_)*response(dt,.11);
    boundaryLoad_ *= std::exp(-dt*4.3);

    const auto collide=[&](Contact body) {
        const Point offset=position_-body.centre;
        const double distance=simd_length(offset), contactRadius=body.radius+hullRadius;
        if (distance>=contactRadius) return;
        const Point normal=distance>1e-8 ? offset/distance : Point{0.,1.,0.};
        position_=body.centre+normal*contactRadius;
        velocity_-=normal*std::min(0.,simd_dot(velocity_,normal))*1.16;
    };
    const std::size_t count=region_ ? regionSystems_.size() : bodyCount_;
    for (unsigned i=0; i<count; ++i) collide(surfaceContact(i));
    const double distance = simd_length(position_);
    if (distance > flightLimit_-hullRadius) {
        const Point normal = position_/distance;
        position_ = normal*(flightLimit_-hullRadius);
        velocity_ -= normal*std::max(0.,simd_dot(velocity_,normal))*1.27;
        boundaryLoad_ = std::max(boundaryLoad_,std::clamp(speed/preferredSpeed,.18,1.));
    }
}

ShipFlight::Contact ShipFlight::contact(unsigned i) const {
    if (region_) {
        if (i>=regionSystems_.size()) return {{},0.};
        return {regionCentre(regionSystems_[i]),6.957e8};
    }
    return {centres_[i],orbits_[i].radius};
}

ShipFlight::Contact ShipFlight::surfaceContact(unsigned i) const {
    return surfaceContact(i,position_);
}

ShipFlight::Contact ShipFlight::surfaceContact(unsigned i,Point point) const {
    auto body = contact(i);
    if (!terrain_ || region_ || i==0 || bodies_[i].surface.x>.5f) return body;
    const auto outward = point-body.centre;
    const double range = simd_length(outward);
    if (range<1.e-6 || range>body.radius*1.04+hullRadius) return body;
    const auto direction = outward/range;
    body.radius *= 1.+terrain_->surfaceHeight(systemId(),bodyName(i),
                                               {float(direction.x),float(direction.y),float(direction.z)});
    return body;
}

double ShipFlight::operatingClearance() const {
    double clearance=std::max(0.,flightLimit_-simd_length(position_));
    const auto count=region_ ? regionSystems_.size() : bodyCount_;
    for (unsigned i=0; i<count; ++i) {
        const auto body=surfaceContact(i);
        clearance=std::min(clearance,simd_length(body.centre-position_)-body.radius);
    }
    return std::max(0.,clearance);
}

double ShipFlight::warpStandOff() const {
    if (missionApproach_) return missionApproach_->kind==missions::ActionKind::Dock ||
                                  missionApproach_->kind==missions::ActionKind::Land ? 0. :
                                  missionApproach_->point.standOff;
    const auto target=contact(unsigned(target_));
    return std::max(target.radius+12000.,target.radius*(target_ ? 3.35 : 8.));
}

double ShipFlight::warpGap() const {
    return std::max(0.,simd_length(warpCentre()-position_)-warpStandOff());
}

void ShipFlight::setUnderAttack(bool active) {
    underAttack_=active;
    if (underAttack_) {
        cancelWarp();
        warpNotice_=0.;
    }
}

void ShipFlight::setMissionHull(double percent) {
    if (std::isfinite(percent)) missionHull_=std::clamp(percent,0.,100.);
}

void ShipFlight::setMissionFuel(double units) {
    if (!std::isfinite(units)) return;
    missionFuel_=std::max(0.,units);
    if (missionFuel_<=.001 && warp_) cancelWarp();
}

void ShipFlight::engageWarp() {
    if (warp_) { cancelWarp(); return; }
    if (!warpAvailable()) return;
    if (missionApproach_) {
        if (missionApproach_->phase==MissionDockPhase::Clamped) return;
        cancelMissionApproach();
    }
    if (warpGap()<100.) {
        warpNotice_=2.8;
        warpBlocked_=false;
        return;
    }
    startWarp();
}
void ShipFlight::startWarp() {
    localFrame_.reset();
    warpWaypoint_.reset();
    warp_=true;
    warpBlocked_=false;
    warpTime_=warpNotice_=throttle_=0.;
    velocity_=thrusters_={};
}
void ShipFlight::cancelWarp() {
    if (warp_) {
        velocity_=thrusters_=spin_=rcs_={};
        throttle_=0.;
        missionApproach_.reset();
    }
    warp_=false;
    warpWaypoint_.reset();
}
std::string_view ShipFlight::warpStatus() const {
    if (underAttack_) return "WARP LOCKED / UNDER ATTACK";
    if (region_) return "WARP LOCKED / ENTER A STAR SYSTEM";
    if (warp_) return warpTime_<.7 ? "ALIGNING FOR WARP" : "WARP / DESTINATION LOCK";
    if (missionApproach_) {
        if (missionApproach_->kind==missions::ActionKind::Follow) return "FORMATION ASSIST";
        if (missionApproach_->kind==missions::ActionKind::Approach) return "APPROACH / DESTINATION LOCK";
        if (missionApproach_->kind==missions::ActionKind::Land) {
            switch (missionApproach_->phase) {
            case MissionDockPhase::Arrival: return "SURFACE PORT / FINAL APPROACH";
            case MissionDockPhase::Align: return "LANDING / ALIGNING";
            case MissionDockPhase::Glide: return "LANDING / CONTROLLED DESCENT";
            case MissionDockPhase::Capture: return "LANDING / FLARE";
            case MissionDockPhase::Clamped: return "LANDED / GEAR DOWN";
            case MissionDockPhase::Departure: return "LAUNCHING / CLIMB";
            }
        }
        switch (missionApproach_->phase) {
        case MissionDockPhase::Arrival: return "DOCKING / ACQUIRING GATE";
        case MissionDockPhase::Align: return "DOCKING / ALIGN WITH BERTH";
        case MissionDockPhase::Glide: return "DOCKING / GLIDE";
        case MissionDockPhase::Capture: return "DOCKING / SOFT CAPTURE";
        case MissionDockPhase::Clamped: return "DOCKED / CLAMPS SECURE";
        case MissionDockPhase::Departure: return "UNDOCKING / CLEARING THE LANE";
        }
    }
    if (warpNotice_>0.) return warpBlocked_ ? "WARP ABORT / COURSE BLOCKED" : "APPROACH REACHED";
    if (missionFuel_<=.001) return "WARP LOCKED / FUEL DEPLETED";
    return {};
}

double ShipFlight::warpEta() const {
    const double gap=warpGap(), cap=metresPerUnit_*warpCruiseFraction;
    const double taper=cap/warpApproachRate;
    const double floor=std::max(14000.,metresPerUnit_*2.5e-5);
    const double crossover=floor/warpApproachRate;
    return std::max(0.,.7-warpTime_)+std::max(0.,gap-taper)/cap+
           std::log(std::max(1.,std::min(gap,taper)/crossover))/warpApproachRate+
           std::min(gap,crossover)/floor;
}

void ShipFlight::arriveFromWarp(Point centre) {
    auto approach=std::move(missionApproach_);
    cancelWarp();
    aimAt(centre);
    localFrame_=target_;
    if (approach && approach->kind!=missions::ActionKind::Approach) missionApproach_=std::move(approach);
    warpNotice_=3.2;
}

void ShipFlight::integrateWarp(double dt) {
    warpTime_+=dt;
    const auto centre=warpCentre();
    const auto delta=centre-position_;
    const double range=simd_length(delta);
    if (range<=warpStandOff()+3.) {
        arriveFromWarp(centre);
        return;
    }
    const auto outward=-delta/range;
    const Point end=centre+outward*warpStandOff();
    const Point track=delta/range;
    if (!warpWaypoint_) {
        double nearest=range-warpStandOff();
        for (unsigned i=0; i<bodyCount_; ++i) {
            if (i==target_ && !missionApproach_) continue;
            const auto body=contact(i);
            const Point relative=body.centre-position_;
            const double along=simd_dot(relative,track);
            const double clearance=body.radius*1.25+hullRadius;
            if (along<=0. || along>=nearest || simd_length(relative-track*along)>=clearance) continue;
            // Route north of an eclipsing body. The sweep below backs up
            // this detour if another moving body crosses the new leg.
            const Point up=std::abs(track.y)<.94 ? Point{0,1,0} : Point{1,0,0};
            const Point side=simd_normalize(up-track*simd_dot(up,track));
            const Point waypoint=body.centre+side*(clearance*2.8);
            if (simd_length(waypoint)<flightLimit_*.993) {
                warpWaypoint_=waypoint;
                nearest=along;
            }
        }
    }
    const Point leg=(warpWaypoint_ ? *warpWaypoint_ : end)-position_;
    const double gap=simd_length(leg);
    const Point direction=gap>1. ? leg/gap : track;
    attitude_=simd_normalize(simd_slerp(attitude_,facing(direction),response(dt,.16)));
    const double alignment=std::max(0.,simd_dot(simd_act(attitude_,Point{0,0,-1}),direction));
    const double progress=eased01((warpTime_-.40)/1.25)*alignment*alignment;
    const double minimum=std::max(14000.,metresPerUnit_*2.5e-5);
    const double rate=std::min(metresPerUnit_*warpCruiseFraction,std::max(minimum,gap*warpApproachRate));
    const double advance=std::min(gap,dt*rate*progress);
    // Test the swept segment in metres before committing any displacement.
    for (unsigned i=0; i<bodyCount_ && advance>0.; ++i) {
        const auto body=contact(i);
        const auto relative=body.centre-position_;
        const double along=std::clamp(simd_dot(relative,direction),0.,advance);
        if (simd_length(relative-direction*along)<body.radius+hullRadius) {
            cancelWarp();
            warpBlocked_=true;
            warpNotice_=3.2;
            return;
        }
    }
    position_+=direction*advance;
    velocity_=direction*(advance/dt);
    warpVisual_+=(progress-warpVisual_)*response(dt,.42);
    engine_+=(progress-engine_)*response(dt,.34);
    boundaryLoad_*=std::exp(-dt*4.3);
    if (advance>=gap) {
        if (warpWaypoint_) warpWaypoint_.reset();
        else arriveFromWarp(centre);
    }
}

Quad ShipFlight::contactPosition(unsigned i) const {
    const auto body=contact(i);
    return quad((body.centre-position_)/metresPerUnit_,float(body.radius/metresPerUnit_));
}
double ShipFlight::contactRange(unsigned i) const {
    const auto body=surfaceContact(i);
    return std::max(0.,simd_length(body.centre-position_)-body.radius)/1000.;
}

FlightScene ShipFlight::scene(float aspect,Quad water,Quad accent) const {
    const auto head = simd_mul(simd_mul(simd_quaternion(-lookYaw_+headLean_.y,Point{0.,1.,0.}),
                               simd_quaternion(lookPitch_+headLean_.x,Point{1.,0.,0.})),
                               simd_quaternion(headLean_.z,Point{0.,0.,1.}));
    const auto camera = simd_mul(attitude_,head);
    const Point right{1.,0.,0.}, up{0.,1.,0.}, forward{0.,0.,-1.};
    const Point viewRight=simd_act(camera,right), viewUp=simd_act(camera,up), viewForward=simd_act(camera,forward);
    constexpr double halfFocal=.7140740034;
    const double viewAspect=std::max(.001,double(aspect));
    FlightScene scene{};
    if (region_) scene.eye=quad(position_/metresPerUnit_);
    scene.right = quad(viewRight);
    scene.up = quad(viewUp);
    scene.forward = quad(viewForward);
    scene.ship=quad(position_/metresPerUnit_,float(hullRadius/metresPerUnit_));
    scene.shipRight = quad(simd_act(attitude_,right));
    scene.shipUp = quad(simd_act(attitude_,up));
    scene.shipForward = quad(simd_act(attitude_,forward));
    scene.cabinRight = quad(simd_act(head,right));
    scene.cabinUp = quad(simd_act(head,up));
    scene.cabinForward = quad(simd_act(head,forward));
    scene.water = water;
    scene.accent = accent;
    scene.screen = {aspect,float(time_),float(engine_),float(boundaryLoad_)};
    scene.navigation = {region_ ? 0.f : float(target_),float(std::min(1.,simd_length(velocity_)/preferredSpeed)),
                        float(bodyCount_),float(regionSystems_.size())};
    scene.cabinOffset = quad(headShift_);
    scene.controls = quad(simd_clamp(spin_*Point{.22,.16,.21},-.34,.34),float(warp_ ? warpVisual_ : throttle_));
    scene.optics = {float(look_),stellarWind_};
    // Xalaria's one galaxy has zero gas fraction and an identity frame.
    constexpr float phaseCycle=float(xalariaGalaxyKey%10000)*.0371f;
    constexpr float galaxyPhase=phaseCycle-int(phaseCycle);
    scene.drive = {float(metresPerUnit_),float(warpVisual_),float(stellarSpin_),galaxyPhase};
    scene.stellar=stellar_;
    if (!region_) {
        const double distance = simd_length(position_);
        const Point sunlight=distance>.00001 ? -position_/distance : Point{0.,1.,0.};
        const double disc=orbits_[0].radius;
        const double angular=std::asin(std::clamp(disc/std::max(distance,disc),0.,1.));
        double visibility = 1.;
        for (std::size_t i=1;i<bodyCount_;++i) {
            const Point delta=centres_[i]-position_;
            const double range=simd_length(delta);
            if (range<=0. || range>=distance) continue;
            const double body=std::asin(std::min(1.,orbits_[i].radius/range));
            const double separation=std::atan2(simd_length(simd_cross(delta,sunlight)),simd_dot(delta,sunlight));
            visibility=std::min(visibility,visibleDiscFraction(angular,body,separation));
        }
        scene.optics.z = float(visibility*std::clamp(std::pow(angular/.00465,.35),.35,2.));
        scene.optics.w = float(angular);
        const double ahead=simd_dot(sunlight,viewForward);
        if (ahead>1e-4 && visibility>0.) {
            const double x=.5+halfFocal*simd_dot(sunlight,viewRight)/(ahead*viewAspect);
            const double y=.5-halfFocal*simd_dot(sunlight,viewUp)/ahead;
            const double radius=std::tan(angular)*halfFocal;
            const double margin=std::max(.06,2.7*radius/std::min(1.,viewAspect));
            const double t=(std::min({x,y,1.-x,1.-y})+margin)/(margin+.015);
            scene.stellarImage={float(x),float(y),float(radius),float(visibility*eased01(t))};
        }
    }
    scene.bodies=bodies_;
    double largestAtmosphere=0.;
    std::size_t terrainBody=localFrame_.value_or(0);
    if (terrainBody && bodies_[terrainBody].surface.x>.5f) terrainBody=0;
    double nearestTerrain=std::numeric_limits<double>::infinity();
    for (unsigned i=0; i<bodyCount_; ++i) {
        auto& body=scene.bodies[i];
        body.position=contactPosition(i);
        body.surface.z/=float(metresPerUnit_);
        body.surface.w/=float(metresPerUnit_);
        const Quad axis=body.appearance.pole;
        body.axis=i ? Quad{axis.x,axis.y,axis.z,0.f} :
                      Quad{0,1,0,float(time_*.045)};
        if (i==0 || body.surface.x>.5f) continue;
        const double radius=orbits_[i].radius;
        const Point offset=centres_[i]-position_;
        const double range=simd_length(offset);
        if (!warp_ && range<1.08*radius && std::abs(range-radius)<nearestTerrain) {
            terrainBody=i;
            nearestTerrain=std::abs(range-radius);
        }
        if (range>8.*radius || body.colour.w<45.f) continue;
        const double angle=radius/std::max(range,radius);
        if (angle<largestAtmosphere) continue;
        // Hyperion's climate retention proxy, using the catalogue's solid-body density.
        const auto smooth=[](double lo,double hi,double v) { return eased01((v-lo)/(hi-lo)); };
        const double temperature=body.colour.w;
        const double gravity=4.188790204786391*6.67430e-11*4200.*radius;
        const double escape=std::sqrt(2.*gravity*radius);
        const double retention=smooth(1400.,6500.,escape/std::sqrt(std::max(60.,temperature)/280.));
        const double pressure=retention*(.10+1.5*body.appearance.features.z)*
                              (1.-smooth(650.,1050.,temperature))*smooth(45.,110.,temperature);
        if (pressure<.015) continue;
        const double height=std::clamp(std::clamp(287.*temperature/std::max(.15,gravity),500.,35000.)/radius,1.e-5,.02);
        const double shell=radius*(1.+5.6*height);
        const double ahead=simd_dot(offset,viewForward);
        const double sideSlope=.5*viewAspect/halfFocal, verticalSlope=.5/halfFocal;
        if (ahead< -shell ||
            std::abs(simd_dot(offset,viewRight))>ahead*sideSlope+shell*std::hypot(1.,sideSlope) ||
            std::abs(simd_dot(offset,viewUp))>ahead*verticalSlope+shell*std::hypot(1.,verticalSlope)) continue;
        const double strength=std::clamp(pressure*288./std::max(60.,temperature),0.,6.);
        const double tangentKm=std::sqrt(tau*radius*radius*height)/1000.;
        const Point eyeDirection=range>1. ? -offset/range : Point{0.,1.,0.};
        const Point illumination=simd_normalize(centres_[0]-centres_[i]);
        const double night=1.-smooth(-.26,-.10,simd_dot(eyeDirection,illumination));
        const double low=1.-smooth(1.,4.444,(range/radius-1.)/height);
        largestAtmosphere=angle;
        scene.atmosphere={float(i),float(height),float(std::lerp(strength,std::min(strength,1.5/(.029*tangentKm)),low*night)),
                          float(radius/1000.)};
    }
    if (terrainBody) {
        const auto eye=position_-centres_[terrainBody];
        scene.terrainView.x=float(terrainBody);
        scene.terrainEye=quad(eye);
        const auto high=scene.terrainEye;
        scene.terrainEyeResidual=quad(eye-Point{high.x,high.y,high.z});
    }
    if (region_ && !regionSystems_.empty()) scene.bodies[0].position=contactPosition(unsigned(target_));
    if (!region_) scene.bodies[0].colour=stellarLight_;
    return scene;
}

FlightScene ShipFlight::overviewScene(float aspect) const {
    auto frame=scene(aspect);
    frame.bodies[0].colour=bodies_[0].colour;
    frame.eye={};
    frame.ship.w=.014f;
    if (region_ || system_) return frame;
    // Use the same catalogue phases in the bubble's schematic display.
    std::array<Point,ziksaBodyCount> centres{};
    for (unsigned i=0; i<bodyCount_; ++i) {
        auto& body=frame.bodies[i];
        body.axis.w=float(std::remainder(time_*.000075,tau));
        const auto& orbit=orbits_[i];
        const bool moon=orbit.parent>=0;
        const double radius=i==0 ? .069 : moon ? .0039+.0041*std::pow(orbit.radius/1670000.,.62) :
                                                     .023+.032*std::pow(orbit.radius/26696320.,.65);
        if (i>0) {
            const double lane=moon ? frame.bodies[orbit.parent].position.w+.016+
                                     .064*std::sqrt(orbit.distance/1159231238.) :
                                     .14+.47*std::pow(orbit.distance/522452797779.,.68);
            const Point parent=moon ? centres[orbit.parent] : Point{};
            const double phase=std::remainder(orbit.phase+time_*orbit.rate,tau);
            centres[i]=parent+orbitPosition(lane,phase,orbit.inclination,orbit.heading);
        }
        if (body.surface.w>0.f) {
            const float ratio=float(radius*metresPerUnit_/orbit.radius);
            body.surface.z*=ratio;
            body.surface.w*=ratio;
        }
        body.position=quad(centres[i],float(radius));
    }
    return frame;
}

void ShipFlight::nextTarget() {
    cancelMissionApproach();
    warpNotice_=0.;
    const std::size_t count=region_ ? regionSystems_.size() : bodyCount_;
    if (count>0) target_=(target_+1)%count;
}
std::string ShipFlight::targetName() const {
    if (missionApproach_ && !missionApproach_->point.label.empty()) return missionApproach_->point.label;
    return region_ ? systemName(regionIds_[target_]) : bodyName(unsigned(target_));
}
std::string ShipFlight::bodyName(unsigned i) const {
    if (i>=bodyCount_) return {};
    const auto& name=bodyNames_[i];
    return name.empty() ? "Planet "+std::to_string(i) : name;
}
float ShipFlight::hudVisibility() const {
    const auto smooth = [](double v,double low,double high) {
        const double t=std::clamp((v-low)/(high-low),0.,1.);
        return t*t*(3.-2.*t);
    };
    return float(smooth(std::cos(lookYaw_)*std::cos(lookPitch_),.529919,.882948)*
                 (1.-.63*smooth(simd_length(spin_),.62,1.65)));
}
unsigned ShipFlight::regionCell() const {
    if (region_) return region_->cell;
    const unsigned id=system_ ? unsigned(system_->catalogue.x) : ziksaSystemId;
    constexpr unsigned mapWidth=regionGrid*regionSide;
    return (id/mapWidth/regionSide)*regionGrid+id%mapWidth/regionSide;
}
double ShipFlight::targetRange() const {
    return missionApproach_ ? simd_length(missionCoursePosition()-position_)/1000. :
                             contactRange(unsigned(target_));
}
double ShipFlight::speed() const { return simd_length(velocity_)/1000.; }
double ShipFlight::stoppingDistance() const {
    const double metresPerSecond=simd_length(velocity_);
    return metresPerSecond*metresPerSecond/(2.*brakeAcceleration);
}
bool ShipFlight::nearFilm() const { return simd_length(position_)>flightLimit_-metresPerUnit_*.018; }

} // namespace pelagic
