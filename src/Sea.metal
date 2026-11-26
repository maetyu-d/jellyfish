#include <metal_stdlib>
using namespace metal;

struct Planet { float4 position, material, pigment; float ringOpacity, opacity; };
constant uint systemPlanetLimit = 9u;
struct WorldAppearance { float4 dark, light, features, annulus, pole; };
struct SystemBubble {
    float4 position, star;
    float4 orbits[systemPlanetLimit], colours[systemPlanetLimit], materials[systemPlanetLimit];
    float4 catalogue;
    WorldAppearance appearances[systemPlanetLimit];
};
float4 catalogueInterior(device const SystemBubble& system, float3 eye, float3 ray,
                         float membrane, float pixel, float time);
struct BellSystem { float4 sun, sunlight; Planet planets[3]; float4 skyPositions[3]; float4 region; };
constant uint bellPassageCount = 5u;
struct Scene {
    float4 screen, eye, right, up, forward, deep, water, bright, contrast, sun, sunlight, tide;
    Planet planets[3];
    float4 player;
    float4 call;
    float4 music;
    float4 habitat;
    float4 eclipse;
    float4 basinWave;
    float4 paletteMix;
    float4 innerOcean;
    float4 passages[bellPassageCount];
    float4 passageColours[bellPassageCount];
    float4 enclosingBell;
    float4 enclosingShape;
    float4 whirlpool;
    float4 cycle;
    float4 returnPassage;
    float4 passageFlow;
    float4 enclosedOrbits;
    uint graphicsStyle;
    float enclosingSky;
    float celestialTime;
    float skyDepth;
    float orbitalPixel;
    float whirlpoolApproach;
    float basinArrival;
    float playerSystem;
    float4 enclosingPalette, interiorPalette, birthPalette;
    float4 searchlightOrigin, searchlightAxis;
    float4 heldBubbleCentre, heldSystemCentre;
    uint heldBubble, heldSystem;
    uint lockedPassage, openPassage;
    float4 pulseAxis;
};
struct Bubble {
    float4 position, pigment, flow, trail;
    float presence, eclipsing, basinLight, basinTone, pitch, membraneAnchor, bellSystem, bellSystemVisibility;
    float4 palette;
};
struct Tracer { float4 head, tail; float wake, current; };
struct FlowNode { float4 point, light; };
struct TrailPose { float4 position, light, palette; };
struct Full { float4 p [[position]]; float2 uv; };
constant float pi = 3.14159265;
constant float tau = 6.2831853;
constant float focal = 1.94;
constant float3 moonDirection = float3(-.32108,.43145,.84283);
constant float moonRadius = .049;
constant uint hybridGraphics = 1u;
constant uint paintedGraphics = 2u;
constant uint ultraGraphics = 3u;

constant float3 bubbleLuma = float3(.2126,.7152,.0722);

float3 bubbleChroma(float3 light, float4 palette) {
    if (palette.w >= 1.) return light;
    const float value = max(0.,dot(light,bubbleLuma));
    // A gentle highlight shoulder keeps the locked hue as lights accumulate.
    const float3 monochrome = palette.rgb * (.40*value/(1.+.28*value));
    return mix(monochrome,light,palette.w);
}
float3 displayBubbleChroma(float3 light, float4 palette) {
    if (palette.w >= 1.) return light;
    const float value = saturate(dot(light,bubbleLuma));
    return mix(palette.rgb*(value*(.50+.50*value)),light,palette.w);
}
float bubbleColourAt(float restoredAt,float time) {
    if (restoredAt < 0.) return restoredAt == -2. ? 1. : 0.;
    return smoothstep(0.,2.5,time-restoredAt);
}

constant float3 searchlightColour = float3(.74,.91,1.);
constant float searchlightSlope = .115;
constant float searchlightMouth = .012;

float searchlightProfile(float3 point, float axial, float3 axis) {
    const float3 lateral = point-axis*axial;
    const float radius = searchlightSlope*(axial+searchlightMouth);
    const float crossSection = dot(lateral,lateral)/max(.000001,radius*radius);
    return (1.-smoothstep(.10,1.,crossSection))*(1.-smoothstep(.62,1.,axial));
}

float searchlightAt(float3 world, constant Scene& s) {
    const float range = s.searchlightOrigin.w;
    if (range <= 0.) return 0.;
    const float3 point = (world-s.searchlightOrigin.xyz)/range;
    const float axial = dot(point,s.searchlightAxis.xyz);
    if (axial <= 0. || axial >= 1.) return 0.;
    return s.searchlightAxis.w*searchlightProfile(point,axial,s.searchlightAxis.xyz)/(1.+12.*axial*axial);
}

float searchlightFilm(float3 world, float3 normal, constant Scene& s) {
    const float beam = searchlightAt(world,s);
    if (beam <= 0.) return 0.;
    const float3 towardLamp = normalize(s.searchlightOrigin.xyz-world);
    // Either side of a transparent film can catch the light.
    const float incidence = abs(dot(normal,towardLamp));
    return beam*(.28+.72*incidence);
}

float3 searchlightScatter(float3 ray, constant Scene& s) {
    const float range = s.searchlightOrigin.w;
    if (range <= 0.) return float3(0.);
    const float3 axis = s.searchlightAxis.xyz;
    const float3 origin = (s.eye.xyz-s.searchlightOrigin.xyz)/range;
    const float height = dot(origin,axis), climb = dot(ray,axis);
    float near = 0., far = length(origin)+1.2;
    if (abs(climb) > .0001) {
        const float a = -height/climb, b = (1.-height)/climb;
        near = max(near,min(a,b));
        far = min(far,max(a,b));
    } else if (height < 0. || height > 1.) return float3(0.);
    if (far <= near) return float3(0.);

    // Intersect the actual cone so the narrow beam at the nose gets enough samples.
    const float3 radial = origin-axis*height, tangent = ray-axis*climb;
    const float radius = searchlightSlope*(height+searchlightMouth), flare = searchlightSlope*climb;
    const float a = dot(tangent,tangent)-flare*flare;
    const float b = dot(radial,tangent)-radius*flare;
    const float c = dot(radial,radial)-radius*radius;
    if (abs(a) < .000001) {
        if (b > .000001) far = min(far,-c/(2.*b));
        else if (b < -.000001) near = max(near,-c/(2.*b));
        else if (c > 0.) return float3(0.);
    } else {
        const float discriminant = b*b-a*c;
        if (discriminant > 0.) {
            const float root = -b-copysign(sqrt(discriminant),b);
            const float first = min(root/a,c/root), last = max(root/a,c/root);
            if (a > 0.) {
                near = max(near,first);
                far = min(far,last);
            } else if (near < first) far = min(far,first);
            else near = max(near,last);
        } else if (a > 0.) return float3(0.);
    }
    if (far <= near) return float3(0.);

    constexpr uint samples = 10u;
    const float step = (far-near)/float(samples);
    float light = 0.;
    for (uint i=0; i<samples; ++i) {
        const float travel = near+(float(i)+.5)*step;
        const float axial = height+climb*travel;
        const float density = (1.+1.8*exp2(-24.*axial))/(1.+18.*axial*axial);
        light += searchlightProfile(origin+ray*travel,axial,axis)*density;
    }
    const float3 tint = mix(searchlightColour,s.interiorPalette.rgb,.30*(1.-s.interiorPalette.w));
    return tint*(.16*s.searchlightAxis.w*(1.-exp2(-4.8*light*step)));
}

bool hybridWater(constant Scene& s) {
    return s.graphicsStyle == hybridGraphics || s.graphicsStyle == ultraGraphics;
}
constant float3 playerBody[4] = {
    float3(1.,.083,.021), float3(.34,.86,.024), float3(.081,.17,.99), float3(1.,.086,.14)
};
constant float3 playerRim[4] = {
    float3(1.,.64,.013), float3(.89,1.,.038), float3(.45,.10,1.), float3(1.,.53,.012)
};

constant float3 sulphur = float3(.83,1.,.033);
constant float3 ember = float3(1.,.16,.019);
constant float3 hotMagenta = float3(.98,.020,.43);

float3 paletteColour(float4 blend, constant float3* dyes) {
    return blend.x*dyes[0]+blend.y*dyes[1]+blend.z*dyes[2]+blend.w*dyes[3];
}

vertex Full fullTriangle(uint id [[vertex_id]]) {
    const float2 p = float2(float((id << 1) & 2), float(id & 2));
    return {float4(p*float2(2,-2)+float2(-1,1),0,1),p};
}

float hash(float n) { return fract(sin(n*1.2719)*43758.5453); }
float hash21(float2 p) {
    const float3 q = fract(p.xyx*float3(.1031,.1030,.0973));
    const float3 a = q+dot(q,q.yzx+33.33);
    return fract((a.x+a.y)*a.z);
}
float noise(float2 p) {
    const float2 i = floor(p);
    const float2 w = fract(p);
    const float2 s = w*w*(3-2*w);
    return mix(mix(hash21(i),hash21(i+float2(1,0)),s.x),
               mix(hash21(i+float2(0,1)),hash21(i+1),s.x),s.y);
}
float fbm(float2 p) {
    const float3 n = float3(noise(p),noise(float2(-.9*p.y+.7*p.x,.9*p.x+.7*p.y)*2.02+4.1),
                          noise(p*4.23-7.3));
    return dot(n,float3(.58,.29,.13));
}
float3 pigment(float hue) {
    const float3 spectral = saturate(abs(fract(hue+float3(0.,.667,.333))*6.-3.)-1.);
    return .012+.988*pow(spectral,float3(1.18));
}

float3 hybridPrism(float phase) {
    const float wash = .5+.5*sin(phase);
    const float heat = .5+.5*sin(phase*.77+1.62);
    return mix(mix(ember,hotMagenta,smoothstep(.26,.77,heat)),sulphur,smoothstep(.48,.88,wash));
}

float2 paintStrokes(float2 point) {
    const float2 stroke = float2(.83*point.x+.56*point.y,-.56*point.x+.83*point.y);
    const float wash = noise(point*.44);
    const float bristles = noise(stroke*float2(.67,5.9)+float2(0.,wash*.63));
    const float overpaint = noise(point*float2(3.1,.64)+4.8);
    return float2(wash,mix(bristles,overpaint,.28));
}
float3 discharge(float3 ray, float3 axis, float phase, constant Scene& s) {
    const float3 side = normalize(cross(axis,float3(.87,-.13,.51)));
    const float3 travel = cross(side,axis);
    const float2 p = float2(dot(ray,side),dot(ray,travel));
    const float t = s.celestialTime;
    const float lift = (.17+.037*s.music.x)*sin(p.x*4.5-p.y*3.4+phase+t*.068) +
                       .071*cos(p.x*9.5+p.y*2.1-phase-t*.09-s.call.w*.11);
    const float edge = dot(ray,axis)+lift;
    const float band = exp(-abs(edge)*7.2);
    const float2 local = float2(p.x*6+p.y*1.9,edge*14.)
                       + float2(phase,t*.16);
    const float texture = fbm(local+float2(.7*sin(local.y),.36*sin(local.x)));
    const float broken = sin(local.y*2.7+texture*6+sin(local.x*1.6)*1.18);
    const float broad = exp(-pow((edge+.052*sin(local.x*1.37-phase)) * 4.3,2.));
    const float rim = exp(-abs(edge+.11+.035*sin(local.x*1.21-phase))*35.);
    const float trace = pow(max(0., broken),8.);
    const float fine = trace * smoothstep(.39,.77,texture) * band;
    const float separation = smoothstep(.30,.81,texture + .10*sin(p.x*10.-t*.16+phase));
    const float3 colour = mix(s.water.xyz,s.contrast.xyz,separation*.72);
    return colour*(.097*broad+.08*band+.32*rim*texture)*(1.+.48*s.music.x)
         + s.bright.xyz*fine*(.24+.31*s.tide.w+.32*s.music.z);
}
float3 starfield(float3 ray) {
    const float2 sphere = float2(atan2(ray.x,ray.z)/tau,asin(clamp(ray.y,-1.,1.))/pi);
    const float2 cells = sphere*float2(775,395);
    const float2 id = floor(cells), f = fract(cells);
    const float a = hash21(id);
    const float width = max(fwidth(cells.x),fwidth(cells.y));
    if (a <= .97) return float3(0.);
    const float2 xy = f-(.18+.64*float2(hash21(id+27.5),hash21(id+19.2)));
    const float d = length(xy);
    const float glint = smoothstep(.97,1.,a) * exp(-d*d/(.028+width*.026));
    const float spark = smoothstep(.9988,1.,a) * exp(-d*7.)*1.9;
    const float blue = fract(a*213.3);
    return mix(float3(1.,.53,.46),float3(.38,.77,1.),blue)*(glint*.72+spark);
}

float3 exteriorStars(float3 ray, float seedOffset = 0.) {
    const float2 grid = float2(775.,395.);
    const float2 cells = float2(atan2(ray.x,ray.z)/tau,asin(clamp(ray.y,-1.,1.))/pi)*grid;
    const float2 base = floor(cells-.5);
    // Broaden each point by the pixel footprint. Include neighbouring cells so its light
    // remains continuous as the camera moves across the procedural grid.
    const float pixel = max(length(dfdx(ray)),length(dfdy(ray)))*grid.y/pi;
    const float width = .033+.36*pixel*pixel;
    float3 stars = 0.;
    for (uint i = 0; i < 4; ++i) {
        const float2 cell = base+float2(i&1u,i>>1);
        const float2 id = float2(cell.x-floor(cell.x/grid.x)*grid.x,cell.y)+seedOffset;
        const float seed = hash21(id);
        if (seed <= .97) continue;
        const float2 centre = cell+.33+.34*float2(hash21(id+27.5),hash21(id+19.2));
        const float2 offset = cells-centre;
        const float distance = dot(offset,offset);
        const float glow = exp(-distance/width)*(.033/width)*(1.-smoothstep(.24,.51,distance));
        const float intensity = .78*smoothstep(.97,1.,seed)+1.2*smoothstep(.9988,1.,seed);
        stars += mix(float3(1.,.53,.46),float3(.38,.77,1.),fract(seed*213.3))*intensity*glow;
    }
    return stars;
}

float upperWater(float height) {
    return smoothstep(-17.,19.,height);
}

float3 depthLight(float height, constant Scene& s) {
    if (s.innerOcean.z > 0.) return float3(1.);
    return mix(float3(.19,.32,.49),float3(1.05,1.19,1.23),upperWater(height));
}

float lunarCrater(float2 p, float2 centre, float radius) {
    const float d = length(p-centre)/radius;
    return .17*exp2(-65.*(d-.83)*(d-.83))-.28*(1.-smoothstep(.31,.96,d));
}

float3 lunarLight(float3 water, float3 ray, float pixel, float clarity, float4 palette) {
    if (dot(ray,moonDirection) < .94) return water;

    const float2 skyPlane = float2(dot(ray,normalize(cross(float3(0,1,0),moonDirection))),
                                  dot(ray,normalize(float3(0,1,0)-moonDirection*moonDirection.y)));
    const float2 p = skyPlane/moonRadius;
    const float r = length(p);
    const float edge = clamp(pixel/moonRadius+.095*(1.-clarity),.026,.25);
    const float3 pearl = float3(.68,.79,1.);
    const float halo = (.16*exp2(-.75*r*r)+.072*exp2(-.16*r*r))*(1.-smoothstep(4.6,6.,r));
    const float3 light = water+bubbleChroma(pearl*halo*clarity,palette);
    if (r >= 1.+edge) return light;

    const float3 normal = float3(p,sqrt(max(0.,1.-dot(p,p))));
    const float phase = smoothstep(-.33,.78,dot(normal,float3(-.49,.34,.80)));
    const float maria = fbm(p*4.7+float2(18.5,6.2));
    const float dust = fbm(p*27.+float2(maria*3.));
    const float craters = lunarCrater(p,float2(-.28,.34),.37)+
                          lunarCrater(p,float2(.38,-.22),.29)+
                          lunarCrater(p,float2(-.41,-.46),.17)+
                          lunarCrater(p,float2(.27,.45),.14);
    const float rock = .49+.39*smoothstep(.32,.76,maria)+.17*dust+craters;
    const float3 disc = mix(float3(.13,.17,.30),mix(pearl,float3(1.,.91,.73),.29),phase)*
                        (rock*(.21+1.34*phase));
    return mix(light,bubbleChroma(disc,palette),(1.-smoothstep(1.-edge,1.+edge,r))*clarity);
}
float stellarTransmission(float3 ray, constant Scene& s) {
    if (s.eclipse.w <= 0.) return 1.;
    const float3 scale = float3(1.,1.46,1.);
    const float3 sight = normalize(ray*scale);
    const float3 offset = (s.eclipse.xyz-s.eye.xyz)*scale;
    if (dot(offset,sight) <= 0.) return 1.;
    const float3 miss = cross(offset,sight)/s.eclipse.w;
    return mix(.014,1.,smoothstep(.80,1.035,dot(miss,miss)));
}

constant float ringFeatherLimit = .28;
struct RingSample { float depth, opacity; };

RingSample sampleRing(Planet planet, float3 ray, float outer, float pixel) {
    if (planet.ringOpacity <= 0.) return {};
    const float3 centre = planet.position.xyz;
    const float radius = planet.position.w;
    const float angle = planet.material.z;
    const float3 normal = normalize(float3(sin(angle)*.88,cos(angle),-.34));
    const float plane = dot(centre,normal);
    const float slope = dot(ray,normal);
    // Thin rings fade as their projected width drops below a pixel.
    const float width = abs(plane)*radius*outer;
    const float resolved = smoothstep(.45*pixel,2.2*pixel,width);
    if (resolved <= 0. || plane*slope <= 0.) return {};
    const float depth = plane/slope;
    if (abs(depth-1.) >= radius*(outer+ringFeatherLimit)) return {};
    const float band = length(ray*depth-centre)/radius;
    const float footprint = pixel*depth/(radius*max(.08,abs(slope)));
    const float feather = clamp(.56*footprint,.025,ringFeatherLimit);
    const float silhouette = smoothstep(1.20,1.24+feather,band)*
                             (1.-smoothstep(outer-feather,outer+feather,band));
    const float broad = .28*sin(band*90.)*(1.-smoothstep(.015,.039,footprint));
    const float fine = .15*sin(band*151.)*(1.-smoothstep(.007,.025,footprint));
    const float gap = exp(-abs(band-outer*.87)*55.)*(1.-smoothstep(.023,.065,footprint));
    return {depth,.80*planet.ringOpacity*resolved*silhouette*(.53+broad+fine)*(1.-.89*gap)};
}

float3 celestialSky(float3 ray, float3 sea, constant Scene& s, float4 sun, float3 sunColour,
                    constant Planet* planets, constant float4* skyPositions, float seed, bool eclipse) {
    const float pixel = s.orbitalPixel;
    const float3 star = sun.xyz;
    const float cs = dot(ray,star);
    const float R = sun.w;
    float3 result = sea;
    if (R > 0. && cs > .81) {
        const float d = length(cross(ray,star));
        const float r = d/R;
        const float ph = atan2(ray.y-star.y,ray.x-star.x);
        const float2 coronaAngle = float2(cos(ph),sin(ph));
        const float streamer = fbm(coronaAngle*6.7+seed);
        const float reach = max(0.,r-1.);
        const float flecks = fbm(coronaAngle*14.4+float2(reach*2.8,s.celestialTime*.025));
        const float fingers = pow(saturate(.5+.5*cos(ph*19.+flecks*3.4+r*.76)),5.);
        const float corona = exp(-reach*(4.6-3.1*streamer));
        result += sunColour*(.065*exp(-r*.72)+corona*(.083+.36*streamer*fingers));
        result += mix(s.contrast.xyz,sunColour,.66)*exp(-abs(r-1.)*10.)*(.10+.32*flecks);
        const float through = eclipse ? stellarTransmission(ray,s) : 1.;
        if (r < 1.01 && through > .02) {
            const float2 q = (ray.xy-star.xy)/R;
            const float twist = fbm(q*3.9+float2(seed*6.1,s.celestialTime*.031));
            const float cells = fbm(q*33.+float2(twist*8.,twist*5.4));
            const float pools = fbm(q*7.6+float2(twist*3.1,twist*4.6));
            const float granulation = pow(saturate(cells),2.8);
            const float filament = exp(-abs(pools-.36)*19.)*(.16+.61*twist);
            const float limb = sqrt(max(0.,1.-r*r));
            const float3 hot = mix(sunColour,float3(1.,.81,.42),.23+granulation*.66);
            const float3 disc = hot*(.47+1.8*pools+3.3*granulation)*(limb*.53+.47)
                                +float3(.92,.126,.03)*filament;
            result = mix(result,disc,1.-smoothstep(.975,1.01,r));
        }
        result = mix(sea,result,through*smoothstep(.81,.90,cs));
    }
    for (uint i = 0; i < 3; ++i) {
        Planet p = planets[i];
        if (skyPositions) p.position = skyPositions[i];
        if (p.position.w <= 0. || p.opacity <= 0.) continue;
        const float3 centre = p.position.xyz;
        const float r = p.position.w;
        const float centreDepth = dot(ray,centre);
        if (centreDepth <= 0.) continue;
        const float miss = sqrt(max(0.,1.-centreDepth*centreDepth));
        const float limbDistance = miss / r;
        const float outer = 1.71+.48*p.material.w;
        if (limbDistance >= (p.ringOpacity > 0. ? outer+ringFeatherLimit : 1.26)) continue;
        const float intersection = centreDepth-sqrt(max(0.,r*r-miss*miss));
        const float3 normal = (ray*intersection-centre)/r;
        const float lit = saturate(dot(normal,normalize(star-centre*.73))*.83+.20);

        const RingSample ring = sampleRing(p,ray,outer,pixel);
        const float3 ringTint = mix(p.pigment.xyz,s.bright.xyz,.48)*(.43+.43*lit);
        if (ring.depth > intersection)
            result = mix(result,ringTint,ring.opacity*p.opacity);
        if (limbDistance < 1.26) {
            const float a = atan2(normal.z,normal.x) + p.pigment.w*.31;
            const float v = asin(clamp(normal.y,-1.,1.));
            const float2 surface = float2(a,v);
            const float f = fbm(surface*7.);
            const float curl = sin(a*4.+f*2.6)*.091 + f*.21;
            const float band = sin((v+curl)*33.+sin(v*9.)*.5+.68*sin(11.*a+f*7.));
            const float ridges = fbm(surface*5.+f*1.37);
            const float rock = .30+.68*ridges-.19*exp(-abs(f-.48)*30.);
            const float sediment = saturate(.27+.31*band+.63*f);
            const float texture = mix(rock,sediment,p.material.x);
            const float weather = fbm(surface*9.+float2(p.pigment.w*.11,f*.47));
            const float clouds = smoothstep(.45,.72,weather+f*.13)*smoothstep(.23,.67,texture);
            const float3 base = mix(p.pigment.xyz * s.water.xyz,
                p.pigment.xyz*1.05+sunColour*.21,texture*.84);
            const float terminator = pow(lit,.89);
            const float3 sphere = base*(.028+terminator*1.02)
                + p.material.y*clouds*mix(s.bright.xyz,sunColour,.62)*terminator*.71;
            const float rim = exp(-abs(limbDistance-1.)*53.)*(.047+.47*lit);
            const float halo = exp(-abs(limbDistance-.995)*17.)*(.018+.12*lit);
            const float feather = clamp(.54*pixel/r,.005,.22);
            const float body = p.opacity*(1.-smoothstep(1.-feather,1.+feather,limbDistance));
            result = mix(result,sphere+s.water.xyz*.060,body);
            const float atmosphere = 1.-smoothstep(1.10,1.26,limbDistance);
            result += mix(s.bright.xyz,p.pigment.xyz,.34)*(rim+halo)*atmosphere*p.opacity;
        }
        if (ring.depth <= intersection)
            result = mix(result,ringTint,ring.opacity*p.opacity);
    }
    return result;
}

float3 celestial(float3 ray, float3 sea, constant Scene& s) {
    return celestialSky(ray,sea,s,s.sun,s.sunlight.xyz,s.planets,nullptr,s.tide.x,true);
}

float3 bellSky(float3 ray, float3 water, constant Scene& s, constant BellSystem& system) {
    const float seed = system.sunlight.w;
    const float3 dust = exteriorStars(ray,seed*197.)*mix(float3(.64,.79,1.),system.sunlight.xyz,.33);
    return celestialSky(ray,water+dust*.58,s,system.sun,system.sunlight.xyz,system.planets,system.skyPositions,seed,false);
}

float distantWaterAmount(constant Scene& s) {
    return max(max(s.innerOcean.z,s.cycle.z),1.-s.basinArrival);
}

float3 distantWaterOrigin(constant Scene& s) {
    return (s.eye.xyz-s.enclosingBell.xyz)*(18./max(1.,s.enclosingBell.w));
}

float3 suspendedLightAt(float3 ray, float3 sunAcross, float3 sunUp, float3 origin, constant Scene& s) {
    const float ahead = saturate(dot(ray,s.sun.xyz));
    const float t = s.celestialTime;
    float shafts = 0., haze = 0.;
    const float2 drift = float2(t*.14,-t*.082);
    // The samples sit in the water, so nearby light drifts past faster than distant haze.
    for (uint i = 0; i < 4; ++i) {
        const float reach = 10.+float(i*i)*7.;
        const float3 point = origin+ray*reach;
        const float2 sheet = float2(dot(point,sunAcross),dot(point,sunUp));
        const float fold = .23*sin(sheet.y*.25-sheet.x*.14+t*.08);
        const float fine = noise((sheet+float2(fold*4.7,0))*float2(.28,.085)+drift+s.tide.x*31.);
        const float mass = noise(sheet*.065-drift*.45+s.tide.x*14.);
        const float slit = smoothstep(.51,.89,fine-.50*fold);
        shafts += slit*(.19+.81*mass)*mix(1.,.64,float(i)/3.);
        haze += mass*mass*(.40+.60*fine);
    }
    const float rays = (.09+.91*pow(ahead,3.6))*shafts*.19;
    const float airlight = haze*(.018+.036*pow(ahead,4.8));
    const float3 beam = mix(s.water.xyz,s.sunlight.xyz,.28+.31*ahead);
    const float3 wash = mix(s.water.xyz,s.bright.xyz,.18);
    return beam*rays+wash*airlight;
}

float3 suspendedLight(float3 ray, float3 sunAcross, float3 sunUp, constant Scene& s) {
    // Sample each field at its own scale before blending. Interpolating the
    // coordinates sweeps through hundreds of light bands during the return.
    const float distant = distantWaterAmount(s);
    const float3 farLight = distant > 0. ?
        suspendedLightAt(ray,sunAcross,sunUp,distantWaterOrigin(s),s) : float3(0.);
    const float3 nearLight = distant < 1. ?
        suspendedLightAt(ray,sunAcross,sunUp,s.eye.xyz,s) : float3(0.);
    return mix(nearLight,farLight,distant);
}

float2 waterField(float3 ray, constant Scene& s) {
    const float t = s.celestialTime;
    const float2 sphere = float2(dot(ray,float3(.89,.12,-.39)),dot(ray,float3(-.27,.74,.61)));
    const float field = fbm(sphere*7.2+float2(s.tide.x*3.3,t*.033));
    const float undersea = fbm(sphere*17.+float2(field*3.4,s.tide.x*7.+t*.018));
    return float2(field,undersea);
}

float3 narrowsFilter(float3 ray, constant Scene& s) {
    const float3 slit = normalize(float3(-4.,-.6,178.)-s.eye.xyz+float3(.001));
    const float opening = pow(saturate(dot(ray,slit)),17.);
    return mix(float3(1.),mix(float3(.56,.15,.42),float3(.80,.61,.64),opening),
               s.habitat.y*(.43+.50*s.screen.w));
}

float4 paintedGroundAt(float3 ray, float3 origin, constant Scene& s) {
    // The large marks sit in world space, following the view through the scene.
    const float3 suspended = ray*24.+origin*.11;
    const float2 point = float2(dot(suspended,float3(.91,.13,-.41)),
                               dot(suspended,float3(-.23,.76,.61)));
    const float2 strokes = paintStrokes(point);
    const float diagonal = noise(point*float2(.36,.83)+float2(4.3,2.1));
    const float light = .22+.55*strokes.x+.23*diagonal;
    const float3 dye = s.water.xyz/max(.01,max(s.water.r,max(s.water.g,s.water.b)));
    const float3 ash = float3(.041,.027,.032);
    const float3 ground = ash+dye*(.044+.134*smoothstep(.28,.83,diagonal));
    float3 water = mix(float3(.014,.010,.016),ground,light);
    water += (strokes.y-.5)*float3(.031,.022,.023);
    if (s.habitat.x > .5) {
        const float3 opening = normalize(float3(0.,5.,266.)-s.eye.xyz+float3(.001));
        const float wash = pow(saturate(dot(ray,opening)),4.6)*s.habitat.z;
        water += wash*(.24+.76*diagonal)*mix(ember,s.bright.xyz,.74)*.055;
    }
    return float4(water,strokes.y);
}

float4 paintedGround(float3 ray, constant Scene& s) {
    const float distant = distantWaterAmount(s);
    const float4 farPaint = distant > 0. ? paintedGroundAt(ray,distantWaterOrigin(s),s) : float4(0.);
    const float4 nearPaint = distant < 1. ? paintedGroundAt(ray,s.eye.xyz,s) : float4(0.);
    return mix(nearPaint,farPaint,distant);
}

float3 paintedOcean(float3 ray, constant Scene& s) {
    const float4 ground = paintedGround(ray,s);
    const float3 water = ground.xyz+starfield(ray)*float3(.037,.048,.068);
    const float3 celestialLight = celestial(ray,water,s);
    const float3 lit = max(celestialLight-water,0.);
    const float pigmentLoad = max(0.,dot(lit,float3(.32,.50,.18))-.012);
    const float warm = smoothstep(.035,.62,lit.r-lit.b);
    const float3 mineral = mix(float3(.59,.69,.78),float3(.96,.72,.48),warm);
    const float3 chalk = mix(mineral,lit/max(.01,max(lit.r,max(lit.g,lit.b))),.47);
    return min(celestialLight,water)+chalk*(1.-exp2(-2.8*pigmentLoad))*(.68+.30*ground.w);
}

// Undo the luminous tone curve so the painted ground stays dark under the original finish.
float3 paintAsLight(float3 colour) {
    colour = max(colour,0.);
    const float peak = max(colour.r,max(colour.g,colour.b));
    const float light = pow(min(peak,.99),1./.68);
    const float a = 2.51-2.43*light;
    const float b = .03-.59*light;
    const float linearPeak = (sqrt(b*b+.56*a*light)-b)/(2.*a*.96);
    return pow(colour/max(peak,.00001),float3(1./.89))*linearPeak;
}

float3 luminousWater(float3 ray, constant Scene& s) {
    const float t = s.celestialTime;
    const float2 nd = float2(atan2(ray.x,ray.z),ray.y);
    const float2 noiseField = waterField(ray,s);
    const float field = noiseField.x, undersea = noiseField.y;
    const float3 stars = (s.innerOcean.z > 0. ? exteriorStars(ray) : starfield(ray))*(.56-.34*undersea);
    const float3 sweep = s.water.xyz * (.024+.074*field);
    float3 water = s.deep.xyz * (.84 + 1.16*undersea)+sweep;
    water += stars;
    water += discharge(ray,normalize(float3(.36,.92,.26)),s.tide.x*3.2+.81,s);
    water += discharge(ray,normalize(float3(-.65,.38,.41)),s.tide.x*7.+1.6,s)*.72;
    water += discharge(ray,normalize(float3(.55,.48,-.56)),s.tide.x*9.+3.1,s)*.69;
    const float caustic = sin(nd.x*18.+sin(nd.y*10.+t*.16)*4.+undersea*5.-t*.28-s.call.w*.13);
    const float shaft = pow(saturate(dot(ray,normalize(float3(-.38,.74,.7)))),6.);
    water += s.bright.xyz * (pow(saturate(caustic),7.)*(.10+.24*s.music.w)+.05)*shaft;
    const float tideLight = pow(saturate(caustic*.6+.4),3.);
    water += mix(s.water.xyz,s.bright.xyz,tideLight)*s.music.x*(.035+.11*tideLight)*(.2+.8*field);
    const float3 sunAcross = normalize(cross(float3(.14,1.,.25),s.sun.xyz));
    const float3 sunUp = cross(s.sun.xyz,sunAcross);
    water += suspendedLight(ray,sunAcross,sunUp,s);
    water += s.contrast.xyz * (.036+undersea*.073) *
             sin(nd.x*4.+nd.y*5.4+s.tide.x*8.+t*.22)*.52;
    const bool opening = s.habitat.x > .5;
    const float3 transmission = opening ? narrowsFilter(ray,s) : float3(1.);
    const bool hybrid = hybridWater(s);
    const float originalWaterOpacity = hybrid ? .50 : 1.;
    if (hybrid) {
        // The two water layers sit behind the same sun and planets.
        const float4 brush = paintedGround(ray,s);
        const float sweep = 5.1*dot(ray,float3(.79,.41,-.33))+.145*t+.42*brush.w;
        const float fold = 4.6*dot(ray,float3(-.22,.91,.28))-.10*t+s.tide.x*3.2;
        const float3 prism = hybridPrism(sweep+.91*sin(fold));
        const float density = max(brush.r,max(brush.g,brush.b));
        float3 painted = brush.xyz*.86+prism*(.029+.18*density+.012*s.music.x);
        if (opening) {
            const float3 dye = s.water.xyz/max(.01,max(s.water.r,max(s.water.g,s.water.b)));
            const float3 stain = density*(.17+.98*dye);
            const float3 shimmer = mix(prism,dye,.88)*(.021+.16*density+.012*s.music.x);
            painted = mix(painted,stain+shimmer,.91);
        }
        const float3 ground = paintAsLight(painted);
        water = mix(ground/transmission+stars,water,originalWaterOpacity);
    }
    water = celestial(ray,water,s)*transmission;
    if (opening) {
        const float3 basin = normalize(float3(2.,7.,268.)-s.eye.xyz+float3(.001));
        const float lantern = pow(saturate(dot(ray,basin)),3.);
        const float window = pow(saturate(dot(ray,normalize(basin+float3(.27,.16,0.)))),7.);
        const float spread = s.habitat.z*s.habitat.z*originalWaterOpacity;
        water += spread*(lantern*mix(s.water.xyz,s.contrast.xyz,field)*(.061+.142*undersea)+
                         sulphur*window*field*.037);
    }
    return water;
}

// Crossing wave fronts form a soft sheet of light with narrower caustics on its folds.
float2 refractedWater(float2 point, float time, float footprint) {
    const float swell = noise(point*.49+float2(time*.11,-time*.062));
    const float2 water = point+float2(.57*sin(point.y*.84-time*.72),.92*swell);
    const float wave = sin(water.x*1.61+water.y*.88-time)+
                       .74*sin(water.x*-.91+water.y*1.92+time*.71)+
                       .38*sin(water.x*.67-water.y*2.36-time*.59);
    const float crease = abs(wave-.22);
    const float glow = exp2(-crease*crease*2.6)*(.32+.68*swell);
    const float focus = exp2(-crease/(.076+footprint*1.5))*(1.-smoothstep(.07,.33,footprint));
    return float2(glow,focus);
}

float3 waterColumn(float3 water, float3 ray, constant Scene& s) {
    // Sample the light suspended along the view direction, without intersecting a surface.
    const float3 sample = s.eye.xyz+ray*39.;
    const float exposed = upperWater(sample.y);
    const float overhead = smoothstep(-.21,.72,ray.y);
    const float3 abyss = float3(.055,.040,.061);
    const float3 attenuation = mix(abyss,float3(1.06,1.08,1.09),exposed);
    const float4 palette = s.interiorPalette;
    const float3 colour = water*mix(float3(dot(attenuation,bubbleLuma)),attenuation,palette.w)+
                          bubbleChroma(s.deep.xyz*.18*(1.-exposed),palette);
    const float pixel = max(length(dfdx(ray)),length(dfdy(ray)));
    const float2 field = sample.xz*.128+sample.y*float2(.069,-.041);
    const float footprint = length(fwidth(field));
    const float clarity = mix(.28,.89,upperWater(s.eye.y+5.));
    if (exposed <= 0.) return lunarLight(colour,ray,pixel,clarity,palette);
    const float2 caustic = refractedWater(field,s.celestialTime*.24,footprint);
    const float3 prism = hybridPrism(field.x*.88+field.y*.53-.24*s.celestialTime+.8*caustic.x);
    const float prismAmount = s.habitat.x > .5 ? .17 : .33;
    const float3 enamel = mix(mix(s.water.xyz,s.bright.xyz,.56),prism,prismAmount);
    const float glow = exposed*(.28+.72*overhead)*(.059*caustic.x+.14*caustic.y);
    return lunarLight(colour+bubbleChroma(enamel*glow,palette),ray,pixel,clarity,palette);
}

float membraneIntersection(float3 eye, float3 ray, float3 axes) {
    const float3 p = eye/axes, d = ray/axes;
    const float a = dot(d,d), b = dot(p,d), c = dot(p,p)-1.;
    const float discriminant = b*b-a*c;
    if (discriminant < 0.) return -1.;
    const float root = sqrt(discriminant);
    const float entry = (-b-root)/a;
    const float exit = (-b+root)/a;
    return entry > 0. ? entry : exit;
}

float3 containedCentre(float3 direction, float depth) {
    return float3(direction.x*.72,.28+.48*direction.y,depth+.19*(direction.z-.8));
}

struct OrbitLayer { float3 light; float strength, depth; };

void addOrbitLayer(thread OrbitLayer* layers, thread uint& count, OrbitLayer layer) {
    if (layer.strength <= 0.) return;
    uint slot = count++;
    while (slot > 0u && layers[slot-1u].depth < layer.depth) {
        layers[slot] = layers[slot-1u];
        --slot;
    }
    layers[slot] = layer;
}

float4 containedSky(float3 eye, float3 ray, float membrane, float pixel, constant BellSystem& system,
                    float emergence = 1., float4 anchor = float4(0.), float layout = 1.) {
    if (system.sun.w <= 0.) return float4(0.);
    const float distance = anchor.w;
    const bool anchored = distance > 0.;
    const float spread = anchored ? layout : 0.;
    const float3 sun = mix(containedCentre(system.sun.xyz,-.23),anchor.xyz+system.sun.xyz*(distance*1.25),spread);
    const float3 chamber = mix(float3(0.,.36,0.),anchor.xyz+float3(0.,.21,.16),spread);
    const float middle = max(membrane,dot(chamber-eye,ray));
    const float3 local = eye+ray*middle-chamber;
    const float cloud = exp2(-11.*dot(local,local))*smoothstep(.14,.79,emergence);
    const float2 field = local.xy*10.+local.z*float2(3.1,6.8)+system.sunlight.w*28.;
    const float veil = noise(field);
    const float3 dust = mix(float3(.10,.23,.76),system.sunlight.xyz,.25)*(cloud*(.017+.10*veil*veil));
    float3 light = dust+exteriorStars(ray,system.sunlight.w*197.)*cloud*.20;
    OrbitLayer layers[7];
    uint hits = 0;
    for (uint i = 0; i < 4; ++i) {
        const bool stellar = i == 0u;
        const uint index = i-uint(!stellar);
        const Planet planet = system.planets[index];
        const float onset = .22+.13*float(i);
        const float shown = stellar ? smoothstep(0.,.30,emergence) : planet.opacity*smoothstep(onset,onset+.30,emergence);
        if (shown <= 0. || (!stellar && planet.position.w <= 0.)) continue;
        const float orbit = distance*(1.-.14*float(index));
        const float unscaled = stellar ? .090+.47*system.sun.w : .042+.54*planet.position.w;
        const float trueSize = stellar ? system.sun.w*distance*1.25 : planet.position.w*orbit;
        const float radius = mix(unscaled,trueSize,spread)*mix(.48,1.,shown);
        const float3 miniature = containedCentre(planet.position.xyz,-.09+.12*float(i));
        const float3 centre = stellar ? sun : mix(miniature,anchor.xyz+system.skyPositions[index].xyz*orbit,spread);
        const float3 offset = centre-eye;
        const float travel = dot(ray,offset);
        const float soft = clamp(travel*pixel/radius,.018,.26);
        const float outer = 1.67+.26*planet.material.w;
        const float clipWidth = clamp(radius*.20+pixel*max(travel,.01),.012,.071);
        if (travel+max(2.8,outer+.32)*radius <= membrane-clipWidth) continue;
        const float miss = length(cross(ray,offset))/radius;
        if (stellar && miss < 3.4) {
            const float clear = smoothstep(-clipWidth,clipWidth,travel-membrane);
            const float coronation = exp2(-max(0.,miss-1.)*4.7)*(1.-smoothstep(2.4,3.4,miss));
            light += system.sunlight.xyz*(.40*coronation*clear*shown);
        }
        if (!stellar && miss < 1.42) {
            const float limb = exp2(-19.*max(0.,miss-.97))*(1.-smoothstep(1.26,1.42,miss));
            const float clear = smoothstep(-clipWidth,clipWidth,travel-radius-membrane);
            light += mix(planet.pigment.xyz,float3(.31,.70,1.),.53)*(.145*limb*clear*shown);
        }
        if (!stellar && planet.ringOpacity > 0. && miss < outer+.32) {
            const float tilt = planet.material.z;
            const float3 axis = normalize(float3(sin(tilt)*.78,cos(tilt),-.46));
            const float facing = dot(ray,axis);
            if (abs(facing) > .035) {
                const float plane = dot(offset,axis)/facing;
                if (plane > 0.) {
                    const float band = length(ray*plane-offset)/radius;
                    const float edge = clamp(soft/max(.23,abs(facing)),.028,.32);
                    const float rings = smoothstep(1.16,1.19+edge,band)*(1.-smoothstep(outer-edge,outer+edge,band));
                    const float clear = smoothstep(-clipWidth,clipWidth,plane-membrane);
                    const float detail = 1.-smoothstep(.035,.18,edge);
                    const float striae = (.75+.25*cos(band*61.+planet.pigment.w*.06)*detail)*
                                         (1.-.37*exp(-abs(band-outer*.84)*19.)*detail);
                    const float opacity = planet.ringOpacity*rings*striae*clear*smoothstep(.035,.20,abs(facing))*.84*shown;
                    const float3 cast = mix(planet.pigment.xyz,system.sunlight.xyz,.52)*.87;
                    addOrbitLayer(layers,hits,{cast,opacity,plane});
                }
            }
        }
        if (miss >= 1.+soft) continue;
        const float front = travel-radius*sqrt(max(0.,1.-miss*miss));
        if (front <= membrane-clipWidth) continue;
        const float3 normal = normalize(ray*front-offset);
        const float shape = (1.-smoothstep(1.-soft,1.+soft,miss))*shown*
                            smoothstep(-clipWidth,clipWidth,front-membrane);
        const float2 address = normal.xy*9.+normal.z*3.+system.sunlight.w*11.;
        const float grit = noise(address);
        float3 radiance;
        if (stellar) {
            radiance = system.sunlight.xyz*(1.14+.87*grit+.44*max(0.,-dot(normal,ray)));
        } else {
            const float3 daylight = normalize(sun-centre);
            const float shading = smoothstep(-.23,.86,dot(normal,daylight));
            const float storm = noise(address*1.65+float2(grit*2.,planet.pigment.w*.13));
            const float stripes = .5+.5*sin(normal.y*24.+grit*3.4+.84*storm+planet.pigment.w);
            const float surface = mix(.68*grit+.32*storm,stripes,planet.material.x);
            const float3 tint = mix(planet.pigment.xyz*.75,system.sunlight.xyz,.30*surface);
            const float limb = exp(-abs(miss-.96)*14.);
            radiance = tint*(.11+.96*shading)*(.48+.91*surface)+
                       mix(planet.pigment.xyz,float3(.24,.70,1.),.46)*limb*(.085+.17*shading);
        }
        addOrbitLayer(layers,hits,{radiance,shape,front});
    }
    float coverage = .10*cloud;
    for (uint i = 0; i < hits; ++i) {
        light = mix(light,layers[i].light,layers[i].strength);
        coverage += (1.-coverage)*layers[i].strength;
    }
    return float4(light,coverage);
}

struct BubbleFilm {
    float3 colour;
    float edge, body, gloss, phase;
};

BubbleFilm bubbleFilm(float3 normal, float3 view, float3 sun, float3 dye, float time) {
    const float facing = saturate(abs(dot(normal,view)));
    const float edge = pow(1.-facing,2.45);
    const float sheet = dot(normal,float3(.48,.86,-.27));
    const float2 surface = normal.xy*2.7+normal.z*float2(1.7,-1.4);
    const float warp = noise(surface+float2(.058*time,-.041*time))-.5;
    const float phase = 4.4*facing+3.9*sheet+.92*sin(sheet*3.8+time*.38)+1.9*warp;
    const float3 spectrum = hybridPrism(phase);
    const float3 reflected = reflect(-view,dot(normal,view) >= 0. ? normal : -normal);
    const float sunward = saturate(dot(reflected,sun));
    const float gloss = .84*pow(sunward,62.)+.26*pow(sunward,12.);
    const float sheen = smoothstep(.18,.80,.5+.5*sin(phase*.86-.42));
    const float etch = smoothstep(.66,.96,.5+.5*sin(phase*1.41+.26));
    const float3 colour = mix(dye,spectrum,.08+(.21+.16*edge)*etch);
    return {colour,edge,sheen,gloss,phase};
}

struct FlightBody { float4 position, colour, surface, axis; WorldAppearance appearance; };
struct FlightScene {
    float4 eye, right, up, forward;
    float4 ship, shipRight, shipUp, shipForward;
    float4 cabinRight, cabinUp, cabinForward;
    float4 water, accent, screen, navigation;
    float4 cabinOffset, controls, optics, drive, stellar, stellarImage, atmosphere;
    float4 cloudShell, cloudOptics, cloudMotion, cloudProjection;
    float cloudDeckPhases[16];
    float4 terrainView, terrainEye, terrainEyeResidual;
    FlightBody bodies[13];
};

float4 ziksaInterior(float3 eye, float3 ray, float membrane, float pixel,
                     constant FlightScene& f, bool showShip);

float3 enclosingWater(float3 ray, float3 water, constant Scene& s, constant BellSystem& system,
                      constant FlightScene& flight, device const SystemBubble& catalogue) {
    const float3 eye = (s.eye.xyz-s.enclosingBell.xyz)/s.enclosingBell.w;
    const float3 axes = s.enclosingShape.xyz;
    const float reach = membraneIntersection(eye,ray,axes);
    if (reach <= 0.) return water;
    const float shown = s.cycle.y > 0. ? s.enclosingShape.w : 1.;
    const float3 localRay = normalize(ray/axes);
    const float4 pocket = catalogueInterior(catalogue,eye/axes,localRay,0.,s.orbitalPixel,s.celestialTime);
    const float3 surface = eye+ray*reach;
    const float3 normal = normalize(surface/(axes*axes));
    const float facing = saturate(abs(dot(normal,ray)));
    const float space = 1.-s.enclosingSky;
    const float3 dye = mix(mix(s.water.xyz,s.bright.xyz,.34),float3(.76,.036,.23),space*.88);
    const BubbleFilm film = bubbleFilm(normal,-ray,s.sun.xyz,dye,s.celestialTime);
    const float thickness = .017+.035*film.body;
    const float opacity = thickness+film.edge*mix(.088,.44,space);
    const float fog = s.graphicsStyle == paintedGraphics ? .64 : 1.;
    const float3 soft = film.colour*(.014+.041*film.body+.092*film.edge);
    const float3 rim = film.colour*(.073*film.body+.76*film.edge);
    const float3 shine = mix(film.colour,s.sunlight.xyz,.66)*film.gloss*.60;
    float3 shellLight = (mix(soft,rim,space)+shine)*fog;
    if (s.cycle.y > 0.) {
        const float progress = s.cycle.y;
        const float pulsePhase = fract((progress-.397)*12.987);
        const float signal = smoothstep(.395,.426,progress)*(1.-smoothstep(.611,.686,progress));
        const float compression = exp2(-13.*powr(abs(pulsePhase-.29),2.));
        const float crest = surface.y-mix(-.78,.95,pulsePhase)+.12*cos(film.phase);
        const float sweep = exp2(-27.*crest*crest)*sin(pi*pulsePhase);
        const float3 flash = mix(sulphur,ember,film.body);
        shellLight += signal*(flash*(.33*sweep+.55*film.edge*compression)+pocket.rgb*.17*compression);
        const float3 inlet = (s.returnPassage.xyz-s.enclosingBell.xyz)/s.enclosingBell.w;
        const float3 offset = surface-inlet;
        const float radial = length(cross(offset,s.passageFlow.xyz));
        const float gathered = s.returnPassage.w*(1.-smoothstep(.95,.982,progress))*exp2(-10.*dot(offset,offset));
        const float inletGlow = exp2(-360.*(radial-.125)*(radial-.125));
        shellLight += gathered*inletGlow*mix(hotMagenta,flash,.62)*.54;
    }
    const float pixel = max(length(dfdx(ray)),length(dfdy(ray)));
    const float silhouette = smoothstep(0.,max(.074,sqrt(3.6*reach*pixel)),facing);
    const float coverage = mix(1.,silhouette,space)*shown;
    const float growth = s.cycle.y > 0. ? smoothstep(.71,.92,s.cycle.y) : 1.;
    const float4 palette = mix(s.birthPalette,s.enclosingPalette,growth);
    const float3 membrane = water*(1.-fog*opacity)+bubbleChroma(shellLight,palette);
    const float3 orbit = bubbleChroma(pocket.rgb,s.enclosingPalette);
    float3 body = mix(membrane,orbit,.91*pocket.w)+orbit*.19;
    if (s.cycle.y > 0. && s.cycle.y < .92) {
        const float entry = space > .5 ? reach*length(ray/axes) : 0.;
        const float4 ziksa = ziksaInterior(eye/axes,localRay,entry,s.orbitalPixel,flight,true);
        const float3 chamber = membrane*(1.-ziksa.w)+bubbleChroma(ziksa.rgb,s.birthPalette);
        body = mix(chamber,body,growth);
    }
    return mix(water,body,coverage);
}

float3 interiorWater(float3 ray, constant Scene& s, constant BellSystem* systems) {
    const float time = s.screen.y;
    const float stage = max(0.,s.innerOcean.x-1.);
    const uint from = min(uint(stage),bellPassageCount-1u);
    const uint to = min(from+1u,bellPassageCount-1u);
    const float3 origin = mix(s.passages[from].xyz,s.passages[to].xyz,smoothstep(0.,1.,fract(stage)));
    const float3 camera = (s.eye.xyz-origin)*(1.+.47*stage);
    const float3 eye = camera*(82./sqrt(82.*82.+dot(camera,camera)));
    const float aim = dot(eye,ray);
    const float radius = dot(eye,eye);
    // The light is suspended on two curved layers, so it moves at different depths as you swim.
    const float3 near = eye+ray*(-aim+sqrt(max(0.,aim*aim-radius+118.*118.)));
    const float3 far = eye+ray*(-aim+sqrt(max(0.,aim*aim-radius+246.*246.)));
    const float2 folds = float2(near.x-.19*near.z,near.y+.26*near.z)*.096;
    const float2 canopy = float2(far.x+.23*far.z,far.y-.15*far.z)*.048;
    const float haze = fbm(canopy*.32+float2(.020*time,-.014*time));
    const float2 veins = refractedWater(canopy+float2(1.7*haze,0.),time*.16,length(fwidth(canopy)));
    const float2 gauze = refractedWater(folds,time*.22,length(fwidth(folds)));
    const float crest = far.y/246.+.19*sin(far.x*.018-haze-time*.076)+.11*haze;
    const float roof = exp2(-12.*(crest-.18)*(crest-.18));
    const float veils = smoothstep(.28,.8,haze)*roof;
    const float ringed = 1.-smoothstep(.02,.94,abs(stage-1.));
    const float innermost = smoothstep(float(bellPassageCount)-2.05,float(bellPassageCount)-1.,stage);
    const float3 direction = normalize(mix(float3(-.39,.57,1.),systems[2].skyPositions[0].xyz,ringed*.9));
    const float lightwell = pow(saturate(dot(ray,direction)),mix(5.,11.,ringed));
    const float3 enamel = s.water.xyz*1.43;
    const float3 lumen = s.bright.xyz;
    const float3 orchid = mix(s.contrast.xyz,enamel,.37+.35*haze);
    const float3 beams = mix(enamel,lumen,.33+.58*lightwell);
    const float veilLight = 1.-.58*ringed-.65*innermost;
    const float3 scattered = enamel*(.024+.074*haze)*(.43+.57*roof);
    return s.deep.xyz*(.94+.73*haze)+scattered+
           (orchid*(.019+.15*veils)+enamel*gauze.x*roof*.11+
            beams*(.13*lightwell+.40*veins.x*veils+.25*gauze.y*veils)+
            lumen*veins.y*veils*(.23+.52*lightwell+.26*s.music.w))*veilLight;
}

float3 whirlpoolPlume(float3 ray, float3 origin, float time, float breath, float approach) {
    // Intersect the suspended column before sampling its rising filaments.
    const float height = origin.y, angle = ray.y;
    const float2 side = origin.xz, stepAcross = ray.xz;
    const float a = max(1.e-6,dot(stepAcross,stepAcross));
    const float b = dot(side,stepAcross), c = dot(side,side)-3.60*3.60;
    const float discriminant = b*b-a*c;
    if (discriminant <= 0.) return float3(0.);
    const float span = sqrt(discriminant);
    float entry = max(0.,(-b-span)/a), exit = (-b+span)/a;
    const float topLevel = mix(26.,94.,approach);
    if (abs(angle) > .001) {
        const float bottom = (-.85-height)/angle, top = (topLevel-height)/angle;
        entry = max(entry,min(bottom,top));
        exit = min(exit,max(bottom,top));
    } else if (height < -.85 || height > topLevel) {
        return float3(0.);
    }
    if (exit <= entry) return float3(0.);
    const float3 waist = origin+ray*clamp(-b/a,entry,exit);
    const float r2 = dot(waist.xz,waist.xz);
    const float core = exp2(-r2/mix(.080,.25,approach));
    const float sheath = exp2(-r2/mix(.46,1.26,approach));
    const float lighthouse = smoothstep(-.26,1.35,waist.y)*(1.-smoothstep(topLevel*.55,topLevel,waist.y));
    const float plumeGain = .52+1.68*approach;
    const float reach = min(1.,(exit-entry)*.48);
    const float3 ivory = float3(1.,.98,.75);
    const float3 shaft = (ivory*core*(1.38+.26*breath)+sulphur*.33*sheath)*lighthouse*reach*plumeGain;
    const float step = (exit-entry)/8.;
    float3 light = 0.;
    for (uint i=0; i<8; ++i) {
        const float3 point = origin+ray*(entry+(float(i)+.5)*step);
        const float level = point.y;
        const float2 plane = point.xz;
        const float radius = length(plane);
        const float spin = atan2(plane.y,plane.x+1e-6);
        const float rise = smoothstep(-.85,.35,level)*(1.-smoothstep(topLevel*.49,topLevel,level));
        const float grain = spin+.022*level+.19*sin(.053*level-.34*time);
        const float drift = noise(plane*.64+float2(level*.097,time*.21));
        const float flare = .5+.5*sin(level*.48-time*.64);
        const float width = .72+.82*smoothstep(1.,topLevel*.58,level);
        const float crest = radius-width*(.76+.082*sin(3.*grain)+.068*drift);
        const float shell = exp2(-8.1*crest*crest);
        const float strands = shell*smoothstep(.14,.94,cos(3.*grain+radius*.21))*(.38+.62*flare);
        const float lightwell = exp2(-2.45*radius*radius/(width*width));
        const float mist = exp2(-.54*radius*radius/(width*width))*drift;
        const float3 gold = float3(1.,.46,.013);
        const float3 prism = mix(ember,sulphur,smoothstep(.26,.83,drift));
        light += rise*(prism*(.071*mist+.46*strands)+
                       gold*(.080*lightwell+.35*strands)*(1.-.80*smoothstep(4.,24.,level)));
    }
    return shaft+light*min(step,1.28)*(.68+.50*approach+.19*breath);
}

float3 whirlpoolRim(float3 ray, float3 origin, float radius, float time, float charge) {
    const float3 normal = normalize(float3(.075,.45,-.89));
    const float facing = dot(ray,normal);
    if (abs(facing) < .035) return float3(0.);
    const float travel = -dot(origin,normal)/facing;
    if (travel < .035) return float3(0.);
    const float3 point = origin+ray*travel;
    const float3 side = normalize(cross(float3(0.,1.,0.),normal));
    const float angle = atan2(dot(point,cross(normal,side)),dot(point,side)+1e-6);
    const float rim = length(point)/radius-1.;
    const float curl = .065*sin(5.*angle-time*1.14)+.026*sin(9.*angle+time*.63);
    const float band = rim-curl;
    const float foil = exp2(-13.*abs(band));
    const float braid = exp2(-29.*abs(band+.135+.046*sin(4.*angle+time*.81)));
    const float sparks = pow(max(0.,cos(12.*angle-2.1*time)),5.);
    const float3 pearl = float3(1.,.94,.52);
    const float3 dye = mix(sulphur,pearl,.24+.45*sparks+.23*charge);
    return smoothstep(.035,.32,abs(facing))*smoothstep(.035,.31,travel)*
          (dye*(foil*(.39+.69*sparks+.75*charge)+.66*braid)+sulphur*.11*exp2(-8.*abs(band)));
}

float3 whirlpoolLight(float3 ray, constant Scene& s) {
    const float eyeRadius = s.whirlpool.w;
    if (eyeRadius <= 0.) return float3(0.);
    const float3 origin = (s.eye.xyz-s.whirlpool.xyz)/eyeRadius;
    const float distance = eyeRadius*length(origin);
    const float depth = smoothstep(1.62,2.19,s.innerOcean.x);
    const float presence = depth*(1.-smoothstep(151.,215.,distance))*
                           (1.-smoothstep(.01,.16,s.cycle.y));
    if (presence <= 0.) return float3(0.);
    const float time = s.screen.y;
    const float breath = .5-.5*cos(time*.72);
    const float charge = s.cycle.x;
    const float3 acid = mix(sulphur,float3(.15,1.,.45),.29);
    const float3 gold = float3(1.,.55,.019);
    const float3 core = mix(float3(1.,.82,.22),float3(1.,.99,.83),charge);
    const float nearby = 1.-smoothstep(6.,24.,distance);
    const float3 column = whirlpoolPlume(ray,origin,time,breath,s.whirlpoolApproach);
    const float closest = -dot(ray,origin);
    if (closest <= 0.) return column*presence;
    const float3 miss = origin+ray*closest;
    const float r2 = dot(miss,miss);
    const float impact = sqrt(r2);
    const float spread = mix(4.72,8.6,smoothstep(9.,83.,distance));
    if (impact >= spread) return column*presence;
    const float edge = 1.-smoothstep(spread*.66,spread,impact);
    const float lamp = exp2(-r2*.63);
    const float beam = exp2(-r2*4.2);
    const float3 beacon = edge*(ember*.15*exp2(-r2*.19)*(1.-.93*nearby)+
                                gold*lamp*(.20+.14*breath)*(1.-.83*nearby)+
                                core*beam*(1.27+.37*breath+.60*charge)*(1.-.43*nearby));

    float3 funnel = 0.;
    if (impact < 4.72) {
        const float range = sqrt(4.72*4.72-r2);
        const float entry = max(0.,closest-range), exit = closest+range;
        const float step = (exit-entry)/8.;
        for (uint i=0; i<8; ++i) {
            const float3 local = origin+ray*(entry+(float(i)+.5)*step);
            const float radius = length(local.xz);
            const float angle = atan2(local.z,local.x+1e-6);
            const float surface = local.y-.126*radius*radius+.12;
            const float wave = cos(3.*angle+radius*4.1+time*2.08+local.y*.85);
            const float lip = (1.-smoothstep(3.88,4.55,radius))*smoothstep(.38,.91,radius);
            const float sheet = exp2(-27.*surface*surface)*lip;
            const float crest = smoothstep(.24,.92,wave)*sheet;
            const float fleck = exp2(-54.*surface*surface)*smoothstep(.87,.999,wave)*lip;
            funnel += (mix(ember,gold,smoothstep(.78,3.4,radius))*(.053*sheet+.42*crest)+
                       acid*(crest*.37+fleck*.58))*(.81+.23*breath);
        }
        funnel *= min(step,1.22)*(1.-.32*nearby);
    }
    // The inner shell sits on the physical eye. Light gathers there while the swimmer stays in it.
    const float rim = impact-1.;
    const float border = exp2(-68.*rim*rim);
    const float close = 1.-smoothstep(6.,32.,distance);
    const float front = smoothstep(.025,.24,closest);
    const float shoulder = impact-mix(2.05,1.07,charge);
    const float fill = exp2(-27.*shoulder*shoulder)*(charge*.9+.06*breath);
    const float3 outline = (mix(acid,core,.20+.60*charge)*border*(.18+.33*charge)+core*fill*.62)*
                            close*front;
    const float3 lip = whirlpoolRim(ray,origin,mix(2.10,1.36,charge),time,charge)*
                       mix(.73,1.10,nearby);
    return (column+beacon+funnel+outline+lip)*presence;
}

float3 emissiveLayerColour(float3 tint) {
    return tint/max(.01,max(tint.r,max(tint.g,tint.b)));
}

float3 membranePassage(float3 ray, uint gate, constant Scene& s, float4 palette, bool destination = false) {
    const float4 passage = s.passages[gate];
    if (passage.w <= 0. || abs(ray.z) < .001) return float3(0.);
    const bool open = s.openPassage == gate+1u;
    const float travel = (passage.z-s.eye.z)/ray.z;
    const float range = length(s.eye.xyz-passage.xyz);
    const float nearby = open ? 1.-smoothstep(54.,178.,range) : 1.-smoothstep(47.,125.,range);
    if (travel <= 0. || nearby <= 0.) return float3(0.);
    const float3 point = s.eye.xyz+ray*travel-passage.xyz;
    const float2 plane = point.xy*float2(1.,1.13)/passage.w;
    const float t = s.screen.y;
    const float radius = length(plane);
    const float footprint = length(fwidth(plane))*8.;
    // The broadest light term is already below 5e-8 beyond this radius.
    if (radius >= 2.3) return float3(0.);
    const float detail = noise(plane*3.+float2(.038*t,-.016*t));
    const float2 veils = refractedWater(plane*8.,t*.28,footprint);
    const float well = exp2(-radius*radius*4.5);
    if (open) {
        const float edge = radius-.97-.065*(detail-.5)-.027*sin(plane.x*8.+plane.y*4.-t*.44);
        const float band = exp2(-245.*edge*edge);
        const float halo = exp2(-17.*edge*edge);
        const float spill = exp2(-4.5*edge*edge);
        const float emission = band*(1.45+.67*veils.x)+.40*halo+.13*spill+.045*well;
        const float breath = .93+.07*sin(t*1.1);
        const float presence = nearby*smoothstep(.24,4.,travel)*exp(-travel*.0035);
        return emissiveLayerColour(palette.rgb)*(emission*breath*presence);
    }
    const float shoulder = radius-.84-.12*detail-.047*sin(plane.x*8.+plane.y*4.-t*.44);
    const float rim = exp2(-322.*shoulder*shoulder);
    const float glow = exp2(-36.*shoulder*shoulder);
    const float presence = nearby*smoothstep(.24,4.,travel)*exp(-travel*.008)*
                           (s.lockedPassage == gate+1u ? .24 : 1.);
    const float3 light = s.passageColours[gate].xyz;
    const float3 spark = mix(light,destination ? float3(1.,.46,.11) : float3(1.,.93,.80),
                             .63*smoothstep(.33,.76,detail));
    if (destination) {
        const float bone = exp2(-82.*shoulder*shoulder);
        return bubbleChroma((light*(.21*glow+.24*well*veils.x)+spark*rim*(.38+1.27*veils.x)+
                    mix(light,float3(1.,.88,.67),.45)*bone*(.35+.41*veils.y))*presence,palette);
    }
    return bubbleChroma((light*(.16*glow+well*(.12+.39*veils.x+.20*veils.y))+
                        spark*rim*(.08+.51*veils.x))*presence,palette);
}

float3 openingWaveLight(float3 ray, constant Scene& s) {
    if (s.basinWave.w <= 0. || abs(ray.z) < .025) return float3(0.);
    const float travel = (s.basinWave.z-s.eye.z)/ray.z;
    if (travel <= .3 || travel >= 142.) return float3(0.);
    const float2 offset = (s.eye.xyz+ray*travel-s.basinWave.xyz).xy;
    const float span = (1.-smoothstep(9.,28.,abs(offset.x)))*
                       (1.-smoothstep(4.,14.,abs(offset.y)));
    if (span <= 0.) return float3(0.);
    const float t = s.screen.y, x = offset.x;
    const float ripple = offset.y-.92*sin(.26*x-.77*t)-.045*x*x;
    const float fold = offset.y+3.3+.82*sin(.21*x+.93*t)+.024*x*x;
    const float2 silk = refractedWater(offset*float2(.72,1.7),t*.42,length(fwidth(offset)));
    const float crest = exp2(-2.9*ripple*ripple)*(.46+.54*silk.x);
    const float fringe = exp2(-2.3*fold*fold)*(.22+.58*silk.x+.49*silk.y);
    const float halo = exp2(-.41*ripple*ripple);
    const float presence = span*s.basinWave.w*smoothstep(.3,4.,travel)*(1.-smoothstep(85.,142.,travel));
    const float3 amber = float3(1.,.49,.085);
    const float3 opal = mix(float3(.51,.18,1.),float3(1.,.88,.55),silk.x);
    return (amber*(crest*.89+halo*.12)+opal*fringe*.53)*presence;
}

float3 whirlpoolSystem(float3 water, float3 ray, constant Scene& s, device const SystemBubble* catalogues) {
    const float shown = smoothstep(.025,.80,s.innerOcean.w)*(1.-smoothstep(.08,.30,s.cycle.y));
    if (s.playerSystem <= 0. || s.whirlpool.w <= 0. || shown <= 0.) return water;
    const float3 origin = s.whirlpool.xyz+float3(.78,1.25,1.78)*s.whirlpool.w;
    const float3 eye = (s.eye.xyz-origin)/(s.whirlpool.w*4.6);
    if (dot(eye,ray) >= 0. || length(cross(eye,ray)) > 1.12) return water;
    const float4 orbit = catalogueInterior(catalogues[uint(s.playerSystem)-1u],eye,ray,0.,s.orbitalPixel,s.celestialTime);
    const float3 light = bubbleChroma(orbit.rgb,s.birthPalette);
    return mix(water,light,.92*orbit.w*shown)+light*.14*shown;
}

float4 gateInterior(float3 ray, constant Scene& s, Bubble gate, device const SystemBubble& catalogue);

float3 oceanBeforeTransformation(float3 ray, float2 q, constant Scene& s, constant BellSystem* systems,
                                 constant FlightScene& flight, device const SystemBubble* catalogues,
                                 constant Bubble* gates) {
    const bool paintedWorld = s.graphicsStyle == paintedGraphics;
    const float inside = smoothstep(0.,1.,s.skyDepth);
    const float3 base = inside < 1. ? (paintedWorld ? paintedOcean(ray,s) : luminousWater(ray,s)) : float3(0.);
    float3 water = bubbleChroma(base,s.enclosingBell.w > 0. ? s.enclosingPalette : s.interiorPalette);
    // Draw the membrane over the complete sky so the light of every star, planet and ring passes through it.
    if (inside < 1. && s.enclosingBell.w > 0.) water = enclosingWater(ray,water,s,systems[0],flight,catalogues[0]);
    if (inside > 0.) {
        const float stage = max(1.,s.skyDepth);
        const uint from = uint(stage);
        const float transition = smoothstep(0.,1.,fract(stage));
        const float3 inner = bubbleChroma(interiorWater(ray,s,systems),s.interiorPalette);
        const float4 pocket = gateInterior(ray,s,gates[from-1u],catalogues[from]);
        float3 local = inner*(1.-pocket.a)+bubbleChroma(pocket.rgb,gates[from-1u].palette);
        if (from < bellPassageCount && transition > 0.) {
            const float4 next = gateInterior(ray,s,gates[from],catalogues[from+1u]);
            local = mix(local,inner*(1.-next.a)+bubbleChroma(next.rgb,gates[from].palette),transition);
        }
        water = mix(water,local,inside);
    }
    for (uint i=0; s.habitat.x > .5 && i+1u < bellPassageCount; ++i) {
        const float distance = float(i)-s.innerOcean.x;
        const float shown = (1.-smoothstep(.19,1.,distance))*smoothstep(-1.9,-1.12,distance);
        if (shown > 0.) water += membranePassage(ray,i,s,gates[i].palette)*shown;
    }
    const float finalOpening = smoothstep(3.0,3.82,s.innerOcean.x)*(1.-smoothstep(4.62,5.,s.innerOcean.x));
    if (finalOpening > 0. && s.whirlpool.w > 0.)
        water += membranePassage(ray,bellPassageCount-1u,s,gates[bellPassageCount-1u].palette,true)*finalOpening;
    float3 scatter = 0.;
    if (s.innerOcean.y > 0.) {
        const float ripple = .5+.5*sin(length(q)*12.-s.screen.y*.72);
        scatter += mix(s.bright.xyz,s.contrast.xyz,ripple)*s.innerOcean.y*(.055+.045*ripple);
    }
    const float age = s.screen.z;
    if (age < 5.3 && s.pulseAxis.w <= 0.) {
        const float3 off = s.player.xyz - s.eye.xyz;
        const float radius = age*s.call.z;
        const float front = dot(ray,off);
        const float impact = sqrt(max(0.,dot(off,off)-front*front));
        const float edge = impact-radius;
        const float shell = exp(-abs(edge)*mix(2.1,1.28,s.call.y))+
                            s.call.y*.35*exp(-abs(edge+1.3)*1.4)*smoothstep(0.,.5,age);
        const float3 colour = paintedWorld ? mix(float3(.60,.76,.84),float3(.89,.39,.31),s.call.y) :
                              mix(s.bright.xyz,s.contrast.xyz,mix(.16,.66,s.call.y));
        scatter += colour*shell*smoothstep(0.,5.,front)*exp(-age*mix(.83,.59,s.call.y))*.35*
                   (1.-smoothstep(4.,5.3,age));
    }
    if (s.cycle.w > .22 && s.cycle.w < .44) {
        const float3 offset = s.player.xyz-s.eye.xyz;
        const float front = dot(ray,offset);
        const float radius = mix(.8,23.,1.-smoothstep(.22,.44,s.cycle.w));
        const float shell = length(cross(ray,offset))-radius;
        const float strength = smoothstep(.22,.31,s.cycle.w)*(1.-smoothstep(.37,.44,s.cycle.w));
        const float scattered = exp2(-.95*abs(shell))+.30*exp2(-.38*abs(shell+1.82));
        scatter += mix(s.bright.xyz,float3(.20,.60,1.),.46)*scattered*strength*.34*smoothstep(0.,9.,front);
    }
    water += bubbleChroma(scatter,s.interiorPalette);
    if (s.innerOcean.z == 0. && s.basinArrival > 0.)
        water = mix(water,waterColumn(water,ray,s),s.basinArrival);
    water += bubbleChroma(openingWaveLight(ray,s)+whirlpoolLight(ray,s),s.interiorPalette);
    return whirlpoolSystem(water,ray,s,catalogues);
}

float3 contractionWakes(float3 ray, constant Scene& s) {
    const float progress = s.cycle.y;
    if (progress <= .41 || progress >= .965) return float3(0.);
    const float3 origin = (s.eye.xyz-s.enclosingBell.xyz)/s.enclosingBell.w;
    float3 water = 0.;
    for (uint i=0; i<3; ++i) {
        const float layer = float(i);
        const float age = (progress-.41-.077*layer)/.43;
        const float strength = smoothstep(0.,.17,age)*(1.-smoothstep(.60,1.,age));
        if (strength <= 0.) continue;
        const float3 axis = normalize(float3(.085-.09*layer,1.,.10+.057*layer));
        const float facing = dot(ray,axis);
        if (abs(facing) <= .045) continue;
        const float plane = -.15-.12*layer-.56*age;
        const float travel = (plane-dot(origin,axis))/facing;
        if (travel <= 0.) continue;
        const float3 p = origin+ray*travel-axis*plane;
        const float distance = length(p);
        const float reach = .79+3.4*age;
        const float edge = distance-reach;
        if (abs(edge) > .77) continue;
        const float angle = atan2(p.z,p.x);
        const float t = s.screen.y;
        const float eddies = noise(p.xz*5.1+float2(t*.15,-t*.11)+layer*11.);
        const float twist = .5+.5*sin(5.*angle+12.*edge-1.6*t+layer);
        const float crest = edge+.087*sin(9.*angle-1.42*t)+.050*sin(14.*angle+layer);
        const float resolved = clamp(travel*.0038,.018,.081);
        const float filament = exp2(-abs(crest)/resolved)+.72*exp2(-abs(crest+.116+.053*twist)/(1.24*resolved));
        const float foam = exp2(-17.*(edge+.14)*(edge+.14))*smoothstep(.35,.87,eddies);
        const float2 cells = float2(angle*43.+layer*5.+1.64*eddies,distance*37.-age*11.+2.79*eddies);
        const float seed = hash21(floor(cells));
        const float2 grain = fract(cells)-float2(.22+.55*seed,.25+.49*hash(seed*235.));
        const float plankton = exp2(-58.*dot(grain,grain*float2(1.,.37)))*
            smoothstep(.57,.96,seed)*exp2(-17.*(edge+.30)*(edge+.30))*(1.-smoothstep(6.,16.,travel));
        const float3 gold = float3(1.,.47,.12);
        const float3 enamel = mix(mix(float3(.095,.46,1.),float3(.73,.095,.73),twist),gold,
                                  smoothstep(.40,.81,eddies));
        water += strength*smoothstep(.045,.29,abs(facing))*
            (enamel*(.52*filament+.51*foam)+mix(gold,float3(.48,.99,1.),seed)*plankton*.90);
    }
    return water;
}

float3 waterThroughInlet(float3 water, float3 ray, constant Scene& s) {
    const float opening = s.returnPassage.w;
    if (opening <= 0.) return water;
    const float3 axis = s.passageFlow.xyz;
    const float bearing = dot(ray,axis);
    if (bearing <= .1) return water;
    const float3 origin = (s.eye.xyz-s.returnPassage.xyz)/s.enclosingBell.w;
    const float axial = dot(origin,axis);
    const float near = max(0.,(-.145-axial)/bearing);
    const float far = (.46-axial)/bearing;
    if (far <= near) return water;
    const float closest = clamp(-dot(origin,ray),near,far);
    if (dot(origin+ray*closest,origin+ray*closest) > .57*.57) return water;

    const float3 right = normalize(cross(float3(0.,1.,0.),axis));
    const float3 up = cross(axis,right);
    const float step = (far-near)/8.;
    const float time = s.passageFlow.w;
    float3 light = 0.;
    float transmittance = 1.;
    for (uint i=0; i<8; ++i) {
        const float3 p = origin+ray*(near+step*(float(i)+.5));
        const float z = dot(p,axis);
        const float2 crossSection = float2(dot(p,right),dot(p,up));
        const float radius = length(crossSection);
        const float angle = atan2(crossSection.y,crossSection.x+1e-6);
        const float outsideCore = smoothstep(.021,.115,radius);
        const float eddy = noise(crossSection*21.+float2(z*9.-time*.61,z*14.+time*.40));
        const float coarse = noise(crossSection*7.1+float2(z*11.+time*.24,z*7.2-time*.38));
        const float rip = sin(7.*angle+18.*radius-14.*z-1.30*time)*outsideCore;
        const float span = .101+.36*smoothstep(-.08,.49,z);
        const float margin = span*(1.+.14*rip)-radius;
        const float tissue = exp2(-720.*margin*margin)*(.48+.52*rip*rip);
        const float veil = smoothstep(-.035,.07,margin)*(1.-smoothstep(.10,.45,z))*smoothstep(-.14,-.045,z);
        const float twist = 4.*angle+38.*z-23.*radius-3.1*time+1.92*coarse;
        const float stream = exp2(-8.8*abs(sin(twist)))*outsideCore*smoothstep(-.115,-.030,margin);
        const float flecks = smoothstep(.65,.92,eddy)*smoothstep(.34,.70,coarse)*veil;
        const float ripple = 5.*angle+z*55.-radius*19.+time*2.2+coarse*3.1;
        const float threads = exp2(-12.4*abs(sin(ripple)))*outsideCore*
                              smoothstep(-.055,.027,margin)*(1.-smoothstep(.18,.40,z));
        const float density = opening*(veil*(.19+.35*eddy+.15*coarse)+.52*tissue+.24*stream)*
                              (1.-smoothstep(.27,.46,z))*smoothstep(-.145,-.080,z);
        const float coverage = 1.-exp2(-density*step*22.);
        const float3 indigo = float3(.052,.12,.34);
        const float3 turquoise = float3(.065,.60,.89);
        const float3 pearl = mix(float3(.72,.093,.91),float3(1.,.56,.20),smoothstep(-.55,.92,rip));
        const float3 suspended = mix(indigo,turquoise,smoothstep(.17,.87,coarse))*(.41+.64*eddy);
        const float3 braid = mix(float3(.27,.43,1.),float3(1.,.59,.22),smoothstep(.29,.74,eddy));
        light += (suspended+pearl*(.45*tissue+.61*stream)+turquoise*flecks*2.3+braid*threads*.97)*
                 (transmittance*coverage);
        transmittance *= 1.-coverage;
    }
    return water*transmittance+bubbleChroma(light,s.enclosingPalette);
}

fragment half4 oceanLight(Full in [[stage_in]], constant Scene& s [[buffer(0)]],
                          constant BellSystem* systems [[buffer(1)]],
                          constant FlightScene& flight [[buffer(2)]],
                          device const SystemBubble* catalogues [[buffer(5)]],
                          constant Bubble* gates [[buffer(6)]]) {
    const float2 q = (in.uv*2.-1.)*float2(s.screen.x,-1.);
    const float3 ray = normalize(s.forward.xyz+(s.right.xyz*q.x+s.up.xyz*q.y)/focal);
    const float docking = smoothstep(.86,.982,s.cycle.y);
    float3 water = s.cycle.z < 1. ? oceanBeforeTransformation(ray,q,s,systems,flight,catalogues,gates) : float3(0.);
    if (s.cycle.z > 0.) {
        const float focus = smoothstep(.24,.54,s.cycle.y);
        float3 outside = luminousWater(ray,s)*(1.-.44*focus*(1.-docking))+contractionWakes(ray,s);
        if (docking > 0. && s.graphicsStyle == paintedGraphics)
            outside = mix(outside,paintedOcean(ray,s),docking);
        water = mix(water,bubbleChroma(outside,s.birthPalette),s.cycle.z);
    }
    if (s.cycle.y > 0. && s.enclosingShape.w > 0.)
        water = enclosingWater(ray,water,s,systems[0],flight,catalogues[0]);
    water += searchlightScatter(ray,s);
    return half4(half3(max(waterThroughInlet(water,ray,s),0.)),1);
}

struct BubbleFragment {
    float4 p [[position]];
    float3 normal, world;
    float4 pigment [[flat]], state [[flat]], lighting [[flat]];
    float4 cosmos [[flat]], membranePose [[flat]];
    float2 presenceAndSize [[flat]];
    float orbitalVisibility [[flat]];
    float4 palette [[flat]];
};

float3 projectWorld(float3 point, constant Scene& s) {
    const float3 c = point-s.eye.xyz;
    const float z = dot(c,s.forward.xyz);
    return float3(dot(c,s.right.xyz)*focal/s.screen.x,dot(c,s.up.xyz)*focal,z);
}
float3 rotateY(float3 p,float theta) {
    const float a = cos(theta), b = sin(theta);
    return float3(p.x*a+p.z*b,p.y,p.z*a-p.x*b);
}

float2 rotatePlane(float2 p, float angle) {
    const float a = cos(angle), b = sin(angle);
    return float2(p.x*a-p.y*b,p.x*b+p.y*a);
}

float3 bubbleOrientation(float3 p, Bubble j) {
    if (j.flow.z > 0.) p.xy = rotatePlane(p.xy,-.27*j.flow.x);
    if (j.pitch != 0.) p.yz = rotatePlane(p.yz,j.pitch);
    return rotateY(p,j.flow.y);
}

float2 patch(uint i, uint cols, uint rows) {
    const uint triangle = i / 6;
    const uint corner = i % 6;
    const uint ox = corner == 1 || corner == 2 || corner == 4;
    const uint oy = corner == 2 || corner == 4 || corner == 5;
    return float2(float(triangle%cols+ox)/cols,float(triangle/cols+oy)/rows);
}

struct Ribbon {
    float4 p [[position]];
    float across, depth, height;
    float4 light;
};

vertex Ribbon currentSheet(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                           device const FlowNode* field [[buffer(3)]],
                           constant uint& nodes [[buffer(4)]],
                           constant uint& columns [[buffer(5)]]) {
    const uint cells = columns*(nodes-1)*6;
    const uint line = (id/cells)*nodes;
    const float2 uv = patch(id%cells,columns,nodes-1);
    const uint row = uint(round(uv.y*float(nodes-1)));
    const FlowNode node = field[line+row];
    const float3 tangent = field[line+min(row+1,nodes-1)].point.xyz-
                           field[line+max(1u,row)-1].point.xyz;
    const float3 side = normalize(float3(tangent.z,0.,-tangent.x)+float3(.0001,0,0));
    const float layer = node.light.z;
    const float across = uv.x*2.-1.;
    const float travel = node.light.x-s.screen.y*2.26;
    const float fold = .23*sin(4.8*across+travel*.19+layer*2.8)+
                       .15*sin(7.9*across-travel*.29+layer);
    const float curl = .26*across*across+fold*(.68+.39*s.music.x);
    const float3 world = node.point.xyz+node.point.w*
                         (side*across+float3(0,curl-.17,0));
    const float3 clip = projectWorld(world,s);
    return {float4(clip.xy,clip.z-.35,clip.z),across,clip.z,world.y,node.light};
}

// Currents emit light without darkening the water behind their meshes.
constant float currentOpacity = .50;

half flowTransmission(float4 position, texture2d<half,access::read> transmission) {
    return saturate(transmission.read(uint2(position.xy)).g);
}

float3 currentPigment(float3 light, float phase, float colourAmount, constant Scene& s) {
    // Convert the thin, premultiplied strokes at the brightness of the painted ground.
    if (!hybridWater(s)) return light;
    const float peak = max(light.r,max(light.g,light.b));
    const float rainbow = s.habitat.x > .5 ? .24*colourAmount : .70*colourAmount;
    return .51*mix(light,hybridPrism(phase)*peak*1.12,rainbow);
}

float flowFilament(float offset, float width, float footprint) {
    // Keep a thin line stable as it becomes smaller than a pixel.
    const float span = max(width,.82*footprint);
    const float distance = offset/span;
    return exp2(-2.85*distance*distance)*(width/span);
}

fragment half4 sheetLight(Ribbon in [[stage_in]], constant Scene& s [[buffer(0)]],
                          texture2d<half,access::read> transmission [[texture(2)]]) {
    const float transmissionAmount = flowTransmission(in.p,transmission);
    if (in.light.w <= 0. || transmissionAmount <= 0.) return half4(0.);
    const float a = in.across;
    const float layer = in.light.z;
    const float drift = in.light.x-s.screen.y*2.26;
    const float roll = .21*sin(drift*.17+layer*2.3)+.16*sin(drift*.49-layer*.78);
    const float folded = a-roll;
    const float edge = 1.-smoothstep(.60,1.,abs(a));
    const float silk = exp2(-3.85*folded*folded)*edge;
    const float phase = fract(drift*.144-.21*folded*folded+layer*.28+.5)-.5;
    const float crest = exp2(-abs(phase)*mix(6.5,45.,smoothstep(-.024,.021,phase)))*
                        (1.-smoothstep(.25,.48,abs(phase)));
    const float braid = folded*3.45+.23*sin(drift*.38+folded*3.4+layer*1.5);
    const float cord = flowFilament(fract(braid+.5)-.5,.102,fwidth(braid));
    const float iridescence = .5+.5*sin(drift*.34+layer*1.8+folded*3.1);
    const float depth = smoothstep(1.4,6.,in.depth)*exp2(-in.depth*.014);
    const float presence = currentOpacity*in.light.w*depth*silk*transmissionAmount*(1.-s.cycle.z)*s.basinArrival;
    const bool brush = s.graphicsStyle != 0u;
    const float3 base = brush ? float3(.35,.19,.18) : mix(ember,sulphur,s.habitat.z);
    const float tint = s.habitat.x > .5 ? .82 : (1.-s.screen.w)*(brush ? .38 : .78);
    const float3 dye = mix(base,mix(s.water.xyz,s.bright.xyz,.57),tint);
    const float3 foldTint = mix(dye,s.contrast.xyz,.14+.14*layer);
    const float3 sheen = mix(foldTint,s.bright.xyz,.23+.24*iridescence);
    const float3 light = foldTint*.021+
                         sheen*cord*(.122+.064*iridescence+crest*(.30+.23*s.music.w));
    const float colourPhase = drift*.264+layer*1.12;
    return half4(half3(bubbleChroma(currentPigment(light,colourPhase,.56,s)*
                       depthLight(in.height,s),s.interiorPalette)*presence),0);
}
vertex Ribbon currentVertex(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                            device const FlowNode* field [[buffer(3)]],
                            constant uint& nodes [[buffer(4)]]) {
    const uint segment = (id/6)%(nodes-1);
    const uint line = ((id/6)/(nodes-1))*nodes;
    const float2 uv = patch(id%6,1,1);
    const uint row = segment+uint(uv.y);
    const FlowNode node = field[line+row];
    const float3 behind = field[line+max(1u,row)-1].point.xyz;
    const float3 ahead = field[line+min(row+1,nodes-1)].point.xyz;
    const float3 ray = normalize(node.point.xyz-s.eye.xyz+float3(.00001));
    const float3 side = normalize(cross(ahead-behind,ray) + s.right.xyz*.0001);
    const float across = (uv.x*2.-1.);
    const float swell = 1.+.37*s.music.x+.12*s.music.w;
    const float bend = sin(node.light.x*.40-s.screen.y*.58-s.call.w*.21)*.32*s.music.y;
    const float3 world = node.point.xyz+side*((across*swell+bend)*node.point.w);
    const float3 clip = projectWorld(world,s);
    return {float4(clip.xy,clip.z-.29,clip.z),across,clip.z,world.y,node.light};
}

fragment half4 currentLight(Ribbon in [[stage_in]], constant Scene& s [[buffer(0)]],
                            texture2d<half,access::read> transmission [[texture(2)]]) {
    const float transmissionAmount = flowTransmission(in.p,transmission);
    if (in.light.w <= 0. || transmissionAmount <= 0.) return half4(0.);
    const float x = in.across;
    const float along = in.light.x;
    const float speed = in.light.z;
    const float time = s.screen.y;
    const bool brush = s.graphicsStyle != 0u;
    const bool guide = in.light.y > 3.5;
    const float destination = saturate(in.light.y-4.);
    const bool stream = in.light.y < .5 || guide;
    const bool eddy = !stream && in.light.y < 1.5;
    // The coordinate increases downstream even on ribbons that turn back towards the camera.
    const float travel = along-time*(stream ? 2.45 : eddy ? 1.55 : 1.95);
    const float ripple = .25*sin(travel*.68+x*3.8)+.16*sin(travel*.31-x*5.3);
    const float braid = .15*sin(travel*.39+x*.8);
    const float core = x-.12*sin(travel*.29)-.065*sin(travel*.63);
    const float edge = 1.-smoothstep(.67,1.,abs(x));
    const float haze = exp2(-4.9*core*core)*edge;
    const float left = core-.31-braid;
    const float right = core+.32-braid*.65;
    const float centre = flowFilament(core,.114,fwidth(core));
    const float threads = .51*flowFilament(left,.080,fwidth(left))+
                          .44*flowFilament(right,.072,fwidth(right))+.47*centre;
    const float silk = .5+.5*sin(travel*.91+6.2*x+4.*ripple);

    // A narrow bright crest and a long upstream tail show which way the water moves.
    const float crest = fract(travel*(stream ? .215 : .30)-.18*x*x+.5)-.5;
    const float falloff = mix(8.,44.,smoothstep(-.025,.025,crest));
    const float surge = exp2(-abs(crest)*falloff)*(1.-smoothstep(.29,.49,abs(crest)));
    const float gleam = surge*(.76*centre+.39*threads)*edge;
    const float visibility = currentOpacity*in.light.w*smoothstep(1.4,5.5,in.depth)*exp(-in.depth*.0065)*
                             transmissionAmount*(1.-s.cycle.z)*s.basinArrival;
    const float strength = (guide ? 1.14 : stream ? .94 : eddy ? .65 : .81)*
                           (.81+.19*saturate(speed*.46));
    const float guideTint = mix(.18,.89,smoothstep(.38,1.07,s.innerOcean.x));
    float3 body = guide ? mix(sulphur,s.bright.xyz,guideTint) :
                        stream ? mix(s.water.xyz,s.bright.xyz,.64) :
                        eddy ? mix(s.water.xyz,s.contrast.xyz,.79) : float3(.92,.28,.019);
    float3 highlight = guide ? mix(sulphur,s.bright.xyz,guideTint) :
                             stream ? mix(s.bright.xyz,s.contrast.xyz,.16+.14*ripple) :
                             eddy ? mix(s.contrast.xyz,s.bright.xyz,.25) : float3(1.,.73,.12);
    if (brush) {
        body = guide ? body : body*.84;
        highlight = mix(highlight,float3(.93,.70,.47),.10);
    }
    if (stream) {
        const float tint = s.habitat.x > .5 ? (guide ? .80 : .73) :
                           (1.-s.screen.w)*(brush ? .40 : guide ? .79 : .25);
        body = mix(body,mix(s.water.xyz,s.bright.xyz,.59),tint);
        highlight = mix(highlight,s.bright.xyz,tint);
    }
    body = mix(body,mix(ember,sulphur,.66),destination);
    highlight = mix(highlight,sulphur,destination);
    const float3 foam = mix(highlight,float3(1.,.92,.77),.19);
    const float3 light = body*haze*(.129+.094*silk) +
                         highlight*threads*edge*(.27+.17*silk+.16*s.music.z) +
                         foam*gleam*(.99+.43*s.music.w);
    const float colourPhase = travel*.23+in.light.y*.79;
    const float3 colour = currentPigment(light,colourPhase,stream ? .57 : eddy ? .38 : .17,s);
    const float3 gleamDownstream = (highlight*threads*edge*.35+foam*gleam*1.68)*destination;
    return half4(half3(bubbleChroma(colour*depthLight(in.height,s)+gleamDownstream,s.interiorPalette)*
                      (visibility*strength)),0);
}

float bubbleWidth(Bubble j) {
    const float kind = j.pigment.w;
    return kind > 4.5 ? .83 : kind > 3.5 ? .57 : kind > 1.5 ? 1.21 : kind > .5 ? .83 : 1.;
}

struct SphereShape { float3 axes, warp; };

SphereShape sphereShape(Bubble j, float charge) {
    const float phase = j.pigment.y, seed = j.flow.w*tau;
    const float impulse = j.membraneAnchor == 1. ? j.trail.w : 0.;
    const float squeeze = max(0.,j.flow.z)*(.15*charge+.085*j.trail.w);
    const float wobble = sin(phase);
    const float rise = smoothstep(.18,2.4,abs(j.trail.y));
    const float height = 1.+.093*wobble-(.12*rise+squeeze)+.24*impulse;
    const float sideways = 1.+.061*cos(phase+seed);
    // Redistribute the film around a near-constant volume as the bubble compresses.
    const float width = bubbleWidth(j)*rsqrt(height);
    const float3 axes = float3(width*sideways,bubbleWidth(j)*height,width/sideways);
    const float3 warp = float3(.13*sin(phase+seed),.085*cos(phase-seed),.053*wobble);
    return {axes,warp};
}

float sphereRadius(float3 n, float3 warp) {
    const float split = n.z*n.z-n.x*n.x;
    return 1.+dot(warp,float3(n.y*(n.x+.62*n.z),split*(.42+n.y),n.x*n.z));
}

float3 sphereNormal(float3 n, float radius, SphereShape sphere) {
    const float3 gradient = sphere.warp.x*float3(n.y,n.x+.62*n.z,.62*n.y)+
                            sphere.warp.y*float3(-2.*n.x*(.42+n.y),n.z*n.z-n.x*n.x,2.*n.z*(.42+n.y))+
                            sphere.warp.z*float3(n.z,0.,n.x);
    return normalize((n*(radius+dot(n,gradient))-gradient)/sphere.axes);
}

float3 bubbleCentre(Bubble j, SphereShape sphere, constant Scene& s) {
    float3 centre = j.position.xyz;
    if (j.membraneAnchor > 0.) {
        // The near pole stays on the original passage through each deformation.
        const float3 inlet = float3(0.,0.,-1.);
        centre -= bubbleOrientation(inlet*sphere.axes*sphereRadius(inlet,sphere.warp),j)*j.position.w;
    }
    if (s.heldBubbleCentre.w > 0. && s.heldBubble == uint(j.bellSystem))
        centre = mix(centre,s.heldBubbleCentre.xyz,s.heldBubbleCentre.w);
    return centre;
}

float3 bubbleWorldPoint(float3 local, Bubble j, float3 centre) {
    local.x += j.flow.x*local.y*.23;
    return centre+bubbleOrientation(local,j)*j.position.w;
}

float3 gateSpace(float3 p, Bubble gate, float3 axes) {
    p = rotateY(p,-gate.flow.y);
    p.yz = rotatePlane(p.yz,-gate.pitch);
    p.x -= gate.flow.x*p.y*.23;
    return p/axes;
}

float4 gateInterior(float3 ray, constant Scene& s, Bubble gate, device const SystemBubble& catalogue) {
    if (gate.position.w <= 0. || catalogue.star.w <= 0.) return float4(0.);
    const SphereShape sphere = sphereShape(gate,s.call.x);
    const float3 centre = bubbleCentre(gate,sphere,s);
    const float3 eye = gateSpace((s.eye.xyz-centre)/gate.position.w,gate,sphere.axes);
    const float3 localRay = normalize(gateSpace(ray,gate,sphere.axes));
    return catalogueInterior(catalogue,eye,localRay,0.,s.orbitalPixel,s.celestialTime);
}

struct WakeBubble {
    float4 p [[position]];
    float2 uv;
    float4 light;
    float4 palette [[flat]];
};

vertex WakeBubble bubbleWakeVertex(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                                  device const TrailPose* history [[buffer(5)]],
                                  constant uint4& layout [[buffer(6)]]) {
    const uint sample = id/6;
    const uint past = sample%layout.y, actor = sample/layout.y;
    const uint row = (layout.x+layout.z-1u-past)%layout.z;
    const TrailPose birth = history[row*layout.w+actor];
    const float age = s.screen.y-birth.light.x;
    const float seed = hash(floor(birth.light.x*11.4+.5)*8.31+float(actor)*2.795);
    if (age <= 0. || age >= 5.2 || birth.light.w <= 0. || seed < .69)
        return {float4(0,0,-1,1),float2(0),float4(0),float4(0)};
    const float2 uv = patch(id%6,1,1)*2.-1.;
    const float radius = mix(.053,.153,hash(seed*113.))*min(1.9,birth.position.w)*
                         (1.+.10*age);
    const float lift = age*mix(.17,.56,hash(seed*719.));
    const float spread = .54*birth.position.w;
    const float turn = seed*139.6;
    const float3 centre = birth.position.xyz+
        float3(spread*cos(turn)+.14*sin(age*1.7+turn),lift-.61*birth.position.w,spread*sin(turn));
    const float3 clip = projectWorld(centre+radius*(s.right.xyz*uv.x+s.up.xyz*uv.y),s);
    const float life = smoothstep(.06,.32,age)*(1.-smoothstep(2.7,5.2,age));
    const float visibility = smoothstep(1.,3.3,clip.z)*exp(-.026*clip.z);
    const float3 tint = mix(mix(pigment(birth.light.y),sulphur,.23),s.bright.xyz,.53);
    return {float4(clip.xy,clip.z-.25,clip.z),uv,float4(tint,life*visibility*birth.light.w),birth.palette};
}

fragment half4 bubbleWakeLight(WakeBubble in [[stage_in]]) {
    const float radius = length(in.uv);
    const float edge = smoothstep(.51,.82,radius)*(1.-smoothstep(.83,1.,radius));
    const float glint = exp2(-25.*dot(in.uv-float2(-.31,.47),in.uv-float2(-.31,.47)));
    const float opacity = in.light.w*(.32*edge+.28*glint);
    const float3 light = bubbleChroma(in.light.xyz*edge+float3(.69,.88,1.)*glint,in.palette);
    return half4(half3(light*in.light.w*.48),half(opacity));
}

vertex BubbleFragment bubbleVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                   constant Scene& s [[buffer(0)]],
                                   device const Bubble* bubbles [[buffer(1)]],
                                   constant uint2& mesh [[buffer(7)]]) {
    const Bubble j = bubbles[instance];
    const float morph = max(0.,j.flow.z)*smoothstep(.04,.51,s.cycle.y);
    SphereShape sphere = sphereShape(j,s.call.x);
    sphere.axes = mix(sphere.axes,s.enclosingShape.xyz,morph);
    sphere.warp *= 1.-morph;
    const float2 uv = patch(id,mesh.x,mesh.y);
    const float azimuth = uv.x*tau, polar = uv.y*pi;
    const float ring = sin(polar);
    const float3 direction = float3(cos(azimuth)*ring,cos(polar),sin(azimuth)*ring);
    const float radius = sphereRadius(direction,sphere.warp);
    const float3 local = sphere.axes*direction*radius;
    float3 normal = sphereNormal(direction,radius,sphere);
    normal.y -= j.flow.x*.23*normal.x;
    const float3 centre = bubbleCentre(j,sphere,s);
    const float3 point = bubbleWorldPoint(local,j,centre);
    const float3 clip = projectWorld(point,s);
    return {float4(clip.xy,clip.z-.12,clip.z),bubbleOrientation(normal,j),point,j.pigment,j.flow,
            float4(j.eclipsing,j.basinLight,j.basinTone,j.membraneAnchor),
            float4(centre,j.bellSystem),float4(sphere.axes,j.pitch),
            float2(j.presence,j.position.w),j.bellSystemVisibility,j.palette};
}

struct BubbleLight {
    half4 weighted [[color(0)]];
    half2 opacity [[color(1)]];
};

float3 bubbleSpace(float3 vector, BubbleFragment in) {
    vector = rotateY(vector,-in.state.y);
    vector.yz = rotatePlane(vector.yz,-in.membranePose.w);
    vector.xy = rotatePlane(vector.xy,.27*in.state.x*in.state.z);
    vector.x -= in.state.x*vector.y*.23;
    return vector/in.membranePose.xyz;
}

float4 bubbleWindow(BubbleFragment in, constant Scene& s, constant BellSystem* systems,
                    float3 view, float3 eye, float inside, float facing, constant FlightScene& flight,
                    device const SystemBubble* catalogues) {
    const bool ziksa = in.state.z < 0.;
    if (!ziksa && (in.cosmos.w <= 0. || in.orbitalVisibility <= 0.)) return float4(0.);
    const float size = in.presenceAndSize.y;
    const float distance = length(s.eye.xyz-in.cosmos.xyz);
    const float resolved = smoothstep(4.,13.,size/max(.12,distance*s.orbitalPixel));
    const float visible = resolved*mix(smoothstep(.025,.28,facing),1.-smoothstep(-.20,.08,facing),inside);
    if (visible <= 0.) return float4(0.);
    const float3 direction = normalize(bubbleSpace(-view,in));
    const float3 surface = bubbleSpace((in.world-s.eye.xyz)/size,in);
    const float entry = max(0.,dot(direction,surface))*(1.-inside);
    if (ziksa) return ziksaInterior(eye,direction,entry,s.orbitalPixel,flight,true)*visible;
    const uint slot = uint(in.cosmos.w)-1u;
    if (systems[slot].region.w > 0.) return float4(0.);
    if (catalogues[slot].star.w <= 0.) return float4(0.);
    return catalogueInterior(catalogues[slot],eye,direction,entry,s.orbitalPixel,s.celestialTime)*
           (visible*in.orbitalVisibility);
}

struct SystemBubbleFragment {
    float4 position [[position]];
    float2 local;
    float4 tint [[flat]];
    float3 lockedTint [[flat]];
    float2 depthAndYaw [[flat]];
    uint system [[flat]];
    float4 sphere [[flat]];
};

vertex SystemBubbleFragment systemBubbleVertex(uint id [[vertex_id]], uint index [[instance_id]],
                                              constant Scene& s [[buffer(0)]],
                                              device const Bubble* bubbles [[buffer(1)]],
                                              device const SystemBubble* systems [[buffer(2)]],
                                              constant uint& parentIndex [[buffer(3)]],
                                              constant BellSystem* skies [[buffer(4)]]) {
    const Bubble parent = bubbles[parentIndex];
    const SphereShape shape = sphereShape(parent,s.call.x);
    const float4 body = systems[index].position;
    float3 centre = bubbleWorldPoint(body.xyz*shape.axes,parent,bubbleCentre(parent,shape,s));
    if (s.heldSystemCentre.w > 0. && s.heldSystem == index)
        centre = mix(centre,s.heldSystemCentre.xyz,s.heldSystemCentre.w);
    const float depth = dot(centre-s.eye.xyz,s.forward.xyz);
    if (depth < .12) return {float4(0.,0.,-1.,1.),float2(0.),float4(0.),float3(0.),float2(0.),index,float4(0.)};
    const float radius = parent.position.w*body.w*min(shape.axes.x,min(shape.axes.y,shape.axes.z));
    // A minimum raster footprint keeps very distant systems stable as they pass between pixels.
    const float footprint = max(radius,.72*depth*s.orbitalPixel);
    const float2 quad = (patch(id,1,1)*2.-1.)*1.75;
    const float3 clip = projectWorld(centre+footprint*(s.right.xyz*quad.x+s.up.xyz*quad.y),s);
    const float3 tint = skies[uint(parent.bellSystem)-1u].region.xyz;
    return {float4(clip.xy,clip.z-.12,clip.z),quad*(footprint/radius),float4(tint,parent.presence),parent.palette.rgb,
            float2(depth,parent.flow.y),index,float4(centre,radius)};
}

float hullTransmission(float depth, uint2 pixel, texture2d<half,access::read> hull,
                       texture2d<half,access::read> hullRange) {
    const float cover = hull.read(pixel).w;
    return cover > 0. && depth*cover > float(hullRange.read(pixel).r) ? 1.-cover : 1.;
}

float4 shadeSystemBubble(device const SystemBubble& system, float2 local, float width, float3 tint,
                         float yaw, float3x3 camera, float time, constant FlightScene& ziksa, bool closeUp = false) {
    const float radius = length(local);
    const float soft = clamp(.47*width,closeUp ? .001 : .024,.85);
    const float resolved = 1.-smoothstep(.36,1.14,width);
    const float rim = resolved*smoothstep(.43,.92,radius);
    const float2 glintOffset = local-float2(-.39,.62);
    const float glint = resolved*exp2(-26.*dot(glintOffset,glintOffset));
    const bool isZiksa = uint(system.catalogue.x) == 14538u;
    const float starSize = isZiksa ? ziksa.bodies[0].position.w : system.star.w;
    const float3 star = isZiksa ? ziksa.bodies[0].colour.xyz : system.star.xyz;
    const float starCore = 1.-smoothstep(max(0.,starSize-soft),starSize+soft,radius);
    const float shine = exp2(-9.*radius*radius);
    const float3 dye = mix(tint,star,.32);
    float3 light = dye*(.034+.48*rim) + glint*mix(dye,float3(.87,.97,1.),.75)*.66;
    light += star*(.85*starCore+.24*shine+.29*(1.-resolved));
    if (closeUp && starCore > 0.) {
        const float limb = sqrt(saturate(1.-powr(radius/starSize,2.)));
        const float2 surface = local/starSize;
        const float granules = noise(surface*16.+float2(time*.23,limb*2.));
        const float flows = noise(surface*6.4+float2(-time*.086,granules*.57));
        light += star*starCore*(.16+.43*limb*(.48+.52*flows)+.25*granules);
    }
    float opacity = .10+.37*rim+.45*starCore+.24*shine+.25*(1.-resolved);

    const float detail = 1.-smoothstep(.17,.37,width);
    if (detail > 0.) {
        // The overview uses an orthographic ray through the same scene as the cockpit.
        const float3 right = rotateY(camera[0],-yaw), up = rotateY(camera[1],-yaw);
        const float3 forward = rotateY(camera[2],-yaw);
        const float3 eye = right*local.x+up*local.y-forward*2.4;
        const float pixel = max(.0001,width*.48);
        const float4 orbits = isZiksa ? ziksaInterior(eye,forward,0.,pixel,ziksa,false) :
                                      catalogueInterior(system,eye,forward,0.,pixel,time);
        light = mix(light,orbits.rgb,detail*.87*orbits.w);
        opacity = max(opacity,orbits.w*detail*.91);
    }

    return float4(light,opacity);
}

fragment BubbleLight systemBubbleLight(SystemBubbleFragment in [[stage_in]], constant Scene& s [[buffer(0)]],
                                      device const SystemBubble* systems [[buffer(3)]],
                                      device const float* colours [[buffer(7)]],
                                      constant FlightScene& ziksa [[buffer(2)]],
                                      texture2d<half,access::read> hull [[texture(3)]],
                                      texture2d<half,access::read> hullRange [[texture(4)]]) {
    const float radius = length(in.local);
    const float width = max(length(fwidth(in.local)),.0001);
    const float soft = clamp(.47*width,.024,.85);
    const float silhouette = 1.-smoothstep(1.-soft,1.+soft,radius);
    if (silhouette <= 0.) return {half4(0.),half2(0.)};
    device const SystemBubble& system = systems[in.system];
    const float depth = in.depthAndYaw.x;
    const float transmission = hullTransmission(depth,uint2(in.position.xy),hull,hullRange);
    if (transmission <= 0.) return {half4(0.),half2(0.)};
    const float3x3 camera(s.right.xyz,s.up.xyz,s.forward.xyz);
    float4 pocket = shadeSystemBubble(system,in.local,width,in.tint.xyz,in.depthAndYaw.y,camera,s.celestialTime,ziksa);
    if (s.searchlightOrigin.w > 0.) {
        const float3 normal = camera*float3(in.local,-sqrt(saturate(1.-radius*radius)));
        const float reflection = searchlightFilm(in.sphere.xyz+normal*in.sphere.w,normal,s);
        pocket.rgb += searchlightColour*(2.1*reflection);
        pocket.w += .18*reflection;
    }
    const float coverage = transmission*silhouette*in.tint.w*smoothstep(.15,2.7,depth)*
        (1.-smoothstep(72.,107.,depth))*exp(-.0057*depth);
    const float weight = .048+1.7*exp2(-.091*depth);
    const float a = saturate(pocket.w)*coverage;
    const float colour = bubbleColourAt(colours[uint(system.catalogue.x)],s.celestialTime);
    return {half4(half3(bubbleChroma(pocket.xyz,float4(in.lockedTint,colour))*coverage*weight),half(a*weight)),
            half2(a,0.)};
}

fragment half4 systemSurveyLight(Full in [[stage_in]], constant float4& frame [[buffer(0)]],
                                constant float4& tintAndTime [[buffer(1)]],
                                device const SystemBubble* systems [[buffer(2)]],
                                constant uint& index [[buffer(3)]],
                                constant FlightScene& ziksa [[buffer(4)]],
                                constant float4& palette [[buffer(5)]]) {
    const float2 local = (in.uv-frame.xy)*float2(frame.w,-1.)/frame.z;
    const float r = length(local);
    const float width = max(length(fwidth(local)),.001);
    const float3 tint = tintAndTime.xyz;
    const float3 surround = bubbleChroma(float3(.006,.014,.018)+tint*(.015*exp2(-1.34*r*r)),palette);
    const float shell = 1.-smoothstep(1.-width,1.+width,r);
    if (shell <= 0.) return half4(half3(surround),1.);

    const float yaw = .11+.18*sin(tintAndTime.w*.12);
    const float3 forward = normalize(float3(.10,.94,.52));
    const float3 right = normalize(cross(float3(0.,1.,0.),forward));
    const float3 up = cross(forward,right);
    const float3x3 camera(right,up,forward);
    device const SystemBubble& system = systems[index];
    const float4 pocket = shadeSystemBubble(system,local,width,tint,yaw,camera,tintAndTime.w,ziksa,true);

    // Project the same plane the planets move in, then draw its orbital lanes.
    const float3 x = rotateY(float3(1.,0.,0.),yaw), y = rotateY(float3(0.,.43,.903),yaw);
    const float2 axisX = float2(dot(x,right),dot(x,up));
    const float2 axisY = float2(dot(y,right),dot(y,up));
    const float area = axisX.x*axisY.y-axisX.y*axisY.x;
    const float planeRadius = length(float2(axisY.y*local.x-axisY.x*local.y,
                                            -axisX.y*local.x+axisX.x*local.y)/area);
    float lane = 2.;
    for (uint body = 0u; body < systemPlanetLimit; ++body) {
        const float4 orbit = system.orbits[body];
        if (orbit.w <= 0.) break;
        lane = min(lane,abs(planeRadius-orbit.x));
    }
    const float rings = (uint(system.catalogue.x) == 14538u ? 0. : 1.-smoothstep(width*.48,width*1.6,lane))*smoothstep(system.star.w,system.star.w+.01,r);
    const float film = smoothstep(.73,1.,r);
    const float fineRim = exp2(-abs(r-.974)*55.);
    const float3 glass = mix(tint,float3(.49,.84,.89),film*.50);
    const float3 colour = surround+shell*bubbleChroma(pocket.xyz*.73+glass*(.10*film+.39*fineRim)+
                                         mix(tint,float3(.47,.63,.66),.56)*rings*.23,palette);
    return half4(half3(colour/(1.+.37*colour)),1.);
}

fragment BubbleLight bubbleMembrane(BubbleFragment in [[stage_in]], constant Scene& s [[buffer(0)]],
                                    constant BellSystem* systems [[buffer(1)]],
                                    constant FlightScene& flight [[buffer(2)]],
                                    device const SystemBubble* catalogues [[buffer(5)]],
                                    texture2d<half> waterLight [[texture(0)]],
                                    texture2d<half,access::read> hull [[texture(3)]],
                                    texture2d<half,access::read> hullRange [[texture(4)]]) {
    constexpr sampler sampleWater(coord::normalized,address::clamp_to_edge,filter::linear);
    const float3 offset = s.eye.xyz-in.world;
    const float distance = length(offset), size = in.presenceAndSize.y;
    const float nearPlane = -dot(offset,s.forward.xyz);
    const float hullClearance = hullTransmission(nearPlane,uint2(in.p.xy),hull,hullRange);
    const float largest = smoothstep(9.,13.,size);
    const bool passage = in.lighting.w > 0.;
    const bool player = in.state.z > 0.;
    const float distanceScale = passage ? max(1.,size/40.) : player && s.cycle.y > 0. ? max(1.,size/1.25) : 1.;
    const float reach = distance/distanceScale;
    const float visibility = hullClearance*in.presenceAndSize.x*smoothstep(.24,2.7,nearPlane)*
        (1.-smoothstep(mix(71.,148.,largest),mix(107.,224.,largest),reach));
    if (visibility <= 0.) return {half4(0.),half2(0.)};

    const float3 normal = normalize(in.normal+float3(.00001));
    const float3 view = offset/max(distance,.0001);
    const float face = dot(normal,view);
    const float3 eye = bubbleSpace((s.eye.xyz-in.cosmos.xyz)/size,in);
    const float inside = 1.-smoothstep(.87,1.12,length(eye));
    const float surface = mix(.13+.87*smoothstep(-.035,.17,face),
                              .16+.84*(1.-smoothstep(-.15,.03,face)),inside);
    const float3 bodyDye = paletteColour(s.paletteMix,playerBody);
    const float3 rimDye = paletteColour(s.paletteMix,playerRim);
    float3 dye = player ? mix(bodyDye,rimDye,.42) : in.state.z < 0. ? float3(.94,.43,.085) :
                                                                 pigment(in.pigment.x);
    if (passage) dye = mix(dye,s.passageColours[uint(in.lighting.w)-1u].xyz,.69);
    if (!player && in.cosmos.w > 0.) {
        const float4 region = systems[uint(in.cosmos.w)-1u].region;
        if (region.w > 0.) dye = mix(dye,region.xyz,.73);
    }
    const float time = s.screen.y;
    const BubbleFilm film = bubbleFilm(normal,view,s.sun.xyz,dye,time+13.*in.state.w);
    const float edge = film.edge;
    const float eclipse = in.lighting.x;
    const float painted = s.graphicsStyle == paintedGraphics ? .72 : 1.;
    float opacity = (.024+.038*film.body+.43*edge+.24*eclipse)*(player ? 1.14 : 1.);
    const float relay = 1.+.86*in.pigment.z+.36*s.music.w;
    float3 light = film.colour*relay*(.027+.063*film.body+.59*edge) +
                   mix(film.colour,s.sunlight.xyz,.62)*film.gloss*.66;
    float clear = 1.;
    if (passage) {
        const float4 gate = s.passages[uint(in.lighting.w)-1u];
        const float aperture = length((in.world-gate.xyz)*float3(1.,1.13,.42))/gate.w;
        clear = smoothstep(.40,1.24,aperture);
        const float lip = exp2(-54.*(aperture-.99)*(aperture-.99));
        light += dye*lip*.29;
    }
    if (face > .01) {
        const float2 screenUV = in.p.xy/float2(waterLight.get_width(),waterLight.get_height());
        const float2 direction = float2(dot(normal,s.right.xyz),-dot(normal,s.up.xyz))/float2(s.screen.x,1.);
        const float2 bend = direction*min(.47,size/max(2.,distance))*(.047+.027*film.body);
        const float3 lens = float3(waterLight.sample(sampleWater,screenUV+bend*1.19).r,
                                  waterLight.sample(sampleWater,screenUV+bend).g,
                                  waterLight.sample(sampleWater,screenUV+bend*.82).b);
        const float transmission = (.064+.088*edge)*smoothstep(.01,.28,face)*(1.-.68*eclipse)*painted;
        light += lens*transmission*(.82+.18*dye);
        opacity += transmission;
    }
    const float cohort = in.lighting.z < 0. ? 1. : mix(.36,1.,in.lighting.y);
    const float fog = exp(-.0057*reach);
    const float4 pocket = bubbleWindow(in,s,systems,view,eye,inside,face,flight,catalogues);
    light *= surface*cohort*(.18+.82*clear)*painted;
    opacity *= surface*cohort*(.19+.81*clear)*painted;
    light = player ? light*(1.-pocket.w*.81)+pocket.rgb :
                     mix(light,pocket.rgb*.83,pocket.w*.87)+pocket.rgb*.20;
    opacity = max(opacity,pocket.w*.72);
    const float reflection = searchlightFilm(in.world,normal,s)*surface*clear;
    light += searchlightColour*reflection*(1.7+1.2*film.body+.7*film.gloss);
    opacity += .18*reflection;
    const float coverage = visibility*fog;
    const float a = opacity*coverage;
    const float weight = .048+1.7*exp2(-.091*max(0.,nearPlane));
    float3 radiance = bubbleChroma(light,in.palette);
    if (passage && uint(in.lighting.w) == s.openPassage && face > 0.)
        radiance += emissiveLayerColour(in.palette.rgb)*(.018+.27*edge*edge)*painted;
    return {half4(half3(radiance*coverage*weight),half(a*weight)),
            half2(a,player ? coverage*smoothstep(.02,.25,opacity) : 0.)};
}

fragment half4 copyWaterLight(Full in [[stage_in]],
                              texture2d<half,access::read> water [[texture(0)]]) {
    return water.read(uint2(in.p.xy));
}

fragment half4 copyShipLight(Full in [[stage_in]],
                             texture2d<half,access::read> hull [[texture(3)]]) {
    return hull.read(uint2(in.p.xy));
}

fragment half4 combineBubbleLight(Full in [[stage_in]],
                                texture2d<half,access::read> jelly [[texture(1)]],
                                texture2d<half,access::read> transmission [[texture(2)]]) {
    const uint2 pixel = uint2(in.p.xy);
    const half4 sum = jelly.read(pixel);
    const float opacity = 1.-saturate(float(transmission.read(pixel).r));
    const float3 colour = float3(sum.rgb)/max(.00001,float(sum.a));
    return half4(half3(colour*opacity),half(opacity));
}

struct Fleck { float4 p [[position]]; float2 uv; float3 hue; float spark, detail; };

float3 colossusBloomPoint(float age, float layer, float stream, float seed, float scatter) {
    const float outward = smoothstep(0.,.91,age);
    const float sweep = stream*tau/6. + scatter*.88 + outward*(1.22+.32*layer);
    const float tide = sin(sweep*3.+layer*2.22);
    const float radius = .87 + (1.70+.39*seed+.23*tide)*outward;
    const float height = mix(-.26,-1.06,layer*.5) + .22*scatter +
                         outward*(1.56*tide+.78-1.1*layer);
    return float3(radius*cos(sweep),height,radius*sin(sweep));
}

float3 shaftBloomPoint(float age, float turn, float seed, float approach) {
    const float radius = mix(5.8,.29,smoothstep(0.,.69,age))+.22*seed;
    const float angle = turn+.75*smoothstep(0.,.62,age);
    const float lift = powr(age,3.2)*mix(4.2,32.,approach)*(.71+.47*seed);
    return float3(radius*cos(angle),.21+.61*sin(turn)+lift,radius*sin(angle));
}

float3 passageMote(float distance, float bearing, float scatter, constant Scene& s) {
    const float3 axis = s.passageFlow.xyz;
    const float3 up = float3(0.,axis.z,-axis.y);
    const float3 basin = s.enclosingBell.xyz+s.enclosedOrbits.xyz*s.enclosingBell.w;
    const float radius = distance*(.055+.16*scatter);
    return basin-axis*distance+radius*(float3(cos(bearing),0.,0.)+.66*up*sin(bearing));
}

vertex Fleck bloomVertex(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                         constant uint& source [[buffer(5)]]) {
    const uint mote = id/6;
    const float seed = hash(float(mote)+23.1);
    const float scatter = hash(float(mote)+719.2)*2.-1.;
    const float shimmer = hash(float(mote)+255.6);
    const float2 uv = patch(id%6,1,1);
    float3 head, tail;
    float size, luminosity, scale;
    if (source == 1u) {
        const float approach = s.whirlpoolApproach;
        const float age = fract(seed+s.celestialTime*(.105+.039*shimmer));
        const float turn = hash(float(mote)+10.)*tau;
        const float radius = s.whirlpool.w;
        scale = radius;
        head = s.whirlpool.xyz+radius*shaftBloomPoint(age,turn,shimmer,approach);
        tail = s.whirlpool.xyz+radius*shaftBloomPoint(max(0.,age-.021-.016*shimmer),turn,shimmer,approach);
        size = radius*(.012+.035*shimmer);
        luminosity = smoothstep(.04,.62,approach)*(1.-smoothstep(.015,.15,s.cycle.y))*
                     smoothstep(.01,.16,age)*(1.-smoothstep(.78,.99,age))*(.51+.29*s.cycle.x);
    } else if (source == 2u) {
        const float time = s.passageFlow.w;
        const float age = fract(seed+.137*(time+2.4));
        const float distance = exp2(mix(log2(s.enclosingBell.w*.90),2.3,age));
        const float bearing = shimmer*tau+.89*age+.23*scatter;
        head = passageMote(distance,bearing,shimmer,s);
        tail = passageMote(distance*mix(1.015,1.086,shimmer),bearing-.012,shimmer,s);
        size = distance*mix(.0012,.0038,shimmer);
        scale = max(1.,distance*.15);
        luminosity = smoothstep(-2.4,-.45,time)*(1.-smoothstep(4.85,7.75,time))*
                     smoothstep(0.,.13,age)*(1.-smoothstep(.82,1.,age))*(.32+.42*shimmer);
    } else {
        const float layer = float(mote%3u);
        const float stream = float((mote/3u)%6u);
        const float age = (s.cycle.y-(.393+.077*layer+.050*seed))/(.34+.13*shimmer);
        if (age <= 0. || age >= 1.) return {float4(0,0,-1,1),uv,float3(0),0,0};
        const float radius = s.enclosingBell.w;
        scale = radius;
        const float3 local = colossusBloomPoint(age,layer,stream,seed,scatter);
        head = s.enclosingBell.xyz+radius*local;
        tail = s.enclosingBell.xyz+radius*colossusBloomPoint(max(0.,age-.021-.044*shimmer),layer,stream,seed,scatter);
        size = radius*(.0048+.017*shimmer);
        // The bell damps the particles behind it while leaving a glow through its membrane.
        const float3 axes = s.enclosingShape.xyz;
        const float3 eye = (s.eye.xyz-s.enclosingBell.xyz)/(radius*axes);
        const float3 sight = local/axes-eye;
        const float offset = saturate(-dot(eye,sight)/max(.00001,dot(sight,sight)));
        const float transmission = mix(.26,1.,smoothstep(.81,1.14,length(eye+offset*sight)));
        luminosity = transmission*smoothstep(0.,.15,age)*(1.-smoothstep(.70,1.,age))*
                     (1.-smoothstep(.877,.961,s.cycle.y))*(.72+.29*shimmer);
    }

    const float3 projected = projectWorld(head,s), previous = projectWorld(tail,s);
    const float depth = min(projected.z,previous.z);
    if (depth < .065*scale) return {float4(0,0,-1,1),uv,float3(0),0,0};
    const float2 aspect = float2(s.screen.x,1.);
    const float2 end = projected.xy*aspect/projected.z;
    const float2 start = previous.xy*aspect/previous.z;
    const float2 axis = normalize(end-start+float2(.000001,.000004));
    const float width = clamp(focal*size/projected.z,.0011,.025);
    const float2 point = end+axis*mix(-max(width,length(end-start)),width,uv.y)+
                         float2(-axis.y,axis.x)*(uv.x*2.-1.)*width;
    const float pearl = smoothstep(.79,.99,shimmer);
    const float3 opal = mix(float3(.31,.064,1.),float3(.11,1.,.86),smoothstep(.13,.64,seed));
    const float3 colour = source == 2u ? mix(float3(.062,.71,1.),float3(.88,.93,.72),shimmer) :
                          mix(opal,float3(1.,.54,.095),smoothstep(.61,.94,seed));
    const float sparkle = .74+.26*sin(s.celestialTime*(2.1+seed*2.)+seed*71.);
    return {float4(point/aspect,0,1),uv,colour*(1.10+.54*pearl),
            luminosity*sparkle*smoothstep(.065,.30,depth/scale),.56+.44*pearl};
}

vertex Fleck planktonVertex(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                            device const Tracer* particles [[buffer(2)]]) {
    const Tracer mote = particles[id/6];
    const float2 uv = patch(id%6,1,1);
    const float3 head = projectWorld(mote.head.xyz,s);
    const float3 tail = projectWorld(mote.tail.xyz,s);
    const float depth = min(head.z,tail.z);
    if (depth < .8)
        return {float4(0,0,-1,1),uv,float3(0),0,0};
    const float2 aspect = float2(s.screen.x,1);
    const float2 end = head.xy/head.z*aspect;
    const float2 start = tail.xy/tail.z*aspect;
    const float halfWidth = mote.head.w*focal*(1.+.48*mote.current)/head.z;
    const float2 axis = normalize(end-start+float2(.000001,.000004));
    const float2 across = float2(-axis.y,axis.x);
    const float streak = length(end-start);
    const float2 point = end + axis*mix(-max(streak,halfWidth),halfWidth,uv.y) +
                        across*(uv.x*2.-1.)*halfWidth;
    const float glint = hash(float(id/6)+17.7);
    const bool paintedWorld = s.graphicsStyle == paintedGraphics;
    const float3 colour = paintedWorld ? mix(float3(.47,.61,.72),float3(.84,.55,.44),mote.wake) :
                          mix(mix(s.water.xyz,s.bright.xyz,.44+.20*glint+.34*mote.current),
                              mix(s.bright.xyz,float3(1.,.54,.095),.63),mote.wake);
    const float fade = smoothstep(.8,4.5,depth)*exp(-head.z*.015);
    const float suspended = mix(1.,.36+.83*mote.current,s.habitat.y)*(1.-s.cycle.z)*s.basinArrival;
    const float spin = .66+.34*sin(s.screen.y*(.95+glint*.57)+glint*57.);
    const float detail = smoothstep(.91,1.,glint)*spin;
    return {float4(point/aspect,0,1),uv,colour*depthLight(mote.head.y,s)+1.8*searchlightAt(mote.head.xyz,s)*searchlightColour,
            mote.tail.w*fade*suspended*(paintedWorld ? .62 : 1.+.48*s.music.z+.19*s.music.w),detail};
}
fragment half4 planktonFragment(Fleck in [[stage_in]], constant Scene& s [[buffer(0)]],
                                texture2d<half,access::read> transmission [[texture(2)]]) {
    const float cross = in.uv.x*2.-1.;
    const float along = in.uv.y;
    const float edge = (1.-abs(cross))*(1.-smoothstep(.90,1.,along));
    const float body = edge*edge*smoothstep(.02,.85,along)*(.33+.67*along);
    const float2 offset = float2(cross*2.9,(along-.83)*13.);
    const float bead = exp(-dot(offset,offset))*in.detail*edge;
    const float light = in.spark*flowTransmission(in.p,transmission);
    const float opacity = (body*.63+bead*.22)*light;
    return half4(half3(bubbleChroma(in.hue*1.29*opacity+mix(in.hue,float3(1.,.91,.68),.28)*bead*light*.82,
                                  s.interiorPalette)),
                 half(opacity));
}

float3 grade(float3 x) {
    // Compress brightness together so the brighter membranes keep their hue.
    x = max(x,0.) * .96;
    const float peak = max(x.r,max(x.g,x.b));
    const float light = saturate((peak*(2.51*peak+.03))/(peak*(2.43*peak+.59)+.14));
    return pow(x/max(peak,.00001),float3(.89))*pow(light,.68);
}

float3 gradeHybrid(float3 light) {
    const float3 colour = grade(light*1.17);
    const float luminance = dot(colour,float3(.213,.715,.072));
    const float3 chroma = colour-luminance;
    const float peak = max(colour.r,max(colour.g,colour.b));
    const float dark = min(colour.r,min(colour.g,colour.b));
    const float saturation = (peak-dark)/max(peak,.00001);
    const float vibrance = .38*(1.-.68*saturation)*smoothstep(.025,.22,peak);
    const float limit = min((1.-luminance)/max(peak-luminance,.00001),
                            luminance/max(luminance-dark,.00001));
    return saturate(luminance+chroma*min(1.+vibrance,max(1.,limit)));
}

float3 finishPaint(float3 colour, float2 pixel) {
    const float tooth = .66*noise(pixel*float2(.39,.72))+.34*hash21(pixel);
    const float peak = max(colour.r,max(colour.g,colour.b));
    const float3 glaze = colour/(1.+.23*max(0.,peak-.67));
    return saturate(glaze+(tooth-.5)*.017);
}

float3 bloomSource(float3 color) {
    const float peak = max(color.r,max(color.g,color.b));
    const float knee = smoothstep(.34,.90,peak);
    return color*(knee/(1.+.19*peak));
}

fragment half4 extractGlow(Full in [[stage_in]], texture2d<half> scene [[texture(0)]]) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    const float2 px = 1.6/float2(scene.get_width(),scene.get_height());
    float3 soft = 0.;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            const float weight = (x == 0 ? 2. : 1.)*(y == 0 ? 2. : 1.)/16.;
            soft += bloomSource(float3(scene.sample(linear,in.uv+float2(x,y)*px).rgb))*weight;
        }
    }
    return half4(half3(soft),1);
}

fragment half4 spreadGlow(Full in [[stage_in]], texture2d<half> nearGlow [[texture(0)]]) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    const float2 px = 2.45/float2(nearGlow.get_width(),nearGlow.get_height());
    float3 soft = 0.;
    for (int y = -1; y <= 1; ++y) {
        for (int x = -1; x <= 1; ++x) {
            const float weight = (x == 0 ? 2. : 1.)*(y == 0 ? 2. : 1.)/16.;
            soft += float3(nearGlow.sample(linear,in.uv+float2(x,y)*px).rgb)*weight;
        }
    }
    return half4(half3(soft),1);
}

float3 sampleOceanDetail(texture2d<half> light,float2 uv) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    const float2 size = float2(light.get_width(),light.get_height());
    const float2 texel = uv*size-.5;
    const float2 base = floor(texel);
    const float2 t = texel-base;
    const float2 t2 = t*t, t3 = t2*t;
    const float2 lowWeight = -.5*t+t2-.5*t3;
    const float2 highWeight = .5*(t3-t2);
    const float2 centreWeight = 1.-lowWeight-highWeight;
    const float2 centreMix = (.5*t+2.*t2-1.5*t3)/centreWeight;
    const float2 centre = (base+.5+centreMix)/size;
    const float2 low = (base-.5)/size, high = (base+2.5)/size;
    // Fold the central Catmull–Rom taps into bilinear fetches and omit the faint diagonal lobes.
    const float3 middle = float3(light.sample(linear,centre).rgb);
    const float3 left = float3(light.sample(linear,float2(low.x,centre.y)).rgb);
    const float3 right = float3(light.sample(linear,float2(high.x,centre.y)).rgb);
    const float3 above = float3(light.sample(linear,float2(centre.x,low.y)).rgb);
    const float3 below = float3(light.sample(linear,float2(centre.x,high.y)).rgb);
    const float total = centreWeight.x*centreWeight.y+(lowWeight.x+highWeight.x)*centreWeight.y+
                        (lowWeight.y+highWeight.y)*centreWeight.x;
    const float3 detail = ((left-middle)*lowWeight.x+(right-middle)*highWeight.x)*centreWeight.y+
                          ((above-middle)*lowWeight.y+(below-middle)*highWeight.y)*centreWeight.x;
    const float3 minimum = min(middle,min(min(left,right),min(above,below)));
    const float3 maximum = max(middle,max(max(left,right),max(above,below)));
    return clamp(middle+detail/total,minimum,maximum);
}

float finishLens(float radiusSquared) {
    return .977+.040*radiusSquared;
}

float3 flightMarker(float3 colour, float2 uv, constant Scene& s, float4 guide) {
    if (guide.w == 0.) return colour;
    const bool region = guide.w < 0.;
    const bool locked = !region && s.lockedPassage != 0u;
    const float3 clip = projectWorld(guide.xyz,s);
    if (!region && clip.z < .15) return colour;
    const float2 projected = clip.z >= .15 ? clip.xy/clip.z :
        float2(clip.x < 0. ? -.92 : .92,clamp(clip.y/max(1.,abs(clip.z)),-.55,.55));
    const float2 centre = clamp(projected,float2(-.92,-.88),float2(.92,.88));
    const float2 local = (uv*float2(2.,-2.)+float2(-1.,1.)-centre)*float2(s.screen.x,1.);
    const float d = length(local);
    const float diagonal = min(abs(local.x),abs(local.y))/max(.0001,d);
    const float arc = locked ? 1. : smoothstep(.31,.45,diagonal);
    const float edge = max(.001,fwidth(d)*.54);
    const float square = max(abs(local.x),abs(local.y));
    const float ring = locked ? min(abs(square-.022),max(abs(local.y),abs(local.x)-.022)) :
                                abs(d-(region ? .040 : .026));
    const float outline = 1.-smoothstep(.0047,.0047+edge,ring);
    const float line = 1.-smoothstep(.0018,.0018+edge*.77,ring);
    const float opacity = abs(guide.w)*(region ? 1. : smoothstep(.15,.64,clip.z));
    const float3 tinted = mix(colour,float3(.019,.040,.051),opacity*outline*arc*.73);
    const float3 ink = region || locked ? float3(.98,.80,.38) : float3(.86,.985,.97);
    return mix(tinted,ink,opacity*line*arc*.91);
}

float3 pulseWavefront(float3 colour, float2 uv, constant Scene& s,
                      texture2d<half,access::read> hull, texture2d<half,access::read> hullRange) {
    const float lifetime = s.pulseAxis.w;
    if (lifetime <= 0. || s.innerOcean.z > 0. || s.cycle.y > 0. || s.cycle.w > .001) return colour;
    const float age = s.screen.z, radius = age*s.call.z;
    const float strength = smoothstep(.038,.18,age)*(1.-smoothstep(.60*lifetime,lifetime,age));
    if (strength <= 0.) return colour;
    const float2 q = (uv*float2(2.,-2.)+float2(-1.,1.))*float2(s.screen.x,1.);
    const float3 ray = normalize(s.forward.xyz+(q.x*s.right.xyz+q.y*s.up.xyz)/focal);
    const float3 offset = s.player.xyz-s.eye.xyz;
    const float centre = dot(ray,offset);
    const float impact = length(cross(ray,offset));
    const float root = radius*radius-impact*impact;
    const float travel = centre+sqrt(max(0.,root));
    const float3 normal = (ray*travel-offset)/max(.01,radius);
    const float latitude = dot(normal,s.pulseAxis.xyz);

    // Keep the ripple on the advancing front of the sphere.
    const float front = step(0.,root)*smoothstep(.15,.65,travel);
    const float ripple = sin(dot(normal,float3(13.,7.,-6.))+age*3.6);
    const float edge = abs(latitude-(.943+.0014*ripple));
    const float width = clamp(.70*fwidth(latitude),.00055,.0028);
    const float crest = front*(1.-smoothstep(.00085,.00175+width,edge));
    const float halo = front*exp2(-3.3*powr(edge/.012,2.));
    if (crest+halo <= .001) return colour;

    const float depth = max(.1,travel)*dot(ray,s.forward.xyz);
    const float2 hullSize = float2(hull.get_width(),hull.get_height());
    const uint2 pixel = uint2(clamp(uv,0.,.99999)*hullSize);
    const float seen = strength*hullTransmission(depth,pixel,hull,hullRange);
    const float3 corona = mix(colour,float3(.13,.50,.57),seen*halo*.22);
    return mix(corona,float3(.54,.87,.90),seen*crest*(.48+.08*ripple));
}

fragment half4 finish(Full in [[stage_in]], constant Scene& s [[buffer(0)]],
                      constant float4& guide [[buffer(1)]],
                      texture2d<half> light [[texture(0)]],
                      texture2d<half> nearGlow [[texture(1)]],
                      texture2d<half> farGlow [[texture(2)]],
                      texture2d<half,access::read> hull [[texture(3)]],
                      texture2d<half,access::read> hullRange [[texture(4)]]) {
    constexpr sampler sampleLight(coord::normalized,address::clamp_to_edge,filter::linear);
    const float2 q = in.uv-.5;
    const float lens = dot(q,q);
    if (s.graphicsStyle == paintedGraphics) {
        const float3 coat = sampleOceanDetail(light,in.uv);
        const float3 tinted = pulseWavefront(finishPaint(coat,in.p.xy),in.uv,s,hull,hullRange);
        return half4(half3(flightMarker(tinted,in.uv,s,guide)),1);
    }
    const float2 uv = .5 + q*finishLens(lens);
    const bool ultra = s.graphicsStyle == ultraGraphics;
    float3 c = ultra ? float3(light.sample(sampleLight,uv).rgb) : sampleOceanDetail(light,uv);
    // Keep the glow tight enough to leave dark water between bubbles.
    c += float3(nearGlow.sample(sampleLight,uv).rgb)*(ultra ? .17 : .11)+
         float3(farGlow.sample(sampleLight,uv).rgb)*(ultra ? .12 : .048);
    c *= 1.-.27*smoothstep(.11,.50,lens);
    const float grain = (hash21(in.p.xy)-.5)*.006;
    const float grainAmount = 1.-smoothstep(.69,1.,max(c.r,max(c.g,c.b)));
    c = (hybridWater(s) ? gradeHybrid(c) : grade(c))+grain*grainAmount;
    c = pulseWavefront(c,uv,s,hull,hullRange);
    return half4(half3(flightMarker(c,uv,s,guide)),1);
}
