#include "MissionTravel.hpp"
#include "MissionRuntime.hpp"

#include <algorithm>
#include <numbers>

namespace pelagic::missions {
namespace {
glm::dvec3 vector(Position p) { return {p[0],p[1],p[2]}; }
Position point(glm::dvec3 p) { return {p.x,p.y,p.z}; }
glm::dquat quaternion(Orientation p) { return {p[0],p[1],p[2],p[3]}; }
Orientation rotation(glm::dquat p) { return {p.w,p.x,p.y,p.z}; }

RoutePoint gate(NativeRuntime& runtime,const infinity::XalariaWormholeMouth& mouth) {
    RoutePoint result;
    result.frame=runtime.frame(mouth.reference);
    result.position=point(mouth.metres);
    result.orientation=rotation(mouth.orientation);
    result.standOff=mouth.radius*.7;
    result.label="Wormhole to "+runtime.catalog->star(mouth.destination).name;
    result.connection=mouth.destination;
    return result;
}
}

std::optional<MissionPassage> missionPassage(NativeRuntime& runtime,std::uint32_t current,std::uint32_t destination) {
    if (current==destination || !runtime.catalog->stars.contains(current) ||
        !runtime.catalog->stars.contains(destination)) return {};
    const auto path=runtime.catalog->route(current,destination);
    if (path.size()<2) return {};
    const auto* entrance=runtime.course.wormholeFor(current,path[1]);
    if (!entrance) return {};
    const auto& links=runtime.catalog->star(path[1]).wormholes;
    if (links.empty()) return {};
    const auto exitDirection=std::find(links.begin(),links.end(),current)!=links.end() ? current : links.front();
    const auto* exit=runtime.course.wormholeFor(path[1],exitDirection);
    if (!exit) return {};
    runtime.course.view.wormhole=*entrance;
    return MissionPassage{gate(runtime,*entrance),gate(runtime,*exit),entrance->radius,unsigned(path.size()-1)};
}

std::optional<MissionArrival> crossMissionPassage(const MissionPassage& passage,Position previous,
                                                  const PlayerLocation& current,double hullRadius) {
    if (!current.active || current.inTransit || current.landed || current.docking || current.clamped ||
        current.frame!=passage.entrance.frame) return {};
    const auto entrance=quaternion(passage.entrance.orientation);
    const auto exit=quaternion(passage.exit.orientation);
    const auto forward=entrance*glm::dvec3(0.,0.,-1.);
    const auto centre=vector(passage.entrance.position);
    const auto before=vector(previous)-centre;
    const auto after=vector(current.eye)-centre;
    const double start=glm::dot(before,forward),end=glm::dot(after,forward);
    const bool outward=start<0. && end>=0.;
    if (!outward && !(start>0. && end<=0.)) return {};
    const auto atPlane=glm::mix(before,after,-start/(end-start));
    if (glm::length(atPlane)+hullRadius>=passage.radius) return {};
    const auto reverse=glm::angleAxis(std::numbers::pi,glm::dvec3(0.,1.,0.));
    const auto transform=exit*reverse*glm::inverse(outward ? entrance : entrance*reverse);
    const auto speed=transform*vector(current.velocity);
    const auto eye=vector(passage.exit.position)+transform*atPlane+
                   exit*glm::dvec3(0.,0.,95.+std::min(std::abs(end),220.));
    return MissionArrival{passage.exit.frame,point(eye),
                          point(speed*std::min(1.,160./std::max(1.,glm::length(speed)))),
                          rotation(glm::normalize(transform*quaternion(current.orientation)))};
}

} // namespace pelagic::missions
