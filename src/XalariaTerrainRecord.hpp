#pragma once

#include <array>
#include <cstdint>
#include <istream>
#include <ostream>
#include <string>

namespace pelagic {

inline constexpr std::array terrainCatalogueHeader{'X', 'A', 'L', 'T', 'E', 'R', 'R', '1'};

struct TerrainRecord {
    std::uint32_t system{};
    std::string name;
    std::uint64_t seed{};
    std::uint8_t mineral{};
    double logRadius{}, temperature{}, peakTemperature{}, age{}, waterActivity{}, pressureBar{};
    std::array<double,4> chemistry{};
    std::array<float,3> low{}, high{};
};

inline void writeTerrainRecord(std::ostream& stream, const TerrainRecord& record) {
    const auto write = [&stream](const auto& value) {
        stream.write(reinterpret_cast<const char*>(&value),sizeof(value));
    };
    const auto length = std::uint16_t(record.name.size());
    write(record.system);
    write(length);
    stream.write(record.name.data(),length);
    write(record.seed);
    write(record.mineral);
    write(record.logRadius);
    write(record.temperature);
    write(record.peakTemperature);
    write(record.age);
    write(record.waterActivity);
    write(record.pressureBar);
    write(record.chemistry);
    write(record.low);
    write(record.high);
}

inline bool readTerrainRecord(std::istream& stream, TerrainRecord& record) {
    const auto read = [&stream](auto& value) {
        return bool(stream.read(reinterpret_cast<char*>(&value),sizeof(value)));
    };
    std::uint16_t length{};
    if (!read(record.system) || !read(length) || length == 0 || length > 1024) return false;
    record.name.resize(length);
    return bool(stream.read(record.name.data(),length)) &&
           read(record.seed) && read(record.mineral) &&
           read(record.logRadius) && read(record.temperature) && read(record.peakTemperature) &&
           read(record.age) && read(record.waterActivity) && read(record.pressureBar) &&
           read(record.chemistry) && read(record.low) && read(record.high);
}

} // namespace pelagic
