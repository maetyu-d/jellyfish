#include <metal_stdlib>
using namespace metal;

struct Planet { float4 position, material, pigment; };
struct Scene {
    float4 screen, eye, right, up, forward, deep, water, bright, contrast, sun, sunlight, tide;
    Planet planets[3];
    float4 player;
    float4 call;
    float4 music;
    float4 habitat;
    float4 eclipse;
};
struct Jelly { float4 position, pigment, flow, trail; float presence, eclipsing, basinLight, basinTone; };
struct Tracer { float4 head, tail; float wake, current; };
struct FlowNode { float4 point, light; };
struct TrailPose { Jelly jelly; float4 time; };
struct TrailMark { float4 tip, body, light; }; // Tip/time, origin/size, hue/hero/pulse/presence.
struct TrailLayout { uint4 history; float lifetime; uint lines, segments; };
struct Full { float4 p [[position]]; float2 uv; };
constant float pi = 3.14159265;
constant float tau = 6.2831853;
constant float focal = 1.94;
constant float3 playerBody[4] = {
    float3(1.,.008,.15), float3(1.,.008,.31), float3(.024,.14,1.), float3(1.,.24,.006)
};
constant float3 playerRim[4] = {
    float3(1.,.024,.69), float3(.50,.017,1.), float3(.58,.012,1.), float3(1.,.85,.012)
};

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
float3 discharge(float3 ray, float3 axis, float phase, constant Scene& s) {
    const float3 side = normalize(cross(axis,float3(.87,-.13,.51)));
    const float3 travel = cross(side,axis);
    const float2 p = float2(dot(ray,side),dot(ray,travel));
    const float t = s.screen.y;
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
    const float a = hash21(id), b = hash21(id+27.5);
    const float2 xy = f-(.18+.64*float2(b,hash21(id+19.2)));
    const float d = length(xy);
    const float width = max(fwidth(cells.x),fwidth(cells.y));
    const float glint = smoothstep(.97,1.,a) * exp(-d*d/(.028+width*.026));
    const float spark = smoothstep(.9988,1.,a) * exp(-d*7.)*1.9;
    const float blue = fract(a*213.3);
    return mix(float3(1.,.53,.46),float3(.38,.77,1.),blue)*(glint*.72+spark);
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

float3 celestial(float3 ray, float3 sea, constant Scene& s) {
    const float pixel = max(length(dfdx(ray)),length(dfdy(ray)));
    const float3 star = s.sun.xyz;
    const float3 sunColour = s.sunlight.xyz;
    const float cs = dot(ray,star);
    const float R = s.sun.w;
    float3 result = sea;
    if (cs > .84) {
        const float d = length(cross(ray,star));
        const float r = d/R;
        const float ph = atan2(ray.y-star.y,ray.x-star.x);
        const float2 coronaAngle = float2(cos(ph),sin(ph));
        const float streamer = fbm(coronaAngle*6.7+s.tide.x);
        const float reach = max(0.,r-1.);
        const float flecks = fbm(coronaAngle*14.4+float2(reach*2.8,s.screen.y*.025));
        const float fingers = pow(saturate(.5+.5*cos(ph*19.+flecks*3.4+r*.76)),5.);
        const float corona = exp(-reach*(4.6-3.1*streamer));
        result += sunColour*(.065*exp(-r*.72)+corona*(.083+.36*streamer*fingers));
        result += mix(s.contrast.xyz,sunColour,.66)*exp(-abs(r-1.)*10.)*(.10+.32*flecks);
        const float through = stellarTransmission(ray,s);
        if (r < 1.01 && through > .02) {
            const float2 q = (ray.xy-star.xy)/R;
            const float twist = fbm(q*3.9+float2(s.tide.x*6.1,s.screen.y*.031));
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
        result = mix(sea,result,through);
    }
    for (uint i = 0; i < 3; ++i) {
        const Planet p = s.planets[i];
        if (p.position.w <= 0.) continue;
        const float3 centre = p.position.xyz;
        const float r = p.position.w;
        const float centreDepth = dot(ray,centre);
        if (centreDepth < .69) continue;
        const float miss = sqrt(max(0.,1.-centreDepth*centreDepth));
        const float limbDistance = miss / r;
        const float intersection = centreDepth-sqrt(max(0.,r*r-miss*miss));
        const float3 normal = (ray*intersection-centre)/r;
        const float lit = saturate(dot(normal,normalize(star-centre*.73))*.83+.20);

        const float ringWidth = p.material.w;
        float ringDepth = 0.;
        float ringAlpha = 0.;
        float3 ringTint = 0.;
        if (ringWidth > .02 && limbDistance < 3.4) {
            const float a = p.material.z;
            const float3 ringNormal = normalize(float3(sin(a)*.88,cos(a),-.34));
            const float denom = dot(ray,ringNormal);
            if (abs(denom) > .001) {
                ringDepth = dot(centre,ringNormal)/denom;
                const float ring = length(ray*ringDepth-centre)/r;
                const float outer = 1.71 + .48*ringWidth;
                const float silhouette = smoothstep(1.20,1.24,ring)*(1.-smoothstep(outer-.025,outer,ring));
                const float footprint = pixel*ringDepth/(r*max(.08,abs(denom)));
                const float broad = .28*sin(ring*90.)*(1.-smoothstep(.015,.039,footprint));
                const float fine = .15*sin(ring*151.)*(1.-smoothstep(.007,.025,footprint));
                const float lane = .53+broad+fine;
                const float division = 1.-.89*exp(-abs(ring-(outer*.87))*55.);
                ringAlpha = silhouette*lane*division;
                ringTint = mix(p.pigment.xyz,s.bright.xyz,.48)*(.43+.43*lit);
            }
        }
        if (ringDepth > intersection)
            result = mix(result,ringTint,ringAlpha*.75);
        if (limbDistance < 1.16) {
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
            const float body = 1.-smoothstep(.993,1.005,limbDistance);
            result = mix(result,sphere+s.water.xyz*.060,body);
            result += mix(s.bright.xyz,p.pigment.xyz,.34)*(rim+halo);
        }
        if (ringDepth <= intersection)
            result = mix(result,ringTint,ringAlpha*.84);
    }
    return result;
}

float3 suspendedLight(float3 ray, float3 sunAcross, float3 sunUp, constant Scene& s) {
    const float ahead = saturate(dot(ray,s.sun.xyz));
    const float t = s.screen.y;
    float scatter = 0., clear = 0.;
    // The samples sit in the water, so nearby light drifts past faster than distant haze.
    for (uint i = 0; i < 4; ++i) {
        const float reach = 10.+float(i*i)*7.;
        const float3 point = s.eye.xyz+ray*reach;
        const float2 sheet = float2(dot(point,sunAcross),dot(point,sunUp));
        const float2 drift = float2(t*.14,-t*.082);
        const float fine = noise(sheet*.22+drift+s.tide.x*31.);
        const float mass = noise(sheet*.065-drift*.45+s.tide.x*14.);
        const float slit = smoothstep(.53,.91,fine-.19*sin(sheet.y*.39-sheet.x*.14));
        scatter += slit*(.23+.77*mass);
        clear += mass*mass;
    }
    const float shaft = (.13+.87*pow(ahead,2.9))*scatter*.126;
    const float haze = clear*(.013+.045*pow(ahead,5.6));
    return mix(s.water.xyz,s.sunlight.xyz,.34)*(shaft+haze);
}

fragment half4 oceanLight(Full in [[stage_in]], constant Scene& s [[buffer(0)]]) {
    const float2 q = (in.uv * 2. - 1.)*float2(s.screen.x,-1.);
    const float3 ray = normalize(s.forward.xyz + (s.right.xyz*q.x+s.up.xyz*q.y)/focal);
    const float t = s.screen.y;
    const float2 nd = float2(atan2(ray.x,ray.z),ray.y);
    const float2 sphere = float2(dot(ray,float3(.89,.12,-.39)),dot(ray,float3(-.27,.74,.61)));
    const float field = fbm(sphere*7.2+float2(s.tide.x*3.3,t*.033));
    const float undersea = fbm(sphere*17.+float2(field*3.4,s.tide.x*7.+t*.018));
    const float3 sweep = s.water.xyz * (.024+.074*field);
    float3 water = s.deep.xyz * (.84 + 1.16*undersea)+sweep;
    water += starfield(ray)*(.56-.34*undersea);
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
    water = celestial(ray,water,s);
    if (s.habitat.x > .5) {
        const float narrow = s.habitat.y;
        const float3 slit = normalize(float3(-4.,-.6,178.)-s.eye.xyz+float3(.001));
        const float opening = pow(saturate(dot(ray,slit)),17.);
        const float3 darkness = water*mix(float3(.45,.09,.74),float3(.70,.58,.82),opening);
        water = mix(water,darkness,narrow*.93);
        const float3 basin = normalize(float3(2.,7.,268.)-s.eye.xyz+float3(.001));
        const float lantern = pow(saturate(dot(ray,basin)),3.);
        const float window = pow(saturate(dot(ray,normalize(basin+float3(.27,.16,0.)))),7.);
        const float spread = s.habitat.z*s.habitat.z;
        water += spread*(lantern*mix(float3(.013,.068,.21),float3(.015,.20,.24),field)*
                         (.32+.49*undersea)+float3(.15,.29,.013)*window*field*.38);
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
        const float3 colour = mix(s.bright.xyz,s.contrast.xyz,mix(.16,.66,s.call.y));
        water += colour*shell*smoothstep(0.,5.,front)*exp(-age*mix(.83,.59,s.call.y))*.35*
                 (1.-smoothstep(4.,5.3,age));
    }
    return half4(half3(max(water,0.)),1);
}

struct AnimalFragment {
    float4 p [[position]];
    float3 normal, world;
    float4 shape;
    float2 attachment;
    float4 pigment;
    float4 state;
    float synchrony, scale, presence;
    float3 lighting;
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
float2 patch(uint i, uint cols, uint rows) {
    const uint triangle = i / 6;
    const uint corner = i % 6;
    const uint ox = corner == 1 || corner == 2 || corner == 4;
    const uint oy = corner == 2 || corner == 4 || corner == 5;
    return float2(float(triangle%cols+ox)/cols,float(triangle/cols+oy)/rows);
}

struct Ribbon {
    float4 p [[position]];
    float across, depth;
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
    return {float4(clip.xy,clip.z-.35,clip.z),across,clip.z,node.light};
}

// Scale the light and alpha together for premultiplied blending.
constant float currentOpacity = .50;

float flowFilament(float offset, float width, float footprint) {
    // Keep a thin line stable as it becomes smaller than a pixel.
    const float span = max(width,.82*footprint);
    const float distance = offset/span;
    return exp2(-2.85*distance*distance)*(width/span);
}

fragment half4 sheetLight(Ribbon in [[stage_in]], constant Scene& s [[buffer(0)]]) {
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
    const float presence = currentOpacity*in.light.w*depth*silk;
    const float3 dye = mix(float3(.009,.53,1.),float3(.022,1.,.74),s.habitat.z);
    const float3 foldTint = mix(dye,s.contrast.xyz,.14+.14*layer);
    const float3 sheen = mix(foldTint,float3(.36,.94,1.),.23+.24*iridescence);
    const float3 light = foldTint*.021+
                         sheen*cord*(.122+.064*iridescence+crest*(.30+.23*s.music.w));
    return half4(half3(light*presence),half(presence*(.036+cord*(.041+.056*crest))));
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
    const float3 vertical = float3(.16*node.light.z,1.,0.);
    const float3 world = node.point.xyz+(node.light.y == 3. ? vertical*across : side*(across*swell+bend))*node.point.w;
    const float3 clip = projectWorld(world,s);
    return {float4(clip.xy,clip.z-.29,clip.z),across,clip.z,node.light};
}
fragment half4 currentLight(Ribbon in [[stage_in]], constant Scene& s [[buffer(0)]]) {
    const float x = in.across;
    const float along = in.light.x;
    const float speed = in.light.z;
    const float time = s.screen.y;
    if (in.light.y > 2.5 && in.light.y < 3.5) {
        const float tide = noise(float2(along*.18,x*3.7)+float2(time*.045,-time*.11));
        const float fold = .24*sin(along*.24+6.*tide)+.16*sin(along*.071-time*.14);
        const float edge = abs(x-fold);
        const float fog = exp(-edge*edge*4.2)*(1.-smoothstep(.71,1.,abs(x)));
        const float drift = pow(saturate(.5+.5*sin(along*.51+x*10.+tide*7.)),6.);
        const float sheen = drift*(.17+.83*tide)*fog;
        const float visible = in.light.w*smoothstep(.5,4.5,in.depth)*exp(-in.depth*.010);
        const float3 tone = mix(float3(.001,.0008,.008),float3(.025,.004,.052),tide);
        return half4(half3((tone*fog+s.contrast.xyz*sheen*.044)*visible),half(fog*visible*.81));
    }
    const bool guide = in.light.y > 3.5;
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
    const float visibility = currentOpacity*in.light.w*smoothstep(1.4,5.5,in.depth)*exp(-in.depth*.0065);
    const float strength = (guide ? 1.14 : stream ? .94 : eddy ? .65 : .81)*
                           (.81+.19*saturate(speed*.46));
    const float3 body = guide ? mix(float3(.007,.56,1.),s.bright.xyz,s.habitat.z*.53) :
                        stream ? mix(s.water.xyz,s.bright.xyz,.64) :
                        eddy ? mix(s.water.xyz,s.contrast.xyz,.79) : float3(.92,.28,.019);
    const float3 highlight = guide ? mix(float3(.018,.92,1.),s.bright.xyz,s.habitat.z*.32) :
                             stream ? mix(s.bright.xyz,s.contrast.xyz,.16+.14*ripple) :
                             eddy ? mix(s.contrast.xyz,s.bright.xyz,.25) : float3(1.,.73,.12);
    const float3 foam = mix(highlight,float3(1.,.92,.77),.19);
    const float3 light = body*haze*(.129+.094*silk) +
                         highlight*threads*edge*(.27+.17*silk+.16*s.music.z) +
                         foam*gleam*(.99+.43*s.music.w);
    const float opacity = haze*(.094+.046*silk)+threads*edge*.065;
    return half4(half3(light*(visibility*strength)),half(opacity*visibility*strength));
}

float strandSeed(Jelly j, uint strand) { return hash(float(strand)+j.flow.w*43.+19.); }
float bellWidth(Jelly j, float time, float charge) {
    const float kind = j.pigment.w;
    const float breath = sin(j.pigment.y)+.42*j.pigment.z*sin(time*3.8);
    return ((kind >= 1.5 ? 1.21 : kind > .5 ? .83 : 1.)+.1*breath)*(1.-.21*charge*j.flow.z);
}

float bellLobes(float species) {
    return species >= 1.5 ? 8. : species > .5 ? 12. : 16.;
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
    const float scallopDepth = .029+.013*sin(slow);
    const float scallop = ct*scallopDepth+.008*cos(little)+.014*cos(cleft);
    const float drift = angle*3.+.86*sin(phase);
    const float base = j.pigment.w > .5 && j.pigment.w < 1.5 ? 1.10 : .98;
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

float3 tentacleSpine(Jelly j, uint strand, float progress, float width,
                     float h, float linger) {
    const float kind = j.pigment.w;
    const bool disc = kind >= 1.5;
    const bool crown = kind > .5 && !disc;
    const bool ribbon = strand < (disc ? 8u : 4u);
    const float a = float(strand)*2.39996323+j.flow.w;
    const float root = ribbon ? .26 + h*.13 : .65 + h*.34;
    const float span = (ribbon ? 2.72+1.0*h : 1.65+2.12*h)*
                       (disc ? .52 : crown ? 1.17 : mix(1.,.76,j.flow.z));
    const float extension = j.flow.z*(ribbon ? .24 : .60)*smoothstep(.10,.88,progress);
    const float loose = pow(max(.001,progress),1.21);
    const float curl = progress*(ribbon ? 1.2 : .74)*sin(linger+a);
    const float dist = root*width+loose*(.13+.42*h) + .18*loose*sin(linger+.37*sin(linger));
    float3 local = float3(cos(a+curl)*dist,.055-span*progress*(1.+extension),sin(a+curl)*dist);
    local.x += (sin(linger)*.23+j.flow.x*2.1)*loose;
    local.z += cos(linger-.29*sin(linger))*loose*.34;
    return local+rotateY(j.trail.xyz,-j.flow.y)*float3(.28,.16,.34)*loose;
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
    float3 local = tentacleSpine(j,strand,fraction,width,h,linger);
    local.x += j.flow.x*local.y*.23;
    return j.position.xyz+rotateY(local,j.flow.y)*j.position.w;
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
        return {float4(0,0,-1,1),0,0,float4(0)};
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
    return {float4(clip.xy,clip.z-.25,clip.z),across,clip.z,
            float4(age,young.light.x,hero,intensity*startTaper*endTaper)};
}
fragment half4 streakLight(Ribbon in [[stage_in]], constant Scene& s [[buffer(0)]]) {
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
    const float voyage = 1.-smoothstep(.80,.995,s.screen.w);
    const float decay = rise*fade*voyage*smoothstep(1.,4.3,in.depth)*exp(-in.depth*.017);
    const float3 dye = mix(pigment(hue+.079+.08*age),playerRim[uint(s.tide.z)],hero);
    const float3 trace = mix(dye,pigment(hue+.22),age*.30*(1.-hero));
    const float strength = in.light.w*decay;
    const float radiance = diffusion*(.19-.048*loosen)+filament*.58+gleam*(.23+.55*s.music.z);
    const float3 fringe = mix(trace,s.bright.xyz,.48)*satellite*.26;
    return half4(half3((trace*radiance+fringe)*strength*(1.+.25*s.music.w)),
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
    const float t = s.screen.y;
    const float kind = j.pigment.w;
    const float phase = j.pigment.y;
    const float breath = sin(phase)+.42*j.pigment.z*sin(t*3.8);
    const float charge = s.call.x*j.flow.z;
    const bool crown = kind > .5 && kind < 1.5;
    const bool comb = kind >= 1.5;
    const float width = bellWidth(j,t,s.call.x);
    const float height = (crown ? 1.29 : comb ? .47 : .87)-.12*breath+.26*charge;
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
            local = attachedSpine(j,strand,local,progress,width,h,ribbon,root);
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
            const float3 across = rotateY(s.right.xyz,-j.flow.y);
            const float3 toward = rotateY(-s.forward.xyz,-j.flow.y);
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
    local.x += j.flow.x*local.y*.23;
    local = rotateY(local,j.flow.y);
    normal.y -= j.flow.x*.23*normal.x;
    normal = rotateY(normal,j.flow.y);
    const float3 point = j.position.xyz+local*j.position.w;
    const float3 clip = projectWorld(point,s);
    return {float4(clip.xy,clip.z-.12,clip.z),normal,point,shape,attachment,j.pigment,j.flow,
            j.trail.w,j.position.w,j.presence,float3(j.eclipsing,j.basinLight,j.basinTone)};
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
    half opacity [[color(1)]];
};

fragment JellyLight jellyMembrane(AnimalFragment in [[stage_in]], constant Scene& s [[buffer(0)]],
                                  texture2d<half> waterLight [[texture(0)]]) {
    constexpr sampler sampleWater(coord::normalized,address::clamp_to_edge,filter::linear);
    const float3 offset = s.eye.xyz-in.world;
    const float distance = length(offset);
    const float3 view = offset/max(.0001,distance);
    const float2 uv = in.shape.xy;
    const float clock = s.screen.y;
    const float hero = in.state.z;
    const float currentContrast = hero*s.habitat.w;
    const float kind = in.pigment.w;
    const float rz = uv.y;
    const float angle = uv.x*tau;
    const float hueSeed = in.pigment.x+.022*sin(clock*.076+in.state.w*tau);
    const float hue = hueSeed+.065*cos(angle+rz*3.2);
    const uint palette = uint(s.tide.z);
    const float3 prism = pigment(hue);
    const float basinTone = in.lighting.z;
    const float eclipsing = in.lighting.x;
    float3 dye = mix(prism,playerBody[palette],hero);
    float3 flare = mix(pigment(hue+.12),playerRim[palette],hero);
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
    const float3 normal = normalize(in.normal+float3(.0001));
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
    const float largest = smoothstep(9.,13.,in.scale);
    const float silhouette = largest*smoothstep(43.,126.,distance);
    const float depth = exp(-distance*mix(.015,.0076,silhouette));
    const float nearPlane = -dot(offset,s.forward.xyz);
    const float visibility = in.presence*smoothstep(.24,2.7,nearPlane)*
                             (1.-smoothstep(mix(71.,148.,largest),mix(107.,224.,largest),distance));
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
        const float3 sharedDye = mix(pigment(sharedHue),playerBody[palette],hero);
        const float3 sharedLight = mix(pigment(sharedHue+.12),playerRim[palette],hero)*pulse;
        if (in.shape.z == 1.) {
            const float pleat = rz*11.4+in.shape.w*12.+1.35*abs(x*.18)+.19*sin(rz*49.);
            const float ridges = periodicLine(pleat,.085);
            const float fibre = periodicLine(uv.x*8.+.18*sin(rz*34.+uv.x*6.),.028);
            const float edgeBinding = exp(-pow((abs(x)-2.38)*3.3,2.));
            const float centre = exp(-x*x*12.);
            const float3 iris = pigment(hue+.105+.12*sin(pleat*tau)*fresnel);
            const float3 lit = mix(dye,iris,.16+.35*morning);
            opacity = tap*(side*(.29+.31*silk+.13*ridges)+edgeBinding*.21);
            radiance = lit*opacity*(.058+.26*morning+.17*backlight) +
                       phosphor*tap*(side*(.11+.21*fibre+.24*ridges)+
                                     centre*(.16+.36*pearls)+edgeBinding*(.21+.15*ridges)) +
                       sheen*opacity*(.21*pow(shine,28.)+.072*ridges*backlight);
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
        opacity = mix(.35,.63,facing)+.12*fresnel+.07*folds;
        radiance = tissue*opacity*(.075+.35*morning+.18*inner) +
                   warm*(.041+.23*folds+.31*flow*inner)*opacity+
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
        const float3 film = pigment(hue+.045+.36*spectrum);
        const float3 gel = mix(dye*.79,mix(float3(.075,.25,.85),s.water.xyz,.37),.09+.29*texture);
        const float3 iridescence = mix(film,phosphor,.43);
        const float3 shellLight = mix(sheen*.91,iridescence,.38+.39*fresnel);
        const float structure = (comb ? .24*cilia : (.124+.064*travel)*primary) +
                                vein*.093+filaments*.037;
        opacity = (underside ? .061+.13*fresnel+.086*rim :
                              .062+.20*thickness*(.50+.50*facing)+.20*fresnel+.081*rim);
        opacity *= mix(.53,1.,facing);
        opacity += .11*structure;
        const float backScatter = .27*backlight*(.32+.68*texture);
        const float volume = .10+.13*texture+.24*morning+backScatter;
        const float polished = pow(shine,61.)*(.28+.27*texture)+pow(shine,16.)*.045;
        const float bellRim = rim*(.20+.086*travel+.071*texture)+.095*rimThreads;
        radiance = gel*opacity*volume +
                   (phosphor*structure+iridescence*(bellRim+fresnel*(.088+.11*texture)))*
                        mix(.56,1.,facing) +
                   shellLight*(polished+granules*(.008+.066*pow(shine,13.)));
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
            const float2 bend = float2(dot(normal,s.right.xyz)/s.screen.x,-dot(normal,s.up.xyz))
                              * min(.64,in.scale/max(2.,distance))*(underside ? .094 : .162)
                              * (.67+.60*texture)*(.54+.46*ndv);
            const float spread = .085+.19*lip+.15*edge;
            const float3 lens = float3(waterLight.sample(sampleWater,screenUV+bend*(1.+spread)).r,
                                      waterLight.sample(sampleWater,screenUV+bend).g,
                                      waterLight.sample(sampleWater,screenUV+bend*(1.-spread)).b);
            const float transparency = (.11+.18*edge)*(1.-opacity)*smoothstep(0.,.26,ndv)*
                                       (1.-.78*eclipsing)*(1.-.36*currentContrast)*(1.-silhouette);
            const float3 absorption = exp2(-thickness*(1.-mix(dye,film,.25))*1.45);
            radiance += lens*absorption*transparency;
            opacity += transparency;
        }
    }
    if (basinTone >= 0.) {
        radiance *= mix(.10,1.31-.12*basinTone,in.lighting.y);
    } else {
        radiance *= mix(1.,.50+.28*hero+.45*eclipsing,s.habitat.y);
    }
    const float deepWater = 1.-exp(-max(0.,distance-12.)*.016);
    const float3 attenuation = mix(float3(1),.50+.50*s.water.xyz,.69*deepWater);
    const float3 waterScatter = mix(s.deep.xyz,s.water.xyz*.19,.69)*opacity*deepWater*.59;
    // Depth weighting favours the foreground smoothly, without changing draw order at crossings.
    const float weight = .048+1.7*exp2(-.091*max(0.,nearPlane));
    const float pixelOpacity = opacity*depth*visibility;
    return {half4(half3((radiance*depth*attenuation+waterScatter)*visibility*weight),
                  half(pixelOpacity*weight)),half(pixelOpacity)};
}

fragment half4 combineJellyLight(Full in [[stage_in]],
                                texture2d<half,access::read> water [[texture(0)]],
                                texture2d<half,access::read> jelly [[texture(1)]],
                                texture2d<half,access::read> transmission [[texture(2)]]) {
    const uint2 pixel = uint2(in.p.xy);
    const half4 sum = jelly.read(pixel);
    const half through = saturate(transmission.read(pixel).r);
    const float3 colour = float3(sum.rgb)/max(.00001,float(sum.a));
    return half4(half3(colour*(1.-float(through)))+water.read(pixel).rgb*through,1);
}

struct Fleck { float4 p [[position]]; float2 uv; float3 hue; float spark, detail; };
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
    const float3 colour = mix(mix(s.water.xyz,s.bright.xyz,.44+.20*glint+.34*mote.current),
                              mix(s.bright.xyz,float3(1.,.54,.095),.63),mote.wake);
    const float fade = smoothstep(.8,4.5,depth)*exp(-head.z*.015);
    const float suspended = mix(1.,.36+.83*mote.current,s.habitat.y);
    const float spin = .66+.34*sin(s.screen.y*(.95+glint*.57)+glint*57.);
    const float detail = smoothstep(.91,1.,glint)*spin;
    return {float4(point/aspect,0,1),uv,colour,
            mote.tail.w*fade*suspended*(1.+.48*s.music.z+.19*s.music.w),detail};
}
fragment half4 planktonFragment(Fleck in [[stage_in]]) {
    const float cross = in.uv.x*2.-1.;
    const float along = in.uv.y;
    const float edge = (1.-abs(cross))*(1.-smoothstep(.90,1.,along));
    const float body = edge*edge*smoothstep(.02,.85,along)*(.33+.67*along);
    const float2 offset = float2(cross*2.9,(along-.83)*13.);
    const float bead = exp(-dot(offset,offset))*in.detail*edge;
    const float opacity = (body*.63+bead*.22)*in.spark;
    return half4(half3((in.hue*1.29*opacity+mix(in.hue,float3(1.,.91,.68),.28)*bead*in.spark*.82)),
                 half(opacity));
}

float3 grade(float3 x) {
    // Compress brightness together so the brighter membranes keep their hue.
    x = max(x,0.) * .96;
    const float peak = max(x.r,max(x.g,x.b));
    const float light = saturate((peak*(2.51*peak+.03))/(peak*(2.43*peak+.59)+.14));
    return pow(x/max(peak,.00001),float3(.89))*pow(light,.68);
}

float3 bloomSource(float3 color) {
    const float peak = max(color.r,max(color.g,color.b));
    const float knee = smoothstep(.37,.96,peak);
    return color*(knee/(1.+.19*peak));
}

fragment half4 extractGlow(Full in [[stage_in]], texture2d<half> scene [[texture(0)]]) {
    constexpr sampler linear(coord::normalized,address::clamp_to_edge,filter::linear);
    const float2 px = 1./float2(scene.get_width(),scene.get_height());
    float3 soft = bloomSource(float3(scene.sample(linear,in.uv).rgb))*.24;
    for (uint i = 0; i < 4; ++i) {
        const float2 corner = float2((i&1u) ? 1. : -1.,(i&2u) ? 1. : -1.);
        soft += bloomSource(float3(scene.sample(linear,in.uv+corner*px*1.53).rgb))*.19;
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

fragment half4 finish(Full in [[stage_in]], constant Scene& s [[buffer(0)]],
                      texture2d<half> light [[texture(0)]],
                      texture2d<half> nearGlow [[texture(1)]],
                      texture2d<half> farGlow [[texture(2)]]) {
    constexpr sampler sampleLight(coord::normalized,address::clamp_to_edge,filter::linear);
    const float2 q = in.uv-.5;
    const float lens = dot(q,q);
    const float2 uv = .5 + q*(.977+.040*lens);
    float3 c = float3(light.sample(sampleLight,uv).rgb);
    // Keep colour separation on the bell lenses, where it follows the material.
    c += float3(nearGlow.sample(sampleLight,uv).rgb)*.19+
         float3(farGlow.sample(sampleLight,uv).rgb)*.14;
    const float migration = pow(s.screen.w,2.8);
    c *= (1.-.36*smoothstep(.11,.50,lens))*(1.-.997*migration);
    c += s.bright.xyz * (.014*migration + .047*s.screen.w*(1.-migration))*
        pow(saturate(sin(lens*91.-s.screen.w*6.+s.screen.y*.9)),3.);
    const float grain = (hash21(in.p.xy)-.5)*.009;
    c = grade(c) + grain * (1.-smoothstep(.69,1.,max(c.r,max(c.g,c.b))));
    return half4(half3(c),1);
}
