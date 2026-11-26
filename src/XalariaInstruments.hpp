#pragma once

#include "ShipFlight.hpp"

namespace pelagic {

struct InstrumentVertex {
    float x, y, z, u, v;
    std::uint32_t colour;
};

struct XalariaInstruments {
    std::vector<InstrumentVertex> screens, overlay;
};

XalariaInstruments xalariaInstruments(const ShipFlight& pilot, const FlightScene& scene,
                                      const Ocean& ocean, float hudOpacity);
std::vector<std::uint8_t> xalariaFontPixels();

} // namespace pelagic
