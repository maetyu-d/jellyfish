#include "ShipFlight.hpp"

#include <fstream>
#include <stdexcept>
#include <string_view>

namespace pelagic {

XalariaMeshes readXalariaMeshes(const std::filesystem::path& path) {
    std::ifstream file(path,std::ios::binary);
    char magic[8]{};
    if (!file.read(magic,sizeof(magic)) || std::string_view(magic,sizeof(magic)) != "XALMESH1")
        throw std::runtime_error("The Xalaria flight meshes could not be opened.");
    XalariaMeshes meshes;
    for (auto* part : {&meshes.cabin,&meshes.hatch,&meshes.deck,&meshes.yoke,&meshes.throttle,
                       &meshes.glazing,&meshes.ship}) {
        std::uint32_t count{};
        if (!file.read(reinterpret_cast<char*>(&count),sizeof(count)) || count == 0 || count%3 != 0 || count > 300000)
            throw std::runtime_error("Invalid Xalaria flight geometry.");
        part->resize(count);
        const auto bytes = std::streamsize(part->size()*sizeof(CabinVertex));
        if (!file.read(reinterpret_cast<char*>(part->data()),bytes))
            throw std::runtime_error("Incomplete Xalaria flight geometry.");
    }
    return meshes;
}

} // namespace pelagic
