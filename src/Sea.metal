#include <metal_stdlib>
using namespace metal;

struct Planet { float4 position, material, pigment; float ringOpacity, opacity; };
struct BellSystem { float4 sun, sunlight; Planet planets[3]; float4 skyPositions[3]; };
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
};
struct Jelly {
    float4 position, pigment, flow, trail;
    float presence, eclipsing, basinLight, basinTone, pitch, membraneAnchor, bellSystem, bellSystemVisibility;
};
struct Tracer { float4 head, tail; float wake, current; };
struct FlowNode { float4 point, light; };
struct TrailPose { Jelly jelly; float4 time; };
struct TrailMark { float4 tip, body, light; }; // Tip/time, origin/size, hue/hero/pulse/presence.
struct TrailLayout { uint4 history; float lifetime; uint lines, segments; };
struct Full { float4 p [[position]]; float2 uv; };
constant float pi = 3.14159265;
constant float tau = 6.2831853;
constant float focal = 1.94;
constant float3 moonDirection = float3(-.32108,.43145,.84283);
constant float moonRadius = .049;
constant uint hybridGraphics = 1u;
constant uint paintedGraphics = 2u;
constant uint ultraGraphics = 3u;

bool hybridWater(constant Scene& s) {
    return s.graphicsStyle == hybridGraphics || s.graphicsStyle == ultraGraphics;
}
constant float3 playerBody[4] = {
    float3(1.,.008,.15), float3(1.,.008,.31), float3(.024,.14,1.), float3(1.,.24,.006)
};
constant float3 playerRim[4] = {
    float3(1.,.024,.69), float3(.50,.017,1.), float3(.58,.012,1.), float3(1.,.85,.012)
};

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
    return pigment(.705+.243*sin(phase));
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

float3 lunarLight(float3 water, float3 ray, float pixel, float clarity) {
    if (dot(ray,moonDirection) < .94) return water;

    const float2 skyPlane = float2(dot(ray,normalize(cross(float3(0,1,0),moonDirection))),
                                  dot(ray,normalize(float3(0,1,0)-moonDirection*moonDirection.y)));
    const float2 p = skyPlane/moonRadius;
    const float r = length(p);
    const float edge = clamp(pixel/moonRadius+.095*(1.-clarity),.026,.25);
    const float3 pearl = float3(.68,.79,1.);
    const float halo = (.16*exp2(-.75*r*r)+.072*exp2(-.16*r*r))*(1.-smoothstep(4.6,6.,r));
    const float3 light = water+pearl*halo*clarity;
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
    return mix(light,disc,(1.-smoothstep(1.-edge,1.+edge,r))*clarity);
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
    return mix(float3(1.),mix(float3(.45,.09,.74),float3(.70,.58,.82),opening),
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
    const float warmWater = smoothstep(1.35,2.65,s.tide.z);
    const float3 indigo = mix(float3(.100,.143,.224),float3(.118,.165,.179),.52*saturate(s.tide.z));
    const float3 plum = float3(.203,.128,.158);
    const float3 ground = mix(indigo,plum,max(warmWater*.84,s.habitat.y*.34));
    float3 water = mix(float3(.039,.041,.065),ground,light);
    const float3 pigment = s.water.xyz/max(.01,max(s.water.r,max(s.water.g,s.water.b)));
    water = mix(water,water*(.66+.62*pigment),.55*(1.-s.paletteMix.x));
    water += (strokes.y-.5)*float3(.038,.043,.055);
    if (s.habitat.x > .5) {
        const float3 opening = normalize(float3(0.,5.,266.)-s.eye.xyz+float3(.001));
        const float wash = pow(saturate(dot(ray,opening)),4.6)*s.habitat.z;
        water += wash*(.24+.76*diagonal)*float3(.032,.047,.068);
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
    const float3 chalk = mix(float3(.70,.80,.89),float3(.94,.82,.73),warm);
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
        float3 painted = brush.xyz*.84+prism*(.067+.31*density+.017*s.music.x);
        if (opening) {
            const float3 dye = s.water.xyz/max(.01,max(s.water.r,max(s.water.g,s.water.b)));
            const float3 stain = density*(.23+1.1*dye);
            const float3 shimmer = mix(prism,dye,.78)*(.044+.21*density+.017*s.music.x);
            painted = mix(painted,stain+shimmer,.86);
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
        water += spread*(lantern*mix(float3(.013,.068,.21),float3(.015,.20,.24),field)*
                         (.32+.49*undersea)+float3(.15,.29,.013)*window*field*.38);
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
    const float3 abyss = float3(.035,.085,.175);
    const float3 colour = water*mix(abyss,float3(1.10,1.22,1.32),exposed)+
                          float3(.0014,.003,.011)*(1.-exposed);
    const float pixel = max(length(dfdx(ray)),length(dfdy(ray)));
    const float2 field = sample.xz*.128+sample.y*float2(.069,-.041);
    const float footprint = length(fwidth(field));
    const float clarity = mix(.28,.89,upperWater(s.eye.y+5.));
    if (exposed <= 0.) return lunarLight(colour,ray,pixel,clarity);
    const float2 caustic = refractedWater(field,s.celestialTime*.24,footprint);
    const float3 prism = hybridPrism(field.x*.88+field.y*.53-.24*s.celestialTime+.8*caustic.x);
    const float3 enamel = mix(mix(s.water.xyz,s.bright.xyz,.56),prism,.49);
    const float glow = exposed*(.28+.72*overhead)*(.059*caustic.x+.14*caustic.y);
    return lunarLight(colour+enamel*glow,ray,pixel,clarity);
}

float bellIntersection(float3 eye, float3 ray, float3 axes, float hemisphere) {
    const float3 p = eye/axes, d = ray/axes;
    const float a = dot(d,d), b = dot(p,d), c = dot(p,p)-1.;
    const float discriminant = b*b-a*c;
    if (discriminant < 0.) return -1.;
    const float root = sqrt(discriminant);
    const float entry = (-b-root)/a;
    const float exit = (-b+root)/a;
    if (entry > 0. && (eye.y+ray.y*entry)*hemisphere >= 0.) return entry;
    if (exit > 0. && (eye.y+ray.y*exit)*hemisphere >= 0.) return exit;
    return -1.;
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

float3 enclosingWater(float3 ray, float3 water, constant Scene& s, constant BellSystem& system) {
    // Trace the inner face of a world-space bell. Normalized distances keep the intersection precise.
    const float time = s.celestialTime;
    const float pixel = max(length(dfdx(ray)),length(dfdy(ray)));
    const float3 eye = (s.eye.xyz-s.enclosingBell.xyz)/s.enclosingBell.w;
    const float breath = sin(time*.266+.51);
    const float width = s.enclosingShape.x;
    const float crown = s.enclosingShape.y;
    const float bowl = s.enclosingShape.z;
    const float top = bellIntersection(eye,ray,float3(width,crown,width),1.);
    const float bottom = bellIntersection(eye,ray,float3(width,bowl,width),-1.);
    const bool dome = top > 0. && (bottom <= 0. || top <= bottom);
    const float reach = dome ? top : bottom;
    if (reach <= 0.) return water;
    const float shown = s.cycle.y > 0. ? s.enclosingShape.w : 1.;
    const float layout = s.cycle.y > 0. ? smoothstep(.26,.64,s.cycle.y) : 1.;
    // The same bodies are traced in bell space on both sides of the membrane.
    const float4 pocket = containedSky(eye,ray,0.,s.orbitalPixel,system,1.,s.enclosedOrbits,layout);
    const float3 surface = eye+ray*reach;
    const float height = dome ? crown : bowl;
    const float rise = surface.y/height;
    const float lat = abs(rise);
    const float angle = atan2(surface.z,surface.x);
    const float3 normal = normalize(surface/float3(width*width,height*height,width*width));
    const float facing = saturate(abs(dot(normal,ray)));
    // A pixel sees much more of the surface at the edge of the bell than face-on.
    const float footprint = reach*pixel/max(.055,facing);

    const float2 sheet = surface.xz*7.4+surface.y*float2(4.9,-8.3);
    const float tissue = fbm(sheet*.73+float2(time*.019,-time*.012));
    const float2 caustics = refractedWater(sheet*1.63+float2(tissue*2.,0.),time*.17,footprint*19.);
    const float folds = sin(7.*angle+rise*6.8+1.3*tissue+breath*.45);
    const float ribs = 24.*angle+1.04*sin(rise*9.+5.*angle)+1.12*folds*lat;
    const float fan = (1.-smoothstep(.79,.995,lat))*(.25+.75*tissue);
    const float ribFootprint = 24.*footprint/max(.12,length(surface.xz));
    const float ribDetail = 1.-smoothstep(.16,1.12,ribFootprint);
    const float canals = mix(.12,exp2(-4.9*abs(sin(ribs))),ribDetail)*fan;
    const float fork = .33+.50*sin(rise*19.-3.*angle);
    const float capillaries = mix(.09,exp2(-6.5*abs(sin(ribs+fork))),ribDetail) * fan * smoothstep(.11,.53,lat);
    const float beat = fract(rise*.34-time*.071+tissue*.15+.5)-.5;
    const float pulse = exp2(-36.*beat*beat);

    // The bell margin wraps continuously around the horizon as viewed from the water inside it.
    const float skirt = surface.y-.021*sin(angle*13.+breath*.64)-.022*sin(angle*7.-time*.13);
    const float hem = exp2(-410.*skirt*skirt);
    const float pleat = skirt+.049+.024*sin(angle*17.+time*.16);
    const float fringe = exp2(-570.*pleat*pleat)*(.17+.83*caustics.x);
    const float lamella = exp2(-38.*skirt*skirt)*(.28+.72*tissue);

    // Four horseshoe-shaped organs sit against the curved underside of the dome.
    const float2 organ = float2((fract(4.*angle/tau+.31)-.5)*2.6,(rise-.47)*2.9);
    const float contour = length(organ*float2(1.,1.22));
    const float gap = 1.-smoothstep(.26,.49,-organ.y)*(1.-smoothstep(.09,.31,abs(organ.x)));
    const float gland = exp2(-75.*(contour-.59)*(contour-.59))*gap;
    const float lining = exp2(-285.*(contour-.54)*(contour-.54))*gap*(.24+.76*caustics.x);
    const float fascia = exp2(-5.4*contour*contour);

    const float3 violet = mix(float3(.50,.11,1.),s.bright.xyz,.31);
    const float3 orchid = mix(float3(.37,.061,.64),s.contrast.xyz,.24);
    const float3 amber = float3(1.,.43,.108);
    const float3 flesh = mix(float3(.035,.075,.25),orchid,smoothstep(.26,.77,tissue));
    const float3 enamel = mix(violet,amber,.67*smoothstep(.52,.89,tissue+.13*folds));
    const float3 glow = flesh*(.14+.27*caustics.x+.12*fascia)+
        enamel*(.25*hem+.20*fringe+.071*lamella+.10*capillaries+canals*(.11+.24*pulse))+
        mix(orchid,amber,.43)*gland*(.17+.28*tissue)+amber*lining*.21+
        violet*caustics.y*(.039+.16*lamella)*(1.+.32*s.music.w);
    // Keep distant bodies readable even through the densest organs and folds.
    const float absorption = (.055+.047*fascia+.078*gland+.047*lamella)*(.57+.43*tissue);
    const float backdrop = dot(max(water,0.),float3(.213,.715,.072));
    const float veil = 1./(1.+1.7*backdrop);
    const float softness = s.graphicsStyle == paintedGraphics ? .46 : 1.;
    const float3 interior = water*(1.-absorption*softness)+glow*(veil*softness);
    const float space = 1.-s.enclosingSky;
    if (space <= 0.) return mix(water,mix(interior,pocket.rgb,.91*pocket.w)+pocket.rgb*.19,shown);

    // Light the same surface from outside, where the dome has a visible silhouette.
    const float grazing = 1.-facing;
    const float fresnel = grazing*grazing*grazing;
    const float sun = saturate(.49+.61*dot(normal,s.sun.xyz));
    const float3 pearl = mix(enamel,s.sunlight.xyz,.27+.28*sun);
    float3 exterior = water*(.72-.23*fresnel-.17*gland) +
        flesh*(.26+.64*sun)*(.34+.66*tissue)+glow*(.62+.74*sun) +
        pearl*(.38*fresnel+.23*hem+.18*fringe+.19*caustics.y*sun);
    if (s.cycle.y > 0.) {
        const float phase = s.cycle.y;
        const float crest = mix(-.43,.76,smoothstep(.37,.84,phase));
        const float pulse = exp2(-18.*powr(abs(surface.y-crest-.034*folds),2.));
        const float radiance = smoothstep(.32,.53,phase)*(1.-smoothstep(.84,.982,phase));
        const float3 opal = mix(float3(.22,.43,1.),float3(1.,.47,.16),.5+.5*folds);
        const float tracery = (canals+.74*capillaries)*(.32+.90*pulse)+.52*hem+.22*fringe;
        exterior += radiance*(opal*(tracery+.24*pulse*caustics.x) +
                              float3(.40,.95,1.)*fresnel*(.19+.57*pulse));
        exterior += pocket.rgb*(.22+.56*pulse)*radiance;
        const float signal = (phase-.404)*12.987;
        const float beatPhase = fract(signal);
        const float wave = rise-(.04+.92*beatPhase)+.047*folds;
        const float conduction = exp2(-106.*wave*wave)*smoothstep(0.,.18,beatPhase)*
            (1.-smoothstep(.74,1.,beatPhase))*smoothstep(.404,.45,phase)*(1.-smoothstep(.610,.681,phase));
        const float3 impulse = mix(float3(.66,.14,1.),float3(.17,1.,.87),.5+.5*sin(angle*6.+1.57*signal));
        exterior += conduction*(impulse*(1.18*canals+.75*capillaries)+opal*.44*caustics.y);
        const float3 inlet = (s.returnPassage.xyz-s.enclosingBell.xyz)/s.enclosingBell.w;
        const float3 offset = surface-inlet;
        const float radial = length(cross(offset,s.passageFlow.xyz));
        const float gathered = s.returnPassage.w*(1.-smoothstep(.95,.982,phase))*exp2(-10.*dot(offset,offset));
        const float rimGlow = exp2(-360.*(radial-.125)*(radial-.125));
        exterior += gathered*(float3(.19,.66,1.)*(.33*rimGlow+.34*canals)+opal*(.30*rimGlow+.14*caustics.x));
    }
    const float silhouetteWidth = max(.083,sqrt(3.6*reach*pixel));
    const float silhouette = smoothstep(0.,silhouetteWidth,facing);
    const float3 membraneLight = mix(interior,mix(water,exterior,silhouette),space);
    const float strength = mix(1.,silhouette,space);
    const float3 body = mix(membraneLight,pocket.rgb,pocket.w*strength*.91)+pocket.rgb*(strength*.19);
    return mix(water,body,shown);
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
    const float3 ivory = float3(1.,.92,.72);
    const float3 cobalt = float3(.18,.33,1.);
    const float3 shaft = (ivory*core*(1.38+.26*breath)+cobalt*.33*sheath)*lighthouse*reach*plumeGain;
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
        const float3 orchid = float3(.80,.035,1.);
        const float3 gold = float3(1.,.54,.071);
        const float3 cyan = float3(.090,.74,1.);
        const float3 prism = mix(orchid,cyan,smoothstep(.26,.83,drift));
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
    const float3 cyan = float3(.096,.79,1.);
    const float3 pearl = float3(1.,.89,.63);
    const float3 dye = mix(cyan,pearl,.24+.45*sparks+.23*charge);
    return smoothstep(.035,.32,abs(facing))*smoothstep(.035,.31,travel)*
          (dye*(foil*(.39+.69*sparks+.75*charge)+.66*braid)+cyan*.11*exp2(-8.*abs(band)));
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
    const float3 aqua = float3(.062,.68,1.);
    const float3 coral = float3(1.,.075,.37);
    const float3 gold = float3(1.,.60,.12);
    const float3 core = mix(float3(.97,.75,.38),float3(1.,.97,.88),charge);
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
    const float3 beacon = edge*(coral*.15*exp2(-r2*.19)*(1.-.93*nearby)+
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
            funnel += (mix(coral,gold,smoothstep(.78,3.4,radius))*(.053*sheet+.42*crest)+
                       aqua*(crest*.37+fleck*.58))*(.81+.23*breath);
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
    const float3 outline = (mix(aqua,core,.20+.60*charge)*border*(.18+.33*charge)+core*fill*.62)*
                            close*front;
    const float3 lip = whirlpoolRim(ray,origin,mix(2.10,1.36,charge),time,charge)*
                       mix(.73,1.10,nearby);
    return (column+beacon+funnel+outline+lip)*presence;
}

float3 membranePassage(float3 ray, uint gate, constant Scene& s, bool destination = false) {
    const float4 passage = s.passages[gate];
    if (passage.w <= 0. || abs(ray.z) < .001) return float3(0.);
    const float travel = (passage.z-s.eye.z)/ray.z;
    const float nearby = 1.-smoothstep(47.,125.,length(s.eye.xyz-passage.xyz));
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
    const float shoulder = radius-.84-.12*detail-.047*sin(plane.x*8.+plane.y*4.-t*.44);
    const float rim = exp2(-322.*shoulder*shoulder);
    const float glow = exp2(-36.*shoulder*shoulder);
    const float presence = nearby*smoothstep(.24,4.,travel)*exp(-travel*.008);
    const float3 light = s.passageColours[gate].xyz;
    const float3 spark = mix(light,destination ? float3(1.,.46,.11) : float3(1.,.93,.80),
                             .63*smoothstep(.33,.76,detail));
    if (destination) {
        const float bone = exp2(-82.*shoulder*shoulder);
        return (light*(.21*glow+.24*well*veils.x)+spark*rim*(.38+1.27*veils.x)+
                mix(light,float3(1.,.88,.67),.45)*bone*(.35+.41*veils.y))*presence;
    }
    return (light*(.16*glow+well*(.12+.39*veils.x+.20*veils.y))+
            spark*rim*(.08+.51*veils.x))*presence;
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

float3 whirlpoolSystem(float3 water, float3 ray, constant Scene& s, constant BellSystem* systems) {
    const float shown = smoothstep(.025,.80,s.innerOcean.w)*(1.-smoothstep(.08,.30,s.cycle.y));
    if (s.playerSystem <= 0. || s.whirlpool.w <= 0. || shown <= 0.) return water;
    const float3 origin = s.whirlpool.xyz+float3(.78,1.25,1.78)*s.whirlpool.w;
    const float3 eye = (s.eye.xyz-origin)/(s.whirlpool.w*4.6);
    if (dot(eye,ray) >= 0. || length(cross(eye,ray)) > 1.12) return water;
    const float4 orbit = containedSky(eye,ray,0.,s.orbitalPixel,systems[uint(s.playerSystem)-1u],
                                      shown,float4(0.,0.,0.,.51));
    return mix(water,orbit.rgb,.92*orbit.w*shown)+orbit.rgb*.14*shown;
}

float3 oceanBeforeTransformation(float3 ray, float2 q, constant Scene& s, constant BellSystem* systems) {
    const bool paintedWorld = s.graphicsStyle == paintedGraphics;
    const float inside = smoothstep(0.,1.,s.skyDepth);
    float3 water = inside < 1. ? (paintedWorld ? paintedOcean(ray,s) : luminousWater(ray,s)) : float3(0.);
    // Draw the membrane over the complete sky so the light of every star, planet and ring passes through it.
    if (inside < 1. && s.enclosingBell.w > 0.) water = enclosingWater(ray,water,s,systems[0]);
    if (inside > 0.) {
        const float stage = max(1.,s.skyDepth);
        const uint from = uint(stage);
        const float transition = smoothstep(0.,1.,fract(stage));
        const float3 inner = interiorWater(ray,s,systems);
        float3 local = bellSky(ray,inner,s,systems[from]);
        if (from < bellPassageCount && transition > 0.)
            local = mix(local,bellSky(ray,inner,s,systems[from+1u]),transition);
        water = mix(water,local,inside);
    }
    for (uint i=0; s.habitat.x > .5 && i+1u < bellPassageCount; ++i) {
        const float distance = float(i)-s.innerOcean.x;
        const float shown = (1.-smoothstep(.19,1.,distance))*smoothstep(-1.9,-1.12,distance);
        if (shown > 0.) water += membranePassage(ray,i,s)*shown;
    }
    const float finalOpening = smoothstep(3.0,3.82,s.innerOcean.x)*(1.-smoothstep(4.62,5.,s.innerOcean.x));
    if (finalOpening > 0. && s.whirlpool.w > 0.)
        water += membranePassage(ray,bellPassageCount-1u,s,true)*finalOpening;
    if (s.innerOcean.y > 0.) {
        const float ripple = .5+.5*sin(length(q)*12.-s.screen.y*.72);
        water += mix(s.bright.xyz,s.contrast.xyz,ripple)*s.innerOcean.y*(.055+.045*ripple);
    }
    const float age = s.screen.z;
    if (age < 5.3) {
        const float3 off = s.player.xyz - s.eye.xyz;
        const float radius = age*s.call.z;
        const float front = dot(ray,off);
        const float impact = sqrt(max(0.,dot(off,off)-front*front));
        const float edge = impact-radius;
        const float shell = exp(-abs(edge)*mix(2.1,1.28,s.call.y))+
                            s.call.y*.35*exp(-abs(edge+1.3)*1.4)*smoothstep(0.,.5,age);
        const float3 colour = paintedWorld ? mix(float3(.60,.76,.84),float3(.89,.39,.31),s.call.y) :
                              mix(s.bright.xyz,s.contrast.xyz,mix(.16,.66,s.call.y));
        water += colour*shell*smoothstep(0.,5.,front)*exp(-age*mix(.83,.59,s.call.y))*.35*
                 (1.-smoothstep(4.,5.3,age));
    }
    if (s.cycle.w > .22 && s.cycle.w < .44) {
        const float3 offset = s.player.xyz-s.eye.xyz;
        const float front = dot(ray,offset);
        const float radius = mix(.8,23.,1.-smoothstep(.22,.44,s.cycle.w));
        const float shell = length(cross(ray,offset))-radius;
        const float strength = smoothstep(.22,.31,s.cycle.w)*(1.-smoothstep(.37,.44,s.cycle.w));
        const float scattered = exp2(-.95*abs(shell))+.30*exp2(-.38*abs(shell+1.82));
        water += mix(s.bright.xyz,float3(.20,.60,1.),.46)*scattered*strength*.34*smoothstep(0.,9.,front);
    }
    if (s.innerOcean.z == 0. && s.basinArrival > 0.)
        water = mix(water,waterColumn(water,ray,s),s.basinArrival);
    water += openingWaveLight(ray,s)+whirlpoolLight(ray,s);
    return whirlpoolSystem(water,ray,s,systems);
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
    return water*transmittance+light;
}

fragment half4 oceanLight(Full in [[stage_in]], constant Scene& s [[buffer(0)]],
                          constant BellSystem* systems [[buffer(1)]]) {
    const float2 q = (in.uv*2.-1.)*float2(s.screen.x,-1.);
    const float3 ray = normalize(s.forward.xyz+(s.right.xyz*q.x+s.up.xyz*q.y)/focal);
    const float docking = smoothstep(.86,.982,s.cycle.y);
    float3 water = s.cycle.z < 1. ? oceanBeforeTransformation(ray,q,s,systems) : float3(0.);
    if (s.cycle.z > 0.) {
        const float focus = smoothstep(.24,.54,s.cycle.y);
        float3 outside = luminousWater(ray,s)*(1.-.44*focus*(1.-docking))+contractionWakes(ray,s);
        if (docking > 0. && s.graphicsStyle == paintedGraphics)
            outside = mix(outside,paintedOcean(ray,s),docking);
        water = mix(water,outside,s.cycle.z);
    }
    if (s.cycle.y > 0. && s.enclosingShape.w > 0.)
        water = enclosingWater(ray,water,s,systems[0]);
    return half4(half3(max(waterThroughInlet(water,ray,s),0.)),1);
}

struct AnimalFragment {
    float4 p [[position]];
    float3 normal, world;
    float4 shape [[centroid_perspective]];
    float2 attachment;
    float4 pigment;
    float4 state;
    float synchrony, scale, presence;
    float4 lighting;
    float4 cosmos [[flat]];
    float4 cosmosShape [[flat]];
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

float3 jellyOrientation(float3 p, Jelly j) {
    if (j.flow.z > 0.) p.xy = rotatePlane(p.xy,-.27*j.flow.x);
    if (j.pitch != 0.) p.yz = rotatePlane(p.yz,j.pitch);
    return rotateY(p,j.flow.y);
}

float3 jellyLocalVector(float3 p, Jelly j) {
    p = rotateY(p,-j.flow.y);
    if (j.pitch != 0.) p.yz = rotatePlane(p.yz,-j.pitch);
    if (j.flow.z > 0.) p.xy = rotatePlane(p.xy,.27*j.flow.x);
    return p;
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
    const float rainbow = s.habitat.x > .5 ? .42*colourAmount : colourAmount;
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
    const float3 base = brush ? float3(.30,.48,.63) :
                        mix(float3(.009,.53,1.),float3(.022,1.,.74),s.habitat.z);
    const float tint = s.habitat.x > .5 ? .82 : (1.-s.screen.w)*(brush ? .38 : .78);
    const float3 dye = mix(base,mix(s.water.xyz,s.bright.xyz,.57),tint);
    const float3 foldTint = mix(dye,brush ? float3(.56,.30,.36) : s.contrast.xyz,.14+.14*layer);
    const float3 sheen = mix(foldTint,brush ? float3(.73,.79,.85) : float3(.36,.94,1.),.23+.24*iridescence);
    const float3 light = foldTint*.021+
                         sheen*cord*(.122+.064*iridescence+crest*(.30+.23*s.music.w));
    const float colourPhase = drift*.264+layer*1.12;
    return half4(half3(currentPigment(light,colourPhase,.56,s)*depthLight(in.height,s)*presence),0);
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
    float3 body = guide ? mix(float3(.007,.56,1.),s.bright.xyz,s.habitat.z*.53) :
                        stream ? mix(s.water.xyz,s.bright.xyz,.64) :
                        eddy ? mix(s.water.xyz,s.contrast.xyz,.79) : float3(.92,.28,.019);
    float3 highlight = guide ? mix(float3(.018,.92,1.),s.bright.xyz,s.habitat.z*.32) :
                             stream ? mix(s.bright.xyz,s.contrast.xyz,.16+.14*ripple) :
                             eddy ? mix(s.contrast.xyz,s.bright.xyz,.25) : float3(1.,.73,.12);
    if (brush) {
        body = stream ? float3(.30,.43,.58) : eddy ? float3(.53,.33,.43) : float3(.65,.38,.30);
        highlight = mix(body,float3(.86,.83,.78),.54);
    }
    if (stream) {
        const float tint = s.habitat.x > .5 ? (guide ? .80 : .73) :
                           (1.-s.screen.w)*(brush ? .40 : guide ? .79 : .25);
        body = mix(body,mix(s.water.xyz,s.bright.xyz,.59),tint);
        highlight = mix(highlight,s.bright.xyz,tint);
    }
    body = mix(body,float3(.91,.19,.038),destination);
    highlight = mix(highlight,float3(1.,.65,.18),destination);
    const float3 foam = mix(highlight,float3(1.,.92,.77),.19);
    const float3 light = body*haze*(.129+.094*silk) +
                         highlight*threads*edge*(.27+.17*silk+.16*s.music.z) +
                         foam*gleam*(.99+.43*s.music.w);
    const float colourPhase = travel*.23+in.light.y*.79;
    const float3 colour = currentPigment(light,colourPhase,stream ? .57 : eddy ? .38 : .17,s);
    const float3 gleamDownstream = (highlight*threads*edge*.35+foam*gleam*1.68)*destination;
    return half4(half3((colour*depthLight(in.height,s)+gleamDownstream)*(visibility*strength)),0);
}

float strandSeed(Jelly j, uint strand) { return hash(float(strand)+j.flow.w*43.+19.); }
bool crownShape(float species) { return (species > .5 && species < 1.5) || species > 4.5; }
bool foldedArms(float species) { return species > 1.5 && species < 3.5; }
float bellWidth(Jelly j, float time, float charge) {
    const float kind = j.pigment.w;
    const float breath = sin(j.pigment.y)+.42*j.pigment.z*sin(time*3.8);
    const float contraction = (kind > 4.5 ? .038 : .10)+.083*j.trail.w*j.flow.z;
    const float width = kind > 4.5 ? .83 : kind > 3.5 ? .57 : kind > 1.5 ? 1.21 : kind > .5 ? .83 : 1.;
    const float stroke = j.membraneAnchor == 1. ? j.trail.w : 0.;
    return (width+contraction*breath)*(1.-.21*charge*j.flow.z)*(1.-.128*stroke);
}

float bellHeight(Jelly j, float time, float charge) {
    const float kind = j.pigment.w;
    const float breath = sin(j.pigment.y)+.42*j.pigment.z*sin(time*3.8);
    const float height = kind > 4.5 ? 1.23 : kind > 3.5 ? 1.75 : kind > 2.5 ? .25 :
                         crownShape(kind) ? 1.29 : foldedArms(kind) ? .47 : .87;
    const float stroke = j.membraneAnchor == 1. ? j.trail.w : 0.;
    return height-(.12+.073*j.trail.w*j.flow.z)*breath+.26*charge*j.flow.z+.20*stroke;
}

float bellLobes(float species) {
    return species > 4.5 ? 18. : species > 3.5 ? 5. : species > 2.5 ? 7. :
           species > 1.5 ? 8. : species > .5 ? 12. : 16.;
}

struct BellSurface { float3 point, normal; };
BellSurface sampleBell(Jelly j, float angle, float polar, float width, float height,
                       bool underside, bool needNormal) {
    const float r = sin(polar), c = cos(polar);
    const float lip = pow(r,7.);
    const float lobes = bellLobes(j.pigment.w);
    const float theta = angle*lobes+j.flow.w*tau;
    const float little = angle*(lobes+8.)+j.flow.w*11.6;
    const float phase = j.pigment.y;
    const float st = sin(theta), ct = cos(theta);
    const float slow = angle*3.+.8*sin(phase);
    const float cleft = angle*5.+.64*sin(phase);
    const float petals = j.pigment.w > 2.5 && j.pigment.w < 3.5 ? .25 : 0.;
    const float scallopDepth = .029+petals+.013*sin(slow);
    const float scallop = ct*scallopDepth+.008*cos(little)+.014*cos(cleft);
    const float drift = angle*3.+.86*sin(phase);
    const float base = crownShape(j.pigment.w) ? 1.10 : .98;
    const float spread = pow(r,base)*width;
    const float wall = 1.+lip*scallop+.022*sin(drift)*r*r;
    const float radius = spread*wall;
    const float frill = .045*(st+.20*sin(little+phase))+.026*sin(angle*4.+phase);
    const float neck = r*(1.-r);
    const float furrow = underside ? .038*st : .068*sin(slow);
    const float arch = underside ? -.287*(1.-r*r) : height*c*(.95+.088*r*r);
    const float y = arch+frill*lip+furrow*neck;
    const float3 radial = float3(cos(angle),0,sin(angle));
    const float up = underside ? -1. : 1.;
    const float3 pole = float3(0,up,0);
    BellSurface surface = {radial*radius+float3(0,y,0),pole};
    if (needNormal) {
        const float lipV = 7.*pow(r,6.)*c;
        const float scallopA = -lobes*st*scallopDepth+.039*ct*cos(slow)-
                               .008*(lobes+8.)*sin(little)-.070*sin(cleft);
        const float radiusA = spread*(lip*scallopA+.066*cos(drift)*r*r);
        const float radiusV = base*pow(max(.0001,r),base-1.)*width*c*wall+
                              spread*(lipV*scallop+.044*sin(drift)*r*c);
        const float frillA = .045*(lobes*ct+.20*(lobes+8.)*cos(little+phase))+.104*cos(angle*4.+phase);
        const float furrowA = underside ? .038*lobes*ct : .204*cos(slow);
        const float archV = underside ? .574*r*c : height*(-r*(.95+.088*r*r)+.176*r*c*c);
        const float yA = frillA*lip+furrowA*neck;
        const float yV = archV+frill*lipV+furrow*c*(1.-2.*r);
        const float3 tangent = float3(-radial.z,0,radial.x);
        // The two tangents follow the sculpted surface through every bell contraction.
        const float3 angular = tangent+(float3(0,yA,0)+radial*radiusA)/max(.02,radius);
        const float3 vertical = radial*radiusV+float3(0,yV,0);
        surface.normal = mix(pole,normalize(cross(angular,vertical)*up+pole*.001),smoothstep(0.,.12,r));
    }
    return surface;
}

float3 jellyWorldPoint(float3 local, Jelly j, float width, float height) {
    // The entrance sits at the three-quarter marks of the dome's azimuth and profile.
    if (j.membraneAnchor > 0.) local -= sampleBell(j,.75*tau,.375*pi,width,height,false,false).point;
    local.x += j.flow.x*local.y*.23;
    return j.position.xyz+jellyOrientation(local,j)*j.position.w;
}

float3 tentacleSpine(Jelly j, uint strand, float progress, float width,
                     float h, float linger) {
    const float kind = j.pigment.w;
    const bool disc = foldedArms(kind);
    const bool crown = crownShape(kind);
    const bool ribbon = strand < (disc ? 8u : 4u);
    const float a = float(strand)*2.39996323+j.flow.w;
    const float root = ribbon ? .26 + h*.13 : .65 + h*.34;
    const float speciesSpan = kind > 4.5 ? .70 : kind > 2.5 ? .31 :
                              disc ? .52 : crown ? 1.17 : mix(1.,.76,j.flow.z);
    const float span = (ribbon ? 2.72+1.0*h : 1.65+2.12*h)*speciesSpan;
    const float extension = j.flow.z*(ribbon ? .24 : .60)*smoothstep(.10,.88,progress);
    const float loose = pow(max(.001,progress),1.21);
    const float curl = progress*(ribbon ? 1.2 : .74)*sin(linger+a);
    const float dist = root*width+loose*(.13+.42*h) + .18*loose*sin(linger+.37*sin(linger));
    float3 local = float3(cos(a+curl)*dist,.055-span*progress*(1.+extension),sin(a+curl)*dist);
    local.x += (sin(linger)*.23+j.flow.x*2.1)*loose;
    local.z += cos(linger-.29*sin(linger))*loose*.34;
    return local+jellyLocalVector(j.trail.xyz,j)*float3(.28,.16,.34)*loose;
}

float2 tentacleAttachment(Jelly j, uint strand, float seed, bool oral) {
    const float naturalAngle = float(strand)*2.39996323+j.flow.w;
    if (oral) return float2(naturalAngle,asin(mix(.19,.33,seed)));

    // Gather the fine tentacles into small groups underneath the scallops.
    const float lobes = bellLobes(j.pigment.w);
    const float ridge = naturalAngle*lobes+j.flow.w*tau;
    const float angle = naturalAngle-.79*sin(ridge)/lobes;
    const float radius = strand%2u == 0 ? mix(.87,.96,seed) : mix(.78,.89,seed);
    return float2(angle,asin(radius));
}

constant float attachmentEnd = .38;
float3 attachedSpine(Jelly j, uint strand, float3 freeSpine, float progress, float width,
                     float seed, bool oral, float2 root) {
    const float angle = float(strand)*2.39996323+j.flow.w;
    const float looseRadius = (oral ? .26+.13*seed : .65+.34*seed)*width;
    const float3 original = float3(cos(angle)*looseRadius,.055,sin(angle)*looseRadius);
    const float3 surface = sampleBell(j,root.x,root.y,width,0.,true,false).point;
    // Start inside the membrane and ease back to the existing motion below the bell.
    const float3 buried = surface+float3(0.,oral ? .054 : .037,0.);
    const float blend = 1.-smoothstep(.047,attachmentEnd,progress);
    const float stem = smoothstep(0.,.062,progress)*(1.-smoothstep(.10,attachmentEnd,progress));
    return freeSpine+(buried-original)*blend-float3(0.,(oral ? .035 : .048)*stem,0.);
}
float3 tentacleMark(TrailPose sample, uint strand) {
    const Jelly j = sample.jelly;
    const float fraction = .93;
    const float h = strandSeed(j,strand);
    const float linger = j.pigment.y-fraction*5.1+h*5.9;
    const float width = bellWidth(j,sample.time.x,sample.time.y);
    const float3 local = tentacleSpine(j,strand,fraction,width,h,linger);
    const float height = j.membraneAnchor > 0. ? bellHeight(j,sample.time.x,sample.time.y) : 0.;
    return jellyWorldPoint(local,j,width,height);
}
TrailPose trailAt(device const TrailPose* history, uint4 layout, uint actor, uint past) {
    const uint row = past == 0 ? layout.z : (layout.x+layout.z-past)%layout.z;
    return history[row*layout.w+actor];
}
kernel void makeTrailMarks(device const TrailPose* history [[buffer(0)]],
                           device TrailMark* marks [[buffer(1)]],
                           constant TrailLayout& trails [[buffer(2)]],
                           uint id [[thread_position_in_grid]]) {
    const uint4 layout = trails.history;
    const uint past = id/trails.lines;
    const uint line = id%trails.lines;
    const uint extra = line >= layout.w ? line-layout.w : 0;
    const uint actor = line < layout.w ? line : (extra < 4u ? extra : layout.w-1);
    const uint strand = line < layout.w ? 9u : (extra == 5u ? 2u : 16u);
    const TrailPose sample = trailAt(history,layout,actor,past);
    const Jelly j = sample.jelly;
    if (line+2u >= trails.lines) {
        if (sample.time.z <= 0. || sample.time.w < 1.) {
            marks[id] = {float4(j.position.xyz,sample.time.x),j.position,float4(0)};
            return;
        }
        const uint guest = uint(sample.time.w)-1u;
        const TrailPose crown = trailAt(history,layout,guest,past);
        const float3 playerTip = tentacleMark(sample,9u), guestTip = tentacleMark(crown,9u);
        const float3 gap = guestTip-playerTip;
        const float3 across = normalize(gap+float3(.001,.002,0.));
        const float3 up = normalize(cross(across,float3(.03,.08,1.))+float3(0.,.001,0.));
        const float phase = sample.time.x*2.8;
        const float radius = min(1.25,length(gap)*.24)*sqrt(sample.time.z);
        const bool second = line+1u == trails.lines;
        const float3 twist = (across*cos(phase)+up*sin(phase))*radius*(second ? -1. : 1.);
        marks[id] = {float4((playerTip+guestTip)*.5+twist,sample.time.x),
                     (j.position+crown.jelly.position)*.5,
                     float4(second ? .105 : .48,0.,.80,sample.time.z*1.6)};
        return;
    }
    marks[id] = {float4(tentacleMark(sample,strand),sample.time.x),j.position,
                 float4(j.pigment.x,j.flow.z,j.pigment.z,j.presence*
                         (j.basinTone < 0. ? 1. : mix(.12,1.,j.basinLight)))};
}
vertex Ribbon streakVertex(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                           device const TrailMark* marks [[buffer(5)]],
                           constant TrailLayout& trails [[buffer(6)]]) {
    const uint segment = (id/12)%trails.segments;
    const uint line = (id/12)/trails.segments;
    const float2 uv = patch(id%6,1,1);
    const float u = (float((id/6)%2u)+uv.y)*.5;
    const TrailMark old = marks[(segment+1)*trails.lines+line];
    const TrailMark young = marks[segment*trails.lines+line];
    const float3 jump = old.body.xyz-young.body.xyz;
    const float span = young.tip.w-old.tip.w;
    if (span <= .0001 || dot(jump,jump) > 42. || max(old.light.w,young.light.w) <= 0.)
        return {float4(0,0,-1,1),0,0,0,float4(0)};
    const uint total = trails.history.y;
    const TrailMark before = marks[(segment > 0 ? segment-1 : 0)*trails.lines+line];
    const TrailMark after = marks[min(segment+2,total)*trails.lines+line];
    const bool hasBefore = segment > 0 && distance(before.body.xyz,young.body.xyz) <= 6.5;
    const bool hasAfter = segment+2 <= total && distance(after.body.xyz,old.body.xyz) <= 6.5;
    const float3 p1 = young.tip.xyz, p2 = old.tip.xyz;
    // Scale tangents by the sample times: the live segment grows from zero every capture.
    const float3 c = hasBefore ? (p2-before.tip.xyz)*(span/max(span,before.tip.w-old.tip.w)) : p2-p1;
    const float3 endSlope = hasAfter ? (after.tip.xyz-p1)*(span/max(span,young.tip.w-after.tip.w)) : p2-p1;
    const float3 a = 2.*(p1-p2)+c+endSlope;
    const float3 b = 3.*(p2-p1)-2.*c-endSlope;
    const float3 centre = p1+u*(c+u*(b+u*a));
    const float3 tangent = c+u*(2.*b+u*3.*a);
    const float3 ray = normalize(centre-s.eye.xyz+float3(.00001));
    const float3 side = normalize(cross(tangent,ray)+s.right.xyz*.0001);
    const float age = saturate((s.screen.y-mix(young.tip.w,old.tip.w,u))/trails.lifetime);
    const float hero = young.light.y;
    const float giant = smoothstep(3.1,4.6,young.body.w);
    const float radius = (.047+.038*max(hero,giant))*(1.+age*1.5);
    const float across = uv.x*2.-1.;
    const float3 clip = projectWorld(centre+side*(across*radius),s);
    const float startTaper = segment > 0 && !hasBefore ? smoothstep(0.,1.,u) : 1.;
    const float endTaper = hasAfter ? 1. : 1.-smoothstep(0.,1.,u);
    const float intensity = (.68+.21*giant+.20*hero)*
                            (1.+mix(young.light.z,old.light.z,u)*.48)*
                            mix(young.light.w,old.light.w,u);
    return {float4(clip.xy,clip.z-.25,clip.z),across,clip.z,centre.y,
            float4(age,young.light.x,hero,intensity*startTaper*endTaper)};
}
fragment half4 streakLight(Ribbon in [[stage_in]], constant Scene& s [[buffer(0)]]) {
    if (in.light.w <= 0.) return half4(0.);
    const float age = in.light.x;
    const float hue = in.light.y;
    const float hero = in.light.z;
    const float line = in.across;
    const float n = .5+.5*sin(age*68.+hue*51.);
    const float diffusion = exp(-line*line*5.)*(1.-smoothstep(.78,1.,abs(line)));
    const float loosen = smoothstep(.015,.69,age);
    const float split = (.16+.18*sin(age*25.+hue*38.))*loosen;
    const float filament = exp(-pow((line+split*.21)*6.6,2.));
    const float satellite = exp(-pow((line-split-.12)*7.8,2.))*loosen*diffusion;
    const float gleam = pow(n,7.)*filament;
    const float rise = smoothstep(0.,.033,age);
    const float fade = pow(1.-age,1.45)*(1.-smoothstep(.69,1.,age));
    const float decay = rise*fade*smoothstep(1.,4.3,in.depth)*exp(-in.depth*.017);
    const float3 dye = mix(pigment(hue+.079+.08*age),paletteColour(s.paletteMix,playerRim),hero);
    const bool paintedWorld = s.graphicsStyle == paintedGraphics;
    const float3 trace = paintedWorld ? mix(mix(float3(.46,.65,.78),float3(.90,.52,.43),hero),
                                         float3(.32,.24,.34),age*.61) :
                         mix(dye,pigment(hue+.22),age*.30*(1.-hero));
    const float strength = in.light.w*decay*(1.-s.cycle.z)*s.basinArrival;
    const float radiance = diffusion*(.19-.048*loosen)+filament*.58+gleam*(.23+.55*s.music.z);
    const float3 fringe = mix(trace,paintedWorld ? float3(.75,.73,.78) : s.bright.xyz,.48)*satellite*.26;
    return half4(half3((trace*radiance+fringe)*depthLight(in.height,s)*strength*(1.+.25*s.music.w)),
                 half(strength*diffusion*.22));
}

vertex AnimalFragment jellyVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                  constant Scene& s [[buffer(0)]],
                                  device const Jelly* shoal [[buffer(1)]],
                                  constant uint4& mesh [[buffer(7)]]) {
    const Jelly j = shoal[instance];
    const uint steps = mesh.x, sides = mesh.z, slices = mesh.w;
    const uint rootRows = 4u, rootColumns = 3u;
    const uint rootSize = rootRows*rootColumns*6;
    const uint filamentSize = rootSize+(steps-rootRows)*6;
    const uint armSize = steps*4*6;
    const uint arms = 8*armSize;
    const uint tentacles = arms+(mesh.y-8)*filamentSize;
    const uint organSections = sides/3;
    const uint organSize = organSections*8*6;
    const uint organs = organSize*4;
    const uint lowerShell = sides*(slices/3)*6;
    const float kind = j.pigment.w;
    const float phase = j.pigment.y;
    const bool crown = crownShape(kind);
    const bool comb = foldedArms(kind);
    const bool enclosing = j.flow.z <= 0. && s.enclosingBell.w > 0. && j.position.w == s.enclosingBell.w;
    const float t = enclosing ? s.celestialTime : s.screen.y;
    const float morph = j.flow.z*smoothstep(.04,.51,s.cycle.y);
    const float width = enclosing ? s.enclosingShape.x : mix(bellWidth(j,t,s.call.x),s.enclosingShape.x,morph);
    const float height = mix(bellHeight(j,t,s.call.x),s.enclosingShape.y/.95,morph);
    float3 local, normal;
    float4 shape;
    float2 attachment = 0.;
    if (id < tentacles) {
        const bool folded = id < arms;
        const uint strand = folded ? id/armSize : 8+(id-arms)/filamentSize;
        const uint cell = folded ? id%armSize : (id-arms)%filamentSize;
        const float collar = float(rootRows)/steps;
        float2 uv;
        if (folded) {
            uv = patch(cell,4,steps);
        } else if (cell < rootSize) {
            uv = patch(cell,rootColumns,rootRows);
            uv.y *= collar;
        } else {
            uv = patch(cell-rootSize,1,steps-rootRows);
            uv.y = collar+uv.y*(1.-collar);
        }
        const float h = strandSeed(j,strand);
        const bool ribbon = strand < (comb ? 8u : 4u);
        const float progress = uv.y;
        const float linger = phase-progress*5.1+h*5.9;
        local = tentacleSpine(j,strand,progress,width,h,linger);
        const float naturalAngle = float(strand)*2.39996323+j.flow.w;
        float2 root = float2(naturalAngle,0.);
        if (progress < attachmentEnd) {
            root = tentacleAttachment(j,strand,h,ribbon);
            if (enclosing) {
                const float radial = width*sin(root.y);
                const float3 base = float3(cos(root.x)*radial,-s.enclosingShape.z*cos(root.y),sin(root.x)*radial);
                local = mix(base+float3(0.,-.58*progress,0.),local,smoothstep(0.,attachmentEnd,progress));
            } else {
                local = attachedSpine(j,strand,local,progress,width,h,ribbon,root);
            }
            attachment = float2(root.x,root.y*(2./pi));
        }
        const float x = uv.x*2.-1.;
        if (ribbon) {
            const float unfurl = smoothstep(.021,.25,progress);
            const float freeTurn = float(strand)*2.37;
            const float arc = root.x+pi*.5-freeTurn;
            const float anchorTurn = freeTurn+atan2(sin(arc),cos(arc));
            const float turn = mix(anchorTurn,freeTurn,unfurl)+unfurl*(progress*8.1+sin(linger)*.9);
            const float3 across = normalize(float3(cos(turn),unfurl*.22*sin(turn*1.67),sin(turn)));
            const float3 bow = normalize(cross(across,float3(.18,-1.,.1)));
            const float fold = .50+.50*sin(progress*(30.+h*17.)+2.*linger+turn*x*.21);
            const float rootWidth = (.083+.062*h)*width;
            const float frill = mix(rootWidth,pow(1.015-progress,.65)*(.076+.147*fold),unfurl);
            const float pleat = progress*56.+x*5.+h*12.;
            const float curl = x*x*.48*sin(pleat)*unfurl;
            local += frill*(across*x+bow*((1.-x*x)*mix(.26,.63,unfurl)+curl));
            normal = normalize(bow+across*(x*(.64+unfurl*(.44-.50*cos(pleat))))+
                               float3(0,.30*sin(fold*8.)*unfurl,0));
        } else {
            const float3 across = jellyLocalVector(s.right.xyz,j);
            const float3 toward = jellyLocalVector(-s.forward.xyz,j);
            const float shoulder = 1.-smoothstep(.015,.092,progress);
            const float thickness = (.009+.016*h)*pow(1.007-progress,.56)+
                                    (.023+.016*h)*shoulder*width;
            local += thickness*(across*x+toward*(1.-x*x)*shoulder*.72);
            normal = normalize(toward+across*x*(.80+.86*shoulder));
        }
        shape = float4(uv,ribbon ? 1. : 2.,h);
    } else if (id < tentacles+organs) {
        const uint spot = (id-tentacles)/organSize;
        const float2 uv = patch((id-tentacles)%organSize,organSections,8);
        const float angle = float(spot)*pi*.5+j.flow.w*.9;
        const float a = uv.x*tau;
        const float b = uv.y*tau;
        const float3 radial = float3(cos(angle),0,sin(angle));
        const float3 side = cross(float3(0,1,0),radial);
        const float wing = crown ? .160 : comb ? .113 : .213;
        const float reach = crown ? .311 : comb ? .171 : .225;
        const float offset = crown ? .292 : comb ? .335 : .381;
        const float heart = .99+.115*cos(a)-.088*cos(2.*a);
        local = radial*(offset+reach*cos(a)*heart)+side*(wing*sin(a)*heart);
        local *= width;
        local.y = height*(.36+.14*cos(a))+.038*sin(2.*a+phase);
        const float3 crossRing = normalize(radial*cos(a)+side*sin(a));
        const float3 tube = normalize(crossRing*cos(b)+float3(0,sin(b),0));
        const float pinch = smoothstep(-.94,-.17,cos(a));
        const float thickness = (.017+.047*pinch)*(1.+.23*sin(3.*a+angle));
        local += tube*thickness;
        local.y += .012*sin(4.*a+angle)*sin(b);
        normal = tube;
        shape = float4(uv,4.,(float(spot)+.5)*.25);
    } else {
        const uint b = id-tentacles-organs;
        const bool underside = b < lowerShell;
        const float2 uv = underside ? patch(b,sides,slices/3) : patch(b-lowerShell,sides,slices);
        const BellSurface surface = sampleBell(j,uv.x*tau,uv.y*pi*.5,width,height,underside,true);
        local = surface.point;
        normal = surface.normal;
        shape = float4(uv,underside ? 3. : 0.,0);
    }
    normal.y -= j.flow.x*.23*normal.x;
    normal = jellyOrientation(normal,j);
    const float3 point = jellyWorldPoint(local,j,width,height);
    const float3 clip = projectWorld(point,s);
    const float3 centre = j.membraneAnchor > 0. ? jellyWorldPoint(float3(0.),j,width,height) : j.position.xyz;
    const float4 cosmos = float4(centre,j.bellSystem);
    return {float4(clip.xy,clip.z-.12,clip.z),normal,point,shape,attachment,j.pigment,j.flow,
            j.trail.w,j.position.w,j.presence,float4(j.eclipsing,j.basinLight,j.basinTone,j.membraneAnchor),
            cosmos,float4(width,height,j.pitch,j.bellSystemVisibility)};
}

float periodicLine(float phase, float width) {
    const float d = abs(fract(phase+.5)-.5);
    const float footprint = max(.006,fwidth(phase)*.72);
    return (1.-smoothstep(width,width+footprint,d))*(1.-smoothstep(.19,.57,footprint));
}

float contractionLight(float phase, float delay) {
    const float offset = fract(phase/tau+.125-delay)-.5;
    return exp2(-94.*offset*offset);
}

struct JellyLight {
    half4 weighted [[color(0)]];
    half2 opacity [[color(1)]]; // Membrane opacity and coverage of the moving water details.
};

float3 bellSpaceVector(float3 vector, AnimalFragment in, float3 axes) {
    vector = rotateY(vector,-in.state.y);
    vector.yz = rotatePlane(vector.yz,-in.cosmosShape.z);
    vector.xy = rotatePlane(vector.xy,.27*in.state.x*in.state.z);
    vector.x -= in.state.x*vector.y*.23;
    return vector/axes;
}

float4 bellWindow(AnimalFragment in, constant Scene& s, constant BellSystem* systems,
                  float3 view, float3 normal) {
    if (in.cosmos.w <= 0. || in.cosmosShape.w <= 0. || (in.shape.z != 0. && in.shape.z != 3.))
        return float4(0.);
    const float pixel = s.orbitalPixel;
    const float3 offset = s.eye.xyz-in.cosmos.xyz;
    const float resolved = smoothstep(4.,13.,in.scale/max(.12,length(offset)*pixel));
    if (resolved <= 0.) return float4(0.);
    const float3 axes = float3(in.cosmosShape.x,max(.19,in.cosmosShape.y)/.85,in.cosmosShape.x);
    const float3 eye = bellSpaceVector(offset/in.scale,in,axes);
    const float3 direction = normalize(bellSpaceVector(-view,in,axes));
    const float inside = 1.-smoothstep(.91,1.08,length(eye/float3(1.,eye.y>=0. ? .85 : .24,1.)));
    const float facing = mix(smoothstep(.01,.29,dot(normal,view)),1.,inside);
    if (facing <= 0.) return float4(0.);
    // Use a smooth optical surface independent of which triangles the current render tier draws.
    const float3 shell = float3(1.,.86,1.);
    const float3 p = eye/shell, d = direction/shell;
    const float a = dot(d,d), b = dot(p,d);
    const float entry = max(0.,(-b-sqrt(max(0.,b*b-a*(dot(p,p)-1.))))/a);
    const float membrane = entry*(1.-inside);
    const bool player = in.state.z > 0.;
    return containedSky(eye,direction,membrane,pixel,systems[uint(in.cosmos.w)-1u],
                        player ? in.cosmosShape.w : 1.)*(resolved*facing*(player ? 1. : in.cosmosShape.w));
}

void combineBellWindow(thread float3& light, thread float& opacity, float4 pocket) {
    light = mix(light,pocket.rgb*.72,.80*pocket.w)+pocket.rgb*.20;
    opacity = max(opacity,.68*pocket.w);
}

float playerFlowCoverage(AnimalFragment in, float visibility) {
    const float cover = in.state.z*smoothstep(0.,.18,visibility);
    if (in.shape.z != 1. && in.shape.z != 2.) return cover;
    const float across = 1.-smoothstep(.58,1.,abs(in.shape.x*2.-1.));
    const float along = smoothstep(0.,.043,in.shape.y)*(1.-smoothstep(.89,1.,in.shape.y));
    return cover*across*along;
}

JellyLight paintedJelly(AnimalFragment in, constant Scene& s, float3 view, float silhouette,
                       float visibility, float weight, float4 pocket) {
    const float2 uv = in.shape.xy;
    const float kind = in.shape.z;
    const float hero = in.state.z;
    const float facing = dot(normalize(in.normal+float3(.0001)),view);
    const float grazing = pow(1.-saturate(abs(facing)),2.1);
    const float facingLight = saturate(.51+.42*dot(in.normal,s.sun.xyz));
    const float angle = uv.x*tau;
    const bool trail = kind == 1. || kind == 2.;
    const float2 domain = trail || kind == 4. ? uv*float2(4.2,18.4) :
                          float2(cos(angle),sin(angle))*sin(uv.y*pi*.5)*11.5;
    const float2 marks = paintStrokes(domain+in.state.w*17.2);
    const float brush = smoothstep(.24,.77,marks.y);
    const float load = saturate(.14+.53*facingLight+.31*marks.x+.19*(brush-.5));
    const float3 slate = float3(.23,.28,.39);
    const float3 blue = float3(.52,.67,.76);
    const float3 chalk = mix(float3(.79,.87,.91),float3(.96,.89,.81),.25+.70*hero);
    const float3 coral = mix(float3(.69,.34,.39),float3(.96,.49,.37),marks.x);
    const float warm = saturate(.63*hero+.34*in.state.w+.12*(in.pigment.w > .5));
    const float3 underpaint = mix(mix(slate,blue,marks.x),float3(.52,.34,.43),warm*.52);
    float3 colour = mix(underpaint,chalk,load);
    const float accent = smoothstep(.52,.82,marks.x+.17*(brush-.5))*warm;
    float opacity;
    float rim = 0.;

    if (trail) {
        const float side = 1.-abs(uv.x*2.-1.);
        const float taper = pow(saturate(1.-uv.y),.53);
        const float root = smoothstep(.013,.072,uv.y);
        colour = mix(colour,coral,mix(.24,.61,brush)*warm);
        opacity = side*taper*root*(.49+.22*brush+.08*hero);
        rim = side*taper*.22;
    } else if (kind == 4.) {
        colour = mix(float3(.30,.18,.26),coral,load*.63);
        opacity = .52+.14*brush;
    } else {
        const float broken = uv.y+.049*(marks.y-.5);
        rim = smoothstep(.86,.99,broken);
        const float dryEdge = grazing*(.29+.52*brush);
        colour = mix(colour,coral,accent*(.49+.22*rim));
        colour = mix(colour,chalk,max(.78*rim,dryEdge));
        const float wash = .5+.5*sin(angle*2.+in.pigment.y+marks.x*3.1);
        colour = mix(colour,mix(blue,chalk,wash),rim*grazing*(.15+.22*brush));
        opacity = (kind == 3. ? .39 : .60)+.12*brush+.14*rim+.07*hero;
    }

    if (in.lighting.x > 0.) {
        const float relay = contractionLight(in.pigment.y,trail ? .29+.64*uv.y : .25*(1.-uv.y));
        const float3 shadow = mix(float3(.061,.066,.099),float3(.24,.23,.33),marks.x);
        colour = mix(shadow,chalk,saturate(rim*(.44+.52*relay)+grazing*.31));
    }
    if (in.lighting.z >= 0.) {
        const float3 distanceTint = mix(float3(.69,.62,.49),blue,in.lighting.z);
        colour = mix(colour,distanceTint,.36)*mix(.27,1.,in.lighting.y);
        opacity *= mix(.45,1.,in.lighting.y);
    }
    const float3 distant = mix(float3(.046,.062,.107),blue,(rim*.62+grazing*.18)*(.57+.43*brush));
    colour = mix(colour,distant,silhouette);
    combineBellWindow(colour,opacity,pocket);
    const float a = saturate(opacity)*visibility;
    return {half4(half3(colour*(a*weight)),half(a*weight)),half2(a,playerFlowCoverage(in,visibility))};
}

struct BellOptics { float opacity; float3 light; };

BellOptics colossalOptics(AnimalFragment in, constant Scene& s, float3 view, float3 normal,
                          float rim, float3 dye, float3 phosphor) {
    const float2 uv = in.shape.xy;
    const float time = s.screen.y;
    const float angle = uv.x*tau;
    const uint gate = uint(in.lighting.w)-1u;
    const float4 passage = s.passages[gate];
    const float3 offset = in.world-passage.xyz;
    const float detailScale = clamp(18./in.scale,.042,.53);
    const float face = dot(normal,view);
    const float3 inward = refract(-view,face < 0. ? -normal : normal,.78);
    const float2 shell = float2(offset.x+.24*offset.z,offset.y-.16*offset.z)*detailScale;
    const float2 bend = float2(inward.x+.24*inward.z,inward.y-.16*inward.z);
    const float2 pocket = shell+bend*1.26;
    const float2 drift = shell+bend*3.83+float2(2.1,-1.6);
    const float2 veins = refractedWater(pocket,time*.19,length(fwidth(pocket)));
    const float2 eddies = refractedWater(drift*.59,-time*.14,length(fwidth(drift))*.59);
    const float wash = noise(drift*.44+float2(0.,time*.021));
    const float wave = pocket.y+.39*sin(.79*pocket.x-time*.21)+.64*wash;
    const float surface = exp2(-2.6*(wave-.82)*(wave-.82));
    const float waterline = exp2(-19.*(wave-.94)*(wave-.94));
    const float trough = (1.-smoothstep(-1.6,.87,wave))*(.41+.59*wash);

    const float seam = uv.x*18.+uv.y*(.22*sin(angle*6.+uv.y*7.2)+.16*sin(angle*11.-uv.y*14.));
    const float channels = periodicLine(seam,.028)*smoothstep(.15,.73,uv.y);
    const float fork = .18*sin(uv.y*19.+angle*5.);
    const float branches = periodicLine(seam+fork,.024)*smoothstep(.46,.94,uv.y);
    const float sleeve = exp2(-460.*(uv.y-.968)*(uv.y-.968));
    const float pulse = contractionLight(in.pigment.y,.36+.53*uv.y);
    const float filmPhase = 3.7*abs(face)+2.9*wash+.17*sin(angle*6.);
    const float3 film = .48+.52*cos(filmPhase+float3(.08,2.32,4.01));
    const float3 entranceLight = s.passageColours[gate].xyz;
    const float3 enamel = mix(dye,entranceLight,.72);
    const float3 gleam = mix(entranceLight,float3(1.,.94,.86),.29);
    const float3 opal = mix(enamel,gleam,smoothstep(.22,.79,wash+.09*veins.x));
    const float3 shadow = mix(dye,entranceLight,.46)*.7;
    const float3 livingLight = mix(opal,mix(entranceLight,phosphor,.27),.17+.32*pulse);

    // A sparse third layer of drifting organisms gives the flooded bell a sense of depth.
    const float2 reef = drift*1.64+float2(time*.018,-time*.040);
    const float seed = hash21(floor(reef));
    const float moteSize = mix(.044,.124,seed*seed);
    const float2 local = fract(reef)-float2(.24+.49*seed,.5);
    const float fleck = 1.-smoothstep(moteSize*.37,moteSize,length(local*float2(.76,1.7)));
    const float slip = local.x+.024*sin(local.y*35.+seed*42.-time);
    const float filament = exp2(-slip*slip*3400.)*smoothstep(.005,.030,local.y)*
                           (1.-smoothstep(.034,.15,local.y));
    const float shoal = smoothstep(.66,.96,seed)*(.77*fleck+.36*filament)*
                        (1.-smoothstep(.027,.16,length(fwidth(reef))))*(.24+.76*eddies.x);

    const float aperture = length(offset*float3(1.,1.13,.42))/passage.w;
    const float opening = 1.-smoothstep(.53,1.13,aperture);
    const float shore = exp2(-66.*(aperture-.94)*(aperture-.94))*(.19+.81*veins.x);
    const float depthLight = (.14*veins.x+.25*veins.y)*(.15+.85*surface)+.28*waterline;
    const float3 flood = shadow*(.016+.088*trough+.11*eddies.x)+
                         opal*(depthLight+.19*shore)+enamel*.19*eddies.y*trough;
    const float3 skin = livingLight*(channels*(.092+.19*pulse)+branches*.068+.37*sleeve)+
                        mix(opal,film,.26)*rim*.53;
    const float eclipse = (gate == 0u ? in.synchrony : 0.)*(.38+.58*abs(face));
    const float density = mix(.18+.17*wash+.12*trough+.20*rim+.14*sleeve,.985,eclipse);
    const float opacity = density*(1.-.80*opening);
    const float3 light = ((flood+skin+opal*shoal*.52)*(1.-.64*eclipse)+
                          gleam*eclipse*(.35*rim+.24*channels))*(1.-.71*opening);
    return {opacity,light};
}

JellyLight interiorCreature(AnimalFragment in, constant Scene& s, float3 view,
                           float visibility, float weight, float distance, float4 pocket) {
    const float2 uv = in.shape.xy;
    const float angle = uv.x*tau;
    const float time = s.screen.y;
    const float phase = in.pigment.y;
    const float species = in.pigment.w;
    const bool bell = species > 4.5;
    const bool tendril = in.shape.z == 1. || in.shape.z == 2.;
    const float3 facing = normalize(in.normal+float3(.0001));
    const float rim = pow(1.-saturate(abs(dot(facing,view))),2.35);
    const float3 base = pigment(in.pigment.x);
    const float3 light = mix(base,s.bright.xyz,bell ? .42 : .28);
    const float3 glint = mix(light,s.sunlight.xyz,.27);
    float opacity;
    float3 glow;
    if (tendril) {
        const float edge = 1.-abs(uv.x*2.-1.);
        const float taper = edge*pow(saturate(1.-uv.y),.7)*smoothstep(0.,.053,uv.y);
        const float droplets = contractionLight(phase,.12+.64*uv.y+.13*in.shape.w);
        const float strands = periodicLine(uv.x*4.+.16*sin(20.*uv.y-phase),.064);
        opacity = taper*(.25+.20*strands)*(bell ? .61 : 1.);
        glow = taper*(light*(.16+.37*strands)+glint*rim*.36+droplets*glint*.28);
    } else if (bell && in.lighting.w > 0. && in.lighting.w < float(bellPassageCount) && in.shape.z != 4.) {
        const BellOptics optics = colossalOptics(in,s,view,facing,rim,base,light);
        const bool underside = in.shape.z == 3.;
        opacity = optics.opacity*(underside ? .66 : 1.);
        glow = optics.light*(underside ? .72 : 1.);
    } else if (bell) {
        const float2 radial = float2(cos(angle),sin(angle));
        float2 liquid = radial*(.48+3.9*uv.y);
        liquid += .36*view.xy;
        const float wash = fbm(liquid*2.15+float2(.017*time,-.010*time));
        const float surface = .49+.12*sin(liquid.x*1.25+time*.085)+.091*wash;
        const float tide = liquid.y*.17+.45-surface;
        const float horizon = exp(-abs(tide)*31.);
        const float refraction = exp(-abs(sin(tide*32.+wash*5.4+time*.36))*5.);
        const float sleeve = exp2(-390.*(uv.y-.963)*(uv.y-.963));
        const float seams = periodicLine(uv.x*18.+.12*sin(19.*uv.y-phase),.047);
        const float2 address = liquid*3.4+float2(0.,time*.11);
        const float2 cell = floor(address);
        const float seed = hash21(cell);
        const float2 local = fract(address)-float2(.30+.39*seed,.52);
        const float young = 1.-smoothstep(.10,.21,length(local*float2(1.,1.7)));
        const float stems = exp(-abs(local.x+.05*sin(local.y*24.+phase))*32.)*
                            smoothstep(.02,.07,local.y)*(1.-smoothstep(.12,.37,local.y));
        const float shoal = smoothstep(.35,.80,seed)*(young+stems*.47)*(1.-smoothstep(.12,.31,length(fwidth(address))));
        float hole = 0.;
        if (in.lighting.w > 0.) {
            const float4 passage = s.passages[uint(in.lighting.w)-1u];
            const float3 reach = (in.world-passage.xyz)*float3(1.,1.13,.42);
            hole = 1.-smoothstep(.58,1.1,length(reach)/passage.w);
        }
        opacity = (.16+.16*wash+.18*rim+.14*sleeve)*(1.-.74*hole);
        const float3 sea = mix(base,light,.24+.58*wash);
        const float3 tinyLife = mix(float3(.096,.84,.69),float3(1.,.61,.22),smoothstep(.53,.89,seed));
        glow = sea*(.055+.15*refraction+.40*horizon)+light*(.34*rim+.34*sleeve+.12*seams)+tinyLife*shoal*.64;
        glow *= 1.-.47*hole;
        if (in.shape.z == 4.) { opacity *= .57; glow *= .43; }
    } else {
        const bool lantern = species > 3.5;
        const float seams = periodicLine(uv.x*bellLobes(species)+.14*sin(uv.y*12.+phase),.063);
        const float rings = periodicLine(uv.y*(lantern ? 7. : 4.)-.15*sin(phase+2.*angle),.072);
        const float pulse = contractionLight(phase,.2+.53*uv.y);
        const float enamel = exp2(-74.*(uv.y-.90)*(uv.y-.90));
        opacity = .13+.23*rim+.21*seams+.09*rings;
        glow = base*(.14+.26*seams)+light*(.26*rim+.22*rings+.31*enamel)+
               glint*pulse*(lantern ? .66*rings : .48*seams);
    }
    combineBellWindow(glow,opacity,pocket);
    const float distanceScale = in.lighting.w > 0. ? max(1.,in.scale/40.) : 1.;
    const float fog = exp(-(distance/distanceScale)*(bell ? .0046 : .014));
    const float a = opacity*visibility*fog;
    const float3 colour = mix(glow,s.deep.xyz*.22,1.-fog);
    return {half4(half3(colour*visibility*fog*weight),half(a*weight)),half2(a,0.)};
}

fragment JellyLight jellyMembrane(AnimalFragment in [[stage_in]], constant Scene& s [[buffer(0)]],
                                  constant BellSystem* systems [[buffer(1)]],
                                  texture2d<half> waterLight [[texture(0)]]) {
    constexpr sampler sampleWater(coord::normalized,address::clamp_to_edge,filter::linear);
    const float3 offset = s.eye.xyz-in.world;
    const float distance = length(offset);
    const float3 view = offset/max(.0001,distance);
    if (in.state.z <= 0. && s.enclosingBell.w > 0. && in.scale == s.enclosingBell.w) {
        const float2 uv = saturate(in.shape.xy);
        const float edge = 1.-abs(uv.x*2.-1.);
        const float taper = smoothstep(.01,.12,uv.y)*(1.-smoothstep(.78,1.,uv.y));
        const float phase = uv.x*3.+.15*sin(uv.y*23.-in.pigment.y);
        const float strandDetail = 1.-smoothstep(.12,.51,fwidth(phase));
        const float ribs = .44+.44*cos(phase*tau)*strandDetail;
        const float pulse = contractionLight(in.pigment.y,.13+.64*uv.y+.11*in.shape.w);
        const float3 tint = mix(float3(.18,.81,.71),float3(.97,.31,.47),smoothstep(.23,.83,in.shape.w));
        const float presence = in.presence*(1.-smoothstep(5.4,8.2,distance/in.scale));
        const float opacity = presence*taper*edge*(.25+.33*ribs);
        const float surge = s.cycle.y > .36 ? exp2(-42.*powr(abs(uv.y-(s.cycle.y-.36)*2.2),2.))*
            (1.-smoothstep(.78,.94,s.cycle.y)) : 0.;
        const float3 lit = tint*(.24+.49*ribs+.51*pulse)+s.sunlight.xyz*(.083+.13*pulse)+
                           mix(tint,float3(.65,.91,1.),.50)*(1.4*surge*ribs);
        return {half4(half3(lit*opacity),half(opacity)),half2(opacity,0.)};
    }
    const float largest = smoothstep(9.,13.,in.scale);
    const float morphScale = s.cycle.y > 0. && in.state.z > 0. ? max(1.,in.scale/1.25) : 1.;
    const float silhouette = largest*smoothstep(43.,126.,distance/morphScale);
    const float depth = exp(-distance/morphScale*mix(.015,.0076,silhouette));
    const float nearPlane = -dot(offset,s.forward.xyz);
    const float distanceScale = in.lighting.w > 0. ? max(1.,in.scale/40.) : morphScale;
    const float hero = in.state.z;
    const float visibility = in.presence*smoothstep(.24,2.7,nearPlane)*
                             (1.-smoothstep(mix(71.,148.,largest),mix(107.,224.,largest),distance/distanceScale));
    if (visibility <= 0.) return {half4(0.),half2(0.)};
    const float weight = .048+1.7*exp2(-.091*max(0.,nearPlane));
    const float3 bellNormal = normalize(in.normal+float3(.0001));
    const float4 pocket = bellWindow(in,s,systems,view,bellNormal);
    const float3 column = mix(depthLight(in.world.y,s),float3(1.),.36*hero);
    if (in.pigment.w > 2.5 || s.graphicsStyle == paintedGraphics) {
        JellyLight result = in.pigment.w > 2.5 ? interiorCreature(in,s,view,visibility,weight,distance,pocket) :
                            paintedJelly(in,s,view,silhouette,depth*visibility,weight,pocket);
        result.weighted.rgb *= half3(column);
        return result;
    }
    const float2 uv = in.shape.xy;
    const float clock = s.screen.y;
    const float currentContrast = hero*s.habitat.w;
    const float kind = in.pigment.w;
    const float rz = uv.y;
    const float angle = uv.x*tau;
    const float hueSeed = in.pigment.x+.022*sin(clock*.076+in.state.w*tau);
    const float hue = hueSeed+.065*cos(angle+rz*3.2);
    const float3 prism = pigment(hue);
    const float basinTone = in.lighting.z;
    const float eclipsing = in.lighting.x;
    const float3 bellDye = paletteColour(s.paletteMix,playerBody);
    const float3 rimDye = paletteColour(s.paletteMix,playerRim);
    float3 dye = mix(prism,bellDye,hero);
    float3 flare = mix(pigment(hue+.12),rimDye,hero);
    if (basinTone >= 0.) {
        const float3 gold = float3(.93,1.,.012);
        const float3 turquoise = float3(.009,1.,.62);
        const float3 blue = float3(.022,.24,1.);
        const float3 lantern = mix(mix(gold,turquoise,smoothstep(.16,.59,basinTone)),blue,
                                   smoothstep(.52,.96,basinTone));
        dye = mix(dye,lantern,.74);
        flare = mix(flare,lantern,.84);
    }
    const float beat = pow(saturate(.5+.5*sin(in.pigment.y)),3.)*in.synchrony;
    const float pulse = 1.+1.03*in.pigment.z+.59*beat+.64*s.call.x*hero;
    const float shimmer = pow(saturate(.5+.5*sin(angle*13.+rz*42.-clock*4.4)),4.);
    const float3 phosphor = mix(flare,s.bright.xyz,beat*.46)*pulse*
                           (1.+s.music.z*(.16+.55*shimmer)+.20*s.music.w);
    const float3 normal = bellNormal;
    const float ndv = dot(normal,view);
    const float facing = smoothstep(-.18,.18,ndv);
    const float edge = 1.-saturate(abs(ndv));
    const float fresnel = pow(edge,3.8);
    const float3 sun = normalize(s.sun.xyz);
    const float3 halfVector = normalize(view+sun+float3(.00011,.00007,.00013));
    const float shine = abs(dot(normal,halfVector));
    const float sunAngle = dot(normal,sun)*(2.*facing-1.);
    const float morning = saturate(sunAngle*.54+.45);
    const float backlight = saturate(-sunAngle*.72+.37);
    const float3 sheen = mix(s.sunlight.xyz,float3(.21,.62,1.),.32);
    const float3 eclipseTint = mix(s.sunlight.xyz,float3(.08,.70,1.),.67);
    float3 radiance;
    float opacity;

    if (in.shape.z == 1. || in.shape.z == 2.) {
        const float side = 1.-abs(uv.x*2.-1.);
        const float x = (uv.x-.5)*6.;
        const float silk = exp(-x*x);
        const float tap = pow(saturate(1.-rz),.43);
        const float flow = rz*10.-clock*.77+in.shape.w*4.67;
        const float pearls = pow(saturate(.5+.5*sin(flow*tau)),8.);
        const float threadline = periodicLine(uv.x*4.+.19*sin(uv.y*40.+flow),.045);
        const float joint = 1.-smoothstep(.028,in.shape.z == 1. ? .235 : .13,rz);
        const float sharedHue = hueSeed+.065*cos(in.attachment.x+in.attachment.y*3.2);
        const float3 sharedDye = mix(pigment(sharedHue),bellDye,hero);
        const float3 sharedLight = mix(pigment(sharedHue+.12),rimDye,hero)*pulse;
        if (in.shape.z == 1.) {
            const float pleat = rz*11.4+in.shape.w*12.+1.35*abs(x*.18)+.19*sin(rz*49.);
            const float ridges = periodicLine(pleat,.085);
            const float fibre = periodicLine(uv.x*8.+.18*sin(rz*34.+uv.x*6.),.028);
            const float edgeBinding = exp(-pow((abs(x)-2.38)*3.3,2.));
            const float centre = exp(-x*x*12.);
            const float3 iris = pigment(hue+.105+.12*sin(pleat*tau)*fresnel);
            const float3 lit = mix(dye,iris,.16+.35*morning);
            const float foldShadow = smoothstep(.24,.74,.50+.50*sin(pleat*tau))*(.32+.68*silk);
            const float nacre = pow(saturate(shine-.11*foldShadow),13.);
            opacity = tap*(side*(.29+.26*silk+.13*ridges+.12*foldShadow)+edgeBinding*.21);
            radiance = lit*opacity*(.071+.22*morning+.21*backlight)*(1.-.37*foldShadow) +
                       phosphor*tap*(side*(.11+.21*fibre+.24*ridges)+
                                     centre*(.16+.36*pearls)+edgeBinding*(.21+.15*ridges)) +
                       mix(sheen,iris,.41)*opacity*(.18*nacre+.17*pow(shine,33.)+.072*ridges*backlight);
            const float stem = side*(.12+.15*fibre)+centre*.15;
            const float joinedOpacity = side*(.28+.26*silk+.06*fibre);
            const float3 joinedLight = sharedDye*joinedOpacity*(.14+.27*morning)+
                                       sharedLight*stem+sheen*pow(shine,25.)*side*.075;
            opacity = mix(opacity,joinedOpacity,joint);
            radiance = mix(radiance,joinedLight,joint);
        } else {
            const float lumen = exp(-x*x*5.5);
            const float knot = pearls*(.52+.48*sin(rz*9.5+in.shape.w*18.));
            const float3 filament = mix(phosphor,pigment(hue+.17),.25+.17*sin(flow));
            opacity = side*tap*(.23+.28*lumen+.22*knot);
            radiance = dye*opacity*.20+filament*tap*side*(.08+.30*threadline+.64*knot*lumen)+
                       sheen*silk*pow(shine,27.)*tap*.14;
            const float heel = side*(.18+.28*lumen+.09*fresnel);
            const float3 collarLight = heel*(sharedDye*(.22+.30*morning)+sharedLight*(.22+.34*lumen));
            opacity = mix(opacity,heel,joint);
            radiance = mix(radiance,collarLight,joint);
        }
        const float trim = currentContrast*tap*side;
        const float travellingLight = contractionLight(in.pigment.y,.20+.64*rz);
        const float3 ribbonLight = mix(sharedLight,sheen,.28+.24*backlight);
        radiance += ribbonLight*travellingLight*tap*side*silk*(1.-joint)*(.11+.14*hero);
        opacity += trim*(.065+.060*silk);
        radiance += sharedLight*trim*(.088+.055*joint);
        if (eclipsing > 0.) {
            const float relay = contractionLight(in.pigment.y,.29+.64*rz);
            const float stem = silk*side*(.25+.75*joint);
            radiance = radiance*.23+eclipseTint*(relay*.94+.11*backlight)*stem*tap;
        }
        // The first rows sit within the bell and pick up their opacity as they emerge.
        const float emergence = mix(.06,1.,smoothstep(0.,in.shape.z == 1. ? .044 : .037,rz));
        opacity *= emergence;
        radiance *= emergence;
    } else if (in.shape.z == 4.) {
        const float folds = periodicLine(uv.x*19.+.23*sin(rz*tau+angle*3.),.067);
        const float inner = smoothstep(.07,.74,sin(rz*tau));
        const float flow = pow(saturate(.5+.5*sin(angle*2.-clock*1.36+in.shape.w*tau)),5.);
        const float3 warm = mix(phosphor,float3(1.,.20,.038)*pulse,.17+.18*hero);
        const float3 tissue = mix(dye*.65,warm,.39+.13*inner);
        const float3 tissueEdge = mix(warm,sheen,.40);
        opacity = mix(.35,.63,facing)+.12*fresnel+.07*folds;
        radiance = tissue*opacity*(.075+.35*morning+.18*inner) +
                   warm*(.041+.23*folds+.31*flow*inner)*opacity+
                   tissueEdge*fresnel*(.035+.13*folds)*opacity+
                   sheen*(pow(shine,42.)*.17+pow(shine,8.)*.027);
        if (eclipsing > 0.) radiance *= .24;
    } else {
        const bool underside = in.shape.z == 3.;
        const bool comb = kind >= 1.5;
        const float count = bellLobes(kind);
        const float warp = rz*(.25*sin(angle*3.+rz*5.6)+.11*sin(angle*5.-rz*18.+in.state.w*4.));
        const float canals = uv.x*count+warp;
        const float fork = .35*sin(rz*11.+angle*3.)*smoothstep(.30,.69,rz);
        const float primary = periodicLine(canals,.027+.018*rz)*smoothstep(.12,.49,rz);
        const float vein = (periodicLine(canals+fork,.016)+periodicLine(canals-fork,.016))*
                           smoothstep(.44,.83,rz)*.5;
        const float filaments = periodicLine(canals*3.+.12*sin(rz*42.+angle*5.),.024)*
                                (.18+.82*pow(saturate(.5+.5*cos(canals*tau)),2.));
        const float lip = smoothstep(.72,.98,rz);
        const float rim = exp(-pow((rz-.983)*39.,2.));
        const float rimThreads = periodicLine(rz*16.4+.15*cos(canals*tau),.032)*lip;
        const float2 tissueUV = float2(cos(angle),sin(angle))*(.49+rz*5.8);
        const float texture = fbm(tissueUV*1.7+float2(rz*13.,in.state.w*9.));
        const float micro = noise(tissueUV*8.6+in.state.w*4.4);
        const float granules = smoothstep(.70,.89,micro)*(1.-smoothstep(.06,.37,length(fwidth(tissueUV))));
        const float travel = pow(saturate(.5+.5*sin(rz*22.-clock*2.13+warp*3.)),3.);
        const float cilia = periodicLine(canals,.062)*(.34+.66*travel)*
                           (.22+.78*periodicLine(rz*12.5-clock*.68,.12));
        const float thickness = .59+.41*texture-.28*rz*rz;
        const float spectrum = .52+.27*cos(13.*edge+rz*7.+4.*texture)+.18*sin(18.*edge-rz*9.);
        float3 film = pigment(hue+.045+.36*spectrum);
        const float opticalPath = (1.7+3.1*thickness)*sqrt(max(0.,1.-.48*edge*edge))+.55*texture;
        const float3 interference = .54+.46*cos(opticalPath*float3(1.38,1.68,2.04)+hue*4.2);
        film = mix(film,film*(.38+.62*interference)+interference*.24,.28+.29*fresnel);
        if (hybridWater(s)) {
            const float swirl = angle*2.+rz*7.4+1.45*texture-clock*.23+hueSeed*5.1;
            film = mix(film,hybridPrism(swirl),.27+.27*fresnel);
        }
        const float3 gel = mix(dye*.76,mix(float3(.053,.15,.54),s.water.xyz,.37),.08+.29*texture);
        const float3 iridescence = mix(film,phosphor,.37+.18*clamp(hero,0.,1.));
        const float3 shellLight = mix(sheen*.91,iridescence,.38+.39*fresnel);
        const float structure = (comb ? .24*cilia : (.124+.064*travel)*primary) +
                                vein*.093+filaments*.037;
        opacity = (underside ? .061+.13*fresnel+.086*rim :
                              .062+.20*thickness*(.50+.50*facing)+.20*fresnel+.081*rim);
        opacity *= mix(.53,1.,facing);
        opacity += .11*structure;
        const float backScatter = .27*backlight*(.32+.68*texture);
        const float volume = .10+.13*texture+.24*morning+backScatter;
        const float wetness = .73+.27*noise(tissueUV*4.1+float2(texture,in.state.w*9.));
        const float polished = pow(shine,55.)*(.20+.32*wetness)+pow(shine,13.)*.071;
        const float bellRim = rim*(.20+.086*travel+.071*texture)+.095*rimThreads;
        const float pearlBand = exp2(-1350.*(rz-.952)*(rz-.952));
        const float pearls = periodicLine(uv.x*count*3.+.13*sin(angle*3.+rz*7.),.103)*pearlBand;
        const float arc = contractionLight(in.pigment.y,.16+.25*cos(angle*2.));
        const float3 pearlTint = mix(iridescence,sheen,.27+.26*morning);
        const float3 innerGlow = mix(gel,s.sunlight.xyz,.28)*backlight*(.045+.12*thickness)*opacity;
        const float3 lipLight = mix(film,sheen,.53)*(.17+.21*morning)*
                                rim*(.33+.67*pow(shine,5.));
        radiance = gel*opacity*volume +
                   (phosphor*structure+iridescence*(bellRim+fresnel*(.088+.11*texture)))*
                        mix(.56,1.,facing) +
                   shellLight*(polished+granules*(.008+.066*pow(shine,13.))) + innerGlow+lipLight +
                   pearlTint*pearls*(.085+.14*arc+.11*hero)*(.36+.64*facing);
        if (underside) {
            const float radial = sin(rz*pi*.5);
            const float oralWeb = smoothstep(.03,.22,radial)*(1.-smoothstep(.35,.53,radial));
            const float margin = smoothstep(.69,.84,radial)*(1.-smoothstep(.955,.996,radial));
            const float ribs = periodicLine(uv.x*count+in.state.w,.066);
            const float mesh = oralWeb*(.45+.55*texture)+margin*(.37+.63*ribs);
            opacity += .088*mesh;
            radiance += (dye*(.08+.13*morning)+phosphor*(.050+.13*ribs))*mesh;
        }
        if (eclipsing > 0.) {
            const float relay = contractionLight(in.pigment.y,.25*(1.-rz));
            const float transmission = rim*(.29+.36*morning)+
                                       fresnel*(.07+.62*backlight)*mix(.62,1.,lip);
            const float path = primary*.62+vein*.29+rim*.73;
            radiance = radiance*.18+eclipseTint*(transmission+path*relay*1.06);
            opacity = max(opacity,.48+.15*(1.-fresnel));
        }
        // In fast water, let the player's pigment hold against the bright cyan behind the bell.
        const float tintedGel = currentContrast*(.103+.053*fresnel+.048*rim);
        opacity += tintedGel;
        radiance += dye*(tintedGel*.24)+flare*currentContrast*(.095*rim+.046*primary+.075*fresnel);
        if (silhouette > 0.) {
            const float3 ink = mix(s.deep.xyz,float3(.013,.039,.106),.67);
            const float3 farRim = mix(float3(.035,.20,.55),s.bright.xyz,.16);
            const float shell = .39+.15*fresnel+.072*rim;
            opacity = mix(opacity,max(opacity,shell),silhouette);
            radiance = mix(radiance,ink*(.42*opacity)+farRim*(.21*rim+.12*fresnel+.050*primary),
                           silhouette);
        }
        if (ndv > 0. && visibility > .001 && silhouette < 1.) {
            const float2 screenSize = float2(waterLight.get_width(),waterLight.get_height());
            const float2 screenUV = in.p.xy/screenSize;
            const float2 surfaceRipple = float2(texture-.5,micro-.5)*.18;
            const float2 bend = (float2(dot(normal,s.right.xyz),-dot(normal,s.up.xyz))+surfaceRipple)/
                                  float2(s.screen.x,1.)
                              * min(.64,in.scale/max(2.,distance))*(underside ? .094 : .162)
                              * (.67+.60*texture)*(.54+.46*ndv);
            const float spread = .085+.19*lip+.15*edge;
            const float3 lens = float3(waterLight.sample(sampleWater,screenUV+bend*(1.+spread)).r,
                                      waterLight.sample(sampleWater,screenUV+bend).g,
                                      waterLight.sample(sampleWater,screenUV+bend*(1.-spread)).b);
            const float transparency = (.11+.18*edge)*(1.-opacity)*smoothstep(0.,.26,ndv)*
                                       (1.-.78*eclipsing)*(1.-.36*currentContrast)*(1.-silhouette);
            const float3 absorption = exp2(-thickness*(1.-mix(dye,film,.25))*(1.39+.57*edge));
            radiance += lens*absorption*transparency;
            opacity += transparency;
        }
    }
    combineBellWindow(radiance,opacity,pocket);
    if (basinTone >= 0.) {
        radiance *= mix(.10,1.31-.12*basinTone,in.lighting.y);
    } else {
        radiance *= mix(1.,.50+.28*hero+.45*eclipsing,s.habitat.y);
    }
    const float deepWater = 1.-exp(-max(0.,distance-12.)*.016);
    const float3 attenuation = mix(float3(1),.50+.50*s.water.xyz,.69*deepWater);
    const float3 waterScatter = mix(s.deep.xyz,s.water.xyz*.19,.69)*opacity*deepWater*.59;
    // Depth weighting favours the foreground smoothly, without changing draw order at crossings.
    const float pixelOpacity = opacity*depth*visibility;
    return {half4(half3((radiance*depth*attenuation+waterScatter)*column*visibility*weight),
                  half(pixelOpacity*weight)),half2(pixelOpacity,playerFlowCoverage(in,depth*visibility))};
}

fragment half4 copyWaterLight(Full in [[stage_in]],
                              texture2d<half,access::read> water [[texture(0)]]) {
    return water.read(uint2(in.p.xy));
}

fragment half4 combineJellyLight(Full in [[stage_in]],
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
        const float3 axes = float3(s.enclosingShape.x,.68,s.enclosingShape.x);
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
    return {float4(point/aspect,0,1),uv,colour*depthLight(mote.head.y,s),
            mote.tail.w*fade*suspended*(paintedWorld ? .62 : 1.+.48*s.music.z+.19*s.music.w),detail};
}
fragment half4 planktonFragment(Fleck in [[stage_in]],
                                texture2d<half,access::read> transmission [[texture(2)]]) {
    const float cross = in.uv.x*2.-1.;
    const float along = in.uv.y;
    const float edge = (1.-abs(cross))*(1.-smoothstep(.90,1.,along));
    const float body = edge*edge*smoothstep(.02,.85,along)*(.33+.67*along);
    const float2 offset = float2(cross*2.9,(along-.83)*13.);
    const float bead = exp(-dot(offset,offset))*in.detail*edge;
    const float light = in.spark*flowTransmission(in.p,transmission);
    const float opacity = (body*.63+bead*.22)*light;
    return half4(half3(in.hue*1.29*opacity+mix(in.hue,float3(1.,.91,.68),.28)*bead*light*.82),
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
    const float3 colour = grade(light*1.32);
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

fragment half4 upscaleFrame(Full in [[stage_in]], texture2d<half> colour [[texture(0)]]) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    return colour.sample(linear,in.uv);
}

fragment half4 finish(Full in [[stage_in]], constant Scene& s [[buffer(0)]],
                      texture2d<half> light [[texture(0)]],
                      texture2d<half> nearGlow [[texture(1)]],
                      texture2d<half> farGlow [[texture(2)]]) {
    constexpr sampler sampleLight(coord::normalized,address::clamp_to_edge,filter::linear);
    const float2 q = in.uv-.5;
    const float lens = dot(q,q);
    if (s.graphicsStyle == paintedGraphics) {
        const float3 coat = float3(light.sample(sampleLight,in.uv).rgb);
        return half4(half3(finishPaint(coat,in.p.xy)),1);
    }
    const float2 uv = .5 + q*(.977+.040*lens);
    float3 c = float3(light.sample(sampleLight,uv).rgb);
    // Keep colour separation on the bell lenses, where it follows the material.
    c += float3(nearGlow.sample(sampleLight,uv).rgb)*.22+
         float3(farGlow.sample(sampleLight,uv).rgb)*.16;
    c *= 1.-.27*smoothstep(.11,.50,lens);
    const float grain = (hash21(in.p.xy)-.5)*.006;
    const float grainAmount = 1.-smoothstep(.69,1.,max(c.r,max(c.g,c.b)));
    c = (hybridWater(s) ? gradeHybrid(c) : grade(c))+grain*grainAmount;
    return half4(half3(c),1);
}
