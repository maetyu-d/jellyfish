#pragma once

#include "PassagePattern.hpp"

#include <limits>
#include <set>
#include <string_view>
#include <utility>

namespace pelagic {

struct BubbleAnchor {
    using Key = std::pair<unsigned,unsigned>;
    static constexpr unsigned shell = bubbleShell;
    unsigned bubble{}, system{shell};
    Vec direction; // Material-space direction on the membrane.

    Key key() const { return {bubble,system}; }
    bool sameBubble(const BubbleAnchor& other) const {
        return key()==other.key();
    }
};

struct StringStroke {
    Quad start, end; // Unwarped screen coordinates, depth and path fraction (screen radius for bursts).
    Quad film;       // Material parameters, opacity and material.
};

struct StringContact {
    Quad position; // World position and contact radius.
    Quad normal;   // Membrane normal and opacity.
    Quad tangent;  // Direction of the pull on the surface and membrane hue.
    Quad film;     // Curvature radius, sideways pull and cut highlight.
};

struct HarpoonHit {
    BubbleAnchor anchor;
    Vec impact;
    Vec heading; // Flight direction expressed in the entered bubble's coordinate frame.
    bool inward;
};

struct BubbleInspection {
    BubbleId id;
    unsigned slot, system;
    Vec shellCentre, centre;
    Quad screen; // Projected centre, apparent radius and aspect in screen-height units.
    Quad palette;
    Quad impact; // Projected point where the searchlight strikes the membrane.
};

std::optional<BubbleInspection> inspectBubble(const Ocean&, const Scene&, std::span<const Bubble> visible);

struct BubbleChime {
    BubbleId bubble;
    Vec position;
    unsigned layer{}, step{}, sequenceLength{};
};

class BubbleStrings {
public:
    enum class Result { Miss, Anchored, SameBubble, AlreadyLinked, Connected, Disconnected };
    struct ResonanceFrame { std::vector<BubbleChime> chimes; bool opened{}; };

    bool cutting() const { return cutMode && !harpoonMode; }
    bool harpooning() const { return harpoonMode; }
    void toggleMode() { if (harpoonMode) harpoonMode = false; else cutMode = !cutMode; }
    void toggleHarpoon() { harpoonMode = !harpoonMode; }
    bool anchored() const { return pending.has_value(); }
    void cancelAnchor() { pending.reset(); }
    Result fire(const Ocean& ocean, const Scene& view, double now);
    std::optional<HarpoonHit> fireHarpoon(const Ocean& ocean, const Scene& view, double now);
    Quad compose(const Ocean& ocean, const Scene& view, const ShipPose& ship,
                 std::span<const Bubble> visible, bool steer, double now,
                 std::vector<StringStroke>& strokes, std::vector<StringContact>& contacts) const;
    std::string encode() const;
    void restore(std::string_view saved, const Ocean& ocean);
    unsigned preparePassage(const Ocean&, unsigned restored, const PassagePattern&);
    bool passageReady() const { return !readyChains.empty(); }
    unsigned sequenceNotesPlayed() const;
    unsigned sequenceLength() const;
    bool resonanceActive() const { return wave.has_value() || melody.has_value(); }
    bool hasResonanceEffects() const { return resonanceActive() || !flashes.empty(); }
    void beginResonance(unsigned layer);
    void cancelResonance();
    ResonanceFrame advanceResonance(Ocean&, const Scene&, double now);

private:
    struct Link { BubbleAnchor a, b; };
    enum class ShotKind { String, Disconnect, Harpoon };
    struct Shot { Vec from, to; double time; ShotKind kind; };
    struct Cut { std::size_t index; Vec point; };

    std::optional<Cut> cutAt(const Ocean& ocean, const Scene& view, const ShipPose& ship) const;
    bool contains(const BubbleAnchor& a, const BubbleAnchor& b) const;
    using Chain = std::vector<BubbleAnchor>;
    struct PassageMatch { unsigned matched{}; std::vector<Chain> chains; };
    struct Wave {
        unsigned layer;
        std::set<BubbleAnchor::Key> reached{};
    };
    struct Melody {
        Chain chain;
        unsigned layer{}, played{};
        double due{}, spacing{};
    };
    struct Flash {
        BubbleAnchor bubble;
        double time;
        unsigned layer, step, length;
        bool finale() const { return length && step+1 == length; }
        double duration() const;
    };

    PassageMatch passageMatch(const Ocean&, const PassagePattern&) const;
    std::vector<Link> links;
    std::vector<Chain> readyChains;
    std::optional<Wave> wave;
    std::optional<Melody> melody;
    std::vector<Flash> flashes;
    std::optional<BubbleAnchor> pending;
    std::optional<Shot> shot;
    bool cutMode{};
    bool harpoonMode{};
};

} // namespace pelagic
