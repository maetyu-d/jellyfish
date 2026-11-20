#include "Sea.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <numbers>
#include <stdexcept>

namespace pelagic {
namespace {

constexpr float pi = std::numbers::pi_v<float>;
constexpr float tau = 2 * pi;
constexpr double physicsStep = 1.0/90.0;
constexpr unsigned ticksPerTrailSample = 9;
// Retain two completely dark samples for interpolation and one spare for retirement.
static_assert((trailSamples-3)*ticksPerTrailSample*physicsStep > trailLifetime);
constexpr float holdSeconds = .57f;
constexpr float pulseSpeed = 10.6f;
constexpr float drawSpeed = 8.1f;
constexpr unsigned moon = 0, crown = 1, comb = 2;
constexpr float playerSize = 2.65f;
constexpr float shoalHalfWidth = 62.f, shoalHalfHeight = 38.f;
constexpr float shoalBehind = 62.f, shoalAhead = 93.f;
constexpr float streamSpacing = 46.f, eddySpacing = 44.f;
constexpr float eddyOrigin = 14.f;
constexpr std::size_t eclipseGiant = 2;
constexpr std::size_t basinGiant = 3;
constexpr float basinGiantSize = 13.6f;
constexpr float eclipseStation = 166.f;
constexpr std::array<Vec,giantCount> giantPositions{{
    {7.2f,-1.6f,15.7f}, {-12.4f,2.9f,23.f}, {17.8f,6.8f,39.2f}, {-26.2f,-2.6f,62.9f}
}};
constexpr std::array<Vec,giantCount> giantCourses{{
    {.27f,.02f,1.15f}, {.22f,-.03f,.94f}, {-.37f,-.11f,.82f}, {.44f,.12f,.72f}
}};
constexpr std::array<const char*, 4> waterNames{
    "Tidal Blue", "Verdant Fog", "Charred Glass", "Acid Etch"
};
struct Palette { Quad deep, water, bright, contrast; };
constexpr std::array<Palette, 4> palettes{{
    {{.001f,.004f,.027f}, {.004f,.32f,.51f}, {.014f,1.f,.77f}, {.27f,.012f,1.f}},
    {{.001f,.017f,.006f}, {.008f,.36f,.032f}, {.36f,1.f,.014f}, {.025f,.15f,1.f}},
    {{.021f,.001f,.004f}, {.59f,.029f,.006f}, {1.f,.23f,.006f}, {.48f,.012f,1.f}},
    {{.024f,.001f,.035f}, {.61f,.007f,.34f}, {1.f,.82f,.008f}, {.074f,.095f,1.f}}
}};

float dot(Vec a, Vec b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
float length(Vec value) { return std::sqrt(dot(value, value)); }
Vec unit(Vec v) { return v * (1.f / std::max(.001f, length(v))); }
Vec cross(Vec a, Vec b) {
    return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}
Quad packed(Vec v, float w = 0) { return {v.x,v.y,v.z,w}; }
std::uint32_t spread(std::uint32_t v) {
    v ^= v >> 16; v *= 0x7feb352dU; v ^= v >> 15; v *= 0x846ca68bU;
    return v ^ (v >> 16);
}
float range(unsigned seed) { return float(spread(seed) & 0x00ffffffU) / 16777216.f; }
float ease(float value) {
    const float x = std::clamp(value, 0.f, 1.f);
    return x*x*(3-2*x);
}
float eased(float z, float from, float to) { return ease((z-from)/(to-from)); }
float slope(float z, float from, float to) {
    const float v = std::clamp((z-from)/(to-from),0.f,1.f);
    return 6.f*v*(1.f-v)/(to-from);
}
struct Reach {
    Vec centre, tangent;
    float narrows, basin, flow;
};
Reach openingAt(float z) {
    const float first = eased(z,34.f,89.f), second = eased(z,105.f,161.f);
    const float exit = eased(z,165.f,218.f);
    const float dive = eased(z,45.f,126.f), rise = eased(z,150.f,216.f);
    const float narrow = eased(z,48.f,76.f)*(1.f-eased(z,142.f,181.f));
    return {{2.f+8.f*first-18.f*second+10.f*exit,.65f-4.3f*dive+4.8f*rise,z},
            {8.f*slope(z,34.f,89.f)-18.f*slope(z,105.f,161.f)+10.f*slope(z,165.f,218.f),
             -4.3f*slope(z,45.f,126.f)+4.8f*slope(z,150.f,216.f),1.f},
            narrow,eased(z,155.f,214.f),
            eased(z,7.f,34.f)*(1.f-eased(z,196.f,253.f))};
}
float openingMask(Vec p) {
    return eased(p.z,-50.f,-12.f)*(1.f-eased(p.z,280.f,348.f))*
           (1.f-eased(std::abs(p.x),30.f,67.f))*(1.f-eased(std::abs(p.y),19.f,43.f));
}
float reachCore(Vec p, const Reach& reach) {
    const float dx = (p.x-reach.centre.x)/std::lerp(8.5f,5.f,reach.narrows);
    const float dy = (p.y-reach.centre.y)/std::lerp(6.5f,4.5f,reach.narrows);
    return std::exp(-dx*dx-dy*dy);
}
float shoalFade(Vec offset) {
    return ease((shoalHalfWidth-1.f-std::abs(offset.x))/18.f)*
           ease((shoalHalfHeight-1.f-std::abs(offset.y))/16.f)*
           ease((offset.z+shoalBehind-1.f)/22.f)*
           ease((shoalAhead-1.f-offset.z)/28.f);
}
float planktonFade(Vec offset) {
    return ease((48.f-std::abs(offset.x))/12.f)*ease((25.f-std::abs(offset.y))/9.f)*
           ease((offset.z+15.f)/13.f)*ease((85.f-offset.z)/18.f);
}
float currentStrength(const Water& water) {
    return ease((std::max({water.stream,.88f*water.eddy,water.wake})-.13f)*1.32f);
}
Vec limited(Vec value, float cap) {
    return value * (cap / std::max(cap,length(value)));
}
Vec unpack(Quad value) { return {value.x,value.y,value.z}; }
float approachAngle(float from, float to, float amount) {
    return std::remainder(from+std::remainder(to-from,tau)*amount,tau);
}
Vec pressure(Vec offset, float clearance) {
    const float distance = length(offset);
    return offset*(std::max(0.f,clearance-distance)/std::max(.05f,distance));
}
float logRange(float v, float lo, float hi) { return std::clamp((v-lo)/(hi-lo), 0.f, 1.f); }
Vec hue(float h) {
    return {.55f + .43f*std::cos(tau*h), .55f + .43f*std::cos(tau*(h-.33f)),
            .55f + .43f*std::cos(tau*(h-.67f))};
}
Vec facing(float yaw, float pitch) {
    return {std::sin(yaw)*std::cos(pitch), std::sin(pitch), std::cos(yaw)*std::cos(pitch)};
}
Vec streamAtLane(float lane, float z, float t) {
    const float q = z*.081f+t*.047f;
    return {5.3f+3.2f*std::sin(q)+streamSpacing*lane,1.4f+1.7f*std::sin(q*.67f+.3f),z};
}
Vec streamCentre(float x, float z, float t) {
    const Vec origin = streamAtLane(0,z,t);
    return origin+Vec{streamSpacing*std::round((x-origin.x)/streamSpacing),0,0};
}
Vec eddyAtCell(float lane, float cell, float t) {
    return {-8.2f+1.7f*std::sin(cell*2.4f+t*.036f)+streamSpacing*lane,
            -.7f,eddyOrigin+cell*eddySpacing};
}
Vec eddyCentre(float x, float z, float t) {
    const float cell = std::round((z-eddyOrigin)/eddySpacing);
    const Vec origin = eddyAtCell(0,cell,t);
    return origin+Vec{streamSpacing*std::round((x-origin.x)/streamSpacing),0,0};
}
} // namespace

const std::array<Current, 8> currents{{
    {"Noctiluca", "Tidal Blue", 16142, 0},
    {"Verdigris", "Verdant Fog", 14538, 1},
    {"Glasswake", "Charred Glass", 14940, 2},
    {"Sulphur Bloom", "Acid Etch", 16134, 3},
    {"Moon Milk", "Tidal Blue", 63, 0},
    {"Sargasso", "Verdant Fog", 70, 1},
    {"Ember Trench", "Charred Glass", 68, 2},
    {"Orchid Rill", "Acid Etch", 66, 3}
}};

Vec Vec::operator+(Vec b) const { return {x+b.x,y+b.y,z+b.z}; }
Vec Vec::operator-(Vec b) const { return {x-b.x,y-b.y,z-b.z}; }
Vec Vec::operator*(float s) const { return {x*s,y*s,z*s}; }
Vec& Vec::operator+=(Vec b) { return *this = *this + b; }

void Ocean::updateWake(std::size_t index) {
    const auto& giant = animals[index];
    const Vec axis = unit(giant.velocity+Vec{0,0,.26f});
    wakeFlow[index] = {axis,unit(cross({0,1,0},axis)),shoalFade(giant.p-player),
                       1.35f+.30f*std::min(2.1f,length(giant.velocity))};
}

Water Ocean::waterAt(Vec p, bool withWake, std::size_t ignoreGiant) const {
    const float route = openingRoute() ? openingMask(p) : 0.f;
    const Vec stream = streamCentre(p.x,p.z,clock);
    const float dx = p.x-stream.x, dy = p.y-stream.y;
    float channel = std::exp(-dx*dx/15.f-dy*dy/13.f)*(1.f-.97f*route);
    const float turnRate = p.z*.081f+clock*.047f;
    const Vec course = {.259f*std::cos(turnRate),.092f*std::cos(turnRate*.67f+.3f),1.f};
    Vec drift = Vec{.19f*std::sin(p.y*.19f+p.z*.083f+clock*.12f),
                    .12f*std::sin(p.x*.19f-clock*.17f),.26f}+course*(2.55f*channel);
    if (route > 0.f) {
        const auto reach = openingAt(p.z);
        const float core = reachCore(p,reach);
        const float running = route*reach.flow*core;
        const Vec side = reach.centre-p;
        drift += reach.tangent*(1.90f*running)+side*(.19f*running);
        if (withWake && ignoreGiant != eclipseGiant) drift += eclipseWash(p)*route;
        channel += running;
    }

    const Vec turn = p-eddyCentre(p.x,p.z,clock);
    const float r2 = turn.x*turn.x+turn.z*turn.z;
    const float spin = std::exp(-r2/75.f-turn.y*turn.y/24.f)*
                       ease((eddySpacing*.5f-std::abs(turn.z))/5.f)*
                       ease((streamSpacing*.5f-std::abs(turn.x))/5.f)*(1.f-.93f*route);
    drift += Vec{turn.z,0,-turn.x}*(.49f*spin);
    const float still = std::exp(-r2/6.1f-turn.y*turn.y/9.f)*(1.f-.96f*route);
    drift = drift*(1.f-.95f*still);
    float lee = 0.f, wake = 0.f;
    Vec wakeDrift{};
    for (std::size_t i = 0; withWake && i < giantCount; ++i) {
        if (i == ignoreGiant) continue;
        const auto& giant = animals[i];
        const auto& flow = wakeFlow[i];
        const Vec offset = p-giant.p;
        if (flow.presence <= 0.f || dot(offset,offset) > 1040.f) continue;
        const Vec axis = flow.axis;
        const float behind = -dot(offset,axis);
        if (behind <= 0.f || behind >= 27.f) continue;
        const Vec away = offset+axis*behind;
        const float spread = giant.size*.62f+.15f*behind;
        const float envelope = std::exp(-dot(away,away)/(spread*spread))*flow.presence;
        lee = std::max(lee,envelope*ease(behind/1.4f)*(1.f-ease((behind-2.8f)/2.8f)));
        const float slipstream = envelope*ease((behind-3.0f)/4.6f)*(1.f-ease((behind-16.f)/10.f));
        wake = std::max(wake,slipstream);
        const float flank = dot(away,flow.side);
        const Vec curl = cross(axis,away)*(.18f*std::clamp(flank,-1.f,1.f));
        wakeDrift += (axis*flow.thrust+curl)*slipstream;
    }
    drift = drift*(1.f-.94f*lee) + limited(wakeDrift,2.65f);

    const WaterKind kind = std::max(lee,still) > .55f ? WaterKind::Still :
                           wake > .49f ? WaterKind::Wake :
                           channel > .47f ? WaterKind::Stream :
                           spin > .41f && r2 > 4.f ? WaterKind::Eddy : WaterKind::Open;
    return {drift,kind,channel,spin*(1.f-still),wake};
}

Vec Ocean::eclipseWash(Vec point) const {
    if (std::abs(point.z-eclipseStation) > 49.f) return {};
    const auto& giant = animals[eclipseGiant];
    const float distance = point.z-giant.p.z+10.f;
    const float side = point.x-giant.p.x+giant.velocity.x*1.8f-distance*.11f;
    const float height = point.y-giant.p.y+9.5f;
    const float falloff = side*side*.029f+distance*distance*.0049f+height*height*.034f;
    if (falloff > 6.f) return {};
    const float strength = std::exp(-falloff)*(1.f-eased(falloff,4.f,6.f));
    const float swirl = std::sin(giant.phase-.19f*side+.085f*distance);
    return Vec{.34f*giant.velocity.x+.72f*swirl,-.44f-.19f*swirl,.28f}*strength;
}

Ocean::Ocean(const std::filesystem::path& catalogue) {
    std::ifstream file(catalogue);
    std::string version;
    std::getline(file, version);
    if (version != "PELAGIC 1") throw std::runtime_error("The orbital catalogue could not be opened.");
    System entry;
    while (file >> entry.id >> entry.radius >> entry.temperature >> entry.count) {
        if (entry.count > entry.orbits.size() || (!systems.empty() && entry.id <= systems.back().id))
            throw std::runtime_error("Invalid orbital catalogue.");
        for (unsigned i = 0; i < entry.count; ++i) {
            auto& body = entry.orbits[i];
            if (!(file >> body.radius >> body.distance >> body.period >> body.heat >> body.material
                       >> body.clouds >> body.rings >> body.tilt))
                throw std::runtime_error("Incomplete orbital data.");
        }
        systems.push_back(entry);
    }
    if (systems.empty()) throw std::runtime_error("The orbital catalogue is empty.");
    visited.resize(systems.size());
    arrive(0);
}
void Ocean::arrive(unsigned destination) {
    active = destination;
    if (destination < currents.size()) {
        const auto& locate = currents[destination];
        const auto it = std::lower_bound(systems.begin(), systems.end(), locate.id,
            [](const System& system, unsigned id) { return system.id < id; });
        if (it == systems.end() || it->id != locate.id) throw std::runtime_error("Featured system missing.");
        index = unsigned(it - systems.begin());
        palette = locate.palette;
    } else {
        index = (destination - unsigned(currents.size())) % systems.size();
        palette = spread(systems[index].id / 400U + 672U) % palettes.size();
    }
    visited[index] = true;
    player = {}; velocity = {}; eye = {}; tailSlip = {};
    yaw = 0; pitch = 0; lookYaw = 0; lookPitch = 0; bodyYaw = 0;
    lastPulse = clock-10.f; answers = 0; accent = 0;
    companions = 0; synchronised = 0; lastCall = Call::Pulse;
    meeting = Encounter::None;
    crownGuest = jellyfishCount;
    replyCount = 0;
    demoCalled = false;
    cancelCall();
    population();
    for (std::size_t i = 0; i < giantCount; ++i) updateWake(i);
    for (std::size_t i = 0; i < plankton.size(); ++i) {
        plankton[i].seed = spread(systems[index].id*31U+unsigned(i)*83U);
        plantPlankter(i,true);
    }
    buildRibbons();
    nextTrailSlot = 0; trailCount = 0; trailTicks = 0;
    recordTrails();
}
void Ocean::population() {
    const unsigned seed = systems[index].id;
    for (unsigned i = 0; i < animals.size(); ++i) {
        const unsigned key = spread(seed * 887U + i*13U);
        const float angle = range(key+1)*tau;
        const float orbit = 5.f + 50.f*std::pow(range(key+2), .72f);
        Animal animal;
        animal.p = {std::cos(angle)*orbit, std::sin(angle)*orbit*.53f, -2.5f + 87.f*range(key+3)};
        animal.seed = key;
        animal.size = .85f + 2.50f*std::pow(range(key+4),2.f);
        animal.phase = range(key+5)*tau;
        animal.hue = range(key+6);
        animal.kind = spread(key+7)%3U;
        animal.velocity = {0,0,.45f};
        animals[i] = animal;
    }
    constexpr std::array<float,giantCount> size{5.6f,6.5f,7.4f,8.2f};
    constexpr std::array<float,giantCount> colour{.35f,.78f,.10f,.53f};
    for (std::size_t i = 0; i < giantCount; ++i) {
        auto& giant = animals[i];
        giant.p = giantPositions[i];
        giant.velocity = giantCourses[i];
        giant.kind = crown;
        giant.size = size[i];
        giant.hue = colour[i];
    }
    for (unsigned i = 0; i < 14; ++i) {
        auto& jelly = animals[i+giantCount];
        const bool nearEddy = i < 7;
        const Vec centre = nearEddy ? Vec{-5.2f,.55f,8.6f} : Vec{5.8f,2.65f,10.8f};
        const float slot = float(i%7);
        jelly.p = centre+Vec{(slot-3.f)*.93f,(range(jelly.seed+10)-.5f)*5.f,
                             (range(jelly.seed+11)-.5f)*7.5f};
        jelly.velocity = {nearEddy ? .85f : -.85f,0,.55f};
        jelly.kind = nearEddy ? moon : comb;
        jelly.cohort = nearEddy ? 1 : 2;
        jelly.size = i%3 == 0 ? .44f+.31f*range(jelly.seed+8) : 1.16f+.87f*range(jelly.seed+8);
    }
    if (openingRoute()) {
        constexpr std::array<Vec,giantCount> stations{{
            {5.2f,1.5f,36.f}, {14.f,2.2f,232.f}, {-37.f,5.55f,eclipseStation}, {22.f,12.f,313.f}
        }};
        constexpr std::array<float,giantCount> residentSize{4.14f,4.75f,8.65f,basinGiantSize};
        for (std::size_t i = 0; i < animals.size(); ++i) {
            auto& jelly = animals[i];
            const auto key = jelly.seed;
            if (i < giantCount) {
                jelly.home = stations[i];
                jelly.velocity = {.16f,0,.27f};
                jelly.size = residentSize[i];
                if (i == eclipseGiant) jelly.hue = .61f;
                if (i == basinGiant) jelly.hue = .58f;
            } else if (i < giantCount+6) {
                const float z = 105.f+float(i-giantCount)*11.f;
                const auto reach = openingAt(z);
                jelly.home = reach.centre+Vec{i%2 == 0 ? -5.5f : 5.5f,
                                             -5.f+8.f*range(key+8),0.f};
                jelly.kind = i%2 == 0 ? moon : comb;
                jelly.cohort = 0;
            } else {
                const bool left = i%2 == 0;
                const float layer = float(((i-giantCount-6)/2)%3);
                const float arm = (left ? -1.f : 1.f)*(4.f+24.f*range(key+14)+2.5f*layer);
                jelly.home = {arm,-8.f+19.f*range(key+15)+2.f*layer,216.f+27.f*layer+19.f*range(key+16)};
                jelly.kind = left ? moon : comb;
                jelly.cohort = left ? 1 : 2;
                if (layer == 2.f || (i%5 == 0 && layer == 0.f))
                    jelly.size = .39f+.44f*range(key+8);
            }
            jelly.p = jelly.home;
        }
        buildBanks();
    }
}
bool Ocean::beginCall() {
    if (callStart >= 0.f || migrating() || paused) return false;
    callStart = clock;
    return true;
}
float Ocean::callCharge() const {
    return callStart < 0.f ? 0.f : ease((clock-callStart)/holdSeconds);
}
bool Ocean::releaseCall() {
    if (callStart < 0.f) return false;
    const bool held = clock-callStart >= holdSeconds;
    cancelCall();
    return pulse(held ? Call::Draw : Call::Pulse);
}
std::size_t Ocean::nearestCrown() const {
    std::size_t best = jellyfishCount;
    float distance = 44.f;
    for (std::size_t i = 0; i < animals.size(); ++i) {
        const auto& jelly = animals[i];
        if (jelly.kind != crown) continue;
        const float reach = length(jelly.p-player);
        if (reach < distance) { best = i; distance = reach; }
    }
    return best;
}
bool Ocean::crownInRange() const { return nearestCrown() != jellyfishCount; }
std::span<const Reply> Ocean::takeReplies() {
    const auto ready = std::span<const Reply>(replies).first(replyCount);
    replyCount = 0;
    return ready;
}
bool Ocean::pulse(Call type) {
    if (clock-lastPulse < .83f || migrating() || paused) return false;
    lastPulse = clock;
    lastCall = type;
    ++callNumber;
    pulseOrigin = player;
    answers = 0;
    accent = 1.f;
    note = 1.f;
    const bool held = type == Call::Draw;
    if (held && meeting != Encounter::Alongside && meeting != Encounter::Approaching) {
        crownGuest = nearestCrown();
        meeting = crownGuest < jellyfishCount ? Encounter::Calling : Encounter::None;
        encounterUntil = clock+8.f;
    }
    for (auto& jelly : animals) {
        const float distance = length(jelly.p - player);
        if (!held && meeting == Encounter::Calling && jelly.kind == crown) continue;
        jelly.due = -1.f;
        jelly.relay = 0;
        if (held && meeting == Encounter::Calling && &jelly == animals.data()+crownGuest)
            jelly.due = clock+distance/drawSpeed+.24f;
        if (!held && jelly.kind != crown && distance < (jelly.kind == moon ? 20.f : 15.f))
            jelly.due = clock+distance/pulseSpeed+(jelly.kind == moon ? .09f : .29f);
    }
    return true;
}
void Ocean::voyage(unsigned destination) {
    if (migrating() || destination == active || destination >= currents.size()+systems.size()) return;
    target = destination;
    transition = 0;
    cancelCall();
}
void Ocean::next() {
    if (migrating()) return;
    if (active < currents.size()-1) {
        voyage(active+1);
    } else {
        uncharted();
    }
}
void Ocean::uncharted() {
    if (migrating()) return;
    ++generation;
    const unsigned offset = (2999U + generation*3499U) % systems.size();
    voyage(unsigned(currents.size())+offset);
}
void Ocean::plantPlankter(std::size_t slot, bool arriving) {
    auto& mote = plankton[slot];
    const unsigned seed = mote.seed = spread(mote.seed+9381U);
    const float z = player.z+(range(seed+1)*70.f-7.f);
    const Vec ambient = player+Vec{(range(seed+2)-.5f)*67.f,(range(seed+3)-.5f)*34.f,z-player.z};
    Vec p = ambient;
    const bool foreground = slot%13 == 3;
    if (foreground) {
        const Vec forward = facing(yaw,pitch);
        const Vec right = unit(cross({0,1,0},forward));
        const Vec up = cross(forward,right);
        p = eye+forward*(range(seed+1)*11.f-7.f)+right*((range(seed+2)-.5f)*13.f)+
            up*((range(seed+3)-.5f)*9.f-1.9f);
    } else if (slot%5 == 0) {
        const auto reach = openingAt(z);
        const bool route = openingRoute() && openingMask(player) > .5f && reach.flow > .12f;
        const auto centre = route ? reach.centre : streamCentre(player.x,z,clock);
        p = centre+Vec{(range(seed+2)-.5f)*7.4f,(range(seed+3)-.5f)*5.8f,0};
    } else if (slot%5 == 1) {
        const Vec centre = eddyCentre(player.x,z,clock);
        const float angle = range(seed+4)*tau, radius = 2.9f+range(seed+5)*6.5f;
        p = centre+Vec{std::cos(angle)*radius,(range(seed+3)-.5f)*8.0f,std::sin(angle)*radius};
    } else if (slot%11 == 2) {
        const auto index = (slot/11)%giantCount;
        const auto& giant = animals[index];
        const Vec axis = wakeFlow[index].axis;
        p = giant.p-axis*(4.f+15.f*range(seed+4))+
            Vec{(range(seed+2)-.5f)*6.f,(range(seed+3)-.5f)*4.f,0};
    }
    // Fall back to the local water when a particular feature has drifted out of range.
    if (planktonFade(p-player) < .10f) p = ambient;
    const auto water = waterAt(p);
    const float current = currentStrength(water);
    mote.p = p;
    mote.tail = p-water.drift*(.35f+.52f*current);
    mote.lifetime = foreground ? 12.f+14.f*range(seed+6) : 22.f+23.f*range(seed+6);
    mote.age = arriving ? 2.f+range(seed+7)*(mote.lifetime-5.f) : 0.f;
    const float width = std::pow(range(seed+8),2.6f);
    mote.width = foreground ? .010f+.018f*width : .016f+.039f*width;
    const float light = .29f+.67f*current;
    const float opacity = arriving ? light*planktonFade(mote.p-player) : 0.f;
    planktonView[slot] = {packed(mote.p,mote.width),packed(mote.tail,opacity),ease(water.wake),current};
}
void Ocean::advancePlankton(float dt) {
    const float smoothing = 1.f-std::exp(-dt*3.2f);
    for (std::size_t i = 0; i < plankton.size(); ++i) {
        auto& mote = plankton[i];
        const Vec offset = mote.p-player;
        mote.age += dt;
        if (mote.age >= mote.lifetime || std::abs(offset.x) > 49.f ||
            std::abs(offset.y) > 26.f || offset.z < -16.f || offset.z > 86.f) {
            plantPlankter(i,false);
            continue;
        }
        const auto water = waterAt(mote.p);
        const float current = currentStrength(water);
        mote.p += waterAt(mote.p+water.drift*(dt*.5f)).drift*dt;
        const float trail = .04f+.52f*current;
        mote.tail += (mote.p-water.drift*trail-mote.tail)*smoothing;
        const float fade = ease(mote.age*.63f)*ease((mote.lifetime-mote.age-.22f)*.55f)*
                           planktonFade(mote.p-player);
        const float opacity = fade*(.29f+.67f*current);
        planktonView[i] = {packed(mote.p,mote.width),packed(mote.tail,opacity),ease(water.wake),current};
    }
}
void Ocean::buildRibbons() {
    const float streamLane = std::floor((player.x-streamAtLane(0,player.z,clock).x)/streamSpacing);
    const float eddyCell = std::floor((player.z-eddyOrigin)/eddySpacing);
    const float route = openingRoute() ? openingMask(player) : 0.f;
    const auto visibleLines = openingRoute() ? flowLines+guideLines+sheetLines : flowLines;
    for (std::size_t line = 0; line < visibleLines; ++line) {
        const bool stream = line < streamLines;
        const bool eddy = !stream && line < streamLines+eddyLines;
        const float type = stream ? 0.f : eddy ? 1.f : 2.f;
        Vec p;
        float presence, phaseOffset;
        auto* nodes = flowView.data()+line*flowNodes;
        if (line >= flowLines) {
            const bool sheet = line >= flowLines+guideLines;
            const float band = float(line-flowLines)-3.f;
            const float layer = float(line-flowLines)-(float(guideLines)+1.f);
            for (std::size_t node = 0; node < flowNodes; ++node) {
                const float z = player.z-23.f+float(node)*2.55f;
                const auto reach = openingAt(z);
                const float width = std::lerp(1.42f,1.00f,reach.narrows);
                const float extent = float(node)/float(flowNodes-1);
                const float shape = ease(extent*5.f)*ease((1.f-extent)*5.f);
                const Vec offset = sheet ?
                    Vec{layer*.89f+1.12f*std::sin(z*.102f+layer*2.1f),layer*2.42f-1.22f,0.f} :
                    Vec{width*band+.24f*std::sin(z*.15f+band),.58f*std::cos(band*1.67f+z*.044f),0.f};
                const Vec path = reach.centre+offset;
                const Vec swept = path+eclipseWash(path)*4.8f;
                const float light = route*reach.flow*shape;
                if (sheet) {
                    const float span = std::lerp(7.9f,5.15f,reach.narrows)*(1.f+.09f*layer);
                    nodes[node] = {packed(swept,span),{z,5.f,layer,light}};
                } else {
                    nodes[node] = {packed(swept,.75f+.73f*reach.flow),
                                   {z+band*2.13f,4.f,.30f+1.90f*reach.flow,light*(1.f-.085f*std::abs(band))}};
                }
            }
            continue;
        }
        if (stream) {
            const float z = player.z-27.f;
            const float lane = streamLane+float(line/linesPerStream);
            const float band = float(line%linesPerStream);
            p = streamAtLane(lane,z,clock)+
                Vec{(band-3.f)*.82f,1.3f*std::cos(band*1.78f)-.60f,0};
            presence = ease((42.f-std::abs(player.x-streamAtLane(lane,player.z,clock).x))/18.f);
            phaseOffset = band*2.13f+std::remainder(lane,29.f)*.91f;
        } else if (eddy) {
            const std::size_t strip = line-streamLines;
            const std::size_t group = strip/linesPerEddy;
            const unsigned band = unsigned(strip%linesPerEddy);
            const float cell = eddyCell+float(group/2);
            const float lane = std::floor((player.x-eddyAtCell(0,cell,clock).x)/streamSpacing)+float(group%2);
            const Vec centre = eddyAtCell(lane,cell,clock);
            const float angle = float(band)*tau/float(linesPerEddy);
            const float radius = 4.1f+float(band%3)*.79f;
            p = centre+Vec{radius*std::cos(angle),-.64f+float(band%3)*.77f,radius*std::sin(angle)};
            presence = ease((42.f-std::abs(centre.x-player.x))/19.f)*
                       ease((40.f-std::abs(centre.z-player.z))/19.f);
            phaseOffset = float(band)*2.13f+std::remainder(lane+1.9f*cell,29.f)*.91f;
        } else {
            const unsigned band = unsigned(line-streamLines-eddyLines);
            const auto index = band/3;
            const auto& flow = wakeFlow[index];
            p = animals[index].p-flow.axis*20.f+flow.side*(float(int(band%3)-1)*1.49f)+Vec{0,-.64f,0};
            presence = flow.presence;
            phaseOffset = float(band)*2.13f;
        }
        if (stream || eddy) presence *= 1.f-.97f*route;
        if (presence <= 0.f) {
            std::fill_n(nodes,flowNodes,FlowNode{});
            continue;
        }
        const float dt = stream ? .76f : eddy ? .67f : .47f;
        float distance = 0.f;
        for (std::size_t node = 0; node < flowNodes; ++node) {
            const auto water = waterAt(p);
            const float speed = length(water.drift);
            const float limit = stream ? water.stream : eddy ? water.eddy : water.wake;
            const float extent = float(node)/float(flowNodes-1);
            const float envelope = ease(extent*7.f)*ease((1.f-extent)*6.f);
            const float horizon = ease((86.f-length(p-player))/22.f);
            const float width = (stream ? .85f : eddy ? .50f : .56f) *
                                (.77f+.33f*limit);
            const float phase = (stream ? p.z : distance)+phaseOffset;
            nodes[node] = {packed(p,width),
                {phase,type,speed,presence*envelope*horizon*ease((limit-.13f)*1.75f)}};
            const Vec step = waterAt(p+water.drift*(dt*.5f)).drift*dt;
            distance += length(step);
            p += step;
        }
    }
}
void Ocean::buildBanks() {
    for (std::size_t line = 0; line < bankLines; ++line)
        for (std::size_t node = 0; node < flowNodes; ++node) {
            const float z = 46.f+float(node)*(140.f/float(flowNodes-1));
            const auto reach = openingAt(z);
            const float side = line%2 == 0 ? -1.f : 1.f;
            const float layer = float(line/2);
            const float bank = std::lerp(20.f,9.f,reach.narrows)+layer*7.f;
            const float fold = (1.f+layer)*std::sin(z*.143f+side*2.1f);
            const Vec p = reach.centre+Vec{side*(bank+fold),layer*4.f-1.6f,0.f};
            flowView[(flowLines+guideLines+sheetLines+line)*flowNodes+node] = {
                packed(p,13.f+layer*8.f+2.8f*std::sin(z*.091f)),
                {z,3.f,side,reach.narrows*(1.f-layer*.44f)}
            };
        }
}
void Ocean::answerCalls() {
    for (std::size_t i = 0; i < animals.size(); ++i) {
        auto& jelly = animals[i];
        if (jelly.due < 0 || clock < jelly.due) continue;
        jelly.due = -1.f;
        jelly.answered = callNumber;
        jelly.response = clock;
        ++answers;
        note = std::max(note,jelly.kind == crown ? .54f : .38f);
        if (replyCount < replies.size()) replies[replyCount++] = {jelly.p,jelly.kind == crown,answers};
        if (jelly.kind == crown) {
            if (meeting == Encounter::Calling && i == crownGuest) {
                meeting = Encounter::Approaching;
                encounterUntil = clock+28.f;
                const auto right = cross({0,1,0},facing(bodyYaw,0.f));
                guestSide = dot(jelly.p-player,right) >= 0.f ? -1.f : 1.f;
            }
            continue;
        }
        if (lastCall == Call::Draw) continue;
        if (jelly.kind != moon || jelly.relay >= 3) continue;
        for (auto& other : animals) {
            if (other.kind == crown || other.answered == callNumber) continue;
            const float separation = length(other.p-jelly.p);
            const float reaches = clock+.17f+separation/pulseSpeed;
            if (separation < 9.6f && (other.due < 0 || reaches < other.due)) {
                other.due = reaches;
                other.relay = jelly.relay+1;
            }
        }
    }
}
void Ocean::advanceShoal(float dt) {
    if (meeting != Encounter::None && clock >= encounterUntil) {
        meeting = Encounter::None;
        crownGuest = jellyfishCount;
    }
    answerCalls();
    const auto previous = animals;
    const Vec forward = facing(bodyYaw,0.f);
    const Vec right = cross({0,1,0},forward);
    companions = 0;
    synchronised = 0;
    const bool resident = openingRoute();
    const float gathering = resident ? eased(player.z,156.f,213.f) : 0.f;
    for (std::size_t i = 0; i < animals.size(); ++i) {
        auto& jelly = animals[i];
        const auto& before = previous[i];
        const auto current = waterAt(before.p,true,i);
        Vec swimming{std::sin(jelly.hue*tau+clock*.33f)*.29f,
                     std::cos(jelly.phase)*.18f, .35f+.24f*std::cos(jelly.hue*tau)};
        float rate = 2.34f-.30f*float(jelly.kind);
        if (i < giantCount && !resident) rate /= 1.f+.13f*(jelly.size-3.4f);
        if (resident) {
            const float tide = clock*.073f+float(i)*1.71f;
            const Vec circling{2.1f*std::sin(tide),.95f*std::cos(tide*.79f),2.7f*std::cos(tide)};
            const Vec approach = jelly.cohort ? Vec{-jelly.home.x*.56f,0,(251.f-jelly.home.z)*.28f} : Vec{};
            Vec home = jelly.home+circling+approach*gathering;
            if (i == eclipseGiant) {
                const float traverse = eased(player.z,120.f,185.f);
                home = jelly.home+Vec{54.f*traverse,.52f*std::sin(tide),1.05f*std::cos(tide*.58f)};
                rate = .91f;
            } else if (i == basinGiant) {
                home = jelly.home+Vec{8.4f*std::sin(tide*.58f),2.6f*std::cos(tide*.47f),
                                     4.2f*std::cos(tide*.52f)};
                rate = .66f;
            }
            const bool crossing = i == eclipseGiant;
            const Vec patrol = limited((home-before.p)*(crossing ? .49f : .36f),crossing ? 2.6f : 1.8f)-current.drift;
            swimming = swimming*.38f+patrol;
        }
        if (jelly.kind == crown) {
            if (!resident && i < giantCount) swimming += giantCourses[i]*.59f;
            if (i == crownGuest && (meeting == Encounter::Approaching || meeting == Encounter::Alongside)) {
                const float curve = meeting == Encounter::Approaching ?
                    ease((clock+24.f-encounterUntil)/7.f) : 1.f;
                const Vec shoulder = player+right*(guestSide*(4.2f+jelly.size*.82f))+
                                     forward*std::lerp(7.7f,2.5f,curve)+Vec{0,1.0f,0};
                const Vec separation = shoulder-before.p;
                const Vec approach = limited(separation*.66f,3.7f)+velocity*.91f;
                swimming = approach-current.drift;
                if (meeting == Encounter::Approaching && curve > .7f && length(separation) < 3.8f) {
                    meeting = Encounter::Alongside;
                    alongsideSince = clock;
                    encounterUntil = clock+17.f;
                    if (replyCount < replies.size()) replies[replyCount++] = {jelly.p,true,0};
                }
                if (meeting == Encounter::Alongside) {
                    const float release = ease((encounterUntil-clock)/3.f);
                    rate = std::lerp(rate,2.34f,release*.77f);
                }
                ++companions;
            }
        } else {
            Vec neighbours{}, course{}, space{};
            float pull = 0.f, coherence = 0.f, weight = 0.f;
            unsigned joined = 0;
            for (std::size_t j = 0; j < previous.size(); ++j) {
                const auto& other = previous[j];
                if (i == j || other.kind == crown) continue;
                const Vec offset = other.p-before.p;
                const float d2 = dot(offset,offset);
                if (d2 > 50.f) continue;
                const float w = ease(1.f-d2/51.f);
                const bool meeting = before.cohort && other.cohort && before.cohort != other.cohort;
                if (meeting && d2 < 38.f) ++joined;
                const bool travellingTogether = before.cohort &&
                    (before.cohort == other.cohort || meeting);
                if (!travellingTogether && d2 > 18.f) continue;
                neighbours += offset*w;
                course += (other.velocity-before.velocity)*w;
                space += offset*(-.55f*w*ease(1.f-d2/7.f));
                pull += w*std::sin(other.phase-before.phase);
                coherence += w*std::cos(other.phase-before.phase);
                weight += w;
            }
            if (joined && !before.meeting && clock >= before.joinedUntil)
                jelly.joinedUntil = clock+9.f;
            jelly.meeting = joined > 0;
            const bool together = jelly.joinedUntil > clock || (jelly.cohort && gathering > .53f);
            const float toward = together ? 1.f : 0.f;
            jelly.synchrony += (toward-jelly.synchrony)*(1.f-std::exp(-dt*1.75f));
            if (before.cohort) {
                const float converge = (before.cohort == 1 ? 1.07f : -1.12f)*(resident ? .26f : 1.f);
                const float accord = .22f-.85f*jelly.synchrony;
                swimming += Vec{converge*(1.f-jelly.synchrony)+.30f*jelly.synchrony,
                                .04f,accord};
            }
            if (weight > .04f) {
                swimming += (neighbours*.13f+course*.55f+space)*(1.f/weight);
                rate = std::lerp(rate,2.02f,jelly.synchrony)+
                       pull/weight*(.75f+2.45f*jelly.synchrony);
                if (jelly.synchrony > .65f && coherence/weight > .64f &&
                    length(before.p-player) < 37.f)
                    ++synchronised;
            }
            const float fresh = std::exp(-std::max(0.f,clock-jelly.response)*.88f);
            swimming += unit(player-jelly.p)*(.30f*fresh);
        }
        jelly.phase = std::remainder(jelly.phase+rate*dt,tau);
        swimming += pressure(before.p-player,1.3f+before.size*.58f)*1.35f;
        for (std::size_t j = 0; j < giantCount; ++j)
            if (j != i) swimming += pressure(before.p-previous[j].p,
                (previous[j].size+before.size)*.51f)*.86f;
        const Vec relative = before.velocity-current.drift;
        const Vec error = limited(swimming,4.25f)-relative;
        const float turn = (1.42f+.19f*length(error))/(1.f+before.size*.17f);
        jelly.velocity += error*(1.f-std::exp(-dt*turn));
        const Vec trailingWater = waterAt(before.p-Vec{0,before.size*1.36f,0},true,i).drift;
        jelly.slip += (limited(trailingWater-jelly.velocity,4.f)-jelly.slip)*
                      (1.f-std::exp(-dt*(2.7f/before.size+.65f)));
        const Vec heading = jelly.velocity*1.1f-current.drift*.28f;
        if (heading.x*heading.x+heading.z*heading.z > .035f)
            jelly.heading = approachAngle(before.heading,std::atan2(heading.x,heading.z),
                                         1.f-std::exp(-dt*.93f));
        jelly.p += jelly.velocity*dt;
        if (!resident) {
            if (jelly.p.x-player.x > shoalHalfWidth) jelly.p.x -= 2*shoalHalfWidth;
            if (jelly.p.x-player.x < -shoalHalfWidth) jelly.p.x += 2*shoalHalfWidth;
            if (jelly.p.y-player.y > shoalHalfHeight) jelly.p.y -= 2*shoalHalfHeight;
            if (jelly.p.y-player.y < -shoalHalfHeight) jelly.p.y += 2*shoalHalfHeight;
            if (jelly.p.z-player.z > shoalAhead) jelly.p.z -= shoalAhead+shoalBehind;
            if (jelly.p.z-player.z < -shoalBehind) jelly.p.z += shoalAhead+shoalBehind;
        }
        if (i < giantCount) updateWake(i);
    }
}
void Ocean::driftOpening(float dt, Vec& swim) {
    const auto reach = openingAt(player.z);
    const auto ahead = openingAt(player.z+16.f);
    Vec interest = ahead.centre-player;
    if (crownGuest < animals.size() && meeting != Encounter::None) {
        const Vec towardsGuest = animals[crownGuest].p-player;
        interest += unit(towardsGuest)*6.f;
    }
    lookYaw = approachAngle(lookYaw,std::atan2(interest.x,interest.z),1.f-std::exp(-dt*.64f));
    lookPitch = std::lerp(lookPitch,std::clamp(interest.y*.036f,-.24f,.18f),
                          1.f-std::exp(-dt*.64f));
    const float speed = std::lerp(1.38f,1.86f,reach.flow)*
                        (1.f-.79f*eased(player.z,250.f,275.f));
    const Vec inward = reach.centre-player;
    const Vec desired = reach.tangent*speed+limited(inward*.39f,1.15f);
    const auto forward = facing(yaw,pitch);
    const auto right = unit(cross({0,1,0},forward));
    const Vec correction = limited((desired-velocity)*.52f,.53f);
    swim = {dot(correction,right),correction.y,dot(correction,forward)};
    if (!demoCalled && player.z > 205.f && crownInRange() && pulse(Call::Draw)) demoCalled = true;
}
void Ocean::step(float dt, Vec swim, float panX, float panY) {
    if (paused) return;
    lookYaw = std::remainder(lookYaw+panX,tau);
    lookPitch = std::clamp(lookPitch+panY,-1.26f,1.26f);
    physicsRemainder += std::clamp(double(dt),0.,.12);
    while (physicsRemainder >= physicsStep) {
        physicsRemainder -= physicsStep;
        integrate(float(physicsStep),swim);
    }
    if (clock >= nextFlow) {
        buildRibbons();
        nextFlow = clock+1.f/36.f;
    }
}
void Ocean::integrate(float dt, Vec swim) {
    clock += dt;
    note *= std::exp(-4.8f*dt);
    accent *= std::exp(-.27f*dt);
    if (migrating()) {
        const float before = transition;
        transition += dt*.38f;
        if (before < .5f && transition >= .5f) arrive(target);
        if (transition >= 1.f) transition = -1.f;
    }
    if (demo && openingRoute() && !migrating()) {
        driftOpening(dt,swim);
    } else if (demo && !migrating()) {
        lookYaw = std::remainder(lookYaw+dt*.047f*std::sin(clock*.17f),tau);
        lookPitch = std::clamp(lookPitch+dt*.009f*std::cos(clock*.13f),-1.26f,1.26f);
        swim = {.20f*std::cos(clock*.29f),.15f*std::sin(clock*.18f),.62f};
        if (clock > demoSoon && callStart < 0.f) {
            pulse();
            demoSoon = clock + 9.f;
            if (int(clock) % 40 < 9) next();
        }
    }
    const float lookBlend = 1.f-std::exp(-dt*24.f);
    yaw = approachAngle(yaw,lookYaw,lookBlend);
    pitch = std::lerp(pitch,lookPitch,lookBlend);
    const Vec forward = facing(yaw,pitch);
    const Vec right = unit(cross({0,1,0},forward));
    const Vec movement = right*swim.x + Vec{0,swim.y,0} + forward*swim.z;
    const float swimPulse = .87f+.25f*std::sin(clock*2.35f);
    const auto water = waterAt(player);
    const Vec medium = water.drift;
    const Vec slip = velocity-medium;
    const Vec thrust = limited(movement,1.f)*(6.25f*swimPulse);
    const float entry = openingRoute() ? .52f*ease(water.stream) : 0.f;
    const Vec drag = slip*(.76f+.27f*length(slip)+entry);
    Vec separation{};
    for (const auto& animal : animals)
        separation += pressure(player-animal.p,1.27f+animal.size*.55f)*1.28f;
    velocity += (thrust-drag+limited(separation,2.4f))*dt;
    player += velocity*dt;
    for (std::size_t i = 0; i < giantCount; ++i) updateWake(i);
    eye += (player-eye)*(1.f-std::exp(-dt*5.2f));
    const Vec trailWater = waterAt(player-Vec{0,playerSize*1.35f,0}).drift;
    tailSlip += (limited(trailWater-velocity+medium*(entry*.46f),4.f)-tailSlip)*
                (1.f-std::exp(-dt*2.0f));
    const Vec heading = movement+medium*entry;
    if (heading.x*heading.x+heading.z*heading.z > .05f)
        bodyYaw = approachAngle(bodyYaw,std::atan2(heading.x,heading.z),
                                1.f-std::exp(-dt*2.2f));
    advanceShoal(dt);
    advancePlankton(dt);
    if (++trailTicks == ticksPerTrailSample) {
        recordTrails();
        trailTicks = 0;
    }
}
std::string Ocean::title() const {
    return active < currents.size() ? currents[active].title : "Drift " + std::to_string(systems[index].id);
}
const char* Ocean::waterName() const { return waterNames[palette]; }
const char* Ocean::habitatName() const {
    if (!openingRoute() || openingMask(player) < .25f) return waterName();
    if (player.z >= 174.f) return "Lantern Basin";
    if (player.z >= 62.f) return "The Narrows";
    return "Open Water";
}
float Ocean::basinAmount() const {
    return openingRoute() ? openingAt(player.z).basin*openingMask(player) : 0.f;
}
unsigned Ocean::visitedCount() const { return unsigned(std::count(visited.begin(),visited.end(),1)); }

Scene Ocean::scene(float aspect) const {
    const auto& p = palettes[palette];
    const auto& system = systems[index];
    const Vec forward = facing(yaw,pitch);
    const Vec right = unit(cross({0,1,0},forward));
    const Vec up = cross(forward,right);
    const float seed = range(system.id + 19);
    const Vec camera = eye - forward*10.2f - up*2.12f;
    const float warm = logRange(system.temperature,2800,8500);
    Scene result{};
    result.screen = {aspect,clock,clock-lastPulse,migrating() ? std::sin(pi*transition) : 0};
    result.eye = packed(camera); result.forward = packed(forward);
    result.right = packed(right); result.up = packed(up);
    result.deep = p.deep; result.water = p.water; result.bright = p.bright; result.contrast = p.contrast;
    result.habitat.w = currentStrength(waterAt(player));
    if (openingRoute()) {
        const auto reach = openingAt(player.z);
        const float mask = openingMask(player);
        const float narrow = reach.narrows*mask, basin = reach.basin*mask;
        result.habitat = {1.f,narrow,basin,result.habitat.w};
        result.deep = {.0015f+.0071f*narrow,.004f+.007f*basin-.003f*narrow,.026f-.015f*narrow+.017f*basin};
        result.water = {.004f+.021f*basin,.32f-.224f*narrow+.11f*basin,
                        .51f-.18f*narrow+.12f*basin};
        result.bright = {.014f+.054f*basin,1.f-.14f*narrow,.77f+.19f*narrow+.16f*basin};
        result.contrast = {.27f+.19f*narrow+.12f*basin,.012f+.063f*basin,1.f};
        const auto& occluder = animals[eclipseGiant];
        const float bell = occluder.size*(1.08f+.073f*std::sin(occluder.phase));
        const float visible = std::sqrt(mask*shoalFade(occluder.p-player));
        result.eclipse = packed(occluder.p+Vec{0,.43f*occluder.size,0},bell*visible);
    }
    const Vec star = unit({-.48f+.08f*seed,.28f+.14f*seed,.94f});
    result.sun = packed(star,.052f+.045f*logRange(system.radius,7.25f,9.85f));
    result.sunlight = {1.f-.26f*warm,.49f+.40f*warm,.32f+.68f*warm,1.f};
    result.tide = {seed,accent,float(palette),std::sin(clock*.069f)*.5f+.5f};
    result.player = packed(pulseOrigin);
    result.call = {callCharge(),drawnCall() ? 1.f : 0.f,drawnCall() ? drawSpeed : pulseSpeed,0.f};
    unsigned mainBody = 0;
    for (unsigned i = 1; i < system.count; ++i) {
        const auto& current = system.orbits[i];
        const auto& previous = system.orbits[mainBody];
        if (current.radius + .6f*std::min(current.rings,1.f) >
            previous.radius + .6f*std::min(previous.rings,1.f)) mainBody = i;
    }
    for (unsigned i = 0; i < system.count; ++i) {
        const auto& body = system.orbits[i];
        const unsigned slot = i == mainBody ? 0 : (i < mainBody ? i+1 : i);
        const float phase = range(system.id+47*slot)*tau;
        const float drift = std::sin(clock * (.018f-.012f*logRange(body.period,6,10)) + phase);
        const float y = slot == 0 ? .226f : (slot == 1 ? -.28f : .39f);
        const float x = slot == 0 ? .50f : (slot == 1 ? -.82f : .94f);
        const Vec direction = unit({x + .045f*drift,y+.038f*std::cos(phase+clock*.009f),1.f});
        const float size = (slot == 0 ? .129f : .030f) +
            (slot == 0 ? .098f : .048f)*logRange(body.radius,5.5f,8);
        result.planets[slot].position = packed(direction,size);
        const float tilt = body.tilt*pi/180.f;
        const float temperature = logRange(body.heat,95,770);
        const float giant = logRange(body.radius,7.1f,7.6f);
        result.planets[slot].material = {giant,body.clouds+.26f*temperature,
                                         .24f + .40f*std::sin(phase+tilt),
                                         std::min(body.rings,2.4f)};
        const Vec tint = hue(.45f+seed*.24f + .33f*temperature + .08f*body.material);
        result.planets[slot].pigment = packed(tint,.16f*clock/(.45f+logRange(body.distance,10,13))+phase);
    }
    return result;
}
Jelly Ocean::animalView(const Animal& jelly) const {
    const float glow = std::exp(-std::max(0.f,clock-jelly.response)*.72f);
    Jelly view{packed(jelly.p,jelly.size),
               {jelly.hue,jelly.phase,glow,float(jelly.kind)},
               {std::sin(jelly.phase)*.10f,jelly.heading,0.f,range(jelly.seed+19)},
               packed(jelly.slip,jelly.synchrony),shoalFade(jelly.p-player)};
    if (openingRoute()) {
        view.eclipsing = &jelly == &animals[eclipseGiant] ? 1.f : 0.f;
        if (&jelly == &animals[basinGiant]) {
            const float distance = length(jelly.p-player);
            const float entering = eased(player.z,154.f,202.f);
            view.presence = std::max(view.presence,entering*(1.f-eased(distance,168.f,226.f)));
        }
        if (jelly.cohort) {
            view.basinTone = logRange(jelly.home.z,216.f,286.f);
            const float position = view.basinTone;
            view.basinLight = eased(player.z,153.f+42.f*position,174.f+48.f*position);
            view.pigment.x = std::lerp(.17f,.63f,position)+.09f*(jelly.hue-.5f);
        }
    }
    return view;
}
Jelly Ocean::bodyView() const {
    const float freshness = std::max(0.f,clock-lastPulse);
    const Vec body = player+Vec{0,.095f*std::sin(clock*2.35f),0};
    return {packed(body,playerSize),{.93f,clock*2.34f,ease(1.f-freshness*.58f),0.f},
        {dot(tailSlip,cross({0,1,0},facing(bodyYaw,0)))*.09f,bodyYaw,1.f,.7f},
        packed(tailSlip),1.f};
}
void Ocean::captureTrailRow(TrailPose* row) const {
    const Quad time{clock,callCharge(),0,0};
    for (std::size_t i = 0; i < animals.size(); ++i) row[i] = {animalView(animals[i]),time};
    row[animals.size()] = {bodyView(),time};
    if (crownGuest < animals.size() && (meeting == Encounter::Approaching || meeting == Encounter::Alongside)) {
        const auto& guest = animals[crownGuest];
        const float near = 1.f-eased(length(guest.p-player),8.f,17.f);
        const float fade = ease((encounterUntil-clock)/3.2f);
        const float entrance = meeting == Encounter::Alongside ? eased(clock,alongsideSince,alongsideSince+1.4f) : 0.f;
        row[animals.size()].time.z = near*fade*(.67f+.33f*entrance);
        row[animals.size()].time.w = float(crownGuest+1);
    }
}
void Ocean::recordTrails() {
    captureTrailRow(trailHistory.data()+nextTrailSlot*trailActors);
    nextTrailSlot = (nextTrailSlot+1)%trailSamples;
    trailCount = std::min(trailCount+1,unsigned(trailSamples));
}
std::vector<Jelly> Ocean::shoal(float aspect) const {
    std::array<Jelly,trailActors> storage;
    const auto visible = shoal(scene(aspect),storage);
    return {visible.begin(),visible.end()};
}
std::span<const Jelly> Ocean::shoal(const Scene& view, std::span<Jelly,trailActors> storage) const {
    const Vec camera = unpack(view.eye);
    const Vec forward = unpack(view.forward);
    const Vec right = unpack(view.right), up = unpack(view.up);
    const float vertical = .55f, horizontal = vertical*view.screen.x;
    const float sidePlane = std::sqrt(1.f+horizontal*horizontal);
    const float topPlane = std::sqrt(1.f+vertical*vertical);
    std::size_t count = 0;
    for (const auto& jelly : animals) {
        const auto visual = animalView(jelly);
        if (visual.presence <= 0.f) continue;
        // Keep the full tentacle span visible even with the bell outside the view.
        const Vec centre = jelly.p+Vec{0,-1.63f*jelly.size,0}-camera;
        const float radius = 4.6f*jelly.size;
        const float depth = dot(centre,forward);
        const float viewRange = jelly.size >= basinGiantSize ? 238.f : 112.f;
        if (depth+radius < .12f || length(centre)-radius > viewRange ||
            std::abs(dot(centre,right)) > depth*horizontal+radius*sidePlane ||
            std::abs(dot(centre,up)) > depth*vertical+radius*topPlane)
            continue;
        storage[count++] = visual;
    }
    storage[count++] = bodyView();
    return storage.first(count);
}
} // namespace pelagic
