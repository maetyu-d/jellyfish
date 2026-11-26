#include "XalariaTerrain.hpp"
#include "XalariaTerrainRecord.hpp"

#include "infinity/Prospecting.hpp"
#include "infinity/TerrainMaterial.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <deque>
#include <fstream>
#include <map>
#include <mutex>
#include <optional>
#include <set>
#include <stdexcept>
#include <thread>
#include <unordered_map>

namespace infinity {
glm::vec3 cockpitTerrainAlbedo(const Node&, const GeologySample&);
}

namespace pelagic {
namespace {

using TerrainKey = std::pair<unsigned,std::string>;

// Xalaria–Infinity 0.68.0's cube frontier and exact integer shared-vertex keys.
namespace nativeTiles {
struct Tile {
    int face;
    unsigned level;
    std::uint32_t x, y;
};
using infinity::cubeDirection;
constexpr unsigned terrainCells = 8;
Tile terrainNeighbor(Tile, unsigned);

uint64_t encodeTile(Tile t) {
    if (t.face < 0 || t.face > 5 || t.level > 24 || t.x >= (1u << t.level) || t.y >= (1u << t.level))
        throw std::invalid_argument("Tile range");
    return static_cast<uint64_t>(t.face) | (static_cast<uint64_t>(t.level) << 3) |
           (static_cast<uint64_t>(t.x) << 8) | (static_cast<uint64_t>(t.y) << 32);
}
glm::dvec3 tileDirection(Tile t, double u = .5, double v = .5) {
    double n = static_cast<double>(1u << t.level);
    return cubeDirection(t.face, 2 * (t.x + u) / n - 1, 2 * (t.y + v) / n - 1);
}
Tile tileAt(glm::dvec3 p, unsigned level) {
    if (level > 24 || !std::isfinite(glm::length(p)) || glm::length(p) == 0)
        throw std::invalid_argument("Invalid spherical tile lookup");
    const auto a = glm::abs(p);
    int face;
    double u, v;
    if (a.x >= a.y && a.x >= a.z) {
        face = p.x >= 0 ? 0 : 1;
        u = (p.x >= 0 ? -p.z : p.z) / a.x;
        v = p.y / a.x;
    } else if (a.y >= a.z) {
        face = p.y >= 0 ? 2 : 3;
        u = p.x / a.y;
        v = (p.y >= 0 ? -p.z : p.z) / a.y;
    } else {
        face = p.z >= 0 ? 4 : 5;
        u = (p.z >= 0 ? p.x : -p.x) / a.z;
        v = p.y / a.z;
    }
    const auto count = 1u << level;
    auto index = [&](double q) {
        return uint32_t(std::clamp(std::floor((q + 1) * .5 * count), 0., double(count - 1)));
    };
    return {face, level, index(u), index(v)};
}
uint64_t id(Tile t) {
    return encodeTile(t);
}
Tile parent(Tile t) {
    return {t.face, t.level - 1, t.x / 2, t.y / 2};
}
bool contains(Tile p, Tile c) {
    return p.face == c.face && p.level <= c.level && (c.x >> (c.level - p.level)) == p.x &&
           (c.y >> (c.level - p.level)) == p.y;
}
std::array<Tile, 4> children(Tile t) {
    return {{{t.face, t.level + 1, t.x * 2, t.y * 2},
             {t.face, t.level + 1, t.x * 2 + 1, t.y * 2},
             {t.face, t.level + 1, t.x * 2, t.y * 2 + 1},
             {t.face, t.level + 1, t.x * 2 + 1, t.y * 2 + 1}}};
}
std::optional<Tile> covering(const std::map<uint64_t, Tile>& leaves, Tile t) {
    for (;;) {
        if (leaves.contains(id(t)))
            return t;
        if (!t.level)
            return {};
        t = parent(t);
    }
}
void balance(std::map<uint64_t, Tile>& leaves) {
    for (unsigned pass = 0; pass < 1000; ++pass) {
        std::optional<Tile> merge;
        for (const auto& [key, tile] : leaves) {
            for (unsigned e = 0; e < 4; ++e)
                if (auto coarse = covering(leaves, terrainNeighbor(tile, e));
                    coarse && coarse->level + 1 < tile.level) {
                    auto p = tile;
                    while (p.level > coarse->level + 1)
                        p = parent(p);
                    merge = p;
                    break;
                }
            if (merge)
                break;
        }
        if (!merge)
            return;
        std::erase_if(leaves, [&](const auto& entry) { return contains(*merge, entry.second); });
        leaves.emplace(id(*merge), *merge);
    }
    throw std::runtime_error("Terrain frontier could not be balanced");
}
unsigned remap(unsigned index, unsigned stitch) {
    unsigned x = index % 9, y = index / 9;
    if ((stitch & 1) && x == 0 && (y & 1))
        --y;
    if ((stitch & 2) && x == 8 && (y & 1))
        --y;
    if ((stitch & 4) && y == 0 && (x & 1))
        --x;
    if ((stitch & 8) && y == 8 && (x & 1))
        --x;
    return y * 9 + x;
}
Tile terrainNeighbor(Tile t, unsigned edge) {
    const double epsilon = 1e-5;
    double u = .5, v = .5;
    if (edge < 2)
        u = edge ? 1 + epsilon : -epsilon;
    else
        v = edge == 3 ? 1 + epsilon : -epsilon;
    return tileAt(tileDirection(t, u, v), t.level);
}
std::vector<Tile> terrainFrontier(glm::dvec3 eye, double altitude, double pixels, size_t budget = 192) {
    budget = std::clamp(budget, size_t(6), size_t(384));
    const auto direction = glm::length(eye) > 0 ? glm::normalize(eye) : glm::dvec3(0, 1, 0);
    std::array<glm::dvec2, 6> projected;
    std::array<bool, 6> facing;
    for (unsigned face = 0; face < 6; ++face) {
        const unsigned axis = face / 2;
        const double signedComponent = direction[axis] * (face % 2 ? -1. : 1.);
        facing[face] = signedComponent > 1e-15;
        if (!facing[face])
            continue;
        switch (face) {
        case 0:
            projected[face] = {-direction.z / signedComponent, direction.y / signedComponent};
            break;
        case 1:
            projected[face] = {direction.z / signedComponent, direction.y / signedComponent};
            break;
        case 2:
            projected[face] = {direction.x / signedComponent, -direction.z / signedComponent};
            break;
        case 3:
            projected[face] = {direction.x / signedComponent, direction.z / signedComponent};
            break;
        case 4:
            projected[face] = {direction.x / signedComponent, direction.y / signedComponent};
            break;
        default:
            projected[face] = {-direction.x / signedComponent, direction.y / signedComponent};
            break;
        }
    }
    auto error = [&](Tile tile) {
        const double width = std::ldexp(2.5, -int(tile.level));
        double lateral = 1.;
        if (facing[tile.face]) {
            const double span = std::ldexp(2., -int(tile.level));
            const glm::dvec2 lo(-1. + tile.x * span, -1. + tile.y * span);
            const auto uv = glm::clamp(projected[tile.face], lo, lo + span);
            const auto nearest = cubeDirection(tile.face, uv.x, uv.y);
            lateral = glm::length(nearest - direction);
        }
        const double distance = std::max(1e-15, std::hypot(std::abs(altitude), lateral));
        return width * pixels / (terrainCells * distance * 2 * std::tan(.5));
    };
    std::map<uint64_t, Tile> leaves;
    for (int face = 0; face < 6; ++face)
        leaves.emplace(id({face, 0, 0, 0}), Tile{face, 0, 0, 0});
    while (leaves.size() + 3 <= budget) {
        auto best = leaves.end();
        double maximum = 12;
        for (auto it = leaves.begin(); it != leaves.end(); ++it)
            if (it->second.level < 24)
                if (double e = error(it->second); e > maximum) {
                    maximum = e;
                    best = it;
                }
        if (best == leaves.end())
            break;
        auto tile = best->second;
        // Refine coarse neighbours before their finer dependant. Maintaining
        // 2:1 balance while spending the budget avoids discarding the nearest
        // high-detail tiles in a final merge pass.
        for (unsigned depth = 0; depth < 24; ++depth) {
            std::optional<Tile> coarse;
            for (unsigned edge = 0; edge < 4; ++edge)
                if (auto n = covering(leaves, terrainNeighbor(tile, edge)); n && n->level < tile.level) {
                    coarse = n;
                    break;
                }
            if (!coarse)
                break;
            tile = *coarse;
        }
        leaves.erase(id(tile));
        for (auto child : children(tile))
            leaves.emplace(id(child), child);
    }
    balance(leaves);
    std::vector<Tile> out;
    for (const auto& [key, tile] : leaves)
        out.push_back(tile);
    return out;
}
unsigned terrainStitches(Tile tile, const std::map<uint64_t, Tile>& leaves) {
    unsigned mask = 0;
    for (unsigned edge = 0; edge < 4; ++edge)
        if (auto n = covering(leaves, terrainNeighbor(tile, edge)); n && n->level < tile.level)
            mask |= 1u << edge;
    return mask;
}
uint64_t terrainVertexKey(Tile tile, unsigned x, unsigned y) {
    unsigned level = tile.level;
    uint32_t u = tile.x * terrainCells + x, v = tile.y * terrainCells + y;
    uint32_t count = terrainCells << level;
    // Canonical face at seams/corners; all arithmetic is exact dyadic integer math.
    glm::i64vec3 p;
    const int64_t a = int64_t(u) * 2 - count, b = int64_t(v) * 2 - count, n = count;
    switch (tile.face) {
    case 0:
        p = {n, b, -a};
        break;
    case 1:
        p = {-n, b, a};
        break;
    case 2:
        p = {a, n, -b};
        break;
    case 3:
        p = {a, -n, b};
        break;
    case 4:
        p = {a, b, n};
        break;
    default:
        p = {-a, b, -n};
        break;
    }
    int face;
    int64_t s, t;
    if (std::abs(p.x) == n) {
        face = p.x > 0 ? 0 : 1;
        s = p.x > 0 ? -p.z : p.z;
        t = p.y;
    } else if (std::abs(p.y) == n) {
        face = p.y > 0 ? 2 : 3;
        s = p.x;
        t = p.y > 0 ? -p.z : p.z;
    } else {
        face = p.z > 0 ? 4 : 5;
        s = p.z > 0 ? p.x : -p.x;
        t = p.y;
    }
    u = uint32_t((s + n) / 2);
    v = uint32_t((t + n) / 2);
    while (level && !(u & 1) && !(v & 1)) {
        --level;
        u /= 2;
        v /= 2;
    }
    return (uint64_t(level) << 59) | (uint64_t(face) << 56) | (uint64_t(u) << 28) | v;
}
glm::dvec3 terrainVertexDirection(uint64_t key) {
    unsigned level = unsigned(key >> 59), face = unsigned((key >> 56) & 7);
    const auto u = uint32_t((key >> 28) & 0xfffffff), v = uint32_t(key & 0xfffffff);
    const double n = double(terrainCells << level);
    return cubeDirection(int(face), 2 * u / n - 1, 2 * v / n - 1);
}
} // namespace nativeTiles

struct PatchRequest {
    TerrainKey key;
    std::shared_ptr<const XalariaTerrainGlobe> globe;
    Quad coordinates;
};

struct MeshRequest {
    TerrainKey key;
    std::array<double,3> eye;
    unsigned pixels;
};

Quad materialQuad(glm::vec3 rgb, float extra) {
    return {rgb.r,rgb.g,rgb.b,extra};
}

infinity::Node nativePlanet(const TerrainRecord& record) {
    infinity::Node planet;
    planet.address.path.push_back({infinity::Kind::Planet,0});
    planet.seed=planet.planetSeed=record.seed;
    planet.planetLogRadius=planet.frame.logRadius=record.logRadius;
    auto& env=planet.environment;
    env.mineral=static_cast<infinity::Mineral>(record.mineral);
    env.temperature=record.temperature;
    env.ageGyr=record.age;
    env.peakTemperature=record.peakTemperature;
    env.waterActivity=record.waterActivity;
    env.chemistry={record.chemistry[0],record.chemistry[1],record.chemistry[2],record.chemistry[3]};
    planet.geology=infinity::planetProcess(record.seed,record.logRadius,env,true,false);
    return planet;
}

TerrainStyle nativeStyle(const TerrainRecord& record, const infinity::Node& planet) {
    const auto material=infinity::terrainMaterial(planet);
    const float phase=float(record.seed%10000)*.0371f;
    const bool ice=planet.environment.mineral==infinity::Mineral::Ice ||
                   planet.geology->type==infinity::GeologyType::IceShell;
    constexpr float metalByMineral[]{0.f,.75f,0.f,0.f,0.f};
    constexpr float roughByMineral[]{.36f,.42f,.66f,.25f,.80f};
    return {
        materialQuad(material.bedrock,material.rockRoughness),
        materialQuad(material.sediment,material.sedimentRoughness),
        {0.f,material.sedimentCover,float(record.waterActivity),float(record.pressureBar)},
        {phase-std::floor(phase),float(ice),float(planet.geology->activity),metalByMineral[record.mineral]},
        {record.low[0],record.low[1],record.low[2],roughByMineral[record.mineral]},
        {record.high[0],record.high[1],record.high[2],material.radiusMetres},
        materialQuad(material.fabric,material.layerMetres)
    };
}

glm::dvec3 nativeTerrainNormal(const infinity::Node& planet,glm::dvec3 direction,double radius) {
    const auto frame=infinity::tangentFrame(direction);
    const auto& terrain=planet.geology->terrain;
    const double step=terrain.type==infinity::TerrainType::None ? 1.e-5 :
        std::clamp(terrain.wavelengthMetres/radius/512.,1.e-9,1.e-5);
    const auto point=[&](glm::dvec3 d) {
        d=glm::normalize(d);
        const double height=infinity::geologySample(*planet.geology,d).heightMetres;
        return d*(1.+height/radius);
    };
    const auto east=frame*glm::dvec3(step,0.,0.), north=frame*glm::dvec3(0.,0.,step);
    return glm::normalize(glm::cross(point(direction+north)-point(direction-north),
                                     point(direction+east)-point(direction-east)));
}

glm::vec3 sampledNativeNormal(glm::dvec3 normal) {
    // Infinity normalizes the stored float normal in double before passing it
    // through its two signed 16-bit octahedral vertex attributes.
    const auto unit=[](glm::vec3 n) {
        const float square=glm::dot(n,n);
        return square>1.e-30f ? n/std::sqrt(square) : glm::vec3(0.f,0.f,1.f);
    };
    const auto signNZ=[](float x) { return x<0.f ? -1.f : 1.f; };
    auto n=unit(glm::vec3(glm::normalize(glm::dvec3(glm::vec3(normal)))));
    n/=std::abs(n.x)+std::abs(n.y)+std::abs(n.z);
    glm::vec2 oct(n);
    if (n.z<0.f)
        oct={(1.f-std::abs(n.y))*signNZ(n.x),(1.f-std::abs(n.x))*signNZ(n.y)};
    const glm::vec2 packed(std::round(oct.x*32767.f)/32767.f,std::round(oct.y*32767.f)/32767.f);
    n={packed.x,packed.y,1.f-std::abs(packed.x)-std::abs(packed.y)};
    if (n.z<0.f) {
        n.x=(1.f-std::abs(packed.y))*signNZ(packed.x);
        n.y=(1.f-std::abs(packed.x))*signNZ(packed.y);
    }
    return unit(n);
}

struct MeshBuilder {
    TerrainKey key;
    std::vector<nativeTiles::Tile> tiles;
    std::vector<unsigned> stitches;
    std::unordered_map<std::uint64_t,XalariaTerrainMeshVertex> samples;
    std::optional<infinity::Node> planet;
    std::shared_ptr<const XalariaTerrainMesh> ready;

    std::array<double,3> oldPosition(std::uint64_t key) const {
        const unsigned level=unsigned(key>>59),face=unsigned((key>>56)&7);
        const double scale=double(nativeTiles::terrainCells<<level);
        const double u=double((key>>28)&0xfffffff)/scale,v=double(key&0xfffffff)/scale;
        constexpr unsigned cells=nativeTiles::terrainCells,indicesPerTile=cells*cells*6;
        for (std::size_t i=0;i<tiles.size();++i) {
            const auto tile=tiles[i];
            if (tile.face!=int(face)) continue;
            const double size=double(1u<<tile.level);
            const double gx=(u*size-tile.x)*cells,gy=(v*size-tile.y)*cells;
            if (gx< -1.e-8 || gy< -1.e-8 || gx>cells+1.e-8 || gy>cells+1.e-8) continue;
            const int cx=std::clamp(int(std::floor(gx)),0,int(cells)-1);
            const int cy=std::clamp(int(std::floor(gy)),0,int(cells)-1);
            // The old triangle UVs are the same stitched integer indices
            // used to draw the mesh. Convert barycentric weights from cube
            // space back to the old triangle's linear planet coordinates.
            const unsigned mask=stitches[i];
            for (int y=std::max(0,cy-1);y<=std::min(int(cells)-1,cy+1);++y)
                for (int x=std::max(0,cx-1);x<=std::min(int(cells)-1,cx+1);++x)
                    for (unsigned triangle=0;triangle<2;++triangle) {
                        const unsigned a=y*(cells+1)+x,b=a+cells+1;
                        const std::array indices{a,a+1,b,a+1,b+1,b};
                        std::array<glm::dvec2,3> uv;
                        for (unsigned k=0;k<3;++k) {
                            const unsigned vertex=nativeTiles::remap(indices[triangle*3+k],mask);
                            uv[k]={vertex%(cells+1),vertex/(cells+1)};
                        }
                        const auto e=uv[1]-uv[0],f=uv[2]-uv[0],p=glm::dvec2(gx,gy)-uv[0];
                        const double determinant=e.x*f.y-e.y*f.x;
                        if (std::abs(determinant)<1.e-12) continue;
                        const double w1=(p.x*f.y-p.y*f.x)/determinant;
                        const double w2=(e.x*p.y-e.y*p.x)/determinant;
                        if (w1< -1.e-8 || w2< -1.e-8 || w1+w2>1.+1.e-8) continue;
                        const glm::dvec3 weights(1.-w1-w2,w1,w2);
                        glm::dvec3 out{};
                        double sum=0.;
                        const std::size_t at=i*indicesPerTile+(y*cells+x)*6+triangle*3;
                        for (unsigned k=0;k<3;++k) {
                            const auto& position=ready->vertices[ready->indices[at+k]].position;
                            const double weight=weights[k]/std::abs(position[face/2]);
                            out+=glm::dvec3(position[0],position[1],position[2])*weight;
                            sum+=weight;
                        }
                        out/=sum;
                        return {out.x,out.y,out.z};
                    }
        }
        throw std::runtime_error("Xalaria terrain morph has a coverage hole.");
    }

    std::shared_ptr<const XalariaTerrainMesh> build(const TerrainRecord& record,
                                                   const MeshRequest& request,std::stop_token stop) {
        if (key!=request.key) {
            key=request.key;
            tiles.clear();
            stitches.clear();
            samples.clear();
            planet=nativePlanet(record);
            ready.reset();
        }
        const double radius=std::pow(10.,planet->frame.logRadius);
        const glm::dvec3 eye=glm::dvec3(request.eye[0],request.eye[1],request.eye[2])/radius;
        const double range=glm::length(eye);
        const auto direction=range>0. ? eye/range : glm::dvec3(0.,1.,0.);
        const double altitude=range-1.-infinity::geologySample(*planet->geology,direction).heightMetres/radius;
        const auto cut=nativeTiles::terrainFrontier(eye,altitude,request.pixels);
        std::map<std::uint64_t,nativeTiles::Tile> leaves;
        for (const auto& tile : cut) leaves.emplace(nativeTiles::id(tile),tile);
        if (ready && cut.size()==tiles.size() &&
            std::equal(cut.begin(),cut.end(),tiles.begin(),[](auto a,auto b) { return nativeTiles::id(a)==nativeTiles::id(b); }))
            return ready;

        auto result=std::make_shared<XalariaTerrainMesh>();
        result->style=nativeStyle(record,*planet);
        result->radiusMetres=radius;
        constexpr unsigned cells=nativeTiles::terrainCells, verticesPerTile=(cells+1)*(cells+1);
        result->vertices.reserve(cut.size()*verticesPerTile);
        result->indices.reserve(cut.size()*cells*cells*6);
        if (ready) result->morphFrom.reserve(cut.size()*verticesPerTile);
        std::unordered_map<std::uint64_t,std::uint32_t> vertexIndices;
        vertexIndices.reserve(cut.size()*verticesPerTile);
        std::vector<unsigned> nextStitches;
        nextStitches.reserve(cut.size());
        for (auto tile : cut) {
            if (stop.stop_requested()) return {};
            std::array<std::uint32_t,verticesPerTile> indices;
            for (unsigned y=0;y<=cells;++y) {
                for (unsigned x=0;x<=cells;++x) {
                    const auto vertexKey=nativeTiles::terrainVertexKey(tile,x,y);
                    const auto [index,insertion]=vertexIndices.try_emplace(vertexKey,std::uint32_t(result->vertices.size()));
                    indices[y*(cells+1)+x]=index->second;
                    if (!insertion) continue;
                    const auto [sample,generate]=samples.try_emplace(vertexKey);
                    if (generate) {
                        const auto radial=nativeTiles::terrainVertexDirection(vertexKey);
                        const auto geology=infinity::geologySample(*planet->geology,radial);
                        const double elevation=geology.heightMetres/radius;
                        const auto position=radial*(1.+elevation);
                        const auto normal=sampledNativeNormal(nativeTerrainNormal(*planet,radial,radius));
                        const auto base=infinity::cockpitTerrainAlbedo(*planet,geology);
                        const auto exposed=infinity::exposureColor(*planet,radial,geology,base);
                        const auto unlit=glm::floor(glm::clamp(exposed,0.f,1.f)*255.f+.5f)/255.f;
                        sample->second={{position.x,position.y,position.z},materialQuad(unlit,1.f),
                                        materialQuad(normal,float(elevation))};
                    }
                    result->vertices.push_back(sample->second);
                    if (ready) result->morphFrom.push_back(oldPosition(vertexKey));
                    result->style.process.x=std::max(result->style.process.x,std::abs(sample->second.normal.w));
                }
            }
            const unsigned stitch=nativeTiles::terrainStitches(tile,leaves);
            nextStitches.push_back(stitch);
            for (unsigned y=0;y<cells;++y) {
                for (unsigned x=0;x<cells;++x) {
                    const unsigned a=y*(cells+1)+x,b=a+cells+1;
                    for (auto index : {a,a+1,b,a+1,b+1,b})
                        result->indices.push_back(indices[nativeTiles::remap(index,stitch)]);
                }
            }
        }
        constexpr std::size_t cachedVertices=4*192*verticesPerTile;
        if (samples.size()>cachedVertices)
            std::erase_if(samples,[&](const auto& sample) { return !vertexIndices.contains(sample.first); });
        tiles=cut;
        stitches=std::move(nextStitches);
        ready=result;
        return result;
    }
};

glm::dvec2 faceUv(glm::dvec3 d,unsigned face) {
    switch (face) {
    case 0: return glm::dvec2(-d.z,d.y)/d.x;
    case 1: return glm::dvec2(d.z,d.y)/-d.x;
    case 2: return glm::dvec2(d.x,-d.z)/d.y;
    case 3: return glm::dvec2(d.x,d.z)/-d.y;
    case 4: return glm::dvec2(d.x,d.y)/d.z;
    default: return glm::dvec2(-d.x,d.y)/-d.z;
    }
}

unsigned cubeFace(glm::dvec3 d) {
    const auto a=glm::abs(d);
    if (a.x>=a.y && a.x>=a.z) return d.x>=0. ? 0 : 1;
    if (a.y>=a.z) return d.y>=0. ? 2 : 3;
    return d.z>=0. ? 4 : 5;
}

Quad coarseSample(const XalariaTerrainGlobe& globe,glm::dvec3 direction) {
    constexpr auto limit=double(terrainFaceSize-1);
    const unsigned face=cubeFace(direction);
    const auto point=(faceUv(direction,face)*.5+.5)*limit;
    const auto origin=glm::uvec2(glm::clamp(glm::floor(point),0.,limit-1.));
    const auto offset=point-glm::dvec2(origin);
    const bool upper=offset.x+offset.y>1.;
    const unsigned a=upper ? 1 : 0;
    const auto texels=[&](unsigned x,unsigned y) {
        return globe.texels[(face*terrainFaceSize+origin.y+y)*terrainFaceSize+origin.x+x];
    };
    const auto vertex=[&](unsigned x,unsigned y,float h) {
        const auto uv=2.*glm::dvec2(origin+glm::uvec2(x,y))/limit-1.;
        return infinity::cubeDirection(int(face),uv.x,uv.y)*(1.+double(h));
    };
    const auto qa=texels(a,0), qb=texels(a,1), qc=texels(1-a,a);
    const auto va=vertex(a,0,qa.w), vb=vertex(a,1,qb.w), vc=vertex(1-a,a,qc.w);
    const auto e=vb-va, f=vc-va, n=glm::cross(e,f);
    const double radius=glm::dot(n,va)/glm::dot(n,direction);
    const auto p=direction*radius-va;
    const double ee=glm::dot(e,e), ef=glm::dot(e,f), ff=glm::dot(f,f);
    const double ep=glm::dot(e,p), fp=glm::dot(f,p), det=ee*ff-ef*ef;
    const float wa=float((ff*ep-ef*fp)/det), wb=float((ee*fp-ef*ep)/det);
    const auto blend=[&](float x,float y,float z) { return x+(y-x)*wa+(z-x)*wb; };
    return {blend(qa.x,qb.x,qc.x),blend(qa.y,qb.y,qc.y),blend(qa.z,qb.z,qc.z),float(radius-1.)};
}

bool buildFace(std::vector<Quad>& texels,const infinity::Node& planet,int face,glm::dvec2 centre,
               double extent,std::stop_token stop,const XalariaTerrainGlobe* coarse=nullptr) {
    struct Sample {
        glm::dvec3 point;
        glm::vec3 colour;
        double elevation;
    };
    constexpr unsigned padded=terrainFaceSize+2;
    std::vector<Sample> samples(padded*padded);
    const glm::dvec3 authorLight=glm::normalize(glm::dvec3(-.5,.8,1.));
    const double inverseRadius=std::pow(10.,-planet.planetLogRadius);
    const auto coord=[&](unsigned i) { return extent*(2.*(double(i)-1.)/(terrainFaceSize-1)-1.); };
    for (unsigned y=0;y<padded;++y) {
        if (stop.stop_requested()) return false;
        for (unsigned x=0;x<padded;++x) {
            const auto direction=infinity::cubeDirection(face,centre.x+coord(x),centre.y+coord(y));
            const auto field=infinity::geologySample(*planet.geology,direction);
            const auto base=infinity::cockpitTerrainAlbedo(planet,field);
            const double height=field.heightMetres*inverseRadius;
            samples[y*padded+x]={direction*(1.+height),infinity::exposureColor(planet,direction,field,base),height};
        }
    }
    for (unsigned y=1;y<=terrainFaceSize;++y) {
        for (unsigned x=1;x<=terrainFaceSize;++x) {
            const auto& sample=samples[y*padded+x];
            auto normal=glm::cross(samples[(y+1)*padded+x].point-samples[(y-1)*padded+x].point,
                                   samples[y*padded+x+1].point-samples[y*padded+x-1].point);
            if (glm::dot(normal,sample.point)<0.) normal=-normal;
            const float light=float(.19+.81*std::max(0.,glm::dot(glm::normalize(normal),authorLight)));
            glm::vec3 colour=glm::floor(glm::clamp(sample.colour*light,0.f,1.f)*255.f+.5f)/255.f;
            float elevation=float(sample.elevation);
            if (coarse) {
                const double edge=std::max(std::abs(coord(x)),std::abs(coord(y)))/extent;
                const float weight=float(infinity::smoothstep(.70,1.,edge));
                if (weight>0.f) {
                    const auto base=coarseSample(*coarse,glm::normalize(sample.point));
                    colour=glm::mix(colour,glm::vec3(base.x,base.y,base.z),weight);
                    elevation=std::lerp(elevation,base.w,weight);
                }
            }
            texels.push_back(materialQuad(colour,elevation));
        }
    }
    return true;
}

std::shared_ptr<const XalariaTerrainGlobe> buildGlobe(const TerrainRecord& record, std::stop_token stop) {
    const auto planet=nativePlanet(record);
    auto globe=std::make_shared<XalariaTerrainGlobe>();
    globe->style=nativeStyle(record,planet);
    globe->texels.reserve(terrainFaceCount*terrainFaceSize*terrainFaceSize);
    for (unsigned face=0;face<terrainFaceCount;++face)
        if (!buildFace(globe->texels,planet,int(face),glm::dvec2(0.),1.,stop)) return {};
    for (const auto& texel : globe->texels)
        globe->style.process.x=std::max(globe->style.process.x,std::abs(texel.w));
    globe->style.process.x+=.002f;
    return globe;
}

bool sameCoordinates(const Quad& a,const Quad& b) {
    return a.x==b.x && a.y==b.y && a.z==b.z && a.w==b.w;
}

std::shared_ptr<const XalariaTerrainPatch> buildPatch(const TerrainRecord& record,const PatchRequest& request,
                                                      std::stop_token stop) {
    const auto planet=nativePlanet(record);
    const Quad c=request.coordinates;
    auto patch=std::make_shared<XalariaTerrainPatch>();
    patch->coordinates=c;
    patch->texels.reserve(terrainFaceSize*terrainFaceSize);
    if (!buildFace(patch->texels,planet,int(c.x),{c.y,c.z},c.w,stop,request.globe.get())) return {};
    return patch;
}

} // namespace

struct XalariaTerrain::State {
    std::map<TerrainKey,TerrainRecord> catalogue;
    std::map<TerrainKey,std::shared_ptr<const XalariaTerrainGlobe>> cache;
    std::deque<TerrainKey> requests, recent;
    std::set<TerrainKey> pending;
    std::optional<PatchRequest> requestedPatch, activePatch;
    TerrainKey patchKey;
    std::shared_ptr<const XalariaTerrainPatch> patch;
    std::optional<MeshRequest> meshRequest, lastMeshRequest;
    std::chrono::steady_clock::time_point meshRequestedAt{};
    std::optional<std::chrono::steady_clock::time_point> meshObservedAt;
    TerrainKey meshKey;
    std::shared_ptr<const XalariaTerrainMesh> mesh;
    std::mutex mutex;
    std::condition_variable_any wake;
    std::jthread worker;

    explicit State(const std::filesystem::path& source) {
        std::ifstream stream(source,std::ios::binary);
        auto header=terrainCatalogueHeader;
        if (!stream.read(header.data(),header.size()) || header!=terrainCatalogueHeader)
            throw std::runtime_error("The Xalaria terrain catalogue could not be opened.");
        while (stream.peek()!=std::char_traits<char>::eof()) {
            TerrainRecord record;
            if (!readTerrainRecord(stream,record) || record.mineral>4)
                throw std::runtime_error("Invalid Xalaria terrain record.");
            TerrainKey key{record.system,record.name};
            if (!catalogue.emplace(std::move(key),std::move(record)).second)
                throw std::runtime_error("Duplicate Xalaria terrain record.");
        }
        worker=std::jthread([this](std::stop_token stop) { generate(stop); });
    }

    void generate(std::stop_token stop) {
        MeshBuilder meshes;
        std::unique_lock lock(mutex);
        while (wake.wait(lock,stop,[this] { return meshRequest || requestedPatch || !requests.empty(); }) &&
               !stop.stop_requested()) {
            if (meshRequest) {
                auto request=std::move(*meshRequest);
                meshRequest.reset();
                const auto& record=catalogue.at(request.key);
                lock.unlock();
                auto result=meshes.build(record,request,stop);
                lock.lock();
                if (result && result!=mesh) {
                    meshKey=request.key;
                    mesh=std::move(result);
                    meshObservedAt.reset();
                    // A quickly moving camera can submit more than one cut
                    // while the previous one is building. Reconsider only
                    // the newest view after this transition has been shown.
                    if (meshRequest && meshRequest->key==meshKey && !mesh->morphFrom.empty()) {
                        meshRequest.reset();
                        lastMeshRequest=std::move(request);
                    }
                }
                continue;
            }
            if (requestedPatch) {
                activePatch=std::move(requestedPatch);
                requestedPatch.reset();
                const auto& record=catalogue.at(activePatch->key);
                lock.unlock();
                auto result=buildPatch(record,*activePatch,stop);
                lock.lock();
                if (result) {
                    patchKey=activePatch->key;
                    patch=std::move(result);
                }
                activePatch.reset();
                continue;
            }
            auto key=std::move(requests.front());
            requests.pop_front();
            const auto& record=catalogue.at(key);
            lock.unlock();
            auto result=buildGlobe(record,stop);
            lock.lock();
            pending.erase(key);
            if (!result) continue;
            cache.emplace(key,std::move(result));
            recent.push_back(std::move(key));
            constexpr std::size_t cacheGlobeLimit=20;
            if (recent.size()>cacheGlobeLimit) {
                cache.erase(recent.front());
                recent.pop_front();
            }
        }
    }
};

XalariaTerrain::XalariaTerrain(const std::filesystem::path& source) : state_(std::make_unique<State>(source)) {}
XalariaTerrain::~XalariaTerrain() = default;

float XalariaTerrain::surfaceHeight(unsigned system,std::string_view name,Vec radial) const {
    const auto found=state_->catalogue.find(TerrainKey{system,std::string(name)});
    if (found==state_->catalogue.end()) return 0.f;
    const glm::dvec3 direction{radial.x,radial.y,radial.z};
    if (glm::dot(direction,direction)<1.e-20) return 0.f;
    const auto& record=found->second;
    const auto planet=nativePlanet(record);
    return float(infinity::geologySample(*planet.geology,direction).heightMetres*std::pow(10.,-record.logRadius));
}

std::shared_ptr<const XalariaTerrainGlobe> XalariaTerrain::globe(unsigned system,std::string_view name) {
    auto& state=*state_;
    TerrainKey key{system,std::string(name)};
    std::lock_guard lock(state.mutex);
    if (auto found=state.cache.find(key); found!=state.cache.end()) return found->second;
    if (!state.catalogue.contains(key) || !state.pending.emplace(key).second) return {};
    state.requests.push_back(std::move(key));
    state.wake.notify_one();
    return {};
}

std::shared_ptr<const XalariaTerrainMesh> XalariaTerrain::tiles(unsigned system,std::string_view name,
                                                               std::array<double,3> planetEyeMetres,
                                                               unsigned pixels) {
    if (!pixels || !std::ranges::all_of(planetEyeMetres,[](double value) { return std::isfinite(value); }))
        return {};
    const TerrainKey key{system,std::string(name)};
    auto& state=*state_;
    if (!state.catalogue.contains(key)) return {};

    std::lock_guard lock(state.mutex);
    const auto now=std::chrono::steady_clock::now();
    const auto& last=state.lastMeshRequest;
    const bool newBody=!last || last->key!=key;
    const bool changed=newBody || last->eye!=planetEyeMetres || last->pixels!=pixels;
    const bool ready=state.mesh && state.meshKey==key;
    if (ready && !state.meshObservedAt) state.meshObservedAt=now;
    const bool morphing=ready && !state.mesh->morphFrom.empty() &&
                        now-*state.meshObservedAt<std::chrono::milliseconds(200);
    if (changed && !morphing && (newBody || now-state.meshRequestedAt>=std::chrono::milliseconds(60))) {
        state.meshRequest=MeshRequest{key,planetEyeMetres,pixels};
        state.lastMeshRequest=state.meshRequest;
        state.meshRequestedAt=now;
        state.wake.notify_one();
    }
    return ready ? state.mesh : std::shared_ptr<const XalariaTerrainMesh>{};
}

std::shared_ptr<const XalariaTerrainPatch> XalariaTerrain::patch(unsigned system,std::string_view name,
                                                                Vec eyeDirection,float eyeRangeInRadii) {
    if (eyeRangeInRadii>1.18f) return {};
    const glm::dvec3 worldEye{eyeDirection.x,eyeDirection.y,eyeDirection.z};
    if (glm::dot(worldEye,worldEye)<1.e-20) return {};
    const unsigned face=cubeFace(worldEye);
    const auto projected=faceUv(worldEye,face);
    const float extent=std::exp2(std::ceil(std::log2(std::clamp((eyeRangeInRadii-1.f)*2.5f,
                                                              .00048828125f,.5f))));
    const auto snapped=glm::round(projected/(extent*.25))*double(extent*.25);
    const Quad c{float(face),float(snapped.x),float(snapped.y),extent};
    auto& state=*state_;
    TerrainKey key{system,std::string(name)};
    std::lock_guard lock(state.mutex);
    const auto globe=state.cache.find(key);
    if (globe==state.cache.end()) return {};
    const bool sameBody=state.patch && state.patchKey==key;
    if (sameBody && sameCoordinates(state.patch->coordinates,c)) return state.patch;
    const auto alreadyRequested=[&](const auto& request) {
        return request && request->key==key && sameCoordinates(request->coordinates,c);
    };
    if (!alreadyRequested(state.requestedPatch) && !alreadyRequested(state.activePatch)) {
        state.requestedPatch=PatchRequest{key,globe->second,c};
        state.wake.notify_one();
    }
    if (sameBody) {
        const auto previous=state.patch->coordinates;
        const auto local=faceUv(worldEye,unsigned(previous.x));
        if (face==unsigned(previous.x) &&
            std::max(std::abs(local.x-previous.y),std::abs(local.y-previous.z))<previous.w*.68)
            return state.patch;
    }
    return {};
}

} // namespace pelagic
