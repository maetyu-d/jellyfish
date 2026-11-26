// Build against Infinity / Xalaria v0.68.0 and run with the destination mesh bundle path.
#include "infinity/Activity.hpp"
#include "infinity/Cockpit.hpp"
#include "infinity/Geometry.hpp"

#include <algorithm>
#include <cstdint>
#include <fstream>
#include <stdexcept>

namespace {
struct Vertex { float x, y, z; std::uint32_t colour; float nx, ny, nz; };
static_assert(sizeof(Vertex) == 28);

void writeMesh(std::ofstream& out, const infinity::Mesh& mesh, bool exterior = false) {
    const auto count = std::uint32_t(mesh.indexCount());
    out.write(reinterpret_cast<const char*>(&count), sizeof(count));
    for (std::uint32_t i = 0; i < count; i += 3) {
        Vertex vertices[3]{};
        glm::vec3 xyz[3];
        for (unsigned j = 0; j < 3; ++j) {
            const auto v = mesh.vertices[mesh.index(i+j)];
            xyz[j] = exterior ? glm::vec3(-v.x,v.y,-v.z) : glm::vec3(v.x,v.y,v.z);
            auto colour = v.color;
            if (exterior) {
                const float red = float(colour&255u), blue = float((colour>>16)&255u);
                const bool engine = xyz[j].z < -1.25f && blue > red*1.28f && blue > 125.f;
                colour = (colour&0x00ffffffu) | ((engine ? 0x4fu : 0x20u)<<24);
            }
            vertices[j] = {xyz[j].x,xyz[j].y,xyz[j].z,colour,0,0,0};
        }
        const auto area = glm::cross(xyz[1]-xyz[0],xyz[2]-xyz[0]);
        const auto normal = glm::length(area) > 1e-9f ? glm::normalize(area) : glm::vec3(0,1,0);
        for (auto& v : vertices) { v.nx = normal.x; v.ny = normal.y; v.nz = normal.z; }
        out.write(reinterpret_cast<const char*>(vertices),sizeof(vertices));
    }
}
}
int main(int argc, char** argv) {
    if (argc != 2) return 2;
    std::ofstream out(argv[1],std::ios::binary);
    out.write("XALMESH1",8);
    writeMesh(out,infinity::xalariaCockpitMesh());
    writeMesh(out,infinity::xalariaCockpitHatch());
    writeMesh(out,infinity::xalariaShipDeck());
    writeMesh(out,infinity::xalariaCockpitYoke());
    writeMesh(out,infinity::xalariaCockpitThrottle());
    writeMesh(out,infinity::xalariaCockpitGlazing());
    writeMesh(out,infinity::activityMesh(infinity::ActivityKind::Patrol,2),true);
    return out ? 0 : 1;
}
