// Xalaria–Infinity 0.68.0. Only the original deterministic geology and
// material samplers used by the cockpit renderer are included here.
#include "infinity/MajorLandforms.hpp"
#include "infinity/Prospecting.hpp"
#include "infinity/SurfaceProvince.hpp"
#include "infinity/TerrainMaterial.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>
#include <numeric>
#include <stdexcept>

namespace infinity {
namespace {
constexpr double pi = std::numbers::pi;
glm::dvec3 sphere(const Random& r, uint64_t i) {
    double z = r.signedUnit(i), a = r.unit(i + 1) * 2 * pi;
    return {std::sqrt(1 - z * z) * std::cos(a), z, std::sqrt(1 - z * z) * std::sin(a)};
}
} // namespace

uint64_t mix64(uint64_t x) {
    x += 0x9e3779b97f4a7c15ULL;
    x = (x ^ (x >> 30)) * 0xbf58476d1ce4e5b9ULL;
    x = (x ^ (x >> 27)) * 0x94d049bb133111ebULL;
    return x ^ (x >> 31);
}

uint64_t featureSeed(uint64_t objectSeed, Feature feature, uint64_t id) {
    return mix64(mix64(objectSeed ^ 0x726566696e656d65ULL) + mix64(static_cast<uint64_t>(feature)) +
                 mix64(id));
}

double smoothstep(double a, double b, double x) {
    x = std::clamp((x - a) / (b - a), 0.0, 1.0);
    return x * x * (3 - 2 * x);
}
double valueNoise(glm::dvec3 p, uint64_t seed) {
    auto q = glm::floor(p);
    auto f = p - q;
    f = f * f * (3.0 - 2.0 * f);
    auto sample = [&](int x, int y, int z) {
        uint64_t h = seed;
        h = mix64(h ^ static_cast<uint64_t>(static_cast<int64_t>(q.x) + x));
        h = mix64(h ^ static_cast<uint64_t>(static_cast<int64_t>(q.y) + y));
        h = mix64(h ^ static_cast<uint64_t>(static_cast<int64_t>(q.z) + z));
        return Random{h}.signedUnit(0);
    };
    double a = glm::mix(sample(0, 0, 0), sample(1, 0, 0), f.x),
           b = glm::mix(sample(0, 1, 0), sample(1, 1, 0), f.x);
    double c = glm::mix(sample(0, 0, 1), sample(1, 0, 1), f.x),
           d = glm::mix(sample(0, 1, 1), sample(1, 1, 1), f.x);
    return glm::mix(glm::mix(a, b, f.y), glm::mix(c, d, f.y), f.z);
}
double fractalNoise(glm::dvec3 p, uint64_t seed, int octaves) {
    double a = .5, sum = 0;
    for (int i = 0; i < octaves; ++i) {
        sum += a * valueNoise(p, seed);
        p = p * 2.03 + glm::dvec3(17.1, 3.7, 9.2);
        a *= .5;
    }
    return sum;
}
glm::dvec3 cubeDirection(int face, double u, double v) {
    switch (face) {
    case 0:
        return glm::normalize(glm::dvec3(1, v, -u));
    case 1:
        return glm::normalize(glm::dvec3(-1, v, u));
    case 2:
        return glm::normalize(glm::dvec3(u, 1, -v));
    case 3:
        return glm::normalize(glm::dvec3(u, -1, v));
    case 4:
        return glm::normalize(glm::dvec3(u, v, 1));
    case 5:
        return glm::normalize(glm::dvec3(-u, v, -1));
    default:
        throw std::invalid_argument("Cube face");
    }
}
glm::dquat tangentFrame(glm::dvec3 n) {
    auto east =
        glm::normalize(glm::cross(std::abs(n.y) > .95 ? glm::dvec3(0, 0, 1) : glm::dvec3(0, 1, 0), n));
    return glm::quat_cast(glm::dmat3(east, n, glm::cross(east, n)));
}

const Material& material(Mineral m) {
    static const std::array<Material, 5> lib{
        {{Mineral::Quartz, "QUARTZ", "SiO2", "trigonal / alpha quartz", {.46f, .81f, .88f}, 2650, 4.913e-10},
         {Mineral::Iron, "IRON", "Fe", "body-centred cubic", {.74f, .66f, .55f}, 7874, 2.866e-10},
         {Mineral::Olivine, "OLIVINE", "Mg2SiO4", "orthorhombic", {.51f, .71f, .25f}, 3300, 4.754e-10},
         {Mineral::Ice, "ICE Ih", "H2O", "hexagonal oxygen network", {.55f, .76f, .95f}, 917, 4.518e-10},
         {Mineral::Graphite, "GRAPHITE", "C", "hexagonal / AB layers", {.29f, .32f, .36f}, 2260, 2.461e-10}}};
    return lib.at(static_cast<size_t>(m));
}
void Composition::normalize() {
    for (double value : {silicate, metal, carbon, ice})
        if (!std::isfinite(value) || value < 0)
            throw std::invalid_argument("Invalid chemistry reservoir");
    double s = silicate + metal + carbon + ice;
    if (!(s > 0) || !std::isfinite(s))
        throw std::invalid_argument("Empty chemistry");
    silicate /= s;
    metal /= s;
    carbon /= s;
    ice /= s;
}

std::shared_ptr<const PlanetProcess> planetProcess(uint64_t seed, double logRadius, const Environment& e,
                                                   bool localTerrain, bool gasEnvelope) {
    auto p = std::make_shared<PlanetProcess>();
    p->seed = seed;
    p->logRadius = logRadius;
    p->ageGyr = e.ageGyr;
    // Size/age control remaining heat; hydration weakens a silicate lithosphere.
    p->activity = std::clamp(std::pow(10.0, logRadius - 6.8) * std::exp(-e.ageGyr / 7) *
                                 (.55 + e.peakTemperature / 2200),
                             .015, 1.0);
    p->ice = e.chemistry.ice;
    p->liquidWater =
        e.waterActivity * smoothstep(235, 275, e.temperature) * (1 - smoothstep(340, 410, e.temperature));
    p->type = gasEnvelope                                    ? GeologyType::GasEnvelope
              : e.chemistry.ice > .25 && e.temperature < 250 ? GeologyType::IceShell
              : p->activity * (.12 + p->liquidWater) > .27   ? GeologyType::MobileLid
                                                             : GeologyType::StagnantLid;
    Random r{featureSeed(seed, Feature::PlateMotion, 0)};
    for (size_t i = 0; i < p->plates.size(); ++i) {
        // Fibonacci centres avoid accidental tiny plates; keyed perturbations
        // and independent Euler poles supply coherent rigid plate motions.
        double y = 1 - 2 * (i + .5) / p->plates.size();
        double angle = i * pi * (3 - std::sqrt(5.0)) + .15 * r.signedUnit(i * 8);
        auto centre =
            glm::dvec3(std::sqrt(1 - y * y) * std::cos(angle), y, std::sqrt(1 - y * y) * std::sin(angle));
        p->plates[i] = {centre, sphere(r, i * 8 + 1) * (.3 + .7 * r.unit(i * 8 + 3)), r.unit(i * 8 + 4)};
    }
    Random impacts{featureSeed(seed, Feature::Impacts, 0)};
    for (size_t i = 0; i < p->impacts.size(); ++i) {
        double radius = .014 * std::pow(1 - .96 * impacts.unit(i * 4 + 2), -.7);
        double age = e.ageGyr * impacts.unit(i * 4 + 3);
        double resurfacing = p->activity * (p->type == GeologyType::MobileLid ? 2 : .35) + p->liquidWater;
        p->impacts[i] = {sphere(impacts, i * 4), radius, std::exp(-age * resurfacing)};
    }
    for (size_t i = 0; i < p->hotspots.size(); ++i)
        p->hotspots[i] = sphere(r, 1000 + i * 2);
    if (localTerrain) {
        p->terrain = terrainProcess(*p, e);
        p->landform = generateMajorLandform(*p, e);
    }
    return p;
}
GeologySample geologySample(const PlanetProcess& p, glm::dvec3 d) {
    if (p.type == GeologyType::GasEnvelope)
        return {};
    d = glm::normalize(d);
    GeologySample s;
    std::array<double, 12> weights;
    double sum = 0;
    for (size_t i = 0; i < p.plates.size(); ++i) {
        weights[i] = std::exp(28 * (glm::dot(d, p.plates[i].centre) - 1));
        sum += weights[i];
    }
    for (size_t i = 0; i < weights.size(); ++i) {
        weights[i] /= sum;
        s.continental += weights[i] * p.plates[i].continental;
    }
    // Pairwise smooth weights keep triple junctions continuous. Closure and
    // shear derive from v = omega x r, rather than a boundary-noise label.
    for (size_t i = 0; i < p.plates.size(); ++i)
        for (size_t j = i + 1; j < p.plates.size(); ++j) {
            double w = 4 * weights[i] * weights[j];
            if (w < 1e-12)
                continue;
            auto normal = p.plates[j].centre - p.plates[i].centre;
            normal -= d * glm::dot(normal, d);
            if (glm::dot(normal, normal) < 1e-24)
                continue;
            normal = glm::normalize(normal);
            auto velocity = glm::cross(p.plates[i].angularVelocity - p.plates[j].angularVelocity, d);
            double closure = glm::dot(velocity, normal);
            s.convergence += w * std::max(0.0, closure);
            s.divergence += w * std::max(0.0, -closure);
            s.shear += w * std::abs(glm::dot(velocity, glm::cross(d, normal)));
        }
    double mobile = p.type == GeologyType::MobileLid ? p.activity : p.activity * .12;
    double continents = (s.continental - .5) * .012;
    double ridges = .004 * s.convergence - .0017 * s.divergence;
    // Subduction trench and uplift are separated by crust buoyancy.
    ridges -= .002 * s.convergence * (1 - smoothstep(.32, .65, s.continental));
    double fine = fractalNoise(d * 180.0, featureSeed(p.seed, Feature::PlateMotion, 1), 4);
    for (auto hot : p.hotspots) {
        double distance = glm::length(d - hot);
        s.volcanism += p.activity * std::exp(-distance * distance / .0064);
    }
    double height = continents + mobile * ridges + .005 * s.volcanism;
    for (const auto& crater : p.impacts) {
        double q = glm::length(d - crater.centre) / crater.radius;
        if (q < 1.7) {
            double taper = 1 - smoothstep(1.35, 1.7, q);
            double bowl = -.03 * crater.radius * std::exp(-q * q * 2.5);
            double rim = .012 * crater.radius * std::exp(-std::pow((q - 1) * 6, 2));
            double ejecta = .002 * crater.radius * std::exp(-q) * smoothstep(.95, 1.2, q);
            double relief = (bowl + rim + ejecta) * crater.survival * taper;
            height += relief;
            s.cratering += std::abs(relief);
        }
    }
    // Analytic weathering/incision proxy, evaluated in planet coordinates.
    // It is deliberately not presented as a solved fluid/erosion simulation.
    double drainage = std::pow(1 - std::abs(fractalNoise(d * 42.0, p.seed, 3)), 8);
    s.erosion = p.liquidWater * (.0006 * drainage + .001 * mobile * s.convergence);
    s.sediment = p.liquidWater * (1 - smoothstep(-.002, .002, height));
    height -= s.erosion;
    height += s.sediment * .0005;
    height += fine * (.00025 + .0007 * mobile * s.convergence);
    if (p.type == GeologyType::IceShell) {
        // Extensional belts in a buoyant icy shell and subdued impact relief.
        height = height * .35 + .0015 * s.divergence - .001 * s.shear + fine * .00015;
    }
    s.localReliefMetres = localTerrainHeight(p, d, s);
    s.heightMetres = std::pow(10.0, p.logRadius) * height + s.localReliefMetres;
    if (p.landform) {
        const auto major = sampleMajorLandform(*p.landform,d);
        s.majorReliefMetres = major.reliefMetres;
        s.majorCoverage = major.coverage;
        s.majorHeat = major.heat;
        s.majorIce = major.ice;
        s.majorFracture = major.fracture;
        s.heightMetres += major.reliefMetres;
        s.volcanism += major.heat * .5;
        s.shear += major.fracture * .2;
        s.cratering += major.impact * .0006;
    }
    return s;
}

bool hasSolidSurface(const Node& node) {
    return node.geology && node.geology->type != GeologyType::GasEnvelope;
}
std::string_view terrainName(TerrainType type) {
    switch (type) {
    case TerrainType::Highlands:
        return "Highlands";
    case TerrainType::Volcanic:
        return "Volcanic";
    case TerrainType::Dissected:
        return "Canyons";
    case TerrainType::IceRidges:
        return "Ice ridges";
    default:
        return "Plains";
    }
}
TerrainProcess terrainProcess(const PlanetProcess& planet, const Environment& environment) {
    TerrainProcess terrain;
    if (planet.type == GeologyType::GasEnvelope)
        return terrain;
    const Random random{featureSeed(planet.seed, Feature::LocalRelief, terrainRecipeVersion)};
    // A subset retains smoother landscapes. The catalogue's old planets use
    // the existing geological recipe; this additive layer is opt-in.
    if (random.unit(0) < .20)
        return terrain;
    terrain.seed = random.key;
    terrain.type = planet.type == GeologyType::IceShell                          ? TerrainType::IceRidges
                   : planet.liquidWater > .10                                    ? TerrainType::Dissected
                   : planet.activity > .10 && environment.peakTemperature > 1400 ? TerrainType::Volcanic
                                                                                 : TerrainType::Highlands;
    const double radius = std::pow(10., planet.logRadius);
    terrain.wavelengthMetres = std::clamp(radius * (.003 + .009 * random.unit(1)), 500., 12000.);
    terrain.reliefMetres = std::clamp(terrain.wavelengthMetres * (.16 + .12 * random.unit(2)), 40., 1800.);
    terrain.weathering = std::clamp(planet.liquidWater * (.4 + planet.ageGyr / 8.), 0., .85);
    if (terrain.type == TerrainType::IceRidges)
        terrain.reliefMetres *= .65;
    // Existing Euler motion provides the fabric direction; no independent
    // local terrain scene or sampling-window seed is introduced.
    terrain.fabric = tangentFrame(glm::normalize(planet.plates[0].angularVelocity));
    return terrain;
}
double localTerrainHeight(const PlanetProcess& planet, glm::dvec3 direction, const GeologySample& geology) {
    const auto& terrain = planet.terrain;
    if (planet.type == GeologyType::GasEnvelope || terrain.type == TerrainType::None)
        return 0;
    const double radius = std::pow(10., planet.logRadius);
    const auto d = glm::normalize(direction);
    const auto q = glm::inverse(terrain.fabric) * d * (radius / terrain.wavelengthMetres);
    const double regional = smoothstep(-.28, .28, fractalNoise(d * 11., terrain.seed, 2));
    // Domain warping bends ridges continuously in planet coordinates. The
    // same field is sampled by orbit meshes, streamed patches and collisions.
    const double bend = fractalNoise(q * .35, mix64(terrain.seed ^ 1), 2);
    const auto warped = q + glm::dvec3(bend * .8, bend * .3, -bend * .5);
    const double signal = fractalNoise(warped, terrain.seed, 4);
    const double ridge = std::pow(std::max(0., 1 - std::sqrt(signal * signal * 3.2 + .0025)), 3);
    const double detail = fractalNoise(warped * 3.2, mix64(terrain.seed ^ 2), 3);
    double height = 0;
    switch (terrain.type) {
    case TerrainType::Highlands:
        height = (ridge - .4 + detail * .30) * (.45 + .55 * std::clamp(geology.convergence, 0., 1.));
        break;
    case TerrainType::Volcanic:
        height = (ridge * ridge - .35 + detail * .22) * (.45 + std::min(1., geology.volcanism) * 1.4);
        break;
    case TerrainType::Dissected: {
        const double channel = std::pow(std::max(0., 1 - std::sqrt(signal * signal * 5 + .0025)), 9);
        height = detail * .35 - channel * (.65 + terrain.weathering * .35);
        break;
    }
    case TerrainType::IceRidges:
        height = (ridge - .4 + detail * .20) *
                 (.5 + .5 * std::clamp(geology.divergence + geology.shear * .5, 0., 1.));
        break;
    default:
        return 0;
    }
    return terrain.reliefMetres * regional * height * (1 - terrain.weathering * .35);
}
SurfaceProvince ProvinceSample::dominant() const {
    return SurfaceProvince(std::max_element(weights.begin(), weights.end()) - weights.begin());
}
std::string_view provinceName(SurfaceProvince type) {
    constexpr std::array names{"Weathered Bedrock", "Folded Uplands", "Volcanic Field",
                               "Impact Field", "Sediment Basin", "Frost Belt"};
    return names[size_t(type)];
}
ProvinceSample surfaceProvince(const PlanetProcess& planet, glm::dvec3 d, const GeologySample& g) {
    if (planet.type == GeologyType::GasEnvelope)
        return {};
    const double h = g.heightMetres / std::pow(10., planet.logRadius);
    const double elevation = smoothstep(.0009, .004, h);
    const double folding = smoothstep(.045, .52, g.convergence + g.shear * .65);
    const double lava = smoothstep(.021, .22, g.volcanism);
    const double ejecta = smoothstep(.000055, .00042, g.cratering);
    const double deposition = smoothstep(.018, .20, g.sediment) * (1 - smoothstep(-.001, .0015, h));
    double frost = 0;
    if (planet.type == GeologyType::IceShell || planet.ice > .12) {
        // Use the same spin axis as planetary weather.
        const auto axis = glm::normalize(planet.plates.front().angularVelocity);
        const double polarCold = smoothstep(.43, .94, std::abs(glm::dot(axis, d)));
        frost = planet.type == GeologyType::IceShell ? .56 + .63 * polarCold + .16 * elevation
                : smoothstep(.12, .46, planet.ice) * (.15 + .87 * polarCold + .28 * elevation);
    }
    const double bedrock = .36 + .25 * (1 - smoothstep(.015, .19, planet.liquidWater));
    return {{bedrock, .66 * elevation + .84 * folding, 1.55 * lava, 1.52 * ejecta,
             1.42 * deposition, frost}};
}
glm::vec3 provinceAlbedo(const ProvinceSample& sample, glm::vec3 substrate) {
    constexpr std::array palette{
        glm::vec3(.36f, .23f, .24f), glm::vec3(.58f, .40f, .29f), glm::vec3(.12f, .075f, .16f),
        glm::vec3(.62f, .49f, .42f), glm::vec3(.33f, .45f, .27f), glm::vec3(.49f, .69f, .79f)};
    glm::vec3 color(0);
    double total = 0;
    for (size_t i = 0; i < palette.size(); ++i) {
        const double weight = sample.weights[i] * sample.weights[i];
        color += palette[i] * float(weight);
        total += weight;
    }
    return total > 0 ? glm::mix(substrate, color / float(total), .72f) : substrate;
}

std::shared_ptr<const MajorLandform> generateMajorLandform(const PlanetProcess& p, const Environment& e) {
    if (p.type == GeologyType::GasEnvelope)
        return {};
    const double radius = std::pow(10., p.logRadius);
    if (radius < 180000)
        return {};
    // Frozen society admission has probability at most .96. Use only its
    // rejected tail (or physically excluded worlds), never move an old town.
    const double gravity = 4.188790204786391 * 6.67430e-11 * material(e.mineral).density * radius;
    if (e.temperature >= 85 && e.temperature <= 650 && gravity <= 32 &&
        Random{featureSeed(p.seed, Feature::SurfaceSociety, 1)}.unit(0) <= .96)
        return {};
    const Random r{featureSeed(p.seed, Feature::LocalRelief, 0x6d616a6f720001ULL)};
    if (r.unit(0) >= .30)
        return {};
    auto f = std::make_shared<MajorLandform>();
    f->seed = r.key;
    f->radiusMetres = radius;
    const bool frozen = p.type == GeologyType::IceShell && e.temperature < 245 && p.ice > .25;
    const bool volcanic = p.activity > .045 && e.chemistry.silicate > .25 && e.peakTemperature > 1250;
    if (frozen)
        f->type = MajorLandformType::IceSheet;
    else if (volcanic && r.unit(1) < .65)
        f->type = r.unit(2) < .55 ? MajorLandformType::Supercaldera : MajorLandformType::ShieldVolcano;
    else
        f->type = r.unit(3) < .5 ? MajorLandformType::Rift : MajorLandformType::ImpactBasin;
    // Start from inherited geological structures, then choose the highest dry
    // candidate. Sampling the unmodified process cannot recurse into this layer.
    double best = -1e100;
    for (unsigned i = 0; i < 12; ++i) {
        glm::dvec3 d;
        if (frozen) {
            const auto pole = glm::normalize(p.plates[0].angularVelocity) * (r.unit(4) < .5 ? -1. : 1.);
            const auto frame = tangentFrame(pole);
            const double a = i * 2.399963229728653;
            d = glm::normalize(pole + frame * glm::dvec3(.3 * std::cos(a), 0, .3 * std::sin(a)));
        } else if (f->type == MajorLandformType::Supercaldera || f->type == MajorLandformType::ShieldVolcano)
            d = p.hotspots[i % p.hotspots.size()];
        else if (f->type == MajorLandformType::ImpactBasin)
            d = p.impacts[i].centre;
        else
            d = glm::normalize(p.plates[i].centre + p.plates[(i + 1) % p.plates.size()].centre);
        const auto g = geologySample(p, d);
        const double score =
            g.heightMetres +
            (f->type == MajorLandformType::ImpactBasin ? p.impacts[i].survival * radius * .005 : 0);
        if (score > best) {
            best = score;
            f->centre = d;
        }
    }
    if (p.liquidWater > .1 && geologySample(p, f->centre).heightMetres < -radius * .0005)
        return {};
    auto along = p.plates[0].angularVelocity - f->centre * glm::dot(p.plates[0].angularVelocity, f->centre);
    if (glm::length(along) < 1e-8)
        along = glm::cross(f->centre, glm::dvec3(1, .1, 0));
    if (frozen) {
        // Route the outlet ice down the inherited catchment gradient.
        const auto frame = tangentFrame(f->centre);
        const auto east = frame * glm::dvec3(.0005, 0, 0);
        const auto north = frame * glm::dvec3(0, 0, .0005);
        const double dx = geologySample(p, glm::normalize(f->centre + east)).heightMetres -
                          geologySample(p, glm::normalize(f->centre - east)).heightMetres;
        const double dz = geologySample(p, glm::normalize(f->centre + north)).heightMetres -
                          geologySample(p, glm::normalize(f->centre - north)).heightMetres;
        const auto downhill = -east * dx - north * dz;
        if (glm::length(downhill) > 1e-8)
            along = downhill;
    }
    f->along = glm::normalize(along);
    f->across = glm::normalize(glm::cross(f->centre, f->along));
    const double scale = .7 + .6 * r.unit(5);
    const double gravityLimit = std::clamp(10. / std::max(1., gravity), .35, 2.5);
    switch (f->type) {
    case MajorLandformType::Supercaldera:
        f->widthMetres = std::min(radius * .035, 35000. * scale);
        f->lengthMetres = f->widthMetres * (.8 + .4 * r.unit(6));
        f->reliefMetres = std::min(f->widthMetres * .13, 4500. * gravityLimit);
        break;
    case MajorLandformType::ShieldVolcano:
        f->widthMetres = std::min(radius * .10, 220000. * scale);
        f->lengthMetres = f->widthMetres * .85;
        f->reliefMetres = std::min(f->widthMetres * .085, 17000. * gravityLimit);
        break;
    case MajorLandformType::IceSheet:
        f->widthMetres = std::min(radius * .09, 350000. * scale);
        f->lengthMetres = f->widthMetres * 1.4;
        f->reliefMetres = std::min(f->widthMetres * .025, 4000. * gravityLimit);
        break;
    case MajorLandformType::Rift:
        f->widthMetres = std::min(radius * .018, 50000. * scale);
        f->lengthMetres = std::min(radius * .12, f->widthMetres * 7.);
        f->reliefMetres = std::min(f->widthMetres * .18, 7000. * gravityLimit);
        break;
    case MajorLandformType::ImpactBasin:
        f->widthMetres = std::min(radius * .08, 180000. * scale);
        f->lengthMetres = f->widthMetres;
        f->reliefMetres = std::min(f->widthMetres * .045, 7000. * gravityLimit);
        break;
    }
    f->activity = volcanic ? std::clamp(p.activity * 1.8, 0., 1.) : 0;
    return f;
}
MajorLandformSample sampleMajorLandform(const MajorLandform& f, glm::dvec3 direction) {
    const auto d = glm::normalize(direction);
    if (glm::dot(d, f.centre) < .9)
        return {};
    const double x = glm::dot(d, f.along) * f.radiusMetres / f.lengthMetres;
    const double z = glm::dot(d, f.across) * f.radiusMetres / f.widthMetres;
    const double q = std::sqrt(x * x + z * z);
    if (q >= 2.3)
        return {};
    const double taper = 1 - smoothstep(1.8, 2.3, q);
    const auto bell = [](double a, double width) { return std::exp(-a * a / (width * width)); };
    MajorLandformSample s;
    s.coverage = (1 - smoothstep(1., 2.3, q));
    double h = 0;
    switch (f.type) {
    case MajorLandformType::Supercaldera: {
        const double floor = 1 - smoothstep(.68, .92, q);
        h = .24 * bell(q, 1.4) - floor * .8 + .44 * bell(q - .98, .11) + .24 * bell(q, .22);
        s.fracture = .8 * bell(q - .88, .15) * taper;
        s.heat = f.activity * bell(q, .24);
        break;
    }
    case MajorLandformType::ShieldVolcano: {
        const double dome = std::pow(std::max(0., 1 - q / 1.8), 2);
        h = dome - .38 * bell(q, .13) + .055 * bell(q - .20, .055);
        // Lobate apron and channels remain fixed to the edifice, never time noise.
        h += .045 * std::sin(std::atan2(z, x) * 11 + q * 8) * smoothstep(.2, .5, q) * dome;
        s.heat = f.activity * bell(q, .12);
        s.fracture = .3 * bell(q - .2, .07);
        break;
    }
    case MajorLandformType::IceSheet: {
        const double dome = std::sqrt(std::max(0., 1 - q * q));
        // Accumulation dome feeds three outlet tongues and scoured U troughs.
        const double outlet = smoothstep(-.35, .65, x) * (1 - smoothstep(1.2, 2.1, x));
        const double channels =
            bell(z - .34 - .05 * std::sin(x * 4), .13) + bell(z + .37, .16) + bell(z, .10);
        h = dome + outlet * channels * .22;
        const double margin = bell(q - .98, .08);
        const double cracks = (.5 + .5 * std::sin(x * 115 + std::sin(z * 32) * 2));
        s.fracture = std::clamp(margin * .85 + outlet * channels * cracks * .45, 0., 1.) * taper;
        h -= s.fracture * .055;
        h += bell(q - 1.13, .055) * .07; // terminal moraine
        s.ice = std::clamp(dome + outlet * channels, 0., 1.) * taper;
        break;
    }
    case MajorLandformType::Rift: {
        const double edge = 1 - smoothstep(.68, 1.05, std::abs(x));
        const double bend = z + .10 * std::sin(x * 4);
        h = edge * (-.85 * bell(bend, .38) - .28 * bell(bend, .17) + .18 * bell(std::abs(bend) - .65, .15));
        s.fracture = edge * bell(std::abs(bend) - .4, .2) * taper;
        break;
    }
    case MajorLandformType::ImpactBasin:
        h = -.8 * bell(q, .62) + .38 * bell(q - .82, .10) + .21 * bell(q - 1.25, .09) +
            .12 * bell(q - 1.65, .08) + .12 * bell(q, .18);
        s.impact = s.coverage;
        s.fracture = .6 * bell(q - .82, .15) * taper;
        break;
    }
    s.reliefMetres = h * f.reliefMetres * taper;
    return s;
}

std::array<glm::vec4, 4> TerrainMaterial::uniforms() const {
    return {glm::vec4(bedrock, rockRoughness), glm::vec4(sediment, sedimentRoughness),
            glm::vec4(layerMetres, sedimentCover, metal, radiusMetres), glm::vec4(fabric, frozen)};
}
TerrainMaterial terrainMaterial(const Node& n) {
    TerrainMaterial m;
    if (!hasSolidSurface(n)) return m;
    const auto& p = *n.geology;
    const auto& e = n.environment;
    const std::array<glm::vec3, 5> rock{{{.27f,.29f,.32f}, {.29f,.14f,.075f}, {.16f,.24f,.15f},
                                       {.085f,.27f,.36f}, {.065f,.075f,.10f}}};
    m.bedrock = rock[size_t(e.mineral)];
    m.frozen = float(std::clamp(std::max({e.mineral == Mineral::Ice ? 1. : 0.,
        p.type == GeologyType::IceShell ? .9 : 0., e.chemistry.ice}) *
        (1 - smoothstep(265., 305., e.temperature)), 0., 1.));
    m.bedrock = glm::mix(m.bedrock, glm::vec3(.075f,.25f,.34f), m.frozen);
    // Weathered iron, silicate dust and carbon remain chemically distinct.
    const auto dust = glm::mix(glm::vec3(.35f,.29f,.21f), glm::vec3(.38f,.18f,.09f), float(e.chemistry.metal));
    m.sediment = glm::mix(m.bedrock * 1.12f, dust, float(.25 + .45 * e.waterActivity));
    m.sediment = glm::mix(m.sediment, glm::vec3(.63f,.78f,.83f), m.frozen);
    m.sedimentCover = float(std::clamp(.25 + p.terrain.weathering * .6 + e.ageGyr * .025 - p.activity * .15, .12, .85));
    m.metal = float(std::clamp(e.chemistry.metal * (e.mineral == Mineral::Iron ? .85 : .30), 0., .8));
    m.rockRoughness = glm::mix(.66f - m.metal * .20f, .24f, m.frozen);
    m.sedimentRoughness = glm::mix(.91f, .78f, m.frozen);
    m.layerMetres = float(std::clamp(p.terrain.wavelengthMetres / 320., 2., 28.));
    m.radiusMetres = float(std::pow(10., p.logRadius));
    m.fabric = glm::vec3(p.terrain.fabric * glm::dvec3(0, 1, 0));
    return m;
}

ResourceExposure resourceExposure(const Node& n, glm::dvec3 d, const GeologySample& g) {
    ResourceExposure out;
    if (!hasSolidSurface(n))
        return out;
    auto c = n.environment.chemistry;
    c.normalize();
    const double fracture = std::clamp(g.convergence + g.shear + g.divergence * .6, 0., 2.);
    const double impact = std::clamp(g.cratering * 2000, 0., 1.);
    const double water = n.geology->liquidWater;
    const double cold = 1 - smoothstep(190, 260, n.environment.temperature);
    // Transport and concentration amplify existing constituents, never create a missing element.
    const double vein = fracture * (.25 + water) + g.volcanism * 2.5;
    const double sediment = g.sediment + g.erosion * 400;
    const double fabric =
        .5 + .5 * fractalNoise(glm::normalize(d) * 64., mix64(n.planetSeed ^ 0x4558504f53555245ULL), 2);
    out.fractions = {c.ice * cold * (1 + 5 * fracture + 4 * n.geology->ice + 3 * g.majorIce),
                     c.metal * (.5 + 4 * vein + 3 * impact + fabric),
                     c.silicate * (.7 + 2 * sediment + .8 * fracture),
                     c.carbon * (.4 + 4 * sediment + 2 * n.environment.waterActivity) *
                         (1 - smoothstep(650, 1500, n.environment.temperature))};
    const double total = std::accumulate(out.fractions.begin(), out.fractions.end(), 0.);
    if (total > 0)
        for (auto& f : out.fractions)
            f /= total;
    const auto primary =
        unsigned(std::max_element(out.fractions.begin(), out.fractions.end()) - out.fractions.begin());
    out.type = primary == 0 && cold > .5                                      ? ExposureType::IceFracture
               : (primary == 3 || (out.fractions[3] > .12 && sediment > .15)) ? ExposureType::CarbonSeam
               : impact > .28                                                 ? ExposureType::Ejecta
               : vein > .32                                                   ? ExposureType::Vein
                                                                              : ExposureType::Layered;
    out.concentration = std::clamp(.25 + vein * .25 + impact * .3 + sediment * .3 + fabric * .15, .15, 1.);
    out.exposure =
        std::clamp(.12 + fracture * .22 + impact * .6 + g.volcanism * .35 + sediment * .18, 0., .75);
    constexpr std::array<glm::vec3, 4> colors{glm::vec3(.30, .78, .91), glm::vec3(.79, .38, .19),
                                              glm::vec3(.62, .51, .74), glm::vec3(.12, .16, .23)};
    for (unsigned k = 0; k < 4; ++k)
        out.color += colors[k] * float(out.fractions[k]);
    return out;
}

glm::vec3 exposureColor(const Node& n, glm::dvec3 direction, const GeologySample& field, glm::vec3 base) {
    const double log = n.address.kind() == Kind::Planet ? n.frame.logRadius : n.planetLogRadius;
    if (!hasSolidSurface(n))
        return base;
    const double height = field.heightMetres / std::pow(10., log);
    const double exposedGround = n.geology->liquidWater > .1 ? smoothstep(-.0008, -.0005, height) : 1.;
    if (exposedGround == 0)
        return base;
    const auto province = surfaceProvince(*n.geology, direction, field);
    const auto rock = provinceAlbedo(province, base);
    const auto exposure = resourceExposure(n, direction, field);
    return glm::mix(base, glm::mix(rock, exposure.color, float(exposure.exposure * .55)),
                    float(exposedGround));
}

glm::vec3 cockpitTerrainAlbedo(const Node& n, const GeologySample& field) {
    if (!hasSolidSurface(n))
        throw std::invalid_argument("Terrain albedo requires a solid surface");
    double log = n.address.kind() == Kind::Planet ? n.frame.logRadius : n.planetLogRadius;
    double h = field.heightMetres / std::pow(10.0, log);
    glm::vec3 color;
    if (n.geology->type == GeologyType::IceShell)
        color = glm::mix(glm::vec3(.21, .31, .38), glm::vec3(.75, .84, .88),
                         static_cast<float>(smoothstep(-.001, .002, h)));
    else if (n.geology->liquidWater > .1 && h < -.0008)
        color = {.025f, .18f, .28f};
    else
        color = glm::mix(glm::vec3(.18, .22, .15), glm::vec3(.58, .47, .31),
                         static_cast<float>(smoothstep(-.001, .003, h)));
    color = glm::mix(color, glm::vec3(.11, .10, .095),
                     static_cast<float>(std::clamp(field.volcanism * .7, 0.0, .8)));
    if (n.geology->liquidWater > .1 && h > .003)
        color = glm::mix(color, glm::vec3(.85, .88, .85), static_cast<float>(smoothstep(.003, .006, h)));
    if (field.majorIce > 0)
        color = glm::mix(color,glm::vec3(.66,.86,.94),float(field.majorIce*.72));
    return color;
}

} // namespace infinity
