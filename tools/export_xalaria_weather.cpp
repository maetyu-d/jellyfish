// Build with the Xalaria–Infinity catalogue and generation code.
#include "infinity/SurfaceLife.hpp"
#include "infinity/Xalaria.hpp"

#include <fstream>
#include <iomanip>
#include <iostream>
#include <limits>
#include <memory>
#include <set>

int main(int argc, char** argv) {
    if (argc != 3) {
        std::cerr << "Usage: export-xalaria-weather catalog.tsv xalaria-weather.tsv\n";
        return 2;
    }
    auto catalogue = std::make_shared<infinity::XalariaCatalog>(argv[1]);
    const infinity::Universe universe(0x58414c4152494101ULL, catalogue); // XalariaMain.cpp
    std::ofstream out(argv[2]);
    out << "XALARIA_WEATHER\t1\n" << std::setprecision(std::numeric_limits<double>::max_digits10);
    for (const auto& [system, star] : catalogue->stars) {
        const auto address = catalogue->address(system);
        std::set<std::string> names;
        for (const auto& [id, world] : star.worlds) {
            const auto node = universe.describe(address.child(infinity::Kind::Planet, id));
            const auto c = infinity::planetClimate(node);
            if (!c.solid) continue;
            if (!names.insert(world.name).second) {
                std::cerr << "Repeated world name in system " << system << ": " << world.name << '\n';
                return 1;
            }
            const auto phaseKey=node.planetSeed ? node.planetSeed : node.seed;
            out << system << '\t' << std::quoted(world.name) << '\t' << c.seed << '\t' << phaseKey << '\t'
                << c.radiusMetres << '\t' << c.temperatureK << '\t' << c.pressureBar << '\t'
                << c.gravity << '\t' << c.moisture << '\t' << c.daySeconds << '\t'
                << c.scaleHeightMetres << '\t' << c.windMetresPerSecond << '\t'
                << c.axis.x << '\t' << c.axis.y << '\t' << c.axis.z << '\n';
        }
    }
    return out ? 0 : 1;
}
