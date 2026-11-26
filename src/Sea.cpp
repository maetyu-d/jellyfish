#include "Sea.hpp"

#include <algorithm>
#include <cmath>
#include <fstream>
#include <iomanip>
#include <memory>
#include <numbers>
#include <stdexcept>
#include <utility>

namespace pelagic {
namespace {

constexpr float pi = std::numbers::pi_v<float>;
constexpr float tau = 2 * pi;
constexpr double physicsStep = 1.0/90.0;
constexpr unsigned ticksPerTrailSample = 9;
// Keep the history longer than the five-second wake.
static_assert(trailSamples*ticksPerTrailSample*physicsStep > 5.2f);
constexpr float holdSeconds = .57f;
constexpr float shortestMorphSeconds = 30.f, longestMorphSeconds = 60.f;
constexpr float manualMorphSeconds = 12.f;
constexpr float pulseSpeed = 10.6f;
constexpr float drawSpeed = 8.1f;
constexpr unsigned moon = 0, crown = 1, comb = 2, petal = 3, lantern = 4, seaBell = 5;
constexpr float seedBubbleSize = 2.65f;
constexpr float playerSpeedScale = .5f;
constexpr float chaseDistance = 9.15f, chaseHeight = 3.45f, chaseLead = 7.4f;
constexpr float shoalHalfWidth = 62.f, shoalHalfHeight = 38.f;
constexpr float shoalBehind = 62.f, shoalAhead = 93.f;
constexpr float streamSpacing = 46.f, eddySpacing = 44.f;
constexpr float eddyOrigin = 14.f;
constexpr std::size_t eclipseGiant = 2;
constexpr std::size_t basinGiant = 3;
constexpr float basinGiantSize = 13.6f;
constexpr float eclipseStation = 166.f;
constexpr std::array<std::size_t,bellPassageCount> bellAnimals{basinGiant,32,39,46,52};
constexpr std::size_t openingSignalAnimal = 13;
constexpr unsigned whirlpoolDepth = bellPassageCount;
constexpr std::size_t whirlpoolHost = bellAnimals.back();
constexpr float whirlpoolReach = 4.8f, whirlpoolEye = 1.25f;
constexpr float eyeHoldSeconds = 2.f, transformationSeconds = 18.f, returnSeconds = 8.f;
constexpr float returnTravelSeconds = 6.65f;
constexpr float openingStrokeTime = 5.8f, openingWaveSpeed = 18.f;
constexpr std::size_t viridianFirst = bellAnimals[3]+1, viridianEnd = bellAnimals[4];
// The enclosing sky comes first, followed by the traversable bells in order.
constexpr std::array<unsigned,1+bellPassageCount> bellCatalogueIds{70,276,84,464,282,470};
constexpr std::array<float,1+bellPassageCount> swimmerScales{1.f,.73f,.55f,.50f,.46f,.46f};
constexpr std::array<unsigned,bellPassageCount> bellScorePalettes{1,2,1,3,0};
constexpr std::array<const char*,bellPassageCount> innerNames{
    "The Amber Garden", "The Cobalt Gloam", "The Viridian Fold", "The Carmine Deep", "The Whirlpool"
};
constexpr auto bellSystemSlots = [] {
    std::array<std::size_t,bubbleCount+1> slots{};
    for (std::size_t i = 0; i < bellAnimals.size(); ++i) slots[bellAnimals[i]] = i+1;
    std::size_t next = bellCatalogueIds.size();
    for (auto& slot : slots) if (slot == 0) slot = next++;
    return slots;
}();
constexpr auto bellPassageByAnimal = [] {
    std::array<unsigned,bubbleCount> stages{};
    for (unsigned i = 0; i < bellAnimals.size(); ++i) stages[bellAnimals[i]] = i+1;
    return stages;
}();
struct BellPassage { Vec opening; float size, aperture, hue; };
// Keep the original passage radii for the new membranes.
constexpr float bellSize(float radius) { return radius/.83f; }
constexpr std::array<BellPassage,bellPassageCount> passages{{
    {{2.f,1.15f,280.f},bellSize(300.f),11.f,.105f},
    {{-6.f,4.15f,354.f},bellSize(119.f),8.f,.636f},
    {{.6f,3.4f,400.f},bellSize(48.f),6.6f,.245f},
    {{3.f,1.15f,431.f},bellSize(20.f),5.4f,.968f},
    {{3.5f,1.0f,448.f},bellSize(8.f),2.9f,.503f}
}};
constexpr float enclosingBellSize = 3200.f;
constexpr Vec enclosingBellCentre{-.27f*enclosingBellSize,-.19f*enclosingBellSize,
                                  .38f*enclosingBellSize};
constexpr float basinPitch = .091f;
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
    {{.002f,.004f,.014f}, {.017f,.20f,.39f}, {.064f,.66f,.98f}, {.66f,.039f,.008f}},
    {{.005f,.013f,.001f}, {.16f,.34f,.011f}, {.71f,.99f,.018f}, {.057f,.51f,.31f}},
    {{.020f,.003f,.002f}, {.55f,.068f,.005f}, {1.f,.31f,.008f}, {.73f,.015f,.17f}},
    {{.023f,.002f,.024f}, {.57f,.012f,.23f}, {.91f,.99f,.025f}, {.76f,.014f,.45f}}
}};
constexpr Palette enclosingPalette{
    {.014f,.002f,.026f}, {.225f,.016f,.37f}, {1.f,.068f,.55f}, {.42f,.024f,.76f}
};
constexpr std::array<Palette,bellPassageCount> innerPalettes{{
    {{.032f,.010f,.001f}, {.81f,.25f,.006f}, {1.f,.76f,.035f}, {.96f,.15f,.016f}},
    {{.003f,.005f,.038f}, {.032f,.112f,.76f}, {.11f,.39f,1.f}, {.48f,.055f,1.f}},
    {{.010f,.024f,.001f}, {.30f,.62f,.009f}, {.74f,1.f,.027f}, {.43f,.68f,.013f}},
    {{.036f,.002f,.009f}, {.72f,.017f,.089f}, {1.f,.038f,.18f}, {.80f,.026f,.42f}},
    {{.002f,.018f,.020f}, {.012f,.46f,.48f}, {.039f,1.f,.73f}, {.064f,.64f,.94f}}
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
    Vec tide{};
};
Reach openingAt(float z) {
    if (z > 250.f) {
        Vec centre = passages[0].opening, tangent{0.f,0.f,1.f}, tide{};
        constexpr std::array<Vec,bellPassageCount-1> bends{{
            {-5.f,6.8f,0.f}, {8.8f,.65f,0.f}, {-2.8f,.8f,0.f}, {1.6f,-3.6f,0.f}
        }};
        constexpr std::array<Vec,bellPassageCount-1> currents{{
            {.06f,1.62f,.25f}, {1.74f,.09f,.04f}, {0.f,.17f,.28f}, {-.37f,-1.18f,-.24f}
        }};
        for (unsigned i = 1; i < passages.size(); ++i) {
            const auto& start = passages[i-1].opening;
            const auto& end = passages[i].opening;
            if (z < start.z) break;
            centre = end;
            if (z >= end.z) continue;
            const float progress = (z-start.z)/(end.z-start.z);
            const float arc = pi*progress;
            const Vec offset = end-start;
            const float swell = std::sin(arc)*std::sin(arc);
            centre = start+offset*ease(progress)+bends[i-1]*swell;
            tangent = offset*slope(z,start.z,end.z);
            tangent += bends[i-1]*(pi*std::sin(2.f*arc)/(end.z-start.z));
            tangent.z = 1.f;
            tide = currents[i-1]*swell;
            break;
        }
        centre.z = z;
        const float narrowing = .78f*eased(z,passages[1].opening.z,passages.back().opening.z);
        const float flow = 1.f-eased(z,196.f,253.f)+.84f*eased(z,251.f,271.f)*
                           (1.f-eased(z,passages.back().opening.z-3.f,passages.back().opening.z+5.f));
        return {centre,tangent,narrowing,1.f,flow,tide};
    }
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
    return eased(p.z,-50.f,-12.f)*(1.f-eased(p.z,490.f,573.f))*
           (1.f-eased(std::abs(p.x),30.f,67.f))*(1.f-eased(std::abs(p.y),19.f,43.f));
}
float apertureDistance(Vec p, const BellPassage& passage) {
    const Vec offset = p-passage.opening;
    return std::sqrt(offset.x*offset.x+offset.y*offset.y*1.28f);
}
float descentScale(float depth) {
    const auto stage = std::min(unsigned(depth),unsigned(bellPassageCount-1));
    return std::lerp(swimmerScales[stage],swimmerScales[stage+1],depth-float(stage));
}
float transformationRadius(float progress, float scale) {
    const float small = seedBubbleSize*scale;
    const float growth = eased(progress,.015f,.61f);
    return growth >= 1.f ? enclosingBellSize : small*std::pow(enclosingBellSize/small,growth);
}
Vec basinSpawn() {
    // Start in the enclosing sea, below its canopy and clear of the next bell's membrane.
    return passages[0].opening+Vec{0.f,7.25f,-86.f};
}
const Vec whirlpoolApproach{.65f,.38f,3.5f};
Vec whirlpoolSpawn() { return passages.back().opening-whirlpoolApproach; }
Vec returnAxis() {
    return {0.f,std::sin(basinPitch),std::cos(basinPitch)};
}
Vec basinCamera() {
    const Vec axis = returnAxis();
    return basinSpawn()-axis*chaseDistance+cross(axis,{1.f,0.f,0.f})*chaseHeight;
}
Vec returnInlet() {
    // The inlet sits on the near membrane, on the approach to the original swimmer.
    const Vec axis = returnAxis();
    const Vec camera = basinCamera();
    const Vec relative = (camera-enclosingBellCentre)*(1.f/enclosingBellSize);
    // The membrane settles into a unit sphere as the camera crosses this point.
    const float b = dot(relative,axis);
    const float near = b+std::sqrt(b*b+1.f-dot(relative,relative));
    return camera-axis*(near*enclosingBellSize);
}
float returnElapsed(float flight) {
    return (1.f-flight)*returnSeconds;
}
float returnSteering(float flight) {
    return eased(returnElapsed(flight),3.55f,returnTravelSeconds);
}
float openingContraction(float age) {
    return eased(age,.0f,2.1f)*(1.f-eased(age,2.55f,6.1f));
}
float passageDistance(float seconds) {
    // One velocity profile on both sides of the inlet, with a soft arrival at swim scale.
    const float inside = std::max(0.f,seconds);
    const float travel = seconds-.22f*inside*inside/(inside+1.65f);
    const float scale = std::exp(-1.10f*travel);
    return 5.f*scale/(4.f+scale)*(1.f-eased(seconds,3.85f,returnTravelSeconds));
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
Quad blend(Quad a, Quad b, float t) {
    return {std::lerp(a.x,b.x,t),std::lerp(a.y,b.y,t),std::lerp(a.z,b.z,t),std::lerp(a.w,b.w,t)};
}
Quad blendDirection(Quad a, Quad b, float t) {
    const Quad direction = blend(a,b,t);
    return packed(unit(unpack(direction)),direction.w);
}
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
    if (openingRoute() && index == basinGiant) {
        wakeFlow[index] = {};
        return;
    }
    const auto& giant = animals[index];
    const Vec axis = unit(giant.velocity+Vec{0,0,.26f});
    wakeFlow[index] = {axis,unit(cross({0,1,0},axis)),shoalFade(giant.p-player),
                       1.35f+.30f*std::min(2.1f,length(giant.velocity))};
}

Vec Ocean::whirlpoolCentre() const {
    const auto& host = animals[whirlpoolHost];
    return host.p+Vec{0.f,-.025f*host.size,.66f*host.size};
}

float Ocean::systemEmergence() const {
    return playerSystemBirth < 0.f ? 0.f : eased(clock,playerSystemBirth,playerSystemBirth+2.15f);
}

float Ocean::transformationProgress() const {
    return transforming() ? std::clamp((clock-transformationStart)/transformationSeconds,0.f,1.f) : 0.f;
}
bool Ocean::returning() const {
    return returnElapsed(returnFlight) < returnTravelSeconds;
}
float Ocean::passageResonance() const {
    return transforming() ? eased(transformationProgress(),.79f,.985f) : eased(returnFlight,.08f,.94f);
}

void Ocean::updateViridianShoals() {
    viridianShoals = {};
    for (std::size_t i = viridianFirst; i < viridianEnd; ++i) {
        const auto shoal = (i-viridianFirst)%2;
        const auto members = (viridianEnd-viridianFirst+1-shoal)/2;
        viridianShoals[shoal] += animals[i].p*(1.f/float(members));
    }
}

Vec Ocean::viridianWash(Vec p) const {
    const float first = passages[2].opening.z, last = passages[3].opening.z;
    if (p.z <= first || p.z >= last) return {};
    Vec current{};
    for (std::size_t i = 0; i < viridianShoals.size(); ++i) {
        const Vec offset = p-viridianShoals[i];
        const float d2 = dot(offset,offset);
        const float near = 1.f-eased(d2,5.f,110.f);
        const float turn = i == 0 ? .23f : -.23f;
        const Vec curl{offset.z*turn,.70f-.14f*offset.y,-offset.x*turn};
        current += curl*near;
    }
    return current*(eased(p.z,first,first+4.f)*(1.f-eased(p.z,last-4.f,last)));
}

void Ocean::updateOpeningStroke() {
    if (openingStroke < 0.f && depth == 0 && !returning() &&
        clock >= openingStrokeTime+(inheritedSky ? returnTravelSeconds : 0.f) &&
        player.z > basinSpawn().z-28.f && player.z < passages[0].opening.z-13.f &&
        std::abs(player.x-passages[0].opening.x) < 25.f && std::abs(player.y) < 22.f) {
        openingStroke = clock;
        voyageCue = {VoyageSound::OpeningStroke};
    }
    if (openingStroke < 0.f) return;
    const float age = clock-openingStroke-2.15f;
    const float strength = eased(age,0.f,.79f)*(1.f-eased(age,7.3f,10.8f));
    openingWave = packed(passages[0].opening-Vec{0.f,0.f,openingWaveSpeed*age},strength);
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
        drift += reach.tangent*(1.90f*running)+side*(.19f*running)+
                 reach.tide*(route*(.48f+.52f*core));
        drift += viridianWash(p)*route;
        if (withWake && ignoreGiant != eclipseGiant) drift += eclipseWash(p)*route;
        channel += running;
    }

    const Vec turn = p-eddyCentre(p.x,p.z,clock);
    const float r2 = turn.x*turn.x+turn.z*turn.z;
    float spin = std::exp(-r2/75.f-turn.y*turn.y/24.f)*
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

    if (openingWave.w > 0.f && p.z < passages[0].opening.z) {
        const Vec offset = p-unpack(openingWave);
        const float reach = (1.f-eased(std::abs(offset.x),10.f,29.f))*
                            (1.f-eased(std::abs(offset.y),6.f,16.f))*
                            (1.f-eased(p.z,passages[0].opening.z-9.f,passages[0].opening.z));
        const float crest = openingWave.w*reach*(1.f-eased(std::abs(offset.z),1.3f,8.f));
        const float draw = openingWave.w*reach*eased(offset.z,2.f,13.f)*
                           (1.f-eased(offset.z,51.f,96.f));
        drift += Vec{-.038f*offset.x,.77f,2.84f}*draw+Vec{0.f,-.26f,-1.15f}*crest;
        wake = std::max(wake,.76f*draw+.20f*crest);
    }

    if (route > 0.f && p.z > passages.back().opening.z-1.f) {
        const float calm = route*eased(p.z,passages.back().opening.z-1.f,passages.back().opening.z+3.f);
        drift = drift*(1.f-.92f*calm);
        channel *= 1.f-.92f*calm;
    }
    float whirlpool = 0.f;
    if (depth >= whirlpoolDepth-1 && ignoreGiant != whirlpoolHost) {
        const Vec offset = p-whirlpoolCentre();
        whirlpool = 1.f-eased(length(offset),whirlpoolEye,whirlpoolReach+2.1f);
        const Vec circling{offset.z*.33f,-offset.y*.36f,-offset.x*.33f};
        const float rim = eased(p.z,passages.back().opening.z-1.8f,passages.back().opening.z+1.f);
        drift = drift*(1.f-.56f*whirlpool)+(circling*rim-offset*.27f)*whirlpool;
        spin = std::max(spin,.51f*whirlpool);
    }

    const WaterKind kind = whirlpool > .42f ? WaterKind::Eddy :
                           std::max(lee,still) > .55f ? WaterKind::Still :
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

static std::vector<System> readCatalogue(const std::filesystem::path& catalogue) {
    std::ifstream file(catalogue);
    std::string version;
    std::getline(file, version);
    unsigned limit;
    if (version == "PELAGIC 1") limit = 3;
    else if (version == "PELAGIC 2" || version == "PELAGIC 3" || version == "PELAGIC 4" || version == "PELAGIC 5")
        limit = systemPlanetLimit;
    else throw std::runtime_error("The orbital catalogue could not be opened.");
    const bool physical = version == "PELAGIC 5";
    const bool appearance = version == "PELAGIC 4" || physical;
    const bool named = version == "PELAGIC 3" || appearance;
    const auto readQuad = [&](Quad& quad) -> bool {
        return bool(file >> quad.x >> quad.y >> quad.z >> quad.w);
    };
    std::vector<System> systems;
    System entry;
    while (file >> entry.id >> entry.radius >> entry.temperature >> entry.count) {
        if (entry.count > limit || (!systems.empty() && entry.id <= systems.back().id))
            throw std::runtime_error("Invalid orbital catalogue.");
        if (named && !(file >> std::quoted(entry.name)))
            throw std::runtime_error("Incomplete system name.");
        for (unsigned i = 0; i < entry.count; ++i) {
            auto& body = entry.orbits[i];
            if (!(file >> body.radius >> body.distance >> body.period >> body.heat >> body.material
                       >> body.clouds >> body.rings >> body.tilt))
                throw std::runtime_error("Incomplete orbital data.");
            if (named && !(file >> body.node >> std::quoted(body.name)))
                throw std::runtime_error("Incomplete planet data.");
            if (appearance) {
                auto& look = body.appearance;
                if (!readQuad(look.dark) || !readQuad(look.light) || !readQuad(look.features) ||
                    !readQuad(look.annulus) || !readQuad(look.pole) ||
                    look.light.w < 1.f || look.light.w > 9.f)
                    throw std::runtime_error("Invalid Xalaria world appearance.");
            }
            if (physical && !(file >> body.orbitalTilt >> body.orbitalHeading >> body.orbitalPhase))
                throw std::runtime_error("Incomplete Xalaria orbital phase.");
        }
        systems.push_back(entry);
    }
    if (systems.empty()) throw std::runtime_error("The orbital catalogue is empty.");
    return systems;
}

Ocean::Ocean(const std::filesystem::path& catalogue, unsigned initial, OceanStart start)
    : Ocean(readCatalogue(catalogue),initial,start) {}

Ocean::Ocean(std::vector<System> catalogue, unsigned initial, OceanStart start)
    : systems(std::move(catalogue)) {
    colourTimes.fill(-1.f);
    visited.resize(systems.size());
    if (initial >= currents.size()+systems.size()) initial = 0;
    current = destination(initial);
    hasOpeningRoute = initial == 0;
    std::vector<bool> assigned(systems.size());
    for (std::size_t slot = 0; slot < bellCatalogues.size(); ++slot) {
        const unsigned key = slot < bellCatalogueIds.size() ? bellCatalogueIds[slot] :
                             systems[current.system].id*917u+unsigned(slot)*983u;
        unsigned choice = unsigned(spread(key)%systems.size());
        if (slot < bellCatalogueIds.size()) {
            const auto found = std::lower_bound(systems.begin(),systems.end(),key,
                                                [](const System& system,unsigned id) { return system.id < id; });
            if (found != systems.end() && found->id == key) choice = unsigned(found-systems.begin());
        }
        // Preserve distinct catalogue systems when the input has enough records. A custom
        // catalogue can run out of bodies, so its repeated records still get separate skies.
        if (slot < systems.size())
            while (assigned[choice]) choice = (choice+1)%systems.size();
        assigned[choice] = true;
        bellCatalogues[slot] = choice;
    }
    visited[current.system] = true;
    placeRegions();
    if (hasOpeningRoute && start == OceanStart::ColossalBell) {
        player = eye = basinSpawn();
        const Vec inward = passages.front().opening-player;
        yaw = lookYaw = std::atan2(inward.x,inward.z);
        pitch = lookPitch = std::atan2(inward.y,std::hypot(inward.x,inward.z));
        launchHold = true;
        demoCalled = true;
    } else if (hasOpeningRoute && start == OceanStart::WhirlpoolApproach) {
        // Rest between the Carmine shoal and the entrance to the Whirlpool.
        player = eye = whirlpoolSpawn();
        launchHold = true;
        depth = whirlpoolDepth-1;
        depthBlend = skyDepthBlend = float(depth);
        yaw = lookYaw = std::atan2(whirlpoolApproach.x,whirlpoolApproach.z);
        pitch = lookPitch = std::atan2(whirlpoolApproach.y,std::hypot(whirlpoolApproach.x,whirlpoolApproach.z));
    }
    chaseYaw = yaw;
    chasePitch = pitch;
    const auto seed = systems[current.system].id;
    population(seed);
    if (openingRoute()) updateViridianShoals();
    for (std::size_t i = 0; i < giantCount; ++i) updateWake(i);
    for (std::size_t i = 0; i < plankton.size(); ++i) {
        plankton[i].seed = spread(seed*31U+unsigned(i)*83U);
        plantPlankter(i,true);
    }
    recordTrails();
    startAutomaticMorph();
}

XalariaLook xalariaLook(unsigned regionCell) {
    // The same region hash as XalariaCatalog::region in Infinity / Xalaria.
    const auto mix64 = [](std::uint64_t n) {
        n += 0x9e3779b97f4a7c15ULL;
        n = (n^(n>>30))*0xbf58476d1ce4e5b9ULL;
        n = (n^(n>>27))*0x94d049bb133111ebULL;
        return n^(n>>31);
    };
    if (mix64(0x45544348454441d8ULL^regionCell)%4 == 0) return XalariaLook::AcidEtch;
    if (mix64(0x544944414c424c1bULL^regionCell)%3 == 0) return XalariaLook::TidalBlue;
    return mix64(0x58414c4152494100ULL^regionCell)&1 ? XalariaLook::VerdantFog : XalariaLook::CharredGlass;
}
SystemBubble systemModel(const System& system) {
    SystemBubble bubble{};
    const float stellarSize = logRange(system.radius,7.25f,9.85f);
    bubble.position.w = std::lerp(.019f,.024f,stellarSize);
    const float warm = logRange(system.temperature,2800.f,8500.f);
    bubble.star = {1.f-.26f*warm,.49f+.40f*warm,.32f+.68f*warm,std::lerp(.14f,.26f,stellarSize)};
    const float seed = range(system.id+19u);
    constexpr unsigned grid = regionGrid*regionSide;
    const unsigned region = (system.id/grid/regionSide)*regionGrid+(system.id%grid)/regionSide;
    bubble.catalogue = {float(system.id),float(xalariaLook(region)),float(system.count),system.temperature};
    auto orbits = system.orbits;
    const bool compact = system.count > 3;
    if (compact)
        std::stable_sort(orbits.begin(),orbits.begin()+system.count,
                         [](const Orbit& a, const Orbit& b) { return a.distance < b.distance; });
    const float inner = std::max(.29f,bubble.star.w+.05f);
    const float lane = (.92f-inner)/float(std::max(1u,system.count));
    for (unsigned i = 0; i < system.count; ++i) {
        const auto& body = orbits[i];
        const float orbitPosition = logRange(body.distance,10.f,13.f);
        const float rings = eased(body.rings,0.f,.18f);
        float distance = .32f+.15f*i+.084f*orbitPosition;
        float radius = std::lerp(.047f,.090f,logRange(body.radius,5.5f,8.f));
        if (compact) {
            // Fit the more numerous planets and their rings into distinct orbital lanes.
            distance = inner+lane*(i+.5f+.16f*(orbitPosition-.5f));
            radius = std::min(radius,.39f*lane/(rings > 0.f ? 2.f : 1.f));
        }
        const bool physical = body.orbitalPhase >= 0.;
        const float phase = physical ? float(body.orbitalPhase) : tau*range(system.id+47u*(i+1));
        const float speed = physical ? float(tau/std::pow(10.,body.period)) :
                                         std::lerp(.46f,.12f,logRange(body.period,6.f,10.f));
        bubble.orbits[i] = {distance,phase,speed,radius};
        const float temperature = logRange(body.heat,95.f,770.f);
        bubble.colours[i] = packed(hue(.45f+.24f*seed+.33f*temperature+.08f*body.material),rings);
        bubble.materials[i] = {logRange(body.radius,7.1f,7.6f),body.clouds,body.tilt*pi/180.f,body.node*pi/180.f};
        auto& look = bubble.appearances[i];
        look = body.appearance;
        if (look.light.w > 0.f) {
            bubble.colours[i] = blend(look.dark,look.light,.54f);
            bubble.colours[i].w = rings;
            bubble.materials[i].x = look.light.w >= 7.f ? 1.f : 0.f;
        }
    }
    return bubble;
}
void Ocean::placeRegions() {
    constexpr unsigned gridSide = regionGrid*regionSide;
    const auto cellAt = [](unsigned x, unsigned y) {
        return (y/regionSide)*regionGrid+x/regionSide;
    };
    std::array<unsigned,regionCells> counts{}, nextSystem{};
    for (const auto& system : systems) {
        if (system.id >= gridSide*gridSide) continue;
        const unsigned x = system.id%gridSide, y = system.id/gridSide;
        ++counts[cellAt(x,y)];
    }
    // Fold back along alternate rows to keep nearby catalogue regions together.
    unsigned offset = 0;
    for (unsigned row = 0; row < regionGrid; ++row) {
        for (unsigned column = 0; column < regionGrid; ++column) {
            const unsigned cell = row*regionGrid+(row%2 ? regionGrid-1-column : column);
            if (!counts[cell]) continue;
            regionMap.push_back({cell,0,counts[cell],offset});
            nextSystem[cell] = offset;
            offset += counts[cell];
        }
    }
    nestedSystems.resize(offset);
    nestedSystemIds.resize(offset);
    for (const auto& system : systems) {
        if (system.id >= gridSide*gridSide) continue;
        const unsigned x = system.id%gridSide, y = system.id/gridSide;
        const unsigned cell = cellAt(x,y);
        const unsigned localX = x%regionSide, localY = y%regionSide;
        const unsigned depthPlane = spread(system.id+97u)%3;
        const auto heat = unsigned(logRange(system.temperature,2600.f,14600.f)*62.f)+1;
        starsByRegion[cell*regionArea+localY*regionSide+localX] =
            std::uint8_t((depthPlane << 6) | heat);

        const auto index = nextSystem[cell]++;
        nestedSystemIds[index] = system.id;
        auto& bubble = nestedSystems[index];
        const float halfGrid = .5f*float(regionSide-1);
        bubble = systemModel(system);
        // Keep the grid corners inside the flexing membrane.
        bubble.position.x = (float(localX)-halfGrid)*.052f;
        bubble.position.y = (float(localY)-halfGrid)*.052f;
        bubble.position.z = (float(depthPlane)-1.f)*.25f;
    }
    regionBubbles.reserve(regionMap.size());
    constexpr std::array<float,regionScales> sizes{3.85f,2.60f,1.76f,1.18f,.79f,.51f};
    constexpr std::array<float,regionScales> ringRadii{18.f,15.f,9.5f,7.5f,5.2f,4.2f};
    constexpr std::array<float,regionScales> startZ{207.f,296.f,363.f,406.f,435.f,452.3f};
    constexpr std::array<float,regionScales> endZ{248.f,331.f,388.f,423.f,443.5f,457.4f};
    unsigned index = 0;
    for (unsigned scale = 0; scale < regionScales; ++scale) {
        const unsigned count = unsigned(regionMap.size()/regionScales+(scale < regionMap.size()%regionScales));
        const unsigned firstRing = (count+1)/2;
        for (unsigned slot = 0; slot < count; ++slot) {
            auto& region = regionMap[index++];
            region.scale = scale;
            const bool outerRing = slot >= firstRing;
            const unsigned around = outerRing ? slot-firstRing : slot;
            const unsigned ringCount = outerRing ? count-firstRing : firstRing;
            const float angle = (float(around)+(outerRing ? .67f : .22f))*tau/float(ringCount);
            const float z = (outerRing ? endZ[scale] : startZ[scale])+sizes[scale]*.42f*std::cos(angle);
            const float radius = ringRadii[scale]*(outerRing ? 1.12f : 1.f);
            Vec home = openingAt(z).centre+Vec{std::cos(angle)*radius,std::sin(angle)*radius*.70f,0.f};
            if (scale == 0) home.y += 4.1f;
            regionBubbles.push_back({home,sizes[scale]});
        }
    }
}

void Ocean::restartCycle() {
    const auto previousSky = atmosphere();
    std::unique_ptr<Ocean> next(new Ocean(std::move(systems),0,OceanStart::ColossalBell));
    next->pitch = next->lookPitch = next->chasePitch = basinPitch;
    next->launchHold = false;
    next->bellCatalogues = bellCatalogues;
    std::swap(next->bellCatalogues[0],next->bellCatalogues[bellSystemSlots.back()]);
    next->orbitalEpoch = orbitalEpoch+double(clock);
    // The exterior sky remains behind the membrane as the next voyage begins.
    next->manualSource = previousSky;
    next->incoming = next->current;
    next->morphEnd = shortestMorphSeconds;
    next->manualMorph = true;
    next->demo = demo;
    next->returnFlight = 1.f;
    next->inheritedSky = true;
    next->markedRegion = markedRegion;
    next->unlockedPassages = unlockedPassages;
    next->colourTimes = colourTimes;
    next->paletteRevision = paletteRevision;
    next->physicsRemainder = physicsRemainder;
    *this = std::move(*next);
}
Ocean::Destination Ocean::destination(unsigned number) const {
    if (number < currents.size()) {
        const auto& locate = currents[number];
        const auto it = std::lower_bound(systems.begin(), systems.end(), locate.id,
            [](const System& system, unsigned id) { return system.id < id; });
        if (it == systems.end() || it->id != locate.id) throw std::runtime_error("Featured system missing.");
        return {number,unsigned(it-systems.begin()),locate.palette};
    }
    const unsigned index = number-unsigned(currents.size());
    return {number,index,unsigned(spread(systems[index].id / 400U + 672U) % palettes.size())};
}
void Ocean::population(unsigned seed) {
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
            if (const auto gate = bellPassageByAnimal[i]) {
                const auto& passage = passages[gate-1];
                jelly.home = passage.opening;
                jelly.velocity = {};
                jelly.size = passage.size;
                jelly.kind = seaBell;
                jelly.hue = passage.hue;
                jelly.realm = gate-1;
            } else if (i < giantCount) {
                jelly.home = stations[i];
                jelly.velocity = {.16f,0,.27f};
                jelly.size = residentSize[i];
                if (i == eclipseGiant) jelly.hue = .61f;
            } else if (i > bellAnimals[1]) {
                const auto boundary = std::upper_bound(bellAnimals.begin(),bellAnimals.end(),i);
                const auto realm = unsigned(boundary-bellAnimals.begin()-1);
                const auto slot = i-bellAnimals[realm];
                const float angle = float(slot)*2.3999632f;
                const float spread = (3.8f+6.2f*range(key+10))*swimmerScales[realm]*2.f;
                const float z = std::lerp(passages[realm-1].opening.z,passages[realm].opening.z,
                                          .14f+.70f*range(key+11));
                jelly.realm = realm;
                jelly.home = openingAt(z).centre+Vec{spread*std::cos(angle),.54f*spread*std::sin(angle),0.f};
                jelly.cohort = 0;
                jelly.kind = slot%3 == 0 ? lantern : petal;
                jelly.hue = passages[realm-1].hue+.22f*(range(key+9)-.5f);
                jelly.size = (.84f+1.45f*range(key+8))*swimmerScales[realm];
                if (i >= viridianFirst && i < viridianEnd) {
                    const auto group = (i-viridianFirst)%2;
                    const float station = std::lerp(passages[2].opening.z,passages[3].opening.z,group ? .72f : .30f);
                    const Vec offset{(group ? 5.8f : -5.8f)+2.9f*(range(key+10)-.5f),
                                     2.1f*(range(key+11)-.5f),4.8f*(range(key+12)-.5f)};
                    jelly.home = openingAt(station).centre+offset;
                }
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
            if (i==openingSignalAnimal && residentSystem(bellSystemSlots[i]).id==openingSignalSystemId) {
                const auto spawn=basinSpawn();
                jelly.home=spawn+(passages.front().opening-spawn)*(14.f/length(passages.front().opening-spawn));
                jelly.velocity={};
                jelly.size=2.65f;
                jelly.cohort=0;
            }
            jelly.p = jelly.home;
        }
    }
}
bool Ocean::beginCall() {
    if (transforming() || returning()) return false;
    if (callStart >= 0.f || paused) return false;
    callStart = clock;
    return true;
}
float Ocean::callCharge() const {
    return callStart < 0.f ? 0.f : ease((clock-callStart)/holdSeconds);
}
bool Ocean::releaseCall(Call tap) {
    if (callStart < 0.f) return false;
    const bool held = clock-callStart >= holdSeconds;
    cancelCall();
    return pulse(held ? Call::Draw : tap);
}
std::size_t Ocean::nearestCrown() const {
    std::size_t best = bubbleCount;
    float distance = 44.f;
    for (std::size_t i = 0; i < animals.size(); ++i) {
        const auto& jelly = animals[i];
        if (jelly.kind != crown || jelly.realm != depth) continue;
        const float reach = length(jelly.p-player);
        if (reach < distance) { best = i; distance = reach; }
    }
    return best;
}
bool Ocean::crownInRange() const { return nearestCrown() != bubbleCount; }
std::span<const Reply> Ocean::takeReplies() {
    const auto ready = std::span<const Reply>(replies).first(replyCount);
    replyCount = 0;
    return ready;
}
VoyageCue Ocean::takeVoyageCue() {
    return std::exchange(voyageCue,VoyageCue{});
}
bool Ocean::pulse(Call type) {
    if (transforming() || returning()) return false;
    if (clock-lastPulse < .83f || paused) return false;
    lastPulse = clock;
    lastCall = type;
    ++callNumber;
    pulseOrigin = player;
    answers = 0;
    accent = 1.f;
    note = 1.f;
    if (type==Call::Resonance) {
        pulseDirection=facing(yaw,pitch);
        return true;
    }
    const bool held = type == Call::Draw;
    if (held && meeting != Encounter::Alongside && meeting != Encounter::Approaching) {
        crownGuest = nearestCrown();
        meeting = crownGuest < bubbleCount ? Encounter::Calling : Encounter::None;
        encounterUntil = clock+8.f;
    }
    for (auto& jelly : animals) {
        const float distance = length(jelly.p - player);
        if (jelly.realm != depth || jelly.kind == seaBell) continue;
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
void Ocean::voyage(unsigned number) {
    if (number >= currents.size()+systems.size() || (manualMorph && number == incoming.number)) return;
    manualSource = atmosphere();
    incoming = destination(number);
    morphStart = clock;
    morphEnd = clock+manualMorphSeconds;
    manualMorph = true;
}
void Ocean::next() {
    const unsigned from = manualMorph ? incoming.number : current.number;
    if (from < currents.size()-1) voyage(from+1);
    else uncharted();
}
unsigned Ocean::unchartedDestination() {
    ++generation;
    const unsigned offset = (2999U + generation*3499U) % systems.size();
    return unsigned(currents.size())+offset;
}
void Ocean::uncharted() { voyage(unchartedDestination()); }

void Ocean::startAutomaticMorph() {
    const unsigned number = current.number < currents.size() ?
                            (current.number+1)%unsigned(currents.size()) : unchartedDestination();
    incoming = destination(number);
    morphStart = clock;
    const float variation = range(919U*++morphCount+systems[incoming.system].id);
    morphEnd = clock+std::lerp(shortestMorphSeconds,longestMorphSeconds,variation);
    manualMorph = false;
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
    mote.drift = water.drift;
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
        // Predict the midpoint from the previous sample. The tracer still advances on every physics tick.
        const auto water = waterAt(mote.p+mote.drift*(dt*.5f));
        const float current = currentStrength(water);
        mote.drift = water.drift;
        mote.p += mote.drift*dt;
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
    const auto visibleLines = openingRoute() ? routeLines : flowLines;
    std::array<Reach,flowNodes> guideSamples;
    if (openingRoute()) {
        for (std::size_t node = 0; node < flowNodes; ++node)
            guideSamples[node] = openingAt(player.z-23.f+float(node)*2.55f);
    }
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
                const auto& reach = guideSamples[node];
                const float z = reach.centre.z;
                const float width = std::lerp(1.42f,1.00f,reach.narrows);
                const float extent = float(node)/float(flowNodes-1);
                const float shape = ease(extent*5.f)*ease((1.f-extent)*5.f);
                const float inlet = passages.back().opening.z;
                const float destination = eased(z,inlet-51.f,inlet-14.f);
                const float gathering = 1.f-.79f*eased(z,inlet-15.f,inlet+1.f);
                const Vec offset = sheet ?
                    Vec{layer*.89f+1.12f*std::sin(z*.102f+layer*2.1f),layer*2.42f-1.22f,0.f} :
                    Vec{width*band+.24f*std::sin(z*.15f+band),.58f*std::cos(band*1.67f+z*.044f),0.f}*gathering;
                const Vec path = reach.centre+offset;
                const Vec swept = path+eclipseWash(path)*4.8f+viridianWash(path)*1.35f;
                const float light = route*reach.flow*shape;
                if (sheet) {
                    const float span = std::lerp(7.9f,5.15f,reach.narrows)*(1.f+.09f*layer);
                    nodes[node] = {packed(swept,span),{z,5.f,layer,light}};
                } else {
                    nodes[node] = {packed(swept,.75f+.73f*reach.flow),
                                   {z+band*2.13f,4.f+destination,.30f+1.90f*reach.flow,
                                    light*(1.f-.085f*std::abs(band))}};
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
void Ocean::answerCalls() {
    for (std::size_t i = 0; i < animals.size(); ++i) {
        auto& jelly = animals[i];
        if (jelly.realm != depth || jelly.due < 0 || clock < jelly.due) continue;
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
                const auto right = cross({0,1,0},facing(yaw,0.f));
                guestSide = dot(jelly.p-player,right) >= 0.f ? -1.f : 1.f;
            }
            continue;
        }
        if (lastCall == Call::Draw) continue;
        if (jelly.kind != moon || jelly.relay >= 3) continue;
        for (auto& other : animals) {
            if (other.realm != depth || other.kind == crown || other.kind == seaBell || other.answered == callNumber) continue;
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
        crownGuest = bubbleCount;
    }
    answerCalls();
    const auto previous = animals;
    const Vec forward = facing(yaw,0.f);
    const Vec right = cross({0,1,0},forward);
    companions = 0;
    synchronised = 0;
    const bool resident = openingRoute();
    const float gathering = resident ? eased(player.z,156.f,213.f) : 0.f;
    for (std::size_t i = 0; i < animals.size(); ++i) {
        auto& jelly = animals[i];
        if (resident && i==openingSignalAnimal && residentSystem(bellSystemSlots[i]).id==openingSignalSystemId) {
            jelly.phase=std::remainder(jelly.phase+.38f*dt,tau);
            continue;
        }
        if (const auto gate = bellPassageByAnimal[i]; resident && gate) {
            jelly.phase = std::remainder(jelly.phase+(.17f+.13f*float(gate))*dt,tau);
            continue;
        }
        const auto& before = previous[i];
        const auto current = waterAt(before.p,true,i);
        const float lift = .20f+.35f*eased(jelly.size,.4f,3.1f);
        Vec swimming{std::sin(jelly.hue*tau+clock*.33f)*.29f,
                     std::cos(jelly.phase)*.15f, .35f+.24f*std::cos(jelly.hue*tau)};
        float rate = 2.34f-.30f*float(jelly.kind);
        if (i < giantCount && !resident) rate /= 1.f+.13f*(jelly.size-3.4f);
        if (resident) {
            const float tide = clock*.073f+float(i)*1.71f;
            const Vec circling{2.1f*std::sin(tide),.95f*std::cos(tide*.79f),2.7f*std::cos(tide)};
            const Vec approach = jelly.cohort ? Vec{-jelly.home.x*.56f,0,(251.f-jelly.home.z)*.28f} : Vec{};
            Vec home = jelly.home+circling+approach*gathering+
                       Vec{0,lift*std::sin(tide*.81f),0};
            if (i == eclipseGiant) {
                const float traverse = eased(player.z,120.f,185.f);
                home = jelly.home+Vec{54.f*traverse,.52f*std::sin(tide),1.05f*std::cos(tide*.58f)};
                rate = .91f;
            }
            const bool crossing = i == eclipseGiant;
            const Vec patrol = limited((home-before.p)*(crossing ? .49f : .36f),crossing ? 2.6f : 1.8f)-current.drift;
            swimming = swimming*.38f+patrol;
        }
        swimming.y += lift*(resident ? .45f : 1.f);
        if (jelly.kind == crown || jelly.kind == seaBell) {
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
                if (i == j || other.kind == crown || other.kind == seaBell || other.realm != jelly.realm) continue;
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
        if (jelly.kind != seaBell) swimming += pressure(before.p-player,1.16f+before.size*.75f)*1.48f;
        for (std::size_t j = 0; j < giantCount; ++j)
            if (j != i && jelly.kind != seaBell && previous[j].kind != seaBell) swimming += pressure(before.p-previous[j].p,
                (previous[j].size+before.size)*.51f)*.86f;
        const Vec relative = before.velocity-current.drift;
        const Vec error = limited(swimming,4.25f)-relative;
        const float turn = (1.42f+.19f*length(error))/(1.f+before.size*.17f);
        jelly.velocity += error*(1.f-std::exp(-dt*turn));
        jelly.slip += (limited(current.drift-jelly.velocity,4.f)-jelly.slip)*
                      (1.f-std::exp(-dt*(2.7f/before.size+.65f)));
        const Vec heading = jelly.velocity*1.1f-current.drift*.28f;
        if (heading.x*heading.x+heading.z*heading.z > .035f)
            jelly.heading = approachAngle(before.heading,std::atan2(heading.x,heading.z),
                                         1.f-std::exp(-dt*.93f));
        const bool held = bubbleHold && bubbleHold->releasedAt < 0.f && bubbleHold->system == bubbleShell &&
                          bubbleHold->slot == bellSystemSlots[i]+1;
        if (held) jelly.p = bubbleHold->shellCentre;
        else jelly.p += jelly.velocity*dt;
        if (!resident && !held) {
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
    const bool atWhirlpool = depth == whirlpoolDepth;
    const Vec landmark = atWhirlpool ? whirlpoolCentre() : passages[depth].opening;
    const bool missedOpening = !atWhirlpool && player.z >= landmark.z;
    const auto ahead = openingAt(std::min(player.z+16.f,landmark.z+4.f));
    Vec interest = (atWhirlpool ? landmark : ahead.centre)-player;
    if (crownGuest < animals.size() && meeting != Encounter::None) {
        const Vec towardsGuest = animals[crownGuest].p-player;
        interest += unit(towardsGuest)*6.f;
    }
    const float bearing = atWhirlpool && eyeEntered >= 0.f ? yaw : std::atan2(interest.x,interest.z);
    lookYaw = approachAngle(lookYaw,bearing,1.f-std::exp(-dt*.64f));
    lookPitch = std::lerp(lookPitch,std::clamp(interest.y*.036f,-.24f,.18f),
                          1.f-std::exp(-dt*.64f));
    const float speed = std::lerp(1.38f,1.86f,reach.flow);
    const Vec inward = reach.centre-player;
    Vec desired = reach.tangent*speed+limited(inward*.39f,1.15f);
    if (atWhirlpool) desired = limited((landmark-player)*.85f,1.65f);
    else if (missedOpening)
        desired = limited((landmark-Vec{0,0,4.f}-player)*.68f,1.85f);
    const auto forward = facing(yaw,pitch);
    const auto right = unit(cross({0,1,0},forward));
    const Vec correction = limited((desired-velocity*(1.f/playerSpeedScale))*.52f,missedOpening ? .86f : .53f);
    swim = {dot(correction,right),correction.y,dot(correction,forward)};
    if (!demoCalled && player.z > 205.f && crownInRange() && pulse(Call::Draw)) demoCalled = true;
}
void Ocean::crossBell(Vec previous, float dt) {
    const auto withinOpening = [&](const BellPassage& gate) {
        const float across = (gate.opening.z-previous.z)/(player.z-previous.z);
        return apertureDistance(previous+(player-previous)*across,gate) < gate.aperture;
    };
    if (depth < passages.size()) {
        const auto& ahead = passages[depth];
        if (passageLocked()) {
            const float stop = ahead.opening.z-1.25f;
            if (player.z > stop) {
                player.z = stop;
                velocity.z = std::min(velocity.z,0.f);
            }
        } else if (previous.z < ahead.opening.z && player.z >= ahead.opening.z && withinOpening(ahead)) {
            ++depth;
        }
    }
    if (depth > 0) {
        const auto& behind = passages[depth-1];
        if (previous.z >= behind.opening.z && player.z < behind.opening.z && withinOpening(behind)) --depth;
    }
    depthBlend = std::lerp(depthBlend,float(depth),1.f-std::exp(-dt*1.35f));
    if (std::abs(depthBlend-float(depth)) < .001f) depthBlend = float(depth);
    skyDepthBlend = std::lerp(skyDepthBlend,float(depth),1.f-std::exp(-dt*.58f));
    if (std::abs(skyDepthBlend-float(depth)) < .001f) skyDepthBlend = float(depth);
}
void Ocean::holdBubble(unsigned slot, unsigned system, Vec shellCentre, Vec centre) {
    bubbleHold = BubbleHold{slot,system,shellCentre,centre};
}

void Ocean::releaseBubble() {
    if (bubbleHold) bubbleHold->releasedAt = clock;
}

void Ocean::step(float dt, Vec thrust, float panX, float panY, bool brake, ThrustMode mode, bool stationKeeping) {
    if (paused) return;
    dt = std::clamp(dt,0.f,.12f);
    if (stationKeeping) {
        velocity = {};
        lookYaw = yaw;
        lookPitch = pitch;
    } else if (!transforming()) {
        const float steering = returnSteering(returnFlight);
        if (steering > .12f && demo && (brake || dot(thrust,thrust) > .04f)) demo = false;
        const float limit = dt*(mode == ThrustMode::Precision ? 1.0f : 2.5f);
        const float sensitivity = mode == ThrustMode::Precision ? .53f : 1.f;
        lookYaw = std::remainder(lookYaw+std::clamp(panX*sensitivity,-limit,limit)*steering,tau);
        lookPitch = std::clamp(lookPitch+std::clamp(panY*sensitivity,-limit,limit)*steering,-1.26f,1.26f);
    }
    physicsRemainder += dt;
    while (physicsRemainder >= physicsStep) {
        physicsRemainder -= physicsStep;
        integrate(float(physicsStep),thrust,brake,mode,stationKeeping);
    }
}

const std::array<FlowNode,routeLines*flowNodes>& Ocean::ribbons() {
    // Generate display geometry only when a frame uses it.
    if (clock >= nextFlow) {
        buildRibbons();
        nextFlow = clock+1.f/36.f;
    }
    return flowView;
}
void Ocean::integrate(float dt, Vec swim, bool brake, ThrustMode mode, bool stationKeeping) {
    clock += dt;
    if (transforming()) {
        if (clock-transformationStart >= transformationSeconds) restartCycle();
        return;
    }
    const float previousFlight = returnFlight;
    returnFlight = std::max(0.f,returnFlight-dt/returnSeconds);
    constexpr float returnChime = 5.2f;
    if (previousFlight > 0.f && returnElapsed(previousFlight) < returnChime &&
        returnElapsed(returnFlight) >= returnChime)
        voyageCue = {VoyageSound::SystemReturn,systems[bellCatalogues[0]].id};
    if (openingRoute()) updateOpeningStroke();
    note *= std::exp(-4.8f*dt);
    accent *= std::exp(-.27f*dt);
    if (clock >= morphEnd) {
        current = incoming;
        visited[current.system] = true;
        startAutomaticMorph();
    }
    if (stationKeeping) {
        engineLoad *= std::exp(-dt*9.f);
        engineBoost *= std::exp(-dt*6.f);
        eyeEntered = -1.f;
    } else {
        steerPlayer(dt,swim,brake,mode);
    }
    for (std::size_t i = 0; i < giantCount; ++i) updateWake(i);
    if (!stationKeeping) eye += (player-eye)*(1.f-std::exp(-dt*(demo ? 5.2f : 8.2f)));
    advanceShoal(dt);
    if (openingRoute() && player.z > passages[2].opening.z-95.f &&
        player.z < passages[3].opening.z+95.f) updateViridianShoals();
    advancePlankton(dt);
    if (++trailTicks == ticksPerTrailSample) {
        recordTrails();
        trailTicks = 0;
    }
}

void Ocean::steerPlayer(float dt, Vec swim, bool brake, ThrustMode mode) {
    const float steering = returnSteering(returnFlight);
    if (demo && openingRoute()) {
        driftOpening(dt*steering,swim);
    } else if (demo) {
        lookYaw = std::remainder(lookYaw+dt*.047f*std::sin(clock*.17f),tau);
        lookPitch = std::clamp(lookPitch+dt*.009f*std::cos(clock*.13f),-1.26f,1.26f);
        swim = {.20f*std::cos(clock*.29f),.15f*std::sin(clock*.18f),.62f};
        if (clock > demoSoon && callStart < 0.f) {
            pulse();
            demoSoon = clock + 9.f;
        }
    }
    const float lookBlend = 1.f-std::exp(-dt*(demo ? 24.f : 46.f));
    const float previousYaw = yaw;
    yaw = approachAngle(yaw,lookYaw,lookBlend);
    pitch = std::lerp(pitch,lookPitch,lookBlend);
    const float chaseBlend = 1.f-std::exp(-dt*7.4f);
    chaseYaw = approachAngle(chaseYaw,yaw,chaseBlend);
    chasePitch = std::lerp(chasePitch,pitch,chaseBlend);
    const float turn = std::remainder(yaw-previousYaw,tau)/dt;
    const float bank = std::clamp(-.13f*turn-.32f*swim.x,-.54f,.54f);
    shipBank = std::lerp(shipBank,bank,1.f-std::exp(-dt*6.4f));
    const bool boosting = !demo && !brake && mode == ThrustMode::Boost && swim.z > .05f;
    const bool precise = !demo && mode == ThrustMode::Precision;
    const float throttle = brake ? 0.f : std::clamp(std::max(0.f,swim.z)+.25f*std::abs(swim.y),0.f,1.f);
    engineLoad = std::lerp(engineLoad,throttle,1.f-std::exp(-dt*9.f));
    engineBoost = std::lerp(engineBoost,float(boosting),1.f-std::exp(-dt*6.f));
    const Vec forward = facing(yaw,pitch);
    const Vec right = unit(cross({0,1,0},forward));
    const Vec movement = right*swim.x + Vec{0,swim.y,0} + forward*swim.z;
    const auto water = waterAt(player);
    const Vec medium = water.drift;
    // Keep the drag and steering response while scaling player travel through the world.
    const Vec slip = velocity*(1.f/playerSpeedScale)-medium;
    const float entry = openingRoute() ? .52f*ease(water.stream) : 0.f;
    const float slipSpeed = length(slip);
    const Vec input = limited(movement,1.f);
    const float effort = !demo && !brake ? length(input) : 0.f;

    Vec acceleration;
    if (demo) {
        const float thrust = .87f+.25f*std::sin(clock*2.35f);
        acceleration = input*(6.25f*thrust)-slip*(.76f+.27f*slipSpeed+entry);
    } else if (brake) {
        acceleration = slip*(-4.8f-.32f*slipSpeed);
    } else {
        // Steer the motion through the water while keeping the current's own velocity.
        const Vec axis = input*(1.f/std::max(.001f,effort));
        const float along = dot(slip,axis);
        const Vec lateral = slip-axis*along;
        const Vec reversing = axis*std::min(0.f,along);
        const float drag = std::lerp(.53f+.13f*slipSpeed,.87f+.22f*slipSpeed,effort)+.38f*entry;
        const float power = precise ? .43f : 1.f;
        acceleration = input*(9.6f*power)-slip*(drag+(precise ? .76f : 0.f))-
                       (lateral*3.1f+reversing*2.4f)*effort;
        if (boosting) acceleration += axis*(std::clamp(swim.z,0.f,1.f)*7.6f);
    }
    if (depth == whirlpoolDepth && !demo && effort < .1f) {
        const Vec offset = whirlpoolCentre()-player;
        if (dot(offset,offset) <= whirlpoolEye*whirlpoolEye)
            acceleration += offset*3.f-velocity*6.f;
    }
    Vec separation{};
    for (const auto& animal : animals)
        if (animal.realm == depth && animal.kind != seaBell)
            separation += pressure(player-animal.p,1.27f+animal.size*.55f)*1.28f;
    const Vec previous = player;
    if (demo || effort > .02f) launchHold = false;
    if (!launchHold) {
        velocity += (acceleration+limited(separation,2.4f))*(dt*playerSpeedScale*steering);
        player += velocity*(dt*steering);
    }
    const float pullback = 1.65f*eased(length(velocity),1.05f,4.1f)+.42f*engineBoost;
    chasePullback = std::lerp(chasePullback,pullback,1.f-std::exp(-dt*3.5f));
    if (openingRoute()) crossBell(previous,dt);
    if (depth == whirlpoolDepth && playerSystemBirth < 0.f) {
        const Vec centre = whirlpoolCentre();
        const Vec travel = player-previous;
        const float along = std::clamp(dot(centre-previous,travel)/std::max(.000001f,dot(travel,travel)),0.f,1.f);
        const Vec nearest = previous+travel*along-centre;
        if (dot(nearest,nearest) <= whirlpoolEye*whirlpoolEye) {
            playerSystemBirth = clock;
            voyageCue = {VoyageSound::SystemBirth,systems[bellCatalogues[bellSystemSlots.back()]].id};
        }
    }
    const Vec eyeOffset = player-whirlpoolCentre();
    if (depth == whirlpoolDepth && dot(eyeOffset,eyeOffset) <= whirlpoolEye*whirlpoolEye) {
        if (eyeEntered < 0.f) eyeEntered = clock;
        if (clock-eyeEntered >= eyeHoldSeconds) {
            transformationStart = clock;
            cancelCall();
        }
    } else {
        eyeEntered = -1.f;
    }
}
std::string Ocean::title() const {
    return current.number < currents.size() ? currents[current.number].title :
           "Drift " + std::to_string(systems[current.system].id);
}
const char* Ocean::waterName() const { return waterNames[current.palette]; }
const char* Ocean::habitatName() const {
    if (depth > 0) return innerNames[depth-1];
    if (!openingRoute() || openingMask(player) < .25f) return waterName();
    if (player.z >= 174.f) return "Lantern Basin";
    if (player.z >= 62.f) return "The Narrows";
    return "Open Water";
}
unsigned Ocean::look() const {
    const auto stage = unsigned(std::round(depthBlend));
    return stage > 0 ? bellScorePalettes[stage-1] : current.palette;
}
float Ocean::basinAmount() const {
    return openingRoute() ? openingAt(player.z).basin*openingMask(player) : 0.f;
}
unsigned Ocean::visitedCount() const { return unsigned(std::count(visited.begin(),visited.end(),1)); }

Ocean::Atmosphere Ocean::atmosphereAt(Destination location) const {
    const auto& p = palettes[location.palette];
    const auto& system = systems[location.system];
    const float seed = range(system.id + 19);
    const float warm = logRange(system.temperature,2800,8500);
    Atmosphere result{};
    result.deep = p.deep; result.water = p.water; result.bright = p.bright; result.contrast = p.contrast;
    result.paletteMix = {float(location.palette == 0),float(location.palette == 1),
                         float(location.palette == 2),float(location.palette == 3)};
    result.seed = seed;
    result.noctiluca = location.number == 0 ? 1.f : 0.f;
    const Vec star = unit({-.48f+.08f*seed,.28f+.14f*seed,.94f});
    result.sun = packed(star,.052f+.045f*logRange(system.radius,7.25f,9.85f));
    result.sunlight = {1.f-.26f*warm,.49f+.40f*warm,.32f+.68f*warm,1.f};
    const float orbitTime = float(orbitalEpoch+double(clock));
    const unsigned featured = std::min(system.count,unsigned(result.planets.size()));
    unsigned mainBody = 0;
    for (unsigned i = 1; i < featured; ++i) {
        const auto& current = system.orbits[i];
        const auto& previous = system.orbits[mainBody];
        if (current.radius + .6f*std::min(current.rings,1.f) >
            previous.radius + .6f*std::min(previous.rings,1.f)) mainBody = i;
    }
    for (unsigned i = 0; i < featured; ++i) {
        const auto& body = system.orbits[i];
        const unsigned slot = i == mainBody ? 0 : (i < mainBody ? i+1 : i);
        const float phase = range(system.id+47*slot)*tau;
        const float drift = std::sin(orbitTime*(.018f-.012f*logRange(body.period,6,10))+phase);
        const float y = slot == 0 ? .226f : (slot == 1 ? -.28f : .39f);
        const float x = slot == 0 ? .50f : (slot == 1 ? -.82f : .94f);
        const Vec direction = unit({x+.045f*drift,y+.038f*std::cos(phase+orbitTime*.009f),1.f});
        const float size = (slot == 0 ? .129f : .030f) +
            (slot == 0 ? .098f : .048f)*logRange(body.radius,5.5f,8);
        result.planets[slot].position = packed(direction,size);
        const float tilt = body.tilt*pi/180.f;
        const float temperature = logRange(body.heat,95,770);
        const float giant = logRange(body.radius,7.1f,7.6f);
        result.planets[slot].material = {giant,body.clouds+.26f*temperature,
                                         .24f + .40f*std::sin(phase+tilt),
                                         std::clamp(body.rings,0.f,2.4f)};
        result.planets[slot].ringOpacity = eased(body.rings,0.f,.18f);
        result.planets[slot].opacity = 1.f;
        const Vec tint = hue(.45f+seed*.24f + .33f*temperature + .08f*body.material);
        result.planets[slot].pigment = packed(tint,.16f*orbitTime/(.45f+logRange(body.distance,10,13))+phase);
    }
    return result;
}
Ocean::Atmosphere Ocean::atmosphere() const {
    const float t = eased(clock,morphStart,morphEnd);
    const auto from = manualMorph ? manualSource : atmosphereAt(current);
    if (t <= 0.f) return from;
    const auto to = atmosphereAt(incoming);
    if (t >= 1.f) return to;
    Atmosphere result{};
    result.deep = blend(from.deep,to.deep,t);
    result.water = blend(from.water,to.water,t);
    result.bright = blend(from.bright,to.bright,t);
    result.contrast = blend(from.contrast,to.contrast,t);
    result.sun = blendDirection(from.sun,to.sun,t);
    result.sunlight = blend(from.sunlight,to.sunlight,t);
    result.paletteMix = blend(from.paletteMix,to.paletteMix,t);
    result.seed = std::lerp(from.seed,to.seed,t);
    result.noctiluca = std::lerp(from.noctiluca,to.noctiluca,t);
    for (std::size_t i = 0; i < result.planets.size(); ++i) {
        auto a = from.planets[i];
        auto b = to.planets[i];
        if (a.position.w == 0.f && b.position.w == 0.f) continue;
        if (a.position.w == 0.f) {
            a = b;
            a.opacity = 0.f;
            a.ringOpacity = 0.f;
        } else if (b.position.w == 0.f) {
            b = a;
            b.opacity = 0.f;
            b.ringOpacity = 0.f;
        }
        result.planets[i] = {blendDirection(a.position,b.position,t),blend(a.material,b.material,t),
                             blend(a.pigment,b.pigment,t),std::lerp(a.ringOpacity,b.ringOpacity,t),
                             std::lerp(a.opacity,b.opacity,t)};
    }
    return result;
}
void Ocean::writeBellSystems(std::span<BellSystem,bellSystemCount> output, VisibleSystems visible) const {
    constexpr std::array<float,bellCatalogueIds.size()> orientations{.06f,-.18f,.08f,-.31f,.24f,-.31f};
    for (std::size_t slot = 0; slot < residentSystemCount+regionMap.size(); ++slot) {
        if (!visible[slot]) continue;
        auto& local = output[slot];
        if (slot >= residentSystemCount) {
            const auto& region = regionMap[slot-residentSystemCount];
            local = {};
            local.region = regionTint(region);
            local.region.w = float(region.cell+1);
            continue;
        }
        const auto swimmer = bellSystemSlots.back();
        const auto source = slot == 0 && transforming() ? swimmer : slot;
        const bool newSky = slot == 0 && (transforming() || inheritedSky);
        const auto catalogue = bellCatalogues[source];
        const auto system = atmosphereAt({1u,catalogue,unsigned(slot%palettes.size())});
        const float bearing = slot < orientations.size() ? orientations[slot] : 1.22f*(range(unsigned(slot)*137u)-.5f);
        const float sn = std::sin(bearing), cs = std::cos(bearing);
        const auto orient = [&](Quad direction) {
            if (slot == 0) direction.x = -direction.x;
            return Quad{cs*direction.x+sn*direction.z,direction.y,cs*direction.z-sn*direction.x,direction.w};
        };
        local = {orient(system.sun),system.sunlight,system.planets,{},{}};
        local.sunlight.w = (float(slot)+system.seed)/float(residentSystemCount);
        if (source == swimmer || newSky) {
            local.sunlight.w = system.seed;
            auto& planet = local.planets.front();
            const unsigned signature = spread(systems[catalogue].id+1471u);
            const float side = (signature&1u) ? 1.f : -1.f;
            planet.material.z = side*(.50f+.21f*range(signature+1u));
            planet.material.w = 1.72f+.24f*range(signature+7u);
            planet.ringOpacity = 1.f;
            const Vec tint = (signature&2u) ? Vec{.84f,.34f,.62f} : Vec{.26f,.78f,.93f};
            planet.pigment = blend(planet.pigment,packed(tint,planet.pigment.w),.56f);
        }
        for (std::size_t i = 0; i < local.planets.size(); ++i) {
            auto& planet = local.planets[i];
            planet.position = orient(planet.position);
            if (planet.position.w <= 0.f) continue;
            const auto direction = planet.position;
            if (i == 0) {
                // The inherited ring clears the moon and the returning swimmer.
                local.skyPositions[i] = newSky ? packed(unit({.69f,-.08f,1.f}),direction.w) : direction;
                continue;
            }
            // Place the companion planets to either side and behind the swimmer. The
            // orbit belongs to the bell's world and never depends on the camera heading.
            const float azimuth = (i == 1 ? -1.66f : 2.61f)+.25f*(system.seed-.5f)+.28f*direction.x;
            const float radius = std::sqrt(std::max(0.f,1.f-direction.y*direction.y));
            local.skyPositions[i] = {radius*std::sin(azimuth), direction.y, radius*std::cos(azimuth), direction.w};
        }
    }
}

Scene Ocean::scene(float aspect, bool exteriorView) const {
    exteriorView = exteriorView && !transforming() && !returning();
    const auto sky = atmosphere();
    const Vec heading = facing(chaseYaw,chasePitch);
    const Vec across = unit(cross({0,1,0},heading));
    const Vec ceiling = cross(heading,across);
    const float scale = descentScale(depthBlend);
    const Vec camera = eye+(ceiling*chaseHeight-heading*(chaseDistance+chasePullback)+across*(shipBank*1.8f))*scale;
    const Vec forward = unit(player+heading*(chaseLead*scale)-camera);
    const Vec right = unit(cross({0,1,0},forward));
    const Vec up = cross(forward,right);
    // Present the orbit continuously between the fixed physics ticks.
    const float visibleTime = exteriorView ? clock+float(physicsRemainder) : clock;
    Scene result{};
    if (passageLocked()) result.lockedPassage=depth+1;
    if (bubbleHold) {
        const auto& hold = *bubbleHold;
        const float weight = hold.releasedAt < 0.f ? 1.f : 1.f-eased(clock-hold.releasedAt,0.f,.65f);
        result.heldBubble = hold.slot;
        result.heldSystem = hold.system;
        result.heldBubbleCentre = packed(hold.shellCentre,weight);
        result.heldSystemCentre = packed(hold.centre,weight);
    }
    result.screen = {aspect,visibleTime,clock-lastPulse,sky.noctiluca};
    result.celestialTime = float(orbitalEpoch+double(visibleTime));
    const auto residentPalette = [&](unsigned slot, unsigned layer) {
        return bubblePalette({BubbleKind::System,residentSystem(slot).id},layer);
    };
    result.enclosingPalette = residentPalette(0,0);
    result.interiorPalette = openingRoute() ? result.enclosingPalette :
        bubblePalette({BubbleKind::System,systems[current.system].id});
    result.birthPalette = residentPalette(bellSystemSlots.back(),whirlpoolDepth);
    result.eye = packed(camera); result.forward = packed(forward);
    result.right = packed(right); result.up = packed(up);
    result.deep = sky.deep; result.water = sky.water; result.bright = sky.bright; result.contrast = sky.contrast;
    result.sun = sky.sun; result.sunlight = sky.sunlight; result.planets = sky.planets;
    result.paletteMix = sky.paletteMix;
    const float paletteTone = sky.paletteMix.y+2.f*sky.paletteMix.z+3.f*sky.paletteMix.w;
    result.tide = {sky.seed,accent,paletteTone,std::sin(result.celestialTime*.069f)*.5f+.5f};
    result.player = packed(returning() ? player : pulseOrigin);
    result.call = {callCharge(),drawnCall() ? 1.f : 0.f,drawnCall() ? drawSpeed : pulseSpeed,0.f};
    if (resonantCall()) result.pulseAxis=packed(pulseDirection,pulseDuration);
    result.habitat.w = currentStrength(waterAt(player));
    result.cycle.w = returnFlight;
    if (openingRoute()) {
        if (depth < passages.size() && !passageLocked() && !exteriorView && !transforming() && !returning())
            result.openPassage = depth+1;
        const float progress = transformationProgress();
        const float docking = eased(progress,.86f,.982f);
        const Vec lightingPosition = player+(basinSpawn()-player)*docking;
        const auto reach = openingAt(lightingPosition.z);
        const float mask = openingMask(lightingPosition);
        const float narrow = reach.narrows*mask, basin = reach.basin*mask;
        result.habitat = {1.f,narrow,basin,result.habitat.w};
        if (!exteriorView && !transforming())
            result.basinWave = packed(unpack(openingWave),openingWave.w*(1.f-ease(depthBlend)));
        const float enclosingColour = mask*(.83f+.09f*basin);
        result.deep = blend(result.deep,enclosingPalette.deep,enclosingColour);
        result.water = blend(result.water,enclosingPalette.water,enclosingColour);
        result.bright = blend(result.bright,enclosingPalette.bright,enclosingColour);
        result.contrast = blend(result.contrast,enclosingPalette.contrast,enclosingColour);
        const auto& occluder = animals[eclipseGiant];
        const float bell = occluder.size*(1.08f+.073f*std::sin(occluder.phase));
        const float visible = std::sqrt(mask*shoalFade(occluder.p-lightingPosition));
        result.eclipse = packed(occluder.p+Vec{0,.43f*occluder.size,0},bell*visible);
        const Quad basinDeep = result.deep, basinWater = result.water,
                   basinBright = result.bright, basinContrast = result.contrast;
        const float inside = ease(depthBlend);
        const float innerStage = std::max(0.f,depthBlend-1.f);
        const auto stage = std::min(unsigned(innerStage),unsigned(bellPassageCount-2));
        const float phase = ease(innerStage-float(stage));
        const auto& from = innerPalettes[stage];
        const auto& to = innerPalettes[stage+1];
        result.deep = blend(result.deep,blend(from.deep,to.deep,phase),inside);
        result.water = blend(result.water,blend(from.water,to.water,phase),inside);
        result.bright = blend(result.bright,blend(from.bright,to.bright,phase),inside);
        result.contrast = blend(result.contrast,blend(from.contrast,to.contrast,phase),inside);
        constexpr std::array<Quad,bellPassageCount> playerColours{{
            {.89f,0.f,0.f,.11f}, {.08f,.07f,.85f,0.f}, {.43f,.57f,0.f,0.f},
            {0.f,0.f,0.f,1.f}, {.30f,.70f,0.f,0.f}
        }};
        result.paletteMix = blend(result.paletteMix,blend(playerColours[stage],playerColours[stage+1],phase),inside);
        float membrane = 0.f;
        for (std::size_t i = 0; i < passages.size(); ++i) {
            const auto& passage = passages[i];
            result.passages[i] = packed(passage.opening,passage.aperture);
            result.passageColours[i] = innerPalettes[i].bright;
            membrane = std::max(membrane,(1.f-eased(std::abs(player.z-passage.opening.z),.2f,9.f))*
                (1.f-eased(apertureDistance(player,passage),passage.aperture*.46f,passage.aperture)));
        }
        result.innerOcean = {depthBlend,membrane,0.f,systemEmergence()};
        if (result.innerOcean.w > 0.f) result.playerSystem = float(bellSystemSlots.back()+1);
        result.skyDepth = exteriorView ? 0.f : skyDepthBlend;
        const float colourDepth = std::clamp(result.skyDepth,0.f,float(bellPassageCount));
        const auto layer = unsigned(colourDepth);
        const auto next = std::min(layer+1,unsigned(bellPassageCount));
        result.interiorPalette = blend(residentPalette(layer,layer),residentPalette(next,next),ease(colourDepth-layer));
        if (depthBlend > 1.62f && !exteriorView) {
            const Vec centre = whirlpoolCentre();
            result.whirlpool = packed(centre,whirlpoolEye);
            result.whirlpoolApproach = 1.f-eased(length(player-centre),3.4f,58.f);
        }
        result.enclosingBell = packed(enclosingBellCentre,enclosingBellSize);
        result.enclosedOrbits = packed((basinSpawn()-enclosingBellCentre)*(1.f/enclosingBellSize),.34f);
        if (exteriorView) {
            const float orbit = -.19f+.13f*std::sin(visibleTime*.081f);
            const Vec offset{4.42f*std::sin(orbit),.28f, -4.42f*std::cos(orbit)};
            const Vec outside = enclosingBellCentre+offset*enclosingBellSize;
            const Vec aim = unit(Vec{0.f,-.10f,0.f}-offset);
            const Vec across = unit(cross({0.f,1.f,0.f},aim));
            result.eye = packed(outside);
            result.forward = packed(aim);
            result.right = packed(across);
            result.up = packed(cross(aim,across));
            result.deep = sky.deep;
            result.water = sky.water;
            result.bright = sky.bright;
            result.contrast = sky.contrast;
            result.paletteMix = sky.paletteMix;
            result.habitat = result.eclipse = result.innerOcean = {};
            result.innerOcean.z = 1.f;
            result.screen.z = 6.f;
        }
        const float freeBreath = transforming() ? 1.f-eased(progress,.79f,.90f) :
                                returnFlight > 0.f ? eased(returnElapsed(returnFlight),2.8f,6.2f) : 1.f;
        const float breath = std::sin(result.celestialTime*.266f+.51f)*freeBreath;
        const float swell = std::sin(result.celestialTime*.177f+1.1f)*freeBreath;
        result.enclosingShape = {1.f+.070f*breath,1.f-.095f*breath,1.f+.049f*swell,1.f};
        if (eyeEntered >= 0.f) result.cycle.x = ease((clock-eyeEntered)/eyeHoldSeconds);
        if (transforming()) {
            const float outsideBlend = eased(progress,.085f,.52f);
            const float pullback = eased(progress,.035f,.57f);
            const float sweep = eased(progress,.15f,.91f);
            const float approach = eased(progress,.775f,.937f);
            const float radius = transformationRadius(progress,scale);
            const Vec centre = player+(enclosingBellCentre-player)*eased(progress,.54f,.71f);
            const float orbitYaw = std::lerp(yaw,0.f,pullback)+std::lerp(.26f,-.54f,sweep);
            const Vec orbit = centre+Vec{-4.15f*std::sin(orbitYaw),.24f+.62f*sweep,
                                         -4.15f*std::cos(orbitYaw)}*radius;
            const Vec near = eye+(camera-eye)*(radius/(seedBubbleSize*scale));
            const Vec inlet = returnInlet();
            const Vec axis = returnAxis();
            const Vec threshold = inlet+axis*(.015f*enclosingBellSize);
            const Vec arrival = basinCamera();
            const float seconds = (progress-1.f)*transformationSeconds;
            const Vec approachEye = arrival+(threshold-arrival)*passageDistance(seconds);
            const Vec pulledEye = near+(orbit-near)*pullback;
            const Vec movingEye = pulledEye+(approachEye-pulledEye)*approach;
            const Vec target = centre-Vec{0,.12f*radius,0};
            const Vec orbitAim = unit(forward*(1.f-pullback)+unit(target-pulledEye)*pullback);
            const Vec aim = unit(orbitAim*(1.f-approach)+axis*approach);
            const Vec across = unit(cross({0,1,0},aim));
            result.eye = packed(movingEye);
            result.forward = packed(aim);
            result.right = packed(across);
            result.up = packed(cross(aim,across));
            result.enclosingBell = packed(centre,radius);
            result.enclosingShape.w = eased(progress,.24f,.52f);
            const float stroke = (progress-.395f)/.077f;
            if (stroke > 0.f && stroke < 3.f) {
                const float phase = stroke-std::floor(stroke);
                const float squeeze = eased(phase,0.f,.39f)*(1.f-eased(phase,.49f,1.f));
                result.enclosingShape.x *= 1.f-.155f*squeeze;
                result.enclosingShape.y *= 1.f+.23f*squeeze;
                result.enclosingShape.z *= 1.f-.067f*squeeze;
            }
            result.cycle = {1.f,progress,outsideBlend,0.f};
            result.returnPassage = packed(inlet,eased(progress,.744f,.865f));
            result.passageFlow = packed(axis,seconds);
            result.deep = blend(result.deep,blend(sky.deep,basinDeep,docking),outsideBlend);
            result.water = blend(result.water,blend(sky.water,basinWater,docking),outsideBlend);
            result.bright = blend(result.bright,blend(sky.bright,basinBright,docking),outsideBlend);
            result.contrast = blend(result.contrast,blend(sky.contrast,basinContrast,docking),outsideBlend);
            result.paletteMix = blend(result.paletteMix,blend({0.f,1.f,0.f,0.f},sky.paletteMix,docking),outsideBlend);
        } else if (returnFlight > 0.f && !exteriorView) {
            const Vec inlet = returnInlet(), axis = returnAxis();
            const Vec threshold = inlet+axis*(.015f*enclosingBellSize);
            const float elapsed = returnElapsed(returnFlight);
            const float release = eased(elapsed,4.2f,returnTravelSeconds);
            const Vec aim = unit(axis+(forward-axis)*release);
            const Vec across = unit(cross({0,1,0},aim));
            const Vec offset = (threshold-camera)*passageDistance(elapsed);
            result.eye = packed(camera+offset);
            result.forward = packed(aim);
            result.right = packed(across);
            result.up = packed(cross(aim,across));
            result.basinArrival = 1.f-eased(length(offset),11.f,150.f);
            result.returnPassage = packed(inlet,1.f);
            result.passageFlow = packed(axis,elapsed);
        }
        const auto& shape = result.enclosingShape;
        const Vec observer = (unpack(result.eye)-unpack(result.enclosingBell))*(1.f/result.enclosingBell.w);
        const float shell = length({observer.x/shape.x,observer.y/shape.y,observer.z/shape.z});
        result.enclosingSky = 1.f-eased(shell,.966f,1.028f);
    }
    return result;
}
FlightTelemetry Ocean::flightTelemetry() const {
    constexpr float degrees=360.f/tau;
    return {length(velocity),std::fmod(yaw*degrees+360.f,360.f),pitch*degrees,shipBank*degrees};
}
ShipPose Ocean::shipPose(const Scene& view) const {
    const Vec forward = facing(yaw,pitch);
    const Vec across = unit(cross({0,1,0},forward));
    const Vec up = cross(forward,across);
    const Vec right = across*std::cos(shipBank)+up*std::sin(shipBank);
    const float visible = view.innerOcean.z > 0.f ? 0.f :
        view.basinArrival*(1.f-eased(view.cycle.y,.015f,.16f));
    return {packed(player,.75f*descentScale(depthBlend)),packed(right),
            packed(cross(forward,right)),packed(forward),{engineLoad,visible,engineBoost}};
}
Quad Ocean::flightGuide(const Scene& view) const {
    if (!openingRoute() || demo || view.innerOcean.z > 0.f || transforming() || returning()) return {};
    if (const auto* selected = selectedRegion(); selected && selected->scale == depth) {
        const auto bubble = regionView(std::size_t(selected-regionMap.data()),view);
        const float separation = length(unpack(bubble.position)-player);
        const float visible = bubble.presence*(1.f-eased(separation,64.f,96.f));
        if (visible > 0.f) return packed(unpack(bubble.position),-visible);
    }
    const auto& signal=animals[openingSignalAnimal];
    const BubbleId opening{BubbleKind::System,openingSignalSystemId};
    const float distanceToSignal=length(signal.p-player);
    if (depth==0 && distanceToSignal<40.f &&
        residentSystem(bellSystemSlots[openingSignalAnimal]).id==opening.id && bubbleColour(opening)==0.f) {
        return packed(signal.p,-(.46f+.18f*std::sin(clock*2.5f))*eased(distanceToSignal,3.f,7.f)*
                              (1.f-eased(distanceToSignal,28.f,40.f)));
    }
    const Vec target = depth == whirlpoolDepth ? whirlpoolCentre() : passages[depth].opening;
    const float distance = length(target-player);
    const float visible = (1.f-eased(distance,depth == 0 ? 58.f : 34.f,depth == 0 ? 105.f : 62.f))*
                          eased(distance,.33f,1.2f);
    return packed(target,visible);
}
const Region* Ocean::regionAt(unsigned cell) const {
    const auto found = std::find_if(regionMap.begin(),regionMap.end(),[cell](const Region& r) { return r.cell == cell; });
    return found == regionMap.end() ? nullptr : &*found;
}
Quad Ocean::regionTint(const Region& region) const {
    constexpr std::array<Quad,4> colours{{
        {1.f,.41f,.12f}, {.51f,.91f,.28f}, {.25f,.61f,1.f}, {1.f,.24f,.67f}
    }};
    return colours[unsigned(xalariaLook(region.cell))];
}
const Region* Ocean::nearbyRegion(const Scene& view, bool preferMarked) const {
    if (!openingRoute() || view.innerOcean.z > 0.f || transforming() || returning()) return nullptr;
    const Region* nearest = nullptr;
    float best = 1.e6f;
    const Vec forward = unpack(view.forward);
    for (std::size_t i = 0; i < regionMap.size(); ++i) {
        const auto& region = regionMap[i];
        if (region.scale != depth) continue;
        const auto bubble = regionView(i,view);
        const Vec offset = unpack(bubble.position)-player;
        const float distance = length(offset);
        if (distance > std::max(14.f,17.f*bubble.position.w)) continue;
        if (preferMarked && region.cell == markedRegion) return &region;
        const float facing = dot(offset,forward)/std::max(.001f,distance);
        const float score = distance*(1.25f-.55f*facing);
        if (score < best) { best = score; nearest = &region; }
    }
    return nearest;
}
Bubble Ocean::regionView(std::size_t index, const Scene& view) const {
    const auto& region = regionMap[index];
    const auto& bubble = regionBubbles[index];
    const float layer = 1.f-eased(std::abs(depthBlend-float(region.scale)),.18f,.92f);
    const float seed = range(region.cell*47u+17u);
    const float phase = .72f*view.celestialTime+seed*tau;
    const Vec drift{.44f*std::sin(phase),.75f*std::cos(phase*.72f),.32f*std::sin(phase*.51f)};
    const float hue = region.scale == 0 ? .86f : passages[region.scale-1].hue;
    const float mark = region.cell == markedRegion ? 1.4f+.50f*std::sin(phase) : 0.f;
    Bubble visual{packed(bubble.home+drift*bubble.size,bubble.size),{hue,phase,mark,0.f},
                  {0.f,.29f*std::sin(phase*.58f),0.f,seed},{},layer*(1.f-view.cycle.z)*view.basinArrival};
    visual.bellSystem = float(residentSystemCount+index+1);
    visual.palette = bubblePalette({BubbleKind::Region,region.cell},region.scale);
    return visual;
}
Bubble Ocean::animalView(const Animal& jelly) const {
    const float glow = std::exp(-std::max(0.f,clock-jelly.response)*.72f);
    const auto index = std::size_t(&jelly-animals.data());
    Bubble view{packed(jelly.p,jelly.size),
               {jelly.hue,jelly.phase,glow,float(jelly.kind)},
               {std::sin(jelly.phase)*.10f,jelly.heading,0.f,range(jelly.seed+19)},
               packed(jelly.slip,jelly.synchrony),shoalFade(jelly.p-player)};
    view.bellSystem = float(bellSystemSlots[index]+1);
    const BubbleId system{BubbleKind::System,residentSystem(bellSystemSlots[index]).id};
    const auto gateIndex = bellPassageByAnimal[index];
    view.palette = openingRoute() ? bubblePalette(system,gateIndex ? gateIndex : jelly.realm) : bubblePalette(system);
    if (jelly.kind == petal || jelly.kind == lantern)
        view.pitch = (jelly.kind == petal ? .39f : .09f)+.23f*std::sin(jelly.phase+jelly.hue*tau);
    if (openingRoute()) {
        view.eclipsing = &jelly == &animals[eclipseGiant] ? 1.f : 0.f;
        if (index==openingSignalAnimal && system.id==openingSignalSystemId)
            view.pigment.z=std::max(view.pigment.z,(1.f-bubbleColour(system))*(.36f+.24f*std::sin(clock*2.5f)));
        if (gateIndex) {
            const float distance = length(jelly.p-player);
            const float reach = std::max(1.f,jelly.size/40.f);
            const float entering = gateIndex == 1 ? eased(player.z,96.f,202.f) : 1.f;
            view.presence = entering*(1.f-eased(distance,136.f*reach,221.f*reach));
            view.membraneAnchor = float(gateIndex);
            view.flow.x = view.flow.y = 0.f;
            if (gateIndex == 1 && openingStroke >= 0.f) {
                const float stroke = openingContraction(clock-openingStroke);
                view.trail.w = stroke;
                view.pigment.z = std::max(view.pigment.z,.56f*stroke);
            }
        }
        if (jelly.cohort && jelly.realm == 0) {
            view.basinTone = logRange(jelly.home.z,216.f,286.f);
            const float position = view.basinTone;
            view.basinLight = eased(player.z,153.f+42.f*position,174.f+48.f*position);
            view.pigment.x = std::lerp(.17f,.63f,position)+.09f*(jelly.hue-.5f);
            view.presence *= 1.f-.36f*eased(player.z,223.f,263.f);
        }
        const float relativeDepth = depthBlend-float(jelly.realm);
        float region = 1.f-eased(std::abs(relativeDepth),.24f,.98f);
        if (gateIndex && relativeDepth > 0.f) {
            // Keep the very same canopy and veins visible overhead on crossing its rim.
            region = std::lerp(1.f,.29f,eased(relativeDepth,.03f,.85f))*
                     (1.f-eased(relativeDepth,1.12f,1.95f));
            view.bellSystemVisibility = 1.f-eased(skyDepthBlend-float(jelly.realm),.10f,.94f);
        }
        if (jelly.realm > 0) {
            const float adjacent = 1.f-eased(std::abs(relativeDepth+.48f),.52f,1.04f);
            const auto& gate = passages[jelly.realm-1];
            const float arrival = eased(player.z,gate.opening.z-17.f,gate.opening.z);
            const float reveal = 1.f-eased(player.z,gate.opening.z+4.f,gate.opening.z+21.f);
            const float glimpse = .26f*arrival*reveal*adjacent*
                                  (1.f-eased(apertureDistance(player,gate),gate.aperture*.55f,gate.aperture));
            region = std::max(region,glimpse);
        }
        view.presence *= region;
    }
    return view;
}
Bubble Ocean::ziksaBubble(const Scene& view) const {
    const Vec home = whirlpoolSpawn()+Vec{-2.5f,.58f,.65f};
    const float layer = openingRoute() ? 1.f-eased(std::abs(depthBlend-float(whirlpoolDepth-1)),.22f,.94f) : 0.f;
    Bubble bubble{packed(home,1.22f),{.11f,view.celestialTime*.72f,0.f,0.f},
                  {0.f,.28f,-1.f,.63f},{},layer*(1.f-view.cycle.z)*view.basinArrival};
    bubble.palette = bubblePalette({BubbleKind::System,14538u},whirlpoolDepth);
    return bubble;
}
const Region* Ocean::bubbleRegion(unsigned slot) const {
    if (slot <= residentSystemCount) return nullptr;
    const auto index = slot-residentSystemCount-1;
    return index < regionMap.size() ? &regionMap[index] : nullptr;
}
const System* Ocean::bubbleSystem(unsigned slot) const {
    if (slot <= 1 || slot > residentSystemCount || slot == bellSystemSlots.back()+1) return nullptr;
    return &residentSystem(slot-1);
}
const System& Ocean::residentSystem(unsigned slot) const {
    const auto source = slot == 0 && transforming() ? bellSystemSlots.back() : slot;
    return systems[bellCatalogues[source]];
}
const System* Ocean::systemById(unsigned id) const {
    const auto found = std::lower_bound(systems.begin(),systems.end(),id,
        [](const System& system,unsigned key) { return system.id < key; });
    return found != systems.end() && found->id == id ? &*found : nullptr;
}
bool Ocean::restoreBubbleColour(BubbleId bubble, bool animate) {
    const bool system = bubble.kind==BubbleKind::System;
    if (bubble.id >= (system ? systemCells : regionCells)) return false;
    auto& start = colourTimes[bubble.id+(system ? 0 : systemCells)];
    if (start != -1.f) return false;
    start = animate ? float(orbitalTime()) : -2.f;
    ++paletteRevision;
    return true;
}
float Ocean::bubbleColour(BubbleId bubble) const {
    const bool system = bubble.kind==BubbleKind::System;
    if (bubble.id >= (system ? systemCells : regionCells)) return 0.f;
    const auto start = colourTimes[bubble.id+(system ? 0 : systemCells)];
    if (start < 0.f) return start == -2.f ? 1.f : 0.f;
    return ease((float(orbitalTime())-start)/bubbleColourFade);
}
bool Ocean::bubbleColourRestored(BubbleId bubble) const {
    const bool system=bubble.kind==BubbleKind::System;
    return bubble.id<(system ? systemCells : regionCells) &&
           colourTimes[bubble.id+(system ? 0 : systemCells)]!=-1.f;
}
Quad Ocean::bubblePalette(BubbleId bubble) const {
    const Region* region = nullptr;
    if (bubble.kind==BubbleKind::Region) region=regionAt(bubble.id);
    else if (bubble.id<systemCells) region=regionAt(regionOfSystem(bubble.id));
    return bubblePalette(bubble,region ? region->scale : 0);
}
Quad Ocean::bubblePalette(BubbleId bubble,unsigned layer) const {
    auto palette = layerMonochrome[std::min(layer,unsigned(regionScales-1))];
    palette.w = bubbleColour(bubble);
    return palette;
}
bool Ocean::passageLocked() const {
    return openingRoute() && depth<bellPassageCount && !(unlockedPassages&(1u<<depth));
}
bool Ocean::bubbleEntryLocked(unsigned slot) const {
    return passageLocked() && slot==bellSystemSlots[bellAnimals[depth]]+1;
}

std::optional<unsigned> Ocean::bubbleFlightLayer(unsigned slot) const {
    if (!openingRoute()) return {};
    if (slot==0) return whirlpoolDepth-1;
    if (const auto* region=bubbleRegion(slot)) return region->scale;
    const auto end=bellSystemSlots.begin()+bubbleCount;
    const auto found=std::find(bellSystemSlots.begin(),end,slot-1);
    if (found==end) return {};
    const auto index=std::size_t(found-bellSystemSlots.begin());
    if (bellPassageByAnimal[index]) return {};
    return animals[index].realm;
}

void Ocean::holdShip() {
    launchHold=true;
    velocity={};
}
bool Ocean::canBoardBubble(unsigned slot) const {
    if (bubbleEntryLocked(slot)) return false;
    if (slot == 0) return openingRoute() && depth == whirlpoolDepth-1;
    if (const auto* region = bubbleRegion(slot)) return openingRoute() && region->scale == depth;
    const auto end = bellSystemSlots.begin()+bubbleCount;
    const auto found = std::find(bellSystemSlots.begin(),end,slot-1);
    if (found == end) return false;
    const auto index = std::size_t(found-bellSystemSlots.begin());
    if (!openingRoute()) return true;
    const auto gate = bellPassageByAnimal[index];
    return gate ? gate == depth+1 : animals[index].realm == depth;
}
std::optional<Bubble> Ocean::stringBubble(unsigned slot, const Scene& view) const {
    if (slot == 0) return ziksaBubble(view);
    if (const auto* region = bubbleRegion(slot)) return regionView(std::size_t(region-regionMap.data()),view);
    const auto end = bellSystemSlots.begin()+bubbleCount;
    const auto found = std::find(bellSystemSlots.begin(),end,slot-1);
    if (found == end) return {};
    auto bubble = animalView(animals[found-bellSystemSlots.begin()]);
    bubble.presence *= (1.f-view.cycle.z)*view.basinArrival;
    return bubble;
}
Bubble Ocean::birthBubble() const {
    const float progress = transformationProgress();
    const float scale = descentScale(depthBlend);
    Bubble view{packed(player,transformationRadius(progress,scale)),
                {.93f,clock*.72f,0.f,0.f},{0.f,yaw,1.f,.7f},{},
                1.f-eased(progress,.24f,.52f)};
    view.bellSystemVisibility = systemEmergence();
    view.bellSystem = float(bellSystemSlots.back()+1);
    view.palette = bubblePalette({BubbleKind::System,residentSystem(bellSystemSlots.back()).id},whirlpoolDepth);
    return view;
}
void Ocean::recordTrails() {
    auto* row = trailHistory.data()+nextTrailSlot*bubbleCount;
    for (std::size_t i = 0; i < animals.size(); ++i) {
        const auto bubble = animalView(animals[i]);
        const float strength = bubble.membraneAnchor == 0.f ?
            bubble.presence*(bubble.basinTone < 0.f ? 1.f : .28f+.72f*bubble.basinLight) : 0.f;
        row[i] = {bubble.position,{clock,bubble.pigment.x,0.f,strength*.65f},bubble.palette};
    }
    nextTrailSlot = (nextTrailSlot+1)%trailSamples;
    trailCount = std::min(trailCount+1,unsigned(trailSamples));
}
std::vector<Bubble> Ocean::shoal(float aspect) const {
    std::array<Bubble,shoalCapacity> storage;
    const auto visible = shoal(scene(aspect),storage);
    return {visible.begin(),visible.end()};
}
std::span<const Bubble> Ocean::shoal(const Scene& view, std::span<Bubble,shoalCapacity> storage,
                                    HullLight* hullLight) const {
    const Vec camera = unpack(view.eye);
    const Vec forward = unpack(view.forward);
    const Vec right = unpack(view.right), up = unpack(view.up);
    const float vertical = .55f, horizontal = vertical*view.screen.x;
    const float sidePlane = std::sqrt(1.f+horizontal*horizontal);
    const float topPlane = std::sqrt(1.f+vertical*vertical);
    std::size_t count = 0;
    if (hullLight) *hullLight = {};
    const auto reflectFilm = [&](const Bubble& film) {
        if (!hullLight || film.presence <= .001f) return;
        const float kind = film.pigment.w;
        const float size = film.position.w *
            (kind > 4.5f ? .83f : kind > 3.5f ? .57f : kind > 1.5f ? 1.21f : kind > .5f ? .83f : 1.f);
        Vec centre = unpack(film.position);
        if (film.membraneAnchor > 0.f) centre += facing(film.flow.y,-film.pitch)*size;
        const auto offset = centre-player;
        const float distance = length(offset);
        const float gap = std::abs(distance-size);
        const float span = 1.4f+.68f*std::sqrt(size);
        if (gap >= 4.f*span) return;
        const float attenuation = 1.f/(1.f+(gap/span)*(gap/span));
        const float cover = size/(size+gap+.30f);
        const float strength = film.presence*cover*attenuation*(1.f-eased(gap,2.5f*span,4.f*span));
        const Vec locked = unpack(film.palette);
        const auto* region = bubbleRegion(unsigned(film.bellSystem));
        const Vec pigment = region ? unpack(regionTint(*region)) : hue(film.pigment.x);
        const Vec light = (locked+(pigment-locked)*film.palette.w)*strength;
        // A membrane crossing spreads the light over both sides of the hull.
        const float side = 2.f*eased(distance-size,-.45f,.45f)-1.f;
        const Vec direction = offset*(side/std::max(.001f,distance));
        const std::array weights{direction.x,-direction.x,direction.y,-direction.y,direction.z,-direction.z};
        const float surround = .075f+.24f*(1.f-std::abs(side));
        for (std::size_t i=0; i<weights.size(); ++i) {
            auto& lobe = (*hullLight)[i];
            lobe = packed(unpack(lobe)+light*(surround+.87f*std::max(0.f,weights[i])));
        }
    };
    const auto inFrustum = [&](Vec p, float radius, float viewRange) {
        const Vec centre = p-camera;
        const float distance = dot(centre,forward);
        return distance+radius >= .12f && length(centre)-radius <= viewRange &&
            std::abs(dot(centre,right)) <= distance*horizontal+radius*sidePlane &&
            std::abs(dot(centre,up)) <= distance*vertical+radius*topPlane;
    };
    for (const auto& jelly : animals) {
        auto visual = animalView(jelly);
        visual.presence *= (1.f-view.cycle.z)*view.basinArrival;
        if (visual.presence <= 0.f) continue;
        reflectFilm(visual);
        // Portal positions are on the near surface, so use a bound that includes the far side.
        const float radius = (visual.membraneAnchor > 0.f ? 2.5f : 1.55f)*jelly.size;
        const float viewRange = visual.membraneAnchor > 0.f ? 226.f*std::max(1.f,jelly.size/40.f) :
                                jelly.size >= basinGiantSize ? 238.f : 112.f;
        if ((view.heldBubbleCentre.w > 0.f && unsigned(visual.bellSystem) == view.heldBubble) ||
            inFrustum(jelly.p,radius,viewRange)) storage[count++] = visual;
    }
    if (openingRoute()) {
        for (std::size_t i = 0; i < regionMap.size(); ++i) {
            const auto visual = regionView(i,view);
            reflectFilm(visual);
            if (visual.presence > 0.f && ((view.heldBubbleCentre.w > 0.f && unsigned(visual.bellSystem) == view.heldBubble) ||
                inFrustum(unpack(visual.position),visual.position.w*1.55f,100.f)))
                storage[count++] = visual;
        }
    }
    const auto ziksa = ziksaBubble(view);
    reflectFilm(ziksa);
    if (ziksa.presence > 0.f && inFrustum(unpack(ziksa.position),1.7f,100.f)) storage[count++] = ziksa;
    if (transforming()) {
        const auto birth = birthBubble();
        reflectFilm(birth);
        if (birth.presence > 0.f) storage[count++] = birth;
    }
    return storage.first(count);
}
} // namespace pelagic
