#pragma once

#include "Sea.hpp"

#include <Accelerate/Accelerate.h>
#include <array>
#include <atomic>

namespace pelagic {

// Single audio-thread writer. The renderer sees only four bounded features
// and a sequence number, published together in one atomic word.
class Spectrum {
public:
    Spectrum();
    ~Spectrum();
    void reset(double sampleRate);
    void push(const float* left, const float* right, unsigned frames, unsigned stride = 1);
    std::uint64_t snapshot() const { return latest.load(std::memory_order_relaxed); }
    static Quad features(std::uint64_t snapshot);
private:
    static constexpr unsigned logSize = 11, size = 1u << logSize, hop = size / 2;
    void analyse();

    FFTSetup fft{};
    std::array<std::array<float,size>,2> history{}, real{};
    std::array<float,size> window{}, imaginary{};
    std::array<float,size/2> power{}, previous{};
    std::atomic<std::uint64_t> latest{};
    unsigned cursor{}, remaining{size}, sequence{};
    float rate{48000.f}, reference{}, averageFlux{}, refractory{}, strike{};
};

} // namespace pelagic
