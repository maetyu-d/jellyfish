#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/QuartzCore.h>

#include "Sea.hpp"
#include "BubbleStrings.hpp"
#include "BubbleFlightHud.h"
#include "MissionDispatch.hpp"
#include "BubbleMissions.hpp"
#include "MissionRuntime.hpp"
#include "MissionStrategy.hpp"
#include "MissionTransport.hpp"
#include "MissionTravel.hpp"
#include "MissionView.h"
#include "ShipFlight.hpp"
#include "XalariaInstruments.hpp"
#include "XalariaTerrain.hpp"
#include "XalariaTerrainDetail.hpp"
#include "XalariaWeather.hpp"
#include "Score.hpp"

#include <algorithm>
#include <array>
#include <atomic>
#include <cmath>
#include <cstddef>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <iostream>
#include <limits>
#include <memory>
#include <numbers>
#include <optional>
#include <stdexcept>

using namespace pelagic;
namespace job = pelagic::missions;
namespace board = pelagic::missionui;

static_assert(sizeof(Planet) == 64);
static_assert(sizeof(BellSystem) == 288);
static_assert(sizeof(SystemBubble) == 1200);
static_assert(offsetof(Scene,pulseAxis) == 944 && sizeof(Scene) == 960);
static_assert(offsetof(FlightScene,bodies) == 528 && sizeof(FlightScene) == 2400);
static_assert(sizeof(TerrainStyle) == 112);
static_assert(sizeof(WorldAppearance) == 80);
static_assert(sizeof(FlightBody) == 144);
static_assert(sizeof(ShipPose) == 80);
static_assert(sizeof(HullLight) == 96);
static_assert(sizeof(StringStroke) == 48);
static_assert(sizeof(StringContact) == 64);
static_assert(sizeof(CabinVertex) == 28);
static_assert(sizeof(Bubble) == 112);
static_assert(sizeof(Tracer) == 48);
static_assert(sizeof(FlowNode) == 32);
static_assert(sizeof(TrailPose) == 48);
struct BubbleMesh {
    std::uint32_t sides, slices;

    constexpr NSUInteger indices() const { return 6*sides*slices; }
};
constexpr BubbleMesh giantMesh{100,60};
constexpr BubbleMesh shoalMesh{56,36};
constexpr BubbleMesh colossalMesh{288,120};
constexpr BubbleMesh compactColossalMesh{156,82};
constexpr BubbleMesh ultraColossalMesh{360,160};
constexpr BubbleMesh ultraGiantMesh{144,84};
static_assert(giantMesh.indices() < UINT16_MAX && shoalMesh.indices() < UINT16_MAX);

template<class Index>
static std::vector<Index> bubbleIndices(const BubbleMesh& mesh) {
    // Each grid corner points at one occurrence in the procedural vertex sequence.
    constexpr unsigned dx[] = {0,1,1,0,1,0};
    constexpr unsigned dy[] = {0,0,1,0,1,1};
    constexpr auto empty = std::numeric_limits<Index>::max();
    std::vector<Index> corners((mesh.sides+1)*(mesh.slices+1),empty);
    std::vector<Index> indices;
    indices.reserve(mesh.indices());
    for (unsigned y = 0; y < mesh.slices; ++y) {
        for (unsigned x = 0; x < mesh.sides; ++x) {
            for (unsigned k = 0; k < 6; ++k) {
                auto& index = corners[(y+dy[k])*(mesh.sides+1)+x+dx[k]];
                if (index == empty) index = Index(indices.size());
                indices.push_back(index);
            }
        }
    }
    return indices;
}

enum class Blend { Solid, Alpha, Bubble, Hull, Exterior, Terrain };

constexpr float searchlightHeight = .238f, searchlightTip = 1.423f;

static void appendSearchlight(std::vector<CabinVertex>& ship) {
    // The illuminated lip continues around the lens so the chase camera sees the fixture.
    constexpr unsigned sides = 24;
    for (unsigned side = 0; side < sides; ++side) {
        const auto vertex = [](unsigned i,float radius,float z,std::uint32_t paint,bool face) {
            const float angle = 6.283185307f*float(i%sides)/float(sides);
            const float x = std::cos(angle), y = std::sin(angle);
            return CabinVertex{x*radius,searchlightHeight+y*radius,z,paint,
                               face ? 0.f : x,face ? 0.f : y,face ? 1.f : 0.f};
        };
        constexpr std::uint32_t metal = 0x005b5d5fu, lip = 0xA0857261u, glass = 0xB0867467u;
        const auto ring = [&](float outer,float back,float inner,float front,std::uint32_t paint,bool face) {
            const auto a = vertex(side,outer,back,paint,face), b = vertex(side+1,outer,back,paint,face);
            const auto c = vertex(side,inner,front,paint,face), d = vertex(side+1,inner,front,paint,face);
            ship.insert(ship.end(),{a,b,c,b,d,c});
        };
        ring(.126f,1.17f,.096f,1.383f,metal,false);
        ring(.096f,1.383f,.085f,searchlightTip,lip,false);
        ring(.085f,searchlightTip,.068f,searchlightTip-.010f,lip,true);
        ship.insert(ship.end(),{vertex(side,.068f,searchlightTip-.010f,glass,true),
                               vertex(side+1,.068f,searchlightTip-.010f,glass,true),
                               CabinVertex{0.f,searchlightHeight,searchlightTip-.010f,glass,0.f,0.f,1.f}});
    }
}

struct FlightTerrainVertex {
    Quad position, colour, normal;
};
struct FlightTerrainMaterialFrame {
    Quad planetEye, microOrigin, mesoOriginLow, mesoOriginHigh;
};
struct FlightTerrainSun {
    Quad right, up, depth, settings, gearPoint, gearNormal;
};
constexpr NSUInteger terrainShadowSize = 2048;

static FlightTerrainSun terrainSun(const XalariaTerrain& terrain,unsigned system,std::string_view name,
                                  const std::array<double,3>& eyeMetres,double radius,
                                  Quad star,Quad planet) {
    const simd_double3 eye{eyeMetres[0],eyeMetres[1],eyeMetres[2]};
    const double range=simd_length(eye);
    if (!(range>0.) || range-radius>radius*.04+60000.) return {};
    const auto radial=eye/range;
    const double ground=radius*(1.+terrain.surfaceHeight(system,name,{float(radial.x),float(radial.y),float(radial.z)}));
    const double altitude=range-ground;
    const auto quad=[](simd_double3 v,double w) { return Quad{float(v.x),float(v.y),float(v.z),float(w)}; };
    FlightTerrainSun result{};
    auto centre=radial*ground;
    if (altitude>=0. && altitude<38.) {
        const double weight=std::clamp((altitude-1.)/37.,0.,1.);
        result.gearPoint=quad(centre-eye,3.2+altitude*.22);
        result.gearNormal=quad(radial,(1.-weight*weight*(3.-2.*weight))*.35);
    }
    const simd_double3 shift{double(star.x)-planet.x,double(star.y)-planet.y,double(star.z)-planet.z};
    if (altitude>=60000. || simd_length_squared(shift)<1.e-30) return result;
    const auto light=simd_normalize(shift);
    if (simd_dot(radial,light)<=.035) return result;
    const double span=std::clamp(std::exp2(std::ceil(std::log2(std::max(2048.,altitude*8.)))),2048.,262144.);
    const double texel=span/terrainShadowSize;
    const auto axis=std::abs(light.y)<.9 ? simd_double3{0.,1.,0.} : simd_double3{1.,0.,0.};
    const auto right=simd_normalize(simd_cross(-light,axis));
    const auto up=simd_normalize(simd_cross(right,-light));
    const auto snapped=[&](simd_double3 axis) {
        const double p=simd_dot(centre,axis);
        return axis*(std::round(p/texel)*texel-p);
    };
    centre+=snapped(right)+snapped(up);
    centre-=eye;
    result.right=quad(right/span,.5-simd_dot(centre,right)/span);
    result.up=quad(-up/span,.5+simd_dot(centre,up)/span);
    result.depth=quad(-light/(2.999*span),(1.499*span+simd_dot(centre,light))/(2.999*span));
    result.settings={1.f,1.f/terrainShadowSize};
    return result;
}

constexpr unsigned nativeRenderWidth = 0;
constexpr unsigned adaptiveMinimumWidth = 1280;

struct RenderResolution {
    static constexpr unsigned widthStep = 160;
    unsigned tier{};
    double frameMilliseconds{};
    unsigned measuredFrames{};

    unsigned width(unsigned drawableWidth) const {
        return std::min(drawableWidth,adaptiveMinimumWidth+widthStep*tier);
    }

    void observe(unsigned drawableWidth, unsigned sampleWidth, double milliseconds) {
        if (sampleWidth != width(drawableWidth) || milliseconds <= 0. || drawableWidth <= adaptiveMinimumWidth) return;
        const unsigned maxTier = (drawableWidth-adaptiveMinimumWidth+widthStep-1)/widthStep;
        // Window resizing can leave more steps selected than the new drawable needs.
        tier = std::min(tier,maxTier);
        frameMilliseconds = measuredFrames ? std::lerp(frameMilliseconds,milliseconds,.18) : milliseconds;
        measuredFrames = std::min(measuredFrames+1,36u);
        auto next = tier;
        // Reduce the cost promptly. Require spare GPU time across more frames before increasing it.
        if (measuredFrames >= 8 && frameMilliseconds > 33. && tier > 0) --next;
        else if (measuredFrames >= 36 && frameMilliseconds < 21.5 && tier < maxTier) ++next;
        if (next != tier) {
            tier = next;
            measuredFrames = 0;
        }
    }
};

static const BubbleMesh& meshFor(const Bubble& bubble, bool compact, bool ultra) {
    if (bubble.membraneAnchor > 0.f && bubble.position.w > 40.f)
        return ultra ? ultraColossalMesh : compact ? compactColossalMesh : colossalMesh;
    if (bubble.flow.z > 0.f || bubble.position.w > 4.f)
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
- (const XalariaTerrain*)terrain;
- (id<MTLCommandBuffer>)render:(id<MTLTexture>)destination ocean:(Ocean&)ocean
                       music:(Quad)music phase:(float)phase style:(GraphicsStyle)style exterior:(bool)exterior
                        guide:(bool)guide aim:(bool)aim searchlight:(bool)searchlight maxWidth:(unsigned)maxWidth
                       flight:(const FlightScene&)flight strings:(const BubbleStrings*)strings toolTime:(double)toolTime
                   inspection:(std::optional<BubbleInspection>*)inspection;
- (id<MTLCommandBuffer>)fly:(id<MTLTexture>)destination scene:(const FlightScene&)flight
                       ocean:(const Ocean&)ocean pilot:(const ShipFlight&)pilot;
- (id<MTLCommandBuffer>)survey:(id<MTLTexture>)destination ocean:(const Ocean&)ocean
                        system:(unsigned)system frame:(Quad)frame light:(Quad)light ziksa:(const FlightScene&)ziksa;
@end

@implementation Renderer {
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLRenderPipelineState> _flightSky, _flightCabin, _flightRegion, _flightGlass;
    id<MTLRenderPipelineState> _flightOptics, _flightCloudVolume, _flightLensSeed, _flightBokeh;
    id<MTLRenderPipelineState> _flightGlare, _flightLens, _flightComposite, _flightScreens, _flightOverlay;
    id<MTLTexture> _flightRadiance, _flightExterior, _flightCabinColour, _flightFinish, _flightGlow, _flightFont;
    id<MTLTexture> _flightOptical, _flightLightSeed, _flightDepth, _flightCloud, _noCloud;
    std::unique_ptr<XalariaWeather> _weather;
    std::array<std::shared_ptr<const XalariaWeatherField>,2> _weatherFields;
    std::array<id<MTLTexture>,2> _weatherTextures;
    CFTimeInterval _lastWeatherFrame;
    std::unique_ptr<XalariaTerrain> _terrainFields;
    std::array<std::shared_ptr<const XalariaTerrainGlobe>,ziksaBodyCount> _residentTerrain;
    std::shared_ptr<const XalariaTerrainPatch> _residentTerrainPatch;
    std::shared_ptr<const XalariaTerrainMesh> _residentTerrainMesh;
    CFTimeInterval _terrainMorphAt;
    id<MTLTexture> _terrainAtlas;
    id<MTLTexture> _terrainDetail, _flightZ, _terrainShadowMap;
    id<MTLBuffer> _terrainIndices;
    id<MTLRenderPipelineState> _flightTerrain, _flightTerrainShadow;
    id<MTLDepthStencilState> _terrainDepthState, _skyDepthState, _terrainShadowDepthState;
    id<MTLRenderPipelineState> _worldShip, _copyShip, _worldExhaust;
    id<MTLDepthStencilState> _cabinDepthState, _cabinGlassDepth;
    id<MTLTexture> _cabinDepth;
    id<MTLBuffer> _cabinMeshes[6], _worldShipMesh;
    NSUInteger _cabinCounts[6], _shipVertices, _shipSamples;
    id<MTLTexture> _shipLight, _shipRange, _shipDepth, _shipMSAALight, _shipMSAARange;
    id<MTLRenderPipelineState> _sea, _currents, _sheets, _bubbleWakes, _animal, _exteriorAnimal;
    id<MTLRenderPipelineState> _systemBubble, _multisampleSystemBubble;
    id<MTLRenderPipelineState> _systemSurvey;
    id<MTLRenderPipelineState> _copyWater, _bubbleComposite, _plankton, _bloom, _finish, _shipReticle;
    id<MTLRenderPipelineState> _bubbleStrings, _stringContacts;
    id<MTLTexture> _light, _waterLight, _bubbleLight, _bubbleTransmission;
    id<MTLTexture> _exteriorLight, _exteriorTransmission;
    id<MTLRenderPipelineState> _extractGlow, _spreadGlow;
    id<MTLTexture> _nearGlow, _farGlow;
    id<MTLBuffer> _tracerBuffers[3];
    id<MTLBuffer> _flowBuffers[3];
    id<MTLBuffer> _trailBuffers[3];
    id<MTLBuffer> _bubbleBuffers[3];
    id<MTLBuffer> _bellSystems[3], _residentCatalogues[3];
    id<MTLBuffer> _systemBubbles;
    id<MTLBuffer> _bubbleColourTimes;
    unsigned _bubbleColourRevision;
    id<MTLBuffer> _colossalIndices, _compactColossalIndices, _giantIndices, _shoalIndices;
    id<MTLBuffer> _ultraColossalIndices, _ultraGiantIndices;
    std::array<Bubble,shoalCapacity> _visibleBubbles;
    std::vector<StringStroke> _stringStrokes;
    std::vector<StringContact> _stringAttachments;
    unsigned _tracerSlot;
}

- (const XalariaTerrain*)terrain {
    return _terrainFields.get();
}

- (id<MTLTexture>)uploadMaterial:(std::span<const std::uint8_t>)pixels width:(NSUInteger)width
                         height:(NSUInteger)height label:(NSString*)label {
    auto info = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                  width:width height:height mipmapped:YES];
    info.storageMode = MTLStorageModeShared;
    info.usage = MTLTextureUsageShaderRead;
    auto texture = [_device newTextureWithDescriptor:info];
    if (!texture) throw std::runtime_error("The Xalaria material texture could not be allocated.");
    texture.label = label;
    std::size_t offset = 0;
    for (NSUInteger level=0; level<texture.mipmapLevelCount; ++level) {
        const auto size = width*height*4;
        if (size>pixels.size()-offset) throw std::runtime_error("Incomplete Xalaria material mip chain.");
        [texture replaceRegion:MTLRegionMake2D(0,0,width,height) mipmapLevel:level
                     withBytes:pixels.data()+offset bytesPerRow:width*4];
        offset += size;
        width = std::max(1UL,width/2);
        height = std::max(1UL,height/2);
    }
    if (offset!=pixels.size()) throw std::runtime_error("Invalid Xalaria material mip chain.");
    return texture;
}

- (id<MTLRenderPipelineState>)pipeline:(id<MTLLibrary>)library vertex:(NSString*)vertex
                             fragment:(NSString*)fragment format:(MTLPixelFormat)format blend:(Blend)blend
                               samples:(NSUInteger)samples depth:(BOOL)depth {
    MTLRenderPipelineDescriptor* d = [MTLRenderPipelineDescriptor new];
    d.label = fragment;
    d.vertexFunction = [library newFunctionWithName:vertex];
    d.fragmentFunction = [library newFunctionWithName:fragment];
    d.rasterSampleCount = samples;
    if (depth) d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    auto attachment = d.colorAttachments[0];
    attachment.pixelFormat = format;
    if (blend == Blend::Hull) {
        d.colorAttachments[1].pixelFormat = MTLPixelFormatR16Float;
    } else if (blend == Blend::Exterior || blend == Blend::Terrain) {
        d.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
        d.colorAttachments[2].pixelFormat = MTLPixelFormatR32Float;
        if (blend == Blend::Terrain) d.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
    } else if (blend == Blend::Alpha) {
        attachment.blendingEnabled = YES;
        attachment.sourceRGBBlendFactor = MTLBlendFactorOne;
        attachment.destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
        attachment.sourceAlphaBlendFactor = MTLBlendFactorOne;
        attachment.destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    } else if (blend == Blend::Bubble) {
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
    return [self pipeline:library vertex:vertex fragment:fragment format:format blend:blend samples:1 depth:NO];
}

- (instancetype)initWithDevice:(id<MTLDevice>)device {
    self = [super init];
    if (!device) throw std::runtime_error("Pelagic Spheres requires a Metal-capable Mac.");
    _device = device;
    _queue = [device newCommandQueue];
    NSError* error = nil;
    NSString* path = resource(@"Sea",@"metal");
    if (!path) throw std::runtime_error("Sea.metal is missing from the app.");
    NSString* source = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:&error];
    if (!source) throw failure(error, "The shader could not be read.");
    NSString* flightPath = resource(@"ShipFlight",@"metal");
    if (!flightPath) throw std::runtime_error("ShipFlight.metal is missing from the app.");
    NSString* flightSource = [NSString stringWithContentsOfFile:flightPath encoding:NSUTF8StringEncoding error:&error];
    if (!flightSource) throw failure(error,"The flight shader could not be read.");
    NSString* spacePath = resource(@"XalariaSpace",@"metal");
    if (!spacePath) throw std::runtime_error("XalariaSpace.metal is missing from the app.");
    NSString* spaceSource = [NSString stringWithContentsOfFile:spacePath encoding:NSUTF8StringEncoding error:&error];
    if (!spaceSource) throw failure(error,"The Xalaria space shader could not be read.");
    NSString* cabinPath = resource(@"XalariaCabin",@"metal");
    if (!cabinPath) throw std::runtime_error("XalariaCabin.metal is missing from the app.");
    NSString* cabinSource = [NSString stringWithContentsOfFile:cabinPath encoding:NSUTF8StringEncoding error:&error];
    if (!cabinSource) throw failure(error,"The Xalaria cabin shader could not be read.");
    NSString* terrainPath = resource(@"XalariaTerrain",@"metal");
    if (!terrainPath) throw std::runtime_error("XalariaTerrain.metal is missing from the app.");
    NSString* terrainSource = [NSString stringWithContentsOfFile:terrainPath encoding:NSUTF8StringEncoding error:&error];
    if (!terrainSource) throw failure(error,"The Xalaria terrain shader could not be read.");
    NSString* shadowPath = resource(@"XalariaTerrainShadow",@"metal");
    if (!shadowPath) throw std::runtime_error("XalariaTerrainShadow.metal is missing from the app.");
    NSString* shadowSource = [NSString stringWithContentsOfFile:shadowPath encoding:NSUTF8StringEncoding error:&error];
    if (!shadowSource) throw failure(error,"The Xalaria terrain shadow shader could not be read.");
    NSString* terrainData = resource(@"xalaria-terrain",@"bin");
    if (!terrainData) throw std::runtime_error("The Xalaria terrain catalogue is missing from the app.");
    _terrainFields = std::make_unique<XalariaTerrain>(terrainData.fileSystemRepresentation);
    auto atlas = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float
                                       width:terrainFaceSize height:terrainFaceSize mipmapped:NO];
    atlas.textureType = MTLTextureType2DArray;
    atlas.arrayLength = terrainFaceCount*ziksaBodyCount+1;
    atlas.storageMode = MTLStorageModePrivate;
    atlas.usage = MTLTextureUsageShaderRead;
    _terrainAtlas = [device newTextureWithDescriptor:atlas];
    if (!_terrainAtlas) throw std::runtime_error("The Xalaria terrain atlas could not be allocated.");
    _terrainAtlas.label = @"Xalaria terrain colours and heights";
    const auto detail = bakeXalariaTerrainDetail();
    _terrainDetail = [self uploadMaterial:detail width:xalariaTerrainDetailSize height:xalariaTerrainDetailSize
                                    label:@"Xalaria physical terrain detail"];
    auto shadowMap = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm
                                  width:terrainShadowSize height:terrainShadowSize mipmapped:NO];
    shadowMap.storageMode = MTLStorageModePrivate;
    shadowMap.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    _terrainShadowMap = [device newTextureWithDescriptor:shadowMap];
    if (!_terrainShadowMap) throw std::runtime_error("The Xalaria terrain shadow map could not be allocated.");
    _terrainShadowMap.label = @"Xalaria snapped terrain shadow depth";
    NSString* weatherPath = resource(@"XalariaWeather",@"metal");
    if (!weatherPath) throw std::runtime_error("XalariaWeather.metal is missing from the app.");
    NSString* weatherSource = [NSString stringWithContentsOfFile:weatherPath encoding:NSUTF8StringEncoding error:&error];
    if (!weatherSource) throw failure(error,"The Xalaria weather shader could not be read.");
    NSString* weatherData = resource(@"xalaria-weather",@"tsv");
    if (!weatherData) throw std::runtime_error("The Xalaria climate catalogue is missing from the app.");
    _weather = std::make_unique<XalariaWeather>(weatherData.fileSystemRepresentation);
    source = [NSString stringWithFormat:@"%@\n%@\n%@\n%@\n%@\n%@\n%@",
              source,spaceSource,cabinSource,shadowSource,terrainSource,weatherSource,flightSource];
    auto options = [MTLCompileOptions new];
    options.languageVersion = MTLLanguageVersion3_1;
    options.mathMode = MTLMathModeFast;
    auto library = [_device newLibraryWithSource:source options:options error:&error];
    if (!library) throw failure(error, "The ocean shader failed.");
    _flightSky = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightSky"
                                format:MTLPixelFormatRGBA16Float blend:Blend::Exterior samples:1 depth:YES];
    _flightTerrain = [self pipeline:library vertex:@"flightTerrainVertex" fragment:@"flightTerrainPixel"
                                    format:MTLPixelFormatRGBA16Float blend:Blend::Terrain samples:1 depth:YES];
    auto shadows = [MTLRenderPipelineDescriptor new];
    shadows.label = @"Xalaria native terrain shadow casters";
    shadows.vertexFunction = [library newFunctionWithName:@"flightTerrainShadowVertex"];
    shadows.depthAttachmentPixelFormat = MTLPixelFormatDepth16Unorm;
    _flightTerrainShadow = [device newRenderPipelineStateWithDescriptor:shadows error:&error];
    if (!_flightTerrainShadow) throw failure(error,"The Xalaria terrain shadow pipeline failed.");
    auto depthWrites = [MTLDepthStencilDescriptor new];
    depthWrites.depthWriteEnabled = YES;
    depthWrites.depthCompareFunction = MTLCompareFunctionAlways;
    _skyDepthState = [device newDepthStencilStateWithDescriptor:depthWrites];
    depthWrites.depthCompareFunction = MTLCompareFunctionGreater;
    _terrainDepthState = [device newDepthStencilStateWithDescriptor:depthWrites];
    depthWrites.depthCompareFunction = MTLCompareFunctionLess;
    _terrainShadowDepthState = [device newDepthStencilStateWithDescriptor:depthWrites];
    if (!_skyDepthState || !_terrainDepthState || !_terrainShadowDepthState)
        throw std::runtime_error("The Xalaria terrain depth state could not be created.");
    _flightRegion = [self pipeline:library vertex:@"cabinSystemVertex" fragment:@"cabinSystemLight"
                                   format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _flightGlare = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightGlare"
                                  format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _flightOptics = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightOpticalExterior"
                                   format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _flightCloudVolume = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightCloudVolume"
                                        format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    auto clearCloud = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                                                        width:1 height:1 mipmapped:NO];
    clearCloud.storageMode = MTLStorageModeShared;
    clearCloud.usage = MTLTextureUsageShaderRead;
    _noCloud = [device newTextureWithDescriptor:clearCloud];
    if (!_noCloud) throw std::runtime_error("The empty cloud texture could not be allocated.");
    const std::array<std::uint8_t,4> clearPixel{0,0,0,255};
    [_noCloud replaceRegion:MTLRegionMake2D(0,0,1,1) mipmapLevel:0 withBytes:clearPixel.data() bytesPerRow:4];
    _flightLensSeed = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightLensSeed"
                                     format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _flightBokeh = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightBokeh"
                                  format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _flightLens = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightExteriorLens"
                                 format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _flightComposite = [self pipeline:library vertex:@"fullTriangle" fragment:@"flightCabinComposite"
                                      format:MTLPixelFormatBGRA8Unorm blend:Blend::Solid];
    _flightOverlay = [self pipeline:library vertex:@"flightOverlayVertex" fragment:@"flightInstrumentLight"
                                    format:MTLPixelFormatBGRA8Unorm blend:Blend::Alpha];
    const auto cabinPipeline = [&](NSString* vertex,NSString* fragment,bool translucent) {
        auto info = [MTLRenderPipelineDescriptor new];
        info.label = fragment;
        info.vertexFunction = [library newFunctionWithName:vertex];
        info.fragmentFunction = [library newFunctionWithName:fragment];
        info.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
        info.colorAttachments[1].pixelFormat = MTLPixelFormatRGBA16Float;
        info.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
        if (translucent) {
            info.colorAttachments[0].blendingEnabled = YES;
            info.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
            info.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            info.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
            info.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
            info.colorAttachments[1].writeMask = MTLColorWriteMaskNone;
        }
        NSError* pipelineError = nil;
        auto state = [_device newRenderPipelineStateWithDescriptor:info error:&pipelineError];
        if (!state) throw failure(pipelineError,"An Xalaria cockpit pipeline failed.");
        return state;
    };
    _flightCabin = cabinPipeline(@"flightCabinVertex",@"flightCabinLight",false);
    _flightGlass = cabinPipeline(@"flightCabinVertex",@"flightCanopyLight",true);
    _flightScreens = cabinPipeline(@"flightInstrumentVertex",@"flightInstrumentLight",true);
    auto font = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                width:512 height:384 mipmapped:NO];
    font.usage = MTLTextureUsageShaderRead;
    _flightFont = [_device newTextureWithDescriptor:font];
    const auto fontPixels = xalariaFontPixels();
    if (!_flightFont || fontPixels.size() != 512*384)
        throw std::runtime_error("The Xalaria instrument font could not be loaded.");
    [_flightFont replaceRegion:MTLRegionMake2D(0,0,512,384) mipmapLevel:0
                      withBytes:fontPixels.data() bytesPerRow:512];
    auto depth = [MTLDepthStencilDescriptor new];
    depth.depthWriteEnabled = YES;
    depth.depthCompareFunction = MTLCompareFunctionLess;
    _cabinDepthState = [_device newDepthStencilStateWithDescriptor:depth];
    depth.depthWriteEnabled = NO;
    depth.depthCompareFunction = MTLCompareFunctionLessEqual;
    _cabinGlassDepth = [_device newDepthStencilStateWithDescriptor:depth];
    NSString* meshPath = resource(@"xalaria-meshes",@"bin");
    if (!meshPath) throw std::runtime_error("The Xalaria flight meshes are missing from the app.");
    auto meshes = readXalariaMeshes(meshPath.fileSystemRepresentation);
    const auto upload = [&](const std::vector<CabinVertex>& part) {
        auto buffer = [_device newBufferWithBytes:part.data() length:part.size()*sizeof(CabinVertex)
                                          options:MTLResourceStorageModeShared];
        if (!buffer) throw std::runtime_error("The spacecraft meshes could not be allocated.");
        return buffer;
    };
    const std::array parts{&meshes.cabin,&meshes.hatch,&meshes.deck,&meshes.yoke,&meshes.throttle,&meshes.glazing};
    for (unsigned i = 0; i < parts.size(); ++i) {
        _cabinMeshes[i] = upload(*parts[i]);
        _cabinCounts[i] = parts[i]->size();
    }
    appendSearchlight(meshes.ship);
    _shipVertices = meshes.ship.size();
    _worldShipMesh = upload(meshes.ship);
    _shipSamples = [device supportsTextureSampleCount:4] ? 4 : 1;
    _worldShip = [self pipeline:library vertex:@"worldShipVertex" fragment:@"worldShipLight"
                                format:MTLPixelFormatRGBA16Float blend:Blend::Hull samples:_shipSamples depth:YES];
    _copyShip = [self pipeline:library vertex:@"fullTriangle" fragment:@"copyShipLight"
                                format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _worldExhaust = [self pipeline:library vertex:@"worldExhaustVertex" fragment:@"worldExhaustLight"
                                     format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _sea = [self pipeline:library vertex:@"fullTriangle" fragment:@"oceanLight" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _currents = [self pipeline:library vertex:@"currentVertex" fragment:@"currentLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _sheets = [self pipeline:library vertex:@"currentSheet" fragment:@"sheetLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _bubbleWakes = [self pipeline:library vertex:@"bubbleWakeVertex" fragment:@"bubbleWakeLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _animal = [self pipeline:library vertex:@"bubbleVertex" fragment:@"bubbleMembrane" format:MTLPixelFormatRGBA16Float blend:Blend::Bubble];
    _systemBubble = [self pipeline:library vertex:@"systemBubbleVertex" fragment:@"systemBubbleLight"
                                  format:MTLPixelFormatRGBA16Float blend:Blend::Bubble];
    _systemSurvey = [self pipeline:library vertex:@"fullTriangle" fragment:@"systemSurveyLight"
                                    format:MTLPixelFormatBGRA8Unorm blend:Blend::Solid];
    if ([device supportsTextureSampleCount:4]) {
        _exteriorAnimal = [self pipeline:library vertex:@"bubbleVertex" fragment:@"bubbleMembrane"
                                   format:MTLPixelFormatRGBA16Float blend:Blend::Bubble samples:4 depth:NO];
        _multisampleSystemBubble = [self pipeline:library vertex:@"systemBubbleVertex" fragment:@"systemBubbleLight"
                                             format:MTLPixelFormatRGBA16Float blend:Blend::Bubble samples:4 depth:NO];
    }
    _copyWater = [self pipeline:library vertex:@"fullTriangle" fragment:@"copyWaterLight" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _bubbleComposite = [self pipeline:library vertex:@"fullTriangle" fragment:@"combineBubbleLight" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _plankton = [self pipeline:library vertex:@"planktonVertex" fragment:@"planktonFragment" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _bloom = [self pipeline:library vertex:@"bloomVertex" fragment:@"planktonFragment" format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _extractGlow = [self pipeline:library vertex:@"fullTriangle" fragment:@"extractGlow" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _spreadGlow = [self pipeline:library vertex:@"fullTriangle" fragment:@"spreadGlow" format:MTLPixelFormatRGBA16Float blend:Blend::Solid];
    _finish = [self pipeline:library vertex:@"fullTriangle" fragment:@"finish" format:MTLPixelFormatBGRA8Unorm blend:Blend::Solid];
    _shipReticle = [self pipeline:library vertex:@"shipReticleVertex" fragment:@"shipReticleLight"
                                  format:MTLPixelFormatBGRA8Unorm blend:Blend::Alpha];
    _bubbleStrings = [self pipeline:library vertex:@"stringStrokeVertex" fragment:@"stringStrokeLight"
                                    format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    _stringContacts = [self pipeline:library vertex:@"stringContactVertex" fragment:@"stringContactLight"
                                      format:MTLPixelFormatRGBA16Float blend:Blend::Alpha];
    const auto high = bubbleIndices<std::uint16_t>(giantMesh), low = bubbleIndices<std::uint16_t>(shoalMesh);
    const auto colossal = bubbleIndices<std::uint32_t>(colossalMesh);
    const auto compact = bubbleIndices<std::uint32_t>(compactColossalMesh);
    const auto ultraColossal = bubbleIndices<std::uint32_t>(ultraColossalMesh);
    const auto ultraGiant = bubbleIndices<std::uint32_t>(ultraGiantMesh);
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
    if (!_colossalIndices || !_compactColossalIndices || !_giantIndices || !_shoalIndices ||
        !_ultraColossalIndices || !_ultraGiantIndices)
        throw std::runtime_error("Could not allocate the mesh index buffers.");
    for (unsigned i = 0; i < 3; ++i) {
        _bellSystems[i] = [device newBufferWithLength:bellSystemCount*sizeof(BellSystem)
                                                options:MTLResourceStorageModeShared];
        _residentCatalogues[i] = [device newBufferWithLength:residentSystemCount*sizeof(SystemBubble)
                                                         options:MTLResourceStorageModeShared];
        if (!_residentCatalogues[i]) throw std::runtime_error("Could not allocate the resident system buffer.");
        std::memset(_residentCatalogues[i].contents,0,_residentCatalogues[i].length);
        _tracerBuffers[i] = [device newBufferWithLength:planktonCount*sizeof(Tracer) options:MTLResourceStorageModeShared];
        _flowBuffers[i] = [device newBufferWithLength:routeLines*flowNodes*sizeof(FlowNode)
                                              options:MTLResourceStorageModeShared];
        _trailBuffers[i] = [device newBufferWithLength:bubbleCount*trailSamples*sizeof(TrailPose) options:MTLResourceStorageModeShared];
        _bubbleBuffers[i] = [device newBufferWithLength:shoalCapacity*sizeof(Bubble) options:MTLResourceStorageModeShared];
    }
    return self;
}
- (id<MTLBuffer>)systemCatalogue:(const Ocean&)ocean {
    const auto systems = ocean.systemBubbles();
    if (!_systemBubbles && !systems.empty()) {
        _systemBubbles = [_device newBufferWithBytes:systems.data() length:systems.size_bytes()
                                            options:MTLResourceStorageModeShared];
        if (!_systemBubbles) throw std::runtime_error("Could not load the Xalaria system bubbles.");
    }
    return _systemBubbles;
}
- (id<MTLBuffer>)bubbleColourTimes:(const Ocean&)ocean {
    if (!_bubbleColourTimes || _bubbleColourRevision != ocean.colourRevision()) {
        const auto times = ocean.systemColourTimes();
        // In-flight frames retain the prior snapshot until their command buffers complete.
        _bubbleColourTimes = [_device newBufferWithBytes:times.data() length:times.size_bytes()
                                                 options:MTLResourceStorageModeShared];
        if (!_bubbleColourTimes) throw std::runtime_error("Could not allocate the bubble colour buffer.");
        _bubbleColourRevision = ocean.colourRevision();
    }
    return _bubbleColourTimes;
}
- (id<MTLCommandBuffer>)survey:(id<MTLTexture>)destination ocean:(const Ocean&)ocean
                        system:(unsigned)system frame:(Quad)frame light:(Quad)light ziksa:(const FlightScene&)ziksa {
    frame.w = float(destination.width)/float(destination.height);
    auto command = [_queue commandBuffer];
    auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    auto draw = [command renderCommandEncoderWithDescriptor:pass];
    [draw setRenderPipelineState:_systemSurvey];
    [draw setFragmentBytes:&frame length:sizeof(frame) atIndex:0];
    [draw setFragmentBytes:&light length:sizeof(light) atIndex:1];
    [draw setFragmentBuffer:[self systemCatalogue:ocean] offset:0 atIndex:2];
    [draw setFragmentBytes:&system length:sizeof(system) atIndex:3];
    [draw setFragmentBytes:&ziksa length:sizeof(ziksa) atIndex:4];
    const auto palette = ocean.bubblePalette({BubbleKind::System,ocean.systemBubbleIds()[system]});
    [draw setFragmentBytes:&palette length:sizeof(palette) atIndex:5];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];
    return command;
}
- (id<MTLCommandBuffer>)render:(id<MTLTexture>)destination ocean:(Ocean&)ocean
                       music:(Quad)music phase:(float)phase style:(GraphicsStyle)style exterior:(bool)exterior
                        guide:(bool)guide aim:(bool)aim searchlight:(bool)searchlight maxWidth:(unsigned)maxWidth
                       flight:(const FlightScene&)flight strings:(const BubbleStrings*)strings toolTime:(double)toolTime
                   inspection:(std::optional<BubbleInspection>*)inspection {
    const float aspect = float(destination.width)/float(destination.height);
    const bool ultra = style == GraphicsStyle::Ultra;
    const auto width = ultra || maxWidth==nativeRenderWidth ? destination.width :
        std::min(destination.width,NSUInteger(maxWidth));
    const auto height = std::max(1UL,(destination.height*width+destination.width/2)/destination.width);
    if (!_light || _light.width != width || _light.height != height) {
        auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                                                   width:width height:height mipmapped:NO];
        d.storageMode = MTLStorageModePrivate;
        d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
        _light = [_device newTextureWithDescriptor:d];
        _light.label = @"Linear ocean and membrane light";
        _waterLight = [_device newTextureWithDescriptor:d];
        _waterLight.label = @"Water light for bubble refraction";
        _bubbleLight = [_device newTextureWithDescriptor:d];
        _bubbleLight.label = @"Weighted sphere membrane light";
        _shipLight = [_device newTextureWithDescriptor:d];
        _shipLight.label = @"World spacecraft radiance and coverage";
        d.pixelFormat = MTLPixelFormatR16Float;
        _shipRange = [_device newTextureWithDescriptor:d];
        auto shipDepth = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                width:width height:height mipmapped:NO];
        shipDepth.usage = MTLTextureUsageRenderTarget;
        shipDepth.storageMode = MTLStorageModeMemoryless;
        if (_shipSamples > 1) {
            shipDepth.textureType = MTLTextureType2DMultisample;
            shipDepth.sampleCount = _shipSamples;
            MTLTextureDescriptor* hullSurface = [shipDepth copy];
            hullSurface.pixelFormat = MTLPixelFormatRGBA16Float;
            _shipMSAALight = [_device newTextureWithDescriptor:hullSurface];
            hullSurface.pixelFormat = MTLPixelFormatR16Float;
            _shipMSAARange = [_device newTextureWithDescriptor:hullSurface];
        }
        _shipDepth = [_device newTextureWithDescriptor:shipDepth];
        d.pixelFormat = MTLPixelFormatRG16Float;
        _bubbleTransmission = [_device newTextureWithDescriptor:d];
        _bubbleTransmission.label = @"Membrane and current transmission";
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
    }
    const bool antialias = exterior || ultra;
    if (antialias && _exteriorAnimal && !_exteriorLight) {
        // Keep samples in tile memory and resolve into the regular compositing textures.
        auto d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:_bubbleLight.pixelFormat
                                                                   width:width height:height mipmapped:NO];
        d.textureType = MTLTextureType2DMultisample;
        d.sampleCount = 4;
        d.storageMode = MTLStorageModeMemoryless;
        d.usage = MTLTextureUsageRenderTarget;
        _exteriorLight = [_device newTextureWithDescriptor:d];
        d.pixelFormat = _bubbleTransmission.pixelFormat;
        _exteriorTransmission = [_device newTextureWithDescriptor:d];
    }
    const bool multisample = antialias && _exteriorLight && _exteriorTransmission;
    Scene scene = ocean.scene(aspect,exterior);
    // Filter orbital silhouettes and rings against the pixels actually shading them.
    scene.orbitalPixel = 2.f/(1.94f*float(height));
    scene.music = music;
    scene.call.w = phase;
    scene.graphicsStyle = exterior && !ultra ? GraphicsStyle::Original : style;
    const auto ship = ocean.shipPose(scene);
    if (searchlight && ship.drive.y > 0.f) {
        const auto& p = ship.position;
        const auto& f = ship.forward;
        const auto& u = ship.up;
        scene.searchlightOrigin = {p.x+p.w*(searchlightTip*f.x+searchlightHeight*u.x),
                                   p.y+p.w*(searchlightTip*f.y+searchlightHeight*u.y),
                                   p.z+p.w*(searchlightTip*f.z+searchlightHeight*u.z),82.f*p.w};
        scene.searchlightAxis = {f.x,f.y,f.z,ship.drive.y};
    }
    HullLight hullLight{};
    const auto shoal = exterior ? std::span<const Bubble>{} : ocean.shoal(scene,_visibleBubbles,ship.drive.y>0.f ? &hullLight : nullptr);
    if (inspection) *inspection = inspectBubble(ocean,scene,shoal);
    const bool showStrings = strings && !exterior && !ocean.transforming() && !ocean.returning();
    const Quad sight = showStrings ? strings->compose(ocean,scene,ship,shoal,aim && !ocean.demo,
                                                       toolTime,_stringStrokes,_stringAttachments) : Quad{};
    // Draws are submitted in order, with at most two frames waiting on the GPU.
    const unsigned slot = _tracerSlot++ % 3;
    const auto systems = _bellSystems[slot];
    VisibleSystems visibleSystems;
    for (unsigned i = 0; i < (exterior ? 1 : regionScales); ++i) visibleSystems.set(i);
    if (scene.playerSystem > 0.f)
        visibleSystems.set(unsigned(scene.playerSystem)-1);
    for (const auto& bubble : shoal) {
        if (bubble.bellSystem > 0.f) visibleSystems.set(unsigned(bubble.bellSystem)-1);
    }
    ocean.writeBellSystems(
        std::span<BellSystem,bellSystemCount>(static_cast<BellSystem*>(systems.contents),bellSystemCount),
        visibleSystems);
    const auto residents = _residentCatalogues[slot];
    auto* models = static_cast<SystemBubble*>(residents.contents);
    for (unsigned i = 0; i < residentSystemCount; ++i) {
        if (!visibleSystems[i]) continue;
        const auto& record = ocean.residentSystem(i);
        if (models[i].star.w == 0.f || unsigned(models[i].catalogue.x) != record.id)
            models[i] = systemModel(record);
    }
    std::array<Bubble,bellPassageCount> gates{};
    if (ocean.openingRoute()) {
        for (unsigned i = 0; i < gates.size(); ++i)
            if (const auto gate = ocean.stringBubble(i+2,scene)) gates[i] = *gate;
    }
    const auto nestedSystems = [self systemCatalogue:ocean];
    const auto tracers = _tracerBuffers[slot];
    const auto field = _flowBuffers[slot];
    const auto wakes = _trailBuffers[slot];
    const auto bubbles = _bubbleBuffers[slot];
    const bool opening = ocean.openingRoute();
    const bool movingWater = !exterior && scene.cycle.z < 1.f && scene.basinArrival > 0.f;
    auto cmd = [_queue commandBuffer];
    const std::array<std::uint32_t,4> trailLayout{
        ocean.trailHead(),ocean.trailsRecorded(),trailSamples,bubbleCount
    };
    if (movingWater) {
        std::memcpy(bubbles.contents,shoal.data(),shoal.size()*sizeof(Bubble));
        std::memcpy(tracers.contents,ocean.tracers().data(),planktonCount*sizeof(Tracer));
        const auto ribbonCount = opening ? routeLines : flowLines;
        std::memcpy(field.contents,ocean.ribbons().data(),ribbonCount*flowNodes*sizeof(FlowNode));
        std::memcpy(wakes.contents,ocean.trailPoses().data(),trailLayout[1]*bubbleCount*sizeof(TrailPose));
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
    [draw setFragmentBuffer:residents offset:0 atIndex:5];
    [draw setFragmentBytes:gates.data() length:sizeof(gates) atIndex:6];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:2];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (movingWater && trailLayout[1] > 0) {
        [draw setRenderPipelineState:_bubbleWakes];
        [draw setVertexBuffer:wakes offset:0 atIndex:5];
        [draw setVertexBytes:&trailLayout length:sizeof(trailLayout) atIndex:6];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:trailLayout[1]*bubbleCount*6];
    }
    [draw endEncoding];

    auto shipPass = [MTLRenderPassDescriptor renderPassDescriptor];
    const auto shipAttachment = [&](NSUInteger index,id<MTLTexture> resolved,id<MTLTexture> sampled) {
        auto color = shipPass.colorAttachments[index];
        color.texture = sampled ? sampled : resolved;
        color.resolveTexture = sampled ? resolved : nil;
        color.loadAction = MTLLoadActionClear;
        color.storeAction = sampled ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
        color.clearColor = MTLClearColorMake(0,0,0,0);
    };
    shipAttachment(0,_shipLight,_shipMSAALight);
    shipAttachment(1,_shipRange,_shipMSAARange);
    shipPass.depthAttachment.texture = _shipDepth;
    shipPass.depthAttachment.loadAction = MTLLoadActionClear;
    shipPass.depthAttachment.clearDepth = 1.;
    shipPass.depthAttachment.storeAction = MTLStoreActionDontCare;
    draw = [cmd renderCommandEncoderWithDescriptor:shipPass];
    if (ship.drive.y > 0.f) {
        [draw setRenderPipelineState:_worldShip];
        [draw setDepthStencilState:_cabinDepthState];
        [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
        [draw setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
        [draw setVertexBuffer:_worldShipMesh offset:0 atIndex:1];
        [draw setVertexBytes:&ship length:sizeof(ship) atIndex:2];
        [draw setFragmentBytes:&ship length:sizeof(ship) atIndex:2];
        [draw setFragmentBytes:hullLight.data() length:sizeof(hullLight) atIndex:3];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_shipVertices];
    }
    [draw endEncoding];

    auto translucent = [MTLRenderPassDescriptor renderPassDescriptor];
    translucent.colorAttachments[0].texture = multisample ? _exteriorLight : _bubbleLight;
    translucent.colorAttachments[0].loadAction = MTLLoadActionClear;
    translucent.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
    translucent.colorAttachments[0].storeAction = multisample ? MTLStoreActionMultisampleResolve : MTLStoreActionStore;
    translucent.colorAttachments[1].texture = multisample ? _exteriorTransmission : _bubbleTransmission;
    translucent.colorAttachments[1].loadAction = MTLLoadActionClear;
    translucent.colorAttachments[1].clearColor = MTLClearColorMake(1,1,1,1);
    translucent.colorAttachments[1].storeAction = translucent.colorAttachments[0].storeAction;
    if (multisample) {
        translucent.colorAttachments[0].resolveTexture = _bubbleLight;
        translucent.colorAttachments[1].resolveTexture = _bubbleTransmission;
    }
    draw = [cmd renderCommandEncoderWithDescriptor:translucent];
    [draw setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setRenderPipelineState:multisample ? _exteriorAnimal : _animal];
    [draw setFragmentBuffer:systems offset:0 atIndex:1];
    [draw setFragmentBuffer:residents offset:0 atIndex:5];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:2];
    [draw setFragmentTexture:_waterLight atIndex:0];
    [draw setFragmentTexture:_shipLight atIndex:3];
    [draw setFragmentTexture:_shipRange atIndex:4];
    [draw setVertexBuffer:bubbles offset:0 atIndex:1];
    const bool compact = width < destination.width && width <= 1024;
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
        [draw drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:mesh.indices()
                          indexType:(colossal || dense ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16) indexBuffer:indices
                   indexBufferOffset:0 instanceCount:end-first baseVertex:0 baseInstance:first];
        first = end;
    }
    if (!shoal.empty() && nestedSystems) {
        const auto regions = ocean.regions();
        [draw setRenderPipelineState:multisample ? _multisampleSystemBubble : _systemBubble];
        [draw setVertexBuffer:nestedSystems offset:0 atIndex:2];
        [draw setVertexBuffer:systems offset:0 atIndex:4];
        [draw setFragmentBuffer:nestedSystems offset:0 atIndex:3];
        [draw setFragmentBuffer:[self bubbleColourTimes:ocean] offset:0 atIndex:7];
        for (std::uint32_t i = 0; i < shoal.size(); ++i) {
            const unsigned slot = unsigned(shoal[i].bellSystem);
            if (slot <= residentSystemCount) continue;
            const auto& region = regions[slot-residentSystemCount-1];
            [draw setVertexBytes:&i length:sizeof(i) atIndex:3];
            [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
                   instanceCount:region.systems baseInstance:region.firstSystem];
        }
    }
    [draw endEncoding];

    pass.colorAttachments[0].texture = _light;
    draw = [cmd renderCommandEncoderWithDescriptor:pass];
    [draw setRenderPipelineState:_copyWater];
    [draw setFragmentTexture:_waterLight atIndex:0];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];

    // Keep the fast water details out of the membrane refraction.
    [draw setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    [draw setFragmentTexture:_bubbleTransmission atIndex:2];
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
    if (ship.drive.y > 0.f) {
        if (ship.drive.x > .028f) {
            [draw setRenderPipelineState:_worldExhaust];
            [draw setVertexBytes:&ship length:sizeof(ship) atIndex:2];
            [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:96];
        }
        [draw setRenderPipelineState:_copyShip];
        [draw setFragmentTexture:_shipLight atIndex:3];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    }
    if (showStrings && !_stringStrokes.empty()) {
        // The filament is lit and composited with the ocean before the final bloom and grade.
        const Quad display{aspect,float(height)};
        [draw setRenderPipelineState:_bubbleStrings];
        [draw setVertexBytes:&display length:sizeof(display) atIndex:0];
        [draw setFragmentTexture:_shipLight atIndex:3];
        [draw setFragmentTexture:_shipRange atIndex:4];
        constexpr std::size_t batch = 64;
        for (std::size_t offset = 0; offset < _stringStrokes.size(); offset += batch) {
            const auto count = std::min(batch,_stringStrokes.size()-offset);
            [draw setVertexBytes:_stringStrokes.data()+offset length:count*sizeof(StringStroke) atIndex:1];
            [draw drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4 instanceCount:count];
        }
    }
    [draw setRenderPipelineState:_bubbleComposite];
    [draw setFragmentTexture:_bubbleLight atIndex:1];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (showStrings && !_stringAttachments.empty()) {
        [draw setRenderPipelineState:_stringContacts];
        [draw setVertexBytes:&scene length:sizeof(scene) atIndex:0];
        [draw setFragmentTexture:_shipLight atIndex:3];
        [draw setFragmentTexture:_shipRange atIndex:4];
        constexpr std::size_t batch = 48;
        for (std::size_t offset = 0; offset < _stringAttachments.size(); offset += batch) {
            const auto count = std::min(batch,_stringAttachments.size()-offset);
            [draw setVertexBytes:_stringAttachments.data()+offset length:count*sizeof(StringContact) atIndex:1];
            [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:96 instanceCount:count];
        }
    }
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

    // Reconstruct and grade the scene directly at the drawable resolution.
    pass.colorAttachments[0].texture = destination;
    pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    auto post = [cmd renderCommandEncoderWithDescriptor:pass];
    [post setRenderPipelineState:_finish];
    [post setFragmentTexture:_light atIndex:0];
    [post setFragmentTexture:_nearGlow atIndex:1];
    [post setFragmentTexture:_farGlow atIndex:2];
    [post setFragmentTexture:_shipLight atIndex:3];
    [post setFragmentTexture:_shipRange atIndex:4];
    [post setFragmentBytes:&scene length:sizeof(scene) atIndex:0];
    const Quad marker = guide ? ocean.flightGuide(scene) : Quad{};
    [post setFragmentBytes:&marker length:sizeof(marker) atIndex:1];
    [post drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (sight.w > 0.f) {
        const Quad display{aspect};
        [post setRenderPipelineState:_shipReticle];
        [post setVertexBytes:&display length:sizeof(display) atIndex:0];
        [post setVertexBytes:&sight length:sizeof(sight) atIndex:1];
        [post drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    }
    [post endEncoding];
    return cmd;
}
- (void)uploadTerrain:(std::array<TerrainStyle,ziksaBodyCount>&)styles patch:(Quad&)patchCoordinates
               scene:(const FlightScene&)flight
              system:(unsigned)system pilot:(const ShipFlight&)pilot height:(NSUInteger)height
             command:(id<MTLCommandBuffer>)command {
    constexpr float halfFovTan = .70020754f;
    const float aspectSlope = halfFovTan*flight.screen.x;
    const auto xyz = [](Quad value) -> simd_float3 { return {value.x,value.y,value.z}; };
    std::array<std::pair<float,unsigned>,ziksaBodyCount> visible;
    std::size_t count = 0;
    for (unsigned i=1; i<unsigned(flight.navigation.z); ++i) {
        const auto& body = flight.bodies[i];
        if (body.surface.x>.5f || body.position.w<=0.f) continue;
        const auto centre = xyz(body.position)-xyz(flight.eye);
        const float radius = body.position.w*1.02f;
        const float range = simd_length(centre);
        const float screenRadius = radius*float(height)/(2.f*halfFovTan*std::max(radius,range));
        const float ahead = simd_dot(centre,xyz(flight.forward));
        if (screenRadius<3.f || ahead< -radius ||
            std::abs(simd_dot(centre,xyz(flight.right)))>ahead*aspectSlope+radius*std::hypot(1.f,aspectSlope) ||
            std::abs(simd_dot(centre,xyz(flight.up)))>ahead*halfFovTan+radius*std::hypot(1.f,halfFovTan)) continue;
        visible[count++] = {screenRadius,i};
    }
    std::sort(visible.begin(),visible.begin()+count,std::greater<>());
    id<MTLBlitCommandEncoder> upload = nil;
    constexpr NSUInteger rowBytes = terrainFaceSize*sizeof(Quad);
    constexpr NSUInteger alignedRowBytes = (rowBytes+255)/256*256;
    constexpr NSUInteger imageBytes = alignedRowBytes*terrainFaceSize;
    const auto stage = [&](const std::vector<Quad>& texels,NSUInteger slices,NSUInteger firstSlice) {
        auto staging = [_device newBufferWithLength:slices*imageBytes options:MTLResourceStorageModeShared];
        if (!staging) throw std::runtime_error("The Xalaria terrain upload could not be allocated.");
        auto* bytes = static_cast<std::uint8_t*>(staging.contents);
        if (!upload) upload = [command blitCommandEncoder];
        for (NSUInteger face=0; face<slices; ++face) {
            for (NSUInteger row=0; row<terrainFaceSize; ++row) {
                const auto* source = texels.data()+(face*terrainFaceSize+row)*terrainFaceSize;
                std::memcpy(bytes+face*imageBytes+row*alignedRowBytes,source,rowBytes);
            }
            [upload copyFromBuffer:staging sourceOffset:face*imageBytes sourceBytesPerRow:alignedRowBytes
                  sourceBytesPerImage:imageBytes sourceSize:MTLSizeMake(terrainFaceSize,terrainFaceSize,1)
                  toTexture:_terrainAtlas destinationSlice:firstSlice+face destinationLevel:0
                  destinationOrigin:MTLOriginMake(0,0,0)];
        }
    };
    unsigned closeIndex = 0;
    float closeRange = 1.04f;
    for (std::size_t j=0; j<count; ++j) {
        const auto i = visible[j].second;
        const auto globe = _terrainFields->globe(system,pilot.bodyName(i));
        if (!globe) continue;
        styles[i] = globe->style;
        const auto body = flight.bodies[i].position;
        const auto range = simd_length(xyz(body)-xyz(flight.eye))/body.w;
        if (range<closeRange && range>.95f) {
            closeIndex = i;
            closeRange = range;
        }
        if (_residentTerrain[i]!=globe) {
            stage(globe->texels,terrainFaceCount,i*terrainFaceCount);
            _residentTerrain[i] = globe;
        }
    }
    if (closeIndex>0) {
        const auto direction = simd_normalize(xyz(flight.eye)-xyz(flight.bodies[closeIndex].position));
        const auto patch = _terrainFields->patch(system,pilot.bodyName(closeIndex),
                                                {direction.x,direction.y,direction.z},closeRange);
        if (patch) {
            if (_residentTerrainPatch!=patch) {
                stage(patch->texels,1,terrainFaceCount*ziksaBodyCount);
                _residentTerrainPatch = patch;
            }
            patchCoordinates = patch->coordinates;
            patchCoordinates.x += float(closeIndex*8+1);
        }
    }
    [upload endEncoding];
}

- (id<MTLCommandBuffer>)fly:(id<MTLTexture>)destination scene:(const FlightScene&)incomingFlight
                       ocean:(const Ocean&)ocean pilot:(const ShipFlight&)pilot {
    if (_cabinDepth.width != destination.width || _cabinDepth.height != destination.height) {
        auto info = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                     width:destination.width height:destination.height mipmapped:NO];
        info.storageMode = MTLStorageModePrivate;
        info.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        _flightRadiance = [_device newTextureWithDescriptor:info];
        _flightRadiance.label = @"Xalaria celestial HDR";
        _flightOptical = [_device newTextureWithDescriptor:info];
        _flightOptical.label = @"Xalaria refracted exterior HDR";
        _flightExterior = [_device newTextureWithDescriptor:info];
        _flightExterior.label = @"Xalaria exterior lens";
        _flightCabinColour = [_device newTextureWithDescriptor:info];
        _flightCabinColour.label = @"Xalaria cabin colour and coverage";
        _flightFinish = [_device newTextureWithDescriptor:info];
        _flightFinish.label = @"Xalaria rings / cabin finish";
        info.pixelFormat = MTLPixelFormatR32Float;
        _flightDepth = [_device newTextureWithDescriptor:info];
        _flightDepth.label = @"Xalaria exterior depth in metres";
        info.pixelFormat = MTLPixelFormatDepth32Float;
        _cabinDepth = [_device newTextureWithDescriptor:info];
        info.usage = MTLTextureUsageRenderTarget;
        _flightZ = [_device newTextureWithDescriptor:info];
        _flightZ.label = @"Xalaria exterior inverse depth";
        info.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        info.pixelFormat = MTLPixelFormatRGBA16Float;
        info.width = std::max(1UL,destination.width/3);
        info.height = std::max(1UL,destination.height/3);
        _flightGlow = [_device newTextureWithDescriptor:info];
        info.mipmapLevelCount = 1+NSUInteger(std::log2(std::max(info.width,info.height)));
        _flightLightSeed = [_device newTextureWithDescriptor:info];
        _flightLightSeed.label = @"Xalaria aperture light seed";
        const double cloudScale = std::min({1./3.,960./destination.width,600./destination.height});
        info.mipmapLevelCount = 1;
        info.width = std::max(1UL,NSUInteger(destination.width*cloudScale));
        info.height = std::max(1UL,NSUInteger(destination.height*cloudScale));
        _flightCloud = [_device newTextureWithDescriptor:info];
        _flightCloud.label = @"Xalaria volumetric clouds";
        if (!_flightRadiance || !_flightOptical || !_flightExterior || !_flightCabinColour || !_flightFinish ||
            !_cabinDepth || !_flightZ || !_flightGlow || !_flightLightSeed || !_flightDepth || !_flightCloud)
            throw std::runtime_error("The Xalaria cockpit targets could not be allocated.");
    }
    auto flight = incomingFlight;
    const auto now = CACurrentMediaTime();
    const auto delta = _lastWeatherFrame == 0. ? 1./60. : std::min(now-_lastWeatherFrame,.25);
    _lastWeatherFrame = now;
    const auto fields = _weather->prepare(pilot,flight,delta,_flightCloud.width,_flightCloud.height);
    auto weatherTextures = _weatherTextures;
    for (std::size_t i=0; i<fields.size(); ++i) {
        const auto& field = fields[i];
        if (!field) {
            weatherTextures[i] = _noCloud;
            continue;
        }
        const auto resident = std::find(_weatherFields.begin(),_weatherFields.end(),field);
        if (resident != _weatherFields.end()) {
            weatherTextures[i] = _weatherTextures[resident-_weatherFields.begin()];
            continue;
        }
        if (i>0 && field==fields[0]) {
            weatherTextures[i] = weatherTextures[0];
            continue;
        }
        weatherTextures[i] = [self uploadMaterial:field->pixels width:XalariaWeatherField::width
                                           height:XalariaWeatherField::height label:@"Xalaria weather atlas"];
    }
    _weatherFields = fields;
    _weatherTextures = weatherTextures;
    FlightTerrainMaterialFrame materialFrame{};
    FlightTerrainSun sun{};
    std::shared_ptr<const XalariaTerrainMesh> surfaceMesh;
    id<MTLBuffer> surfaceVertices = nil;
    const unsigned terrainBody = unsigned(flight.terrainView.x);
    if (!pilot.region() && terrainBody>0 && terrainBody<unsigned(flight.navigation.z)) {
        const auto eyeHigh = flight.terrainEye;
        const auto eyeLow = flight.terrainEyeResidual;
        const std::array eye{double(eyeHigh.x)+eyeLow.x,double(eyeHigh.y)+eyeLow.y,double(eyeHigh.z)+eyeLow.z};
        const auto name = pilot.bodyName(terrainBody);
        surfaceMesh = _terrainFields->tiles(pilot.systemId(),name,eye,unsigned(destination.height));
        if (surfaceMesh && !surfaceMesh->indices.empty()) {
            const double radius = surfaceMesh->radiusMetres;
            const auto period = [](double value,double repeat) { return value-std::floor(value/repeat)*repeat; };
            const auto micro = [&](unsigned axis) { return float(period(eye[axis]/8.,64.)); };
            const auto meso = [&](unsigned axis) { return period(eye[axis]/256.,4096.); };
            const auto cell = [&](unsigned axis) { return float(std::floor(meso(axis)/16.)*16.); };
            materialFrame.planetEye = {float(eye[0]/radius),float(eye[1]/radius),float(eye[2]/radius),float(terrainBody)};
            materialFrame.microOrigin = {micro(0),micro(1),micro(2)};
            materialFrame.mesoOriginHigh = {cell(0),cell(1),cell(2)};
            materialFrame.mesoOriginLow = {float(meso(0)-cell(0)),float(meso(1)-cell(1)),float(meso(2)-cell(2))};
            sun = terrainSun(*_terrainFields,pilot.systemId(),name,eye,radius,flight.bodies[0].position,
                             flight.bodies[terrainBody].position);
            const auto& vertices = surfaceMesh->vertices;
            surfaceVertices = [_device newBufferWithLength:vertices.size()*sizeof(FlightTerrainVertex)
                                                    options:MTLResourceStorageModeShared];
            if (!surfaceVertices) throw std::runtime_error("The Xalaria terrain vertices could not be allocated.");
            surfaceVertices.label = @"Xalaria camera-relative terrain vertices";
            auto* output = static_cast<FlightTerrainVertex*>(surfaceVertices.contents);
            if (surfaceMesh!=_residentTerrainMesh) {
                const auto& indices = surfaceMesh->indices;
                _terrainIndices = [_device newBufferWithBytes:indices.data() length:indices.size()*sizeof(indices[0])
                                                       options:MTLResourceStorageModeShared];
                if (!_terrainIndices) throw std::runtime_error("The Xalaria terrain indices could not be allocated.");
                _terrainIndices.label = @"Xalaria stitched terrain indices";
                _residentTerrainMesh = surfaceMesh;
                _terrainMorphAt = now;
            }
            const double age = std::clamp((now-_terrainMorphAt)/.2,0.,1.);
            const auto& prior = surfaceMesh->morphFrom;
            const double blend = prior.empty() ? 1. : age*age*(3.-2.*age);
            for (std::size_t i=0; i<vertices.size(); ++i) {
                const auto& vertex = vertices[i];
                auto point = vertex.position;
                auto normal = vertex.normal;
                if (blend<1.) {
                    for (unsigned axis=0; axis<point.size(); ++axis)
                        point[axis] = std::lerp(prior[i][axis],point[axis],blend);
                    normal.w = float(std::hypot(point[0],point[1],point[2])-1.);
                }
                const Quad position{float(std::fma(point[0],radius,-eye[0])),
                                    float(std::fma(point[1],radius,-eye[1])),
                                    float(std::fma(point[2],radius,-eye[2]))};
                *output++ = {position,vertex.colour,normal};
            }
            flight.terrainView.y = float(terrainBody);
        }
    }
    const auto instruments = xalariaInstruments(pilot,flight,ocean,pilot.hudVisibility());
    const auto bufferFor = [&](const auto& vertices) -> id<MTLBuffer> {
        if (vertices.empty()) return nil;
        return [_device newBufferWithBytes:vertices.data() length:vertices.size()*sizeof(InstrumentVertex)
                                    options:MTLResourceStorageModeShared];
    };
    const auto screenInk = bufferFor(instruments.screens);
    const auto overlayInk = bufferFor(instruments.overlay);
    auto command = [_queue commandBuffer];
    std::array<TerrainStyle,ziksaBodyCount> terrainStyles{};
    Quad terrainPatch{};
    if (!pilot.region())
        [self uploadTerrain:terrainStyles patch:terrainPatch scene:flight system:pilot.systemId() pilot:pilot
                      height:destination.height command:command];
    if (surfaceVertices && sun.settings.x>0.f) {
        auto shadow = [MTLRenderPassDescriptor renderPassDescriptor];
        shadow.depthAttachment.texture = _terrainShadowMap;
        shadow.depthAttachment.loadAction = MTLLoadActionClear;
        shadow.depthAttachment.clearDepth = 1.;
        shadow.depthAttachment.storeAction = MTLStoreActionStore;
        auto cast = [command renderCommandEncoderWithDescriptor:shadow];
        [cast setRenderPipelineState:_flightTerrainShadow];
        [cast setDepthStencilState:_terrainShadowDepthState];
        [cast setVertexBuffer:surfaceVertices offset:0 atIndex:0];
        [cast setVertexBytes:&sun length:sizeof(sun) atIndex:4];
        [cast drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:surfaceMesh->indices.size()
                          indexType:MTLIndexTypeUInt32 indexBuffer:_terrainIndices indexBufferOffset:0];
        [cast endEncoding];
    }
    const auto passFor = [](id<MTLTexture> target) {
        auto pass = [MTLRenderPassDescriptor renderPassDescriptor];
        pass.colorAttachments[0].texture = target;
        pass.colorAttachments[0].loadAction = MTLLoadActionDontCare;
        pass.colorAttachments[0].storeAction = MTLStoreActionStore;
        return pass;
    };
    auto exterior = passFor(_flightRadiance);
    // Rings resolve before the cabin overwrites this transient attachment.
    exterior.colorAttachments[1].texture = _flightFinish;
    exterior.colorAttachments[1].loadAction = MTLLoadActionDontCare;
    exterior.colorAttachments[1].storeAction = MTLStoreActionStore;
    exterior.colorAttachments[2].texture = _flightDepth;
    exterior.colorAttachments[2].loadAction = MTLLoadActionDontCare;
    exterior.colorAttachments[2].storeAction = MTLStoreActionStore;
    exterior.depthAttachment.texture = _flightZ;
    exterior.depthAttachment.loadAction = MTLLoadActionClear;
    exterior.depthAttachment.clearDepth = 0.;
    exterior.depthAttachment.storeAction = MTLStoreActionDontCare;
    auto draw = [command renderCommandEncoderWithDescriptor:exterior];
    [draw setRenderPipelineState:_flightSky];
    [draw setDepthStencilState:_skyDepthState];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:0];
    [draw setFragmentTexture:weatherTextures[0] atIndex:5];
    [draw setFragmentTexture:weatherTextures[1] atIndex:6];
    [draw setFragmentTexture:_terrainAtlas atIndex:8];
    [draw setFragmentBytes:terrainStyles.data() length:sizeof(terrainStyles) atIndex:8];
    [draw setFragmentBytes:&terrainPatch length:sizeof(terrainPatch) atIndex:10];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (surfaceVertices) {
        [draw setRenderPipelineState:_flightTerrain];
        [draw setDepthStencilState:_terrainDepthState];
        [draw setVertexBuffer:surfaceVertices offset:0 atIndex:0];
        [draw setVertexBytes:&flight length:sizeof(flight) atIndex:1];
        [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:1];
        [draw setVertexBytes:&materialFrame length:sizeof(materialFrame) atIndex:2];
        [draw setFragmentBytes:&materialFrame length:sizeof(materialFrame) atIndex:2];
        [draw setFragmentBytes:&surfaceMesh->style length:sizeof(surfaceMesh->style) atIndex:3];
        [draw setFragmentBytes:&sun length:sizeof(sun) atIndex:4];
        [draw setFragmentTexture:_terrainDetail atIndex:9];
        [draw setFragmentTexture:_terrainShadowMap atIndex:10];
        [draw drawIndexedPrimitives:MTLPrimitiveTypeTriangle indexCount:surfaceMesh->indices.size()
                          indexType:MTLIndexTypeUInt32 indexBuffer:_terrainIndices indexBufferOffset:0];
    }
    [draw endEncoding];
    const bool weatherVisible = flight.cloudShell.w>0.f && fields[0] && fields[1];
    if (weatherVisible) {
        draw = [command renderCommandEncoderWithDescriptor:passFor(_flightCloud)];
        [draw setRenderPipelineState:_flightCloudVolume];
        [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:0];
        [draw setFragmentTexture:_flightDepth atIndex:0];
        [draw setFragmentTexture:weatherTextures[0] atIndex:1];
        [draw setFragmentTexture:weatherTextures[1] atIndex:2];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        [draw endEncoding];
    }

    draw = [command renderCommandEncoderWithDescriptor:passFor(_flightOptical)];
    [draw setRenderPipelineState:_flightOptics];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:0];
    [draw setFragmentTexture:_flightRadiance atIndex:0];
    [draw setFragmentTexture:_flightFinish atIndex:1];
    [draw setFragmentTexture:_flightDepth atIndex:2];
    [draw setFragmentTexture:weatherVisible ? _flightCloud : _noCloud atIndex:3];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];

    draw = [command renderCommandEncoderWithDescriptor:passFor(_flightLightSeed)];
    [draw setRenderPipelineState:_flightLensSeed];
    [draw setFragmentTexture:_flightOptical atIndex:0];
    [draw setFragmentTexture:_flightDepth atIndex:1];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];
    auto mipmaps = [command blitCommandEncoder];
    [mipmaps generateMipmapsForTexture:_flightLightSeed];
    [mipmaps endEncoding];

    draw = [command renderCommandEncoderWithDescriptor:passFor(_flightGlow)];
    [draw setRenderPipelineState:_flightBokeh];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:0];
    [draw setFragmentTexture:_flightLightSeed atIndex:0];
    [draw setFragmentTexture:_flightDepth atIndex:1];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];

    draw = [command renderCommandEncoderWithDescriptor:passFor(_flightExterior)];
    [draw setRenderPipelineState:_flightLens];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:0];
    const auto* region = pilot.region();
    const auto bubble = region ? BubbleId{BubbleKind::Region,region->cell} : BubbleId{BubbleKind::System,pilot.systemId()};
    auto palette = !region && pilot.systemId()==ziksaSystemId ? ocean.bubblePalette(bubble,regionScales-1) :
                                                               ocean.bubblePalette(bubble);
    if (const auto tint=pilot.bubbleTint()) palette={tint->x,tint->y,tint->z,palette.w};
    [draw setFragmentBytes:&palette length:sizeof(palette) atIndex:1];
    [draw setFragmentTexture:_flightOptical atIndex:0];
    [draw setFragmentTexture:_flightGlow atIndex:1];
    [draw setFragmentTexture:_flightDepth atIndex:2];
    [draw setFragmentTexture:_flightLightSeed atIndex:3];
    [draw setFragmentTexture:weatherVisible ? _flightCloud : _noCloud atIndex:4];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (region) {
        const auto systems = [self systemCatalogue:ocean];
        const float time = float(ocean.orbitalTime());
        [draw setRenderPipelineState:_flightRegion];
        [draw setVertexBytes:&flight length:sizeof(flight) atIndex:0];
        [draw setVertexBuffer:systems offset:0 atIndex:1];
        [draw setFragmentBuffer:systems offset:0 atIndex:1];
        [draw setFragmentBuffer:[self bubbleColourTimes:ocean] offset:0 atIndex:2];
        [draw setFragmentBytes:&time length:sizeof(time) atIndex:3];
        [draw setFragmentBytes:&palette length:sizeof(palette) atIndex:4];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6
               instanceCount:region->systems baseInstance:region->firstSystem];
    }
    [draw endEncoding];

    auto cabin = passFor(_flightCabinColour);
    cabin.colorAttachments[0].loadAction = MTLLoadActionClear;
    cabin.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0);
    cabin.colorAttachments[1].texture = _flightFinish;
    cabin.colorAttachments[1].loadAction = MTLLoadActionClear;
    cabin.colorAttachments[1].storeAction = MTLStoreActionStore;
    cabin.colorAttachments[1].clearColor = MTLClearColorMake(0,0,0,0);
    cabin.depthAttachment.texture = _cabinDepth;
    cabin.depthAttachment.loadAction = MTLLoadActionClear;
    cabin.depthAttachment.clearDepth = 1.;
    cabin.depthAttachment.storeAction = MTLStoreActionStore;
    draw = [command renderCommandEncoderWithDescriptor:cabin];
    [draw setRenderPipelineState:_flightCabin];
    [draw setDepthStencilState:_cabinDepthState];
    [draw setVertexBytes:&flight length:sizeof(flight) atIndex:0];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:0];
    const auto part = [&](unsigned i,std::uint32_t pose) {
        [draw setVertexBytes:&pose length:sizeof(pose) atIndex:2];
        [draw setVertexBuffer:_cabinMeshes[i] offset:0 atIndex:1];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:_cabinCounts[i]];
    };
    part(0,0); part(1,0); part(1,3); part(2,0); part(3,1); part(4,2);
    [draw setRenderPipelineState:_flightGlass];
    [draw setDepthStencilState:_cabinGlassDepth];
    [draw setFragmentTexture:_flightExterior atIndex:0];
    part(5,0);
    if (screenInk) {
        [draw setRenderPipelineState:_flightScreens];
        [draw setVertexBuffer:screenInk offset:0 atIndex:1];
        [draw setFragmentTexture:_flightFont atIndex:0];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:instruments.screens.size()];
    }
    [draw endEncoding];
    draw = [command renderCommandEncoderWithDescriptor:passFor(_flightGlow)];
    [draw setRenderPipelineState:_flightGlare];
    [draw setFragmentTexture:_flightCabinColour atIndex:0];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    [draw endEncoding];

    draw = [command renderCommandEncoderWithDescriptor:passFor(destination)];
    [draw setRenderPipelineState:_flightComposite];
    [draw setFragmentBytes:&flight length:sizeof(flight) atIndex:0];
    [draw setFragmentTexture:_flightExterior atIndex:0];
    [draw setFragmentTexture:_flightGlow atIndex:1];
    [draw setFragmentTexture:_flightCabinColour atIndex:2];
    [draw setFragmentTexture:_cabinDepth atIndex:3];
    [draw setFragmentTexture:_flightFinish atIndex:4];
    [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    if (overlayInk) {
        [draw setRenderPipelineState:_flightOverlay];
        [draw setVertexBytes:&flight length:sizeof(flight) atIndex:0];
        [draw setVertexBuffer:overlayInk offset:0 atIndex:1];
        [draw setFragmentTexture:_flightFont atIndex:0];
        [draw drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:instruments.overlay.size()];
    }
    [draw endEncoding];
    return command;
}
@end

@interface Controls : MTKView
@property(nonatomic, copy) void (^keyChange)(NSEvent*, BOOL);
@property(nonatomic, copy) void (^motion)(CGFloat, CGFloat);
@property(nonatomic, copy) void (^clearKeys)(void);
@property(nonatomic, copy) void (^callChange)(BOOL);
@property(nonatomic, copy) void (^fireTool)(void);
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
- (void)rightMouseDown:(NSEvent*)event {
    if (self.fireTool) self.fireTool();
}
- (void)rightMouseDragged:(NSEvent*)event { [self mouseMoved:event]; }
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
static NSString* layerTitle(unsigned layer) {
    constexpr std::array<const char*,regionScales> names{
        "Lantern Basin","Amber Garden","Cobalt Gloam","Viridian Fold","Carmine Deep","The Whirlpool"
    };
    return [NSString stringWithUTF8String:names[layer]];
}
static void circle(NSPoint centre, CGFloat r, NSColor* color) {
    [color setFill];
    [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(centre.x-r,centre.y-r,2*r,2*r)] fill];
}
static NSColor* mapColour(NSColor* tint,Quad palette) {
    if (palette.w>=1.f) return tint;
    const auto colour=[tint colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    const CGFloat value=.2126*colour.redComponent+.7152*colour.greenComponent+.0722*colour.blueComponent;
    const CGFloat tone=.50+.50*value;
    return [NSColor colorWithSRGBRed:std::lerp(palette.x*tone,colour.redComponent,double(palette.w))
                              green:std::lerp(palette.y*tone,colour.greenComponent,double(palette.w))
                               blue:std::lerp(palette.z*tone,colour.blueComponent,double(palette.w))
                              alpha:colour.alphaComponent];
}

static void drawSystemGrid(NSRect map, const Ocean& ocean, const Region& region, NSColor* colour,
                           std::optional<unsigned> selected = std::nullopt) {
    const auto regionColour=mapColour(colour,ocean.bubblePalette({BubbleKind::Region,region.cell},region.scale));
    fill(map,[regionColour colorWithAlphaComponent:.08]);
    const auto* stars = ocean.regionStars().data()+region.cell*regionArea;
    const CGFloat pitch = map.size.width/regionSide;
    for (unsigned i = 0; i < regionArea; ++i) {
        if (!stars[i]) continue;
        const auto x = map.origin.x+(i%regionSide+.5)*pitch;
        const auto y = map.origin.y+(i/regionSide+.5)*pitch;
        const bool active = selected == i;
        const CGFloat radius = pitch*(active ? .41 : .34);
        constexpr unsigned side=regionGrid*regionSide;
        const unsigned system=(region.cell/regionGrid*regionSide+i/regionSide)*side+
                               region.cell%regionGrid*regionSide+i%regionSide;
        const auto starColour=mapColour(colour,ocean.bubblePalette({BubbleKind::System,system},region.scale));
        if (active) fill(NSMakeRect(x-pitch/2.,y-pitch/2.,pitch,pitch),[starColour colorWithAlphaComponent:.48]);
        [(active ? NSColor.whiteColor : starColour) setStroke];
        auto ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x-radius,y-radius,2.*radius,2.*radius)];
        ring.lineWidth = std::max(.30,pitch*.10);
        [ring stroke];
        circle(NSMakePoint(x,y),pitch*.12,[starColour colorWithAlphaComponent:.59+.41*double(stars[i]&63)/63.]);
    }
}

@interface Atlas : NSView
@property(getter=isOpen) BOOL open;
@property(nonatomic) BOOL showingRegions;
@property(nonatomic, copy) void (^selection)(unsigned);
@property(nonatomic, assign) Ocean* ocean;
- (void)showMissionCounts:(const std::array<job::LayerMissionCount,regionScales>&)counts;
@end
@implementation Atlas {
    std::array<job::LayerMissionCount,regionScales> _missionCounts;
}
- (void)showMissionCounts:(const std::array<job::LayerMissionCount,regionScales>&)counts {
    _missionCounts=counts;
    if (self.open && self.showingRegions) self.needsDisplay=YES;
}
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
- (NSRect)regionPanel {
    const auto b = self.bounds;
    const CGFloat w = std::min(b.size.width-24.,620.);
    const CGFloat h = std::min(b.size.height-24.,458.);
    return NSMakeRect((b.size.width-w)/2.,(b.size.height-h)/2.,w,h);
}
- (NSRect)regionGridRect {
    const auto panel = [self regionPanel];
    const CGFloat extent = std::max(10.,std::min({310.,panel.size.width-242.,panel.size.height-130.}));
    return NSMakeRect(panel.origin.x+35.,panel.origin.y+102.,extent,extent);
}
- (NSRect)regionRect:(unsigned)cell {
    const auto grid = [self regionGridRect];
    const CGFloat item = grid.size.width/regionGrid;
    return NSMakeRect(grid.origin.x+item*(cell%regionGrid),grid.origin.y+item*(cell/regionGrid),item,item);
}
- (void)mouseDown:(NSEvent*)event {
    if (!self.open || !self.selection) return;
    const NSPoint point = [self convertPoint:event.locationInWindow fromView:nil];
    if (self.showingRegions) {
        const auto* selected = self.ocean->selectedRegion();
        for (const auto& region : self.ocean->regions()) {
            if (!NSPointInRect(point,[self regionRect:region.cell])) continue;
            self.ocean->markRegion(selected == &region ? regionCells : region.cell);
            self.needsDisplay = YES;
            break;
        }
        return;
    }
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
- (void)drawRegionAtlas {
    const auto panel = [self regionPanel];
    const auto grid = [self regionGridRect];
    const auto x = panel.origin.x+28., y = panel.origin.y;
    fill(panel,[NSColor colorWithSRGBRed:.032 green:.018 blue:.035 alpha:.98]);
    [ink(.32) setStroke];
    [NSBezierPath strokeRect:NSInsetRect(panel,.5,.5)];
    textAt(@"Xalaria Region Atlas",x,y+19.,28.,NSFontWeightLight,1.);
    textAt([NSString stringWithFormat:@"%zu Regions  ·  %u Systems",
            self.ocean->regions().size(),self.ocean->systemCount()],x,y+59.,12.,NSFontWeightMedium,.68);
    NSArray<NSColor*>* colours = @[
        [NSColor colorWithSRGBRed:.96 green:.28 blue:.76 alpha:1.],
        [NSColor colorWithSRGBRed:1. green:.70 blue:.16 alpha:1.],
        [NSColor colorWithSRGBRed:.29 green:.49 blue:1. alpha:1.],
        [NSColor colorWithSRGBRed:.73 green:.96 blue:.15 alpha:1.],
        [NSColor colorWithSRGBRed:1. green:.25 blue:.30 alpha:1.],
        [NSColor colorWithSRGBRed:.20 green:.91 blue:.76 alpha:1.]
    ];
    const Region* selected = self.ocean->selectedRegion();
    const CGFloat step = grid.size.width/regionGrid;
    for (unsigned i = 0; i < regionGrid; ++i) {
        NSString* index = [NSString stringWithFormat:@"%u",i+1];
        textAt(index,grid.origin.x+(i+.35)*step,grid.origin.y-16.,9.,NSFontWeightMedium,.55);
        textAt(index,grid.origin.x-15.,grid.origin.y+i*step+(step-11.)*.5,9.,NSFontWeightMedium,.55);
    }
    for (unsigned cell = 0; cell < regionCells; ++cell)
        fill(NSInsetRect([self regionRect:cell],1.5,1.5),ink(.07));
    for (const auto& region : self.ocean->regions()) {
        const auto rect = NSInsetRect([self regionRect:region.cell],1.5,1.5);
        const auto colour = mapColour(colours[region.scale],
                                      self.ocean->bubblePalette({BubbleKind::Region,region.cell},region.scale));
        const bool here = region.scale == self.ocean->oceanDepth();
        fill(rect,[colour colorWithAlphaComponent:here ? .48 : .24]);
        const CGFloat radius = .15*step+.12*step*std::sqrt(double(region.systems)/regionArea);
        circle(NSMakePoint(NSMidX(rect),NSMidY(rect)),radius,colour);
        if (selected == &region) {
            [ink(1.) setStroke];
            [NSBezierPath strokeRect:NSInsetRect(rect,.5,.5)];
        }
    }
    const CGFloat detailX = NSMaxX(grid)+24.;
    textAt(@"Missions completed",detailX+112.,grid.origin.y-19.,10.,NSFontWeightMedium,.75);
    for (unsigned scale = 0; scale < regionScales; ++scale) {
        const CGFloat line = grid.origin.y+scale*21.;
        const bool here = scale == self.ocean->oceanDepth();
        const auto palette = layerMonochrome[scale];
        circle(NSMakePoint(detailX+4.,line+8.),here ? 4. : 2.5,
               [NSColor colorWithSRGBRed:palette.x green:palette.y blue:palette.z alpha:1.]);
        textAt(layerTitle(scale),detailX+15.,line,12.,here ? NSFontWeightSemibold : NSFontWeightRegular,here ? 1. : .71);
        const auto count=_missionCounts[scale];
        textAt([NSString stringWithFormat:@"%u / %u",count.completed,count.total],
               detailX+126.,line,11.,NSFontWeightMedium,.84);
    }
    const CGFloat detailY = grid.origin.y+146.;
    if (selected) {
        textAt([NSString stringWithFormat:@"Region %02u, %02u",selected->cell%regionGrid+1,selected->cell/regionGrid+1],
               detailX,detailY,15.,NSFontWeightSemibold,1.);
        textAt([NSString stringWithFormat:@"%u %@",selected->systems,selected->systems == 1 ? @"System Bubble" : @"System Bubbles"],
               detailX,detailY+23.,11.,NSFontWeightMedium,.67);
        const CGFloat mapY = detailY+45.;
        const CGFloat mapSize = std::clamp(NSMaxY(panel)-mapY-38.,42.,115.);
        drawSystemGrid(NSMakeRect(detailX,mapY,mapSize,mapSize),*self.ocean,*selected,colours[selected->scale]);
    } else {
        textAt(@"Select a region to mark its bubble.",detailX,detailY,11.,NSFontWeightRegular,.71);
    }
    textAt(selected ? @"X / Inspect     R / Close     Tab / Currents" : @"R / Close     Tab / Currents",
           x,NSMaxY(panel)-29.,11.,NSFontWeightMedium,.72);
}
- (void)drawRect:(NSRect)dirty {
    auto* ocean = self.ocean;
    if (!ocean || !self.open) return;
    fill(self.bounds,[NSColor colorWithWhite:0 alpha:.43]);
    if (self.showingRegions) {
        [self drawRegionAtlas];
        return;
    }
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
    textAt(@"1–8 / Select Current     N / Uncharted Drift     Tab / Close     R / Regions",
           x,y+305,12,NSFontWeightMedium,.72);
}
@end

@interface SystemSurvey : NSView
@property(nonatomic, assign) const Ocean* ocean;
- (void)showRegion:(const Region&)region;
- (void)cycle:(int)direction;
- (unsigned)systemIndex;
- (Quad)previewFrame;
- (Quad)tint;
@end

@implementation SystemSurvey {
    Region _region;
    unsigned _system;
}
- (BOOL)isFlipped { return YES; }
- (void)showRegion:(const Region&)region {
    _region = region;
    _system = 0;
    self.hidden = NO;
    self.needsDisplay = YES;
}
- (void)cycle:(int)direction {
    const int size = int(_region.systems);
    _system = unsigned((int(_system)+size+direction)%size);
    self.needsDisplay = YES;
}
- (unsigned)systemIndex { return _region.firstSystem+_system; }
- (Quad)tint { return self.ocean->regionTint(_region); }
- (NSRect)systemGrid {
    const auto b = self.bounds.size;
    const CGFloat size = std::min({b.width*.34,b.height*.55,318.});
    return NSMakeRect(std::max(25.,b.width*.060),(b.height-size)*.49,size,size);
}
- (Quad)previewFrame {
    const auto grid = [self systemGrid];
    const auto b = self.bounds.size;
    const CGFloat room = b.width-NSMaxX(grid);
    const CGFloat radius = std::min(b.height*.382,room*.425);
    return {float((b.width-room*.50)/b.width),.46f,float(radius/b.height),0.f};
}
- (void)mouseDown:(NSEvent*)event {
    const auto p = [self convertPoint:event.locationInWindow fromView:nil];
    const auto grid = [self systemGrid];
    if (!NSPointInRect(p,grid)) return;
    const CGFloat pitch = grid.size.width/regionSide;
    const unsigned x = (_region.cell%regionGrid)*regionSide+unsigned((p.x-grid.origin.x)/pitch);
    const unsigned y = (_region.cell/regionGrid)*regionSide+unsigned((p.y-grid.origin.y)/pitch);
    const unsigned id = y*(regionGrid*regionSide)+x;
    const auto ids = self.ocean->systemBubbleIds().subspan(_region.firstSystem,_region.systems);
    const auto system = std::lower_bound(ids.begin(),ids.end(),id);
    if (system == ids.end() || *system != id) return;
    _system = unsigned(system-ids.begin());
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    const auto grid = [self systemGrid];
    const auto frame = [self previewFrame];
    const auto b = self.bounds.size;
    const auto tint = [self tint];
    const auto colour = [NSColor colorWithSRGBRed:.32+.60*tint.x green:.32+.60*tint.y
                                           blue:.32+.60*tint.z alpha:1.];
    const unsigned index = [self systemIndex];
    const unsigned id = self.ocean->systemBubbleIds()[index];
    constexpr unsigned side = regionGrid*regionSide;
    const unsigned local = (id/side%regionSide)*regionSide+id%regionSide;
    drawSystemGrid(grid,*self.ocean,_region,colour,local);
    const CGFloat left = NSMinX(grid), top = NSMinY(grid);
    textAt([NSString stringWithFormat:@"Region %02u, %02u",_region.cell%regionGrid+1,_region.cell/regionGrid+1],
           left,top-59.,23.,NSFontWeightMedium,.97);
    textAt([NSString stringWithFormat:@"%u System Bubbles",_region.systems],
           left,top-25.,12.,NSFontWeightMedium,.64);
    textAt(@"← / →  Select System",left,NSMaxY(grid)+14.,11.,NSFontWeightMedium,.73);
    textAt(@"X / Back      R / Atlas      F6 / Bubble Missions",left,b.height-34.,11.,NSFontWeightMedium,.64);
    const auto& system = self.ocean->systemBubbles()[index];
    const unsigned count = unsigned(system.catalogue.z);
    const auto* record = self.ocean->systemById(id);
    const CGFloat labelX = frame.x*b.width-frame.z*b.height;
    const CGFloat labelY = (frame.y+frame.z)*b.height+8.;
    NSString* name = record && !record->name.empty() ? [NSString stringWithUTF8String:record->name.c_str()] : nil;
    textAt(name ? [NSString stringWithFormat:@"%@  ·  Xalaria %05u",name,id] :
                  [NSString stringWithFormat:@"Xalaria %05u",id],labelX,labelY,21.,NSFontWeightMedium,1.);
    textAt([NSString stringWithFormat:@"%u %@   ·   %u of %u",count,count == 1 ? @"Planet" : @"Planets",
                                      _system+1,_region.systems],labelX,labelY+29.,12.,NSFontWeightMedium,.67);
}
@end

@interface WheelMissionItem : NSAccessibilityElement
@property(nonatomic,copy) void (^choose)(void);
@end
@implementation WheelMissionItem
- (BOOL)isAccessibilityEnabled { return self.choose != nil; }
- (BOOL)accessibilityPerformPress {
    if (!self.choose) return NO;
    self.choose();
    return YES;
}
@end

static NSBezierPath* missionLeaf(NSRect frame,bool mirrored) {
    const CGFloat w = NSWidth(frame), h = NSHeight(frame);
    const auto at = [&](CGFloat x,CGFloat y) {
        return NSMakePoint(NSMinX(frame)+(mirrored ? w-x : x),NSMinY(frame)+y);
    };
    const auto leaf = [NSBezierPath bezierPath];
    [leaf moveToPoint:at(0.,h*.48)];
    [leaf curveToPoint:at(21.,h-2.) controlPoint1:at(6.,h*.85) controlPoint2:at(12.,h-2.)];
    [leaf curveToPoint:at(w-19.,h-3.) controlPoint1:at(w*.38,h+1.) controlPoint2:at(w*.75,h)];
    [leaf curveToPoint:at(w,h*.54) controlPoint1:at(w-7.,h-5.) controlPoint2:at(w,h*.76)];
    [leaf curveToPoint:at(w-21.,2.) controlPoint1:at(w,h*.29) controlPoint2:at(w-9.,4.)];
    [leaf curveToPoint:at(19.,2.) controlPoint1:at(w*.77,-1.) controlPoint2:at(w*.34,-1.)];
    [leaf curveToPoint:at(0.,h*.48) controlPoint1:at(8.,3.) controlPoint2:at(4.,h*.29)];
    [leaf closePath];
    return leaf;
}

@interface BubbleMissionWheel : NSView
@property(nonatomic,copy) void (^activate)(std::size_t);
@property(nonatomic,readonly,getter=isReady) BOOL ready;
- (void)showMissions:(const board::Snapshot&)snapshot animated:(BOOL)animated at:(double)now;
- (void)followBubble:(const BubbleInspection&)bubble progress:(double)progress pointer:(BOOL)pointer
              locked:(BOOL)locked at:(double)now;
- (void)reset;
@end
@implementation BubbleMissionWheel {
    board::Snapshot _missions;
    Quad _screen, _palette, _strike;
    double _revealAt, _presentationTime, _progress;
    BOOL _pointer, _large, _locked;
    NSInteger _pressedRow;
    NSMutableArray<NSBezierPath*>* _hitRegions;
    NSMutableArray<WheelMissionItem*>* _accessItems;
}
- (BOOL)isReady { return !self.hidden && !_missions.rows.empty(); }
- (BOOL)isAccessibilityElement { return self.ready; }
- (NSString*)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString*)accessibilityLabel {
    return [NSString stringWithFormat:@"Bubble Missions, %@%@",[NSString stringWithUTF8String:_missions.location.c_str()],
                                      _locked ? @", position locked. U to release." : @", U to lock position."];
}
- (NSArray*)accessibilityChildren { return self.ready ? _accessItems : @[]; }
- (NSInteger)rowAt:(NSPoint)point {
    for (NSUInteger i=0; i<_hitRegions.count; ++i)
        if ([_hitRegions[i] containsPoint:point]) return NSInteger(i);
    return NSNotFound;
}
- (NSView*)hitTest:(NSPoint)point {
    if (!_pointer || !self.ready) return nil;
    return [self rowAt:[self convertPoint:point fromView:self.superview]]==NSNotFound ? nil : self;
}
- (void)mouseDown:(NSEvent*)event {
    _pressedRow = [self rowAt:[self convertPoint:event.locationInWindow fromView:nil]];
}
- (void)mouseUp:(NSEvent*)event {
    const auto row = [self rowAt:[self convertPoint:event.locationInWindow fromView:nil]];
    if (self.ready && row!=NSNotFound && row==_pressedRow && self.activate) self.activate(std::size_t(row));
    _pressedRow = NSNotFound;
}
- (void)reset {
    _missions = {};
    _large = NO;
    _pressedRow = NSNotFound;
    [_hitRegions removeAllObjects];
    [_accessItems removeAllObjects];
    self.hidden = YES;
}
- (void)showMissions:(const board::Snapshot&)snapshot animated:(BOOL)animated at:(double)now {
    _missions = snapshot;
    _revealAt = animated && !NSWorkspace.sharedWorkspace.accessibilityDisplayShouldReduceMotion ? now : 0.;
    _hitRegions = [NSMutableArray new];
    _accessItems = [NSMutableArray new];
    __weak BubbleMissionWheel* weak = self;
    for (std::size_t i=0; i<_missions.rows.size(); ++i) {
        const auto& row = _missions.rows[i];
        auto item = [WheelMissionItem new];
        item.accessibilityRole = NSAccessibilityButtonRole;
        item.accessibilityParent = self;
        item.accessibilityLabel = [NSString stringWithFormat:@"%zu, %@, %@, %@",i+1,
            [NSString stringWithUTF8String:row.title.c_str()],
            row.status=="Filed" ? @"Completed" : row.status=="Tracked" ? @"Tracked" : @"Available",
            [NSString stringWithUTF8String:row.detail.c_str()]];
        item.choose = ^{
            auto wheel = weak;
            if (wheel.ready && wheel.activate) wheel.activate(i);
        };
        [_accessItems addObject:item];
    }
}
- (void)followBubble:(const BubbleInspection&)bubble progress:(double)progress pointer:(BOOL)pointer
              locked:(BOOL)locked at:(double)now {
    _screen = bubble.screen;
    _palette = bubble.palette;
    _strike = bubble.impact;
    _progress = progress;
    _presentationTime = now;
    _pointer = pointer;
    _locked = locked;
    const CGFloat radius = _screen.z*NSHeight(self.bounds)*.5;
    _large = radius>=(_large ? 95. : 104.);
    self.hidden = progress<.12;
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    const auto size = self.bounds.size;
    const auto count = _missions.rows.size();
    if (_screen.w <= 0.) return;
    const auto layer = board::menuAccent(_palette.x,_palette.y,_palette.z);
    if (count == 0) {
        const NSPoint spot{(.5+.5*_strike.x/_screen.w)*size.width,(.5+.5*_strike.y)*size.height};
        const auto ring = [NSBezierPath bezierPath];
        [ring appendBezierPathWithArcWithCenter:spot radius:14. startAngle:90. endAngle:90.-360.*_progress clockwise:YES];
        [[NSColor colorWithWhite:.06 alpha:.9] setStroke];
        ring.lineWidth = 3.3;
        [ring stroke];
        [layer setStroke];
        ring.lineCapStyle = NSLineCapStyleRound;
        ring.lineWidth = 1.5;
        [ring stroke];
        return;
    }
    [_hitRegions removeAllObjects];
    const CGFloat radius = _screen.z*size.height*.5;
    const bool large = _large;
    const CGFloat root = large ? 55. : std::max(33.,radius+9.);
    const CGFloat length = large ? 53. : 44.;
    const CGFloat rim = root+length;
    const CGFloat elapsed = _revealAt>0. ? _presentationTime-_revealAt : 1.;
    const CGFloat t = std::clamp(elapsed/.32,0.,1.);
    const CGFloat opacity = 1.-std::pow(1.-t,3.);
    constexpr CGFloat labelHeight = 54., maxLabelWidth = 205.;
    NSPoint centre{(.5+.5*_screen.x/_screen.w)*size.width,(.5+.5*_screen.y)*size.height};
    if (large) {
        const CGFloat side = std::min(rim+maxLabelWidth+25.,size.width*.5);
        centre.x = std::clamp(centre.x,side,size.width-side);
        centre.y = std::clamp(centre.y,std::min(size.height*.5,rim+labelHeight+63.),
                             std::max(size.height*.5,size.height-rim-labelHeight-23.));
    }
    const auto context = NSGraphicsContext.currentContext.CGContext;
    if (t < 1.) {
        CGContextSaveGState(context);
        CGContextSetAlpha(context,opacity);
        CGContextBeginTransparencyLayer(context,nullptr);
    }
    const auto panel = [NSColor colorWithSRGBRed:.027 green:.029 blue:.028 alpha:.94];
    const auto type = board::menuInk();
    const auto complete = board::completedInk();
    const auto pointer = _pointer ? [self convertPoint:self.window.mouseLocationOutsideOfEventStream fromView:nil] : NSZeroPoint;
    const auto drawLine = [](NSString* text,NSRect rect,CGFloat points,NSFontWeight weight,
                             NSColor* colour,NSTextAlignment alignment,bool wrap=false) {
        auto paragraph = [NSMutableParagraphStyle new];
        paragraph.lineBreakMode = wrap ? NSLineBreakByWordWrapping : NSLineBreakByTruncatingTail;
        paragraph.alignment = alignment;
        auto font = [NSFont systemFontOfSize:points weight:weight];
        const auto attrs = @{NSFontAttributeName:font,
                             NSForegroundColorAttributeName:colour,NSParagraphStyleAttributeName:paragraph};
        if (wrap) [text drawWithRect:rect options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingTruncatesLastVisibleLine
                          attributes:attrs];
        else [text drawInRect:rect withAttributes:attrs];
    };
    constexpr CGFloat radians = std::numbers::pi_v<CGFloat>/180.;
    const CGFloat step = 360./CGFloat(count);
    const CGFloat first = count%2==0 ? 90.-step*.5 : 90.;
    const CGFloat breadth = std::clamp((root+length*.63)*std::sin(step*radians*.31),15.,31.);
    const auto halo = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(centre.x-root+4.,centre.y-root+4.,
                                                                     2.*root-8.,2.*root-8.)];
    [[layer colorWithAlphaComponent:.30] setStroke];
    halo.lineWidth = .65;
    [halo stroke];

    unsigned completed = 0;
    for (std::size_t i=0; i<count; ++i) {
        const auto& item = _missions.rows[i];
        const bool filed = item.status=="Filed";
        if (filed) ++completed;
        const auto accent = filed ? complete : layer;
        const CGFloat angle = (first-step*CGFloat(i))*radians;
        const CGFloat dx = std::cos(angle), dy = std::sin(angle);
        const CGFloat phase = std::clamp((elapsed-.017*CGFloat(i))/.21,0.,1.);
        const CGFloat open = 1.-std::pow(1.-phase,3.);
        const CGFloat extent = length*(.53+.47*open), span = breadth*(.49+.51*open);
        const auto at = [&](CGFloat distance,CGFloat across=0.) {
            return NSMakePoint(centre.x+dx*distance-dy*across,centre.y+dy*distance+dx*across);
        };
        const auto vein = [&](CGFloat progress,CGFloat side=0.) { return at(root+extent*progress,span*side); };
        const auto tip = vein(1.,.11);
        const auto petal = [NSBezierPath bezierPath];
        [petal moveToPoint:vein(0.)];
        [petal curveToPoint:vein(.66,.92) controlPoint1:vein(.26,.13) controlPoint2:vein(.37,.90)];
        [petal curveToPoint:tip controlPoint1:vein(.88,.96) controlPoint2:vein(1.03,.53)];
        [petal curveToPoint:vein(.61,-.82) controlPoint1:vein(.99,-.44) controlPoint2:vein(.82,-.88)];
        [petal curveToPoint:vein(0.) controlPoint1:vein(.34,-.77) controlPoint2:vein(.25,-.19)];
        [petal closePath];

        NSString* title = [NSString stringWithUTF8String:item.title.c_str()];
        NSDictionary* attrs = @{NSFontAttributeName:[NSFont systemFontOfSize:11.5 weight:NSFontWeightSemibold]};
        const CGFloat width = std::clamp([title sizeWithAttributes:attrs].width+34.,116.,maxLabelWidth);
        const auto leader = at(root+extent+14.+(i%2)*2.);
        const bool mirror = dx<-.16 || (std::abs(dx)<.16 && dy<0.);
        const CGFloat x = std::abs(dx)<.16 ? leader.x-width*.5 : dx>0. ? leader.x+3. : leader.x-width-3.;
        const CGFloat y = leader.y+(std::abs(dx)<.16 ? (dy>0. ? 0. : -labelHeight) : -labelHeight*.5);
        const NSRect label = NSMakeRect(std::clamp(x,16.,size.width-width-16.),
                                      std::clamp(y,54.,size.height-labelHeight-17.),width,labelHeight);
        const auto face = missionLeaf(label,mirror);
        NSBezierPath* hit = mirror ? [face bezierPathByReversingPath] : [face copy];
        [hit appendBezierPath:petal];
        [_hitRegions addObject:hit];
        _accessItems[i].accessibilityFrame = [self.window convertRectToScreen:[self convertRect:label toView:nil]];
        const bool selected = _pointer && ([hit containsPoint:pointer] || _pressedRow==NSInteger(i));
        const auto end = NSMakePoint(std::clamp(leader.x,NSMinX(label)+8.,NSMaxX(label)-8.),
                                     std::clamp(leader.y,NSMinY(label)+5.,NSMaxY(label)-5.));
        const auto line = [NSBezierPath bezierPath];
        [line moveToPoint:vein(.83,.105)];
        [line curveToPoint:end controlPoint1:at(root+extent+5.,span*.25) controlPoint2:leader];
        [[accent colorWithAlphaComponent:selected ? .92 : .49] setStroke];
        line.lineWidth = selected ? 1.25 : .75;
        [line stroke];

        const auto pigment = [panel blendedColorWithFraction:selected ? .56 : .37 ofColor:accent];
        const auto light = [[NSGradient alloc] initWithStartingColor:panel endingColor:pigment];
        [light drawInBezierPath:petal angle:angle/radians];
        [[accent colorWithAlphaComponent:selected ? 1. : .75] setStroke];
        petal.lineWidth = selected ? 1.35 : .85;
        [petal stroke];
        const auto seam = [NSBezierPath bezierPath];
        [seam moveToPoint:at(root-4.)];
        [seam curveToPoint:vein(.45,-.04) controlPoint1:vein(.11,.10) controlPoint2:vein(.30,-.06)];
        [[accent colorWithAlphaComponent:.60] setStroke];
        seam.lineWidth = .7;
        [seam stroke];

        const auto number = vein(.71,.035);
        NSString* index = [NSString stringWithFormat:@"%zu",i+1];
        drawLine(index,NSMakeRect(number.x-11.,number.y-8.,22.,16.),12.,NSFontWeightSemibold,
                 filed ? complete : type,NSTextAlignmentCenter);
        [(selected ? [panel blendedColorWithFraction:.18 ofColor:accent] : panel) setFill];
        [face fill];
        [[accent colorWithAlphaComponent:selected ? 1. : .46] setStroke];
        face.lineWidth = selected ? 1.4 : .8;
        [face stroke];
        drawLine(title,NSMakeRect(label.origin.x+17.,label.origin.y+17.,width-34.,32.),
                 11.5,NSFontWeightSemibold,type,NSTextAlignmentLeft,true);
        NSString* detail = [NSString stringWithUTF8String:item.detail.c_str()];
        NSString* status = filed ? @"✓ Report filed" : item.status=="Tracked" ?
            [@"◆ " stringByAppendingString:detail] : detail;
        drawLine(status,NSMakeRect(label.origin.x+17.,label.origin.y+6.,width-34.,13.),
                 9.5,NSFontWeightSemibold,accent,NSTextAlignmentLeft);
    }
    const CGFloat headingWidth = large ? 113. : 163.;
    const CGFloat headingX = std::clamp(centre.x-headingWidth*.5,12.,size.width-headingWidth-12.);
    const CGFloat clearance = count%2==0 ? (count==6 ? 33. : 16.) : labelHeight+23.;
    const CGFloat above = centre.y+rim+clearance, below = centre.y-rim-clearance-58.;
    const CGFloat headingY = large ? centre.y-29. : above+74. <= size.height ? above : std::max(52.,below);
    const NSRect heading = NSMakeRect(headingX,headingY,headingWidth,58.);
    const auto calyx = missionLeaf(heading,false);
    [panel setFill];
    [calyx fill];
    [[layer colorWithAlphaComponent:.65] setStroke];
    calyx.lineWidth = .85;
    [calyx stroke];
    drawLine([NSString stringWithUTF8String:_missions.location.c_str()],NSMakeRect(headingX+9.,headingY+34.,headingWidth-18.,21.),
             16.,NSFontWeightSemibold,type,NSTextAlignmentCenter);
    drawLine([NSString stringWithFormat:@"%u of %zu completed",completed,count],NSMakeRect(headingX,headingY+20.,headingWidth,14.),
             10.5,NSFontWeightMedium,complete,NSTextAlignmentCenter);
    NSString* shortcuts = _locked ? @"Locked · U Release" : [NSString stringWithFormat:@"U Lock · ⇧1–%zu",count];
    drawLine(shortcuts,NSMakeRect(headingX,headingY+7.,headingWidth,13.),
             9.5,NSFontWeightMedium,[type colorWithAlphaComponent:.76],NSTextAlignmentCenter);
    if (t < 1.) {
        CGContextEndTransparencyLayer(context);
        CGContextRestoreGState(context);
    }
}
@end

static NSString* const savedBubbleStrings = @"BubbleStrings.v1";
static NSString* const savedUnlockedPassages = @"UnlockedPassages.v1";
static NSString* const savedPassagePatterns = @"PassagePatterns.v1";

struct MissionMark {
    double x,y,apparentRadius;
    job::ContactKind kind;
    std::string label;
    bool selected=false,passage=false;
};

@interface MissionSight : NSView
- (void)present:(std::vector<MissionMark>)marks status:(NSString*)status objective:(NSString*)objective;
@end
@implementation MissionSight {
    std::vector<MissionMark> _marks;
    NSString* _status;
    NSString* _objective;
}
- (BOOL)isFlipped { return YES; }
- (NSView*)hitTest:(NSPoint)p { return nil; }
- (BOOL)isAccessibilityElement { return _objective.length>0; }
- (NSString*)accessibilityRole { return NSAccessibilityStaticTextRole; }
- (NSString*)accessibilityValue {
    return _objective.length ? [NSString stringWithFormat:@"%@. %@",_objective,_status] : nil;
}
- (void)present:(std::vector<MissionMark>)marks status:(NSString*)status objective:(NSString*)objective {
    const bool changed=(_objective!=objective && ![_objective isEqualToString:objective]) ||
                       (_status!=status && ![_status isEqualToString:status]);
    _marks=std::move(marks);
    _status=status;
    _objective=objective;
    self.needsDisplay=YES;
    if (changed && _objective.length) NSAccessibilityPostNotification(self,NSAccessibilityValueChangedNotification);
}
- (void)drawRect:(NSRect)dirty {
    const auto size=self.bounds.size;
    const auto drawText=[](NSString* text,NSPoint p,NSColor* color) {
        if (!text.length) return;
        NSDictionary* attrs=@{NSFontAttributeName:[NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightMedium],
            NSForegroundColorAttributeName:color};
        const auto extent=[text sizeWithAttributes:attrs];
        [[NSColor colorWithWhite:.015 alpha:.8] setFill];
        NSRectFill(NSMakeRect(p.x-4,p.y-2,extent.width+8,extent.height+4));
        [text drawAtPoint:p withAttributes:attrs];
    };
    for (const auto& mark:_marks) {
        const CGFloat x=mark.x*size.width,y=mark.y*size.height;
        NSColor* ink=mark.passage ? [NSColor colorWithRed:.55 green:.83 blue:1. alpha:.94] :
            mark.kind==job::ContactKind::Hostile ? [NSColor colorWithRed:1. green:.42 blue:.32 alpha:.94] :
            mark.kind==job::ContactKind::Evidence ? [NSColor colorWithRed:1. green:.80 blue:.44 alpha:.94] :
            [NSColor colorWithRed:.66 green:.92 blue:.69 alpha:.9];
        const auto r=std::clamp(mark.apparentRadius*size.height,mark.selected ? 8. : 3.,mark.passage ? 75. : 30.);
        const auto rect=NSMakeRect(x-r,y-r,2*r,2*r);
        [ink setStroke];
        auto outline=mark.passage ? [NSBezierPath bezierPathWithOvalInRect:rect] :
            [NSBezierPath bezierPathWithRoundedRect:rect xRadius:2. yRadius:2.];
        outline.lineWidth=mark.selected ? 1.6 : .9;
        [outline stroke];
        if (mark.selected || mark.passage)
            drawText([NSString stringWithUTF8String:mark.label.c_str()],{x+r+8.,y-r},ink);
    }
    NSColor* readout=[NSColor colorWithRed:.79 green:.94 blue:.83 alpha:1.];
    const CGFloat left=std::min(32.,size.width*.04);
    drawText(_objective,{left,38.},readout);
    drawText(_status,{left,_objective.length ? 56. : 38.},readout);
}
@end

@interface Game : NSObject <NSApplicationDelegate, MTKViewDelegate, NSWindowDelegate>
- (void)toggleMusicResponse:(id)sender;
- (void)toggleMute:(id)sender;
- (void)chooseGraphicsStyle:(NSMenuItem*)sender;
- (void)toggleAdaptiveResolution:(id)sender;
- (void)toggleEnclosingView:(id)sender;
- (void)toggleShipView:(id)sender;
- (void)toggleRegionAtlas:(id)sender;
- (void)toggleFlightGuide:(id)sender;
- (void)markNearbyRegion:(id)sender;
- (void)toggleSurvey:(id)sender;
- (void)fireBubbleTool:(id)sender;
- (void)toggleStringMode:(id)sender;
- (void)toggleHarpoonMode:(id)sender;
- (void)toggleSearchlight:(id)sender;
- (void)toggleMissionLock:(id)sender;
- (void)showMissionBoard:(NSMenuItem*)sender;
@end
@implementation Game {
    NSWindow* _window;
    Controls* _view;
    Atlas* _atlas;
    SystemSurvey* _survey;
    BubbleFlightHud* _bubbleFlightHud;
    BubbleMissionWheel* _missionWheel;
    MissionView* _missionView;
    MissionSight* _missionSight;
    std::unique_ptr<job::NativeRuntime> _missions;
    std::unique_ptr<job::MissionDispatch> _dispatch;
    std::unique_ptr<job::MissionTransport> _transport;
    std::unique_ptr<job::MissionStrategy> _strategy;
    std::unique_ptr<job::BubbleMissions> _bubbleMissions;
    unsigned _bubbleMissionSystem,_bubbleMissionRegion;
    std::size_t _bubbleMissionSelection;
    std::optional<BubbleInspection> _illuminatedBubble;
    std::optional<BubbleInspection> _missionBubbleSource;
    std::optional<BubbleInspection> _lockedMissionBubble;
    double _illuminatedSince;
    PassagePatterns _passagePatterns;
    unsigned _restoredBubbleCount, _passageLayer, _passagePatternMatch;
    std::array<job::LayerMissionCount,regionScales> _layerMissionCounts;
    std::vector<BubbleId> _awaitingBubbleColours;
    std::optional<infinity::StoryKey> _hudTracked;
    std::optional<job::DispatchObjective> _hudObjective;
    double _objectiveRefreshAt;
    std::vector<job::DispatchWorld> _missionWorlds;
    std::vector<job::Contact> _missionContacts;
    std::optional<job::Action> _missionDestination;
    std::optional<job::MissionPassage> _missionGate;
    std::optional<job::Position> _previousGateEye;
    std::optional<job::PlayerLocation> _resumeMission;
    std::optional<Quad> _resumeBubbleTint;
    std::optional<job::Actor> _missionTarget;
    std::optional<unsigned> _missionWorldSystem;
    std::optional<unsigned> _missionCommandSystem;
    NSURL* _missionSave;
    NSString* _missionNotice;
    BOOL _missionSaveEnabled,_missionLook;
    board::Page _missionPage;
    double _missionRefreshAt,_missionSaveAt,_missionNoticeUntil,_missionFollowAt;
    BubbleStrings _strings;
    NSString* _stringFeedback;
    double _stringFeedbackUntil;
    ShipFlight _flight;
    std::optional<ShipFlight> _boardedFlight;
    std::optional<HarpoonHit> _harpoonArrival;
    double _harpoonArrivalTime;
    Quad _boardWater, _boardAccent;
    BOOL _atHelm, _visitedHomeCockpit;
    Renderer* _renderer;
    std::unique_ptr<Ocean> _ocean;
    std::unique_ptr<Score> _score;
    AVAudioEngine* _audio;
    AVAudioSourceNode* _source;
    std::array<bool,128> _pressed;
    dispatch_semaphore_t _inFlight;
    std::shared_ptr<std::atomic<std::uint64_t>> _gpuSample;
    RenderResolution _resolution;
    double _last, _soundAt, _bubblePauseSince, _bubblePauseDuration;
    double _musicAt, _musicPhase;
    std::uint64_t _musicSnapshot;
    Quad _music;
    float _panX, _panY;
    unsigned _lastCallNumber, _callInput;
    BOOL _lookRequested, _musicResponse, _muted, _exteriorView, _adaptiveResolution, _flightGuide;
    BOOL _surveyFromAtlas, _surveyRestoreLook;
    BOOL _searchlightOn;
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

- (ShipFlight*)missionPilot {
    if (!_atHelm) return nullptr;
    auto* pilot=_boardedFlight ? &*_boardedFlight : &_flight;
    return pilot->region() ? nullptr : pilot;
}

- (void)recordMissionNotice:(NSString*)text {
    if (!text.length) return;
    _missionNotice=text;
    _missionNoticeUntil=CACurrentMediaTime()+6.;
}

// Bubble tools use the same clock as the mission wheel, including while a
// harpoon is in flight and chase physics is held for the transition.
- (double)bubbleTimeAt:(double)wallTime {
    return (_ocean->paused ? _bubblePauseSince : wallTime)-_bubblePauseDuration;
}

- (void)setGamePaused:(BOOL)paused {
    if (_ocean->paused==bool(paused)) return;
    const double now=CACurrentMediaTime();
    if (paused) _bubblePauseSince=now;
    else _bubblePauseDuration+=now-_bubblePauseSince;
    _ocean->paused=paused;
}

- (void)recordMissionText:(const std::string&)text {
    [self recordMissionNotice:[NSString stringWithUTF8String:text.c_str()]];
}

- (void)saveMissions {
    if (!_missions || !_missionSaveEnabled || !_missionSave) return;
    const auto snapshot=_missions->serialize();
    auto data=[NSData dataWithBytes:snapshot.data() length:snapshot.size()];
    NSError* error=nil;
    if (![data writeToURL:_missionSave options:NSDataWritingAtomic error:&error])
        [self recordMissionNotice:[@"Mission save failed. " stringByAppendingString:error.localizedDescription]];
    _missionSaveAt=CACurrentMediaTime()+30.;
}

- (void)refreshPassagePattern {
    _passageLayer=_ocean->oceanDepth();
    const auto pattern=_ocean->passageLocked() ? _passagePatterns[_passageLayer] : PassagePattern{};
    _passagePatternMatch=_strings.preparePassage(*_ocean,_restoredBubbleCount,pattern);
}

- (void)advanceBubbleResonance:(double)now {
    if (!_strings.resonanceActive()) return;
    if (![self bubbleToolsVisible]) {
        _strings.cancelResonance();
        return;
    }
    if (_ocean->paused) return;
    if (_passageLayer!=_ocean->oceanDepth()) [self refreshPassagePattern];
    const auto view=_ocean->scene(1.f);
    const auto frame=_strings.advanceResonance(*_ocean,view,now);
    if (_score && !frame.chimes.empty()) {
        const Vec right{view.right.x,view.right.y,view.right.z};
        const Vec forward{view.forward.x,view.forward.y,view.forward.z};
        const auto ordinary=std::ranges::count_if(frame.chimes,[](const auto& note) { return note.sequenceLength==0; });
        const auto melody=_strings.sequenceLength()!=0 || frame.opened;
        const float level=(melody ? .26f : 1.f)/float(std::sqrt(std::max(1.,double(ordinary))));
        for (const auto& note : frame.chimes) _score->chime(note,_ocean->position(),right,forward,level);
    }
    if (frame.opened) {
        const auto layer=_ocean->oceanDepth();
        [NSUserDefaults.standardUserDefaults setInteger:_ocean->unlockedPassageMask() forKey:savedUnlockedPassages];
        NSString* message=[NSString stringWithFormat:@"%@ passage open",layerTitle(layer+1)];
        _stringFeedback=message;
        _stringFeedbackUntil=now+4.;
        [self recordMissionNotice:message];
        [self refreshPassagePattern];
    }
}

- (void)updateBubbleProgress:(BOOL)animate {
    const auto progress = _bubbleMissions->synchronize(*_ocean,animate,_awaitingBubbleColours);
    _restoredBubbleCount=progress.restoredBubbles;
    _layerMissionCounts=progress.layers;
    [_atlas showMissionCounts:_layerMissionCounts];
    if (_awaitingBubbleColours.empty()) [self refreshPassagePattern];
    if (animate && !progress.restored.empty()) {
        [self recordMissionText:_bubbleMissions->label(progress.restored.front())+" / Colour restored"];
    }
}

- (void)setupMissions {
    _missions=std::make_unique<job::NativeRuntime>(resource(@"xalaria-catalog",@"tsv").fileSystemRepresentation);
    _dispatch=std::make_unique<job::MissionDispatch>(*_missions);
    _transport=std::make_unique<job::MissionTransport>(*_missions);
    _strategy=std::make_unique<job::MissionStrategy>(*_missions);
    _bubbleMissions=std::make_unique<job::BubbleMissions>(*_ocean,_missions->stories);
    auto* defaults=NSUserDefaults.standardUserDefaults;
    NSString* encoded=[defaults stringForKey:savedPassagePatterns];
    const auto saved=encoded ? decodePassagePatterns(encoded.UTF8String) : std::nullopt;
    if (saved) {
        _passagePatterns=*saved;
    } else {
        _passagePatterns=generatePassagePatterns(arc4random());
        const auto patterns=encodePassagePatterns(_passagePatterns);
        [defaults setObject:[NSString stringWithUTF8String:patterns.c_str()] forKey:savedPassagePatterns];
    }
    _ocean->setUnlockedPassages(unsigned([defaults integerForKey:savedUnlockedPassages]));
    NSError* error=nil;
    auto* files=NSFileManager.defaultManager;
    auto* support=[files URLForDirectory:NSApplicationSupportDirectory inDomain:NSUserDomainMask
                       appropriateForURL:nil create:YES error:&error];
    auto* directory=[support URLByAppendingPathComponent:@"Pelagic Spheres" isDirectory:YES];
    _missionSaveEnabled=directory &&
        [files createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:&error];
    _missionSave=[directory URLByAppendingPathComponent:@"Xalaria Missions.session"];
    if (!_missionSaveEnabled) {
        [self recordMissionNotice:@"Mission saves are unavailable."];
    } else if ([files fileExistsAtPath:_missionSave.path]) {
        auto* data=[NSData dataWithContentsOfURL:_missionSave options:0 error:&error];
        if (!data || !data.length || !_missions->restore({static_cast<const char*>(data.bytes),data.length})) {
            _missionSaveEnabled=NO;
            [self recordMissionNotice:@"The existing mission save could not be read. It has been preserved."];
        } else {
            _resumeMission=_missions->location();
        }
    }
    [self updateBubbleProgress:NO];
    _missionSaveAt=CACurrentMediaTime()+30.;
}

- (void)bindMissionWorlds:(ShipFlight&)pilot {
    if (_missionWorldSystem!=pilot.systemId()) {
        _missionWorlds=_dispatch->worlds(pilot.systemId());
        _missionWorldSystem=pilot.systemId();
    }
    pilot.bindMissionWorlds(_missionWorlds);
}

- (bool)enterMission:(const job::MissionArrival&)arrival {
    const auto system=arrival.frame.system;
    auto worlds=_dispatch->worlds(system);
    std::optional<ShipFlight> next;
    if (system==ziksaSystemId) {
        next=_flight;
        next->enterAtFilm({0,0,1});
    } else {
        const auto* record=_ocean->systemById(system);
        if (!record) return false;
        next.emplace(systemModel(*record),system,_ocean->orbitalTime(),Vec{0,0,1},record);
    }
    next->setTerrain([_renderer terrain]);
    next->syncOrbits(_ocean->orbitalTime());
    next->bindMissionWorlds(worlds);
    if (arrival.frame.world && !next->exposeMissionWorld(*arrival.frame.world,worlds)) return false;
    if (!next->enterMissionPose(arrival.frame,arrival.eye,arrival.orientation,arrival.velocity)) return false;
    _boardedFlight=std::move(next);
    _missionWorlds=std::move(worlds);
    _missionWorldSystem=system;
    _missionTarget.reset();
    _strategy->selectTarget(std::nullopt);
    _missionContacts.clear();
    _missionRefreshAt=0.;
    _atHelm=YES;
    _visitedHomeCockpit=YES;
    return true;
}

- (void)closeMissions {
    if (_missionView.hidden) return;
    _missionView.hidden=YES;
    _dispatch->close();
    [_window makeFirstResponder:_view];
    [self setMouseLook:_missionLook];
}

- (BubbleId)selectedMissionBubble {
    if (_missionPage==board::Page::RegionBubble) return {BubbleKind::Region,_bubbleMissionRegion};
    return {BubbleKind::System,_bubbleMissionSystem};
}

- (void)refreshMissionBoard {
    if (_missionView.hidden || !_missions) return;
    board::Snapshot snapshot;
    NSColor* tint = nil;
    if (_missionPage==board::Page::SystemBubble || _missionPage==board::Page::RegionBubble) {
        const auto id = [self selectedMissionBubble];
        snapshot=_bubbleMissions->snapshot(id,_bubbleMissionSelection);
        const auto palette = _missionBubbleSource && _missionBubbleSource->id==id ? _missionBubbleSource->palette :
            id.kind==BubbleKind::System && id.id==ziksaSystemId ? _ocean->bubblePalette(id,regionScales-1) :
            _ocean->bubblePalette(id);
        tint = board::menuAccent(palette.x,palette.y,palette.z);
    } else if (job::MissionDispatch::handles(_missionPage)) {
        _dispatch->refresh();
        snapshot=_dispatch->snapshot();
        _missionPage=snapshot.page;
    } else if (_missionPage==board::Page::Charters || _missionPage==board::Page::Convoys) {
        snapshot=_transport->snapshot(_missionPage);
    } else {
        auto plotted=_missionCommandSystem;
        if (!plotted && _missionDestination) plotted=_missionDestination->point.frame.system;
        snapshot=_strategy->snapshot(_missionPage,plotted);
    }
    [_missionView setMissionAccent:tint];
    [_missionView present:snapshot];
}

- (void)displayMissionPage:(board::Page)page forBubble:(std::optional<BubbleId>)bubble
                       row:(std::size_t)row {
    if (!_missions) return;
    std::optional<unsigned> surveying;
    if (!_survey.hidden) surveying=_ocean->systemBubbleIds()[[_survey systemIndex]];
    if (_missionView.hidden) {
        _missionBubbleSource = bubble ? _illuminatedBubble : std::nullopt;
        auto& ship = _boardedFlight ? *_boardedFlight : _flight;
        const auto current=_atHelm ? ship.regionTargetSystem().value_or(ship.systemId()) :
                                    _missions->location().frame.system;
        _bubbleMissionSystem=surveying.value_or(current);
        const auto* browsing = _atlas.open && _atlas.showingRegions ? _ocean->selectedRegion() : nullptr;
        const auto* region = _atHelm && ship.region() ? ship.region() : browsing;
        _bubbleMissionRegion=region ? region->cell : regionOfSystem(_bubbleMissionSystem);
        _missionLook=_lookRequested;
        [self setMouseLook:NO];
        _atlas.open=NO;
        _survey.hidden=YES;
        _missionView.hidden=NO;
        [_window makeFirstResponder:_missionView];
    }
    if (bubble) {
        _bubbleMissionSystem = bubble->kind==BubbleKind::System ? bubble->id : _bubbleMissions->assignments(*bubble)[row].system;
        _bubbleMissionRegion = bubble->kind==BubbleKind::Region ? bubble->id : regionOfSystem(_bubbleMissionSystem);
        _bubbleMissionSelection = row;
    } else if (_missionPage!=page) _bubbleMissionSelection=0;
    _missionPage=page;
    if (job::MissionDispatch::handles(page)) {
        if (!_dispatch->isOpen()) _dispatch->open(surveying,_missionTarget);
        if (page!=board::Page::Nearby) _dispatch->dispatch({board::Input::ShowPage,int(page)});
    } else {
        _dispatch->close();
    }
    [self refreshMissionBoard];
}

- (void)displayMissionPage:(board::Page)page {
    [self displayMissionPage:page forBubble:std::nullopt row:0];
}

- (BOOL)openIlluminatedMission:(std::size_t)row {
    if (!_searchlightOn || !_missionWheel.ready || !_illuminatedBubble || ![self bubbleToolsVisible]) return NO;
    const auto id = _illuminatedBubble->id;
    if (row >= _bubbleMissions->assignments(id).size()) return NO;
    const auto page = id.kind==BubbleKind::System ? board::Page::SystemBubble : board::Page::RegionBubble;
    [self displayMissionPage:page forBubble:id row:row];
    return YES;
}

- (void)updateMissionWheel:(const std::optional<BubbleInspection>&)target at:(double)now {
    if (!target || !_bubbleMissions || !_window.isKeyWindow) {
        if (_illuminatedBubble) [_missionWheel reset];
        _illuminatedBubble.reset();
        return;
    }
    if (!_illuminatedBubble || target->id!=_illuminatedBubble->id || target->slot!=_illuminatedBubble->slot) {
        [_missionWheel reset];
        _illuminatedSince = now;
    }
    _illuminatedBubble = target;
    const double progress = _lockedMissionBubble ? 1. : std::clamp(now-_illuminatedSince,0.,1.);
    if (progress >= 1. && !_missionWheel.ready)
        [_missionWheel showMissions:_bubbleMissions->snapshot(target->id,0) animated:!_lockedMissionBubble at:now];
    [_missionWheel followBubble:*target progress:progress pointer:(!_ocean->paused && !_view.looking)
                        locked:bool(_lockedMissionBubble) at:now];
}

- (void)openBubbleMissions {
    if ([self openIlluminatedMission:0]) return;
    const bool inRegion=_atHelm && _boardedFlight && _boardedFlight->region();
    const bool regionAtlas=_atlas.open && _atlas.showingRegions && _ocean->selectedRegion();
    [self displayMissionPage:inRegion || regionAtlas ? board::Page::RegionBubble : board::Page::SystemBubble];
}

- (void)showMissionBoard:(NSMenuItem*)sender {
    if (static_cast<board::Page>(sender.tag)==board::Page::SystemBubble) {
        [self openBubbleMissions];
        return;
    }
    [self displayMissionPage:static_cast<board::Page>(sender.tag)];
}

- (void)plotPassage:(ShipFlight&)pilot {
    _missionGate.reset();
    _previousGateEye.reset();
    _missions->course.view.wormhole.reset();
    if (!_missionDestination) return;
    const auto& point=_missionDestination->point;
    const unsigned destination=point.connection.value_or(point.frame.system);
    if (pilot.systemId()==destination) return;
    _missionGate=job::missionPassage(*_missions,pilot.systemId(),destination);
    if (!_missionGate) {
        [self recordMissionNotice:@"No wormhole route from this system."];
        return;
    }
    if (_missionGate->entrance.frame.world &&
        !pilot.exposeMissionWorld(*_missionGate->entrance.frame.world,_missionWorlds)) {
        _missionGate.reset();
        _missions->course.view.wormhole.reset();
        return;
    }
    [self recordMissionText:_missionGate->entrance.label+" / H approaches the ring"];
}

- (void)applyMission:(const job::Action&)action {
    if (action.kind==job::ActionKind::None) return;
    auto* pilot=[self missionPilot];
    if (action.kind==job::ActionKind::Recover) {
        const auto& p=action.point;
        const job::MissionArrival arrival{p.frame,p.position,p.velocity,p.orientation};
        if ([self enterMission:arrival]) [self closeMissions];
        return;
    }
    if (!pilot) {
        _missionDestination=action;
        [self recordMissionNotice:@"Enter a system's cockpit to fly this assignment."];
        return;
    }
    [self bindMissionWorlds:*pilot];
    if (action.point.connection || action.point.frame.system!=pilot->systemId()) {
        _missionDestination=action;
        [self plotPassage:*pilot];
        [self closeMissions];
        return;
    }
    if (action.point.frame.world && !pilot->exposeMissionWorld(*action.point.frame.world,_missionWorlds)) {
        [self recordMissionNotice:@"The assignment body is unavailable."];
        return;
    }
    if (action.kind==job::ActionKind::Target && action.point.berth) {
        _strategy->selectTarget(action.point.berth);
        _missionTarget=action.point.berth;
        [self closeMissions];
        return;
    }
    if (action.kind==job::ActionKind::Launch) {
        if (pilot->leaveMissionDock()) [self recordMissionNotice:@"Cleared the berth."];
        [self closeMissions];
        return;
    }
    if (action.kind==job::ActionKind::Plot) {
        if (pilot->selectMissionWorld(action.point.frame.world)) {
            pilot->engageWarp();
            [self recordMissionText:action.point.label+" / "+std::string(pilot->warpStatus())];
        }
    } else if (!pilot->beginMissionApproach(action.point,action.kind)) {
        [self recordMissionNotice:@"Helm unavailable. Clear the berth and check drive status."];
    }
    [self closeMissions];
}

- (void)missionInput:(board::Action)input {
    if (input.kind==board::Input::Close) {
        [self closeMissions];
        return;
    }
    if (input.kind==board::Input::ShowPage) {
        [self displayMissionPage:static_cast<board::Page>(input.value)];
        return;
    }
    if (_missionPage==board::Page::SystemBubble || _missionPage==board::Page::RegionBubble) {
        const auto keys=_bubbleMissions->assignments([self selectedMissionBubble]);
        if (input.kind==board::Input::SelectRow && input.value>=0 && std::size_t(input.value)<keys.size())
            _bubbleMissionSelection=std::size_t(input.value);
        else if ((input.kind==board::Input::Track || input.kind==board::Input::Primary) && !keys.empty()) {
            const auto key=keys[std::min(_bubbleMissionSelection,keys.size()-1)];
            auto& stories=_missions->stories;
            stories.advance(_missions->seconds());
            const bool newLead=stories.discover(key,infinity::StoryOrigin::BubbleBoard);
            if (input.kind==board::Input::Track && stories.track(key)) {
                _missionDestination.reset();
                _missionGate.reset();
                [self saveMissions];
                [self closeMissions];
                return;
            }
            _dispatch->open(key.system);
            stories.openReport(key,_missions->seconds());
            _missionPage=_dispatch->snapshot().page;
            if (newLead) [self saveMissions];
        }
        [self refreshMissionBoard];
        return;
    }
    job::Action command;
    if (job::MissionDispatch::handles(_missionPage)) {
        auto& stories = _missions->stories;
        std::optional<infinity::StoryKey> filing;
        if (input.kind==board::Input::Primary || input.kind==board::Input::Secondary) {
            if (const auto* selected = stories.selected(); selected && !stories.result(selected->key))
                filing = selected->key;
        }
        command=_dispatch->dispatch(input);
        [self recordMissionText:_dispatch->takeNotice()];
        if (filing && stories.result(*filing)) {
            if (const auto bubble=_bubbleMissions->owner(*filing);
                _atHelm && bubble && _bubbleMissions->completed(*bubble)==1)
                _awaitingBubbleColours.push_back(*bubble);
            [self updateBubbleProgress:YES];
        }
    } else if (_missionPage==board::Page::Charters || _missionPage==board::Page::Convoys) {
        command=_transport->dispatch(_missionPage,input);
        [self recordMissionText:_transport->message()];
    } else {
        auto plotted=_missionCommandSystem;
        if (!plotted && _missionDestination) plotted=_missionDestination->point.frame.system;
        command=_strategy->dispatch(_missionPage,input,plotted);
        _missionTarget=_strategy->target();
    }
    if (command.kind!=job::ActionKind::None && command.kind!=job::ActionKind::Follow &&
        _missionPage!=board::Page::Convoys) _transport->cancelFollow();
    [self applyMission:command];
    [self refreshMissionBoard];
    if (input.kind==board::Input::Track || input.kind==board::Input::Primary ||
        input.kind==board::Input::Secondary || input.kind==board::Input::Interact ||
        input.kind==board::Input::Report || input.kind==board::Input::Auxiliary) [self saveMissions];
}

- (void)syncMissionPilot:(ShipFlight&)pilot seconds:(double)seconds {
    auto location=pilot.missionLocation();
    location.target=_missionTarget;
    _missions->advance(location,seconds);
    const auto status=_missions->status();
    pilot.setMissionHull(status.hull);
    pilot.setMissionFuel(status.fuel);
    pilot.setUnderAttack(status.underAttack);
}

- (void)cycleMissionContact {
    if (_missionContacts.empty()) {
        [self recordMissionNotice:@"No local traffic or evidence contacts."];
        return;
    }
    auto item=_missionTarget ? std::ranges::find(_missionContacts,*_missionTarget,&job::Contact::id) :
        _missionContacts.end();
    if (item==_missionContacts.end() || ++item==_missionContacts.end()) item=_missionContacts.begin();
    _missionTarget=item->id;
    _strategy->selectTarget(_missionTarget);
    [self recordMissionText:item->name+(item->status.empty() ? "" : " / "+item->status)];
}

- (void)interactWithMission:(ShipFlight&)pilot board:(BOOL)boarding {
    auto location=pilot.missionLocation();
    if (boarding && location.clamped && !location.aboardDockside && pilot.setMissionAboard(true)) {
        [self syncMissionPilot:pilot seconds:0.];
        [self recordMissionNotice:@"Aboard / E transfers freight / F7 opens Dispatch / Return returns to cockpit"];
    } else if (boarding && (location.aboardDockside || location.landed)) {
        _transport->interact();
        [self recordMissionText:_transport->message()];
    } else if (location.aboardDockside && pilot.setMissionAboard(false)) {
        [self syncMissionPilot:pilot seconds:0.];
        [self recordMissionNotice:@"Back in cockpit / Return clears the berth"];
    } else if (location.clamped || location.landed) {
        if (pilot.leaveMissionDock()) {
            [self syncMissionPilot:pilot seconds:0.];
            [self recordMissionNotice:@"Cleared for departure."];
        }
    } else if (_missionTarget) {
        const auto selected=std::ranges::find(_missionContacts,*_missionTarget,&job::Contact::id);
        const auto action=selected!=_missionContacts.end() && selected->port && selected->kind==job::ContactKind::Station ?
            _missions->stationAction(*selected->port) : _missions->vesselAction(*_missionTarget);
        if (action.kind==job::ActionKind::None) [self recordMissionNotice:@"This contact has no accessible berth."];
        else {
            _transport->cancelFollow();
            [self applyMission:action];
        }
    } else {
        [self recordMissionNotice:@"Use T to select a local docking contact."];
    }
    [self saveMissions];
}

- (void)refreshMissionFlight:(ShipFlight&)pilot at:(double)now {
    if (now>=_missionFollowAt) {
        _missionFollowAt=now+.15;
        if (const auto* route=pilot.missionApproachPoint(); route && route->berth) {
            const auto action=route->place ? _missions->stationAction(*route->place) :
                _missions->vesselAction(*route->berth);
            if (action.kind==job::ActionKind::Dock) pilot.refreshMissionApproach(action.point);
        } else {
            const auto action=_transport->followAction();
            if (action.kind!=job::ActionKind::None) {
                const bool distant=action.point.connection || action.point.frame.system!=pilot.systemId();
                if (distant) {
                    if (!_missionDestination || !_missionGate ||
                        _missionDestination->point.connection!=action.point.connection ||
                        _missionDestination->point.frame.system!=action.point.frame.system)
                        [self applyMission:action];
                } else if (!pilot.refreshMissionApproach(action.point)) {
                    if (!action.point.frame.world || pilot.exposeMissionWorld(*action.point.frame.world,_missionWorlds))
                        pilot.beginMissionApproach(action.point,job::ActionKind::Follow);
                }
            }
        }
    }
    if (now<_missionRefreshAt) return;
    _missionRefreshAt=now+.25;
    _missionContacts=_missions->contacts();
    if (const auto distress=_dispatch->distress()) {
        auto existing=std::ranges::find(_missionContacts,distress->id,&job::Contact::id);
        if (existing==_missionContacts.end()) _missionContacts.push_back(*distress);
        else existing->kind=job::ContactKind::Distress;
    }
    const auto range=[&](const job::Contact& contact) {
        const auto p=pilot.missionRenderPoint(contact.id.frame,contact.position);
        return p ? double(p->x)*p->x+double(p->y)*p->y+double(p->z)*p->z :
                   std::numeric_limits<double>::infinity();
    };
    std::ranges::stable_sort(_missionContacts,std::less<>{},range);
    [self recordMissionText:_dispatch->takeNotice()];
    [self refreshMissionBoard];
}

- (void)checkMissionPassage:(ShipFlight&)pilot {
    if (!_missionGate) return;
    auto location=pilot.missionLocation(_missionGate->entrance.frame);
    if (!location.active || location.inTransit || location.docking || location.landed || location.clamped) {
        _previousGateEye.reset();
        return;
    }
    std::optional<job::MissionArrival> arrival;
    if (_previousGateEye) arrival=job::crossMissionPassage(*_missionGate,*_previousGateEye,location,6.);
    _previousGateEye=location.eye;
    if (!arrival) return;
    if (_missions->economy.fuel()<8.) {
        [self recordMissionNotice:@"Wormhole passage requires 8 fuel. Refuel through Charters."];
        return;
    }
    if (![self enterMission:*arrival]) {
        [self recordMissionNotice:@"Could not acquire the arrival frame."];
        return;
    }
    _missions->economy.payWormholeFuel();
    auto* entered=[self missionPilot];
    [self syncMissionPilot:*entered seconds:0.];
    _previousGateEye.reset();
    _missionGate.reset();
    if (_missionDestination) {
        auto action=*_missionDestination;
        _missionDestination.reset();
        if (action.point.connection) {
            [self recordMissionNotice:@"Wormhole clear / Acquiring convoy"];
        } else if (action.point.frame.system!=entered->systemId()) {
            [self applyMission:action];
        } else {
            [self recordMissionText:"Arrived in "+entered->locationName()];
            [self applyMission:action];
        }
    }
    [self saveMissions];
}

- (void)updateMissionSight:(double)now flight:(const FlightScene&)flight {
    auto* pilot=[self missionPilot];
    const bool show=_atHelm && (pilot || _hudObjective) && _missionView.hidden && !_ocean->paused;
    _missionSight.hidden=!show;
    if (!show) return;
    NSString* objective=nil;
    const NSUInteger width=std::max(20.,std::min(80.,(_missionSight.bounds.size.width-75.)/6.8));
    if (_hudObjective) {
        const auto caption=_hudObjective->headline+" · "+_hudObjective->destination;
        objective=[NSString stringWithUTF8String:caption.c_str()];
        if (objective.length>width) objective=[[objective substringToIndex:width-1] stringByAppendingString:@"…"];
    }
    if (!pilot) {
        [_missionSight present:{} status:@"G Back to Bubble World" objective:objective];
        return;
    }
    std::vector<MissionMark> marks;
    const auto add=[&](job::Frame frame,job::Position point,double radius,job::ContactKind kind,
                       const std::string& name,bool selected,bool passage) {
        const auto p=pilot->missionRenderPoint(frame,point,radius);
        if (!p) return;
        const auto project=[&](Quad axis){ return double(p->x)*axis.x+double(p->y)*axis.y+double(p->z)*axis.z; };
        const double depth=project(flight.forward);
        if (depth<=0.) return;
        const double scale=.714285714/depth;
        const double x=.5+project(flight.right)*scale/flight.screen.x;
        const double y=.5-project(flight.up)*scale;
        if (x>.035 && x<.965 && y>.16 && y<.74)
            marks.push_back({x,y,p->w*scale,kind,name,selected,passage});
    };
    if (_missionGate) {
        const auto& point=_missionGate->entrance;
        add(point.frame,point.position,_missionGate->radius,job::ContactKind::Other,point.label,true,true);
    }
    for (const auto& item:_missionContacts) {
        const bool selected=_missionTarget==item.id;
        if (marks.size()<14 || selected)
            add(item.id.frame,item.position,item.radius,item.kind,item.name,selected,false);
    }
    const auto status=_missions->status();
    NSString* detail=nil;
    if (now<_missionNoticeUntil) detail=_missionNotice;
    else if (status.underAttack) detail=[NSString stringWithUTF8String:status.incomingFire.c_str()];
    else if (_missionGate) detail=@"H approaches the wormhole / Fly through the ring";
    else if (_hudObjective) detail=[NSString stringWithUTF8String:_hudObjective->task.c_str()];
    if (detail.length>width) detail=[[detail substringToIndex:width-1] stringByAppendingString:@"…"];
    const auto line=detail.length ? detail :
        [NSString stringWithFormat:@"Fuel %.0f/%.0f   ·   %lld GC   ·   F6 Bubble Missions",
            status.fuel,status.fuelCapacity,static_cast<long long>(status.credits)];
    [_missionSight present:std::move(marks) status:line objective:objective];
}

- (void)applicationDidFinishLaunching:(NSNotification*)notification {
    try {
        _ocean = std::make_unique<Ocean>(resource(@"orbits",@"txt").fileSystemRepresentation,
                                         0,OceanStart::ColossalBell);
        if (NSString* saved = [NSUserDefaults.standardUserDefaults stringForKey:savedBubbleStrings])
            _strings.restore(saved.UTF8String,*_ocean);
        auto device = MTLCreateSystemDefaultDevice();
        _renderer = [[Renderer alloc] initWithDevice:device];
        _flight.setTerrain([_renderer terrain]);
        _inFlight = dispatch_semaphore_create(2);
        _gpuSample = std::make_shared<std::atomic<std::uint64_t>>(0);
        _adaptiveResolution = YES;
        _flightGuide = YES;
        _musicResponse = YES;
        _graphicsStyle = GraphicsStyle::Hybrid;
        [self setupMissions];
        [self startAudio];

        _window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,1120,735)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable|NSWindowStyleMaskMiniaturizable|NSWindowStyleMaskResizable
                |NSWindowStyleMaskFullSizeContentView
            backing:NSBackingStoreBuffered defer:NO];
        _window.contentMinSize = NSMakeSize(500,420);
        NSString* version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        _window.title = version.length ? [@"Pelagic Spheres " stringByAppendingString:version] : @"Pelagic Spheres";
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
        [_atlas showMissionCounts:_layerMissionCounts];
        _atlas.open = NO;
        [_view addSubview:_atlas];
        _survey = [[SystemSurvey alloc] initWithFrame:_view.bounds];
        _survey.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _survey.ocean = _ocean.get();
        _survey.hidden = YES;
        [_view addSubview:_survey];
        _bubbleFlightHud = [[BubbleFlightHud alloc] initWithFrame:_view.bounds];
        _bubbleFlightHud.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _bubbleFlightHud.hidden = YES;
        [_view addSubview:_bubbleFlightHud];
        _missionWheel = [[BubbleMissionWheel alloc] initWithFrame:_view.bounds];
        _missionWheel.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _missionWheel.hidden = YES;
        [_view addSubview:_missionWheel];
        _missionSight = [[MissionSight alloc] initWithFrame:_view.bounds];
        _missionSight.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _missionSight.hidden = YES;
        [_view addSubview:_missionSight];
        _missionView = [[MissionView alloc] initWithFrame:_view.bounds];
        _missionView.autoresizingMask = NSViewWidthSizable|NSViewHeightSizable;
        _missionView.hidden = YES;
        [_view addSubview:_missionView];
        _window.contentView = _view;
        __weak Game* weak = self;
        [_missionView setActionHandler:^(board::Action action) { [weak missionInput:action]; }];
    _missionWheel.activate = ^(std::size_t row) { [weak openIlluminatedMission:row]; };
        _view.keyChange = ^(NSEvent* e,BOOL down) { [weak keyboard:e down:down]; };
        _view.motion = ^(CGFloat x,CGFloat y) { [weak panX:x y:y]; };
        _view.clearKeys = ^{ [weak clear]; };
        _view.callChange = ^(BOOL down) { [weak callInput:2 down:down]; };
        _view.fireTool = ^{ [weak fireBubbleTool:nil]; };
        _view.resumeLook = ^{ [weak setMouseLook:YES]; };
        _atlas.selection = ^(unsigned i) { [weak select:i]; };
        [_window center];
        [_window makeKeyAndOrderFront:nil];
        [_window makeFirstResponder:_view];
        [NSApp activate];
        dispatch_async(dispatch_get_main_queue(), ^{ [weak setMouseLook:YES]; });
    } catch (const std::exception& error) {
        NSAlert* alert = [NSAlert new];
        alert.messageText = @"Pelagic Spheres could not start";
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
- (void)toggleShipView:(id)sender {
    if (!_ocean) return;
    [self closeMissions];
    const BOOL entering = !_atHelm;
    _missionGate.reset();
    _previousGateEye.reset();
    if (_atHelm) {
        if (auto* pilot=[self missionPilot]) {
            _resumeMission=pilot->missionLocation();
            _resumeBubbleTint=pilot->bubbleTint();
            [self saveMissions];
        }
        _flight.cancelWarp();
        _boardedFlight.reset();
    }
    else if (!_boardedFlight && _resumeMission) {
        const auto pose=*_resumeMission;
        const job::MissionArrival arrival{pose.frame,pose.eye,pose.velocity,pose.orientation};
        if ([self enterMission:arrival]) {
            if (_resumeBubbleTint) _boardedFlight->setBubbleTint(*_resumeBubbleTint);
            if (const auto berth=_missions->resumeDock(pose)) {
                if (!_boardedFlight->restoreMissionDock(*berth,pose.aboardDockside))
                    [self recordMissionNotice:@"The previous berth is unavailable. Resume from your saved position."];
            } else if (pose.landed && !_boardedFlight->restoreMissionLanding(pose)) {
                [self recordMissionNotice:@"The previous landing site is unavailable. Resume from your saved position."];
            }
        }
    }
    else if (!_boardedFlight && !_visitedHomeCockpit) {
        _flight.syncOrbits(_ocean->orbitalTime());
        _flight.approachHomeWorld();
        _visitedHomeCockpit = YES;
    }
    _harpoonArrival.reset();
    _atHelm = entering;
    if (!entering && !_awaitingBubbleColours.empty()) {
        _awaitingBubbleColours.clear();
        [self updateBubbleProgress:YES];
    }
    _atlas.open = NO;
    _survey.hidden = YES;
    _exteriorView = NO;
    if (auto* pilot=[self missionPilot]) {
        [self bindMissionWorlds:*pilot];
        _missionTarget.reset();
        _missionRefreshAt=0.;
        [self syncMissionPilot:*pilot seconds:0.];
        if (_missionDestination) {
            const auto pending=*_missionDestination;
            _missionDestination.reset();
            [self applyMission:pending];
        }
    } else if (_missions) {
        auto location=_missions->location();
        location.active=false;
        location.aboardDockside=false;
        location.clamped.reset();
        _missions->synchronize(location);
    }
    [self clear];
    [self setMouseLook:(_atHelm || !_ocean->demo)];
}
- (void)toggleEnclosingView:(id)sender {
    if (_atHelm || !_survey.hidden || !_ocean || !_ocean->openingRoute() ||
        _ocean->transforming() || _ocean->returning()) return;
    _exteriorView = !_exteriorView;
    _atlas.open = NO;
    [self clear];
    [self updateMouseLook];
}
- (void)closeSurveyToAtlas:(BOOL)showAtlas {
    _survey.hidden = YES;
    _atlas.showingRegions = showAtlas;
    _atlas.open = showAtlas;
    [self clear];
    [self setMouseLook:!showAtlas && _surveyRestoreLook];
}
- (void)toggleRegionAtlas:(id)sender {
    if (_atHelm || !_ocean) return;
    if (!_survey.hidden) {
        [self closeSurveyToAtlas:YES];
        return;
    }
    const BOOL open = !_atlas.open || !_atlas.showingRegions;
    _atlas.showingRegions = YES;
    _atlas.open = open;
    [self clear];
    [self setMouseLook:!open];
}
- (void)toggleFlightGuide:(id)sender { _flightGuide = !_flightGuide; }
- (BOOL)inBubbleFlight {
    return _ocean && !_atHelm && !_exteriorView && !_atlas.open && _survey.hidden &&
           !_ocean->demo && !_ocean->transforming() && !_ocean->returning();
}
- (BOOL)bubbleToolsVisible {
    return [self inBubbleFlight] && _missionView.hidden;
}
- (BOOL)canLockMissionPosition {
    return _searchlightOn && _missionWheel.ready && _illuminatedBubble && [self bubbleToolsVisible] &&
           !_ocean->paused && !_harpoonArrival;
}
- (void)releaseMissionLock {
    if (!_lockedMissionBubble) return;
    _lockedMissionBubble.reset();
    _ocean->releaseBubble();
    [self clear];
    [self updateMouseLook];
}
- (void)toggleMissionLock:(id)sender {
    if (_lockedMissionBubble) {
        [self releaseMissionLock];
        return;
    }
    if (![self canLockMissionPosition]) return;
    _lockedMissionBubble = _illuminatedBubble;
    const auto& bubble = *_lockedMissionBubble;
    _ocean->holdBubble(bubble.slot,bubble.system,bubble.shellCentre,bubble.centre);
    _lookRequested = YES;
    [self clear];
    [self updateMouseLook];
}
- (void)toggleStringMode:(id)sender {
    if (![self bubbleToolsVisible] || _harpoonArrival) return;
    _strings.toggleMode();
    _stringFeedback = nil;
}
- (void)toggleHarpoonMode:(id)sender {
    if (![self bubbleToolsVisible] || _harpoonArrival) return;
    _strings.toggleHarpoon();
    _stringFeedback = nil;
}
- (void)toggleSearchlight:(id)sender {
    if (![self bubbleToolsVisible]) return;
    _searchlightOn = !_searchlightOn;
    if (!_searchlightOn) {
        [self releaseMissionLock];
        [self updateMissionWheel:std::nullopt at:0.];
    }
}
- (void)finishHarpoon:(double)now {
    if (!_harpoonArrival) return;
    if (![self bubbleToolsVisible]) {
        _harpoonArrival.reset();
        return;
    }
    if (now < _harpoonArrivalTime || _ocean->paused) return;
    const auto target = _harpoonArrival->anchor;
    const auto heading = _harpoonArrival->heading;
    _harpoonArrival.reset();
    if (!_ocean->canBoardBubble(target.bubble)) return;
    const auto view = _ocean->scene(1.f);
    const auto bubble = _ocean->stringBubble(target.bubble,view);
    _boardWater = view.water;
    _boardAccent = view.bright;
    if (const auto* region = _ocean->bubbleRegion(target.bubble)) {
        _boardAccent = _ocean->regionTint(*region);
        _boardWater = {_boardAccent.x*.44f,_boardAccent.y*.44f,_boardAccent.z*.44f};
        if (target.system == BubbleAnchor::shell) {
            _boardedFlight.emplace(*_ocean,*region,_ocean->orbitalTime(),target.direction);
        } else {
            const unsigned id = _ocean->systemBubbleIds()[target.system];
            if (id == ziksaSystemId) {
                _boardedFlight = _flight;
                _boardedFlight->enterAtFilm(target.direction);
            } else {
                _boardedFlight.emplace(_ocean->systemBubbles()[target.system],id,_ocean->orbitalTime(),
                                       target.direction,_ocean->systemById(id));
            }
        }
    } else if (target.bubble == 0) {
        _boardedFlight = _flight;
        _boardedFlight->enterAtFilm(target.direction);
    } else if (const auto* record = _ocean->bubbleSystem(target.bubble)) {
        if (bubble && bubble->membraneAnchor > 0.f) {
            _boardAccent = view.passageColours[unsigned(bubble->membraneAnchor)-1];
            _boardWater = {_boardAccent.x*.44f,_boardAccent.y*.44f,_boardAccent.z*.44f};
        }
        if (record->id == ziksaSystemId) {
            _boardedFlight = _flight;
            _boardedFlight->enterAtFilm(target.direction);
        } else {
            _boardedFlight.emplace(systemModel(*record),record->id,_ocean->orbitalTime(),target.direction,record);
        }
    }
    if (_boardedFlight) {
        _boardedFlight->setTerrain([_renderer terrain]);
        _boardedFlight->holdEntryHeading(heading);
        _ocean->holdShip();
        if (bubble) _boardedFlight->setBubbleTint(bubble->palette);
        _stringFeedback = nil;
        [self toggleShipView:nil];
        if (const auto objective=_dispatch->objective(); objective && _boardedFlight) {
            if (_boardedFlight->region()) {
                _boardedFlight->selectRegionTarget(objective->frame.system);
            } else if (_boardedFlight->systemId()==objective->frame.system &&
                       (!objective->frame.world ||
                        _boardedFlight->exposeMissionWorld(*objective->frame.world,_missionWorlds))) {
                _boardedFlight->selectMissionWorld(objective->frame.world);
            }
        }
    }
}
- (void)fireBubbleTool:(id)sender {
    if (![self bubbleToolsVisible] || _ocean->paused || _harpoonArrival) return;
    const auto size = _view.bounds.size;
    auto view = _ocean->scene(float(size.width/std::max(1.,size.height)));
    view.graphicsStyle = _graphicsStyle;
    const auto now = [self bubbleTimeAt:CACurrentMediaTime()];
    if (_strings.harpooning()) {
        const auto hit = _strings.fireHarpoon(*_ocean,view,now);
        if (hit && hit->inward) {
            _harpoonArrival = hit;
            _harpoonArrivalTime = now+.24;
            _stringFeedback = @"Harpoon on its way";
        } else if (hit && _ocean->bubbleEntryLocked(hit->anchor.bubble)) {
            _stringFeedback = [NSString stringWithFormat:@"%@ passage sealed",layerTitle(_ocean->oceanDepth()+1)];
        } else {
            _stringFeedback = hit ? @"Only inward skins can be entered" : @"No bubble skin in sight";
        }
        _stringFeedbackUntil = now+1.6;
        return;
    }
    const auto result = _strings.fire(*_ocean,view,now);
    switch (result) {
        case BubbleStrings::Result::Miss:
            _stringFeedback = _strings.cutting() ? @"No string in sight" : @"No bubble in sight";
            break;
        case BubbleStrings::Result::Anchored: _stringFeedback = nil; break;
        case BubbleStrings::Result::SameBubble: _stringFeedback = @"Aim at a different bubble"; break;
        case BubbleStrings::Result::AlreadyLinked: _stringFeedback = @"These bubbles are already linked"; break;
        case BubbleStrings::Result::Connected: _stringFeedback = @"String connected"; break;
        case BubbleStrings::Result::Disconnected: _stringFeedback = @"String disconnected"; break;
    }
    _stringFeedbackUntil = now+1.6;
    if (result == BubbleStrings::Result::Connected || result == BubbleStrings::Result::Disconnected) {
        const auto saved = _strings.encode();
        [NSUserDefaults.standardUserDefaults setObject:[NSString stringWithUTF8String:saved.c_str()]
                                               forKey:savedBubbleStrings];
        const unsigned priorMatch=_passagePatternMatch;
        [self refreshPassagePattern];
        if (_passagePatternMatch>priorMatch)
            _stringFeedback = _strings.passageReady() ? @"Chain ready. Tap F to sound it" :
                [NSString stringWithFormat:@"%u bubbles match the passage pattern",_passagePatternMatch];
    }
}
- (void)updateBubbleHud:(double)now {
    const auto tracked=_missions ? _missions->stories.tracked() : std::nullopt;
    if (tracked!=_hudTracked || (tracked && now>=_objectiveRefreshAt)) {
        _hudTracked=tracked;
        _hudObjective=tracked ? _dispatch->objective() : std::nullopt;
        _objectiveRefreshAt=now+.4;
    }
    const BOOL visible=[self bubbleToolsVisible];
    if (_bubbleFlightHud.hidden==visible) _bubbleFlightHud.hidden=!visible;
    if (!visible) return;
    if (_passageLayer!=_ocean->oceanDepth()) [self refreshPassagePattern];

    BubbleFlightHudState state{};
    state.tool=_strings.harpooning() ? BubbleTool::Harpoon :
               _strings.cutting() ? BubbleTool::Disconnect : BubbleTool::String;
    state.searchlight=_searchlightOn;
    state.locked=_lockedMissionBubble.has_value();
    state.canLock=!state.locked && [self canLockMissionPosition];
    state.anchored=_strings.anchored();
    state.paused=_ocean->paused;
    if (_ocean->openingRoute()) {
        const unsigned layer=_ocean->oceanDepth();
        state.layer=layer;
        state.layerName=layerTitle(layer).UTF8String;
        if (layer+1<regionScales) state.passageName=layerTitle(layer+1).UTF8String;
        state.gateCompleted=_restoredBubbleCount;
        if (_ocean->passageLocked()) state.passagePattern=_passagePatterns[layer];
        state.passageMatch=_passagePatternMatch;
        state.passageReady=_strings.passageReady();
        state.notesPlayed=_strings.sequenceNotesPlayed();
        state.sequenceLength=_strings.sequenceLength();
    }
    if (_hudObjective) {
        state.objective=_hudObjective->headline;
        state.destination=_hudObjective->destination;
        state.instruction=state.tool==BubbleTool::Harpoon ? "Aim at the bubble and fire to enter" : "Z Switch to harpoon to enter the bubble";
    } else if (state.layer==0 && !_bubbleMissions->completed({BubbleKind::System,openingSignalSystemId})) {
        state.objective="Faint distress signal";
        state.destination=_bubbleMissions->label({BubbleKind::System,openingSignalSystemId})+" system bubble";
        state.instruction=!_searchlightOn ? "O Turn on the searchlight" :
            _missionWheel.ready ? "Shift + 1 Open the beacon assignment" : "Hold the light on the signal";
    } else {
        state.objective="Find an assignment";
        state.instruction=_searchlightOn ? "Hold the light on a bubble for one second" : "O Turn on the searchlight";
    }
    if ([self bubbleTimeAt:now]<_stringFeedbackUntil && _stringFeedback)
        state.toolHint=_stringFeedback.UTF8String;
    else if (state.tool==BubbleTool::Harpoon)
        state.toolHint="Aim at an inner skin";
    else if (state.tool==BubbleTool::Disconnect)
        state.toolHint="Aim at a string";
    else
        state.toolHint=state.anchored ? "Aim at a second bubble" : "Aim at a bubble";
    [_bubbleFlightHud present:state telemetry:_ocean->flightTelemetry()];
}
- (void)markNearbyRegion:(id)sender {
    if (_atHelm || !_ocean || !_survey.hidden || _atlas.open || _exteriorView) return;
    const auto view = _ocean->scene(1.f);
    const auto* region = _ocean->nearbyRegion(view);
    if (region && region != _ocean->selectedRegion()) _ocean->markRegion(region->cell);
    else _ocean->markRegion(regionCells);
}
- (void)toggleSurvey:(id)sender {
    if (_atHelm || !_ocean) return;
    if (!_survey.hidden) {
        [self closeSurveyToAtlas:_surveyFromAtlas];
        return;
    }
    const BOOL fromAtlas = _atlas.open && _atlas.showingRegions;
    if (!fromAtlas && (_atlas.open || _exteriorView)) return;
    const auto view = _ocean->scene(1.f);
    const auto* region = fromAtlas ? _ocean->selectedRegion() : _ocean->nearbyRegion(view,true);
    if (!region) return;
    _surveyFromAtlas = fromAtlas;
    _surveyRestoreLook = _lookRequested || fromAtlas;
    _ocean->markRegion(region->cell);
    _atlas.open = NO;
    [_survey showRegion:*region];
    [self setMouseLook:NO];
}
- (BOOL)validateMenuItem:(NSMenuItem*)item {
    if (item.action == @selector(showMissionBoard:)) return bool(_missions);
    if (item.action == @selector(toggleSearchlight:)) {
        item.state = _searchlightOn ? NSControlStateValueOn : NSControlStateValueOff;
        return [self bubbleToolsVisible];
    }
    if (item.action == @selector(toggleMissionLock:)) {
        item.title = _lockedMissionBubble ? @"Release Mission Position (U)" : @"Lock Mission Position (U)";
        return _lockedMissionBubble || [self canLockMissionPosition];
    }
    if (item.action == @selector(fireBubbleTool:)) return [self bubbleToolsVisible] && !_ocean->paused && !_harpoonArrival;
    if (item.action == @selector(toggleStringMode:)) {
        item.title = _strings.harpooning() ? @"Return to String Tools" :
                     _strings.cutting() ? @"Switch to String" : @"Switch to Disconnect Beam";
        return [self bubbleToolsVisible] && !_harpoonArrival;
    }
    if (item.action == @selector(toggleHarpoonMode:)) {
        item.title = _strings.harpooning() ? @"Return to String Tools" : @"Select Harpoon";
        return [self bubbleToolsVisible] && !_harpoonArrival;
    }
    if (item.action == @selector(toggleSurvey:)) {
        item.state = _survey.hidden ? NSControlStateValueOff : NSControlStateValueOn;
        return _ocean && !_atHelm && (!_exteriorView || (_atlas.open && _atlas.showingRegions));
    }
    if (item.action == @selector(markNearbyRegion:))
        return _ocean && !_atHelm && !_exteriorView && !_atlas.open && _survey.hidden;
    if (item.action == @selector(toggleFlightGuide:)) {
        item.state = _flightGuide ? NSControlStateValueOn : NSControlStateValueOff;
        return !_atHelm && bool(_ocean);
    }
    if (item.action == @selector(toggleRegionAtlas:)) {
        item.state = _atlas.open && _atlas.showingRegions ? NSControlStateValueOn : NSControlStateValueOff;
        return !_atHelm && bool(_ocean);
    }
    if (item.action == @selector(toggleAdaptiveResolution:)) {
        item.state = _adaptiveResolution ? NSControlStateValueOn : NSControlStateValueOff;
        return bool(_gpuSample);
    }
    if (item.action == @selector(toggleShipView:)) {
        item.title = _atHelm ? @"Return to Chase View" : @"Ziksa Cockpit";
        return bool(_ocean);
    }
    if (item.action == @selector(toggleEnclosingView:)) {
        item.state = _exteriorView ? NSControlStateValueOn : NSControlStateValueOff;
        return !_atHelm && _survey.hidden && _ocean && _ocean->openingRoute() &&
               !_ocean->transforming() && !_ocean->returning();
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
        if ([self bubbleToolsVisible] && !_callInput && !_harpoonArrival &&
            !_strings.sequenceLength() && _ocean->beginCall())
            _callInput=source;
        return;
    }
    if (_callInput != source) return;
    _callInput=0;
    if (_ocean->releaseCall(Call::Resonance) && _ocean->resonantCall()) {
        _strings.beginResonance(_ocean->oceanDepth());
        _stringFeedback=@"Pulse wave sent";
        _stringFeedbackUntil=[self bubbleTimeAt:CACurrentMediaTime()]+1.2;
    }
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
    const BOOL looking = _lookRequested && !_lockedMissionBubble && _ocean && !_atlas.open && _survey.hidden &&
                         _missionView.hidden && !_ocean->paused && !_exteriorView;
    [_view enableLook:looking lockCursor:_window.isKeyWindow && NSApp.isActive];
}
- (void)panX:(CGFloat)x y:(CGFloat)y {
    if (!_view.looking) return;
    _panX += std::clamp(float(x),-102.f,102.f)*.0035f;
    _panY -= std::clamp(float(y),-102.f,102.f)*.0035f;
}
- (void)select:(unsigned)i {
    [self releaseMissionLock];
    [self clear];
    if (i <= currents.size()) {
        [self setGamePaused:NO];
        if (i == currents.size()) _ocean->uncharted();
        else _ocean->voyage(i);
    }
    _atlas.open = NO;
    [self setMouseLook:YES];
}
- (void)keyboard:(NSEvent*)event down:(BOOL)down {
    const auto code = event.keyCode;
    if (!_missionView.hidden) {
        if (down) [_missionView handleKey:event];
        return;
    }
    if (!_atHelm && code==49) {
        if (down && !event.isARepeat && _survey.hidden && (!_atlas.open || !_atlas.showingRegions)) {
            [self clear];
            [self setGamePaused:!_ocean->paused];
            [self setMouseLook:!_ocean->paused];
        }
        return;
    }
    if (code < _pressed.size()) _pressed[code] = down;
    NSString* key = event.charactersIgnoringModifiers.lowercaseString;
    if (down && !event.isARepeat) {
        if (event.modifierFlags&NSEventModifierFlagShift) {
            constexpr std::array<unsigned,6> numberKeys{18,19,20,21,23,22};
            const auto row = std::find(numberKeys.begin(),numberKeys.end(),code);
            if (row!=numberKeys.end() && [self openIlluminatedMission:std::size_t(row-numberKeys.begin())]) return;
        }
        switch (code) {
            case 118: [self displayMissionPage:board::Page::Charters]; return;
            case 97: [self openBubbleMissions]; return;
            case 98: [self displayMissionPage:board::Page::Nearby]; return;
            case 100: [self displayMissionPage:board::Page::Combat]; return;
            case 101: [self displayMissionPage:board::Page::Convoys]; return;
            case 109: [self displayMissionPage:board::Page::Fleet]; return;
        }
    }
    if ([key isEqualToString:@"g"]) {
        if (down && !event.isARepeat) [self toggleShipView:nil];
        return;
    }
    if (_atHelm) {
        if (!down || event.isARepeat) return;
        if (code == 53) [self setMouseLook:NO];
        if ([key isEqualToString:@"c"]) [self setMouseLook:!_lookRequested];
        if (auto* pilot=[self missionPilot]; pilot && !_ocean->paused) {
            if (code==36 || code==76) { [self interactWithMission:*pilot board:NO]; return; }
            if (code==14) {
                const auto current=pilot->missionLocation();
                if (current.clamped || current.landed) { [self interactWithMission:*pilot board:YES]; return; }
            }
            if ([key isEqualToString:@"n"]) {
                const bool lead=_dispatch->scan();
                const bool intel=_strategy->localScan();
                [self recordMissionText:_dispatch->takeNotice()];
                if (intel) [self recordMissionNotice:@"Local scans logged. Open Intelligence in F10."];
                if (lead || intel) [self saveMissions];
                return;
            }
            if ([key isEqualToString:@"t"]) { [self cycleMissionContact]; return; }
            if ([key isEqualToString:@"i"]) {
                if (_missionTarget) {
                    const bool heard=_transport->hail(*_missionTarget);
                    [self recordMissionText:_transport->message()];
                    if (heard) {
                        _strategy->heard(*_missionTarget);
                        [self saveMissions];
                    }
                } else [self recordMissionNotice:@"Use T to select a radio contact."];
                return;
            }
            if ([key isEqualToString:@"h"]) {
                if (!_missionGate) [self recordMissionNotice:@"Set a route for an assignment in another system."];
                else if (pilot->beginMissionApproach(_missionGate->entrance)) {
                    _previousGateEye.reset();
                    [self recordMissionNotice:@"Approaching ring / Use W to fly through once the drive ends"];
                } else [self recordMissionNotice:@"Helm unavailable. Clear the berth and check drive status."];
                return;
            }
            if ([key isEqualToString:@"u"]) {
                _strategy->toggleArmed();
                [self recordMissionNotice:_missions->combat.armed ? @"Weapons armed / 1–3 select / Space fires" :
                                                                     @"Weapons safe"];
                return;
            }
            if (key.length==1) {
                const unichar c=[key characterAtIndex:0];
                if (c>='1' && c<='3') _strategy->selectWeapon(c-'1');
            }
            if ([key isEqualToString:@" "] && _missions->combat.armed &&
                !(event.modifierFlags&NSEventModifierFlagShift)) return;
        }
        if ([key isEqualToString:@"y"] || [key isEqualToString:@"f"]) {
            auto& pilot = _boardedFlight ? *_boardedFlight : _flight;
            if ([key isEqualToString:@"y"]) pilot.nextTarget();
            else pilot.toggleAssist();
        }
        if ([key isEqualToString:@"j"] && !_ocean->paused)
            (_boardedFlight ? *_boardedFlight : _flight).engageWarp();
        if ([key isEqualToString:@"m"]) [self toggleMute:nil];
        if ([key isEqualToString:@" "]) {
            [self setGamePaused:!_ocean->paused];
            [self setMouseLook:!_ocean->paused];
        }
        return;
    }
    if (!_survey.hidden) {
        if (down && (code == 123 || code == 124)) [_survey cycle:code == 123 ? -1 : 1];
        if (down && !event.isARepeat) {
            if ((code==36 || code==76) && (event.modifierFlags&NSEventModifierFlagShift)) {
                _missionCommandSystem=_ocean->systemBubbleIds()[[_survey systemIndex]];
                [self displayMissionPage:board::Page::Fleet];
                return;
            }
            if ([key isEqualToString:@"x"] || code == 53) [self toggleSurvey:nil];
            if ([key isEqualToString:@"r"]) [self closeSurveyToAtlas:YES];
            if ([key isEqualToString:@"m"]) [self toggleMute:nil];
        }
        return;
    }
    if ([key isEqualToString:@"f"]) {
        if (!event.isARepeat) [self callInput:1 down:down];
        return;
    }
    if (!down || event.isARepeat) return;
    if ((code == 36 || code == 76) && !_atlas.open) {
        [self fireBubbleTool:nil];
        return;
    }
    if ([key isEqualToString:@"x"]) {
        [self toggleSurvey:nil];
    } else if ([key isEqualToString:@"r"]) {
        [self toggleRegionAtlas:nil];
    } else if (code == 48) {
        const BOOL open = !_atlas.open || _atlas.showingRegions;
        _atlas.showingRegions = NO;
        _atlas.open = open;
        [self clear];
        [self setMouseLook:!_atlas.open];
    } else if (code == 53) {
        if (_lockedMissionBubble) {
            [self releaseMissionLock];
            return;
        }
        _atlas.open = NO;
        [self setMouseLook:NO];
    } else if (!_atlas.open || !_atlas.showingRegions) {
        if (key.length != 1) return;
        const unichar c = [key characterAtIndex:0];
        if (c >= '1' && c <= '8') [self select:c-'1'];
        if (c == 'p') {
            _graphicsStyle = _graphicsStyle == GraphicsStyle::Original ? GraphicsStyle::Hybrid :
                             _graphicsStyle == GraphicsStyle::Hybrid ? GraphicsStyle::Painted :
                             _graphicsStyle == GraphicsStyle::Painted ? GraphicsStyle::Ultra :
                             GraphicsStyle::Original;
        }
        if (c == 'd') {
            _ocean->demo = !_ocean->demo;
            if (_ocean->demo) [self setGamePaused:NO];
            [self setMouseLook:!_ocean->demo];
        }
        if (c == 'm') [self toggleMute:nil];
        if (c == 'v') [self toggleEnclosingView:nil];
        if (c == 'h') [self toggleFlightGuide:nil];
        if (c == 't') [self toggleStringMode:nil];
        if (c == 'z') [self toggleHarpoonMode:nil];
        if (c == 'o') [self toggleSearchlight:nil];
        if (c == 'u') [self toggleMissionLock:nil];
        if (c == 'c' && [self bubbleToolsVisible] && _strings.anchored()) {
            _strings.cancelAnchor();
            _stringFeedback = nil;
        }
        if (c == 'y') [self markNearbyRegion:nil];
        if (c == 'n' || c == '\r') {
            [self releaseMissionLock];
            [self clear];
            const bool chart = _atlas.open;
            _atlas.open = NO;
            [self setGamePaused:NO];
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
    [self saveMissions];
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
    const auto bubbleNow=[self bubbleTimeAt:now];
    [self finishHarpoon:bubbleNow];
    const float dt = _last > 0 ? float(now-_last) : 1.f/60.f;
    _last = now;
    if (_lockedMissionBubble && ![self inBubbleFlight]) [self releaseMissionLock];
    if (!_atlas.open && _survey.hidden && !_ocean->paused) {
        const float x = float(_pressed[124])-float(_pressed[123]);
        const float y = float(_pressed[14])-float(_pressed[12]);
        const float z = float(_pressed[126] || _pressed[13])-float(_pressed[125] || _pressed[1]);
        const float lookX = float(_pressed[37])-float(_pressed[38]);
        const float lookY = float(_pressed[34])-float(_pressed[40]);
        const bool wasDrifting = _ocean->demo;
        const float before = _ocean->transformationProgress();
        const auto flags = _window.isKeyWindow ? NSEvent.modifierFlags : 0;
        Helm helm{};
        if (_atHelm && _window.isKeyWindow && _missionView.hidden) {
            const auto axis = [&](unsigned positive, unsigned negative) {
                return double(_pressed[positive])-double(_pressed[negative]);
            };
            helm = {.strafe=axis(2,0),.lift=axis(14,12),.thrust=axis(13,1),
                    .pitch=axis(126,125),.yaw=axis(124,123),
                    .roll=double(_pressed[31] || _pressed[9])-double(_pressed[6]),
                    .mouseX=_panX,.mouseY=_panY,
                    .boost=bool(flags&NSEventModifierFlagOption),
                    .precise=bool(flags&NSEventModifierFlagControl),.brake=_pressed[11],
                    .lookAround=bool(flags&NSEventModifierFlagShift),.level=_pressed[15]};
        }
        _flight.step(dt,helm,_atHelm && !_boardedFlight);
        if (_boardedFlight) {
            _boardedFlight->step(dt,helm,true);
            _ocean->advanceOrbits(std::clamp(double(dt),0.,.1));
        } else if (_exteriorView || _atHelm) {
            _ocean->step(dt,{},0.f,0.f,_atHelm && !_ocean->demo);
        } else if (!_harpoonArrival) {
            const auto mode = flags&NSEventModifierFlagControl ? ThrustMode::Precision :
                              flags&NSEventModifierFlagOption ? ThrustMode::Boost : ThrustMode::Normal;
            _ocean->step(dt,{x,y,z},_panX+dt*lookX*.85f,_panY+dt*lookY*.70f,_pressed[11],mode,bool(_lockedMissionBubble));
        }
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
        if (wasDrifting && !_ocean->demo && !_atHelm) [self setMouseLook:YES];
        if (auto* pilot=[self missionPilot]) {
            [self syncMissionPilot:*pilot seconds:dt];
            const bool convoyPassage=_missionGate && _missionDestination && _missionDestination->point.connection;
            if (helm.brake || (!convoyPassage && (helm.thrust || helm.strafe || helm.lift ||
                    helm.pitch || helm.yaw || helm.roll || helm.mouseX || helm.mouseY)))
                _transport->cancelFollow();
            if (_pressed[49] && _missionView.hidden && !(flags&NSEventModifierFlagShift))
                _strategy->fire();
            [self refreshMissionFlight:*pilot at:now];
            [self checkMissionPassage:*pilot];
            if (now>=_missionSaveAt) [self saveMissions];
        }
    }
    if (!_survey.hidden && !_ocean->paused) _ocean->advanceOrbits(std::clamp(double(dt),0.,.1));
    _flight.syncOrbits(_ocean->orbitalTime());
    if (_boardedFlight) _boardedFlight->syncOrbits(_ocean->orbitalTime());
    _panX = 0; _panY = 0;
    [self advanceBubbleResonance:bubbleNow];
    [self updateBubbleHud:now];
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
        if (_ocean->calls()>_lastCallNumber && !_ocean->resonantCall()) _score->pulse(_ocean->drawnCall());
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
    const auto ocean = _atHelm ? _ocean->scene(1.f) : Scene{};
    const auto& pilot = _boardedFlight ? *_boardedFlight : _flight;
    const auto flight = pilot.scene(float(drawable.texture.width)/drawable.texture.height,
                                    _boardedFlight ? _boardWater : ocean.water,
                                    _boardedFlight ? _boardAccent : ocean.bright);
    [self updateMissionSight:now flight:flight];
    const bool adaptive = !_atHelm && _survey.hidden && _adaptiveResolution &&
                          !_exteriorView && _graphicsStyle != GraphicsStyle::Ultra &&
                          drawable.texture.width > adaptiveMinimumWidth;
    const auto gpuSample = adaptive ? _gpuSample : nullptr;
    const unsigned drawableWidth = unsigned(drawable.texture.width);
    if (gpuSample) {
        const auto sample = gpuSample->exchange(0,std::memory_order_relaxed);
        _resolution.observe(drawableWidth,unsigned(sample >> 32),std::uint32_t(sample)*.001);
    }
    const unsigned renderWidth = adaptive ? _resolution.width(drawableWidth) : nativeRenderWidth;
    id<MTLCommandBuffer> cmd;
    std::optional<BubbleInspection> inspection;
    if (!_survey.hidden) {
        auto light = [_survey tint];
        light.w = float(_ocean->orbitalTime());
        cmd = [_renderer survey:drawable.texture ocean:*_ocean system:[_survey systemIndex]
                        frame:[_survey previewFrame] light:light ziksa:_flight.overviewScene(flight.screen.x)];
    } else if (_atHelm) {
        cmd = [_renderer fly:drawable.texture scene:flight ocean:*_ocean pilot:pilot];
    } else {
        const bool searchlight = _searchlightOn && [self bubbleToolsVisible];
        if (searchlight && _lockedMissionBubble) inspection = _lockedMissionBubble;
        cmd = [_renderer render:drawable.texture ocean:*_ocean music:_music phase:float(_musicPhase)
                         style:_graphicsStyle exterior:_exteriorView guide:_flightGuide aim:!_atlas.open
                         searchlight:searchlight maxWidth:renderWidth
                         flight:_flight.overviewScene(flight.screen.x) strings:&_strings toolTime:bubbleNow
                         inspection:searchlight && !_lockedMissionBubble ? &inspection : nullptr];
    }
    [self updateMissionWheel:inspection at:bubbleNow];
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
                         guide:false aim:false searchlight:false maxWidth:nativeRenderWidth
                        flight:ShipFlight{}.overviewScene(float(width)/height) strings:nullptr toolTime:0. inspection:nullptr];
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
        NSMenu* appMenu = [[NSMenu alloc] initWithTitle:@"Pelagic Spheres"];
        [appMenu addItemWithTitle:@"Quit Pelagic Spheres" action:@selector(terminate:) keyEquivalent:@"q"];
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
        [view addItemWithTitle:@"Star System Cockpit" action:@selector(toggleShipView:) keyEquivalent:@""].target = game;
        [view addItemWithTitle:@"Flight Guide" action:@selector(toggleFlightGuide:) keyEquivalent:@""].target = game;
        [view addItemWithTitle:@"Mark Nearby Region" action:@selector(markNearbyRegion:) keyEquivalent:@""].target = game;
        [view addItemWithTitle:@"Inspect Systems" action:@selector(toggleSurvey:) keyEquivalent:@""].target = game;
        [view addItemWithTitle:@"View Enclosing Sphere" action:@selector(toggleEnclosingView:) keyEquivalent:@""].target = game;
        [view addItemWithTitle:@"Xalaria Region Atlas" action:@selector(toggleRegionAtlas:) keyEquivalent:@""].target = game;
        NSMenuItem* viewItem = [[NSMenuItem alloc] initWithTitle:@"View" action:nil keyEquivalent:@""];
        viewItem.submenu = view;
        [main addItem:viewItem];
        NSMenu* tools = [[NSMenu alloc] initWithTitle:@"Tools"];
        [tools addItemWithTitle:@"Fire" action:@selector(fireBubbleTool:) keyEquivalent:@""].target = game;
        [tools addItemWithTitle:@"Switch to Disconnect Beam" action:@selector(toggleStringMode:) keyEquivalent:@""].target = game;
        [tools addItemWithTitle:@"Select Harpoon" action:@selector(toggleHarpoonMode:) keyEquivalent:@""].target = game;
        [tools addItemWithTitle:@"Searchlight (O)" action:@selector(toggleSearchlight:) keyEquivalent:@""].target = game;
        [tools addItemWithTitle:@"Lock Mission Position (U)" action:@selector(toggleMissionLock:) keyEquivalent:@""].target = game;
        NSMenuItem* toolsItem = [[NSMenuItem alloc] initWithTitle:@"Tools" action:nil keyEquivalent:@""];
        toolsItem.submenu = tools;
        [main addItem:toolsItem];
        NSMenu* missions = [[NSMenu alloc] initWithTitle:@"Missions"];
        NSArray<NSString*>* titles=@[@"Bubble Missions  (F6)",@"Dispatch  (F7)",@"Combat  (F8)",@"Charters  (F4)",
            @"Convoys  (F9)",@"Fleet  (F10)",@"Intelligence",@"Campaigns"];
        constexpr board::Page pages[]={board::Page::SystemBubble,board::Page::Nearby,board::Page::Combat,board::Page::Charters,
            board::Page::Convoys,board::Page::Fleet,board::Page::Intelligence,board::Page::Campaigns};
        for (NSUInteger i=0;i<titles.count;++i) {
            NSMenuItem* item=[missions addItemWithTitle:titles[i] action:@selector(showMissionBoard:) keyEquivalent:@""];
            item.target=game;
            item.tag=static_cast<NSInteger>(pages[i]);
        }
        NSMenuItem* missionItem=[[NSMenuItem alloc] initWithTitle:@"Missions" action:nil keyEquivalent:@""];
        missionItem.submenu=missions;
        [main addItem:missionItem];
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
