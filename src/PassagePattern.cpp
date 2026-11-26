#include "PassagePattern.hpp"

#include <algorithm>
#include <random>
#include <sstream>

namespace pelagic {
namespace {
constexpr unsigned minimumRestored=5, maximumRestored=8;
}

unsigned PassagePattern::separators() const {
    const auto runs=std::ranges::count_if(colourRuns,[](unsigned n) { return n>0; });
    return runs ? unsigned(runs-1) : 0u;
}

PassagePatterns generatePassagePatterns(std::uint32_t seed) {
    std::mt19937 random(seed);
    unsigned restored=0;
    PassagePatterns patterns{};
    for (auto& pattern:patterns) {
        restored+=std::uniform_int_distribution<unsigned>(minimumRestored,maximumRestored)(random);
        const unsigned separators=std::uniform_int_distribution<unsigned>(1,3)(random);
        std::array<unsigned,maximumRestored*bellPassageCount-1> gaps{};
        std::iota(gaps.begin(),gaps.end(),1u);
        const auto interior=std::span(gaps).first(restored-1);
        std::ranges::shuffle(interior,random);
        std::ranges::sort(interior.first(separators));
        unsigned previous=0;
        for (unsigned i=0;i<separators;++i) {
            pattern.colourRuns[i]=gaps[i]-previous;
            previous=gaps[i];
        }
        pattern.colourRuns[separators]=restored-previous;
    }
    return patterns;
}

std::string encodePassagePatterns(const PassagePatterns& patterns) {
    std::ostringstream out;
    for (const auto& pattern:patterns) {
        for (unsigned n:pattern.colourRuns) out<<n<<' ';
    }
    return out.str();
}

std::optional<PassagePatterns> decodePassagePatterns(std::string_view encoded) {
    std::istringstream in{std::string(encoded)};
    PassagePatterns patterns{};
    unsigned previous=0;
    for (auto& pattern:patterns) {
        bool trailing=false;
        for (auto& n:pattern.colourRuns) {
            if (!(in>>n) || n>maximumRestored*bellPassageCount || (trailing && n>0)) return {};
            trailing=n==0;
        }
        const unsigned total=pattern.restored();
        if (!pattern.separators() || total<previous+minimumRestored || total>previous+maximumRestored) return {};
        previous=total;
    }
    in>>std::ws;
    if (!in.eof()) return {};
    return patterns;
}

}
