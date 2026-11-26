#include "BubbleStrings.hpp"

#include <algorithm>
#include <cmath>
#include <iomanip>
#include <map>
#include <numbers>
#include <set>
#include <sstream>

namespace pelagic {
namespace {

constexpr float focal = 1.94f;
constexpr float nearDepth = .35f;
constexpr unsigned stringSegments = 24;
enum class StringFilm { Strand, Target, Knot, Cast, Beam, Harpoon, Chime, Melody, Burst, Finale };

Vec xyz(Quad q) { return {q.x,q.y,q.z}; }
float dot(Vec a, Vec b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
float length(Vec v) { return std::sqrt(dot(v,v)); }
Vec unit(Vec v) { return v*(1.f/std::max(.000001f,length(v))); }
Vec mix(Vec a, Vec b, float t) { return a+(b-a)*t; }
Vec cross(Vec a, Vec b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }
float smooth(float a, float b, float x) {
    const float t = std::clamp((x-a)/(b-a),0.f,1.f);
    return t*t*(3.f-2.f*t);
}

Vec rotateYZ(Vec p, float angle) {
    const float c = std::cos(angle), s = std::sin(angle);
    return {p.x,c*p.y-s*p.z,s*p.y+c*p.z};
}
Vec rotateY(Vec p, float angle) {
    const float c = std::cos(angle), s = std::sin(angle);
    return {c*p.x+s*p.z,p.y,c*p.z-s*p.x};
}

// Match the mesh's sphereShape and bubbleWorldPoint so a string moves with the film.
struct Membrane {
    Vec centre, axes, warp;
    float yaw{}, pitch{}, shear{};

    Membrane(const Bubble& bubble, const Scene& view) {
        const float phase = bubble.pigment.y, seed = bubble.flow.w*2.f*std::numbers::pi_v<float>;
        const float kind = bubble.pigment.w;
        const float base = kind > 4.5f ? .83f : kind > 3.5f ? .57f : kind > 1.5f ? 1.21f : kind > .5f ? .83f : 1.f;
        const float impulse = bubble.membraneAnchor == 1.f ? bubble.trail.w : 0.f;
        const float squeeze = std::max(0.f,bubble.flow.z)*(.15f*view.call.x+.085f*bubble.trail.w);
        const float height = 1.f+.093f*std::sin(phase)-.12f*smooth(.18f,2.4f,std::abs(bubble.trail.y))-
                             squeeze+.24f*impulse;
        const float side = 1.f+.061f*std::cos(phase+seed), width = base/std::sqrt(height);
        axes = Vec{width*side,base*height,width/side}*bubble.position.w;
        warp = {.13f*std::sin(phase+seed),.085f*std::cos(phase-seed),.053f*std::sin(phase)};
        yaw = bubble.flow.y;
        pitch = bubble.pitch;
        shear = bubble.flow.x*.23f;
        centre = xyz(bubble.position);
        if (bubble.membraneAnchor > 0.f)
            centre += rotateY(rotateYZ({0.f,0.f,axes.z*radius({0.f,0.f,-1.f})},pitch),yaw);
        if (view.heldBubbleCentre.w > 0.f && view.heldBubble == unsigned(bubble.bellSystem))
            centre = mix(centre,xyz(view.heldBubbleCentre),view.heldBubbleCentre.w);
    }

    float radius(Vec n) const {
        return 1.f+dot(warp,{n.y*(n.x+.62f*n.z),(n.z*n.z-n.x*n.x)*(.42f+n.y),n.x*n.z});
    }
    float surfaceDistance(Vec local) const { return length(local)-radius(unit(local)); }
    Vec toLocal(Vec delta) const {
        const Vec p = rotateYZ(rotateY(delta,-yaw),-pitch);
        return {(p.x-shear*p.y)/axes.x,p.y/axes.y,p.z/axes.z};
    }
    Vec toWorld(Vec local) const {
        const float y = local.y*axes.y;
        return centre+rotateY(rotateYZ({local.x*axes.x+shear*y,y,local.z*axes.z},pitch),yaw);
    }
    Vec normal(Vec n) const {
        const Vec gradient =
            Vec{n.y,n.x+.62f*n.z,.62f*n.y}*warp.x+
            Vec{-2.f*n.x*(.42f+n.y),n.z*n.z-n.x*n.x,2.f*n.z*(.42f+n.y)}*warp.y+
            Vec{n.z,0.f,n.x}*warp.z;
        const Vec local = n*(radius(n)+dot(n,gradient))-gradient;
        const float x = local.x/axes.x;
        return unit(rotateY(rotateYZ({x,local.y/axes.y-shear*x,local.z/axes.z},pitch),yaw));
    }
    float innerRadius(float fraction) const { return fraction*std::min({axes.x,axes.y,axes.z}); }
};

Vec systemCentre(const Membrane& film, Quad position, unsigned index, const Scene& view) {
    const Vec centre = film.toWorld(xyz(position));
    return index == view.heldSystem && view.heldSystemCentre.w > 0.f ?
        mix(centre,xyz(view.heldSystemCentre),view.heldSystemCentre.w) : centre;
}

struct Ray { Vec eye, direction; };
struct Interval { float in, out; };

std::optional<Interval> intersect(Vec offset, Vec direction, float radius) {
    const float speedSquared = dot(direction,direction);
    const float closest = -dot(offset,direction)/speedSquared;
    const Vec nearest = offset+direction*closest;
    const float distanceSquared = radius*radius-dot(nearest,nearest);
    if (distanceSquared <= 0.f) return {};
    const float travel = std::sqrt(distanceSquared/speedSquared);
    if (closest+travel <= 0.f) return {};
    return Interval{closest-travel,closest+travel};
}

std::optional<float> filmHit(Vec origin, Vec direction, const Membrane& membrane, Interval bounds,
                             bool back = false) {
    const auto distance = [&](float t) { return membrane.surfaceDistance(origin+direction*t); };
    const float entry = std::max(0.f,bounds.in);
    const float start = back ? bounds.out : entry, end = back ? entry : bounds.out;
    float previous = start;
    if (distance(previous) <= 0.f) return {};
    const float middle = std::max(entry,(bounds.in+bounds.out)*.5f);
    for (unsigned i = 1; i <= 12; ++i) {
        const float t = i <= 6 ? std::lerp(start,middle,float(i)/6.f) :
                                std::lerp(middle,end,float(i-6)/6.f);
        if (distance(t) > 0.f) {
            previous = t;
            continue;
        }
        float lo = previous, hi = t;
        for (unsigned step = 0; step < 10; ++step) {
            const float midpoint = (lo+hi)*.5f;
            (distance(midpoint) > 0.f ? lo : hi) = midpoint;
        }
        return hi;
    }
    return {};
}

Ray aimRay(const Scene& view, const ShipPose& ship) {
    const Vec eye = xyz(view.eye);
    return {eye,unit(xyz(ship.position)+xyz(ship.forward)*(24.f*ship.position.w)-eye)};
}

bool inFront(Vec p, const ShipPose& ship) {
    return dot(p-xyz(ship.position),xyz(ship.forward)) > -.1f*ship.position.w;
}

struct Hit { BubbleAnchor anchor; Vec point; float depth; };

bool inAperture(Vec point, const Bubble& bubble, const Scene& view) {
    if (bubble.membraneAnchor <= 0.f) return false;
    const auto gate = view.passages[unsigned(bubble.membraneAnchor)-1];
    const Vec p = point-xyz(gate);
    return length({p.x,p.y*1.13f,p.z*.42f}) < gate.w*.90f;
}

std::optional<Hit> bubbleAt(const Ocean& ocean, const Scene& view, const ShipPose& ship,
                            std::span<const Bubble> visible) {
    const Ray ray = aimRay(view,ship);
    if (dot(ray.direction,xyz(view.forward)) <= .05f) return {};
    std::optional<Hit> best;
    float nearest = std::numeric_limits<float>::infinity();
    for (const auto& bubble : visible) {
        if (bubble.presence < .14f || bubble.flow.z > 0.f) continue;
        const Membrane membrane(bubble,view);
        const Vec origin = membrane.toLocal(ray.eye-membrane.centre);
        const Vec direction = membrane.toLocal(ray.direction);
        const auto bounds = intersect(origin,direction,1.24f);
        if (!bounds || bounds->in >= nearest) continue;
        const unsigned slot = unsigned(bubble.bellSystem);
        auto distance = filmHit(origin,direction,membrane,*bounds);
        std::optional<Hit> candidate;
        if (distance) {
            const float t = *distance;
            const Vec point = ray.eye+ray.direction*t;
            if (inFront(point,ship) && !inAperture(point,bubble,view))
                candidate = Hit{{slot,BubbleAnchor::shell,unit(origin+direction*t)},point,t};
        }
        const auto regions = ocean.regions();
        if (slot > residentSystemCount) {
            const auto& region = regions[slot-residentSystemCount-1];
            const auto systems = ocean.systemBubbles();
            std::optional<Hit> child;
            for (unsigned i = region.firstSystem; i < region.firstSystem+region.systems; ++i) {
                const Quad position = systems[i].position;
                const Vec centre = systemCentre(membrane,position,i,view);
                const float radius = membrane.innerRadius(position.w);
                const float depth = dot(centre-ray.eye,xyz(view.forward));
                if (depth < nearDepth || radius*focal < .0028f*depth) continue;
                const auto hit = intersect(ray.eye-centre,ray.direction,radius);
                if (!hit || hit->in <= nearDepth || (child && hit->in >= child->depth)) continue;
                const Vec point = ray.eye+ray.direction*hit->in;
                if (inFront(point,ship)) child = Hit{{slot,i,unit(point-centre)},point,hit->in};
            }
            if (child) {
                // The film is transparent, so a resolved system can be selected through its own shell.
                candidate = child;
            }
        }
        if (candidate && candidate->depth < nearest) {
            nearest = candidate->depth;
            best = candidate;
        }
    }
    return best;
}

std::optional<HarpoonHit> firstFilm(const Ocean& ocean, const Scene& view, Ray ray,
                                   std::span<const Bubble> visible, float range) {
    const Vec position = ray.eye;
    if (dot(ray.direction,xyz(view.forward)) <= .05f) return {};
    const Bubble* enclosure = nullptr;
    for (const auto& bubble : visible) {
        if (bubble.membraneAnchor > 0.f || bubble.flow.z > 0.f || bubble.presence < .10f ||
            !ocean.canBoardBubble(unsigned(bubble.bellSystem))) continue;
        if (enclosure && enclosure->position.w <= bubble.position.w) continue;
        const Membrane film(bubble,view);
        if (film.surfaceDistance(film.toLocal(position-film.centre)) <= 0.f) enclosure = &bubble;
    }
    std::optional<HarpoonHit> best;
    float nearest = range;
    const auto consider = [&](float t, BubbleAnchor anchor, Vec at, Vec heading, bool inward) {
        if (t <= .0001f || t >= nearest) return;
        best = HarpoonHit{anchor,at,unit(heading),inward};
        nearest = t;
    };
    for (const auto& bubble : visible) {
        if (bubble.presence < .10f || bubble.flow.z > 0.f) continue;
        const unsigned slot = unsigned(bubble.bellSystem);
        const Membrane film(bubble,view);
        const Vec origin = film.toLocal(ray.eye-film.centre), direction = film.toLocal(ray.direction);
        const auto bounds = intersect(origin,direction,1.24f);
        if (!bounds || bounds->in >= nearest) continue;
        const bool allowed = ocean.canBoardBubble(slot);
        const bool inside = film.surfaceDistance(film.toLocal(position-film.centre)) <= 0.f;
        auto t = filmHit(origin,direction,film,*bounds,inside);
        if (t && !inside && inAperture(ray.eye+ray.direction*(*t),bubble,view))
            t = filmHit(origin,direction,film,*bounds,true);
        if (t) {
            const Vec at = ray.eye+ray.direction*(*t);
            if (!inAperture(at,bubble,view))
                consider(*t,{slot,BubbleAnchor::shell,unit(origin+direction*(*t))},at,direction,
                         allowed && !inside && !enclosure);
        }
        // The harpoon stops at a region shell. Its child films are reachable from inside it.
        if (&bubble != enclosure) continue;
        const auto* region = ocean.bubbleRegion(slot);
        if (!region) continue;
        const auto systems = ocean.systemBubbles();
        bool insideSystem = false;
        for (unsigned i = region->firstSystem; i < region->firstSystem+region->systems; ++i) {
            const Quad p = systems[i].position;
            const Vec centre = systemCentre(film,p,i,view);
            if (length(position-centre) <= film.innerRadius(p.w)) { insideSystem = true; break; }
        }
        for (unsigned i = region->firstSystem; i < region->firstSystem+region->systems; ++i) {
            const Quad p = systems[i].position;
            const Vec centre = systemCentre(film,p,i,view);
            const float radius = film.innerRadius(p.w);
            const auto hit = intersect(ray.eye-centre,ray.direction,radius);
            if (!hit) continue;
            const float t = length(position-centre) <= radius ? hit->out : hit->in;
            const Vec at = ray.eye+ray.direction*t;
            consider(t,{slot,i,rotateY(unit(at-centre),-film.yaw)},at,rotateY(ray.direction,-film.yaw),!insideSystem);
        }
    }
    return best;
}

std::optional<HarpoonHit> harpoonAt(const Ocean& ocean, const Scene& view, const ShipPose& ship,
                                   std::span<const Bubble> visible) {
    // Start at the hull. The chase camera can be outside a shell the ship is already inside.
    return firstFilm(ocean,view,{xyz(ship.position),xyz(ship.forward)},visible,
                     std::numeric_limits<float>::infinity());
}

struct Attachment {
    Vec point, normal, centre;
    float radius, presence, hue;
};

std::optional<BubbleId> bubbleIdentity(const Ocean& ocean,const BubbleAnchor& anchor) {
    if (anchor.system!=BubbleAnchor::shell) {
        const auto* region=ocean.bubbleRegion(anchor.bubble);
        if (!region || anchor.system<region->firstSystem || anchor.system-region->firstSystem>=region->systems)
            return {};
        return BubbleId{BubbleKind::System,ocean.systemBubbleIds()[anchor.system]};
    }
    if (const auto* region=ocean.bubbleRegion(anchor.bubble)) return BubbleId{BubbleKind::Region,region->cell};
    if (anchor.bubble==0) return BubbleId{BubbleKind::System,ziksaSystemId};
    if (const auto* system=ocean.bubbleSystem(anchor.bubble)) return BubbleId{BubbleKind::System,system->id};
    return {};
}

std::optional<Attachment> attachment(const Ocean& ocean, const Scene& view, const BubbleAnchor& anchor) {
    const auto bubble = ocean.stringBubble(anchor.bubble,view);
    if (!bubble) return {};
    const Membrane membrane(*bubble,view);
    const Vec direction = anchor.direction;
    if (anchor.system == BubbleAnchor::shell) {
        const auto point = membrane.toWorld(direction*membrane.radius(direction));
        return Attachment{point,membrane.normal(direction),membrane.centre,membrane.innerRadius(1.f),
                          bubble->presence,bubble->pigment.x};
    }
    const auto regions = ocean.regions();
    if (anchor.bubble <= residentSystemCount || anchor.bubble > residentSystemCount+regions.size()) return {};
    const auto& region = regions[anchor.bubble-residentSystemCount-1];
    if (anchor.system < region.firstSystem || anchor.system-region.firstSystem >= region.systems) return {};
    const Quad p = ocean.systemBubbles()[anchor.system].position;
    const float radius = membrane.innerRadius(p.w);
    const Vec centre = systemCentre(membrane,p,anchor.system,view);
    return Attachment{centre+direction*radius,direction,centre,radius,bubble->presence,bubble->pigment.x};
}

float cameraDepth(Vec point, const Scene& view) {
    return dot(point-xyz(view.eye),xyz(view.forward));
}
Vec project(Vec delta, float depth, const Scene& view) {
    return {dot(delta,xyz(view.right))*focal/depth,dot(delta,xyz(view.up))*focal/depth,depth};
}
float lensScale(Vec point, const Scene& view) {
    if (view.graphicsStyle == GraphicsStyle::Painted) return 1.f;
    const float horizontal = point.x/view.screen.x;
    return 1.f/(.977f+.010f*std::min(horizontal*horizontal+point.y*point.y,4.f));
}
Vec aimOnScreen(const Scene& view, const ShipPose& ship) {
    const Ray ray = aimRay(view,ship);
    return project(ray.direction,std::max(.05f,dot(ray.direction,xyz(view.forward))),view);
}

struct Segment { Vec a, b, p, q; float u, v; };

std::optional<Segment> clip(Vec a, Vec b, const Scene& view, float u = 0.f, float v = 1.f) {
    float za = cameraDepth(a,view), zb = cameraDepth(b,view);
    if (std::max(za,zb) < nearDepth) return {};
    if (za < nearDepth) {
        const float fraction = (nearDepth-za)/(zb-za);
        a = mix(a,b,fraction);
        u = std::lerp(u,v,fraction);
        za = nearDepth;
    } else if (zb < nearDepth) {
        const float fraction = (nearDepth-zb)/(za-zb);
        b = mix(b,a,fraction);
        v = std::lerp(v,u,fraction);
        zb = nearDepth;
    }
    const Vec eye = xyz(view.eye);
    const Vec p = project(a-eye,za,view), q = project(b-eye,zb,view);
    constexpr float edge = 1.08f;
    if (std::min(p.x,q.x) > view.screen.x*edge || std::max(p.x,q.x) < -view.screen.x*edge ||
        std::min(p.y,q.y) > edge || std::max(p.y,q.y) < -edge) return {};
    return Segment{a,b,p,q,u,v};
}

Vec surfaceDirection(Vec normal, Vec toward) {
    const Vec side = toward-normal*dot(toward,normal);
    if (dot(side,side) > .0001f) return unit(side);
    const Vec fallback = std::abs(normal.y) < .85f ? Vec{0.f,1.f,0.f} : Vec{1.f,0.f,0.f};
    return unit(cross(fallback,normal));
}

Vec leadOut(Vec normal, Vec toward) {
    const float alignment = dot(normal,toward);
    const Vec side = toward-normal*alignment;
    // Use a surface tangent even on the far side, where a direct line would enter the film.
    const float turn = .44f*(1.f-smooth(-.999f,-.80f,alignment));
    return unit(side+surfaceDirection(normal,toward)*turn+normal*std::max(.36f,alignment));
}

template <class Draw>
void traceString(const Ocean& ocean, const Scene& view, const Attachment& first, const Attachment& second, Draw draw) {
    const Vec a = first.point, b = second.point;
    const Vec axis = unit(b-a);
    const float span = length(b-a);
    if (span <= .0001f) return;
    const auto handleLength = [span](float radius) { return std::clamp(.18f*span+.40f*radius,.20f*span,.32f*span); };
    const Vec start = a+leadOut(first.normal,axis)*handleLength(first.radius);
    const Vec end = b+leadOut(second.normal,axis*(-1.f))*handleLength(second.radius);
    const Vec stream = ocean.waterAt(mix(a,b,.5f)).drift;
    const Vec load = stream*.72f+Vec{0.f,-.65f,0.f};
    const Vec side = load-axis*dot(load,axis);
    const Vec bow = side*(std::min(.24f*span,5.8f)/(.9f+length(side)));
    const Vec ripple = cross(axis,bow)*.20f;
    const float phase = view.celestialTime*1.25f;
    Vec previous = a;
    for (unsigned i = 1; i <= stringSegments; ++i) {
        const float t = float(i)/stringSegments;
        const float v = 1.f-t;
        const Vec point = a*(v*v*v)+start*(3.f*v*v*t)+end*(3.f*v*t*t)+b*(t*t*t)+
                          (bow+ripple*std::sin(8.f*t-phase))*(16.f*t*t*v*v);
        if (const auto section = clip(previous,point,view,float(i-1)/stringSegments,t)) draw(*section);
        previous = point;
    }
}

void drawStroke(std::vector<StringStroke>& strokes, const Segment& section, float a, float b,
                float presence, StringFilm film) {
    strokes.push_back({{section.p.x,section.p.y,section.p.z,section.u},
                       {section.q.x,section.q.y,section.q.z,section.v},
                       {a,b,presence,float(film)}});
}

void drawColourBurst(std::vector<StringStroke>& strokes, const Attachment& site, const Scene& view,
                     float progress, unsigned step, bool finale) {
    // For an enclosing film, place the burst on the string's attachment, where the note originates.
    const float centreDepth = cameraDepth(site.centre,view);
    const Vec centre = centreDepth > site.radius ? site.centre : site.point;
    const float depth = cameraDepth(centre,view);
    if (depth <= nearDepth) return;
    const Vec point = project(centre-xyz(view.eye),depth,view);
    const float radius = std::clamp(focal*site.radius/depth,.025f,finale ? .29f : .19f);
    const float reach = radius*2.35f;
    if (std::abs(point.x) > view.screen.x+reach || std::abs(point.y) > 1.f+reach) return;
    const float hue = site.hue+.273f*float(step);
    drawStroke(strokes,{centre,centre,point,point,radius,1.f},
               progress,hue,site.presence,finale ? StringFilm::Finale : StringFilm::Burst);
}

void drawContact(std::vector<StringContact>& contacts, const Attachment& anchor, const Attachment& other,
                 const Scene& view, bool targeted) {
    if (anchor.presence < .02f) return;
    const float width = std::min(.18f,anchor.radius*.20f);
    if (!clip(anchor.point,anchor.point,view)) return;
    const Vec toward = unit(other.point-anchor.point);
    const Vec tangent = surfaceDirection(anchor.normal,toward);
    const float alignment = dot(anchor.normal,toward);
    const float pull = std::sqrt(std::max(0.f,1.f-alignment*alignment));
    const auto p = anchor.point, normal = anchor.normal;
    contacts.push_back({{p.x,p.y,p.z,width},{normal.x,normal.y,normal.z,anchor.presence},
                        {tangent.x,tangent.y,tangent.z,anchor.hue},{anchor.radius,pull,float(targeted)}});
}

} // namespace

std::optional<BubbleInspection> inspectBubble(const Ocean& ocean, const Scene& view,
                                              std::span<const Bubble> visible) {
    if (view.searchlightOrigin.w <= 0.f) return {};
    const Ray ray{xyz(view.searchlightOrigin),xyz(view.searchlightAxis)};
    const auto hit = firstFilm(ocean,view,ray,visible,view.searchlightOrigin.w*.94f);
    if (!hit) return {};
    const float impactDepth = cameraDepth(hit->impact,view);
    if (impactDepth <= nearDepth) return {};
    const unsigned slot = hit->anchor.bubble;
    const auto bubble = std::find_if(visible.begin(),visible.end(),[slot](const Bubble& item) {
        return unsigned(item.bellSystem) == slot;
    });
    if (bubble == visible.end()) return {};
    const Membrane film(*bubble,view);
    Vec centre = film.centre;
    float radius = 1.12f*std::max({film.axes.x,film.axes.y,film.axes.z});
    const auto id=bubbleIdentity(ocean,hit->anchor);
    if (!id) return {};
    if (hit->anchor.system != BubbleAnchor::shell) {
        const auto index = hit->anchor.system;
        const Quad body = ocean.systemBubbles()[index].position;
        centre = systemCentre(film,body,index,view);
        radius = film.innerRadius(body.w);
    }
    const Vec eye = xyz(view.eye);
    const float depth = cameraDepth(centre,view);
    const float front = std::max(depth,0.f);
    const float apparent = focal*radius/std::sqrt(std::max(nearDepth*nearDepth,front*front-radius*radius));
    const Vec strike = project(hit->impact-eye,impactDepth,view);
    const Vec projection = depth > nearDepth ? project(centre-eye,depth,view) : strike;
    const float lens = lensScale(projection,view);
    const float strikeLens = lensScale(strike,view);
    return BubbleInspection{*id,slot,hit->anchor.system,film.centre,centre,{projection.x*lens,projection.y*lens,apparent*lens,view.screen.x},
                            bubble->palette,{strike.x*strikeLens,strike.y*strikeLens}};
}

bool BubbleStrings::contains(const BubbleAnchor& a, const BubbleAnchor& b) const {
    return std::any_of(links.begin(),links.end(),[&](const Link& link) {
        return (a.sameBubble(link.a) && b.sameBubble(link.b)) ||
               (a.sameBubble(link.b) && b.sameBubble(link.a));
    });
}

BubbleStrings::PassageMatch BubbleStrings::passageMatch(const Ocean& ocean,const PassagePattern& pattern) const {
    struct Node {
        BubbleAnchor anchor;
        BubbleId id;
        bool colour;
        std::vector<std::size_t> adjacent{};
    };
    std::map<BubbleAnchor::Key,std::size_t> indices;
    std::vector<Node> nodes;
    const auto index=[&](const BubbleAnchor& anchor,BubbleId id) {
        const auto [at,added]=indices.try_emplace(anchor.key(),nodes.size());
        if (added) nodes.push_back({anchor,id,ocean.bubbleColourRestored(id)});
        return at->second;
    };
    const auto layer=ocean.oceanDepth();
    for (const auto& link : links) {
        if (ocean.bubbleFlightLayer(link.a.bubble)!=layer || ocean.bubbleFlightLayer(link.b.bubble)!=layer)
            continue;
        const auto a=bubbleIdentity(ocean,link.a), b=bubbleIdentity(ocean,link.b);
        if (!a || !b) continue;
        const auto from=index(link.a,*a), to=index(link.b,*b);
        nodes[from].adjacent.push_back(to);
        nodes[to].adjacent.push_back(from);
    }
    if (nodes.empty()) return {};
    std::vector<bool> sequence;
    for (const auto colour:pattern.colourRuns) {
        if (colour==0) break;
        if (!sequence.empty()) sequence.push_back(false);
        sequence.insert(sequence.end(),colour,true);
    }

    // Walk from either end. Duplicate identities, branches, loops and extra tails
    // cannot fill a position in the required unbranched chain.
    const auto end=nodes.size();
    PassageMatch match;
    for (std::size_t head=0; head<end; ++head) {
        if (nodes[head].adjacent.size()!=1) continue;
        for (const bool reverse:{false,true}) {
            std::set<BubbleId> seen;
            Chain chain;
            std::size_t previous=end, current=head;
            while (chain.size()<sequence.size() && current!=end) {
                const auto& node=nodes[current];
                const bool colour=sequence[reverse ? sequence.size()-1-chain.size() : chain.size()];
                if (node.adjacent.size()>2 || node.colour!=colour || !seen.insert(node.id).second) break;
                chain.push_back(node.anchor);
                auto next=end;
                for (const auto other:node.adjacent)
                    if (other!=previous) next=other;
                previous=current;
                current=next;
            }
            if (chain.size()==sequence.size() && current==end) {
                match.matched=unsigned(chain.size());
                if (head<previous) match.chains.push_back(std::move(chain));
                break;
            }
            match.matched=std::max(match.matched,unsigned(std::min(chain.size(),sequence.size()-1)));
        }
    }
    return match;
}

unsigned BubbleStrings::preparePassage(const Ocean& ocean,unsigned restored,const PassagePattern& pattern) {
    auto match=ocean.passageLocked() && pattern.length() ? passageMatch(ocean,pattern) : PassageMatch{};
    if (restored>=pattern.restored()) readyChains=std::move(match.chains);
    else readyChains.clear();
    if (melody) {
        const auto same=[](const BubbleAnchor& a,const BubbleAnchor& b) { return a.sameBubble(b); };
        const bool valid=melody->layer==ocean.oceanDepth() && std::ranges::any_of(readyChains,[&](const Chain& chain) {
            return std::ranges::equal(chain,melody->chain,same) ||
                   std::equal(chain.begin(),chain.end(),melody->chain.rbegin(),melody->chain.rend(),same);
        });
        if (!valid) melody.reset();
    }
    return match.matched;
}

unsigned BubbleStrings::sequenceNotesPlayed() const { return melody ? melody->played : 0u; }
unsigned BubbleStrings::sequenceLength() const { return melody ? unsigned(melody->chain.size()) : 0u; }

double BubbleStrings::Flash::duration() const {
    if (finale()) return 1.65;
    return length ? 1.02 : .58;
}

void BubbleStrings::beginResonance(unsigned layer) {
    if (!melody) wave=Wave{layer};
}

void BubbleStrings::cancelResonance() {
    wave.reset();
    melody.reset();
    flashes.clear();
}

BubbleStrings::ResonanceFrame BubbleStrings::advanceResonance(Ocean& ocean,const Scene& view,double now) {
    ResonanceFrame frame;
    if (ocean.paused) return frame;
    const auto layer=ocean.oceanDepth();
    if ((wave && wave->layer!=layer) || (melody && melody->layer!=layer)) {
        cancelResonance();
        return frame;
    }
    std::erase_if(flashes,[now,layer](const Flash& flash) {
        return flash.layer!=layer || now-flash.time>=flash.duration();
    });
    const auto ring=[&](const BubbleAnchor& anchor,Vec point,unsigned step=0,unsigned length=0) {
        if (const auto id=bubbleIdentity(ocean,anchor)) {
            std::erase_if(flashes,[&](const Flash& flash) { return flash.bubble.sameBubble(anchor); });
            flashes.push_back({anchor,now,layer,step,length});
            frame.chimes.push_back({*id,point,layer,step,length});
        }
    };

    if (wave && (!ocean.resonantCall() || view.screen.z>=pulseDuration)) wave.reset();
    if (wave) {
        struct Hit { BubbleAnchor anchor; Vec point; float distance; };
        std::vector<Hit> hits;
        const auto origin=xyz(view.player);
        const float radius=view.screen.z*view.call.z;
        const auto contact=[&](const BubbleAnchor& anchor,Vec point) {
            const float distance=length(point-origin);
            if (distance<=radius && wave->reached.insert(anchor.key()).second)
                hits.push_back({anchor,point,distance});
        };
        const auto toward=[&](Vec offset) { return length(offset)>.0001f ? unit(offset) : Vec{1.f,0.f,0.f}; };
        const unsigned slots=unsigned(residentSystemCount+ocean.regions().size()+1);
        for (unsigned slot=0; slot<slots; ++slot) {
            if (ocean.bubbleFlightLayer(slot)!=layer) continue;
            const auto bubble=ocean.stringBubble(slot,view);
            if (!bubble || bubble->presence<.14f) continue;
            const Membrane film(*bubble,view);
            const Vec offset=origin-film.centre;
            if (length(offset)>radius+1.4f*std::max({film.axes.x,film.axes.y,film.axes.z})) continue;
            const Vec direction=toward(film.toLocal(offset));
            contact({slot,BubbleAnchor::shell,direction},film.toWorld(direction*film.radius(direction)));
            if (const auto* region=ocean.bubbleRegion(slot)) {
                for (unsigned i=region->firstSystem; i<region->firstSystem+region->systems; ++i) {
                    if (wave->reached.contains({slot,i})) continue;
                    const Quad body=ocean.systemBubbles()[i].position;
                    const Vec centre=systemCentre(film,body,i,view);
                    const Vec normal=toward(origin-centre);
                    contact({slot,i,normal},centre+normal*film.innerRadius(body.w));
                }
            }
        }
        std::ranges::stable_sort(hits,std::less<>{},&Hit::distance);
        if (!melody && ocean.passageLocked()) {
            for (const auto& hit:hits) {
                const auto onChain=[&](const BubbleAnchor& bubble) { return bubble.sameBubble(hit.anchor); };
                const auto chain=std::ranges::find_if(readyChains,[&](const Chain& c) {
                    return std::ranges::any_of(c,onChain);
                });
                if (chain==readyChains.end()) continue;
                auto order=*chain;
                const auto node=std::ranges::find_if(order,onChain);
                if (node-order.begin()>order.end()-node-1) std::ranges::reverse(order);
                const double spacing=std::clamp(3.8/double(order.size()-1),.13,.33);
                for (const auto& bubble : order) wave->reached.insert(bubble.key());
                melody=Melody{std::move(order),layer,0,now,spacing};
                break;
            }
        }
        if (!hits.empty()) {
            std::set<BubbleAnchor::Key> strung;
            for (const auto& link : links) {
                strung.insert(link.a.key());
                strung.insert(link.b.key());
            }
            for (const auto& hit : hits)
                if (!strung.contains(hit.anchor.key())) ring(hit.anchor,hit.point);
        }
    }

    if (melody && now>=melody->due) {
        auto& phrase=*melody;
        const auto& bubble=phrase.chain[phrase.played];
        if (const auto site=attachment(ocean,view,bubble))
            ring(bubble,site->point,phrase.played,unsigned(phrase.chain.size()));
        ++phrase.played;
        phrase.due=now+phrase.spacing;
        if (phrase.played==phrase.chain.size()) {
            ocean.setUnlockedPassages(ocean.unlockedPassageMask()|(1u<<layer));
            frame.opened=true;
            melody.reset();
        }
    }
    return frame;
}

std::optional<BubbleStrings::Cut> BubbleStrings::cutAt(const Ocean& ocean, const Scene& view, const ShipPose& ship) const {
    const Vec aim = aimOnScreen(view,ship);
    constexpr float tolerance = .021f;
    float best = std::numeric_limits<float>::infinity();
    std::optional<Cut> target;
    for (std::size_t i = 0; i < links.size(); ++i) {
        const auto a = attachment(ocean,view,links[i].a), b = attachment(ocean,view,links[i].b);
        if (!a || !b || std::max(a->presence,b->presence) < .14f) continue;
        traceString(ocean,view,*a,*b,[&](const Segment& section) {
            const Vec across{section.q.x-section.p.x,section.q.y-section.p.y,0.f};
            const Vec offset{aim.x-section.p.x,aim.y-section.p.y,0.f};
            const float t = std::clamp(dot(offset,across)/std::max(.000001f,dot(across,across)),0.f,1.f);
            const float miss = length(offset-across*t);
            if (miss > tolerance) return;
            const float depth = 1.f/((1.f-t)/section.p.z+t/section.q.z);
            const Vec point = mix(section.a,section.b,t*depth/section.q.z);
            if (!inFront(point,ship)) return;
            const float score = miss/tolerance+.09f*std::log1p(depth);
            if (score < best) {
                best = score;
                target = Cut{i,point};
            }
        });
    }
    return target;
}

BubbleStrings::Result BubbleStrings::fire(const Ocean& ocean, const Scene& view, double now) {
    const auto ship = ocean.shipPose(view);
    const Vec nose = xyz(ship.position)+xyz(ship.forward)*(1.45f*ship.position.w);
    if (cutting()) {
        const auto cut = cutAt(ocean,view,ship);
        shot = Shot{nose,cut ? cut->point : nose+xyz(ship.forward)*10.f,now,ShotKind::Disconnect};
        if (!cut) return Result::Miss;
        links.erase(links.begin()+cut->index);
        return Result::Disconnected;
    }
    std::array<Bubble,shoalCapacity> storage;
    const auto hit = bubbleAt(ocean,view,ship,ocean.shoal(view,storage));
    shot = Shot{nose,hit ? hit->point : nose+xyz(ship.forward)*10.f,now,ShotKind::String};
    if (!hit) return Result::Miss;
    if (!pending) {
        pending = hit->anchor;
        return Result::Anchored;
    }
    if (pending->sameBubble(hit->anchor)) return Result::SameBubble;
    if (contains(*pending,hit->anchor)) return Result::AlreadyLinked;
    links.push_back({*pending,hit->anchor});
    pending.reset();
    return Result::Connected;
}

std::optional<HarpoonHit> BubbleStrings::fireHarpoon(const Ocean& ocean, const Scene& view, double now) {
    const auto ship = ocean.shipPose(view);
    std::array<Bubble,shoalCapacity> storage;
    const auto hit = harpoonAt(ocean,view,ship,ocean.shoal(view,storage));
    const Vec origin = xyz(ship.position), direction = xyz(ship.forward);
    const Vec end = hit ? hit->impact : origin+direction*13.f;
    const Vec muzzle = origin+direction*std::min(1.45f*ship.position.w,.25f*length(end-origin));
    shot = Shot{muzzle,end,now,ShotKind::Harpoon};
    return hit;
}

Quad BubbleStrings::compose(const Ocean& ocean, const Scene& view, const ShipPose& ship,
                            std::span<const Bubble> visible, bool steer, double now,
                            std::vector<StringStroke>& strokes, std::vector<StringContact>& contacts) const {
    strokes.clear();
    contacts.clear();
    const auto cut = steer && cutting() ? cutAt(ocean,view,ship) : std::nullopt;
    const bool audibleLink=melody && melody->played>0 && melody->played<melody->chain.size();
    const float travel=audibleLink ? float(std::clamp(1.-(melody->due-now)/melody->spacing,0.,1.)) : 0.f;
    for (std::size_t i = 0; i < links.size(); ++i) {
        const auto a = attachment(ocean,view,links[i].a), b = attachment(ocean,view,links[i].b);
        if (!a || !b) continue;
        const float presence = std::max(a->presence,b->presence);
        if (presence <= .01f) continue;
        const bool targeted = cut && cut->index == i;
        const auto film = targeted ? StringFilm::Target : StringFilm::Strand;
        const auto along=[&](const BubbleAnchor& from,const BubbleAnchor& to) {
            return audibleLink && from.sameBubble(melody->chain[melody->played-1]) &&
                   to.sameBubble(melody->chain[melody->played]);
        };
        const bool forwards=along(links[i].a,links[i].b);
        const bool backwards=along(links[i].b,links[i].a);
        traceString(ocean,view,*a,*b,[&](const Segment& section) {
            drawStroke(strokes,section,a->hue,b->hue,presence,film);
            if (forwards || backwards)
                drawStroke(strokes,section,forwards ? travel : 1.f-travel,0.f,presence,StringFilm::Melody);
        });
        drawContact(contacts,*a,*b,view,targeted);
        drawContact(contacts,*b,*a,view,targeted);
    }
    for (const auto& flash:flashes) {
        const float progress=float((now-flash.time)/flash.duration());
        if (progress<0.f || progress>=1.f) continue;
        if (const auto site=attachment(ocean,view,flash.bubble); site && site->presence>.08f) {
            if (flash.length)
                drawColourBurst(strokes,*site,view,progress,flash.step,flash.finale());
            else if (const auto point=clip(site->point,site->point,view))
                drawStroke(strokes,*point,progress,0.f,site->presence*(1.f-progress),StringFilm::Chime);
        }
    }
    if (!steer) return {};
    if (pending && !cutting() && !harpooning()) {
        if (const auto anchor = attachment(ocean,view,*pending); anchor && anchor->presence > .06f) {
            if (const auto point = clip(anchor->point,anchor->point,view)) {
                drawStroke(strokes,*point,anchor->hue,anchor->hue,anchor->presence,StringFilm::Knot);
            }
        }
    }
    if (shot) {
        const float age = float(now-shot->time);
        const float life = 1.f-smooth(.11f,.35f,age);
        const bool harpoon = shot->kind == ShotKind::Harpoon;
        const float reach = smooth(0.f,harpoon ? .18f : .09f,age);
        if (life > 0.f) {
            if (const auto beam = clip(shot->from,mix(shot->from,shot->to,reach),view)) {
                const auto film = harpoon ? StringFilm::Harpoon : shot->kind == ShotKind::Disconnect ?
                                  StringFilm::Beam : StringFilm::Cast;
                drawStroke(strokes,*beam,.10f,.16f,life,film);
            }
        }
    }
    float state = cutting() ? (cut ? 4.f : 3.f) : (pending ? 2.f : 0.f);
    Vec aim = aimOnScreen(view,ship);
    if (harpooning()) {
        const auto hit = harpoonAt(ocean,view,ship,visible);
        state = hit ? (hit->inward ? 6.f : 7.f) : 5.f;
        if (hit) {
            const float depth = cameraDepth(hit->impact,view);
            if (depth > nearDepth) aim = project(hit->impact-xyz(view.eye),depth,view);
        }
    } else if (!cutting()) {
        if (const auto hit = bubbleAt(ocean,view,ship,visible);
            hit && (!pending || (!pending->sameBubble(hit->anchor) && !contains(*pending,hit->anchor))))
            state = 1.f;
    }
    // The reticule is drawn on top of the finished image, after the scene's lens distortion.
    aim = aim*lensScale(aim,view);
    const float edge = std::max(std::abs(aim.x)/view.screen.x,std::abs(aim.y));
    const float opacity = ship.drive.y*(1.f-smooth(.94f,1.f,edge));
    return {aim.x,aim.y,state,opacity};
}

std::string BubbleStrings::encode() const {
    std::ostringstream out;
    out << std::setprecision(std::numeric_limits<float>::max_digits10);
    const auto anchor = [&](const BubbleAnchor& a) {
        out << a.bubble << ' ' << a.system << ' ' << a.direction.x << ' ' << a.direction.y << ' ' << a.direction.z;
    };
    for (const auto& link : links) {
        anchor(link.a);
        out << ' ';
        anchor(link.b);
        out << '\n';
    }
    return out.str();
}

void BubbleStrings::restore(std::string_view saved, const Ocean& ocean) {
    links.clear();
    const auto view = ocean.scene(1.f);
    std::istringstream input{std::string(saved)};
    std::string line;
    while (std::getline(input,line)) {
        std::istringstream row(line);
        Link link;
        const auto read = [&](BubbleAnchor& a) {
            if (!(row >> a.bubble >> a.system >> a.direction.x >> a.direction.y >> a.direction.z)) return false;
            const float magnitude = length(a.direction);
            if (!std::isfinite(magnitude) || magnitude < .95f || magnitude > 1.05f) return false;
            a.direction = unit(a.direction);
            return attachment(ocean,view,a).has_value();
        };
        if (read(link.a) && read(link.b) && !link.a.sameBubble(link.b) && !contains(link.a,link.b))
            links.push_back(link);
    }
}

} // namespace pelagic
