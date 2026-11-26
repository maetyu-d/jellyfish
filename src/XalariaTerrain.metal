// Xalaria globe grid: each native cube face retains the original triangle
// split and a radially displaced vertex from the authored geology field.
struct TerrainStyle {
    float4 bedrock, sediment, process, traits, low, high, fabric;
};

struct TerrainContact {
    float3 colour, radial, normal;
    float elevation, distance, coverage;
    bool streamed;
};

float3 terrainFaceDirection(uint face, float2 uv) {
    switch (face) {
    case 0: return normalize(float3(1.,uv.y,-uv.x));
    case 1: return normalize(float3(-1.,uv.y,uv.x));
    case 2: return normalize(float3(uv.x,1.,-uv.y));
    case 3: return normalize(float3(uv.x,-1.,uv.y));
    case 4: return normalize(float3(uv.x,uv.y,1.));
    default: return normalize(float3(-uv.x,uv.y,-1.));
    }
}

float2 terrainFaceUv(float3 p, thread uint& face) {
    const float3 extent=abs(p);
    if (extent.x>=extent.y && extent.x>=extent.z) {
        face=p.x>=0. ? 0u : 1u;
        return float2(p.x>=0. ? -p.z : p.z,p.y)/extent.x;
    }
    if (extent.y>=extent.z) {
        face=p.y>=0. ? 2u : 3u;
        return float2(p.x,p.y>=0. ? -p.z : p.z)/extent.y;
    }
    face=p.z>=0. ? 4u : 5u;
    return float2(p.z>=0. ? p.x : -p.x,p.y)/extent.z;
}

float3 terrainPatchProjection(float3 p, uint face) {
    switch (face) {
    case 0: return float3(-p.z,p.y,p.x);
    case 1: return float3(p.z,p.y,-p.x);
    case 2: return float3(p.x,-p.z,p.y);
    case 3: return float3(p.x,p.z,-p.y);
    case 4: return float3(p.x,p.y,p.z);
    default: return float3(-p.x,p.y,-p.z);
    }
}

struct TerrainFacet {
    float3 a, b, c;
    float3 colours[3];
};

struct NativeTerrainSource {
    texture2d_array<float> atlas;
    constant TerrainStyle* styles;
    float4 patch;

    TerrainStyle style(uint body) const { return styles[body]; }

    TerrainFacet facet(float3 direction, uint body) const {
        uint face;
        float2 uv=terrainFaceUv(direction,face), centre=0.;
        float extent=1.;
        uint slice=body*6u+face;
        if (patch.w>0. && uint(patch.x-1.)/8u==body) {
            const uint patchFace=uint(patch.x-1.)%8u;
            const float3 projection=terrainPatchProjection(direction,patchFace);
            const float2 offset=projection.xy/max(projection.z,1.e-8)-patch.yz;
            if (projection.z>0. && max(abs(offset.x),abs(offset.y))<=patch.w) {
                face=patchFace;
                uv=projection.xy/projection.z;
                centre=patch.yz;
                extent=patch.w;
                slice=78u;
            }
        }
        const float2 point=((uv-centre)/extent*.5+.5)*64.;
        const uint2 origin=uint2(clamp(floor(point),0.,63.));
        const float2 offset=point-float2(origin);
        const bool upper=offset.x+offset.y>1.;
        const uint2 a=origin+uint2(upper ? 1u : 0u,0u), b=origin+uint2(upper ? 1u : 0u,1u);
        const uint2 c=origin+uint2(upper ? 0u : 1u,upper ? 1u : 0u);
        const float4 x=atlas.read(a,slice), y=atlas.read(b,slice), z=atlas.read(c,slice);
        return {terrainFaceDirection(face,centre+extent*(float2(a)/32.-1.))*(1.+x.w),
                terrainFaceDirection(face,centre+extent*(float2(b)/32.-1.))*(1.+y.w),
                terrainFaceDirection(face,centre+extent*(float2(c)/32.-1.))*(1.+z.w),
                {x.xyz,y.xyz,z.xyz}};
    }

    float radialDistance(uint body,float3 position) const {
        if (dot(position,position)<.5) return -1.;
        const auto triangle=facet(normalize(position),body);
        const float3 n=cross(triangle.b-triangle.a,triangle.c-triangle.a);
        return length(position)*(1.-dot(n,triangle.a)/dot(n,position));
    }

    TerrainContact contact(uint body, float3 perpendicular, float3 ray, float bound, float pixel,
                           float cameraAxial) const {
        TerrainContact hit{};
        const float miss=length(perpendicular);
        const float edge=min(.07,max(1.e-6,pixel));
        if (miss>bound+edge) return hit;
        const float last=sqrt(max(0.,bound*bound-miss*miss));
        const float start=max(-last,cameraAxial+1.e-7);
        if (start>last) return hit;
        float axial=start;
        TerrainFacet triangle{};
        float localRadius=1.;
        for (uint step=0;step<4u;++step) {
            const float3 direction=normalize(perpendicular+ray*axial);
            triangle=facet(direction,body);
            const float3 normal=normalize(cross(triangle.b-triangle.a,triangle.c-triangle.a));
            localRadius=dot(normal,triangle.a)/dot(normal,direction);
            const float denominator=dot(normal,ray);
            const float plane=dot(normal,triangle.a-perpendicular)/
                (abs(denominator)>1.e-6 ? denominator : copysign(1.e-6,denominator));
            const float estimate=-sqrt(max(0.,localRadius*localRadius-miss*miss));
            if (dot(normal,direction)*denominator<0. &&
                plane>=start-1.e-5 && plane<=0. &&
                abs(plane-estimate)<.05)
                axial=plane;
            else axial=clamp(estimate,start,last);
        }
        hit.coverage=1.-smoothstep(-edge*.5,edge*.5,miss-localRadius);
        // At low altitude the camera can be inside the conservative globe
        // bounds, yet still above its local valley. March only these grazing
        // misses, retaining hills in front of the ship at positive depth.
        if (cameraAxial>-last && (axial<=start+2.e-6 || hit.coverage<=0.)) {
            float lower=start, upper=start;
            bool found=false;
            for (uint sample=1u;sample<=12u;++sample) {
                const float phase=float(sample)/12.;
                upper=mix(start,last,phase*phase);
                if (radialDistance(body,perpendicular+ray*upper)<=0.) {
                    found=true;
                    break;
                }
                lower=upper;
            }
            if (!found) return TerrainContact{};
            for (uint refinement=0;refinement<7u;++refinement) {
                const float middle=(lower+upper)*.5;
                if (radialDistance(body,perpendicular+ray*middle)>0.) lower=middle;
                else upper=middle;
            }
            axial=(lower+upper)*.5;
            hit.coverage=1.;
        }
        if (hit.coverage<=0.) return hit;
        const float3 point=perpendicular+ray*axial;
        triangle=facet(normalize(point),body);
        const float3 e=triangle.b-triangle.a, f=triangle.c-triangle.a, relative=point-triangle.a;
        const float ee=dot(e,e), ff=dot(f,f), ef=dot(e,f);
        const float2 projections=float2(dot(e,relative),dot(f,relative));
        const float2 uv=saturate(float2(ff*projections.x-ef*projections.y,ee*projections.y-ef*projections.x)/
                                 max(1.e-28,ee*ff-ef*ef));
        const float3 n=normalize(cross(e,f));
        hit.radial=normalize(point);
        hit.normal=dot(n,hit.radial)>=0. ? n : -n;
        hit.distance=axial;
        hit.elevation=length(point)-1.;
        hit.colour=(max(0.,1.-uv.x-uv.y)*triangle.colours[0]+uv.x*triangle.colours[1]+uv.y*triangle.colours[2])/
                   max(1.,uv.x+uv.y);
        return hit;
    }
};

struct PreviewTerrainSource {
    TerrainStyle style(uint) const { return {}; }
    TerrainContact contact(uint, float3, float3, float, float, float) const { return {}; }
};

float3 xalariaTerrainPigment(float phase) {
    const float heat=.5+.5*sin(6.283185*phase);
    const float3 oxide=mix(float3(.045,.004,.0015),float3(.90,.12,.008),smoothstep(.08,.80,heat));
    return mix(oxide,float3(1.65,.72,.045),pow(heat,9.)*.72);
}

float3 xalariaTerrainTapestry(float3 direction, float phase, float seconds) {
    const float3 p=direction*4.8;
    const float a=p.y*1.7+sin(p.x*1.3+p.z*.4+phase*3.)*1.3;
    const float b=p.z*1.4+sin(p.y*1.1-p.x*.5+seconds*.004)*1.2;
    const float soot=pow((.5+.5*sin(a))*(.5+.5*sin(b)),1.6);
    return mix(float3(.008,.004,.003),float3(.24,.035,.012),soot);
}

float3 xalariaTerrainSilk(float3 direction, float phase, float seconds) {
    const float3 p=direction*3.2;
    const float time=seconds*.008;
    const float smoke=.5+.5*sin(p.y*2.4+sin(p.x*2.+phase*6.)+sin(p.z*1.7+time)*.65);
    const float folds=.5+.5*sin(p.z*3.2+sin(p.y*2.1-time)*.6);
    return mix(float3(.012,.007,.006),float3(.18,.028,.011),pow(smoke*folds,1.6))*.55;
}

float xalariaTerrainThread(float phase, float width) {
    const float span=fwidth(phase);
    const float aa=clamp(span*.8,.002,.75);
    const float strand=1.-smoothstep(width,width+aa,abs(sin(phase)));
    const float coverage=2.*asin(saturate(width))/pi;
    return mix(coverage,strand,1.-smoothstep(.65,1.75,span));
}

// Hyperion's texture baker and shader share the 16 m tile period. Explicit
// mip gradients retain the original filtered detail and cubic texel slopes.
constexpr sampler terrainDetailSampler(coord::normalized,address::repeat,filter::linear,
                                       mip_filter::linear,max_anisotropy(16));

float4 xalariaMaterialSample(texture2d<float> texture, float2 uv, float2 dx, float2 dy) {
    const auto gradients=gradient2d(dx,dy);
    const float footprint=max(length(dx),length(dy))*512.;
    if (footprint>=1.5) return texture.sample(terrainDetailSampler,uv,gradients);
    const float2 p=uv*512.-.5, cell=floor(p), f=fract(p), a=1.-f;
    const float2 w0=a*a*a/6., w1=(3.*f*f*f-6.*f*f+4.)/6.;
    const float2 w2=(-3.*f*f*f+3.*f*f+3.*f+1.)/6., w3=f*f*f/6.;
    const float2 g0=w0+w1, g1=w2+w3;
    const float2 lo=(cell-1.+w1/g0+.5)/512., hi=(cell+1.+w3/g1+.5)/512.;
    const float4 reconstructed=
        texture.sample(terrainDetailSampler,lo,gradients)*g0.x*g0.y+
        texture.sample(terrainDetailSampler,float2(hi.x,lo.y),gradients)*g1.x*g0.y+
        texture.sample(terrainDetailSampler,float2(lo.x,hi.y),gradients)*g0.x*g1.y+
        texture.sample(terrainDetailSampler,hi,gradients)*g1.x*g1.y;
    if (footprint<=.75) return reconstructed;
    return mix(reconstructed,texture.sample(terrainDetailSampler,uv,gradients),
               smoothstep(.75,1.5,footprint));
}

float4 xalariaCloseField(texture2d<float> texture, float3 q, float3 normal, float3 dx, float3 dy) {
    float3 w=pow(abs(normal),float3(4.));
    w/=max(dot(w,float3(1.)),.0001);
    w*=step(float3(.001),w);
    w/=max(dot(w,float3(1.)),.0001);
    const float3 p=q*.5;
    float4 field=0.;
    if (w.x>0.) field+=xalariaMaterialSample(texture,p.yz,dx.yz*.5,dy.yz*.5)*w.x;
    if (w.y>0.) field+=xalariaMaterialSample(texture,p.zx,dx.zx*.5,dy.zx*.5)*w.y;
    if (w.z>0.) field+=xalariaMaterialSample(texture,p.xy,dx.xy*.5,dy.xy*.5)*w.z;
    return field;
}

float3 xalariaTerrainBump(float3 n,float3 position,float height,float maximumSlope) {
    const float3 dx=dfdx(position), dy=dfdy(position);
    const float3 a=cross(dy,n), b=cross(n,dx);
    const float det=dot(dx,a);
    float3 gradient=sign(det)*(dfdx(height)*a+dfdy(height)*b)/max(abs(det),1.e-20);
    gradient*=min(1.,maximumSlope/max(length(gradient),.001));
    return normalize(n-gradient);
}

float3 xalariaScaledTerrainBump(float3 n,float3 position,float height,float maximumSlope) {
    float3 dx=dfdx(position), dy=dfdy(position);
    const float3 axes=max(abs(dx),abs(dy));
    const float span=max(axes.x,max(axes.y,axes.z));
    if (span<=1.e-30) return n;
    dx/=span;
    dy/=span;
    const float3 a=cross(dy,n), b=cross(n,dx);
    const float det=dot(dx,a);
    const float3 gradient=sign(det)*((dfdx(height)/span)*a+(dfdy(height)/span)*b)/max(abs(det),1.e-10);
    return normalize(n-gradient*min(1.,maximumSlope/max(length(gradient),.001)));
}

struct TerrainMaterialPoint {
    float3 normal, albedo, coatHue, microGlow;
    float rough, cavity, microVein;
};

struct NoTerrainDetail {
    TerrainMaterialPoint apply(TerrainMaterialPoint point, TerrainContact, TerrainStyle,float3,
                               float,float,float,float,float) const { return point; }
    float sunVisibility(float) const { return 1.; }
    float gearContact() const { return 1.; }
    float wetGround(float) const { return 0.; }
    float3 orbitalBump(float3 n,TerrainContact hit,float height,float slope,float) const {
        return xalariaScaledTerrainBump(n,hit.radial*(1.+hit.elevation),height,slope);
    }
};

struct XalariaNearTerrainDetail {
    texture2d<float> texture;
    depth2d<float> shadow;
    constant FlightTerrainSun* sun;
    float3 position, microOrigin, mesoOriginLow, mesoOriginHigh;
    float rain;

    float sunVisibility(float sunDot) const { return xalariaSurfaceSun(position,sunDot,*sun,shadow); }
    float gearContact() const { return xalariaGearContact(position,*sun); }
    float wetGround(float temperature) const {
        return rain>.01 ? rain*.85*(1.-smoothstep(5000.,15000.,length(position)))*
                           smoothstep(271.,280.,temperature)*(1.-smoothstep(365.,390.,temperature)) : 0.;
    }
    float3 orbitalBump(float3 n,TerrainContact,float height,float slope,float radius) const {
        return xalariaScaledTerrainBump(n,position,height*radius,slope);
    }

    TerrainMaterialPoint apply(TerrainMaterialPoint material, TerrainContact hit, TerrainStyle style,float3 up,
                               float phase,float temperature,float ice,float wet,float seconds) const {
        constexpr float strain=.25; // Xalaria's published catalogue worlds share this value.
        const float3 offset=phase*float3(31.,17.,47.);
        const float3 qMeso=position/256.+mesoOriginLow;
        const float broad=strataNoise(qMeso*.0625+offset,mesoOriginHigh*.0625);
        const float warp=strataNoise(qMeso*.25+offset+11.,mesoOriginHigh*.25);
        const float middle=strataNoise(qMeso+offset+warp*2.,mesoOriginHigh);
        const float grain=strataNoise(qMeso*4.+offset+31.,mesoOriginHigh*4.);
        const float strata=broad*.50+warp*.30+middle*.20;
        const float slope=1.-saturate(dot(material.normal,up));
        const float dust=smoothstep(.30,.76,warp)*(1.-smoothstep(.08,.5,slope));
        const float layer=(hit.elevation*style.high.w/max(2.,style.fabric.w)+
                           dot(hit.radial,style.fabric.xyz)*.35)*6.283185+warp*.6;
        const float bedding=mix(.5,.5+.5*sin(layer),1.-smoothstep(.6,2.,fwidth(layer)));
        const float vein=xalariaTerrainThread(middle*24.+warp*.8,.035)*
                         (1.-smoothstep(.15,.9,fwidth(middle*24.)));
        const float exposed=smoothstep(.21,.67,bedding*.62+middle*.38)*smoothstep(.10,.59,slope);
        const float weathering=smoothstep(.29,.70,broad*.52+warp*.48);
        float3 deposits=material.albedo*(.66+strata*.38+(grain-.5)*.09+bedding*.14);
        deposits=mix(deposits,deposits*.63+style.bedrock.xyz*.052,exposed*.58);
        deposits=mix(deposits,style.sediment.xyz*(.72+strata*.20),dust*style.process.y*.28);
        material.coatHue=xalariaTerrainPigment(phase+strata*.85+grain*.16);
        const float3 dry=deposits*(.72+material.coatHue*.65);
        const float3 frozen=deposits*float3(.64,.91,1.08)+material.coatHue*.012;
        deposits=mix(deposits,mix(dry,frozen,ice),.32);
        material.albedo=mix(deposits,deposits*.46+xalariaTerrainPigment(phase+middle*.18)*.085,vein*.42);
        material.rough=clamp(material.rough+(grain-.5)*.09+dust*.10+weathering*.14-exposed*.09,.22,.98);
        material.normal=xalariaTerrainBump(material.normal,position,((middle-.5)*.65+(grain-.5)*.10)*8.,.24);
        material.cavity*=mix(.84,1.,smoothstep(.28,.58,middle+grain*.04));
        const float quartz=float(style.low.w==.36);
        const float hot=smoothstep(800.,1350.,temperature)*smoothstep(.35,.80,style.traits.z);
        const float3 seamColour=mix(material.coatHue,mix(float3(1.6,.13,.015),float3(1.9,.55,.06),middle),hot);
        material.microGlow=seamColour*vein*(.016+ice*.028+quartz*.022+hot*.36);

        const float3 q=position/8.+microOrigin;
        const float3 dx=dfdx(q),dy=dfdy(q);
        const float footprint=max(length(dx),length(dy));
        const float resolved=(1.-smoothstep(.12,.75,footprint))*smoothstep(.00002,.0002,footprint);
        float4 field=float4(.5,0.,.5,.5);
        if (resolved>.001) field=xalariaCloseField(texture,q+offset,material.normal,dx,dy);
        const float stone=field.r, crack=field.g, deposit=field.b, grit=field.a;
        const float oldRough=material.rough;
        const float frost=smoothstep(.42,.72,deposit+grit*.13)*ice*(1.-smoothstep(245.,278.,temperature));
        const float seam=crack*(1.-frost*.45)*(.62+.38*strain);
        const float height=((stone-.5)*1.1-seam*(.55+ice*.35)+(grit-.5)*.09)*.36*resolved;
        material.normal=xalariaTerrainBump(material.normal,position,height,.65);
        float3 body=material.albedo*(.63+stone*.55+grit*.16)+xalariaTerrainPigment(phase+deposit*.23)*.035;
        if (ice>.5) {
            body=mix(body,body*.57+float3(.17,.28,.33),frost*.65);
            body=mix(body,body*.18+float3(.003,.010,.034),seam*.82);
            material.rough=mix(.19+grit*.16,.68,frost*.82);
        } else {
            const float dust=smoothstep(.45,.73,deposit)*(1.-crack);
            body=mix(body,body*.79+material.albedo*.14,dust*.40);
            material.rough=clamp(material.rough+(grit-.5)*.18+crack*.10,.18,.99);
        }
        material.rough=mix(oldRough,material.rough,resolved);
        material.microVein=seam*resolved;
        material.cavity*=1.-material.microVein*mix(.38,.50,ice);
        material.albedo=mix(material.albedo,body*material.cavity,resolved*.85);
        material.microGlow+=xalariaTerrainPigment(phase+deposit*.23+.42)*material.microVein*.035;

        if (wet>.02 && ice<.5) {
            const float3 a=float3(31.,0.,17.)*.0981747704, b=float3(-69.,0.,19.)*.0981747704;
            const float3 c=float3(113.,0.,-67.)*.0981747704;
            const float3 wave=float3(dot(q,a)-seconds*.94+phase*2.7,dot(q,b)-seconds*1.41+phase*4.1,
                                    dot(q,c)-seconds*2.37+phase*7.);
            const float3 pixel=abs(float3(dot(dx,a),dot(dx,b),dot(dx,c)))+abs(float3(dot(dy,a),dot(dy,b),dot(dy,c)));
            const float3 resolvedWave=1.-smoothstep(float3(.45),float3(1.65),pixel);
            const float height=dot(sin(wave),resolvedWave*float3(.12,.035,.012))*.36;
            material.normal=xalariaScaledTerrainBump(material.normal,position,height*wet,.38);
            material.rough=mix(material.rough,.13+dot(1.-resolvedWave,float3(.028,.020,.012)),wet*.8);
        }
        return material;
    }
};

float3 terrainLavaCellHash(float3 p){
 p=float3(dot(p,float3(127.1,311.7,74.7)),dot(p,float3(269.5,183.3,246.1)),dot(p,float3(113.5,271.9,124.6)));
 return fract(sin(p)*43758.5453);
}
float terrainLavaPlateGap(float3 p){
 float3 cell=floor(p),local=fract(p);
 float nearest=10.,second=10.;
 for(int z=-1;z<=1;++z)for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){
  float3 offset=float3(float(x),float(y),float(z));
  float3 delta=offset+.20+terrainLavaCellHash(cell+offset)*.60-local;
  float distance=dot(delta,delta);
  second=min(second,max(nearest,distance));nearest=min(nearest,distance);
 }
 return sqrt(second)-sqrt(nearest);
}
float3 terrainLavaProvinces(float3 lit,float3 n,float phase,float temperature,float day){
 float3 p=n*5.8+float3(phase*29.,13.,4.);
 float continent=strataNoise(p,float3(0.));
 float drift=strataNoise(p*2.19+float3(7.,continent*2.,3.),float3(0.));
 float crust=strataNoise(p*6.7+float3(drift*2.,3.,continent),float3(0.));
 float granular=strataNoise(p*21.3+crust*.6,float3(0.));
 float province=continent*.76+drift*.24;
 float cooled=smoothstep(.39,.57,province);
 float pool=1.-smoothstep(.32,.48,province);
 float gap=terrainLavaPlateGap(p*1.37+float3(drift,crust,continent)*.67);
 float footprint=max(.003,fwidth(gap));
 float channel=1.-smoothstep(.009,.027+footprint,gap);
 channel*=1.-smoothstep(.10,.30,footprint);
 float margin=exp(-gap/.095);
 float fineFootprint=max(.002,fwidth(crust));
 float hair=1.-smoothstep(.004,.013+fineFootprint,abs(crust-.50+drift*.12));
 hair*=(1.-smoothstep(.04,.16,fineFootprint))*smoothstep(.41,.66,province);
 float rafts=smoothstep(.40,.69,crust)*(.50+.50*cooled);
 float flow=pool*(1.-rafts*.72);
 // Broad cooling crust has a quiet dark body; incandescent river cores
 // are narrow enough for the surrounding red cooling margins to read.
 float3 basalt=lit*(.40+.47*cooled)*(.63+crust*.36+granular*.11);
 basalt+=float3(.004,.0014,.0007)*cooled*day;
 float thermal=clamp(pow(max(0.,temperature)/1400.,4.),0.,4.);
 float energy=flow*(.014+.035*(1.-crust))+channel*(.020+.034*(1.-cooled))+hair*.003;
 float core=pow(channel,5.)*(.44+.56*crust)+flow*pow(1.-rafts,4.)*.49;
 float3 red=float3(1.48,.038,.003),orange=float3(2.10,.36,.018),yellow=float3(2.75,1.12,.16);
 float3 heat=mix(red,orange,smoothstep(.12,.70,flow+channel*.6));
 heat=mix(heat,yellow,clamp(core,0.,1.));
 // Filtered pressure wrinkles live only on the hot flow, leaving the
 // large plates calm and preventing a globe-wide contour pattern.
 float ropePhase=drift*47.+crust*4.1;
 float rope=mix(.5,.5+.5*cos(ropePhase),1.-smoothstep(.5,1.8,fwidth(ropePhase)));
 energy*=.82+.27*rope;
 return basalt+heat*thermal*(.00035+energy)+red*thermal*margin*.0025;
}

float3 xalariaOrbitalCloudLightWithUp(float3 ground,float3 n,float3 up,float3 view,float3 light,float phase,
                                     float seconds,float pressure,float temperature,float eyeRadius);

template<typename Detail = NoTerrainDetail>
float3 xalariaTerrainLight(TerrainContact hit, TerrainStyle materials,
                           float3 view, float3 light, float3 localEye, float seconds,
                           float visibility, uint region, float temperature, uint worldKind, float cloudDeckPhase,
                           Detail materialDetail = {}) {
    const float3 radial=hit.radial;
    const float3 up=dot(radial,view)>=0. ? radial : -radial;
    float3 n=hit.normal;
    const float facing=dot(n,view);
    if (hit.streamed) {
        if (facing<.025) n=normalize(n+view*(.025-facing));
    } else {
        if (facing<0.) n=-n;
        const float geometricSteep=1.-saturate(dot(up,n));
        n=normalize(mix(up,n,.08+.92*smoothstep(.004,.045,geometricSteep)));
    }
    const float steep=1.-saturate(dot(n,up));
    const float phase=materials.traits.x, elevation=hit.elevation;
    const float air=saturate(materials.process.w*.7), ice=materials.traits.y;
    const float liquid=materials.process.z*smoothstep(235.,275.,temperature)*
                       (1.-smoothstep(340.,410.,temperature));
    const float wet=max(liquid*(1.-smoothstep(-.00088,-.00072,elevation)),materialDetail.wetGround(temperature));
    const float3 authorLight=normalize(float3(-.5,.8,1.));
    const float3 base=hit.streamed ? hit.colour : hit.colour/max(.25,.19+.81*max(0.,dot(radial,authorLight)));
    const float spectralElevation=.5+elevation*32.;
    const float detail=sin(radial.x*13.+sin(radial.z*6.))*.13;
    const float3 mineral=xalariaTerrainPigment(spectralElevation*3.7+phase+detail);
    const float3 tapestry=hit.streamed ? float3(0.) : xalariaTerrainTapestry(radial,phase+.15,seconds);
    const float3 flow=hit.streamed ? float3(0.) : xalariaTerrainSilk(radial,phase,seconds);
    float3 albedo=hit.streamed ? base*.38+mineral*.018 : mix(base,base*.48+mineral*.22+tapestry*.14,.9)*.46;
    albedo=mix(float3(dot(albedo,float3(.299,.587,.114)))*float3(.86,.94,1.),albedo,.82);
    const float3 backdrop=mix(materials.low.xyz,materials.high.xyz,saturate(.45+elevation*50.));
    albedo=mix(albedo,backdrop*.35,.46);
    albedo*=.68+smoothstep(-.0004,.0008,elevation)*.46;
    albedo=mix(albedo,albedo*.68+mineral*.055,smoothstep(.08,.40,steep)*.32);
    const float cover=materials.process.y*(1.-smoothstep(.025,.18,steep));
    const float3 substrate=mix(materials.bedrock.xyz,materials.sediment.xyz,cover);
    const float province=clamp(dot(base,float3(.299,.587,.114)),.15,.9);
    const float3 film=mix(float3(1.),float3(.58)+mineral*.95,.16);
    albedo=mix(albedo,substrate*(.64+province*.62)*film,hit.streamed ? .93 : .76);

    const float3 p=radial*39.+float3(phase*17.,6.,phase*13.);
    const float deposit=strataNoise(p,float3(0.));
    const float chips=strataNoise(p*3.1+deposit*1.7,float3(0.));
    const float strata=strataNoise(p*float3(5.5,10.4,5.5)+elevation*87.,float3(0.));
    const float layer=elevation*1660.+deposit*6.1+chips*1.8;
    const float bedding=(.5+.5*cos(layer))*(1.-smoothstep(.60,2.1,fwidth(layer)));
    const float fracture=pow(max(0.,1.-abs(chips*2.-1.)),8.);
    const float erosion=smoothstep(.40,.72,deposit*.57+chips*.31+strata*.12);
    albedo*=.59+deposit*.37+chips*.31+strata*.14;
    albedo=mix(albedo,albedo*.67+materials.sediment.xyz*.12,erosion*.61);
    albedo=mix(albedo,albedo*(.82+strata*.24)+materials.bedrock.xyz*.11,
               smoothstep(.025,.21,steep)*(bedding*.62+fracture*.31));
    float frost=0.;
    if (ice>.5) {
        frost=smoothstep(-.0004,.0012,elevation)*(1.-smoothstep(.10,.40,steep))*
              (1.-smoothstep(250.,280.,temperature));
        const float layers=elevation*18000.+radial.y*7.;
        const float band=mix(.5,.5+.5*sin(layers),1.-smoothstep(.6,2.,fwidth(layers)));
        const float3 dense=albedo*float3(.32,.56,.72)+float3(.004,.022,.046)+mineral*.022;
        const float3 snow=albedo*.62+float3(.16,.23,.27);
        albedo=mix(dense*(.83+band*.22),snow,frost*.84);
    }
    auto material=materialDetail.apply(TerrainMaterialPoint{n,albedo,mineral,float3(0.),materials.low.w*.88,1.,0.},
                                       hit,materials,up,phase,temperature,ice,wet,seconds);
    n=material.normal;
    albedo=mix(material.albedo,material.albedo*.47+float3(.003,.018,.025),wet*.72);
    float rough=mix(material.rough,.19,wet*.78);
    if (ice>.5) rough=mix(rough,mix(.20,.76,frost),.65);
    const float materialSteep=1.-saturate(dot(n,up));
    const float regolith=(1.-ice)*(1.-wet)*(1.-smoothstep(.10,.38,materialSteep));
    rough=max(rough,mix(.52,.82,regolith)*(1.-wet)*(1.-ice));
    const float materialCover=materials.process.y*(1.-smoothstep(.025,.18,materialSteep));
    rough=mix(mix(materials.bedrock.w,materials.sediment.w,materialCover),rough,saturate(wet+ice));
    const float glaze=saturate(.30+wet*.65+ice*.45);
    rough=mix(rough,.095,glaze);

    const bool verdant=region==1u, tidal=region==2u;
    if (verdant) rough=max(rough,.63);
    if (tidal) rough=max(rough,mix(.34,.16,wet));

    const bool acid=region==3u;
    float4 coating=0.;
    if (acid) {
        rough=max(.80,rough);
        coating=acidSurfaceCoating(radial,phase,hit.streamed);
        albedo=mix(albedo,coating.rgb*.55,.77);
    }

    const float surfaceRange=length(localEye);
    const float orbital=smoothstep(1.003,1.035,surfaceRange);
    if (orbital>.001) {
        const float4 relief=orbitalGeology(radial,normalize(localEye-radial),light,phase);
        const float preserve=(1.-smoothstep(.04,.35,materials.process.w))*(1.-wet)*
                             (1.-smoothstep(750.,1200.,temperature));
        float basinCoverage=0.;
        const float4 basins=preserve>.001 ? impactBasins(radial,light,phase,basinCoverage) : float4(0.,0.,0.,1.);
        float height=((relief.x-.5)*.0015+(relief.y-.5)*.00017)*orbital;
        height=height*(1.-basinCoverage*preserve*.86)+basins.x*preserve*orbital;
        n=materialDetail.orbitalBump(n,hit,height,.47*orbital,materials.high.w);
        const float3 stone=mix(materials.sediment.xyz,materials.bedrock.xyz,smoothstep(.42,.78,relief.x));
        albedo=mix(albedo,albedo*(.52+relief.x*.55+relief.y*.21)+stone*relief.z*.038,
                   orbital*(1.-wet*.85)*(1.-basinCoverage*preserve*.70));
        visibility*=mix(1.,relief.w,orbital*(1.-wet))*mix(1.,basins.w,preserve*orbital);
        albedo*=1.+(basins.y*.44+basins.z*.30-basinCoverage*.24)*preserve*orbital;
    }

    const float3 ndx=dfdx(n),ndy=dfdy(n);
    const float variance=min(.25,max(dot(ndx,ndx),dot(ndy,ndy))*.5);
    rough=pow(min(1.,pow(rough,4.)+variance),.25);
    const float pixelAngle=max(length(dfdx(radial)),length(dfdy(radial)));
    rough=max(rough,mix(.13,.48,smoothstep(.002,.025,pixelAngle)));
    const float fresnel=pow(1.-saturate(dot(n,view)),4.), sunDot=dot(n,light);
    visibility*=materialDetail.sunVisibility(sunDot);
    const float skyDay=smoothstep(-.16,.10,dot(up,light)), day=smoothstep(-.10,.18,sunDot);
    const float3 sunlight=mix(float3(1.),mix(float3(1.18,.40,.16),float3(1.,.96,.88),
                                           smoothstep(-.02,.30,dot(up,light))),air*.80);
    const float metal=materials.traits.w*(1.-regolith*.70)*(verdant ? .28 : acid ? .12 : 1.);
    const float keySide=smoothstep(-.16,.45,sunDot)*visibility;
    float3 lit=xalariaBrdf(albedo,n,view,light,rough,metal)*material.cavity*visibility*sunlight*1.43;
    lit+=diffuseEnvironment(n,up,albedo,skyDay,air)*material.cavity*mix(.20,.70,keySide);
    const float3 reflected=reflectedEnvironment(reflect(-view,n),up,skyDay,phase,rough,light);
    const float3 f0=mix(float3(.035),albedo,metal);
    const float reflectedFill=mix(.28,1.,max(keySide,fresnel*.54));
    lit+=reflected*environmentReflectance(f0,fresnel,rough)*(1.-rough*.65)*material.cavity*(1.+wet*1.4+ice*.38)*
         (verdant ? .26 : acid ? .14 : 1.)*reflectedFill;
    const float regionGlaze=region==0u ? glaze : 0.;
    lit+=reflected*(.10+fresnel*.72)*regionGlaze*material.cavity*reflectedFill;
    lit+=albedo*float3(.12,.36,.45)*ice*pow(1.-saturate(dot(n,view)),2.)*day*.22;
    lit+=material.coatHue*fresnel*(ice*.055+wet*.07)*day;
    const float shoreWidth=max(fwidth(elevation)*1.5,.000012);
    const float shore=1.-smoothstep(shoreWidth,shoreWidth*3.,abs(elevation+.00080));
    const float shoreResolved=1.-smoothstep(.00010,.00060,fwidth(elevation));
    const float3 foam=mix(float3(.24,.34,.31),material.coatHue*.35+.08,.22);
    lit+=foam*shore*shoreResolved*liquid*(1.-ice)*(.06+.36*day)*visibility;
    if (wet>.01 && ice<.5) {
        const float solar=pow(saturate(dot(reflect(-view,n),light)),mix(74.,11.,rough));
        const float broken=1.-smoothstep(.35,.73,strataNoise(radial*215.+phase*8.,float3(0.)));
        const float3 glint=mix(float3(1.08,.54,.24),float3(1.,.94,.76),skyDay);
        lit+=glint*solar*wet*visibility*(.09+.18*broken)*(.28+.72*max(0.,sunDot));
    }
    lit*=materialDetail.gearContact();
    lit+=albedo*pow(saturate(dot(view,light)),4.)*day*visibility*(hit.streamed ? .045 : .012)*material.cavity;
    const float ecPhase=spectralElevation*176.+detail*2.+sin(radial.x*29.+radial.z*17.)*.24;
    const float veins=xalariaTerrainThread(ecPhase,.065);
    const float lace=xalariaTerrainThread(ecPhase*2.7+.25*5.,.025);
    const float3 ecColour=xalariaTerrainPigment(spectralElevation*6.3+phase+radial.z*.18+seconds*.0008);
    lit+=ecColour*(veins*.58+lace*.19)*.28*(.045+.955*day)*(hit.streamed ? .025 : 1.)*.045;
    lit+=(tapestry*(.016+.075*fresnel)*(.12+.88*day)+flow*.012*day)*(hit.streamed ? .12 : 1.)*.045;
    lit+=mix(xalariaTerrainPigment(radial.z*.9+phase+fresnel*.35),material.coatHue,hit.streamed ? .35 : 0.)*
         fresnel*(hit.streamed ? .025 : .15)*(.18+.82*day);
    if (!hit.streamed) {
        const float3 limb=mix(float3(.10,.42,.85),xalariaTerrainPigment(phase+fresnel*.28)*.8,.32);
        lit+=limb*pow(fresnel,.8)*air*(.08+.45*smoothstep(-.15,.25,dot(up,light)));
    }
    lit+=material.microGlow+xalariaTerrainPigment(phase+fresnel*.4)*material.microVein*(.018+fresnel*.16);
    if (worldKind==6u) lit=terrainLavaProvinces(lit,radial,phase,temperature,day);
    if (ice<.5)
        lit=xalariaOrbitalCloudLightWithUp(lit,radial,up,view,light,cloudDeckPhase,seconds,
                                          materials.process.w,temperature,surfaceRange);
    if (regionGlaze>.01)
        lit+=xalariaBrdf(float3(.055,.026,.015),n,view,light,max(.055,rough*.55),.68)*visibility*sunlight*regionGlaze*.65;
    if (acid) lit=acidSurfaceLight(lit,coating,day);
    return mix(base,lit,.96);
}
