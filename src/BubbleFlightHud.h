#pragma once

#import <AppKit/AppKit.h>

#include "PassagePattern.hpp"

namespace pelagic {

enum class BubbleTool { String, Disconnect, Harpoon };

struct BubbleFlightHudState {
    std::optional<unsigned> layer;
    std::string layerName, passageName;
    unsigned gateCompleted{}, passageMatch{};
    unsigned notesPlayed{}, sequenceLength{};
    bool passageReady{};
    PassagePattern passagePattern{};
    std::string objective, destination, instruction;
    BubbleTool tool{BubbleTool::String};
    std::string toolHint;
    bool searchlight{}, locked{}, canLock{}, anchored{}, paused{};
    bool operator==(const BubbleFlightHudState&) const = default;
};

}

@interface BubbleFlightHud : NSView
- (void)present:(const pelagic::BubbleFlightHudState&)state telemetry:(pelagic::FlightTelemetry)telemetry;
@end
