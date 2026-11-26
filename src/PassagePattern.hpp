#pragma once

#include "Sea.hpp"

#include <numeric>
#include <string_view>

namespace pelagic {

// An open chain made of colour runs separated by single monochrome bubbles.
struct PassagePattern {
    std::array<unsigned,4> colourRuns{};
    unsigned restored() const { return std::accumulate(colourRuns.begin(),colourRuns.end(),0u); }
    unsigned separators() const;
    unsigned length() const { return restored()+separators(); }
    bool operator==(const PassagePattern&) const = default;
};

using PassagePatterns = std::array<PassagePattern,bellPassageCount>;
PassagePatterns generatePassagePatterns(std::uint32_t seed);
std::string encodePassagePatterns(const PassagePatterns&);
std::optional<PassagePatterns> decodePassagePatterns(std::string_view);

}
