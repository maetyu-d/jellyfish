#include "Spectrum.hpp"

#include <algorithm>
#include <cmath>
#include <numbers>

namespace pelagic {

Spectrum::Spectrum() : fft(vDSP_create_fftsetup(logSize, kFFTRadix2)) {
    for (unsigned i = 0; i < size; ++i)
        window[i] = .5f - .5f * std::cos(2.f * std::numbers::pi_v<float> * i / (size-1));
    if (fft) {
        DSPSplitComplex warmup{real[0].data(), imaginary.data()};
        vDSP_fft_zip(fft,&warmup,1,logSize,FFT_FORWARD);
    }
}

Spectrum::~Spectrum() {
    if (fft) vDSP_destroy_fftsetup(fft);
}

void Spectrum::reset(double sampleRate) {
    history = {};
    previous.fill(0.f);
    cursor = 0;
    remaining = size;
    rate = float(sampleRate);
    reference = averageFlux = refractory = strike = 0.f;
    latest.store(std::uint64_t(++sequence) << 32,std::memory_order_relaxed);
}

void Spectrum::push(const float* left, const float* right, unsigned frames, unsigned stride) {
    if (!fft) return;
    for (unsigned i = 0; i < frames; ++i) {
        history[0][cursor] = left[i*stride];
        history[1][cursor] = right[i*stride];
        cursor = (cursor+1) & (size-1);
        if (--remaining == 0) {
            analyse();
            remaining = hop;
        }
    }
}

void Spectrum::analyse() {
    power.fill(0.f);
    float shortPower = 0.f;
    for (unsigned channel = 0; channel < 2; ++channel) {
        for (unsigned i = 0; i < size; ++i) {
            const float sample = history[channel][(cursor+i) & (size-1)];
            real[channel][i] = sample*window[i];
            if (i >= size-hop) shortPower += sample*sample;
        }
        imaginary.fill(0.f);
        DSPSplitComplex spectrum{real[channel].data(),imaginary.data()};
        vDSP_fft_zip(fft,&spectrum,1,logSize,FFT_FORWARD);
        for (unsigned i = 1; i < size/2; ++i)
            power[i] += real[channel][i]*real[channel][i] + imaginary[i]*imaginary[i];
    }

    const float dt = hop/rate;
    const float rms = std::sqrt(shortPower/(2*hop));
    if (reference < .001f && rms > .001f) reference = rms;
    reference += (rms-reference)*(1.f-std::exp(-dt/(rms > reference ? .32f : 2.1f)));
    const float gate = std::clamp((rms-.00015f)/.0006f,0.f,1.f);

    // Prism Currents' three bands and transient approach, using both channels'
    // power so a wide or out-of-phase mix still animates the water.
    std::array<float,3> bands{};
    float flux = 0.f;
    constexpr float normalise = 8.f/(size*size); // stereo mean and Hann coherent gain
    for (unsigned i = 1; i < size/2; ++i) {
        const float frequency = i*rate/size;
        if (frequency < 30.f || frequency >= 16000.f) continue;
        const float amplitude = std::sqrt(power[i]*normalise);
        bands[frequency < 220.f ? 0 : frequency < 2400.f ? 1 : 2] += amplitude*amplitude;
        flux += std::max(0.f,amplitude-previous[i]);
        previous[i] = amplitude;
    }
    const float change = flux/std::max(.009f,reference*4.f);
    const float threshold = .12f+averageFlux*1.72f;
    refractory -= dt;
    strike *= std::exp(-dt/.18f);
    if (gate > .5f && refractory <= 0.f && change > threshold) {
        strike = std::clamp((change-threshold)/.53f,.20f,1.f);
        refractory = .14f;
    }
    averageFlux += (change-averageFlux)*(1.f-std::exp(-dt/.52f));

    const float level = std::max(.009f,reference);
    constexpr std::array<float,3> weights{1.5f,3.2f,6.1f};
    auto pack = [](float x) { return std::uint64_t(std::clamp(x,0.f,1.f)*255.f+.5f); };
    std::uint64_t state = (std::uint64_t(++sequence) << 32) | (pack(strike*gate) << 24);
    for (unsigned i = 0; i < bands.size(); ++i) {
        const float x = std::sqrt(bands[i]/3.f)*weights[i]/level;
        state |= pack(gate*x/(1.f+x)) << (8*i);
    }
    latest.store(state,std::memory_order_relaxed);
}

Quad Spectrum::features(std::uint64_t snapshot) {
    const auto get = [=](unsigned shift) { return float((snapshot >> shift) & 255u)/255.f; };
    return {get(0),get(8),get(16),get(24)};
}

} // namespace pelagic
