#pragma once

#include <array>
#include <cstdint>
#include <filesystem>
#include <memory>
#include <vector>

namespace pelagic {

class ShipFlight;
struct FlightScene;

struct XalariaWeatherField {
    static constexpr unsigned width = 128, height = 64;
    std::vector<std::uint8_t> pixels; // RGBA8, largest mip level first.
};

class XalariaWeather {
public:
    using Fields = std::array<std::shared_ptr<const XalariaWeatherField>,2>;

    explicit XalariaWeather(const std::filesystem::path& catalogue);
    ~XalariaWeather();
    Fields prepare(const ShipFlight& flight,FlightScene& scene,double delta,unsigned width,unsigned height);

private:
    struct State;
    std::unique_ptr<State> state_;
};

} // namespace pelagic
