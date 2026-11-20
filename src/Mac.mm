#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#include "Sea.hpp"
#include "Score.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <memory>
#include <stdexcept>

using namespace pelagic;

static_assert(sizeof(Scene) == 416);
static_assert(sizeof(Jelly) == 80);
static_assert(sizeof(Tracer) == 48);
static_assert(sizeof(FlowNode) == 32);
static_assert(sizeof(TrailPose) == 96);
struct alignas(16) TrailLayout {
    std::array<std::uint32_t,4> history;
    float lifetime;
    std::uint32_t lines, segments;
};
static_assert(sizeof(TrailLayout) == 32);
struct JellyMesh {
    static constexpr std::uint32_t rootRows = 4, rootColumns = 3;
    std::uint32_t steps, strands, sides, slices;
    constexpr NSUInteger vertices() const {
        const auto tentacles = (strands+8*3)*steps+(strands-8)*rootRows*(rootColumns-1);
        const auto bell = sides*(slices+slices/3);
        const auto anatomy = 4*8*(sides/3);
        return (tentacles+bell+anatomy)*6;
    }
};
constexpr JellyMesh giantMesh{43,33,100,31};
constexpr JellyMesh shoalMesh{24,33,56,19};
static_assert(giantMesh.vertices() < UINT16_MAX && shoalMesh.vertices() < UINT16_MAX);

static std::vector<std::uint16_t> jellyIndices(const JellyMesh& mesh) {
    // Index each grid using the same vertex IDs the procedural shader already expects.
    constexpr unsigned dx[] = {0,1,1,0,1,0};
    constexpr unsigned dy[] = {0,0,1,0,1,1};
    std::vector<std::uint16_t> indices;
    indices.reserve(mesh.vertices());
    auto grid = [&](unsigned columns,unsigned rows) {
        std::vector<std::uint16_t> corners((columns+1)*(rows+1),UINT16_MAX);
        for (unsigned y = 0; y < rows; ++y)
            for (unsigned x = 0; x < columns; ++x)
                for (unsigned k = 0; k < 6; ++k) {
                    auto& index = corners[(y+dy[k])*(columns+1)+x+dx[k]];
                    if (index == UINT16_MAX) index = std::uint16_t(indices.size());
                    indices.push_back(index);
                }
    };
    for (unsigned i = 0; i < 8; ++i) grid(4,mesh.steps);
    for (unsigned i = 8; i < mesh.strands; ++i) {
        grid(JellyMesh::rootColumns,JellyMesh::rootRows);
        grid(1,mesh.steps-JellyMesh::rootRows);
    }
    for (unsigned i = 0; i < 4; ++i) grid(mesh.sides/3,8);
    grid(mesh.sides,mesh.slices/3);
    grid(mesh.sides,mesh.slices);
    return indices;
}

static std::vector<std::uint16_t> trailIndices() {
    constexpr std::uint16_t corners[] = {0,1,2,0,2,5,5,2,8,5,8,11};
    constexpr auto count = trailLines*trailSamples*std::size(corners);
    static_assert(count < UINT16_MAX);
    std::vector<std::uint16_t> indices;
    indices.reserve(count);
    for (std::size_t base = 0; base < count; base += std::size(corners))
        for (const auto offset : corners) indices.push_back(std::uint16_t(base+offset));
    return indices;
}

enum class Blend { Solid, Alpha, Jelly };

static bool usesGiantMesh(const Jelly& jelly) {
    // Body detail is stable as it approaches or crosses the camera.
    return jelly.flow.z > 0.f || jelly.position.w > 4.f;
}

static NSString* message(const std::exception& error) {
    return [NSString stringWithUTF8String:error.what()];
}
static std::runtime_error failure(NSError* error, const char* fallback) {
    const char* detail = error.localizedDescription.UTF8String;
    return std::runtime_error(detail ? detail : fallback);
}
static NSString* resource(NSString* name, NSString* extension) {
    return [NSBundle.mainBundle pathForResource:name ofType:extension];
}
static NSColor* ink(CGFloat alpha = 1.) {
    return [NSColor colorWithSRGBRed:.89 green:.97 blue:.96 alpha:alpha];
}

@interface Renderer : NSObject
- (instancetype)initWithDevice:(id<MTLDevice>)device;
- (id<MTLCommandBuffer>)render:(id<MTLTexture>)destination ocean:(const Ocean&)ocean
                       music:(Quad)music phase:(float)phase;
@end

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _sea, _currents, _sheets, _streaks, _animal, _jellyComposite, _plankton, _finish;
    id<MTLTexture> _light, _waterLight, _jellyLight, _jellyTransmission;
    id<MTLRenderPipelineState> _extractGlow, _spreadGlow;
    id<MTLComputePipelineState> _markTrails;
    id<MTLTexture> _nearGlow, _farGlow;
    id<MTLBuffer> _tracerBuffers[3];
    id<MTLBuffer> _flowBuffers[3];
    id<MTLBuffer> _trailBuffers[3];
    id<MTLBuffer> _jellyBuffers[3];
    id<MTLBuffer> _trailMarks[3];
    id<MTLBuffer> _giantIndices, _shoalIndices, _streakIndices;
    std::array<Jelly,trailActors> _visibleJellies;
    unsigned _tracerSlot;
}

- (id<MTLRenderPipelineState>)pipeline:(id<MTLLibrary>)library vertex:(NSString*)vertex
                             fragment:(NSString*)fragment format:(MTLPixelFormat)format blend:(Blend)blend {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.label = fragment;
    d.vertexFunction = [library newFunctionWithName:vertex];
    d.fragmentFunction = [library newFunctionWithName:fragment];
    auto attachment = d.colorAttachments[0];
    attachment.pixelFormat = format;
    if (blend == Blend::Alpha) {
        attachment.blendingEnabled = YES;
        attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    } else if (blend == Blend::Jelly) {
        attachment.blendingEnabled = YES;
        attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOne;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOne;
        auto transmission = d.colorAttachments[1];
        transmission.pixelFormat = MTLPixelFormatR16Float;
        transmission.blendingEnabled = YES;
        transmission.sourceRGBBlendFactor = MTLBlendFactorZero;
        transmission.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceColor;
    }
    NSError* error = nil;
    auto result = [_device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!result) throw failure(error, "A Metal pipeline failed.");
    return result;
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!device) throw std::runtime_error("Pelagic Orbits requires a Metal-capable Mac.");
    _device = device;
    _queue = [device newCommandQueue];
    NSError* error = nil;
    NSString* path = resource(@"Sea",@"metal");
    if (!path) throw std::runtime_error("Sea.metal is missing from the app.");
    NSString* source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!source) throw failure(error, "The shader could not be read.");
    auto options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_1;
    options.mathMode = MTLMathModeFast;
    auto library = [_device newLibraryWithSource:source options:options error:&error];
    if (!library) throw failure(error, "The ocean shader failed.");
    _sea = [self pipeline:library vertex:@"fullTriangle" fragment:@"oceanLight" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _currents = [self pipeline:library vertex:@"currentVertex" fragment:@"currentLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _sheets = [self pipeline:library vertex:@"currentSheet" fragment:@"sheetLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _streaks = [self pipeline:library vertex:@"streakVertex" fragment:@"streakLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _animal = [self pipeline:library vertex:@"jellyVertex" fragment:@"jellyMembrane" format:MTLPixelFormatRGBA16Float blend:Blend::Jelly];
    _jellyComposite = [self pipeline:library vertex:@"fullTriangle" fragment:@"combineJellyLight" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _plankton = [self pipeline:library vertex:@"planktonVertex" fragment:@"planktonFragment" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _extractGlow = [self pipeline:library vertex:@"fullTriangle" fragment:@"extractGlow" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _spreadGlow = [self pipeline:library vertex:@"fullTriangle" fragment:@"spreadGlow" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _finish = [self pipeline:library vertex:@"fullTriangle" fragment:@"finish" format:MTLPixelFormatBGRA8Unorm blend:Blend::Solid];
    auto marks = [library newFunctionWithName:@"makeTrailMarks"];
    if (!marks) throw std::runtime_error("The trail marker shader is missing.");
    _markTrails = [_device newComputePipelineStateWithFunction:marks error:&error];
    if (!_markTrails) throw failure(error, "The trail marker pipeline failed.");
    const auto high = jellyIndices(giantMesh), low = jellyIndices(shoalMesh);
    _giantIndices = [device newBufferWithBytes:high.data() length:high.size()*sizeof(high[0])
                                    options:MTLResourceStorageModeShared];
    _shoalIndices = [device newBufferWithBytes:low.data() length:low.size()*sizeof(low[0])
                                    options:MTLResourceStorageModeShared];
    const auto trail = trailIndices();
    _streakIndices = [device newBufferWithBytes:trail.data() length:trail.size()*sizeof(trail[0])
                                      options:MTLResourceStorageModeShared];
    if (!_giantIndices || !_shoalIndices || !_streakIndices)
        throw std::runtime_error("Could not allocate the mesh index buffers.");
    for (unsigned i = 0; i < 3; ++i) {
        _tracerBuffers[i] = [device newBufferWithLength:planktonCount*sizeof(Tracer) options:MTLResourceStorageModeShared];
        _flowBuffers[i] = [device newBufferWithLength:routeLines*flowNodes*sizeof(FlowNode)
                                              options:MTLResourceStorageModeShared];
        _trailBuffers[i] = [device newBufferWithLength:trailActors*(trailSamples+1)*sizeof(TrailPose) options:MTLResourceStorageModeShared];
        _jellyBuffers[i] = [device newBufferWithLength:trailActors*sizeof(Jelly) options:MTLResourceStorageModeShared];
        _trailMarks[i] = [device newBufferWithLength:trailLines*(trailSamples+1)*3*sizeof(Quad)
                                            options:MTLResourceStorageModePrivate];
    }
    return self;
}
- (id<MTLCommandBuffer>)render:(id<MTLTexture>)destination ocean:(const Ocean&)ocean
                       music:(Quad)music phase:(float)phase {
    const float aspect = float(destination.width)/float(destination.height);
    const float scale = std::min(1.f,1440.f/float(destination.width));
    const auto width = std::max(1UL,NSUInteger(destination.width*scale));
    const auto height = std::max(1UL,NSUInteger(destination.height*scale));
    if (!_light || _light.width != width || _light.height != height) {
        auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                   width:width height:height mipmapped:NO];
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        _light = [_device newTextureWithDescriptor:d];
        _light.label = @"Linear ocean and membrane light";
        _waterLight = [_device newTextureWithDescriptor:d];
        _waterLight.label = @"Water light for bell refraction";
        _jellyLight = [_device newTextureWithDescriptor:d];
        _jellyLight.label = @"Weighted jellyfish membrane light";
        d.pixelFormat = MTLPixelFormatR16Float;
        _jellyTransmission = [_device newTextureWithDescriptor:d];
        _jellyTransmission.label = @"Water light transmitted through jellyfish";
        d.pixelFormat = MTLPixelFormatRGBA16Float;
        d.width = std::max(1UL,(width+2)/3);
        d.height = std::max(1UL,(height+2)/3);
        _nearGlow = [_device newTextureWithDescriptor:d];
        _nearGlow.label = @"Fine bloom around bright edges";
        d.width = std::max(1UL,(width+7)/8);
        d.height = std::max(1UL,(height+7)/8);
        _farGlow = [_device newTextureWithDescriptor:d];
        _farGlow.label = @"Soft bloom around luminous forms";
    }
    Scene scene = ocean.scene(aspect);
    scene.music = music;
    scene.call.w = phase;
    const auto shoal = ocean.shoal(scene,_visibleJellies);
    // Draws are submitted in order, with at most two frames waiting on the GPU.
    const unsigned slot = _tracerSlot++ % 3;
    const auto tracers = _tracerBuffers[slot];
    const auto field = _flowBuffers[slot];
    const auto streaks = _trailBuffers[slot];
    const auto marks = _trailMarks[slot];
    const auto jellies = _jellyBuffers[slot];
    std::memcpy(jellies.contents,shoal.data(),shoal.size()*sizeof(Jelly));
    std::memcpy(tracers.contents,ocean.tracers().data(),planktonCount*sizeof(Tracer));
    const bool opening = ocean.openingRoute();
    const auto ribbonCount = opening ? routeLines : flowLines;
    std::memcpy(field.contents,ocean.ribbons().data(),ribbonCount*flowNodes*sizeof(FlowNode));
    auto* trailBytes = static_cast<char*>(streaks.contents);
    const std::size_t historyBytes = trailActors*trailSamples*sizeof(TrailPose);
    std::memcpy(trailBytes,ocean.trailPoses().data(),ocean.trailsRecorded()*trailActors*sizeof(TrailPose));
    std::array<TrailPose,trailActors> liveTrail;
    ocean.captureTrailRow(liveTrail.data());
    std::memcpy(trailBytes+historyBytes,liveTrail.data(),sizeof(liveTrail));
    auto cmd = [_queue commandBuffer];
    TrailLayout trailLayout{
        {ocean.trailHead(),ocean.trailsRecorded(),trailSamples,trailActors},trailLifetime,trailLines,0
    };
    // Retain the neighbours needed for each live spline, even when they are too old to draw.
    for (unsigned past = 0; past < trailLayout.history[1]; ++past) {
        const auto row = (ocean.trailHead()+trailSamples-past)%trailSamples;
        const float time = past ? ocean.trailPoses()[row*trailActors].time.x : liveTrail[0].time.x;
        if (scene.screen.y-time >= trailLifetime) break;
        ++trailLayout.segments;
    }
    if (trailLayout.segments) {
        const auto samples = std::min(trailLayout.segments+1,trailLayout.history[1])+1;
        auto cache = [cmd computeCommandEncoder];
        [cache setComputePipelineState:_markTrails];
        [cache setBuffer:streaks offset:0 atIndex:0];
        [cache setBuffer:marks offset:0 atIndex:1];
        [cache setBytes:&trailLayout length:sizeof(trailLayout) atIndex:2];
        [cache dispatchThreads:MTLSizeMake(trailLines*samples,1,1)
            threadsPerThreadgroup:MTLSizeMake(_markTrails.threadExecutionWidth,1,1)];
        [cache endEncoding];
    }
    auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = _waterLight;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    auto draw = [cmd renderCommandEncoderWithDescriptor:pass];
    [draw setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setRenderPipelineState:_sea];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw setRenderPipelineState:_currents];
    const std::uint32_t nodes = flowNodes;
    [draw setVertexBuffer:field offset:0 atIndex:3];
    [draw setVertexBytes:&nodes length:sizeof(nodes) atIndex:4];
    constexpr auto ribbonVertices = (flowNodes-1)*6;
    if (opening) {
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:(routeLines-bankLines)*ribbonVertices
                      vertexCount:bankLines*ribbonVertices];
        [draw setRenderPipelineState:_sheets];
        const std::uint32_t columns = sheetColumns;
        [draw setVertexBuffer:field offset:(flowLines+guideLines)*flowNodes*sizeof(FlowNode) atIndex:3];
        [draw setVertexBytes:&columns length:sizeof(columns) atIndex:5];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:sheetLines*sheetColumns*ribbonVertices];
        [draw setRenderPipelineState:_currents];
        [draw setVertexBuffer:field offset:0 atIndex:3];
    }
    const auto luminousLines = opening ? flowLines+guideLines : flowLines;
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:luminousLines*ribbonVertices];
    if (trailLayout.segments) {
        [draw setRenderPipelineState:_streaks];
        [draw setVertexBuffer:marks offset:0 atIndex:5];
        [draw setVertexBytes:&trailLayout length:sizeof(trailLayout) atIndex:6];
        [draw drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:trailLines*trailLayout.segments*12
                          indexType:MTLIndexTypeUInt16 indexBuffer:_streakIndices indexBufferOffset:0];
    }
    [draw endEncoding];

    auto translucent = [MTLRenderPassDescriptor renderPassDescriptor];
    translucent.colorAttachments[0].texture = _jellyLight;
    translucent.colorAttachments[0].loadAction = MTLLoadActionClear;
    translucent.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
    translucent.colorAttachments[0].storeAction = MTLStoreActionStore;
    translucent.colorAttachments[1].texture = _jellyTransmission;
    translucent.colorAttachments[1].loadAction = MTLLoadActionClear;
    translucent.colorAttachments[1].clearColor = MTLClearColorMake(1,1,1,1);
    translucent.colorAttachments[1].storeAction = MTLStoreActionStore;
    draw = [cmd renderCommandEncoderWithDescriptor:translucent];
    [draw setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setRenderPipelineState:_animal];
    [draw setFragmentTexture:_waterLight atIndex:0];
    [draw setVertexBuffer:jellies offset:0 atIndex:1];
    for (NSUInteger first = 0; first < shoal.size();) {
        const bool giant = usesGiantMesh(shoal[first]);
        NSUInteger end = first+1;
        while (end < shoal.size() && usesGiantMesh(shoal[end]) == giant) ++end;
        const auto& mesh = giant ? giantMesh : shoalMesh;
        [draw setVertexBytes:&mesh length:sizeof(mesh) atIndex:7];
        [draw drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:mesh.vertices()
                          indexType:MTLIndexTypeUInt16 indexBuffer:(giant ? _giantIndices : _shoalIndices)
                   indexBufferOffset:0 instanceCount:end-first baseVertex:0 baseInstance:first];
        first = end;
    }
    [draw endEncoding];

    pass.colorAttachments[0].texture = _light;
    draw = [cmd renderCommandEncoderWithDescriptor:pass];
    [draw setRenderPipelineState:_jellyComposite];
    [draw setFragmentTexture:_waterLight atIndex:0];
    [draw setFragmentTexture:_jellyLight atIndex:1];
    [draw setFragmentTexture:_jellyTransmission atIndex:2];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setRenderPipelineState:_plankton];
    [draw setVertexBuffer:tracers offset:0 atIndex:2];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:planktonCount*6];
    [draw endEncoding];

    pass.colorAttachments[0].texture = _nearGlow;
    draw = [cmd renderCommandEncoderWithDescriptor:pass];
    [draw setRenderPipelineState:_extractGlow];
    [draw setFragmentTexture:_light atIndex:0];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];

    pass.colorAttachments[0].texture = _farGlow;
    draw = [cmd renderCommandEncoderWithDescriptor:pass];
    [draw setRenderPipelineState:_spreadGlow];
    [draw setFragmentTexture:_nearGlow atIndex:0];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];

    pass.colorAttachments[0].texture = destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    auto post = [cmd renderCommandEncoderWithDescriptor:pass];
    [post setRenderPipelineState:_finish];
    [post setFragmentTexture:_light atIndex:0];
    [post setFragmentTexture:_nearGlow atIndex:1];
    [post setFragmentTexture:_farGlow atIndex:2];
    [post setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [post drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [post endEncoding];
    return cmd;
}
@end

@interface Controls : MTKView
@property(nonatomic, copy) void (^keyChange)(NSEvent*, BOOL);
@property(nonatomic, copy) void (^motion)(CGFloat, CGFloat);
@property(nonatomic, copy) void (^clearKeys)(void);
@property(nonatomic, copy) void (^callChange)(BOOL);
@property(nonatomic, copy) void (^resumeLook)(void);
@property(nonatomic, readonly) BOOL looking;
- (void)enableLook:(BOOL)requested lockCursor:(BOOL)relative;
@end
@implementation Controls {
    BOOL _looking, _detached, _mouseCalling;
    NSTrackingArea* _mouseArea;
}
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent*)event { return YES; }
- (void)keyDown:(NSEvent*)event { if (self.keyChange) self.keyChange(event,YES); }
- (void)keyUp:(NSEvent*)event { if (self.keyChange) self.keyChange(event,NO); }
- (BOOL)resignFirstResponder {
    [self enableLook:NO lockCursor:NO];
    if (self.clearKeys) self.clearKeys();
    return [super resignFirstResponder];
}
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    if (_mouseArea) [self removeTrackingArea:_mouseArea];
    _mouseArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
        options:NSTrackingMouseMoved|NSTrackingActiveInKeyWindow|NSTrackingInVisibleRect
        owner:self userInfo:nil];
    [self addTrackingArea:_mouseArea];
}
- (BOOL)looking { return _looking; }
- (void)enableLook:(BOOL)requested lockCursor:(BOOL)relative {
    _looking = requested;
    if (!_looking) _mouseCalling = NO;
    const BOOL capture = requested && relative;
    if (capture && !_detached) {
        const NSRect frame = [self.window convertRectToScreen:[self convertRect:self.bounds toView:nil]];
        const CGFloat top = NSMaxY(NSScreen.screens.firstObject.frame);
        CGWarpMouseCursorPosition(CGPointMake(NSMidX(frame),top-NSMidY(frame)));
        _detached = CGAssociateMouseAndMouseCursorPosition(false) == kCGErrorSuccess;
        if (_detached) [NSCursor hide];
    } else if (!capture && _detached) {
        CGAssociateMouseAndMouseCursorPosition(true);
        [NSCursor unhide];
        _detached = NO;
    }
}
- (void)mouseDown:(NSEvent*)event {
    [self.window makeFirstResponder:self];
    if (!_looking) {
        [self.window makeKeyAndOrderFront:nil];
        [NSApp activate];
        if (self.resumeLook) self.resumeLook();
        return;
    }
    _mouseCalling = YES;
    if (self.callChange) self.callChange(YES);
}
- (void)mouseUp:(NSEvent*)event {
    if (_mouseCalling && self.callChange) self.callChange(NO);
    _mouseCalling = NO;
}
- (void)mouseMoved:(NSEvent*)event {
    if (_looking && self.motion) self.motion(event.deltaX,event.deltaY);
}
- (void)mouseDragged:(NSEvent*)event {
    [self mouseMoved:event];
}
@end

static void textAt(NSString* text, CGFloat x, CGFloat y, CGFloat size, CGFloat weight, CGFloat alpha) {
    [text drawAtPoint:NSMakePoint(x,y) withAttributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:size weight:weight],
        NSForegroundColorAttributeName: ink(alpha),
    }];
}
static void fill(NSRect rect, NSColor* color) { [color setFill]; NSRectFillUsingOperation(rect, NSCompositingOperationSourceOver); }
static void circle(NSPoint centre, CGFloat r, NSColor* color) {
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(centre.x-r,centre.y-r,2*r,2*r)] fill];
}

@interface HUD : NSView
@property BOOL chart, hiddenHUD, muted, mouseLooking;
@property BOOL audioUnavailable;
@property(nonatomic, copy) void (^selection)(unsigned);
@property(nonatomic, assign) Ocean* ocean;
@end
@implementation HUD
- (BOOL)isFlipped { return YES; }
- (NSView*)hitTest:(NSPoint)point { return self.chart ? [super hitTest:point] : nil; }
- (NSRect)chartPanel {
    const auto b = self.bounds;
    const CGFloat w = std::min(b.size.width-64,650.);
    const CGFloat h = 350.;
    return NSMakeRect((b.size.width-w)/2,(b.size.height-h)/2,w,h);
}
- (NSRect)chartCell:(unsigned)i {
    const NSRect panel = [self chartPanel];
    const CGFloat w = (panel.size.width-81)/2;
    return NSMakeRect(panel.origin.x+28+(i/4)*(w+24),panel.origin.y+103+(i%4)*43,w,39);
}
- (void)mouseDown:(NSEvent*)event {
    if (!self.chart || !self.selection) return;
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    for (unsigned i = 0; i < currents.size(); ++i) {
        if (!NSPointInRect(point,[self chartCell:i])) continue;
        self.selection(i);
        return;
    }
    const auto panel = [self chartPanel];
    if (NSPointInRect(point,NSMakeRect(panel.origin.x+164,panel.origin.y+293,143,41)))
        self.selection(8);
    else if (!NSPointInRect(point,panel))
        self.selection(10);
}
- (void)drawRect:(NSRect)dirty {
    auto* ocean = self.ocean;
    if (!ocean || (self.hiddenHUD && !self.chart)) return;
    const auto b = self.bounds;
    if (self.chart) {
        fill(b,[NSColor colorWithWhite:0 alpha:.43]);
        NSRect panel = [self chartPanel];
        fill(panel,[NSColor colorWithSRGBRed:.021 green:.040 blue:.064 alpha:.96]);
        [ink(.32) setStroke];
        [NSBezierPath strokeRect:NSInsetRect(panel,.5,.5)];
        const auto x = panel.origin.x+29, y = panel.origin.y;
        textAt(@"Current Atlas",x,y+24,29,NSFontWeightLight,1.);
        textAt([NSString stringWithFormat:@"%u Visited   ·   %u Solar Systems",
                ocean->visitedCount(),ocean->systemCount()],x,y+66,12,NSFontWeightMedium,.65);
        NSArray<NSColor*>* colors = @[
            [NSColor colorWithSRGBRed:.15 green:.97 blue:.82 alpha:1.],
            [NSColor colorWithSRGBRed:.63 green:.95 blue:.25 alpha:1.],
            [NSColor colorWithSRGBRed:1. green:.45 blue:.20 alpha:1.],
            [NSColor colorWithSRGBRed:1. green:.45 blue:.75 alpha:1.],
        ];
        for (unsigned i = 0; i < currents.size(); ++i) {
            const auto cell = [self chartCell:i];
            const bool active = i == ocean->featured();
            fill(NSMakeRect(cell.origin.x,cell.origin.y,cell.size.width,1),ink(active?.65:.15));
            circle(NSMakePoint(cell.origin.x+30,cell.origin.y+18),3.,colors[currents[i].palette]);
            textAt([NSString stringWithFormat:@"%u",i+1],cell.origin.x+1,cell.origin.y+11,11,NSFontWeightMedium,.61);
            textAt([NSString stringWithUTF8String:currents[i].title],cell.origin.x+44,cell.origin.y+8,16,NSFontWeightRegular,active?1.:.82);
        }
        textAt(@"1–8 / Select Current     N / Uncharted Drift     Tab / Close",
               x,y+305,12,NSFontWeightMedium,.72);
        return;
    }
    const CGFloat h = b.size.height;
    const CGFloat w = b.size.width;
    const auto title = ocean->title();
    const auto system = [NSString stringWithUTF8String:title.c_str()];
    const auto water = [NSString stringWithUTF8String:ocean->habitatName()];
    NSGradient* top = [[NSGradient alloc] initWithStartingColor:[NSColor colorWithWhite:0 alpha:.54]
                                                   endingColor:[NSColor colorWithWhite:0 alpha:0.]];
    [top drawInRect:NSMakeRect(0,0,w,115) angle:90];
    [top drawInRect:NSMakeRect(0,h-70,w,70) angle:270];
    textAt(@"Pelagic Orbits",29,23,28,NSFontWeightLight,1.);
    textAt([NSString stringWithFormat:@"%@  /  %@",system,water],30,61,12,NSFontWeightMedium,.77);
    if (ocean->demo || ocean->paused || ocean->migrating() || self.muted || !self.mouseLooking) {
        NSString* state = ocean->paused ? @"Paused" : ocean->migrating() ? @"Changing Current" :
                          ocean->demo ? @"Free Drift" : !self.mouseLooking ? @"Click to Look" : @"Muted";
        textAt(state,w-138,28,12,NSFontWeightMedium,.88);
    }
    if (self.audioUnavailable) textAt(@"Audio Unavailable",w-138,50,12,NSFontWeightMedium,.8);
    NSMutableArray<NSString*>* notices = [NSMutableArray array];
    switch (ocean->localWater()) {
        case WaterKind::Open: break;
        case WaterKind::Stream: [notices addObject:ocean->demo ? @"In the Stream" : @"In the Stream · Release to Drift"]; break;
        case WaterKind::Eddy: [notices addObject:@"Eddy"]; break;
        case WaterKind::Still: [notices addObject:@"Still Water"]; break;
        case WaterKind::Wake: [notices addObject:@"In the Giant’s Wake"]; break;
    }
    const float charge = ocean->callCharge();
    if (charge > .02f) [notices addObject:charge >= .999f ? @"Release to Call" : @"Drawing a Call"];
    else switch (ocean->encounter()) {
        case Encounter::Calling: [notices addObject:@"Call Travelling"]; break;
        case Encounter::Approaching: [notices addObject:@"A Crown Answers"]; break;
        case Encounter::Alongside: [notices addObject:@"Crown Alongside"]; break;
        case Encounter::None:
            if (ocean->echoes() && !ocean->drawnCall()) {
                const auto count = ocean->echoes();
                [notices addObject:[NSString stringWithFormat:@"%u %@",count,count==1?@"Echo":@"Echoes"]];
            } else if (ocean->openingRoute() && !ocean->demo && ocean->crownInRange()) {
                [notices addObject:@"Hold F to Call"];
            }
            break;
    }
    if (ocean->inStep() >= 3) [notices addObject:@"Shoals In Step"];
    if (notices.count) {
        circle(NSMakePoint(33,h-58),3.0,[NSColor colorWithSRGBRed:.22 green:1 blue:.82 alpha:.82]);
        textAt([notices componentsJoinedByString:@"   ·   "],45,h-65,12,NSFontWeightMedium,.89);
    }
    textAt(@"Arrows / Swim    Mouse / Look    F / Tap Pulse · Hold Call    N / Next    Tab / Atlas",30,h-35,12,NSFontWeightMedium,.79);
    textAt(@"Esc / Cursor    D / Drift    H / Hide",w-197,h-35,11,NSFontWeightMedium,.73);
}
@end

@interface Game : NSObject <NSApplicationDelegate, MTKViewDelegate, NSWindowDelegate>
- (void)toggleMusicResponse:(id)sender;
- (void)toggleMute:(id)sender;
@end
@implementation Game {
    NSWindow* _window;
    Controls* _view;
    HUD* _hud;
    Renderer* _renderer;
    std::unique_ptr<Ocean> _ocean;
    std::unique_ptr<Score> _score;
    AVAudioEngine* _audio;
    AVAudioSourceNode* _source;
    std::array<bool,128> _pressed;
    dispatch_semaphore_t _inFlight;
    double _last, _hudAt, _soundAt;
    double _musicAt, _musicPhase;
    std::uint64_t _musicSnapshot;
    Quad _music;
    float _panX, _panY;
    unsigned _lastCallNumber, _callInput;
    BOOL _lookRequested, _musicResponse;
}

- (void)stopAudio {
    [_audio stop];
    if (_source) [_audio detachNode:_source];
    _source = nil;
    _audio = nil;
    if (_score) _score->stop();
    _score.reset();
}

- (void)startAudio {
    try {
        _score = std::make_unique<Score>();
        NSString* assets = NSBundle.mainBundle.resourcePath;
        NSString* runtime = [assets stringByAppendingPathComponent:@"supercollider"];
        NSString* definitions = [assets stringByAppendingPathComponent:@"synthdefs"];
        _score->start(runtime.fileSystemRepresentation,definitions.fileSystemRepresentation);
        Score* score = _score.get();
        _audio = [AVAudioEngine new];
        auto format = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:Score::sampleRate channels:2];
        _source = [[AVAudioSourceNode alloc] initWithFormat:format
            renderBlock:^OSStatus(BOOL* silent, const AudioTimeStamp*, AVAudioFrameCount frames, AudioBufferList* buffers) {
                if (buffers->mNumberBuffers != 2 || !buffers->mBuffers[0].mData || !buffers->mBuffers[1].mData) {
                    *silent = YES;
                    return noErr;
                }
                *silent = NO;
                score->render(static_cast<float*>(buffers->mBuffers[0].mData),
                              static_cast<float*>(buffers->mBuffers[1].mData),frames);
                return noErr;
            }];
        [_audio attachNode:_source];
        [_audio connect:_source to:_audio.mainMixerNode format:format];
        NSError* audioError = nil;
        if (![_audio startAndReturnError:&audioError]) throw failure(audioError,"Could not open audio output.");
    } catch (const std::exception& error) {
        [self stopAudio];
        NSLog(@"SuperCollider audio unavailable: %@",message(error));
    }
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    try {
        _ocean = std::make_unique<Ocean>(resource(@"orbits",@"txt").fileSystemRepresentation);
        auto device = MTLCreateSystemDefaultDevice();
        _renderer = [[Renderer alloc] initWithDevice:device];
        _inFlight = dispatch_semaphore_create(2);
        _musicResponse = YES;
        [self startAudio];

        _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1120,735)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
            backing:NSBackingStoreBuffered defer:NO];
        _window.title = @"Pelagic Orbits";
        _window.minSize = NSMakeSize(730,505);
        _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        _window.delegate = self;
        _window.acceptsMouseMovedEvents = YES;
        _view = [[Controls alloc] initWithFrame:_window.contentView.bounds device:device];
        _view.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _view.preferredFramesPerSecond = 60;
        _view.delegate = self;
        _hud = [[HUD alloc] initWithFrame:_view.bounds];
        _hud.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _hud.ocean = _ocean.get();
        _hud.audioUnavailable = !_score;
        [_view addSubview:_hud];
        _window.contentView = _view;
        __weak Game* weak = self;
        _view.keyChange = ^(NSEvent* e,BOOL down) { [weak keyboard:e down:down]; };
        _view.motion = ^(CGFloat x,CGFloat y) { [weak panX:x y:y]; };
        _view.clearKeys = ^{ [weak clear]; };
        _view.callChange = ^(BOOL down) { [weak callInput:2 down:down]; };
        _view.resumeLook = ^{ [weak setMouseLook:YES]; };
        _hud.selection = ^(unsigned i) { [weak select:i]; };
        [_window center];
        [_window makeKeyAndOrderFront:nil];
        [_window makeFirstResponder:_view];
        [NSApp activate];
        dispatch_async(dispatch_get_main_queue(), ^{ [weak setMouseLook:YES]; });
    } catch (const std::exception& error) {
        NSAlert* alert = [NSAlert new];
        alert.messageText = @"Pelagic Orbits could not start";
        alert.informativeText = message(error);
        [alert runModal];
        [NSApp terminate:nil];
    }
}
- (void)toggleMusicResponse:(id)sender {
    _musicResponse = !_musicResponse;
}
- (void)toggleMute:(id)sender {
    if (!_score) return;
    _hud.muted = !_hud.muted;
    _score->mute(_hud.muted);
    _hud.needsDisplay = YES;
}
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(toggleMusicResponse:))
        item.state = _musicResponse ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(toggleMute:))
        item.state = _hud.muted ? NSControlStateValueOn : NSControlStateValueOff;
    return bool(_score);
}
- (void)callInput:(unsigned)source down:(BOOL)down {
    if (down) {
        if (!_hud.chart && !_callInput && _ocean->beginCall()) _callInput = source;
        return;
    }
    if (_callInput != source) return;
    _callInput = 0;
    _ocean->releaseCall();
    _hud.needsDisplay = YES;
}
- (void)clear {
    _pressed.fill(false);
    _panX = 0; _panY = 0;
    _callInput = 0;
    if (_ocean) _ocean->cancelCall();
}
- (void)setMouseLook:(BOOL)on {
    _lookRequested = on;
    if (!on) [self clear];
    [self updateMouseLook];
}
- (void)updateMouseLook {
    const BOOL looking = _lookRequested && _ocean && !_hud.chart && !_ocean->paused;
    [_view enableLook:looking lockCursor:_window.isKeyWindow && NSApp.isActive];
    _hud.mouseLooking = _view.looking;
    _hud.needsDisplay = YES;
}
- (void)panX:(CGFloat)x y:(CGFloat)y {
    if (!_view.looking) return;
    _panX += std::clamp(float(x),-102.f,102.f)*.0035f;
    _panY -= std::clamp(float(y),-102.f,102.f)*.0035f;
}
- (void)select:(unsigned)i {
    [self clear];
    if (i <= currents.size()) {
        _ocean->paused = false;
        if (i == currents.size()) _ocean->uncharted();
        else _ocean->voyage(i);
    }
    _hud.chart = NO;
    [self setMouseLook:YES];
    _hud.needsDisplay = YES;
}
- (void)keyboard:(NSEvent*)event down:(BOOL)down {
    const auto code = event.keyCode;
    if (code < _pressed.size()) _pressed[code] = down;
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if ([key isEqualToString:@"f"]) {
        if (!event.isARepeat) [self callInput:1 down:down];
        return;
    }
    if (!down || event.isARepeat) return;
    if (code == 48) {
        _hud.chart = !_hud.chart;
        [self clear];
        [self setMouseLook:!_hud.chart];
    } else if (code == 53) {
        if (_hud.chart) _hud.chart = NO;
        [self setMouseLook:NO];
    } else if (key.length == 1) {
        const unichar c = [key characterAtIndex:0];
        if (c >= '1' && c <= '8') [self select:c-'1'];
        if (c == ' ') {
            [self clear];
            _ocean->paused = !_ocean->paused;
            [self setMouseLook:!_ocean->paused];
        }
        if (c == 'h') _hud.hiddenHUD = !_hud.hiddenHUD;
        if (c == 'd') {
            _ocean->demo = !_ocean->demo;
            if (_ocean->demo) {
                _ocean->paused = false;
                [self setMouseLook:NO];
            }
        }
        if (c == 'm') [self toggleMute:nil];
        if (c == 'n' || c == '\r') {
            [self clear];
            const bool chart = _hud.chart;
            _hud.chart = NO;
            _ocean->paused = false;
            if (chart) _ocean->uncharted();
            else _ocean->next();
            if (chart) [self setMouseLook:YES];
        }
    }
    _hud.needsDisplay = YES;
}
- (void)windowDidBecomeKey:(NSNotification*)note { [self updateMouseLook]; }
- (void)applicationDidBecomeActive:(NSNotification*)note { [self updateMouseLook]; }
- (void)windowDidResignKey:(NSNotification*)note { [self clear]; [self updateMouseLook]; }
- (void)applicationDidResignActive:(NSNotification*)note { [self clear]; [self updateMouseLook]; }
- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication*)sender { return YES; }
- (void)applicationWillTerminate:(NSNotification*)notification {
    [self setMouseLook:NO];
    _view.paused = YES;
    [self stopAudio];
}
- (void)mtkView:(MTKView*)view drawableSizeWillChange:(CGSize)size {}
- (void)updateMusic:(float)dt now:(double)now {
    const auto snapshot = _score ? _score->spectrum() : 0u;
    if (snapshot != _musicSnapshot) {
        _musicSnapshot = snapshot;
        _musicAt = now;
    }
    if (_hud.chart || _ocean->paused) return;
    const Quad target = _musicResponse && now-_musicAt < .16 ? Spectrum::features(snapshot) : Quad{};
    const auto smooth = [dt](float value,float incoming,float attack,float release) {
        incoming *= .76f;
        return value+(incoming-value)*(1.f-std::exp(-dt/(incoming > value ? attack : release)));
    };
    _music.x = smooth(_music.x,target.x,.11f,.49f);
    _music.y = smooth(_music.y,target.y,.07f,.32f);
    _music.z = smooth(_music.z,target.z,.033f,.21f);
    _music.w = smooth(_music.w,target.w,.023f,.23f);
    _musicPhase += dt*(1.85f*_music.x+1.1f*_music.y+.85f*_music.w);
}
- (void)drawInMTKView:(MTKView*)view {
    const double now = CACurrentMediaTime();
    const float dt = _last > 0 ? float(now-_last) : 1.f/60.f;
    _last = now;
    if (!_hud.chart && !_ocean->paused) {
        const float x = float(_pressed[124])-float(_pressed[123]);
        const float y = float(_pressed[14])-float(_pressed[12]);
        const float z = float(_pressed[126] || _pressed[13])-float(_pressed[125] || _pressed[1]);
        const float lookX = float(_pressed[37])-float(_pressed[38]);
        const float lookY = float(_pressed[34])-float(_pressed[40]);
        _ocean->step(dt,{x,y,z},_panX+dt*lookX*.85f,_panY+dt*lookY*.70f);
    }
    _panX = 0; _panY = 0;
    [self updateMusic:std::min(dt,.1f) now:now];
    if (_score && now-_soundAt > .045) {
        _score->update(_ocean->look(),_ocean->waterAt(_ocean->position()),_ocean->callCharge(),_ocean->basinAmount());
        _soundAt = now;
    }
    const auto replies = _ocean->takeReplies();
    if (_score) {
        if (_ocean->calls() != _lastCallNumber) _score->pulse(_ocean->drawnCall());
        if (!replies.empty()) {
            const auto view = _ocean->scene(1.f);
            const Vec right{view.right.x,view.right.y,view.right.z};
            const Vec forward{view.forward.x,view.forward.y,view.forward.z};
            for (const auto& reply : replies) _score->echo(reply,_ocean->position(),right,forward);
        }
    }
    _lastCallNumber = _ocean->calls();
    if (now-_hudAt > .12) {
        _hud.needsDisplay = YES;
        _hudAt = now;
    }
    if (dispatch_semaphore_wait(_inFlight,DISPATCH_TIME_NOW)) return;
    auto drawable = view.currentDrawable;
    if (!drawable) {
        dispatch_semaphore_signal(_inFlight);
        return;
    }
    auto cmd = [_renderer render:drawable.texture ocean:*_ocean music:_music phase:float(_musicPhase)];
    [cmd presentDrawable:drawable];
    dispatch_semaphore_t inflight = _inFlight;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> completed) { dispatch_semaphore_signal(inflight); }];
    [cmd commit];
}
@end

static void capture(NSString* filename, unsigned system, unsigned frames) {
    Ocean ocean(resource(@"orbits",@"txt").fileSystemRepresentation);
    if (system != 0) {
        ocean.voyage(system);
        for (unsigned i = 0; i < 175; ++i) ocean.step(1.f/60.f,{},0,0);
    }
    for (unsigned i = 0; i < frames; ++i) {
        if (frames > 90 && i == frames-85) ocean.pulse();
        ocean.step(1.f/60.f,{},0,0);
    }
    auto device = MTLCreateSystemDefaultDevice();
    auto renderer = [[Renderer alloc] initWithDevice:device];
    constexpr NSUInteger width = 1440, height = 900;
    auto info = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                    width:width height:height mipmapped:NO];
    info.storageMode = MTLStorageModeShared;
    info.usage = MTLTextureUsageRenderTarget;
    auto texture = [device newTextureWithDescriptor:info];
    auto cmd = [renderer render:texture ocean:ocean music:Quad{} phase:0.f];
    [cmd commit];
    [cmd waitUntilCompleted];
    if (cmd.error) throw std::runtime_error(cmd.error.localizedDescription.UTF8String);
    std::vector<std::uint8_t> pixels(width*height*4);
    [texture getBytes:pixels.data() bytesPerRow:width*4 fromRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:0];
    auto bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:nil pixelsWide:width pixelsHigh:height
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace
        bitmapFormat:NSBitmapFormatAlphaNonpremultiplied bytesPerRow:width*4 bitsPerPixel:32];
    for (NSUInteger i = 0; i < pixels.size(); i += 4) {
        bitmap.bitmapData[i] = pixels[i+2];
        bitmap.bitmapData[i+1] = pixels[i+1];
        bitmap.bitmapData[i+2] = pixels[i];
        bitmap.bitmapData[i+3] = 255;
    }
    if (![[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:filename atomically:YES])
        throw std::runtime_error("Could not save the capture.");
}

int main(int argc, const char** argv) {
    @autoreleasepool {
        if (argc > 2 && std::string_view(argv[1]) == "--capture") {
            try {
                const unsigned system = argc > 3 ? std::strtoul(argv[3],nullptr,10) : 0;
                const unsigned frames = argc > 4 ? std::strtoul(argv[4],nullptr,10) : 32;
                capture([NSString stringWithUTF8String:argv[2]],system,frames);
                return 0;
            } catch (const std::exception& error) {
                std::cerr << error.what() << '\n';
                return 1;
            }
        }
        [NSApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
        NSMenu* main = [NSMenu new];
        NSMenuItem* root = [NSMenuItem new];
        [main addItem:root];
        NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Pelagic Orbits"];
        [appMenu addItemWithTitle:@"Quit Pelagic Orbits" action:@selector(terminate:) keyEquivalent:@"q"];
        root.submenu = appMenu;
        Game* game = [Game new];
        NSMenu* music = [[NSMenu alloc] initWithTitle:@"Music"];
        [music addItemWithTitle:@"Mute Audio" action:@selector(toggleMute:) keyEquivalent:@""].target = game;
        [music addItemWithTitle:@"Music-Reactive Ocean" action:@selector(toggleMusicResponse:) keyEquivalent:@""].target = game;
        NSMenuItem* musicItem = [[NSMenuItem alloc] initWithTitle:@"Music" action:nil keyEquivalent:@""];
        musicItem.submenu = music;
        [main addItem:musicItem];
        NSApp.mainMenu = main;
        NSApp.delegate = game;
        [NSApp run];
        NSApp.delegate = nil;
    }
    return 0;
}
