#import "BubbleFlightHud.h"

#include <algorithm>
#include <cmath>
#include <optional>

using namespace pelagic;

namespace {

NSColor* phosphor(CGFloat alpha=1.) {
    return [NSColor colorWithSRGBRed:.79 green:.98 blue:.69 alpha:alpha];
}

NSColor* amber() {
    return [NSColor colorWithSRGBRed:1. green:.79 blue:.43 alpha:1.];
}

NSColor* shade(CGFloat alpha) {
    return [NSColor colorWithSRGBRed:.015 green:.024 blue:.018 alpha:alpha];
}

NSString* label(const std::string& value) {
    return [NSString stringWithUTF8String:value.c_str()];
}

void line(NSPoint a,NSPoint b,NSColor* colour,CGFloat width=1.) {
    const auto path=[NSBezierPath bezierPath];
    [path moveToPoint:a];
    [path lineToPoint:b];
    path.lineWidth=width;
    [colour setStroke];
    [path stroke];
}

void fillRect(NSRect rect,NSColor* colour) {
    [colour setFill];
    NSRectFill(rect);
}

void drawText(NSString* value,NSRect rect,CGFloat size,NSFontWeight weight,NSColor* colour,
              NSTextAlignment align=NSTextAlignmentLeft,bool mono=true) {
    auto* paragraph=[NSMutableParagraphStyle new];
    paragraph.alignment=align;
    paragraph.lineBreakMode=NSLineBreakByTruncatingTail;
    const auto font=mono ? [NSFont monospacedSystemFontOfSize:size weight:weight] :
                           [NSFont systemFontOfSize:size weight:weight];
    [value drawInRect:rect withAttributes:@{NSFontAttributeName:font,NSForegroundColorAttributeName:colour,
                                           NSParagraphStyleAttributeName:paragraph}];
}

int bearing(int degrees) {
    return (degrees%360+360)%360;
}

const char* toolName(BubbleTool tool) {
    switch (tool) {
        case BubbleTool::String: return "String";
        case BubbleTool::Disconnect: return "Disconnect";
        case BubbleTool::Harpoon: return "Harpoon";
    }
}

NSString* passageStatus(const BubbleFlightHudState& state) {
    if (const auto required=state.passagePattern.restored())
        return [NSString stringWithFormat:@"%u of %u bubbles to open %@",state.gateCompleted,required,
                label(state.passageName)];
    if (state.passageName.empty()) return @"Hold in the Whirlpool eye to return";
    return [NSString stringWithFormat:@"%@ passage open",label(state.passageName)];
}

NSString* describePattern(const PassagePattern& pattern,bool spoken) {
    NSMutableArray<NSString*>* runs=[NSMutableArray arrayWithCapacity:pattern.colourRuns.size()];
    for (const unsigned count:pattern.colourRuns) {
        if (!count) break;
        NSString* run=spoken ? [NSString stringWithFormat:@"%u colour %@",count,count==1 ? @"bubble" : @"bubbles"] :
            [NSString stringWithFormat:@"C×%u",count];
        [runs addObject:run];
    }
    return [runs componentsJoinedByString:spoken ? @", then one monochrome bubble, then " : @" – M – "];
}

void headingTape(NSSize size,float heading) {
    const CGFloat cx=size.width*.5, y=57.;
    const CGFloat span=std::clamp(size.width*.20,110.,230.), scale=span/46.;
    // The selected bearing stays on the index while the compass card moves beneath it.
    fillRect(NSMakeRect(cx-span-4.,y-3.,span*2.+8.,34.),shade(.55));
    line({cx-span,y+27.},{cx+span,y+27.},phosphor(.46));
    const int from=int(std::ceil((heading-46.f)/5.f))*5;
    for (int tick=from; tick<=heading+46.f; tick+=5) {
        const CGFloat x=cx+(tick-heading)*scale;
        const bool major=tick%15==0;
        line({x,y+(major ? 17. : 22.)},{x,y+27.},phosphor(.66));
        if (major) {
            const int degrees=bearing(tick);
            NSArray<NSString*>* cardinals=@[@"N",@"E",@"S",@"W"];
            NSString* text=degrees%90==0 ? cardinals[degrees/90] : [NSString stringWithFormat:@"%03d",degrees];
            drawText(text,NSMakeRect(x-16.,y,32.,15.),10.,NSFontWeightMedium,phosphor(.9),NSTextAlignmentCenter);
        }
    }
    const auto plate=NSMakeRect(cx-34.,y+29.,68.,24.);
    fillRect(plate,shade(.87));
    [phosphor(.67) setStroke];
    [NSBezierPath strokeRect:NSInsetRect(plate,.5,.5)];
    line({cx-4.,y+29.},{cx,y+24.},phosphor());
    line({cx,y+24.},{cx+4.,y+29.},phosphor());
    NSString* readout=[NSString stringWithFormat:@"HDG %03d",bearing(int(std::lround(heading)))];
    drawText(readout,NSInsetRect(plate,4.,4.),11.,NSFontWeightSemibold,phosphor(),NSTextAlignmentCenter);
}

void flightTape(NSPoint centre,CGFloat height,float value,int interval,int majorEvery,CGFloat scale,
                bool left,bool signedScale,NSString* title,NSString* readout,NSString* auxiliary,CGFloat opacity) {
    const CGFloat dx=left ? 1. : -1., x=centre.x, y=centre.y;
    const auto textAlign=left ? NSTextAlignmentLeft : NSTextAlignmentRight;
    const auto rectAt=[&](CGFloat offset,CGFloat w,CGFloat row,CGFloat h) {
        return NSMakeRect(left ? x+offset : x-offset-w,row,w,h);
    };
    const auto edge=phosphor(.6*opacity), thin=phosphor(.45*opacity), type=phosphor(opacity);
    fillRect(rectAt(-6.,83.,y-height-22.,height*2.+42.),shade(.43*opacity));
    drawText(title,rectAt(0.,76.,y-height-19.,15.),10.,NSFontWeightSemibold,type,textAlign);
    line({x,y-height},{x,y+height},thin);
    const int first=int(std::ceil((value-height/scale)/interval))*interval;
    for (int tick=first; tick<=value+height/scale; tick+=interval) {
        if (!signedScale && tick<0) continue;
        const CGFloat ty=y-(tick-value)*scale;
        const bool major=tick%majorEvery==0;
        line({x,ty},{x+dx*(major ? 9. : 5.),ty},thin);
        if (major && std::abs(ty-y)>18.) {
            NSString* mark=[NSString stringWithFormat:signedScale && tick ? @"%+d" : @"%d",tick];
            drawText(mark,rectAt(15.,48.,ty-7.,14.),10.,NSFontWeightMedium,type,textAlign);
        }
    }
    const auto indicator=rectAt(12.,64.,y-11.,22.);
    fillRect(indicator,shade(.90*opacity));
    [edge setStroke];
    [NSBezierPath strokeRect:NSInsetRect(indicator,.5,.5)];
    line({x+dx*4.,y},{x+dx*12.,y-4.},edge);
    line({x+dx*4.,y},{x+dx*12.,y+4.},edge);
    drawText(readout,NSInsetRect(indicator,4.,3.),11.5,NSFontWeightSemibold,type,NSTextAlignmentCenter);
    drawText(auxiliary,rectAt(0.,76.,y+height+5.,15.),10.,NSFontWeightMedium,type,textAlign);
}

void readoutFrame(NSRect rect,bool left) {
    fillRect(rect,shade(.83));
    const CGFloat x=left ? NSMinX(rect) : NSMaxX(rect);
    const CGFloat sign=left ? 1. : -1.;
    const auto colour=phosphor(.52);
    line({x,NSMinY(rect)},{x+sign*28.,NSMinY(rect)},colour);
    line({x,NSMinY(rect)},{x,NSMaxY(rect)},colour);
    line({x,NSMaxY(rect)},{x+sign*28.,NSMaxY(rect)},colour);
}

void missionReadout(NSRect rect,const BubbleFlightHudState& state) {
    readoutFrame(rect,true);
    const CGFloat x=NSMinX(rect)+12., w=NSWidth(rect)-24., y=NSMinY(rect)+8.;
    if (state.layer) {
        NSString* zone=[NSString stringWithFormat:@"L%u/%zu   %@",*state.layer+1,regionScales,
                        label(state.layerName).uppercaseString];
        drawText(zone,NSMakeRect(x,y,w,15.),10.,NSFontWeightSemibold,phosphor(.87));
    }
    drawText(label(state.objective),NSMakeRect(x,y+19.,w,20.),14.,NSFontWeightSemibold,phosphor(),NSTextAlignmentLeft,false);
    drawText(label(state.destination),NSMakeRect(x,y+42.,w,17.),11.,NSFontWeightMedium,phosphor(.86),NSTextAlignmentLeft,false);
    drawText(label(state.instruction),NSMakeRect(x,y+62.,w,16.),10.5,NSFontWeightMedium,phosphor(.75),NSTextAlignmentLeft,false);
    if (state.layer) {
        line({x,y+84.},{x+w,y+84.},phosphor(.25));
        const unsigned required=state.passagePattern.restored();
        const auto colour=state.gateCompleted<required ? amber() : phosphor(.96);
        drawText(passageStatus(state),NSMakeRect(x,y+91.,w,15.),11.,NSFontWeightSemibold,colour,NSTextAlignmentLeft,false);
        if (required) {
            const auto pattern=describePattern(state.passagePattern,false);
            const CGFloat size=std::min(11.5,w/(.64*pattern.length));
            drawText(pattern,NSMakeRect(x,y+111.,w,16.),size,NSFontWeightSemibold,phosphor(.96));
            drawText(@"One chain · C Colour · M Mono",NSMakeRect(x,y+130.,w-72.,14.),9.5,NSFontWeightMedium,
                     phosphor(.78),NSTextAlignmentLeft,false);
            const unsigned expected=state.passagePattern.length();
            NSString* progress=state.sequenceLength ?
                [NSString stringWithFormat:@"%u/%u sounding",state.notesPlayed,state.sequenceLength] :
                state.passageReady ? @"F Pulse chain" :
                [NSString stringWithFormat:@"%u/%u matched",state.passageMatch,expected];
            drawText(progress,NSMakeRect(x+w-70.,y+130.,70.,14.),9.5,NSFontWeightSemibold,
                     state.passageMatch==expected ? phosphor() : amber(),NSTextAlignmentRight,false);
        }
    }
}

void toolReadout(NSRect rect,const BubbleFlightHudState& state) {
    readoutFrame(rect,false);
    const CGFloat x=NSMinX(rect)+12., w=NSWidth(rect)-24., y=NSMinY(rect)+8.;
    drawText(@"TOOL",NSMakeRect(x,y,w,15.),10.,NSFontWeightSemibold,phosphor(.78));
    NSString* light=state.searchlight ? @"O  LIGHT ON" : @"O  LIGHT OFF";
    drawText(light,NSMakeRect(x,y,w,15.),10.,NSFontWeightSemibold,
             phosphor(state.searchlight ? 1. : .65),NSTextAlignmentRight);
    NSString* mode=[NSString stringWithUTF8String:toolName(state.tool)];
    drawText(mode.uppercaseString,NSMakeRect(x,y+19.,w,20.),15.,NSFontWeightSemibold,phosphor());
    if (state.paused || state.locked) {
        drawText(state.paused ? @"PAUSED" : @"POSITION LOCKED",NSMakeRect(x,y+23.,w,16.),
                 9.,NSFontWeightSemibold,amber(),NSTextAlignmentRight);
    }
    drawText(label(state.toolHint),NSMakeRect(x,y+42.,w,17.),11.,NSFontWeightMedium,phosphor(.91),NSTextAlignmentLeft,false);
    NSString* modes=state.tool==BubbleTool::Harpoon ? @"↵ Fire   T Strings" :
        state.tool==BubbleTool::Disconnect ? @"↵ Fire   T String   Z Harpoon" : @"↵ Fire   T Cut   Z Harpoon";
    drawText(modes,NSMakeRect(x,y+63.,w,16.),10.,NSFontWeightMedium,phosphor(.77),NSTextAlignmentLeft,false);
    NSString* command=state.locked ? @"U Release position" : state.canLock ? @"U Lock position" :
        state.anchored && state.tool==BubbleTool::String ? @"C Cancel anchor" : @"F Send pulse wave";
    if (command.length) {
        line({x,y+84.},{x+w,y+84.},phosphor(.25));
        drawText(command,NSMakeRect(x,y+91.,w,15.),11.,NSFontWeightSemibold,phosphor(.86),NSTextAlignmentLeft,false);
    }
}

}

@implementation BubbleFlightHud {
    std::optional<BubbleFlightHudState> _state;
    FlightTelemetry _telemetry;
}
- (BOOL)isFlipped { return YES; }
- (NSView*)hitTest:(NSPoint)point { return nil; }
- (BOOL)isAccessibilityElement { return _state.has_value() && !self.hidden; }
- (NSString*)accessibilityRole { return NSAccessibilityStaticTextRole; }
- (NSString*)accessibilityValue {
    if (!_state) return nil;
    const auto& state=*_state;
    NSString* layer=state.layer ? [NSString stringWithFormat:@"Layer %u of %zu. %@. %@. ",
                                   *state.layer+1,regionScales,label(state.layerName),passageStatus(state)] : @"";
    if (state.passagePattern.length()) {
        layer=[layer stringByAppendingFormat:@"String one unbranched chain in this layer. %@. %u of %u matched. ",
               describePattern(state.passagePattern,true),state.passageMatch,state.passagePattern.length()];
        if (state.sequenceLength)
            layer=[layer stringByAppendingFormat:@"Chain sounding. %u of %u notes. ",state.notesPlayed,state.sequenceLength];
        else if (state.passageReady)
            layer=[layer stringByAppendingString:@"Chain ready. Tap F to send a pulse wave to it. "];
    }
    return [NSString stringWithFormat:
        @"%@%@. %@. %@. %@ tool. %@. Searchlight %@. %@Heading %03d degrees. Speed %.1f world units per second. Pitch %+.0f degrees. Bank %+.0f degrees.",
        layer,label(state.objective),label(state.destination),label(state.instruction),
        [NSString stringWithUTF8String:toolName(state.tool)],label(state.toolHint),state.searchlight ? @"on" : @"off",
        state.paused ? @"Paused. Space to resume. " : state.locked ? @"Position locked. " : @"",
        bearing(int(std::lround(_telemetry.heading))),
        _telemetry.speed,_telemetry.pitch,_telemetry.bank];
}
- (void)present:(const BubbleFlightHudState&)state telemetry:(FlightTelemetry)telemetry {
    telemetry.speed=std::round(telemetry.speed*10.f)/10.f;
    telemetry.heading=std::round(telemetry.heading*4.f)/4.f;
    telemetry.pitch=std::round(telemetry.pitch*4.f)/4.f;
    telemetry.bank=std::round(telemetry.bank);
    const bool changed=!_state || *_state!=state;
    if (!changed && _telemetry==telemetry) return;
    if (changed) _state=state;
    _telemetry=telemetry;
    self.needsDisplay=YES;
    if (changed) NSAccessibilityPostNotification(self,NSAccessibilityValueChangedNotification);
}
- (void)drawRect:(NSRect)dirty {
    if (!_state) return;
    const auto size=self.bounds.size;
    const CGFloat margin=std::clamp(size.width*.028,16.,36.);
    const CGFloat cardWidth=(size.width-margin*3.)*.5;
    const auto& state=*_state;
    const CGFloat bottom=size.height-23., missionHeight=state.passagePattern.length() ? 160. : 119.;
    const CGFloat missionTop=bottom-missionHeight;
    const CGFloat middle=std::min(size.height*.46,missionTop-72.);
    const CGFloat height=std::clamp(std::min(middle-125.,missionTop-middle-27.),28.,84.);
    headingTape(size,_telemetry.heading);
    // Give the active mission wheel precedence near the edges of the flight display.
    const CGFloat tapeOpacity=(state.canLock || state.locked) ? .47 : 1.;
    NSString* speed=[NSString stringWithFormat:@"%.1f u/s",_telemetry.speed];
    NSString* pitch=[NSString stringWithFormat:@"%+.0f°",_telemetry.pitch];
    NSString* bank=[NSString stringWithFormat:@"BANK %+.0f°",_telemetry.bank];
    flightTape({margin+5.,middle},height,_telemetry.speed,1,2,height/5.,true,false,@"SPEED",speed,@"",tapeOpacity);
    flightTape({size.width-margin-5.,middle},height,_telemetry.pitch,5,10,height/23.,false,true,
               @"PITCH",pitch,bank,tapeOpacity);
    const CGFloat missionWidth=std::min(cardWidth,362.);
    const CGFloat toolWidth=std::min(cardWidth,304.);
    missionReadout(NSMakeRect(margin,missionTop,missionWidth,missionHeight),state);
    toolReadout(NSMakeRect(size.width-margin-toolWidth,bottom-119.,toolWidth,119.),state);
}
@end
