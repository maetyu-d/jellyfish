// Build against the Xalaria–Infinity 0.68.0 universe generator.
#include "../src/XalariaTerrainRecord.hpp"
#include "infinity/Planetology.hpp"
#include "infinity/SurfaceLife.hpp"
#include "infinity/Xalaria.hpp"

#include <fstream>
#include <iostream>
#include <memory>

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "Usage: export-xalaria-terrain catalog.tsv xalaria-terrain.bin\n";
        return 2;
    }
    auto catalogue = std::make_shared<infinity::XalariaCatalog>(argv[1]);
    // XalariaMain.cpp's world key. The generic Infinity key generates
    // different physical geology at the same catalogue addresses.
    const infinity::Universe universe(0x58414c4152494101ULL,catalogue);
    std::ofstream out(argv[2],std::ios::binary);
    const auto& header=pelagic::terrainCatalogueHeader;
    out.write(header.data(),header.size());
    for (const auto& [system,star] : catalogue->stars) {
        const auto address=catalogue->address(system);
        for (const auto& [id,world] : star.worlds) {
            const auto planet=universe.describe(address.child(infinity::Kind::Planet,id));
            if (!infinity::hasSolidSurface(planet)) continue;
            const auto climate=infinity::planetClimate(planet);
            const auto traits=infinity::planetTraits(planet);
            const auto& env=planet.environment;
            if (world.name.empty() || world.name.size()>1024) return 1;
            pelagic::writeTerrainRecord(out,{
                system,world.name,planet.geology->seed,std::uint8_t(env.mineral),
                planet.frame.logRadius,env.temperature,env.peakTemperature,env.ageGyr,env.waterActivity,
                climate.pressureBar,{env.chemistry.silicate,env.chemistry.metal,env.chemistry.carbon,env.chemistry.ice},
                {traits.low.r,traits.low.g,traits.low.b},{traits.high.r,traits.high.g,traits.high.b}
            });
        }
    }
    return out ? 0 : 1;
}
