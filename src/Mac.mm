#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#include "Sea.hpp"
#include "Score.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <limits>
#include <memory>
#include <stdexcept>

using namespace pelagic;

static_assert(sizeof(Planet) == 64);
static_assert(sizeof(BellSystem) == 272);
static_assert(sizeof(Scene) == 816);
static_assert(sizeof(Jelly) == 96);
static_assert(sizeof(Tracer) == 48);
static_assert(sizeof(FlowNode) == 32);
static_assert(sizeof(TrailPose) == 112);
struct alignas(16) TrailLayout {
    std::array<std::uint32_t,4> history;
    float lifetime;
    std::uint32_t lines, segments;
};
static_assert(sizeof(TrailLayout) == 32);
struct JellyMesh {
    static constexpr std::uint32_t rootRows = 4, rootColumns = 3;
    std::uint32_t steps, strands, sides, slices;
    constexpr NSUInteger tentacleIndices() const {
        return 6*((strands+8*3)*steps+(strands-8)*rootRows*(rootColumns-1));
    }
    constexpr NSUInteger vertices() const {
        const auto bell = sides*(slices+slices/3);
        const auto anatomy = 4*8*(sides/3);
        return tentacleIndices()+(bell+anatomy)*6;
    }
};
constexpr JellyMesh giantMesh{43,33,100,31};
constexpr JellyMesh shoalMesh{24,33,56,19};
constexpr JellyMesh colossalMesh{56,33,288,96};
constexpr JellyMesh compactColossalMesh{56,33,156,60};
constexpr JellyMesh ultraColossalMesh{68,38,360,128};
constexpr JellyMesh ultraGiantMesh{60,38,144,52};
static_assert(giantMesh.vertices() < UINT16_MAX && shoalMesh.vertices() < UINT16_MAX);
static_assert(colossalMesh.sides%4 == 0 && colossalMesh.slices%4 == 0);

template<class Index>
static std::vector<Index> jellyIndices(const JellyMesh& mesh) {
    // Index each grid using the same vertex IDs the procedural shader already expects.
    constexpr unsigned dx[] = {0,1,1,0,1,0};
    constexpr unsigned dy[] = {0,0,1,0,1,1};
    constexpr auto empty = std::numeric_limits<Index>::max();
    std::vector<Index> indices;
    indices.reserve(mesh.vertices());
    auto grid = [&](unsigned columns,unsigned rows) {
        std::vector<Index> corners((columns+1)*(rows+1),empty);
        for (unsigned y = 0; y < rows; ++y)
            for (unsigned x = 0; x < columns; ++x)
                for (unsigned k = 0; k < 6; ++k) {
                    auto& index = corners[(y+dy[k])*(columns+1)+x+dx[k]];
                    if (index == empty) index = Index(indices.size());
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

constexpr unsigned fullRenderWidth = 1440;

struct RenderResolution {
    static constexpr std::array<unsigned,7> widths{640,768,896,1024,1152,1280,fullRenderWidth};
    std::size_t tier{2};
    double frameMilliseconds{};
    unsigned measuredFrames{};

    unsigned width() const { return widths[tier]; }

    void observe(unsigned sampleWidth, double milliseconds) {
        if (sampleWidth != width() || milliseconds <= 0.) return;
        frameMilliseconds = measuredFrames ? std::lerp(frameMilliseconds,milliseconds,.18) : milliseconds;
        measuredFrames = std::min(measuredFrames+1,36u);
        auto next = tier;
        // Reduce the cost promptly. Require spare GPU time across more frames before increasing it.
        if (measuredFrames >= 8 && frameMilliseconds > 33. && tier > 0) --next;
        else if (measuredFrames >= 36 && frameMilliseconds < 21.5 && tier+1 < widths.size()) ++next;
        if (next != tier) {
            tier = next;
            measuredFrames = 0;
        }
    }
};

static const JellyMesh& meshFor(const Jelly& jelly, bool compact, bool ultra) {
    if (jelly.membraneAnchor > 0.f && jelly.position.w > 40.f)
        return ultra ? ultraColossalMesh : compact ? compactColossalMesh : colossalMesh;
    if (jelly.flow.z > 0.f || jelly.position.w > 4.f)
        return ultra ? ultraGiantMesh : giantMesh;
    return shoalMesh;
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
- (id<MTLCommandBuffer>)render:(id<MTLTexture>)destination ocean:(Ocean&)ocean
                       music:(Quad)music phase:(float)phase style:(GraphicsStyle)style exterior:(bool)exterior
                    maxWidth:(unsigned)maxWidth;
@end

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _sea, _currents, _sheets, _streaks, _animal, _exteriorAnimal;
    id<MTLRenderPipelineState> _copyWater, _jellyComposite, _plankton, _bloom, _finish, _upscale;
    id<MTLTexture> _light, _waterLight, _jellyLight, _jellyTransmission, _graded;
    id<MTLTexture> _exteriorLight, _exteriorTransmission;
    id<MTLRenderPipelineState> _extractGlow, _spreadGlow;
    id<MTLComputePipelineState> _markTrails;
    id<MTLTexture> _nearGlow, _farGlow;
    id<MTLBuffer> _tracerBuffers[3];
    id<MTLBuffer> _flowBuffers[3];
    id<MTLBuffer> _trailBuffers[3];
    id<MTLBuffer> _jellyBuffers[3];
    id<MTLBuffer> _bellSystems[3];
    id<MTLBuffer> _trailMarks[3];
    id<MTLBuffer> _colossalIndices, _compactColossalIndices, _giantIndices, _shoalIndices, _streakIndices;
    id<MTLBuffer> _ultraColossalIndices, _ultraGiantIndices;
    std::array<Jelly,trailActors> _visibleJellies;
    unsigned _tracerSlot;
}

- (id<MTLRenderPipelineState>)pipeline:(id<MTLLibrary>)library vertex:(NSString*)vertex
                             fragment:(NSString*)fragment format:(MTLPixelFormat)format blend:(Blend)blend
                               samples:(NSUInteger)samples {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.label = fragment;
    d.vertexFunction = [library newFunctionWithName:vertex];
    d.fragmentFunction = [library newFunctionWithName:fragment];
    d.rasterSampleCount = samples;
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
        transmission.pixelFormat = MTLPixelFormatRG16Float;
        transmission.blendingEnabled = YES;
        transmission.sourceRGBBlendFactor = MTLBlendFactorZero;
        transmission.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceColor;
    }
    NSError* error = nil;
    auto result = [_device newRenderPipelineStateWithDescriptor:d error:&error];
    if (!result) throw failure(error, "A Metal pipeline failed.");
    return result;
}

- (id<MTLRenderPipelineState>)pipeline:(id<MTLLibrary>)library vertex:(NSString*)vertex
                             fragment:(NSString*)fragment format:(MTLPixelFormat)format blend:(Blend)blend {
    return [self pipeline:library vertex:vertex fragment:fragment format:format blend:blend samples:1];
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
    if ([device supportsTextureSampleCount:4])
        _exteriorAnimal = [self pipeline:library vertex:@"jellyVertex" fragment:@"jellyMembrane"
                                   format:MTLPixelFormatRGBA16Float blend:Blend::Jelly samples:4];
    _copyWater = [self pipeline:library vertex:@"fullTriangle" fragment:@"copyWaterLight" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _jellyComposite = [self pipeline:library vertex:@"fullTriangle" fragment:@"combineJellyLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _plankton = [self pipeline:library vertex:@"planktonVertex" fragment:@"planktonFragment" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _bloom = [self pipeline:library vertex:@"bloomVertex" fragment:@"planktonFragment" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _extractGlow = [self pipeline:library vertex:@"fullTriangle" fragment:@"extractGlow" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _spreadGlow = [self pipeline:library vertex:@"fullTriangle" fragment:@"spreadGlow" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _finish = [self pipeline:library vertex:@"fullTriangle" fragment:@"finish" format:MTLPixelFormatBGRA8Unorm blend:Blend::Solid];
    _upscale = [self pipeline:library vertex:@"fullTriangle" fragment:@"upscaleFrame" format:MTLPixelFormatBGRA8Unorm blend:Blend::Solid];
    auto marks = [library newFunctionWithName:@"makeTrailMarks"];
    if (!marks) throw std::runtime_error("The trail marker shader is missing.");
    _markTrails = [_device newComputePipelineStateWithFunction:marks error:&error];
    if (!_markTrails) throw failure(error, "The trail marker pipeline failed.");
    const auto high = jellyIndices<std::uint16_t>(giantMesh), low = jellyIndices<std::uint16_t>(shoalMesh);
    const auto colossal = jellyIndices<std::uint32_t>(colossalMesh);
    const auto compact = jellyIndices<std::uint32_t>(compactColossalMesh);
    const auto ultraColossal = jellyIndices<std::uint32_t>(ultraColossalMesh);
    const auto ultraGiant = jellyIndices<std::uint32_t>(ultraGiantMesh);
    _colossalIndices = [device newBufferWithBytes:colossal.data() length:colossal.size()*sizeof(colossal[0])
                                        options:MTLResourceStorageModeShared];
    _compactColossalIndices = [device newBufferWithBytes:compact.data() length:compact.size()*sizeof(compact[0])
                                               options:MTLResourceStorageModeShared];
    _ultraColossalIndices = [device newBufferWithBytes:ultraColossal.data() length:ultraColossal.size()*sizeof(ultraColossal[0])
                                             options:MTLResourceStorageModeShared];
    _ultraGiantIndices = [device newBufferWithBytes:ultraGiant.data() length:ultraGiant.size()*sizeof(ultraGiant[0])
                                          options:MTLResourceStorageModeShared];
    _giantIndices = [device newBufferWithBytes:high.data() length:high.size()*sizeof(high[0])
                                    options:MTLResourceStorageModeShared];
    _shoalIndices = [device newBufferWithBytes:low.data() length:low.size()*sizeof(low[0])
                                    options:MTLResourceStorageModeShared];
    const auto trail = trailIndices();
    _streakIndices = [device newBufferWithBytes:trail.data() length:trail.size()*sizeof(trail[0])
                                      options:MTLResourceStorageModeShared];
    if (!_colossalIndices || !_compactColossalIndices || !_giantIndices || !_shoalIndices || !_streakIndices ||
        !_ultraColossalIndices || !_ultraGiantIndices)
        throw std::runtime_error("Could not allocate the mesh index buffers.");
    for (unsigned i = 0; i < 3; ++i) {
        _bellSystems[i] = [device newBufferWithLength:bellSystemCount*sizeof(BellSystem)
                                                options:MTLResourceStorageModeShared];
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
- (id<MTLCommandBuffer>)render:(id<MTLTexture>)destination ocean:(Ocean&)ocean
                       music:(Quad)music phase:(float)phase style:(GraphicsStyle)style exterior:(bool)exterior
                    maxWidth:(unsigned)maxWidth {
    const float aspect = float(destination.width)/float(destination.height);
    const bool ultra = style == GraphicsStyle::Ultra;
    const float scale = ultra ? 1.f : std::min(1.f,float(maxWidth)/float(destination.width));
    const auto width = std::max(1UL,NSUInteger(destination.width*scale));
    const auto height = std::max(1UL,NSUInteger(destination.height*scale));
    const bool upscale = maxWidth < fullRenderWidth && width < destination.width;
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
        d.pixelFormat = MTLPixelFormatRG16Float;
        _jellyTransmission = [_device newTextureWithDescriptor:d];
        _jellyTransmission.label = @"Membrane and current transmission";
        _exteriorLight = nil;
        _exteriorTransmission = nil;
        d.pixelFormat = MTLPixelFormatRGBA16Float;
        d.width = std::max(1UL,(width+2)/3);
        d.height = std::max(1UL,(height+2)/3);
        _nearGlow = [_device newTextureWithDescriptor:d];
        _nearGlow.label = @"Fine bloom around bright edges";
        d.width = std::max(1UL,(width+7)/8);
        d.height = std::max(1UL,(height+7)/8);
        _farGlow = [_device newTextureWithDescriptor:d];
        _farGlow.label = @"Soft bloom around luminous forms";
        _graded = nil;
    }
    if (upscale && !_graded) {
        auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                   width:width height:height mipmapped:NO];
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        _graded = [_device newTextureWithDescriptor:d];
    }
    const bool antialias = exterior || ultra;
    if (antialias && _exteriorAnimal && !_exteriorLight) {
        // Keep samples in tile memory and resolve into the regular compositing textures.
        auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_jellyLight.pixelFormat
                                                                   width:width height:height mipmapped:NO];
        d.textureType = MTLTextureType2DMultisample;
        d.sampleCount = 4;
        d.storageMode = MTLStorageModeMemoryless;
        d.usage = MTLTextureUsageRenderTarget;
        _exteriorLight = [_device newTextureWithDescriptor:d];
        d.pixelFormat = _jellyTransmission.pixelFormat;
        _exteriorTransmission = [_device newTextureWithDescriptor:d];
    }
    const bool multisample = antialias && _exteriorLight && _exteriorTransmission;
    Scene scene = ocean.scene(aspect,exterior);
    // Orbital silhouettes and ring detail use the same filter as the render scale changes.
    const float referenceHeight = ultra ? float(height) : std::min(float(destination.height),768.f/aspect);
    scene.orbitalPixel = 2.f/(1.94f*referenceHeight);
    scene.music = music;
    scene.call.w = phase;
    scene.graphicsStyle = exterior && !ultra ? GraphicsStyle::Original : style;
    const auto shoal = exterior ? std::span<const Jelly>{} : ocean.shoal(scene,_visibleJellies);
    // Draws are submitted in order, with at most two frames waiting on the GPU.
    const unsigned slot = _tracerSlot++ % 3;
    const auto systems = _bellSystems[slot];
    std::uint64_t visibleSystems = exterior ? 1 : (std::uint64_t{1} << (1+bellPassageCount))-1;
    if (scene.playerSystem > 0.f)
        visibleSystems |= std::uint64_t{1} << (unsigned(scene.playerSystem)-1);
    for (const auto& jelly : shoal) {
        if (jelly.bellSystem > 0.f && jelly.bellSystemVisibility > 0.f)
            visibleSystems |= std::uint64_t{1} << (unsigned(jelly.bellSystem)-1);
    }
    ocean.writeBellSystems(
        std::span<BellSystem,bellSystemCount>(static_cast<BellSystem*>(systems.contents),bellSystemCount),
        visibleSystems);
    const auto tracers = _tracerBuffers[slot];
    const auto field = _flowBuffers[slot];
    const auto streaks = _trailBuffers[slot];
    const auto marks = _trailMarks[slot];
    const auto jellies = _jellyBuffers[slot];
    const bool opening = ocean.openingRoute();
    const bool movingWater = !exterior && scene.cycle.z < 1.f && scene.basinArrival > 0.f;
    auto cmd = [_queue commandBuffer];
    TrailLayout trailLayout{
        {ocean.trailHead(),ocean.trailsRecorded(),trailSamples,trailActors},trailLifetime,trailLines,0
    };
    if (movingWater) {
        std::memcpy(jellies.contents,shoal.data(),shoal.size()*sizeof(Jelly));
        std::memcpy(tracers.contents,ocean.tracers().data(),planktonCount*sizeof(Tracer));
        const auto ribbonCount = opening ? routeLines : flowLines;
        std::memcpy(field.contents,ocean.ribbons().data(),ribbonCount*flowNodes*sizeof(FlowNode));
        auto* trailBytes = static_cast<char*>(streaks.contents);
        const std::size_t historyBytes = trailActors*trailSamples*sizeof(TrailPose);
        std::memcpy(trailBytes,ocean.trailPoses().data(),ocean.trailsRecorded()*trailActors*sizeof(TrailPose));
        std::array<TrailPose,trailActors> liveTrail;
        ocean.captureTrailRow(liveTrail.data());
        std::memcpy(trailBytes+historyBytes,liveTrail.data(),sizeof(liveTrail));
        // Retain the neighbours needed for each live spline, even when they are too old to draw.
        for (unsigned past = 0; past < trailLayout.history[1]; ++past) {
            const auto row = (ocean.trailHead()+trailSamples-past)%trailSamples;
            const float time = past ? ocean.trailPoses()[row*trailActors].time.x : liveTrail[0].time.x;
            if (scene.screen.y-time >= trailLifetime) break;
            ++trailLayout.segments;
        }
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
    [draw setFragmentBuffer:systems offset:0 atIndex:1];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (trailLayout.segments) {
        [draw setRenderPipelineState:_streaks];
        [draw setVertexBuffer:marks offset:0 atIndex:5];
        [draw setVertexBytes:&trailLayout length:sizeof(trailLayout) atIndex:6];
        [draw drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:trailLines*trailLayout.segments*12
                          indexType:MTLIndexTypeUInt16 indexBuffer:_streakIndices indexBufferOffset:0];
    }
    [draw endEncoding];

    auto translucent = [MTLRenderPassDescriptor renderPassDescriptor];
    translucent.colorAttachments[0].texture = multisample ? _exteriorLight : _jellyLight;
    translucent.colorAttachments[0].loadAction = MTLLoadActionClear;
    translucent.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
    translucent.colorAttachments[0].storeAction = multisample ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
    translucent.colorAttachments[1].texture = multisample ? _exteriorTransmission : _jellyTransmission;
    translucent.colorAttachments[1].loadAction = MTLLoadActionClear;
    translucent.colorAttachments[1].clearColor = MTLClearColorMake(1,1,1,1);
    translucent.colorAttachments[1].storeAction = translucent.colorAttachments[0].storeAction;
    if (multisample) {
        translucent.colorAttachments[0].resolveTexture = _jellyLight;
        translucent.colorAttachments[1].resolveTexture = _jellyTransmission;
    }
    draw = [cmd renderCommandEncoderWithDescriptor:translucent];
    [draw setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setRenderPipelineState:multisample ? _exteriorAnimal : _animal];
    [draw setFragmentBuffer:systems offset:0 atIndex:1];
    [draw setFragmentTexture:_waterLight atIndex:0];
    [draw setVertexBuffer:jellies offset:0 atIndex:1];
    const bool compact = maxWidth <= 1024;
    for (NSUInteger first = 0; first < shoal.size();) {
        const auto& mesh = meshFor(shoal[first],compact,ultra);
        NSUInteger end = first+1;
        while (end < shoal.size() && &meshFor(shoal[end],compact,ultra) == &mesh) ++end;
        const bool colossal = &mesh == &colossalMesh || &mesh == &compactColossalMesh;
        const bool dense = &mesh == &ultraColossalMesh || &mesh == &ultraGiantMesh;
        const auto indices = dense ? (&mesh == &ultraColossalMesh ? _ultraColossalIndices : _ultraGiantIndices) :
                             colossal ? (compact ? _compactColossalIndices : _colossalIndices) :
                             &mesh == &giantMesh ? _giantIndices : _shoalIndices;
        [draw setVertexBytes:&mesh length:sizeof(mesh) atIndex:7];
        [draw drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:mesh.vertices()
                          indexType:(colossal || dense ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16) indexBuffer:indices
                   indexBufferOffset:0 instanceCount:end-first baseVertex:0 baseInstance:first];
        first = end;
    }
    const float exteriorBell = scene.enclosingShape.w*(1.f-scene.enclosingSky);
    if (exteriorBell > 0.f) {
        const Jelly enclosing{.position=scene.enclosingBell,.pigment={.54f,scene.celestialTime*.266f+.51f,0.f,5.f},
                              .flow={0.f,0.f,0.f,.21f},.presence=exteriorBell};
        [draw setVertexBytes:&enclosing length:sizeof(enclosing) atIndex:1];
        const auto& mesh = ultra ? ultraGiantMesh : giantMesh;
        [draw setVertexBytes:&mesh length:sizeof(mesh) atIndex:7];
        [draw drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:mesh.tentacleIndices()
                          indexType:ultra ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16
                        indexBuffer:ultra ? _ultraGiantIndices : _giantIndices indexBufferOffset:0];
    }
    [draw endEncoding];

    pass.colorAttachments[0].texture = _light;
    draw = [cmd renderCommandEncoderWithDescriptor:pass];
    [draw setRenderPipelineState:_copyWater];
    [draw setFragmentTexture:_waterLight atIndex:0];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    // Keep the fast water details out of the bell's refraction and under the player silhouette.
    [draw setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setFragmentTexture:_jellyTransmission atIndex:2];
    [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
    const std::uint32_t nodes = flowNodes;
    constexpr auto ribbonVertices = (flowNodes-1)*6;
    [draw setVertexBytes:&nodes length:sizeof(nodes) atIndex:4];
    if (opening && movingWater) {
        [draw setRenderPipelineState:_sheets];
        const std::uint32_t columns = sheetColumns;
        [draw setVertexBuffer:field offset:(flowLines+guideLines)*flowNodes*sizeof(FlowNode) atIndex:3];
        [draw setVertexBytes:&columns length:sizeof(columns) atIndex:5];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:sheetLines*sheetColumns*ribbonVertices];
    }
    if (movingWater) {
        [draw setRenderPipelineState:_currents];
        [draw setVertexBuffer:field offset:0 atIndex:3];
        const auto luminousLines = opening ? flowLines+guideLines : flowLines;
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:luminousLines*ribbonVertices];
        [draw setRenderPipelineState:_plankton];
        [draw setVertexBuffer:tracers offset:0 atIndex:2];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:planktonCount*6];
    }
    const bool whirlpoolBloom = scene.whirlpoolApproach > .04f && scene.cycle.y < .16f;
    const bool colossusBloom = scene.cycle.y > .392f && scene.cycle.y < .963f;
    const bool passageBloom = scene.returnPassage.w > 0.f &&
                              scene.passageFlow.w > -2.4f && scene.passageFlow.w < 7.75f;
    if (whirlpoolBloom || colossusBloom || passageBloom)
        [draw setRenderPipelineState:_bloom];
    if (whirlpoolBloom || colossusBloom) {
        const std::uint32_t source = whirlpoolBloom ? 1u : 0u;
        [draw setVertexBytes:&source length:sizeof(source) atIndex:5];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:(whirlpoolBloom ? 520 : 1980)*6];
    }
    if (passageBloom) {
        const std::uint32_t source = 2;
        [draw setVertexBytes:&source length:sizeof(source) atIndex:5];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:760*6];
    }
    [draw setRenderPipelineState:_jellyComposite];
    [draw setFragmentTexture:_jellyLight atIndex:1];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];

    if (scene.graphicsStyle != GraphicsStyle::Painted) {
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
    }

    // Grade and mix bloom before upscaling so that pass runs at the scene resolution.
    pass.colorAttachments[0].texture = upscale ? _graded : destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    auto post = [cmd renderCommandEncoderWithDescriptor:pass];
    [post setRenderPipelineState:_finish];
    [post setFragmentTexture:_light atIndex:0];
    [post setFragmentTexture:_nearGlow atIndex:1];
    [post setFragmentTexture:_farGlow atIndex:2];
    [post setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [post drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [post endEncoding];
    if (upscale) {
        pass.colorAttachments[0].texture = destination;
        auto present = [cmd renderCommandEncoderWithDescriptor:pass];
        [present setRenderPipelineState:_upscale];
        [present setFragmentTexture:_graded atIndex:0];
        [present drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [present endEncoding];
    }
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

@interface Atlas : NSView
@property(getter=isOpen) BOOL open;
@property(nonatomic, copy) void (^selection)(unsigned);
@property(nonatomic, assign) Ocean* ocean;
@end
@implementation Atlas
- (BOOL)isFlipped { return YES; }
- (BOOL)isOpen { return !self.hidden; }
- (void)setOpen:(BOOL)open {
    self.hidden = !open;
    if (open) self.needsDisplay = YES;
}
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
    if (!self.open || !self.selection) return;
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
    if (!ocean || !self.open) return;
    fill(self.bounds,[NSColor colorWithWhite:0 alpha:.43]);
    const NSRect panel = [self chartPanel];
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
}
@end

@interface Game : NSObject <NSApplicationDelegate, MTKViewDelegate, NSWindowDelegate>
- (void)toggleMusicResponse:(id)sender;
- (void)toggleMute:(id)sender;
- (void)chooseGraphicsStyle:(NSMenuItem*)sender;
- (void)toggleAdaptiveResolution:(id)sender;
- (void)toggleEnclosingView:(id)sender;
@end
@implementation Game {
    NSWindow* _window;
    Controls* _view;
    Atlas* _atlas;
    Renderer* _renderer;
    std::unique_ptr<Ocean> _ocean;
    std::unique_ptr<Score> _score;
    AVAudioEngine* _audio;
    AVAudioSourceNode* _source;
    std::array<bool,128> _pressed;
    dispatch_semaphore_t _inFlight;
    std::shared_ptr<std::atomic<std::uint64_t>> _gpuSample;
    RenderResolution _resolution;
    double _last, _soundAt;
    double _musicAt, _musicPhase;
    std::uint64_t _musicSnapshot;
    Quad _music;
    float _panX, _panY;
    unsigned _lastCallNumber, _callInput;
    BOOL _lookRequested, _musicResponse, _muted, _exteriorView, _adaptiveResolution;
    GraphicsStyle _graphicsStyle;
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
        _ocean = std::make_unique<Ocean>(resource(@"orbits",@"txt").fileSystemRepresentation,
                                         0,OceanStart::ColossalBell);
        auto device = MTLCreateSystemDefaultDevice();
        _renderer = [[Renderer alloc] initWithDevice:device];
        _inFlight = dispatch_semaphore_create(2);
        _gpuSample = std::make_shared<std::atomic<std::uint64_t>>(0);
        _adaptiveResolution = YES;
        _musicResponse = YES;
        _graphicsStyle = GraphicsStyle::Hybrid;
        [self startAudio];

        _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1120,735)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                |NSWindowStyleMaskFullSizeContentView
            backing:NSBackingStoreBuffered defer:NO];
        _window.title = @"Pelagic Orbits";
        _window.titleVisibility = NSWindowTitleHidden;
        _window.titlebarAppearsTransparent = YES;
        _window.titlebarSeparatorStyle = NSTitlebarSeparatorStyleNone;
        _window.minSize = NSMakeSize(730,505);
        _window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
        _window.delegate = self;
        _window.acceptsMouseMovedEvents = YES;
        _view = [[Controls alloc] initWithFrame:_window.contentView.bounds device:device];
        _view.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        _view.preferredFramesPerSecond = 60;
        _view.delegate = self;
        _atlas = [[Atlas alloc] initWithFrame:_view.bounds];
        _atlas.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _atlas.ocean = _ocean.get();
        _atlas.open = NO;
        [_view addSubview:_atlas];
        _window.contentView = _view;
        __weak Game* weak = self;
        _view.keyChange = ^(NSEvent* e,BOOL down) { [weak keyboard:e down:down]; };
        _view.motion = ^(CGFloat x,CGFloat y) { [weak panX:x y:y]; };
        _view.clearKeys = ^{ [weak clear]; };
        _view.callChange = ^(BOOL down) { [weak callInput:2 down:down]; };
        _view.resumeLook = ^{ [weak setMouseLook:YES]; };
        _atlas.selection = ^(unsigned i) { [weak select:i]; };
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
    _muted = !_muted;
    _score->mute(_muted);
}
- (void)chooseGraphicsStyle:(NSMenuItem*)sender {
    _graphicsStyle = static_cast<GraphicsStyle>(sender.tag);
}
- (void)toggleAdaptiveResolution:(id)sender {
    _adaptiveResolution = !_adaptiveResolution;
    _gpuSample->store(0,std::memory_order_relaxed);
    _resolution = {};
}
- (void)toggleEnclosingView:(id)sender {
    if (!_ocean || !_ocean->openingRoute() || _ocean->transforming() || _ocean->returning()) return;
    _exteriorView = !_exteriorView;
    _atlas.open = NO;
    [self clear];
    [self updateMouseLook];
}
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(toggleAdaptiveResolution:)) {
        item.state = _adaptiveResolution ? NSControlStateValueOn : NSControlStateValueOff;
        return bool(_gpuSample);
    }
    if (item.action == @selector(toggleEnclosingView:)) {
        item.state = _exteriorView ? NSControlStateValueOn : NSControlStateValueOff;
        return _ocean && _ocean->openingRoute() && !_ocean->transforming() && !_ocean->returning();
    }
    if (item.action == @selector(chooseGraphicsStyle:)) {
        item.state = item.tag == static_cast<NSInteger>(_graphicsStyle) ? NSControlStateValueOn : NSControlStateValueOff;
        return YES;
    }
    if (item.action == @selector(toggleMusicResponse:))
        item.state = _musicResponse ? NSControlStateValueOn : NSControlStateValueOff;
    if (item.action == @selector(toggleMute:))
        item.state = _muted ? NSControlStateValueOn : NSControlStateValueOff;
    return bool(_score);
}
- (void)callInput:(unsigned)source down:(BOOL)down {
    if (down) {
        if (!_atlas.open && !_exteriorView && !_callInput && _ocean->beginCall()) _callInput = source;
        return;
    }
    if (_callInput != source) return;
    _callInput = 0;
    _ocean->releaseCall();
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
    const BOOL looking = _lookRequested && _ocean && !_atlas.open && !_ocean->paused && !_exteriorView;
    [_view enableLook:looking lockCursor:_window.isKeyWindow && NSApp.isActive];
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
    _atlas.open = NO;
    [self setMouseLook:YES];
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
        _atlas.open = !_atlas.open;
        [self clear];
        [self setMouseLook:!_atlas.open];
    } else if (code == 53) {
        _atlas.open = NO;
        [self setMouseLook:NO];
    } else if (key.length == 1) {
        const unichar c = [key characterAtIndex:0];
        if (c >= '1' && c <= '8') [self select:c-'1'];
        if (c == ' ') {
            [self clear];
            _ocean->paused = !_ocean->paused;
            [self setMouseLook:!_ocean->paused];
        }
        if (c == 'p') {
            _graphicsStyle = _graphicsStyle == GraphicsStyle::Original ? GraphicsStyle::Hybrid :
                             _graphicsStyle == GraphicsStyle::Hybrid ? GraphicsStyle::Painted :
                             _graphicsStyle == GraphicsStyle::Painted ? GraphicsStyle::Ultra :
                             GraphicsStyle::Original;
        }
        if (c == 'd') {
            _ocean->demo = !_ocean->demo;
            if (_ocean->demo) _ocean->paused = false;
            [self setMouseLook:!_ocean->demo];
        }
        if (c == 'm') [self toggleMute:nil];
        if (c == 'v') [self toggleEnclosingView:nil];
        if (c == 'n' || c == '\r') {
            [self clear];
            const bool chart = _atlas.open;
            _atlas.open = NO;
            _ocean->paused = false;
            if (chart) _ocean->uncharted();
            else _ocean->next();
            if (chart) [self setMouseLook:YES];
        }
    }
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
    if (_atlas.open || _ocean->paused) return;
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
    if (!_atlas.open && !_ocean->paused) {
        const float x = float(_pressed[124])-float(_pressed[123]);
        const float y = float(_pressed[14])-float(_pressed[12]);
        const float z = float(_pressed[126] || _pressed[13])-float(_pressed[125] || _pressed[1]);
        const float lookX = float(_pressed[37])-float(_pressed[38]);
        const float lookY = float(_pressed[34])-float(_pressed[40]);
        const bool wasDrifting = _ocean->demo;
        const float before = _ocean->transformationProgress();
        if (_exteriorView) _ocean->step(dt,{},0.f,0.f);
        else _ocean->step(dt,{x,y,z},_panX+dt*lookX*.85f,_panY+dt*lookY*.70f,_pressed[11]);
        if (_score) {
            const float after = _ocean->transformationProgress();
            constexpr std::array<float,3> contractions{.416f,.493f,.570f};
            for (unsigned i = 0; i < contractions.size(); ++i)
                if (before < contractions[i] && after >= contractions[i]) _score->resonateBell(i);
        }
        if (_exteriorView && _ocean->transforming()) {
            _exteriorView = NO;
            [self updateMouseLook];
        }
        if (wasDrifting && !_ocean->demo) [self setMouseLook:YES];
    }
    _panX = 0; _panY = 0;
    [self updateMusic:std::min(dt,.1f) now:now];
    if (_score && now-_soundAt > .045) {
        _score->update(_ocean->look(),_ocean->waterAt(_ocean->position()),_ocean->callCharge(),
                        _ocean->basinAmount(),_ocean->passageResonance());
        _soundAt = now;
    }
    const auto replies = _ocean->takeReplies();
    const auto cue = _ocean->takeVoyageCue();
    if (_score) {
        _score->play(cue);
        if (_ocean->calls() > _lastCallNumber) _score->pulse(_ocean->drawnCall());
        if (!replies.empty()) {
            const auto view = _ocean->scene(1.f);
            const Vec right{view.right.x,view.right.y,view.right.z};
            const Vec forward{view.forward.x,view.forward.y,view.forward.z};
            for (const auto& reply : replies) _score->echo(reply,_ocean->position(),right,forward);
        }
    }
    _lastCallNumber = _ocean->calls();
    if (dispatch_semaphore_wait(_inFlight,DISPATCH_TIME_NOW)) return;
    auto drawable = view.currentDrawable;
    if (!drawable) {
        dispatch_semaphore_signal(_inFlight);
        return;
    }
    const bool adaptive = _adaptiveResolution && !_exteriorView && _graphicsStyle != GraphicsStyle::Ultra;
    const auto gpuSample = adaptive ? _gpuSample : nullptr;
    if (gpuSample) {
        const auto sample = gpuSample->exchange(0,std::memory_order_relaxed);
        _resolution.observe(unsigned(sample >> 32),std::uint32_t(sample)*.001);
    }
    const unsigned renderWidth = adaptive ? _resolution.width() : fullRenderWidth;
    auto cmd = [_renderer render:drawable.texture ocean:*_ocean music:_music phase:float(_musicPhase)
                           style:_graphicsStyle exterior:_exteriorView maxWidth:renderWidth];
    [cmd presentDrawable:drawable];
    dispatch_semaphore_t inflight = _inFlight;
    [cmd addCompletedHandler:^(id<MTLCommandBuffer> completed) {
        if (gpuSample && completed.status == MTLCommandBufferStatusCompleted && completed.GPUStartTime > 0.) {
            const double elapsed = completed.GPUEndTime-completed.GPUStartTime;
            if (elapsed > 0. && elapsed < 5.) {
                const auto sample = (std::uint64_t(renderWidth) << 32) | std::uint32_t(elapsed*1.e6);
                gpuSample->store(sample,std::memory_order_relaxed);
            }
        }
        dispatch_semaphore_signal(inflight);
    }];
    [cmd commit];
}
@end

static void capture(NSString* filename, unsigned system, unsigned frames, GraphicsStyle style) {
    Ocean ocean(resource(@"orbits",@"txt").fileSystemRepresentation,system);
    for (unsigned i = 0; i < frames; ++i) {
        if (frames > 90 && i == frames-85) ocean.pulse();
        ocean.step(1.f/60.f,{},0,0);
    }
    auto device = MTLCreateSystemDefaultDevice();
    auto renderer = [[Renderer alloc] initWithDevice:device];
    const NSUInteger width = style == GraphicsStyle::Ultra ? 1920 : 1440;
    const NSUInteger height = style == GraphicsStyle::Ultra ? 1080 : 900;
    auto info = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                    width:width height:height mipmapped:NO];
    info.storageMode = MTLStorageModeShared;
    info.usage = MTLTextureUsageRenderTarget;
    auto texture = [device newTextureWithDescriptor:info];
    auto cmd = [renderer render:texture ocean:ocean music:Quad{} phase:0.f style:style exterior:false
                       maxWidth:fullRenderWidth];
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
                const std::string_view look = argc > 5 ? argv[5] : "";
                const auto style = look == "--ultra" ? GraphicsStyle::Ultra :
                                   look == "--painted" ? GraphicsStyle::Painted :
                                   look == "--hybrid" ? GraphicsStyle::Hybrid : GraphicsStyle::Original;
                capture([NSString stringWithUTF8String:argv[2]],system,frames,style);
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
        NSMenu* view = [[NSMenu alloc] initWithTitle:@"View"];
        NSArray<NSString*>* looks = @[@"Original Graphics",@"Hybrid Water",@"Painted World",@"Ultra High Graphics"];
        for (NSUInteger i = 0; i < looks.count; ++i) {
            NSMenuItem* item = [view addItemWithTitle:looks[i] action:@selector(chooseGraphicsStyle:) keyEquivalent:@""];
            item.target = game;
            item.tag = i;
        }
        [view addItem:[NSMenuItem separatorItem]];
        [view addItemWithTitle:@"Adaptive Resolution" action:@selector(toggleAdaptiveResolution:) keyEquivalent:@""].target = game;
        [view addItemWithTitle:@"View Enclosing Jellyfish" action:@selector(toggleEnclosingView:) keyEquivalent:@""].target = game;
        NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
        viewItem.submenu = view;
        [main addItem:viewItem];
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
