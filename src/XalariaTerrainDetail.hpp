#pragma once

#include <cstdint>
#include <vector>

namespace pelagic {

inline constexpr unsigned xalariaTerrainDetailSize = 512;
// Native RGBA8 material and all its mips, largest level first.
std::vector<std::uint8_t> bakeXalariaTerrainDetail();

} // namespace pelagic
