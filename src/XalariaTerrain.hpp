#pragma once

#include "Sea.hpp"

#include <array>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <string_view>
#include <vector>

namespace pelagic {

inline constexpr unsigned terrainFaceSize = 65;
inline constexpr unsigned terrainFaceCount = 6;

struct TerrainStyle {
    Quad bedrock, sediment; // Reflectance and material roughness.
    Quad process; // Maximum protrusion, sediment cover, water activity and pressure in bar.
    Quad traits;  // Native pigment phase, ice identity, geology activity and metallicity.
    Quad low, high; // Native planet-trait colours, with mineral roughness and radius in metres.
    Quad fabric; // Native geological fabric direction and layer spacing in metres.
};

struct XalariaTerrainGlobe {
    TerrainStyle style;
    std::vector<Quad> texels; // Six native cube faces, each with x varying fastest.
};

struct XalariaTerrainPatch {
    Quad coordinates; // Face index, cube u/v centre and half width.
    std::vector<Quad> texels;
};

struct XalariaTerrainMeshVertex {
    std::array<double,3> position; // Native planet-relative position in radii.
    Quad colour; // Quantised, unlit native exposure reflectance and alpha.
    Quad normal; // Native octahedral-quantised normal and true elevation in radii.
};

struct XalariaTerrainMesh {
    TerrainStyle style;
    double radiusMetres{};
    std::vector<XalariaTerrainMeshVertex> vertices;
    std::vector<std::uint32_t> indices;
    std::vector<std::array<double,3>> morphFrom; // Prior stitched surface, in vertex order.
};

class XalariaTerrain {
public:
    explicit XalariaTerrain(const std::filesystem::path& source);
    ~XalariaTerrain();

    // Return the cached globe or start generating it off the render thread.
    std::shared_ptr<const XalariaTerrainGlobe> globe(unsigned system, std::string_view name);
    std::shared_ptr<const XalariaTerrainPatch> patch(unsigned system, std::string_view name,
                                                     Vec eyeDirection, float eyeRangeInRadii);
    // The eye is planet-relative in metres. A finished cut remains available
    // for the same world while a replacement streams in.
    std::shared_ptr<const XalariaTerrainMesh> tiles(unsigned system, std::string_view name,
                                                    std::array<double,3> planetEyeMetres, unsigned pixels);
    float surfaceHeight(unsigned system, std::string_view name, Vec radial) const;

private:
    struct State;
    std::unique_ptr<State> state_;
};

} // namespace pelagic
