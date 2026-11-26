// Build against the Infinity / Xalaria v0.68.0 generation code. No renderer is needed.
#include "infinity/Planetology.hpp"
#include "infinity/TerrainMaterial.hpp"
#include "infinity/Xalaria.hpp"

#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "Usage: export-xalaria-worlds catalog.tsv world-traits.tsv\n";
        return 2;
    }
    auto catalogue = std::make_shared<infinity::XalariaCatalog>(argv[1]);
    const infinity::Universe universe(0x58414c4152494101ULL,catalogue); // XalariaMain.cpp
    std::ofstream out(argv[2]);
    out << "XALARIA_WORLD_TRAITS\t1\n" << std::setprecision(8);
    for (const auto& [system,star] : catalogue->stars) {
        const auto address=catalogue->address(system);
        for (const auto& [id,world] : star.worlds) {
            // The port displays all five Ziksa moons and up to nine primary planets elsewhere.
            if (world.primary>=0 && system!=14538) continue;
            const auto node=universe.describe(address.child(infinity::Kind::Planet,id));
            const auto traits=infinity::planetTraits(node);
            const auto terrain=infinity::terrainMaterial(node);
            const bool solid=infinity::hasSolidSurface(node);
            const auto lo=solid ? glm::mix(traits.low,terrain.bedrock,.45f) : traits.low;
            const auto hi=solid ? glm::mix(traits.high,terrain.sediment,.50f) : traits.high;
            const float frozen=std::max(terrain.frozen,float(traits.iceCoverage));
            const auto& rings=traits.rings;
            out << system << '\t' << world.uniqueId
                << '\t' << lo.x << '\t' << lo.y << '\t' << lo.z << '\t' << traits.phase
                << '\t' << hi.x << '\t' << hi.y << '\t' << hi.z << '\t' << unsigned(traits.type)+1
                << '\t' << (solid ? unsigned(node.geology->terrain.type) : traits.jetBands)
                << '\t' << (solid ? terrain.sedimentCover : traits.bandContrast)
                << '\t' << (solid ? node.environment.waterActivity : traits.haze)
                << '\t' << (solid ? frozen : rings.iceFraction)
                << '\t' << rings.innerRadius << '\t' << rings.outerRadius
                << '\t' << rings.opticalDepth << '\t' << double(rings.seed%10000)/10000.
                << '\t' << traits.axis.x << '\t' << traits.axis.y << '\t' << traits.axis.z
                << '\t' << (solid ? node.environment.pressureGPa*10000. : 0.) << '\n';
        }
    }
    return out ? 0 : 1;
}
