#import "MissionView.h"

#include <algorithm>
#include <array>
#include <cctype>
#include <cmath>
#include <string_view>

using namespace pelagic::missionui;

namespace {

NSString* missionString(std::string_view value) {
    NSString* text = [[NSString alloc] initWithBytes:value.data() length:value.size() encoding:NSUTF8StringEncoding];
    return text ? text : @"";
}

NSColor* secondaryColour() { return [NSColor colorWithSRGBRed:.74 green:.72 blue:.66 alpha:1.]; }
NSColor* dispatchAccent() { return [NSColor colorWithSRGBRed:.93 green:.77 blue:.45 alpha:1.]; }

void fillRect(NSRect bounds, NSColor* colour) {
    [colour setFill];
    NSRectFillUsingOperation(bounds, NSCompositingOperationSourceOver);
}

void drawLine(NSString* text, NSRect bounds, NSFont* font, NSColor* colour) {
    if (!text.length || bounds.size.width <= 0.) return;
    auto paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = NSLineBreakByTruncatingTail;
    [text drawInRect:bounds withAttributes:@{
        NSFontAttributeName:font, NSForegroundColorAttributeName:colour, NSParagraphStyleAttributeName:paragraph
    }];
}

struct Board {
    const char* title;
    int first, end;
};
constexpr std::array boards{Board{"Dispatch",0,6},Board{"Operations",6,9},Board{"Fleet Command",9,12},
                            Board{"Bubble Missions",12,14}};
constexpr std::array pageTitles{
    "Nearby","News","Local Leads","Follow-ups","Journal","Discoveries",
    "Charters","Convoys","Combat","Fleet","Intelligence","Campaigns","System Bubble","Region Bubble"
};

int currentBoard(Page page) {
    const auto index = int(page);
    for (unsigned i=0;i<boards.size();++i) if (index<boards[i].end) return int(i);
    return 0;
}

NSString* keyHint(const Button& button) {
    if (button.shortcut=='\r' || button.shortcut=='\n') return @"↵";
    if (button.shortcut)
        return [NSString stringWithFormat:@"%c",std::toupper(static_cast<unsigned char>(button.shortcut))];
    switch (button.action.kind) {
    case Input::Track: return @"T";
    case Input::Route: return @"↵";
    case Input::Primary: return @"1";
    case Input::Secondary: return @"2";
    case Input::Scan: return @"N";
    case Input::CaseFile: return @"B";
    case Input::Interact: return @"E";
    case Input::Hail: return @"I";
    case Input::Report: return @"R";
    case Input::Follow: return @"F";
    case Input::Mark: return @"P";
    default: return @"";
    }
}

NSTextField* label(CGFloat size, NSFontWeight weight, NSColor* colour) {
    auto field = [NSTextField labelWithString:@""];
    field.font = [NSFont systemFontOfSize:size weight:weight];
    field.textColor = colour;
    field.lineBreakMode = NSLineBreakByTruncatingTail;
    return field;
}

NSScrollView* scrollPane(NSView* document) {
    auto scroll = [NSScrollView new];
    scroll.drawsBackground = NO;
    scroll.borderType = NSNoBorder;
    scroll.scrollerStyle = NSScrollerStyleOverlay;
    scroll.hasVerticalScroller = YES;
    scroll.verticalScrollElasticity = NSScrollElasticityNone;
    scroll.documentView = document;
    return scroll;
}

void scrollToTop(NSScrollView* view) {
    [view.contentView scrollToPoint:NSZeroPoint];
    [view reflectScrolledClipView:view.contentView];
}

} // namespace

@interface MissionCanvas : NSView
@end
@implementation MissionCanvas
- (BOOL)isFlipped { return YES; }
@end

@interface MissionPanel : MissionCanvas
@property(nonatomic,strong) NSColor* accent;
@end
@implementation MissionPanel
- (void)drawRect:(NSRect)dirty {
    const NSRect face = NSInsetRect(self.bounds,2.,2.);
    const auto outline = menuPlate(face,16.,false,true);
    [[NSColor colorWithSRGBRed:.039 green:.035 blue:.034 alpha:.985] setFill];
    [outline fill];
    [[self.accent colorWithAlphaComponent:.57] setStroke];
    outline.lineWidth = 1.;
    [outline stroke];
    fillRect(NSMakeRect(19.,62.,std::max(0.,NSWidth(face)-38.),1.),[self.accent colorWithAlphaComponent:.29]);
    fillRect(NSMakeRect(19.,62.,42.,2.),self.accent);
    fillRect(NSMakeRect(19.,NSHeight(face)-38.,std::max(0.,NSWidth(face)-38.),1.),[self.accent colorWithAlphaComponent:.19]);
}
@end

@interface MissionControl : NSButton
@property(nonatomic,copy) NSString* heading;
@property(nonatomic,copy) NSString* location;
@property(nonatomic,copy) NSString* status;
@property(nonatomic,copy) NSString* shortcut;
@property(nonatomic) BOOL current;
@property(nonatomic) BOOL listRow;
@property(nonatomic) BOOL singleLine;
@property(nonatomic,strong) NSColor* accent;
@end

@implementation MissionControl
- (BOOL)isFlipped { return YES; }
- (NSRect)focusRingMaskBounds { return self.bounds; }
- (void)drawFocusRingMask { NSRectFill(self.bounds); }
- (void)drawRect:(NSRect)dirty {
    const NSRect bounds = self.bounds;
    const bool lit = self.current||self.highlighted;
    const CGFloat alpha = self.enabled ? 1. : .40;
    const auto accent = self.accent ? self.accent : dispatchAccent();
    const auto surface = [NSColor colorWithSRGBRed:.068 green:.059 blue:.055 alpha:1.];
    const auto plate = menuPlate(NSInsetRect(bounds,1.,1.),self.listRow ? 8. : 6.,false,true);
    [surface setFill];
    [plate fill];
    if (lit) {
        [[accent colorWithAlphaComponent:self.highlighted ? .29 : .16] setFill];
        [plate fill];
    }
    [[accent colorWithAlphaComponent:lit ? .86 : .23] setStroke];
    plate.lineWidth = lit ? 1.5 : .7;
    [plate stroke];
    if (self.listRow) {
        const auto heading = [NSFont systemFontOfSize:13. weight:NSFontWeightSemibold];
        const auto detail = [NSFont systemFontOfSize:11. weight:NSFontWeightMedium];
        auto paragraph = [NSMutableParagraphStyle new];
        paragraph.lineBreakMode = NSLineBreakByWordWrapping;
        [self.heading drawWithRect:NSMakeRect(12.,8.,bounds.size.width-24.,34.)
                          options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingTruncatesLastVisibleLine
                       attributes:@{NSFontAttributeName:heading,NSForegroundColorAttributeName:menuInk(),
                                     NSParagraphStyleAttributeName:paragraph}];
        const bool done = [self.status hasPrefix:@"✓"];
        const auto statusWidth = std::min(NSWidth(bounds)*.52,
            std::ceil([self.status sizeWithAttributes:@{NSFontAttributeName:detail}].width)+4.);
        const CGFloat statusX = NSWidth(bounds)-13.-statusWidth;
        drawLine(self.location,NSMakeRect(12.,47.,std::max(0.,statusX-20.),16.),detail,secondaryColour());
        drawLine(self.status,NSMakeRect(statusX,47.,statusWidth,16.),detail,done ? completedInk() : accent);
        return;
    }
    const CGFloat inset = self.shortcut.length ? 32. : self.singleLine ? 4. : 8.;
    const CGFloat width = std::max(1.,bounds.size.width-inset-(self.singleLine ? 4. : 8.));
    if (self.shortcut.length)
        drawLine(self.shortcut,NSMakeRect(8.,(bounds.size.height-14.)*.5,23.,14.),
                 [NSFont monospacedSystemFontOfSize:10. weight:NSFontWeightSemibold],
                 [accent colorWithAlphaComponent:alpha]);
    auto paragraph = [NSMutableParagraphStyle new];
    paragraph.lineBreakMode = self.singleLine ? NSLineBreakByTruncatingTail : NSLineBreakByWordWrapping;
    paragraph.alignment = self.shortcut.length ? NSTextAlignmentLeft : NSTextAlignmentCenter;
    auto font = [NSFont systemFontOfSize:11. weight:NSFontWeightSemibold];
    if (self.singleLine) {
        const CGFloat labelWidth = [self.heading sizeWithAttributes:@{NSFontAttributeName:font}].width;
        if (labelWidth>width)
            font = [NSFont systemFontOfSize:std::max(9.,11.*width/labelWidth) weight:NSFontWeightSemibold];
    }
    auto attributes = @{
        NSFontAttributeName:font,
        NSForegroundColorAttributeName:[menuInk() colorWithAlphaComponent:alpha],
        NSParagraphStyleAttributeName:paragraph
    };
    const CGFloat height = std::min(bounds.size.height-4.,
        std::ceil([self.heading boundingRectWithSize:NSMakeSize(width,CGFLOAT_MAX)
                                          options:NSStringDrawingUsesLineFragmentOrigin attributes:attributes].size.height));
    [self.heading drawWithRect:NSMakeRect(inset,(bounds.size.height-height)*.5,width,height)
                       options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingTruncatesLastVisibleLine
                    attributes:attributes];
}
@end

@implementation MissionView {
    Snapshot _snapshot;
    BOOL _presented, _resetList, _resetDossier, _resetActions, _revealRow, _compactDossier;
    void (^_handler)(Action);
    MissionPanel* _panel;
    NSColor* _accent;
    NSTextField* _heading;
    NSTextField* _location;
    NSTextField* _message;
    NSTextField* _pageCount;
    MissionCanvas* _rowDocument;
    MissionCanvas* _actionDocument;
    NSTextView* _dossier;
    NSScrollView* _rowPane;
    NSScrollView* _dossierPane;
    NSScrollView* _actionPane;
    MissionControl* _close;
    MissionControl* _previous;
    MissionControl* _next;
    NSMutableArray<MissionControl*>* _boardButtons;
    NSMutableArray<MissionControl*>* _pageButtons;
    NSMutableArray<MissionControl*>* _rowButtons;
    NSMutableArray<MissionControl*>* _actionButtons;
}

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (void)setFrameSize:(NSSize)size {
    [super setFrameSize:size];
    self.needsLayout = YES;
}

- (MissionControl*)makeControlIn:(NSView*)parent action:(SEL)action {
    auto button = [MissionControl new];
    button.bordered = NO;
    button.buttonType = NSButtonTypeMomentaryPushIn;
    button.focusRingType = NSFocusRingTypeExterior;
    button.accent = _accent;
    button.target = self;
    button.action = action;
    [parent addSubview:button];
    return button;
}

- (void)setControl:(MissionControl*)button title:(NSString*)title active:(BOOL)active enabled:(BOOL)enabled {
    button.heading = title;
    button.title = title;
    [button setAccessibilityLabel:title];
    button.current = active;
    button.enabled = enabled;
    button.needsDisplay = YES;
}

- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;
    self.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
    self.hidden = YES;
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    _accent = dispatchAccent();
    _panel = [MissionPanel new];
    _panel.accent = _accent;
    [self addSubview:_panel];
    _heading = label(28.,NSFontWeightSemibold,menuInk());
    _location = label(12.,NSFontWeightMedium,secondaryColour());
    _message = label(12.,NSFontWeightMedium,_accent);
    _pageCount = label(11.,NSFontWeightMedium,secondaryColour());
    _pageCount.alignment = NSTextAlignmentCenter;
    for (NSTextField* field in @[_heading,_location,_message,_pageCount]) [_panel addSubview:field];

    _rowDocument = [MissionCanvas new];
    _actionDocument = [MissionCanvas new];
    _dossier = [NSTextView new];
    _dossier.editable = NO;
    _dossier.selectable = NO;
    _dossier.drawsBackground = NO;
    _dossier.horizontallyResizable = NO;
    _dossier.verticallyResizable = YES;
    _dossier.textContainerInset = NSMakeSize(14.,12.);
    _dossier.textContainer.widthTracksTextView = YES;
    _rowPane = scrollPane(_rowDocument);
    _dossierPane = scrollPane(_dossier);
    _actionPane = scrollPane(_actionDocument);
    [_dossierPane setAccessibilityLabel:@"Mission Dossier"];
    [_dossierPane setAccessibilityHelp:@"Use Shift and the Up or Down arrow to scroll the report."];
    [_actionPane setAccessibilityLabel:@"Mission Actions"];
    [_actionPane setAccessibilityHelp:@"Use Control and the Up or Down arrow to scroll the actions."];
    for (NSScrollView* view in @[_rowPane,_dossierPane,_actionPane]) [_panel addSubview:view];
    _close = [self makeControlIn:_panel action:@selector(closePanel:)];
    _previous = [self makeControlIn:_panel action:@selector(previousSheet:)];
    _next = [self makeControlIn:_panel action:@selector(nextSheet:)];
    [self setControl:_close title:@"Close" active:NO enabled:YES];
    _close.shortcut = @"Esc";
    [self setControl:_previous title:@"Previous" active:NO enabled:YES];
    [self setControl:_next title:@"Next" active:NO enabled:YES];
    _boardButtons = [NSMutableArray new];
    _pageButtons = [NSMutableArray new];
    _rowButtons = [NSMutableArray new];
    _actionButtons = [NSMutableArray new];
    return self;
}

- (void)drawRect:(NSRect)dirtyRect {
    fillRect(self.bounds,[NSColor colorWithWhite:0. alpha:.63]);
}

- (void)setActionHandler:(void (^)(Action))handler { _handler = [handler copy]; }
- (void)setMissionAccent:(NSColor*)accent {
    if (!accent) accent = dispatchAccent();
    if ([_accent isEqual:accent]) return;
    _accent = _panel.accent = accent;
    _panel.needsDisplay = YES;
    _message.textColor = _accent;
    for (MissionControl* button in @[_close,_previous,_next]) {
        button.accent = _accent;
        button.needsDisplay = YES;
    }
    for (NSArray<MissionControl*>* controls in @[_boardButtons,_pageButtons,_rowButtons,_actionButtons])
        for (MissionControl* button in controls) {
            button.accent = _accent;
            button.needsDisplay = YES;
        }
    if (_presented) [self applyDossier];
}
- (void)emit:(Action)action {
    auto handler = _handler;
    [self.window makeFirstResponder:self];
    if (handler) handler(action);
}
- (void)closePanel:(id)sender { [self emit:{Input::Close}]; }
- (void)previousSheet:(id)sender { [self emit:{Input::PreviousSheet}]; }
- (void)nextSheet:(id)sender { [self emit:{Input::NextSheet}]; }
- (void)pickPage:(MissionControl*)sender { [self emit:{Input::ShowPage,int(sender.tag)}]; }
- (void)pickRow:(MissionControl*)sender { [self emit:{Input::SelectRow,int(sender.tag)}]; }
- (void)pickAction:(MissionControl*)sender {
    const auto index = std::size_t(sender.tag);
    if (index<_snapshot.buttons.size() && _snapshot.buttons[index].enabled)
        [self emit:_snapshot.buttons[index].action];
}

- (void)resizeControls:(NSMutableArray<MissionControl*>*)controls count:(std::size_t)count
                    in:(NSView*)parent action:(SEL)action {
    while (controls.count > count) {
        [controls.lastObject removeFromSuperview];
        [controls removeLastObject];
    }
    while (controls.count < count) [controls addObject:[self makeControlIn:parent action:action]];
}

- (void)applyDossier {
    auto content = [NSMutableAttributedString new];
    const auto append = [&](std::string_view value, CGFloat size, NSFontWeight weight, NSColor* colour, CGFloat space) {
        if (value.empty()) return;
        auto paragraph = [NSMutableParagraphStyle new];
        paragraph.paragraphSpacing = space;
        paragraph.lineSpacing = 4.;
        auto line = [[NSAttributedString alloc] initWithString:[missionString(value) stringByAppendingString:@"\n"]
                                                  attributes:@{
            NSFontAttributeName:weight>=NSFontWeightSemibold ? menuDisplayFont(size) : [NSFont systemFontOfSize:size weight:weight],
            NSForegroundColorAttributeName:colour, NSParagraphStyleAttributeName:paragraph
        }];
        [content appendAttributedString:line];
    };
    const auto& board = boards[std::size_t(currentBoard(_snapshot.page))];
    if (_snapshot.title!=board.title)
        append(_snapshot.title,_compactDossier ? 20. : 26.,NSFontWeightSemibold,menuInk(),10.);
    append(_snapshot.subtitle,12.,NSFontWeightMedium,_accent,12.);
    if (_snapshot.rows.empty()) append(_snapshot.empty,14.,NSFontWeightRegular,secondaryColour(),10.);
    append(_snapshot.body,14.,NSFontWeightRegular,menuInk(),10.);
    [_dossier.textStorage setAttributedString:content];
}

- (void)present:(const Snapshot&)snapshot {
    if (_presented && snapshot==_snapshot) return;
    const bool sectionChanged = !_presented || snapshot.page!=_snapshot.page || snapshot.sheet!=_snapshot.sheet;
    const bool selectionChanged = sectionChanged || snapshot.selection!=_snapshot.selection ||
                                  snapshot.title!=_snapshot.title;
    const bool tabsChanged = !_presented || snapshot.page!=_snapshot.page;
    const bool rowsChanged = sectionChanged || snapshot.rows!=_snapshot.rows || selectionChanged;
    const bool actionChanged = selectionChanged || snapshot.buttons!=_snapshot.buttons;
    const bool dossierChanged = selectionChanged || snapshot.subtitle!=_snapshot.subtitle ||
                                snapshot.body!=_snapshot.body || snapshot.empty!=_snapshot.empty;
    _snapshot = snapshot;
    _presented = YES;
    const int current = currentBoard(snapshot.page);
    const auto& board = boards[std::size_t(current)];
    _heading.stringValue = missionString(board.title);
    _location.stringValue = missionString(snapshot.location);
    _message.stringValue = missionString(snapshot.message);
    _location.toolTip = _location.stringValue;
    _message.toolTip = _message.stringValue;
    [_message setAccessibilityLabel:_message.stringValue];
    const bool paged = snapshot.sheetCount>1;
    _pageCount.hidden = _previous.hidden = _next.hidden = !paged;
    _pageCount.stringValue = [NSString stringWithFormat:@"%zu / %zu",snapshot.sheet+1,snapshot.sheetCount];
    [self setControl:_previous title:@"Previous" active:NO enabled:snapshot.sheet>0];
    [self setControl:_next title:@"Next" active:NO enabled:snapshot.sheet+1<snapshot.sheetCount];

    if (tabsChanged) {
        [self resizeControls:_boardButtons count:boards.size()-1 in:_panel action:@selector(pickPage:)];
        unsigned item = 0;
        for (unsigned i=0; i<boards.size(); ++i) {
            if (int(i)==current) continue;
            auto button = _boardButtons[item++];
            button.tag = boards[i].first;
            button.singleLine = YES;
            [self setControl:button title:missionString(boards[i].title) active:NO enabled:YES];
        }
        [self resizeControls:_pageButtons count:std::size_t(board.end-board.first) in:_panel action:@selector(pickPage:)];
        for (int i=board.first; i<board.end; ++i) {
            auto button = _pageButtons[NSUInteger(i-board.first)];
            button.tag = i;
            button.singleLine = YES;
            [self setControl:button title:missionString(pageTitles[std::size_t(i)]) active:i==int(snapshot.page) enabled:YES];
            [button setAccessibilityValue:i==int(snapshot.page) ? @"Selected" : @""];
        }
    }
    if (rowsChanged) {
        [self resizeControls:_rowButtons count:snapshot.rows.size() in:_rowDocument action:@selector(pickRow:)];
        for (NSUInteger i=0; i<_rowButtons.count; ++i) {
            const auto& row = snapshot.rows[i];
            auto button = _rowButtons[i];
            button.tag = NSInteger(i);
            button.listRow = YES;
            button.location = missionString(row.location);
            button.status = snapshot.page>=Page::SystemBubble && row.status=="Filed" ? @"✓ Completed" : missionString(row.status);
            [self setControl:button title:missionString(row.title) active:i==snapshot.selection enabled:YES];
            NSMutableArray* spoken = [NSMutableArray arrayWithObject:button.heading];
            if (button.location.length) [spoken addObject:button.location];
            if (button.status.length) [spoken addObject:button.status];
            [button setAccessibilityLabel:[spoken componentsJoinedByString:@", "]];
            [button setAccessibilityValue:i==snapshot.selection ? @"Selected" : @""];
        }
    }
    if (actionChanged) {
        [self resizeControls:_actionButtons count:snapshot.buttons.size() in:_actionDocument action:@selector(pickAction:)];
        for (NSUInteger i=0; i<_actionButtons.count; ++i) {
            const auto& item = snapshot.buttons[i];
            auto button = _actionButtons[i];
            button.tag = NSInteger(i);
            button.shortcut = keyHint(item);
            [self setControl:button title:missionString(item.title) active:NO enabled:item.enabled];
            [button setAccessibilityHelp:button.shortcut.length ? [@"Shortcut " stringByAppendingString:button.shortcut] : nil];
        }
    }
    if (dossierChanged) [self applyDossier];
    _resetList |= sectionChanged;
    _resetDossier |= selectionChanged;
    _resetActions |= selectionChanged;
    _revealRow |= selectionChanged;
    self.needsLayout = YES;
}

- (void)layout {
    [super layout];
    const auto view = self.bounds.size;
    if (view.width<270. || view.height<250.) return;
    const CGFloat width = std::min(1110.,view.width-32.);
    const CGFloat height = std::min(810.,view.height-56.);
    _panel.frame = NSMakeRect((view.width-width)*.5,(view.height-height)*.5+10.,width,height);
    constexpr CGFloat margin = 16., gap = 7., closeWidth = 72.;
    const CGFloat boardWidth = width<570. ? 78. : 102.;
    _heading.font = menuDisplayFont(width<570. ? 23. : 30.);
    _close.frame = NSMakeRect(width-margin-closeWidth,16.,closeWidth,32.);
    CGFloat boardX = NSMinX(_close.frame)-gap-boardWidth;
    for (MissionControl* button in [_boardButtons reverseObjectEnumerator]) {
        button.frame = NSMakeRect(boardX,16.,boardWidth,32.);
        boardX -= boardWidth+gap;
    }
    _heading.frame = NSMakeRect(margin,12.,std::max(100.,boardX+boardWidth-margin),34.);
    _location.frame = NSMakeRect(margin,44.,width-2.*margin,17.);
    const CGFloat pageWidth = (width-2.*margin-std::max(0.,CGFloat(_pageButtons.count)-1.)*gap)/
                              CGFloat(std::max(NSUInteger(1),_pageButtons.count));
    CGFloat tabX = margin;
    for (MissionControl* button in _pageButtons) {
        button.frame = NSMakeRect(tabX,72.,pageWidth,32.);
        tabX += pageWidth+gap;
    }

    const CGFloat footer = height-45.;
    const CGFloat available = footer-117.;
    const CGFloat listWidth = std::clamp(width*.32,126.,342.);
    const CGFloat detailX = margin+listWidth+12.;
    const CGFloat detailWidth = width-detailX-margin;
    const bool compactDossier = detailWidth<345.;
    if (compactDossier!=_compactDossier) {
        _compactDossier = compactDossier;
        if (_presented) [self applyDossier];
    }
    _rowPane.frame = NSMakeRect(margin,116.,listWidth,available);
    const CGFloat actualListWidth = _rowPane.contentSize.width;
    constexpr CGFloat rowHeight = 68., rowPitch = 73.;
    _rowDocument.frame = NSMakeRect(0.,0.,actualListWidth,CGFloat(_rowButtons.count)*rowPitch);
    for (NSUInteger i=0; i<_rowButtons.count; ++i)
        _rowButtons[i].frame = NSMakeRect(0.,CGFloat(i)*rowPitch,actualListWidth,rowHeight);

    const NSUInteger columns = detailWidth>=325. ? 2u : 1u;
    const NSUInteger rows = (_actionButtons.count+columns-1u)/columns;
    constexpr CGFloat actionHeight = 40., actionPitch = 46.;
    const CGFloat totalActions = rows ? actionHeight+CGFloat(rows-1u)*actionPitch : 0.;
    const CGFloat actionsShown = std::min(totalActions,std::max(40.,available*.44));
    const CGFloat dossierHeight = available-actionsShown-(actionsShown>0. ? 8. : 0.);
    _dossierPane.frame = NSMakeRect(detailX,116.,detailWidth,dossierHeight);
    _dossier.frame = NSMakeRect(0.,0.,_dossierPane.contentSize.width,dossierHeight);
    [_dossier.layoutManager ensureLayoutForTextContainer:_dossier.textContainer];
    const NSRect used = [_dossier.layoutManager usedRectForTextContainer:_dossier.textContainer];
    [_dossier setFrameSize:NSMakeSize(_dossierPane.contentSize.width,
        std::max(dossierHeight,NSHeight(used)+_dossier.textContainerInset.height*2.))];

    _actionPane.hidden = !rows;
    _actionPane.frame = NSMakeRect(detailX,116.+dossierHeight+8.,detailWidth,actionsShown);
    const CGFloat actionContentWidth = _actionPane.contentSize.width;
    _actionDocument.frame = NSMakeRect(0.,0.,actionContentWidth,totalActions);
    const CGFloat buttonWidth = (actionContentWidth-(CGFloat(columns)-1.)*gap)/CGFloat(columns);
    for (NSUInteger i=0; i<_actionButtons.count; ++i)
        _actionButtons[i].frame = NSMakeRect(CGFloat(i%columns)*(buttonWidth+gap),CGFloat(i/columns)*actionPitch,
                                             buttonWidth,actionHeight);

    _previous.frame = NSMakeRect(width-margin-190.,footer+6.,66.,28.);
    _pageCount.frame = NSMakeRect(width-margin-122.,footer+12.,54.,16.);
    _next.frame = NSMakeRect(width-margin-66.,footer+6.,66.,28.);
    _message.frame = NSMakeRect(margin,footer+12.,width-2.*margin-(_pageCount.hidden ? 0. : 200.),20.);
    if (_resetList) scrollToTop(_rowPane);
    if (_resetDossier) scrollToTop(_dossierPane);
    if (_resetActions) scrollToTop(_actionPane);
    if (_revealRow && _snapshot.selection<_rowButtons.count)
        [_rowDocument scrollRectToVisible:_rowButtons[_snapshot.selection].frame];
    _resetList = _resetDossier = _resetActions = _revealRow = NO;
}

- (BOOL)handleKey:(NSEvent*)event {
    if (self.hidden || !_presented || (event.modifierFlags&(NSEventModifierFlagCommand|NSEventModifierFlagOption))) return NO;
    NSString* characters = event.charactersIgnoringModifiers.lowercaseString;
    const unichar key = characters.length ? [characters characterAtIndex:0] : 0;
    const auto& board = boards[std::size_t(currentBoard(_snapshot.page))];
    const auto openPage = [&](Page page) {
        [self emit:page==_snapshot.page ? Action{Input::Close} : Action{Input::ShowPage,int(page)}];
    };
    const auto modifiers = event.modifierFlags;
    if ((key==NSUpArrowFunctionKey||key==NSDownArrowFunctionKey) &&
        (modifiers&(NSEventModifierFlagShift|NSEventModifierFlagControl))) {
        NSScrollView* pane = (modifiers&NSEventModifierFlagControl) ? _actionPane : _dossierPane;
        const auto clip = pane.contentView;
        auto scroll = clip.bounds.origin;
        const auto end = std::max(0.,pane.documentView.frame.size.height-clip.bounds.size.height);
        scroll.y = std::clamp(scroll.y+(key==NSUpArrowFunctionKey ? -50. : 50.),0.,end);
        [clip scrollToPoint:scroll];
        [pane reflectScrolledClipView:clip];
        return YES;
    }
    switch (key) {
    case 27: [self emit:{Input::Close}]; return YES;
    case NSF7FunctionKey:
        if (board.first==0) [self emit:{Input::Close}];
        else [self emit:{Input::ShowPage,int(Page::Nearby)}];
        return YES;
    case NSF4FunctionKey: openPage(Page::Charters); return YES;
    case NSF6FunctionKey: openPage(Page::SystemBubble); return YES;
    case NSF8FunctionKey: openPage(Page::Combat); return YES;
    case NSF9FunctionKey: openPage(Page::Convoys); return YES;
    case NSF10FunctionKey: openPage(Page::Fleet); return YES;
    case NSUpArrowFunctionKey:
        if (_snapshot.selection>0) [self emit:{Input::SelectRow,int(_snapshot.selection-1)}];
        return YES;
    case NSDownArrowFunctionKey:
        if (_snapshot.selection+1<_snapshot.rows.size()) [self emit:{Input::SelectRow,int(_snapshot.selection+1)}];
        return YES;
    case NSPageUpFunctionKey:
        if (_snapshot.sheet>0) [self emit:{Input::PreviousSheet}];
        return YES;
    case NSPageDownFunctionKey:
        if (_snapshot.sheet+1<_snapshot.sheetCount) [self emit:{Input::NextSheet}];
        return YES;
    case '\t':
    case NSBackTabCharacter: {
        const int page = int(_snapshot.page);
        const bool back = key==NSBackTabCharacter || (event.modifierFlags&NSEventModifierFlagShift);
        const int step = back ? -1 : 1;
        [self emit:{Input::ShowPage,board.first+(page-board.first+step+board.end-board.first)%(board.end-board.first)}];
        return YES;
    }
    default: break;
    }
    for (const auto& button : _snapshot.buttons) {
        if (!button.shortcut || key!=std::tolower(static_cast<unsigned char>(button.shortcut))) continue;
        if (button.enabled) [self emit:button.action];
        return YES;
    }
    Input action;
    switch (key) {
    case NSCarriageReturnCharacter: case NSEnterCharacter: action=Input::Route; break;
    case 't': action=Input::Track; break;
    case '1': action=Input::Primary; break;
    case '2': action=Input::Secondary; break;
    case 'n': action=Input::Scan; break;
    case 'b': action=Input::CaseFile; break;
    case 'e': action=Input::Interact; break;
    case 'i': action=Input::Hail; break;
    case 'r': action=Input::Report; break;
    case 'f': action=Input::Follow; break;
    case 'p': action=Input::Mark; break;
    default: return NO;
    }
    for (const auto& button : _snapshot.buttons) {
        if (button.action.kind!=action) continue;
        if (button.enabled) [self emit:button.action];
        return YES;
    }
    return NO;
}

- (void)keyDown:(NSEvent*)event {
    if (![self handleKey:event]) [super keyDown:event];
}

@end
