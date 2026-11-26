#pragma once

#import <AppKit/AppKit.h>

#include "MissionPresentation.hpp"

#include <algorithm>
#include <array>
#include <cmath>

namespace pelagic::missionui {

inline NSColor* menuInk() { return [NSColor colorWithSRGBRed:.99 green:.96 blue:.87 alpha:1.]; }
inline NSColor* completedInk() { return [NSColor colorWithSRGBRed:.63 green:.94 blue:.81 alpha:1.]; }
inline NSColor* menuAccent(float red,float green,float blue) {
    const float peak = std::max({.12f,red,green,blue});
    const auto highlight = [peak](float channel) { return .16+.82*std::pow(std::max(0.f,channel)/peak,.63); };
    return [NSColor colorWithSRGBRed:highlight(red) green:highlight(green) blue:highlight(blue) alpha:1.];
}
inline NSFont* menuDisplayFont(CGFloat size) {
    const auto font = [NSFont fontWithName:@"AvenirNextCondensed-Heavy" size:size];
    return font ? font : [NSFont systemFontOfSize:size weight:NSFontWeightHeavy];
}
inline NSBezierPath* menuPlate(NSRect box, CGFloat bite, bool mirrored=false, bool flipped=false) {
    const CGFloat w = NSWidth(box), h = NSHeight(box);
    const CGFloat cut = std::min({bite,w*.20,h*.36});
    const std::array<NSPoint,6> corners{{{0.,cut*.65},{cut*.57,h-cut*.28},{w-cut,h},
                                         {w,h-cut*.72},{w-cut*.36,cut*.43},{cut*1.12,0.}}};
    const auto path = [NSBezierPath bezierPath];
    for (const auto& p:corners) {
        const auto point = NSMakePoint(box.origin.x+(mirrored ? w-p.x : p.x),box.origin.y+(flipped ? h-p.y : p.y));
        if (path.empty) [path moveToPoint:point];
        else [path lineToPoint:point];
    }
    [path closePath];
    return path;
}

} // namespace pelagic::missionui

@interface MissionView : NSView
- (void)setActionHandler:(void (^)(pelagic::missionui::Action))handler;
- (void)setMissionAccent:(NSColor*)accent;
- (void)present:(const pelagic::missionui::Snapshot&)snapshot;
- (BOOL)handleKey:(NSEvent*)event;
@end
