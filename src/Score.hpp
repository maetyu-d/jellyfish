#pragma once

#include "Sea.hpp"
#include "Spectrum.hpp"
#include "sc_app_engine.h"
#include <memory>

namespace pelagic {

struct BubbleChime;

class Score {
public:
    static constexpr unsigned sampleRate = 48000;

    void start(const char* runtime, const char* definitions);
    void stop();
    void render(float* left, float* right, unsigned frames);
    void update(unsigned palette, Water water, float charge, float basin, float passage = 0.f);
    void pulse(bool held);
    void resonateBell(unsigned contraction);
    void play(VoyageCue cue);
    void echo(const Reply& reply, Vec listener, Vec right, Vec forward);
    void chime(const BubbleChime&, Vec listener, Vec right, Vec forward, float mixLevel);
    void mute(bool muted);
    std::uint64_t spectrum() const { return analysis.snapshot(); }
private:
    static constexpr unsigned maximumFrames = 4096;
    std::unique_ptr<scae_engine,decltype(&scae_destroy)> engine{nullptr,scae_destroy};
    Spectrum analysis;
    std::array<float,2*maximumFrames> interleaved{};
    std::int32_t bed{-1};
    unsigned palette{};
    float waterLevel{.22f}, charge{}, basin{}, passage{};
};

} // namespace pelagic
