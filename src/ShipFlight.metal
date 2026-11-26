// Render the same bubble-local model from the cockpit and through the outer film.
float3 hullSpace(float3 point, constant FlightScene& f) {
    return float3(dot(point,f.shipRight.xyz),dot(point,f.shipUp.xyz),dot(point,f.shipForward.xyz));
}

float hullContact(float3 eye, float3 ray, float3 centre, float3 halfSize, thread float3& normal) {
    const float3 p = eye-centre;
    const float3 inverse = mix(float3(-1.),float3(1.),step(0.,ray))/max(.000001,abs(ray));
    const float3 a = (-halfSize-p)*inverse, b = (halfSize-p)*inverse;
    const float3 enter = min(a,b), leave = max(a,b);
    const float near = max(enter.x,max(enter.y,enter.z));
    const float far = min(leave.x,min(leave.y,leave.z));
    if (near < 0. || far < near) return 100.;
    normal = -sign(ray)*step(near-.00001,enter);
    return near;
}

float4 catalogueSurface(float4 orbit,float4 material,WorldAppearance look,bool legacyRings,bool compact) {
    const float radius=orbit.w;
    const float room=min(.987-orbit.x,radius*(compact ? 2.05 : 3.15));
    if (look.light.w==0.)
        return float4(material.xy,radius*1.32,legacyRings ? min(radius*1.96,room) : 0.);
    const float4 rings=look.annulus;
    const float outer=min(radius*rings.y,room);
    if (rings.z<=0. || outer<=radius*1.03) return float4(material.xy,0.,0.);
    const float inner=radius+(outer-radius)*(rings.x-1.)/max(.001,rings.y-1.);
    return float4(material.xy,inner,outer);
}
FlightBody catalogueBody(device const SystemBubble& system,uint i,float time) {
    if (i==0u)
        return {float4(0.,0.,0.,system.star.w),float4(system.star.xyz,system.catalogue.w),
                float4(0.),float4(0.,1.,0.,time*.045),{}};
    const float4 orbit=system.orbits[i-1u], pigment=system.colours[i-1u], material=system.materials[i-1u];
    const WorldAppearance look=system.appearances[i-1u];
    const float angle=orbit.y+orbit.z*time;
    const float wave=sin(angle);
    const float3 centre=float3(cos(angle),wave*.43,wave*.903)*orbit.x;
    const float3 axis=look.light.w>0. ? look.pole.xyz :
        float3(sin(material.z)*cos(material.w),cos(material.z),sin(material.z)*sin(material.w));
    return {float4(centre,orbit.w),pigment,
            catalogueSurface(orbit,material,look,pigment.w>0.,system.catalogue.z>3.),
            float4(axis,time*.044),look};
}

float3 worldSurfaceFrame(float3 n,float3 axis,float phase) {
    const float3 reference=abs(axis.y)<.95 ? float3(0.,1.,0.) : float3(1.,0.,0.);
    const float3 east=normalize(cross(reference,axis)), north=cross(axis,east);
    const float2 p=rotatePlane(float2(dot(n,east),dot(n,north)),phase);
    return float3(p.x,dot(n,axis),p.y);
}

float3 solidWorldAlbedo(FlightBody body,float3 normal,float3 view,float3 light,float detail,
                        thread float& reliefShadow,thread float* orbitalHeight = nullptr) {
    const WorldAppearance look=body.appearance;
    const float phase=look.dark.w;
    const uint kind=uint(look.light.w);
    const float3 q=worldSurfaceFrame(normal,body.axis.xyz,body.axis.w);
    const float3 sun=worldSurfaceFrame(light,body.axis.xyz,body.axis.w);
    const float3 eye=worldSurfaceFrame(view,body.axis.xyz,body.axis.w);
    const float3 dark=kind>0u ? look.dark.rgb : body.colour.xyz*.22;
    const float3 bright=kind>0u ? look.light.rgb : body.colour.xyz*1.20;
    const float3 seed=float3(phase*181.,phase*57.+4.2,phase*83.+19.);
    const float broad=strataNoise(q*mix(3.2,6.9,phase)+seed,float3(0.));
    const float ridge=strataNoise(q*14.5+seed.zxy+broad*.86,float3(37.,17.,0.));
    const float small=strataNoise(q*46.+seed.yzx+ridge*.71,float3(15.,8.,0.));
    const float snow=look.features.w, water=look.features.z;
    const float land= broad*.60+ridge*.28+small*.12;
    const float sediment=look.features.y;
    float relief=smoothstep(.26,.74,land);
    reliefShadow=1.;
    if (detail<.044) {
        const float4 geology=orbitalGeology(q,eye,sun,phase);
        relief=mix(relief,smoothstep(.17,.76,geology.x*.73+geology.y*.19+geology.z*.08),.39);
        reliefShadow=geology.w;
        if (orbitalHeight) *orbitalHeight=(geology.x-.5)*.0015+(geology.y-.5)*.00017;
    }
    float3 ground=mix(dark,bright,smoothstep(.18,.78,relief+sediment*.15));

    if (kind==4u) { // Oceanic
        const float shore=smoothstep(.460,.525,land);
        const float shoal=smoothstep(.385,.51,land)*(1.-shore);
        const float3 deep=mix(dark*.48,float3(.012,.056,.106),.52);
        const float3 coastal=mix(dark,float3(.085,.32,.27),.67);
        ground=mix(deep,coastal,shoal*.91);
        ground=mix(ground,mix(dark*.85,bright,relief),shore);
        const float ice=smoothstep(.68,.94,abs(q.y)+.23*(broad-.5))*snow;
        ground=mix(ground,float3(.77,.87,.88),ice);
    } else if (kind==5u || snow>.28) { // Ice shells and frost-covered regolith
        // Frozen worlds can share the same bulk composition. Retain the
        // independent seed's difference in fracture scale and exposed crust.
        const float crust=strataNoiseSample(seed*.35+7.3,float3(0.));
        const float field=mix(4.4,15.5,fract(phase*3.11+.25));
        const float folds=strataNoise(q*float3(field,field*2.75,field*.80)+seed+ridge*1.44,float3(0.));
        const float rifts=exp(-abs(folds-.49)*mix(16.,39.,crust))*(.29+.71*ridge);
        const float bloom=smoothstep(.27,.78,broad*.52+ridge*.29+small*.19+(crust-.5)*.28);
        const float cap=smoothstep(.60,.95,abs(q.y)+.29*(ridge-.5));
        const float3 bed=mix(dark,float3(.034,.108,.22),crust*.62);
        const float3 frost=mix(bright,float3(.76,.87,.93),.24)*mix(.66,1.13,crust);
        const float3 ice=mix(bed,frost,bloom*mix(.68,1.,crust));
        ground=mix(ground,ice*(1.-rifts*.68)+frost*.19*cap,max(snow,kind==5u ? .87 : .0));
    } else if (kind==3u) { // Dry dunes and windswept bedrock
        const float dunes=sin((ridge*.36+q.y+sin(q.x*8.+phase*7.)*.17)*104.);
        const float wind=mix(.5,.5+.5*dunes,1.-smoothstep(.4,1.95,fwidth(dunes)));
        ground*=.71+.32*wind+.22*small;
    } else if (kind==6u) { // Hot fractures
        const float cracks=exp(-abs(ridge-.52)*34.)*smoothstep(.27,.72,small+broad*.34);
        ground+=float3(.93,.10,.012)*cracks;
    }
    const float preserved=(1.-smoothstep(.015,.36,water))*(1.-smoothstep(.06,.26,look.pole.w));
    if (preserved>.02 && detail<.078) {
        float coverage;
        const float4 craters=impactBasins(q,sun,phase,coverage);
        const float weight=preserved*(.68+.32*phase);
        ground*=1.-coverage*.22*weight;
        ground+=bright*(craters.y*.19+craters.z*.13)*weight;
        reliefShadow*=mix(1.,craters.w,weight*.75);
        if (orbitalHeight) *orbitalHeight=*orbitalHeight*(1.-coverage*weight*.86)+craters.x*weight;
    }
    const float cloudiness=max(body.surface.y,kind==4u ? water*.48 : look.pole.w*.03);
    if (!orbitalHeight && cloudiness>.015) {
        const float3 plume=q*11.+seed*.59;
        const float humidity=strataNoise(plume,float3(0.));
        const float wisps=strataNoise(plume*2.75+humidity*1.28,float3(0.));
        const float clouds=smoothstep(.53,.70,humidity*.71+wisps*.29);
        ground=mix(ground,float3(.73,.80,.83),clouds*cloudiness*.61);
    }
    if (orbitalHeight) {
        const float3 province=q*39.+float3(phase*17.,6.,phase*13.);
        const float deposit=strataNoise(province,float3(0.));
        const float chips=strataNoise(province*3.1+deposit*1.7,float3(0.));
        const float strata=strataNoise(province*float3(5.5,10.4,5.5)+*orbitalHeight*87.,float3(0.));
        const float erosion=smoothstep(.40,.72,deposit*.57+chips*.31+strata*.12);
        ground*=.59+deposit*.37+chips*.31+strata*.14;
        ground=mix(ground,ground*.67+bright*.12,erosion*.61);
    }
    return ground;
}

float4 ringProfile(FlightBody body) {
    const float radius=body.position.w;
    const bool catalogue=body.appearance.light.w>0.;
    return float4(body.surface.zw/radius,catalogue ? body.appearance.annulus.z : .24,
                  catalogue ? body.appearance.annulus.w : fract(radius*617.3));
}

struct OrbitalLayers {
    float depth, geometryDepth, stellarCoverage;
    float4 rings;
};

float xalariaRingGrainHash(float2 p) {
    float3 q=fract(p.xyx*.1031);
    q+=dot(q,q.yzx+33.33);
    return fract((q.x+q.y)*q.z);
}

float xalariaRingGrain(float2 p) {
    const float2 cell=floor(p);
    float2 f=fract(p);
    f=f*f*(3.-2.*f);
    return mix(mix(xalariaRingGrainHash(cell),xalariaRingGrainHash(cell+float2(1.,0.)),f.x),
               mix(xalariaRingGrainHash(cell+float2(0.,1.)),xalariaRingGrainHash(cell+float2(1.,1.)),f.x),f.y);
}

float3 xalariaOrbitalBump(float3 normal,float height,float maxSlope) {
    float3 dx=dfdx(normal),dy=dfdy(normal);
    const float span=max(max(abs(dx.x),max(abs(dx.y),abs(dx.z))),max(abs(dy.x),max(abs(dy.y),abs(dy.z))));
    if (span<=1.e-20) return normal;
    dx/=span; dy/=span;
    const float3 a=cross(dy,normal),b=cross(normal,dx);
    const float det=dot(dx,a);
    float3 gradient=sign(det)*((dfdx(height)/span)*a+(dfdy(height)/span)*b)/max(abs(det),1.e-10);
    gradient*=min(1.,maxSlope/max(length(gradient),.001));
    return normalize(normal-gradient);
}

float3 xalariaWorldLight(float3 albedo,float3 normal,float3 radial,float3 view,float3 light,
                         FlightBody body,float phase,float visibility,uint look,float cloudDeckPhase,
                         float eyeRadius,float seconds) {
    const bool giant=body.surface.x>.95;
    const bool acid=!giant && look==3u;
    const float pressure=body.appearance.pole.w;
    const float air=giant ? 1. : saturate(pressure*.7);
    const float ice=giant ? 0. : body.appearance.features.w;
    float rough=giant ? .83 : mix(.68,.42,ice);
    float4 coating=0.;
    if (!giant) {
        if (look==1u) rough=max(rough,.63);
        if (acid) {
            rough=max(rough,.80);
            coating=acidSurfaceCoating(radial,phase,false);
            albedo=mix(albedo,coating.rgb*.55,.77);
        }
    }
    const float angle=max(length(dfdx(radial)),length(dfdy(radial)));
    rough=max(rough,mix(.13,.48,smoothstep(.002,.025,angle)));
    const float sunDot=dot(normal,light), radialDot=dot(radial,light);
    const float skyDay=smoothstep(-.16,.10,radialDot);
    const float3 sunlight=mix(float3(1.),mix(float3(1.18,.40,.16),float3(1.,.96,.88),
                                          smoothstep(-.02,.30,radialDot)),air*.80);
    const float keySide=smoothstep(-.16,.45,sunDot)*visibility;
    float3 lit=xalariaBrdf(albedo,normal,view,light,rough,0.)*visibility*sunlight*1.43;
    lit+=diffuseEnvironment(normal,radial,albedo,skyDay,air)*mix(.20,.70,keySide);
    const float mu=saturate(dot(radial,view));
    if (giant) {
        const float dawn=smoothstep(-.28,.25,radialDot);
        const float3 cloudRim=mix(float3(.38,.20,.09),float3(.56,.68,.83),dawn);
        lit+=albedo*dawn*.19+cloudRim*pow(1.-mu,3.)*dawn*visibility*.32;
    }
    const float fresnel=pow(1.-saturate(dot(normal,view)),4.);
    const float3 reflected=reflectedEnvironment(reflect(-view,normal),radial,skyDay,phase,rough,light);
    const float reflectedFill=mix(.28,1.,max(keySide,fresnel*.54));
    const float regionalReflection=look==1u ? .26 : look==3u ? .14 : 1.;
    lit+=reflected*environmentReflectance(float3(.035),fresnel,rough)*(1.-rough*.65)*
         (1.+ice*.38)*regionalReflection*reflectedFill;
    if (!giant && look==0u)
        lit+=reflected*(.10+fresnel*.72)*saturate(.30+ice*.45)*reflectedFill;
    const float day=smoothstep(-.10,.18,sunDot);
    lit+=albedo*float3(.12,.36,.45)*ice*(1.-mu)*(1.-mu)*day*.22;
    if (body.surface.x<.08 && ice<.5)
        lit=xalariaOrbitalCloudLight(lit,radial,view,light,cloudDeckPhase,seconds,pressure,body.colour.w,eyeRadius);
    if (acid) lit=acidSurfaceLight(lit,coating,day);
    return lit;
}

float xalariaDaylightExposure(constant FlightScene& flight) {
    if (flight.atmosphere.z<=0.) return 1.;
    const FlightBody world=flight.bodies[uint(flight.atmosphere.x)];
    const float3 eye=(flight.eye.xyz-world.position.xyz)/world.position.w;
    const float range=length(eye);
    if (range<=.99) return 1.;
    const float height=max(0.,range-1.)/max(1.e-6,flight.atmosphere.y);
    const float sunrise=dot(eye/range,normalize(flight.bodies[0].position.xyz-world.position.xyz));
    return exp(-world.appearance.pole.w*exp(-height)*smoothstep(-.16,.08,sunrise)*14.);
}

template<typename Terrain = PreviewTerrainSource, typename Weather = PreviewWeatherSource>
float4 orbitalInterior(float3 eye, float3 ray, float membrane, float pixel,
                       constant FlightScene* flight, bool showShip, device const SystemBubble* system, float time, bool hyperion = false,
                       thread OrbitalLayers* layers = nullptr, Terrain terrain = {}, Weather weather = {}) {
    float reach = 100., ringDepth = 100., ringOpacity = 0., solidOpacity = 0.;
    float3 solidColour = 0., ringColour = 0., glow = 0.;
    float3 stellarPoint = 0.;
    float stellarPointDepth = 0.;
    float ringOccluder = 100.;
    bool litWorld=false;
    const float3 star = system ? float3(0.) : flight->bodies[0].position.xyz;
    const uint count = system ? 1u+uint(system->catalogue.z) : uint(flight->navigation.z);
    const float seconds = system ? time : flight->screen.y;
    const float daylight=hyperion ? xalariaDaylightExposure(*flight) : 1.;
    for (uint i=0; i<count; ++i) {
        const FlightBody body = system ? catalogueBody(*system,i,time) : flight->bodies[i];
        const float radius = body.position.w;
        const float3 centre = body.position.xyz;
        const float3 delta = centre-eye;
        const float depth = dot(delta,ray);
        if (depth+max(radius*2.,body.surface.w) <= membrane || depth > reach+body.surface.w+radius)
            continue;
        const float radial = length(cross(delta,ray));
        const float footprint=max(hyperion ? 1e-14 : .00003,pixel*depth);
        const float soft = clamp(footprint/radius,.005,.37);
        if (hyperion && i==0u && depth>0. && footprint>radius) {
            const float pointSpread=radial/max(footprint*.92,radius);
            stellarPoint=body.colour.xyz*exp2(-2.3*pointSpread*pointSpread)*
                         min(1.,radius/footprint)*.88*daylight;
            stellarPointDepth=depth;
        }
        if (!hyperion && i==0u && radial<radius*2.15) {
            const float rim=exp2(-5.7*max(0.,radial/radius-1.));
            glow+=body.colour.xyz*rim*.28*smoothstep(membrane,membrane+radius*.57,depth);
        }
        if (body.surface.w > 0. && radial < body.surface.w+footprint) {
            const float facing = dot(ray,body.axis.xyz);
            if (abs(facing) > (hyperion ? .00001 : .013)) {
                const float t = dot(delta,body.axis.xyz)/facing;
                const float r=length(ray*t-delta)/radius;
                const float width=clamp(max(footprint/max(.18,abs(facing)),fwidth(r)*radius)/radius,.001,.32);
                const float4 annulus=ringProfile(body);
                const float ring=xalariaRingDensity(annulus,r,width);
                if (t>membrane && t<ringDepth && ring>0.) {
                    const float3 ringPoint=eye+ray*t;
                    const float3 orbitLight=normalize(star-ringPoint);
                    const float shadow=dot(centre-ringPoint,orbitLight)>0. ?
                        smoothstep(radius*.96,radius*1.06,length(cross(centre-ringPoint,orbitLight))) : 1.;
                    const float path=max(.10,abs(dot(orbitLight,body.axis.xyz)));
                    const float face=dot(orbitLight,body.axis.xyz)*(-facing);
                    const float scattering=exp(-ring*(face<0. ? .71 : .24)/path);
                    const float forward=powr(saturate(dot(ray,orbitLight)),9.);
                    const float back=powr(saturate(-dot(ray,orbitLight)),4.);
                    const float exposure=.095+shadow*(.92+.88*sqrt(path)+forward*1.62+back*.64)*scattering;
                    const float location=saturate((r-annulus.x)/max(.001,annulus.y-annulus.x));
                    const float3 dust=mix(float3(1.19,.91,.64),float3(.73,.93,1.22),smoothstep(.34,.86,location));
                    const float ice=body.appearance.light.w>0. ? body.appearance.features.w : .45;
                    const float3 particles=mix(float3(.25,.16,.10),float3(.80,.77,.65),ice);
                    const float grain=strataNoise((ringPoint-centre)/radius*146.+annulus.w*31.,float3(0.));
                    ringOpacity=(1.-exp(-ring/max(.08,abs(facing))))*smoothstep(.014,.075,abs(facing));
                    const float3 tint=body.appearance.light.w>0. ? body.appearance.light.rgb : float3(.62);
                    const float3 reflected=mix(particles,particles*tint*1.18,.27);
                    const float shelf=mix(.76,1.19,smoothstep(.16+annulus.w*.31,.71+annulus.w*.16,location));
                    ringColour=reflected*dust*exposure*shelf*(.63+ring*.90+grain*.28);
                    if (hyperion) {
                        const float3 local=(ringPoint-centre)/radius;
                        const float3 axis=body.axis.xyz;
                        const float3 east=normalize(cross(axis,abs(axis.y)<.9 ? float3(0.,1.,0.) : float3(1.,0.,0.)));
                        const float2 sampleAt=float2(dot(local,east),dot(local,cross(east,axis)))*146.+annulus.w*31.;
                        const float grains=1.-smoothstep(.38,1.40,max(length(dfdx(sampleAt)),length(dfdy(sampleAt))));
                        const float texture=xalariaRingGrain(sampleAt);
                        const float strata=.80+.28*smoothstep(.12,.57,location)-.14*smoothstep(.71,.95,location);
                        ringColour=particles*dust*exposure*(strata+ring*1.09)*(1.+(texture-.5)*.42*grains);
                        ringColour+=particles*shadow*back*pow(texture,5.)*grains*.11;
                        ringOpacity=1.-exp(-ring/max(.08,abs(facing)));
                        if (uint(flight->optics.x)==1u) {
                            const float logDistance=log10(max(1.,t*flight->drive.x));
                            const float haze=(smoothstep(1.2,5.,logDistance)*.38+smoothstep(6.8,14.4,logDistance)*.31)*.87;
                            ringColour=mix(ringColour,float3(.044,.102,.034),haze);
                        }
                    }
                    ringDepth = t;
                }
            }
        }
        const float miss = radial/radius;
        const TerrainStyle ground=hyperion && i>0u && body.surface.x<.08 ? terrain.style(i) : TerrainStyle{};
        const bool native=ground.process.x>0.;
        if (miss >= 1.+ground.process.x+soft) continue;
        const float3 perpendicular=cross(ray,cross(ray,delta))/radius;
        const TerrainContact surface=native ?
            terrain.contact(i,perpendicular,ray,1.+ground.process.x,footprint/radius,
                            (membrane-depth)/radius) : TerrainContact{};
        if (native && surface.coverage<=0.) continue;
        const float t = depth+radius*(native ? surface.distance : -sqrt(max(0.,1.-miss*miss)));
        if (t <= membrane || t >= reach) continue;
        // Streamed triangles will write the solid and actual depth after the
        // sky draw. Keep the analytic limb here only to clip far-side rings.
        if (hyperion && i==uint(flight->terrainView.y)) {
            ringOccluder=min(ringOccluder,t);
            continue;
        }
        const float3 normal=native ? surface.radial :
            normalize(perpendicular-ray*sqrt(max(0.,1.-miss*miss)));
        const float3 light=normalize(star-centre+float3(1e-12));
        const float3 axis = body.axis.xyz;
        litWorld=i!=0u;
        solidOpacity = native ? surface.coverage : 1.-smoothstep(1.-soft,1.+soft,miss);
        reach = t;
        if (i == 0u) {
            if (hyperion) {
                solidColour=typedPhotosphere(normal,body.colour.xyz,saturate(dot(normal,-ray)),
                                              seconds,flight->drive.z,flight->stellar)*daylight;
            } else {
                const float2 coord=normal.xz*6.8+normal.y*float2(2.8,4.4)+body.axis.w*.16;
                const float low=fbm(coord);
                const float photosphere=fbm(coord*3.0+float2(7.9,14.2));
                solidColour = mix(body.colour.xyz,float3(1.,.88,.34),.29+.66*low)*
                              (1.30+photosphere*.80);
            }
            continue;
        }
        const float opticalDetail=footprint/radius;
        const WorldAppearance look=body.appearance;
        const bool hasLook=look.light.w>0.;
        const float phase=hasLook ? look.dark.w : fract(radius*437.11+body.colour.y*2.7);
        float landShadow=1.;
        float3 albedo=0.;
        float cloudHeight=.5, terrainHeight=0.;
        if (!native && body.surface.x>.08) {
            const float3 low=hasLook ? look.dark.rgb : body.colour.xyz*.58;
            const float3 high=hasLook ? look.light.rgb : mix(body.colour.xyz,float3(.88,.77,.64),.44);
            const float jets=hasLook ? max(1.,look.features.x) : mix(8.,18.,phase);
            const float contrast=hasLook ? look.features.y : .42;
            const float haze=hasLook ? look.features.z : .48;
            const float3 clouds=hyperion ?
                xalariaClouds(normal,axis,low,high,light,phase,seconds,jets,contrast,cloudHeight)*.48 :
                giantClouds(normal,axis,low,high,light,phase,seconds*49.,jets,contrast,haze,look.light.w);
            albedo=body.surface.x<.96 ?
                mix(solidWorldAlbedo(body,normal,-ray,light,opticalDetail,landShadow),clouds,body.surface.x) : clouds;
        } else if (!native) {
            albedo=solidWorldAlbedo(body,normal,-ray,light,opticalDetail,landShadow,hyperion ? &terrainHeight : nullptr);
        }
        const float shadow = body.surface.w > body.surface.z ? dot(axis,light) : 0.;
        float ringShadow = 1.;
        if (abs(shadow) > .013) {
            const float tRing = -dot(normal,axis)*radius/shadow;
            if (tRing > 0.) {
                const float rRing = length(normal*radius+tRing*light);
                const float4 annulus=ringProfile(body);
                const float optical=xalariaRingDensity(annulus,rRing/radius,max(.001,footprint/radius));
                ringShadow=exp(-optical*1.8/(hyperion ? max(.08,abs(shadow)) : 1.));
            }
        }
        const float sunlight = smoothstep(-.23,.96,dot(normal,light))*ringShadow;
        const float limb=exp2(-24.*abs(miss-.957));
        const float air=body.surface.x>.95 ? look.features.z : min(.84,look.pole.w*.34+body.surface.y*.36);
        const float projected=hyperion && body.surface.x<.08 ? weather.sun(normal,light,i,*flight) : 1.;
        if (native) {
            solidColour=xalariaTerrainLight(surface,ground,-ray,light,-delta/radius,seconds,
                                           ringShadow*projected,uint(flight->optics.x),body.colour.w,uint(look.light.w),
                                           flight->cloudDeckPhases[i]);
        } else if (hyperion) {
            if (body.surface.x<.95) albedo*=.68;
            const float3 shadingNormal=body.surface.x>.95
                ? xalariaOrbitalBump(normal,(cloudHeight-.5)*.0010,.22)
                : xalariaOrbitalBump(normal,terrainHeight,.47);
            solidColour=xalariaWorldLight(albedo,shadingNormal,normal,-ray,light,body,phase,
                                           ringShadow*landShadow*projected,uint(flight->optics.x),flight->cloudDeckPhases[i],
                                           length(delta)/radius,seconds);
        } else {
            solidColour=albedo*(.10+1.24*sunlight)*landShadow+
                        limb*mix(body.colour.xyz,float3(.36,.62,.81),.56)*air*.31;
        }
    }

    if (showShip) {
        constant FlightScene& f = *flight;
        const float3 delta = f.ship.xyz-eye;
        const float along = dot(delta,ray);
        if (along > membrane && along < reach+.04 && length(cross(delta,ray)) < .055) {
            const float3 localEye = hullSpace(-delta,f), localRay = hullSpace(ray,f);
            float3 partNormal, nearestNormal;
            float3 paint = float3(.45,.73,.79);
            float hit = hullContact(localEye,localRay,float3(0.),float3(.0044,.0038,.011),nearestNormal);
            for (int side=-1; side<=1; side+=2) {
                const float3 nozzle = float3(float(side)*.0062,-.0017,-.007);
                const float t = hullContact(localEye,localRay,nozzle,float3(.0028,.0021,.0048),partNormal);
                if (t < hit) { hit=t; nearestNormal=partNormal; paint=float3(.80,.35,.12); }
                const float3 plume = delta+f.shipRight.xyz*nozzle.x+f.shipUp.xyz*nozzle.y+
                                     f.shipForward.xyz*(-.014-.014*f.screen.z);
                const float rz = length(cross(plume,ray));
                const float glowWidth = .0012+.0024*f.screen.z+pixel*along*.48;
                const float visibility = dot(plume,ray) < reach ? 1. : 0.;
                glow += float3(1.,.42,.11)*exp2(-rz*rz/(glowWidth*glowWidth))*
                        (.20+.52*f.screen.z)*visibility;
            }
            if (hit > membrane && hit < reach) {
                reach = hit;
                solidOpacity = 1.;
                const float3 light = hullSpace(normalize(star-f.ship.xyz),f);
                solidColour = paint*(.38+max(0.,dot(normalize(nearestNormal),light)));
            } else {
                const float size = max(.0006,pixel*along);
                const float gleam = exp2(-length(cross(delta,ray))/size*1.8);
                glow += float3(.62,.82,.91)*gleam*.30;
            }
        }
    }
    const float ring = ringDepth < min(reach,ringOccluder) ? ringOpacity : 0.;
    const float coverage = solidOpacity+(1.-solidOpacity)*ring;
    if (layers) {
        layers->depth=litWorld && solidOpacity>.5 ? reach : 0.;
        layers->geometryDepth=solidOpacity>.5 ? reach : 0.;
        layers->stellarCoverage=litWorld ? 0. : solidOpacity;
        layers->rings=float4(ringColour*ring,ring);
        glow+=stellarPoint*(litWorld && reach<stellarPointDepth ? 1.-solidOpacity : 1.);
        return float4(solidColour*solidOpacity+glow,solidOpacity);
    }
    return float4(mix(solidColour*solidOpacity,ringColour,ring)+glow,coverage);
}

float4 ziksaInterior(float3 eye, float3 ray, float membrane, float pixel,
                     constant FlightScene& f, bool showShip) {
    return orbitalInterior(eye,ray,membrane,pixel,&f,showShip,nullptr,f.screen.y);
}

float4 catalogueInterior(device const SystemBubble& system, float3 eye, float3 ray,
                         float membrane, float pixel, float time) {
    return orbitalInterior(eye,ray,membrane,pixel,nullptr,false,&system,time);
}

float3 exteriorRay(float2 uv,constant FlightScene& f) {
    const float2 q=(uv*2.-1.)*float2(f.screen.x,-1.)/xalariaFocal;
    return normalize(f.forward.xyz+f.right.xyz*q.x+f.up.xyz*q.y);
}

struct FlightExteriorLayers {
    half4 radiance [[color(0)]];
    half4 rings [[color(1)]];
    float depth [[color(2)]];
    float hardwareDepth [[depth(any)]];
};

constant float flightTerrainNear = .06;

fragment FlightExteriorLayers flightSky(Full in [[stage_in]],constant FlightScene& f [[buffer(0)]],
                                        texture2d<half> currentWeather [[texture(5)]],
                                        texture2d<half> followingWeather [[texture(6)]],
                                        texture2d_array<float> terrainAtlas [[texture(8)]],
                                        constant TerrainStyle* styles [[buffer(8)]],
                                        constant float4& terrainPatch [[buffer(10)]]) {
    const float3 ray=exteriorRay(in.uv,f);
    const float pixel=max(length(dfdx(ray)),length(dfdy(ray)));
    const uint look=uint(f.optics.x);
    float3 space=xalariaSpace(ray,look,f.drive.w,f.screen.y)*xalariaDaylightExposure(f);
    if (f.drive.y>.01) {
        const float2 sensor=(in.uv*2.-1.)*float2(f.screen.x,-1.)/xalariaFocal;
        const float r=length(sensor);
        const float angle=atan2(sensor.y,sensor.x);
        const float lane=(angle+pi)*(89./tau);
        const float segment=floor(lane);
        const float grain=hash(segment+19.);
        const float line=exp(-abs(fract(lane)-.5)*46.);
        const float travel=fract(grain+f.screen.y*(1.7+hash(segment+61.)*1.8));
        const float front=mix(.13,1.47,travel);
        const float wake=smoothstep(front-.39,front-.045,r)*(1.-smoothstep(front-.04,front,r));
        const float band=line*wake*smoothstep(.14,.51,r)*smoothstep(.46,.96,grain);
        space+=f.drive.y*.25*band*mix(float3(.25,.66,1.),float3(.86,.91,1.),grain);
    }
    OrbitalLayers layers{};
    const NativeTerrainSource terrain{terrainAtlas,styles,terrainPatch};
    const NativeWeatherSource weather{currentWeather,followingWeather};
    const float4 bodies=orbitalInterior(f.eye.xyz,ray,0.,pixel,&f,false,nullptr,f.screen.y,true,&layers,terrain,weather);
    const float unitsToDepth=max(.0001,dot(ray,f.forward.xyz))*f.drive.x;
    const float metres=layers.depth*unitsToDepth;
    const float geometryMetres=layers.geometryDepth*unitsToDepth;
    return {half4(half3(space*(1.-bodies.a)+bodies.rgb),half(layers.stellarCoverage)),half4(layers.rings),metres,
            geometryMetres>0. ? saturate(flightTerrainNear/geometryMetres) : 0.};
}

struct FlightTerrainVertex {
    float4 position, colour, normal;
};

struct FlightTerrainSample {
    float4 screen [[position]];
    float3 relativeMetres;
    float3 colour;
    float4 normal;
};

struct FlightTerrainMaterialFrame {
    float4 planetEye, microOrigin, mesoOriginLow, mesoOriginHigh;
};

vertex FlightTerrainSample flightTerrainVertex(uint i [[vertex_id]],
                                                 device const FlightTerrainVertex* vertices [[buffer(0)]],
                                                 constant FlightScene& f [[buffer(1)]]) {
    const FlightTerrainVertex point=vertices[i];
    const float3 p=point.position.xyz;
    const float4 screen=float4(dot(p,f.right.xyz)*xalariaFocal/f.screen.x,
                               dot(p,f.up.xyz)*xalariaFocal,flightTerrainNear,dot(p,f.forward.xyz));
    return {screen,p,point.colour.rgb,point.normal};
}

struct FlightTerrainLayers {
    half4 radiance [[color(0)]];
    float depth [[color(2)]];
};

fragment FlightTerrainLayers flightTerrainPixel(FlightTerrainSample in [[stage_in]],
                                                   constant FlightScene& f [[buffer(1)]],
                                                   constant FlightTerrainMaterialFrame& frame [[buffer(2)]],
                                                   constant TerrainStyle& style [[buffer(3)]],
                                                   constant FlightTerrainSun& sun [[buffer(4)]],
                                                   texture2d<half> current [[texture(5)]],
                                                   texture2d<half> following [[texture(6)]],
                                                   texture2d<float> material [[texture(9)]],
                                                   depth2d<float> shadowMap [[texture(10)]]) {
    const uint i=uint(frame.planetEye.w);
    const FlightBody body=f.bodies[i];
    const float3 local=frame.planetEye.xyz+in.relativeMetres/style.high.w;
    const float3 radial=normalize(local);
    const float3 light=normalize(f.bodies[0].position.xyz-body.position.xyz+float3(1.e-12));
    const float3 view=normalize(-in.relativeMetres);
    const TerrainContact contact{in.colour,radial,normalize(in.normal.xyz),in.normal.w,0.,1.,true};
    const float4 annulus=ringProfile(body);
    float ringShadow=1.;
    const float lightAngle=dot(light,body.axis.xyz);
    if (annulus.z>0. && annulus.y>annulus.x && abs(lightAngle)>=.0001) {
        const float t=-dot(radial,body.axis.xyz)/lightAngle;
        const float ringRadius=length(radial+light*t);
        if (t>0.) {
            const float optical=xalariaRingDensity(annulus,ringRadius,max(.001,fwidth(ringRadius)));
            ringShadow=exp(-optical/max(.08,abs(lightAngle))*1.8);
        }
    }
    const NativeWeatherSource weather{current,following};
    const float visibility=ringShadow*weather.sun(radial,light,i,f);
    const XalariaNearTerrainDetail detail{material,shadowMap,&sun,in.relativeMetres,frame.microOrigin.xyz,
                                         frame.mesoOriginLow.xyz,frame.mesoOriginHigh.xyz,f.terrainView.z};
    const float3 colour=xalariaTerrainLight(contact,style,view,light,frame.planetEye.xyz,f.screen.y,
                                            visibility,uint(f.optics.x),body.colour.w,uint(body.appearance.light.w),
                                            f.cloudDeckPhases[i],detail);
    const float metres=dot(in.relativeMetres,f.forward.xyz);
    return {half4(half3(colour),0.),metres};
}

struct CabinSystem {
    float4 p [[position]];
    float2 local;
    uint index [[flat]];
};

vertex CabinSystem cabinSystemVertex(uint id [[vertex_id]], uint index [[instance_id]],
                                      constant FlightScene& f [[buffer(0)]],
                                      device const SystemBubble* systems [[buffer(1)]]) {
    device const SystemBubble& system=systems[index];
    const uint key=uint(system.catalogue.x);
    const float x=float(key%200u),y=float(key/200u);
    const float lift=1.5*sin(x*.105+1.3)*cos(y*.083)+.7*sin((x+y)*.047+.4);
    const float3 centre=float3(system.position.x,.052*lift,system.position.y);
    const float3 delta=centre-f.eye.xyz;
    const float depth=dot(delta,f.forward.xyz);
    if (depth<=1e-7) return {float4(0.,0.,-1.,1.),float2(0.),index};
    const float2 uv=(patch(id,1,1)*2.-1.)*1.40;
    const float2 offset=float2(dot(delta,f.right.xyz),dot(delta,f.up.xyz));
    // Systems at interstellar distance register as resolved points of light.
    const float glare=max(1.4e-8,depth*.0015);
    const float2 clip=(offset+glare*uv)*xalariaFocal/float2(f.screen.x,1.);
    return {float4(clip,depth*.99,depth),uv,index};
}

fragment half4 cabinSystemLight(CabinSystem in [[stage_in]],
                                device const SystemBubble* systems [[buffer(1)]],
                                device const float* colours [[buffer(2)]],
                                constant float& time [[buffer(3)]],
                                constant float4& layer [[buffer(4)]]) {
    const float r2=dot(in.local,in.local);
    const float core=exp2(-12.*r2);
    const float halo=exp2(-4.7*r2);
    const float soft=1.-smoothstep(.92,1.80,r2);
    const float energy=core*1.05+halo*.43;
    device const SystemBubble& system=systems[in.index];
    const float colour=bubbleColourAt(colours[uint(system.catalogue.x)],time);
    const float3 pigment=displayBubbleChroma(system.star.xyz,float4(layer.rgb,colour));
    return half4(half3(pigment*energy*soft),0.);
}

struct CabinVertex { packed_float3 p; uint colour; packed_float3 normal; };
struct CabinPixel {
    float4 p [[position]];
    float3 local, normal;
    float4 paint [[flat]];
};

struct ShipPose {
    float4 position, right, up, forward, drive;
};

struct ShipPixel {
    float4 p [[position]];
    float3 world, local, normal;
    float4 paint [[flat]];
};

vertex ShipPixel worldShipVertex(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                                 device const CabinVertex* mesh [[buffer(1)]],
                                 constant ShipPose& ship [[buffer(2)]]) {
    const auto vert = mesh[id];
    const float3x3 basis = float3x3(ship.right.xyz,ship.up.xyz,ship.forward.xyz);
    const float3 local = float3(vert.p);
    const float3 point = ship.position.xyz+basis*local*ship.position.w;
    const float3 clip = projectWorld(point,s);
    const uint paint = vert.colour;
    const float4 rgba = float4(paint&255u,(paint>>8u)&255u,(paint>>16u)&255u,paint>>24u);
    return {float4(clip.xy,clip.z-.12,clip.z),point,local,basis*float3(vert.normal),
            float4(rgba.xyz/255.,rgba.w)};
}

struct ShipLight { half4 colour [[color(0)]]; half range [[color(1)]]; };

float3 shipBounce(float3 direction, constant float4* lights) {
    const float3 w = direction*direction;
    const float3 light = w.x*lights[direction.x>=0. ? 0 : 1].rgb+
                         w.y*lights[direction.y>=0. ? 2 : 3].rgb+
                         w.z*lights[direction.z>=0. ? 4 : 5].rgb;
    return light/(1.+.38*max(light.r,max(light.g,light.b)));
}

fragment ShipLight worldShipLight(ShipPixel in [[stage_in]], constant Scene& s [[buffer(0)]],
                                  constant ShipPose& ship [[buffer(2)]], constant float4* lights [[buffer(3)]]) {
    if (ship.drive.y < hash21(floor(in.p.xy))) discard_fragment();
    const float3 view = normalize(s.eye.xyz-in.world);
    const float3 surface = normalize(in.normal);
    const float3 normal = dot(surface,view) >= 0. ? surface : -surface;
    const float3 key = normalize(float3(-.53,.78,-.29)+s.sun.xyz*.24);
    const float lit = saturate(dot(normal,key));
    const float sky = .5+.5*normal.y;
    const float rim = powr(1.-saturate(dot(normal,view)),2.6);
    const float glint = powr(saturate(dot(normal,normalize(key+view))),25.);
    const uint material = uint(in.paint.w)>>4u;
    const float lamps = float(uint(in.paint.w)&15u)/15.;
    const float grit = .92+.14*noise(in.local.xz*76.+in.local.y*61.);
    const float3 albedo = powr(in.paint.xyz,float3(1.32))*grit;
    const float3 bounced = shipBounce(normal,lights);
    const float3 sheen = shipBounce(reflect(-view,normal),lights);
    const float3 neutral = float3(.90,.87,.80);
    float3 colour = albedo*(.15+.17*sky+.78*lit*neutral);
    colour += bounced*(.085+.64*albedo)+sheen*(.055+.34*rim);
    colour += neutral*(.056*glint+.028*rim);
    if (material == 4u && lamps == 0.) colour += .19*sheen+.08*neutral*glint;
    if (lamps > 0.) {
        const bool engine = in.local.z < -1.17;
        colour += in.paint.xyz*lamps*(engine ? .88+1.17*ship.drive.x+.72*ship.drive.z : .71);
    }
    if (s.searchlightOrigin.w > 0.) {
        if (material == 11u) colour += searchlightColour*2.8;
        else if (material == 10u) colour += searchlightColour*(.58+.30*lit);
        else {
            const float3 fromLamp = (in.world-s.searchlightOrigin.xyz)/ship.position.w;
            const float falloff = exp2(-13.*dot(fromLamp,fromLamp));
            colour += searchlightColour*(falloff*(.045+.13*rim));
        }
    }
    const float depth = dot(in.world-s.eye.xyz,s.forward.xyz);
    return {half4(half3(colour),1.),half(depth)};
}

struct Exhaust { float4 p [[position]]; float2 uv; float2 drive [[flat]]; };

vertex Exhaust worldExhaustVertex(uint id [[vertex_id]], constant Scene& s [[buffer(0)]],
                                   constant ShipPose& ship [[buffer(2)]]) {
    constexpr uint verticesPerEngine = 48u;
    const float side = id < verticesPerEngine ? -1. : 1.;
    const float2 q = patch(id%verticesPerEngine,1,verticesPerEngine/6u);
    const float t = q.y;
    const float3 nozzle = ship.position.xyz+ship.position.w*
        (ship.right.xyz*(side*.65)+ship.up.xyz*(-.03)-ship.forward.xyz*1.37);
    const float3 centre = nozzle-ship.forward.xyz*t*ship.position.w*(.53+2.55*ship.drive.x+1.25*ship.drive.z);
    const float width = mix(.11,.026,t)*(1.+.42*ship.drive.z);
    const float3 point = centre+s.right.xyz*((q.x*2.-1.)*width*ship.position.w);
    const float3 clip = projectWorld(point,s);
    return {float4(clip.xy,clip.z-.12,clip.z),float2(q.x*2.-1.,t),
            float2(ship.drive.x*ship.drive.y,ship.drive.z)};
}

fragment half4 worldExhaustLight(Exhaust in [[stage_in]], constant Scene& s [[buffer(0)]]) {
    const float across = in.uv.x, distance = in.uv.y;
    const float strand = exp2(-6.4*across*across)*(1.-smoothstep(.56,1.,abs(across)));
    const float pulse = .89+.11*sin(distance*19.-s.celestialTime*15.);
    const float opacity = strand*powr(max(0.,1.-distance),1.7)*pulse*in.drive.x*.77;
    const float3 outer = mix(float3(.048,.48,1.),float3(.39,.19,1.),in.drive.y*.53);
    const float3 tint = mix(float3(.67,.96,1.),outer,smoothstep(-.06,.63,distance));
    return half4(half3(tint*opacity*(.98+.67*in.drive.y)),half(opacity));
}

float3 moveYoke(float3 p,float3 controls) {
    p.xy = rotatePlane(p.xy,controls.z);
    p.yz = rotatePlane(p.yz,controls.x);
    return rotateY(p,controls.y);
}

float3 cabinCamera(float3 local, constant FlightScene& f) {
    return float3(dot(local,f.cabinRight.xyz),dot(local,f.cabinUp.xyz),dot(local,f.cabinForward.xyz));
}
float4 cabinClip(float3 point, constant FlightScene& f) {
    const float3 view=cabinCamera(point-f.cabinOffset.xyz,f);
    const float depth=cabinFar*(view.z-cabinNear)/(cabinFar-cabinNear);
    return float4(view.xy*xalariaFocal/float2(f.screen.x,1.),depth,view.z);
}
float2 cabinProject(float3 point,constant FlightScene& f) {
    const float4 clip=cabinClip(point,f);
    return .5+.5*clip.xy*float2(1.,-1.)/max(.001,clip.w);
}

vertex CabinPixel flightCabinVertex(uint id [[vertex_id]],device const CabinVertex* mesh [[buffer(1)]],
                                    constant FlightScene& f [[buffer(0)]],constant uint& pose [[buffer(2)]]) {
    const CabinVertex v=mesh[id];
    float3 p=float3(v.p),normal=float3(v.normal);
    if (pose==1u) {
        const float3 pivot=float3(0.,-.640,-.888);
        p=pivot+moveYoke(p-pivot,f.controls.xyz);
        normal=moveYoke(normal,f.controls.xyz);
    }
    if (pose==2u) p.z-=.265*f.controls.w;
    if (pose==3u) { p.x=-p.x; normal.x=-normal.x; }
    const uint paint=v.colour;
    const float4 rgba=float4(paint&255u,(paint>>8u)&255u,(paint>>16u)&255u,paint>>24u)/255.;
    return {cabinClip(p,f),p,normal,rgba};
}

struct CabinLight { half4 colour [[color(0)]], finish [[color(1)]]; };

fragment CabinLight flightCabinLight(CabinPixel in [[stage_in]],constant FlightScene& f [[buffer(0)]]) {
    const float3 view=normalize(f.cabinOffset.xyz-in.local);
    const float3 base=normalize(in.normal);
    const float3 normal=dot(base,view)>=0. ? base : -base;
    float4 finish;
    const float3 lamp=shadeCabin(in.paint.rgb,in.paint.a,in.local,in.local,normal,view,cabinSunDirection(f),finish,f);
    const float3 viewed=cabinCamera(finish.xyz,f);
    return {half4(half3(lamp),1.),half4(half3(viewed),half(finish.w))};
}

fragment CabinLight flightCanopyLight(CabinPixel in [[stage_in]],constant FlightScene& f [[buffer(0)]],
                                     texture2d<half> sky [[texture(0)]]) {
    constexpr sampler lens(coord::normalized,address::clamp_to_edge,filter::linear);
    const float3 p=in.local,V=normalize(f.cabinOffset.xyz-p);
    const float3 base=normalize(in.normal),N=dot(base,V)>=0. ? base : -base;
    const float facing=saturate(dot(N,V)),fresnel=.023+.54*powr(1.-facing,4.);
    const float3 reflected=reflect(-V,N);
    const bool cargo=p.z>3.72;
    const float3 reflection=cargo ? deckFixtureReflection(p,reflected,.095) : cabinFixtureReflection(p,reflected,.14);
    const float reflectedEnergy=max(reflection.r,max(reflection.g,reflection.b));
    const float grime=strataNoise(p*float3(23.,47.,23.)+4.,float3(0.));
    const float wipe=strataNoise(p*float3(5.,77.,5.)+float3(17.,3.,9.),float3(0.));
    const float specks=smoothstep(.54,.81,grime*.66+wipe*.34);
    const float forwardLight=powr(saturate(dot(-V,cabinSunDirection(f))),44.);
    const float film=(.023+specks*(cargo?.028:.055)+forwardLight*.064)*(.52+.48*(1.-facing));
    const float reflectOpacity=fresnel*(.19+reflectedEnergy*.77);
    const float3 tint=mix(in.paint.rgb*.19,cabinWindowLight(uint(f.optics.x))*.57,forwardLight*.67+specks*.17);
    const float3 spec=saturate(reflection*.87+in.paint.rgb*.23);
    const float2 uv=cabinProject(p,f);
    const float3 transmitted=refract(-V,N,1./1.49);
    const float3 shear=transmitted-V*dot(transmitted,V);
    const float2 pixel=1./float2(sky.get_width(),sky.get_height());
    const float2 offset=clamp(cabinProject(p+shear*(.022+specks*.012),f)-uv,-pixel*7.,pixel*7.);
    const float border=smoothstep(0.,.04,min(min(uv.x,uv.y),min(1.-uv.x,1.-uv.y)));
    const float resolved=smoothstep(.42,1.35,length(offset/pixel));
    const float weight=(.06+.22*powr(1.-facing,1.4)+.04*specks)*border*resolved*smoothstep(.035,.23,facing);
    const float3 image=float3(sky.sample(lens,uv+offset*border).rgb);
    const float alpha=clamp(film+reflectOpacity+weight,0.,.66);
    return {half4(half3(film*tint+reflectOpacity*spec+weight*image),half(alpha)),half4(0.)};
}

struct InstrumentVertex { packed_float3 p; packed_float2 uv; uint colour; };
struct InstrumentPixel { float4 p [[position]]; float2 uv; float4 colour [[flat]]; };

vertex InstrumentPixel flightInstrumentVertex(uint id [[vertex_id]],device const InstrumentVertex* points [[buffer(1)]],
                                               constant FlightScene& f [[buffer(0)]]) {
    const auto v=points[id];
    const uint c=v.colour;
    return {cabinClip(float3(v.p),f),float2(v.uv),
            float4(c&255u,(c>>8u)&255u,(c>>16u)&255u,c>>24u)/255.};
}
vertex InstrumentPixel flightOverlayVertex(uint id [[vertex_id]],device const InstrumentVertex* points [[buffer(1)]],
                                            constant FlightScene& f [[buffer(0)]]) {
    const auto v=points[id];
    const uint c=v.colour;
    const float2 clip=float2(v.p.x/(900.*f.screen.x),1.-v.p.y/900.)*2.-1.;
    return {float4(clip,0.,1.),float2(v.uv),float4(c&255u,(c>>8u)&255u,(c>>16u)&255u,c>>24u)/255.};
}
fragment half4 flightInstrumentLight(InstrumentPixel in [[stage_in]],texture2d<half> font [[texture(0)]]) {
    constexpr sampler atlas(coord::normalized,address::clamp_to_edge,filter::linear);
    float alpha=in.colour.a;
    if (in.uv.x>=0.) {
        const float coverage=float(font.sample(atlas,in.uv).r);
        const float edge=max(.018,fwidth(coverage)*.56);
        alpha*=smoothstep(.5-edge,.5+edge,coverage);
    }
    return half4(half3(in.colour.rgb*alpha),half(alpha));
}

struct StringStroke { float4 start, end, film; };
struct StringPixel {
    float4 p [[position]];
    float2 local;
    float3 span [[flat]]; // Projected length, world radius and pixel footprint.
    float4 depthAndPath [[flat]];
    float4 film [[flat]];
};

vertex StringPixel stringStrokeVertex(uint vertexID [[vertex_id]], uint instance [[instance_id]],
                                      constant float4& display [[buffer(0)]],
                                      constant StringStroke* strokes [[buffer(1)]]) {
    const StringStroke stroke = strokes[instance];
    const float2 delta = stroke.end.xy-stroke.start.xy;
    const float size = length(delta);
    const float2 tangent = size > .00001 ? delta/size : float2(1.,0.);
    const float2 normal = float2(-tangent.y,tangent.x);
    const bool knot = stroke.film.w == 2.;
    const float radius = stroke.film.w == 6. ? .14 : knot ? .073 : stroke.film.w >= 3. ? .037 : .018;
    const float2 inv = 1./float2(stroke.start.z,stroke.end.z);
    const float pixel = 2./display.y;
    const float pad = 3.9*clamp(radius*focal*max(inv.x,inv.y),.86*pixel,.022)+pixel;
    const bool end = (vertexID & 2u) != 0u;
    const float2 local = float2(end ? size+pad : -pad,(vertexID & 1u) ? pad : -pad);
    const float2 point = stroke.start.xy+tangent*local.x+normal*local.y;
    return {float4(point/float2(display.x,1.),0.,1.),local,float3(size,radius,pixel),
            float4(inv,inv*float2(stroke.start.w,stroke.end.w)),stroke.film};
}

fragment half4 stringStrokeLight(StringPixel in [[stage_in]], constant Scene& s [[buffer(0)]],
                                 texture2d<half,access::read> hull [[texture(3)]],
                                 texture2d<half,access::read> hullRange [[texture(4)]]) {
    const float size = in.span.x, pixel = in.span.z;
    const float fraction = saturate(in.local.x/max(.00001,size));
    const float2 inv = in.depthAndPath.xy;
    const float depth = 1./mix(inv.x,inv.y,fraction);
    const float2 endpoints = in.depthAndPath.zw/inv;
    const float path = clamp(mix(in.depthAndPath.z,in.depthAndPath.w,fraction)*depth,0.,1.);
    const float endFade = min(path,1.-path);
    const float material = in.film.w;
    const bool strand = material <= 1.;
    const bool targeted = material == 1.;
    const bool knot = material == 2.;
    const float radius = in.span.y*focal/depth;
    const float neck = exp2(-55.*endFade);
    const float width = clamp(radius*(strand ? 1.+.52*neck : 1.),.86*pixel,.022);
    const float distance = length(float2(in.local.x-clamp(in.local.x,0.,size),in.local.y));
    const float profile = distance/width;
    const float core = exp2(-2.8*profile*profile);
    const float fringe = exp2(-.57*profile*profile);
    // Adjacent sections meet with a soft seam. Free ends and knots keep their soft caps.
    const float lead = endpoints.x > .00001 ? smoothstep(-pixel,pixel,in.local.x) : 1.;
    const float tail = endpoints.y < .99999 ? smoothstep(-pixel,pixel,size-in.local.x) : 1.;
    const float haze = exp(-depth*(targeted ? .0065 : .018));
    const float visible = in.film.z*lead*tail*haze*hullTransmission(depth,uint2(in.p.xy),hull,hullRange);
    if (material == 6.) {
        const float edge = profile-(.48+2.3*in.film.x);
        const float ring = .70*exp2(-17.*edge*edge)+.18*core;
        return half4(half3(float3(.97,.83,.45)*ring*visible),half(ring*visible*.62));
    }
    if (material == 7.) {
        const float offset=path-in.film.x;
        const float spark=exp2(-152.*offset*offset);
        const float glow=(.10+.94*spark)*(core+.15*fringe)*visible;
        return half4(half3(float3(.98,.83,.44)*glow),half(.65*glow));
    }
    const float glintPhase = path*26.-1.78*s.celestialTime+5.1*in.film.x;
    const float glint = powr(.5+.5*cos(glintPhase),10.);
    const float flecks = .72+.28*noise(float2(path*64.,s.celestialTime*.86+9.*in.film.y));
    const float contact = strand ? neck*.35 : 0.;
    const float3 membrane = mix(pigment(in.film.x),pigment(in.film.y),path);
    const float3 tint = mix(membrane,s.bright.xyz,.52);
    const bool harpoon = material == 5.;
    const float tip = harpoon ? exp2(-48.*(1.-path)) : 0.;
    const float3 colour = harpoon ? float3(.29,.75,1.) : targeted || material == 4. ? float3(1.,.27,.105) :
                         knot ? float3(.96,.66,.24) : tint;
    const float3 silk = mix(colour,float3(1.,.94,.71),.30+.43*glint);
    const float radiance = strand ? .44+.30*glint+contact+.18*float(targeted) : .89+.76*tip;
    const float3 light = silk*core*radiance*flecks+colour*fringe*(.079+.08*glint);
    return half4(half3(light*visible),half((.48*core+.19*fringe)*visible));
}

struct StringContact { float4 position, normal, tangent, film; };
struct StringContactPixel {
    float4 p [[position]];
    float2 uv;
    float depth;
    float4 light [[flat]]; // Hue, visibility, pull and cut highlight.
};

vertex StringContactPixel stringContactVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                                               constant Scene& s [[buffer(0)]],
                                               constant StringContact* anchors [[buffer(1)]]) {
    const StringContact site = anchors[instance];
    const float2 uv = patch(id,4,4)*2.8-1.4;
    const float3 normal = site.normal.xyz, tangent = site.tangent.xyz;
    const float3 bitangent = cross(normal,tangent);
    const float size = site.position.w;
    const float3 plane = size*(tangent*uv.x*(1.+.25*site.film.y)+bitangent*uv.y);
    const float bend = -.5*dot(plane,plane)/max(.00001,site.film.x);
    const float lip = size*.036*exp2(-8.*dot(uv,uv));
    const float3 world = site.position.xyz+plane+normal*(bend+lip);
    const float3 clip = projectWorld(world,s);
    const float toward = dot(normal,normalize(s.eye.xyz-site.position.xyz));
    const float facing = mix(.20,1.,smoothstep(-.33,.44,toward));
    const float sun = .64+.36*saturate(.45+.65*dot(normal,s.sun.xyz));
    return {float4(clip.xy,clip.z-.12,clip.z),uv,clip.z,
            float4(site.tangent.w,facing*sun*site.normal.w,site.film.yz)};
}

fragment half4 stringContactLight(StringContactPixel in [[stage_in]], constant Scene& s [[buffer(0)]],
                                   texture2d<half,access::read> hull [[texture(3)]],
                                   texture2d<half,access::read> hullRange [[texture(4)]]) {
    const float2 uv = in.uv;
    const float r = length(uv);
    const float margin = max(.056,.36*fwidth(r));
    const float seam = .59+.14*in.light.z*uv.x+.043*sin(5.1*uv.x-3.4*uv.y);
    const float edgeWidth = abs(r-seam)/margin;
    const float rim = exp2(-1.72*edgeWidth*edgeWidth)*(.51+.49*smoothstep(-.63,.32,uv.x-.48*uv.y));
    const float film = exp2(-3.3*r*r);
    const float join = exp2(-29.*r*r);
    const float3 dye = mix(pigment(in.light.x),s.bright.xyz,.55);
    const float3 tint = in.light.w > .5 ? float3(1.,.27,.105) : mix(dye,float3(1.,.78,.49),.27);
    const float beat = .88+.12*cos(s.celestialTime*2.5+9.*in.light.x);
    const float strength = in.light.y*exp(-.021*in.depth)*
                           hullTransmission(in.depth,uint2(in.p.xy),hull,hullRange);
    const float3 light = tint*(.20*film+.47*rim)+mix(tint,float3(1.,.94,.72),.76)*join*beat*.91;
    return half4(half3(light*strength),half((.22*film+.26*rim+.38*join)*strength));
}

struct ShipReticle {
    float4 p [[position]];
    float2 local;
    float3 ink [[flat]];
    float opacity [[flat]];
};

vertex ShipReticle shipReticleVertex(uint vertexID [[vertex_id]], constant float4& display [[buffer(0)]],
                                     constant float4& sight [[buffer(1)]]) {
    const float2 corner = float2((vertexID & 1u) ? 1. : -1., (vertexID & 2u) ? 1. : -1.);
    const float3 white = float3(.89,.98,1.);
    const float3 mint = float3(.50,1.,.84), gold = float3(1.,.86,.53);
    const float3 copper = float3(1.,.73,.57), coral = float3(1.,.47,.33);
    const float3 blue = float3(.34,.87,1.), dimBlue = float3(.69,.81,1.);
    const float3 ink = sight.z == 7. ? copper : sight.z == 6. ? blue : sight.z == 5. ? dimBlue :
                       sight.z == 4. ? coral : sight.z == 3. ? copper : sight.z == 2. ? gold :
                       sight.z == 1. ? mint : white;
    return {float4((sight.xy+corner*.043)/float2(display.x,1.),0.,1.),corner,ink,sight.w};
}

fragment half4 shipReticleLight(ShipReticle in [[stage_in]]) {
    const float2 p = abs(in.local);
    const float2 axis = float2(max(p.x,p.y),min(p.x,p.y));
    const float2 box = float2(abs(axis.x-.61)-.225,axis.y-.048);
    const float ticks = length(max(box,0.))+min(max(box.x,box.y),0.);
    const float shape = min(ticks,length(in.local)-.075);
    const float aa = max(.001,fwidth(shape)*.70);
    const float stroke = 1.-smoothstep(-aa,aa,shape);
    const float outline = .88*(1.-smoothstep(.075-aa,.075+aa,shape));
    const float3 dark = float3(.017,.028,.037);
    return half4(half3(mix(dark*outline,in.ink,stroke)*in.opacity),
                 half(mix(outline,1.,stroke)*in.opacity));
}

// The exterior depth buffer stores metres. Zero denotes empty sky, including
// the analytic photosphere and its glow.
constant sampler cockpitLinear(coord::normalized,address::clamp_to_edge,filter::linear);
constant sampler cockpitPoint(coord::normalized,address::clamp_to_edge,filter::nearest);
constant sampler apertureLinear(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);
constant float skyDepthMetres=1.e20;

float opaqueMetres(texture2d<float> depth,float2 uv) {
    return depth.sample(cockpitPoint,uv).r;
}

float cameraDepth(texture2d<float> ranges,float2 uv) {
    const float depth=opaqueMetres(ranges,uv);
    return depth>0. ? depth : skyDepthMetres;
}

float cameraDefocus(float depth,float focus) {
    return smoothstep(.035,.65,abs(depth-focus)/max(depth,focus));
}

float stellarFlux(constant FlightScene& f) {
    const float flux=saturate(f.optics.w/.0015);
    return flux*flux*xalariaDaylightExposure(f);
}

float stellarDepth(constant FlightScene& f) {
    const float3 sun=f.bodies[0].position.xyz;
    const float radius=f.bodies[0].position.w;
    return f.drive.x*max(0.,dot(sun,f.forward.xyz)-radius);
}

float stellarVisibility(texture2d<float> ranges,constant FlightScene& f) {
    if (f.stellarImage.w<=0.) return 0.;
    const float radius=f.stellarImage.z;
    const float2 spread=float2(radius/f.screen.x,radius)*.60;
    const float distance=stellarDepth(f)*.97;
    float open=0.;
    const float2 taps[]={float2(0.,0.),float2(1.,0.),float2(-1.,0.),float2(0.,1.),float2(0.,-1.)};
    for (uint i=0;i<5u;++i) {
        const float d=opaqueMetres(ranges,f.stellarImage.xy+taps[i]*spread);
        open+=(d<=0. || d>=distance) ? .20 : 0.;
    }
    return min(open,f.stellarImage.w);
}

float3 stellarLens(float2 uv,float pixelHeight,constant FlightScene& f) {
    if (f.stellarImage.w<=0.) return 0.;
    // Hyperion's integrated horizontal streak and aureole, in HDR before the film curve.
    const float2 sun=uv-f.stellarImage.xy;
    const float radius=max(f.stellarImage.z,pixelHeight*.35);
    const float r=length(sun*float2(f.screen.x,1.))/radius;
    const float aureole=(exp(-r*r*.18)*.045+exp(-r*.8)*.015)*f.optics.y;
    const float halfWidth=pixelHeight*1.5, a=sun.y-halfWidth, b=sun.y+halfWidth;
    const float integral=sign(b)*(1.-exp(-abs(b)*950.))-sign(a)*(1.-exp(-abs(a)*950.));
    const float streak=integral/max(1900.*halfWidth,.0001)*exp(-abs(sun.x)*3.5);
    const float2 ghost=(uv-(.5-(f.stellarImage.xy-.5)*.38))*float2(f.screen.x,1.);
    const float halo=exp(-abs(length(ghost)-.13)*190.);
    const float3 light=f.bodies[0].colour.rgb;
    const float3 flare=mix(light,float3(1.,.60,.22),.20)*.30;
    return (light*aureole+flare*(streak*.14+halo*.03))*f.stellarImage.w*stellarFlux(f);
}

float luminance(float3 colour) { return dot(colour,float3(.299,.587,.114)); }

float3 resolveExterior(texture2d<half> scene,float2 uv,float2 pixel) {
    float3 c=float3(scene.sample(cockpitLinear,uv).rgb);
    const float3 a=float3(scene.sample(cockpitLinear,uv+float2(-1.,-1.)*pixel).rgb);
    const float3 b=float3(scene.sample(cockpitLinear,uv+float2(1.,-1.)*pixel).rgb);
    const float3 d=float3(scene.sample(cockpitLinear,uv+float2(-1.,1.)*pixel).rgb);
    const float3 e=float3(scene.sample(cockpitLinear,uv+float2(1.,1.)*pixel).rgb);
    const float centre=sqrt(max(luminance(c),0.));
    const float nw=sqrt(max(luminance(a),0.)),ne=sqrt(max(luminance(b),0.));
    const float sw=sqrt(max(luminance(d),0.)),se=sqrt(max(luminance(e),0.));
    const float lo=min(centre,min(min(nw,ne),min(sw,se))),hi=max(centre,max(max(nw,ne),max(sw,se)));
    if (hi-lo>max(.035,hi*.14)) {
        float2 edge=float2(-(nw+ne-sw-se),nw+sw-ne-se);
        edge=clamp(edge/(min(abs(edge.x),abs(edge.y))+max(.008,(nw+ne+sw+se)*.03125)),-6.,6.)*pixel;
        const float3 narrow=.5*(float3(scene.sample(cockpitLinear,uv+edge*.167).rgb)+
                                float3(scene.sample(cockpitLinear,uv-edge*.167).rgb));
        const float3 wide=narrow*.5+(float3(scene.sample(cockpitLinear,uv+edge*.5).rgb)+
                                     float3(scene.sample(cockpitLinear,uv-edge*.5).rgb))*.25;
        const float candidate=sqrt(max(luminance(wide),0.));
        c=mix(c,candidate<lo || candidate>hi ? narrow : wide,.88);
    }
    const float contrast=(hi-lo)/max(hi,.02);
    const float clarity=(1.-smoothstep(.12,.32,contrast))*smoothstep(.015,.08,luminance(c));
    return max(float3(0.),c+(c-(a+b+d+e)*.25)*clarity*.24);
}

bool clearForRefraction(texture2d<half> scene,texture2d<float> ranges,float2 uv) {
    // Native Hyperion composites the star after bending the sky. Its disc
    // must remain fixed here, including samples on its antialiased silhouette.
    return opaqueMetres(ranges,uv)==0. && scene.sample(cockpitLinear,uv).a==0.;
}

float3 refractExterior(float3 original,float2 uv,float3 ray,texture2d<half> scene,texture2d<float> ranges,
                      constant FlightScene& f,float depth) {
    const float2 fold=spaceGlassFold(ray,f.drive.w,f.screen.y);
    const float thickness=spaceGlassThickness(fold);
    const float2 aspectCorrection=float2(1./f.screen.x,1.);
    float2 slope=float2(dfdx(thickness)/max(1e-7,abs(dfdx(uv.x))),
                        dfdy(thickness)*sign(dfdy(uv.y))/max(1e-7,abs(dfdy(uv.y))))*aspectCorrection;
    slope/=sqrt(1.+dot(slope,slope));
    if (depth>0. || !clearForRefraction(scene,ranges,uv)) return original;
    const float boundary=smoothstep(0.,.06,min(min(uv.x,uv.y),min(1.-uv.x,1.-uv.y)));
    const float edge=exp(-abs(sin(fold.x*2.25+.13*sin(fold.y*3.7)))*4.);
    const float opposing=exp(-abs(sin(fold.y*2.60+.16*cos(fold.x*2.3)+1.3))*5.4);
    const float2 bend=slope*aspectCorrection*(.003+.014*edge+.003*opposing)*1.75*boundary;
    const float2 through=clamp(uv+bend,.001,.999),inside=clamp(uv-bend*.62,.001,.999);
    const float clearA=float(clearForRefraction(scene,ranges,through)),clearB=float(clearForRefraction(scene,ranges,inside));
    float3 refracted=float3(scene.sample(cockpitLinear,through).rgb);
    const float2 fringe=clamp(through+bend*.27,.001,.999);
    if (clearForRefraction(scene,ranges,fringe))
        refracted.g=mix(refracted.g,float(scene.sample(cockpitLinear,fringe).g),edge*.33);
    const float3 c=mix(original,refracted,(.28+.43*edge)*clearA*boundary);
    return mix(c,float3(scene.sample(cockpitLinear,inside).rgb),(.045+.17*edge+.13*opposing)*clearB*boundary);
}

float3 stellarProminences(float3 ray,constant FlightScene& f,float pixelHeight,float starDepth,float depth){
 float radius=f.stellarImage.z;
 float kind=f.stellar.x;
 float resolved=smoothstep(9.,26.,radius/max(pixelHeight,1e-8));
 if(f.stellarImage.w<=0. || resolved<=0. || kind<.5 || kind>6.5)return float3(0.);
 float3 toStar=normalize(f.bodies[0].position.xyz);
 float3 normal=cross(toStar,ray);
 float r=length(normal)/max(sin(f.optics.w),1e-8);
 if(dot(ray,toStar)<=0. || r<.992 || r>2.70)return float3(0.);
 if(depth>0. && depth<starDepth*.97)return float3(0.);
 float3 horizontal=normalize(f.right.xyz-toStar*dot(f.right.xyz,toStar));
 float3 vertical=cross(horizontal,toStar);
 float3 local=normalize(cross(normal,toStar));
 float2 radial=float2(dot(local,horizontal),-dot(local,vertical));
 float altitude=r-1.;
 float phase=f.stellar.w;
 float seconds=f.screen.y;
 float spin=fract(seconds*f.drive.z)*6.283;
 float aa=max(pixelHeight/radius,.002);
 float3 envelope=stellarCoronaEnvelope(local,max(0.,altitude),aa,phase,f.bodies[0].colour.rgb);
 if(r>1.53)return envelope*resolved*stellarFlux(f);
 float density=strataNoise(local*float3(19.,10.,19.)+phase*13.,float3(0.));
 float threads=strataNoise(local*62.+float3(0.,0.,altitude*10.),float3(0.));
 float plume=exp(-max(0.,altitude)/(.075+.26*density*density));
 float current=strataNoise(local*float3(27.,13.,24.)+float3(altitude*7.,phase*11.,seconds*.06),float3(0.));
 float streamer=pow(clamp(threads*.66+current*.34,0.,1.),4.)*
                exp(-altitude/(.067+.26*density*density));
 float chromosphere=exp(-altitude/max(.013,aa))*smoothstep(.24,.68,density);
 float3 corona=f.bodies[0].colour.rgb*(plume*(.009+.13*pow(density,2.5)+threads*.031)+
                              streamer*.45+chromosphere*.47);
 for(int i=0;i<4;i++){
  float index=float(i);
  float heading=phase*6.283+index*2.39996+spin;
  float latitude=.16+.38*sin(index*2.17+phase*7.);
  float3 pole=normalize(float3(cos(heading),latitude,sin(heading)));
  float2 projected=float2(dot(horizontal,pole),-dot(vertical,pole));
  float limbVisibility=smoothstep(.62,.97,length(projected));
  float2 axis=normalize(projected+float2(1e-8,0.));
  float arc=atan2(radial.x*axis.y-radial.y*axis.x,dot(radial,axis));
  float width=.13+.12*fract(index*.73+phase);
  if(abs(arc)>width)continue;
  float rise=.10+.18*fract(index*.47+phase*1.7);
  float arch=pow(max(0.,1.-arc*arc/(width*width)),.74)*rise;
  arch*=.93+.07*sin(seconds*.42+index*2.3);
  float distanceToArch=abs(altitude-arch);
  float core=exp(-distanceToArch/max(.010,aa*.7));
  float hair=exp(-abs(altitude-arch*.77-.012)/max(.008,aa*.65))+
             exp(-abs(altitude-arch*1.16-.007)/max(.006,aa*.56))*.49;
  float halo=exp(-distanceToArch/.045)*.24;
  float detail=.38+.62*threads;
  corona+=f.bodies[0].colour.rgb*(core*.87+hair*.31+halo)*limbVisibility*detail;
 }
 float limb=smoothstep(.992,1.02,r)*(1.-smoothstep(1.34,1.53,r));
 return (corona*limb+envelope*smoothstep(.992,1.02,r))*resolved*stellarFlux(f);
}

float3 fogExterior(float3 scene,float2 uv,float3 direction,float depth,constant FlightScene& f) {
    const float2 source=(uv-f.stellarImage.xy)*float2(f.screen.x,1.);
    const float sunGlow=exp(-dot(source,source)*26.)*f.stellarImage.w*sqrt(stellarFlux(f));
    if (depth>0.) {
        const float drift=sin(f.screen.y*.055)*.17;
        const float beltAxis=(direction.y+.29*sin(direction.z*4.1+direction.x*1.6))*2.25;
        const float belt=exp(-beltAxis*beltAxis);
        const float logDistance=log10(depth/max(.0001,dot(direction,f.forward.xyz)));
        const float haze=smoothstep(1.2,5.,logDistance)*.38+smoothstep(6.8,14.4,logDistance)*.31;
        const float cloud=strataNoiseSample(direction*3.4+float3(3.,17.,8.+drift),float3(0.));
        float3 aerial=mix(float3(.009,.032,.018),float3(.080,.165,.048),.20+.42*belt+.22*cloud);
        aerial+=float3(.36,.35,.085)*sunGlow;
        return mix(scene,aerial,haze*mix(.73,1.03,cloud));
    }
    float transmission;
    const float3 fog=xalariaFog(direction,f.screen.y,sunGlow,transmission);
    const float disc=(1.-smoothstep(.90,1.13,length(source)/max(.00001,f.stellarImage.z)))*f.stellarImage.w;
    return scene*mix(transmission,max(.57,transmission),disc)+fog*(1.-disc*.35);
}

float2 atmosphereSpan(float3 eye,float3 ray,float radius) {
    const float3 radial=cross(eye,ray);
    const float h=radius*radius-dot(radial,radial);
    if (h<0.) return float2(-1.);
    const float offset=-dot(eye,ray),width=sqrt(h);
    return float2(offset-width,offset+width);
}

float solarColumn(float radius,float mu,float heightScale,float density) {
    float outward=abs(mu);
    float curvature=max(0.,1.-outward*outward)*2.54648*heightScale/radius;
    float tail=density*2.*heightScale/max(1e-5,outward+sqrt(outward*outward+curvature));
    if(mu>=0.)return tail;
    float tangent=max(1.,radius*sqrt(max(0.,1.-mu*mu)));
    float whole=sqrt(6.2831853*tangent*heightScale)*exp(-(tangent-1.)/heightScale);
    return max(tail,whole-tail);
}

float3 atmosphere(float3 d,float depth,float2 cloudClip,constant FlightScene& f,thread float3& transmission) {
    transmission=float3(1.);
    if (f.atmosphere.z<=0.) return float3(0.);
    const auto body=f.bodies[uint(f.atmosphere.x)];
    float3 o=(f.eye.xyz-body.position.xyz)/body.position.w;
    float3 L=normalize(f.bodies[0].position.xyz-body.position.xyz);
    float H=f.atmosphere.y,outer=1.+H*5.6;
    float2 span=atmosphereSpan(o,d,outer);
    float start=max(0.,span.x),end=span.y;
    float2 ground=atmosphereSpan(o,d,1.);
    if(ground.x>0.)end=min(end,ground.x);
    if(depth>0.)end=min(end,depth/(max(.0001,dot(d,f.forward.xyz))*1000.*f.atmosphere.w));
    end=mix(end,min(end,cloudClip.x),smoothstep(.10,.85,cloudClip.y));
    if(end<=start || end-start<H*.00001)return float3(0.);
    float spanLength=end-start,optical=0.,aerosolDepth=0.;
    float3 direct=float3(0.),diffuse=float3(0.);
    float airglow=0.;
    float3 beta=float3(.0058,.0135,.029)*f.atmosphere.z;
    float3 hazeExtinction=float3(.0040,.0030,.0024)*f.atmosphere.z;
    float mu=dot(d,L),rayleigh=.05968*(1.+mu*mu),mie=.012*pow(max(.02,1.-.84*mu),-1.5);
    // Weight samples toward the ray's tangent altitude, where grazing light
    // crosses the densest part of the atmosphere.
    float pivot=clamp((-dot(o,d)-start)/spanLength,.0001,.9999);
    float ua=0.;
    for(int i=0;i<14;i++){
        float b=(float(i)+1.)/14.;
        float w=b<pivot?(pivot-b)/pivot:(b-pivot)/(1.-pivot);
        float ub=mix(b,pivot,.72*(1.-w));
        float kmStep=(ub-ua)*spanLength*f.atmosphere.w;
        float3 p=o+d*(start+(ua+ub)*.5*spanLength);
        ua=ub;
        float radius=max(1.,length(p)),height=(radius-1.)/H;
        float density=exp(-height),aerosol=exp(-height*2.4);
        float molecularStep=density*kmStep,aerosolStep=aerosol*kmStep;
        float3 viewTransmission=exp(-beta*(optical+.5*molecularStep)-hazeExtinction*(aerosolDepth+.5*aerosolStep));
        optical+=molecularStep;
        aerosolDepth+=aerosolStep;
        float zenith=dot(p,L)/radius;
        float localHorizon=-sqrt(max(0.,1.-1./(radius*radius)));
        float sunlight=smoothstep(-.006,.006,zenith-localHorizon);
        if(sunlight>.001){
            float sunMolecules=solarColumn(radius,zenith,H,density)*f.atmosphere.w;
            float sunAerosol=solarColumn(radius,zenith,H/2.4,aerosol)*f.atmosphere.w;
            float3 sunTransmission=exp(-beta*sunMolecules-hazeExtinction*sunAerosol);
            direct+=viewTransmission*sunTransmission*sunlight*
                    (beta*(molecularStep*rayleigh)+hazeExtinction*(aerosolStep*mie));
        }
        float twilight=smoothstep(-.20,.13,zenith);
        diffuse+=viewTransmission*beta*molecularStep*(.013+.058*twilight)*twilight;
        float upper=(height-3.85)*1.70;
        airglow+=viewTransmission.g*exp(-upper*upper)*kmStep*(.45+.55*twilight);
    }
    float3 scattering=direct*7.8+diffuse*3.4;
    // Soot-red aerial scattering; the real light direction still defines dusk.
    float horizon=exp(-abs(dot(d,normalize(o)))*7.);
    float dusk=1.-smoothstep(.03,.32,abs(dot(normalize(o),L)));
    scattering*=mix(float3(.70,.30,.11),float3(1.85,.62,.065),horizon*.45+dusk*.45);
    scattering=mix(scattering,scattering.g*mix(float3(.38,1.25,.70),float3(.90,1.48,.30),horizon),float(uint(f.optics.x)==1u));
    scattering=mix(scattering,scattering.g*float3(.62,.96,1.25),float(uint(f.optics.x)==2u));
    float3 acidAir=mix(float3(1.28,.37,.77),float3(1.35,1.29,.30),horizon*.62+dusk*.38);
    scattering=mix(scattering,scattering.g*acidAir,float(uint(f.optics.x)==3u));
    float3 upperTint=mix(float3(.65,.15,.052),float3(.21,.78,.28),float(uint(f.optics.x)==1u));
    upperTint=mix(upperTint,float3(.14,.54,.88),float(uint(f.optics.x)==2u));
    upperTint=mix(upperTint,float3(.74,.26,.47),float(uint(f.optics.x)==3u));
    scattering+=upperTint*(1.-exp(-airglow*f.atmosphere.z*.015))*.25;
    transmission=exp(-beta*optical-hazeExtinction*aerosolDepth);
    return scattering;
}

fragment half4 flightOpticalExterior(Full in [[stage_in]],constant FlightScene& f [[buffer(0)]],
                                    texture2d<half> scene [[texture(0)]],texture2d<half> rings [[texture(1)]],
                                    texture2d<float> ranges [[texture(2)]],texture2d<half> clouds [[texture(3)]]) {
    const float2 uv=in.uv,pixel=1./float2(scene.get_width(),scene.get_height());
    const float3 ray=exteriorRay(uv,f);
    const float depth=opaqueMetres(ranges,uv);
    const uint look=uint(f.optics.x);
    float3 c=resolveExterior(scene,uv,pixel);
    if (look==0u) c=refractExterior(c,uv,ray,scene,ranges,f,depth);
    c+=stellarProminences(ray,f,pixel.y,stellarDepth(f),depth);
    if (look==1u) c=fogExterior(c,uv,ray,depth,f);
    const float4 ring=float4(rings.sample(cockpitLinear,uv));
    c=c*(1.-ring.a)+ring.rgb;
    c+=stellarLens(uv,pixel.y,f)*.60;
    float2 cloudClip;
    const float4 cloud=resolveXalariaClouds(uv,ray,depth,f,ranges,clouds,cloudClip);
    c=c*cloud.a+cloud.rgb;
    float3 transmission;
    const float3 scatter=atmosphere(ray,depth,cloudClip,f,transmission);
    return half4(half3(c*transmission+scatter),0.);
}

fragment half4 flightLensSeed(Full in [[stage_in]],texture2d<half> optical [[texture(0)]],
                             texture2d<float> raw [[texture(1)]]) {
    const float2 pixel=1./float2(optical.get_width(),optical.get_height());
    float3 light=0.;
    float hottest=0.;
    for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
        const float3 c=float3(optical.sample(cockpitLinear,in.uv+float2(x,y)*pixel*1.15).rgb);
        const float peak=max(c.r,max(c.g,c.b)),soft=clamp(peak-.18,0.,.9);
        const float amount=max(peak-.67,soft*soft*.27)/max(peak,.0001);
        light+=c*amount/9.;
        hottest=max(hottest,peak*amount);
    }
    const float average=max(light.r,max(light.g,light.b));
    light*=1.+smoothstep(1.55,3.8,hottest/max(average,.00001))*3.2;
    float focus=skyDepthMetres;
    const float2 offsets[]={float2(0.,0.),float2(.035,0.),float2(-.035,0.),
                            float2(0.,.035),float2(0.,-.035)};
    for (uint i=0;i<5u;++i)
        focus=min(focus,cameraDepth(raw,float2(.5)+offsets[i]));
    return half4(half3(light),half(log2(focus)/64.));
}

fragment half4 flightBokeh(Full in [[stage_in]],constant FlightScene& f [[buffer(0)]],
                           texture2d<half> seed [[texture(0)]],texture2d<float> raw [[texture(1)]]) {
    const float2 uv=in.uv,pixel=1./float2(raw.get_width(),raw.get_height());
    const float focus=exp2(float(seed.sample(cockpitPoint,float2(.5)).a)*64.);
    const float coc=cameraDefocus(cameraDepth(raw,uv),focus);
    const float field=vintageField(uv,f.screen.x);
    const float radius=(1.+15.*coc+32.*field*field)*1.15;
    const float lod=clamp(log2(max(1.,radius/6.)),0.,2.2);
    const float2 radial=vintageRadial(uv,f.screen.x);
    float3 sum=float3(seed.sample(apertureLinear,uv,level(lod)).rgb);
    for (int tap=0;tap<48;++tap) {
        const float a=(float(tap)+.5)*2.3999632,r=sqrt((float(tap)+.5)/48.);
        const float2 q=uv+vintagePupil(radial,field,a,r)*radius*pixel;
        sum+=float3(seed.sample(apertureLinear,q,level(lod)).rgb);
    }
    float3 veil=0.;
    for (int tap=0;tap<12;++tap) {
        const float a=(float(tap)+.5)*2.3999632,r=sqrt((float(tap)+.5)/12.);
        const float2 q=uv+vintagePupil(radial,field*.45,a,r)*(radius*2.4+17.)*pixel;
        veil+=float3(seed.sample(apertureLinear,q,level(min(4.,lod+1.25))).rgb)/12.;
    }
    return half4(half3(sum*(1.20/49.)+veil*.27),1.);
}

float3 exteriorFlare(float2 uv,float pixelHeight,texture2d<float> raw,constant FlightScene& f) {
    const float visible=stellarVisibility(raw,f);
    if (visible<.001) return 0.;
    const float2 axis=.5-f.stellarImage.xy;
    float3 ghosts=0.;
    for (int i=0;i<5;++i) {
        const float g=float(i);
        const float2 centre=f.stellarImage.xy+axis*(1.20+g*.42);
        const float edge=length((uv-centre)*float2(f.screen.x,1.));
        const float radius=.018+g*.010+f.stellarImage.z*.32,aa=pixelHeight*2.+radius*.24;
        const float iris=(1.-smoothstep(radius-aa,radius+aa,edge))*.25+
                          exp(-abs(edge-radius)/max(aa*2.,.00001))*.10;
        ghosts+=mix(float3(1.,.24,.025),float3(1.,.78,.20),g*.18)*iris*(.035-g*.004);
    }
    return ghosts*visible*stellarFlux(f)*.56;
}
fragment half4 flightGlare(Full in [[stage_in]],texture2d<half> scene [[texture(0)]]) {
    const float2 pixel=1./float2(scene.get_width(),scene.get_height());
    float3 light=0.;
    for (int i=0;i<12;++i) {
        const float a=float(i)*2.3999632;
        const float r=sqrt((float(i)+.5)/12.)*16.;
        const float4 sample=float4(scene.sample(cockpitLinear,in.uv+float2(cos(a),sin(a))*r*pixel));
        light+=max(sample.rgb-sample.a,0.);
    }
    return half4(half3(light/12.),1.);
}


fragment half4 flightExteriorLens(Full in [[stage_in]],constant FlightScene& f [[buffer(0)]],
                                 constant float4& palette [[buffer(1)]],
                                 texture2d<half> scene [[texture(0)]],texture2d<half> glare [[texture(1)]],
                                 texture2d<float> raw [[texture(2)]],texture2d<half> seed [[texture(3)]],
                                 texture2d<half> clouds [[texture(4)]]) {
    const float2 point=in.uv-.5;
    const float2 uv=clamp(.5+point*(1.+dot(point,point)*.018),.001,.999);
    const float2 pixel=1./float2(scene.get_width(),scene.get_height());
    const float field=vintageField(uv,f.screen.x);
    float3 c=float3(scene.sample(cockpitLinear,uv).rgb);
    const float z=cameraDepth(raw,uv),focus=exp2(float(seed.sample(cockpitPoint,float2(.5)).a)*64.);
    const float coc=cameraDefocus(z,focus), radius=1.35*coc+6.8*field*field;
    if (radius>=.18) {
        const float2 radial=vintageRadial(uv,f.screen.x);
        float3 sum=c;
        float weight=1.;
        for (int tap=0;tap<12;++tap) {
            const float a=(float(tap)+.5)*2.3999632,r=sqrt((float(tap)+.5)/12.);
            const float2 q=uv+vintagePupil(radial,field,a,r)*pixel*radius;
            const float donor=cameraDepth(raw,q);
            const float accept=1.-smoothstep(.025,.15,abs(donor-z)/max(donor,z));
            sum+=float3(scene.sample(cockpitLinear,q).rgb)*accept;
            weight+=accept;
        }
        c=mix(c,sum/weight,clamp(coc*.30+field*.84,0.,.92));
    }
    const uint look=uint(f.optics.x);
    const float2 edge=(uv-.5)*2.;
    const float rim=saturate(dot(edge,edge)*.45);
    const float dispersionStrength=look==0u ? 1. : look==2u ? .25 : look==1u ? .20 : .12;
    const float2 shift=edge*pixel*rim*.65*dispersionStrength;
    const float3 dispersed=float3(scene.sample(cockpitLinear,uv+shift).r,c.g,scene.sample(cockpitLinear,uv-shift*.65).b);
    c=mix(c,dispersed,rim*.22);
    const float3 bokeh=float3(glare.sample(cockpitLinear,uv).rgb);
    c+=bokeh*(.025+.52*field);
    float3 display=xalariaTone(c*(1.-.10*dot(edge,edge)),0.,look);
    const float dither=fract(52.9829189*fract(dot(floor(uv/pixel),float2(.06711056,.00583715))))-.5;
    display=saturate(display+dither/255.);
    const float glow=max(bokeh.r,max(bokeh.g,bokeh.b)),h=smoothstep(.3,2.,glow);
    float3 halo=mix(float3(1.,.16,.012),float3(1.,.66,.11),h);
    if (look==1u) halo=mix(float3(.12,.54,.29),float3(.78,.96,.37),h);
    if (look==2u) halo=mix(float3(.11,.25,.45),float3(.52,.75,.92),h);
    if (look==3u) halo=mix(float3(.78,.13,.45),float3(1.,.96,.40),h)*.59;
    display+=halo*powr(saturate(glow*.30),.9)*.10+vintageGlare(bokeh)*.115;
    const float cloudTransmission=f.cloudShell.w>0. ? float(clouds.sample(cockpitLinear,uv).a) : 1.;
    display+=exteriorFlare(uv,pixel.y,raw,f)*cloudTransmission;
    return half4(half3(displayBubbleChroma(saturate(vintageGrade(display,field)),palette)),1.);
}

float metricDepth(depth2d<float> depth,float2 uv) {
    return cabinNear*cabinFar/max(1e-8,cabinFar-depth.sample(cockpitPoint,uv)*(cabinFar-cabinNear));
}
float3 cabinFromUV(float2 uv,float distance,float aspect) {
    return float3((uv*2.-1.)*float2(aspect,-1.)/xalariaFocal,1.)*distance;
}
float2 cabinUV(float3 p,float aspect) {
    return .5+.5*(p.xy/max(.001,p.z))*xalariaFocal/float2(aspect,-1.);
}
float4 photographicCabin(texture2d<half> cabin,float2 uv) {
    float4 layer=float4(cabin.sample(cockpitLinear,uv));
    const float peak=max(layer.r,max(layer.g,layer.b));
    layer.rgb/=1.+max(0.,peak-layer.a)*.92;
    return layer;
}

float cabinContactOcclusion(depth2d<float> depth,float2 uv,float2 pixel,float aspect,float3 colour) {
    const float z=metricDepth(depth,uv);
    if (z>cabinFar*.98) return 1.;
    const float3 p=cabinFromUV(uv,z,aspect);
    const float2 xs=float2(pixel.x,0.),ys=float2(0.,pixel.y);
    const float3 l=p-cabinFromUV(uv-xs,metricDepth(depth,uv-xs),aspect);
    const float3 r=cabinFromUV(uv+xs,metricDepth(depth,uv+xs),aspect)-p;
    const float3 b=p-cabinFromUV(uv-ys,metricDepth(depth,uv-ys),aspect);
    const float3 a=cabinFromUV(uv+ys,metricDepth(depth,uv+ys),aspect)-p;
    const float3 raw=cross(abs(l.z)<abs(r.z)?l:r,abs(b.z)<abs(a.z)?b:a);
    float3 n=surfaceUnit(raw,float3(0.,0.,-1.));
    if (dot(n,-p)<0.) n=-n;
    const float radius=min(.13,z*.22);
    const float2 spread=radius*xalariaFocal/(z*float2(aspect,1.))*.5;
    float sum=0., weight=0.;
    for (int i=0;i<20;++i) {
        const float k=float(i), angle=k*2.399963, reach=.30+float(i%4)*.19;
        const float2 q=uv+float2(cos(angle),sin(angle))*spread*reach;
        if (any(q<.001)||any(q>.999)) continue;
        const float d=metricDepth(depth,q);
        if (d>=cabinFar*.98) continue;
        const float3 delta=cabinFromUV(q,d,aspect)-p;
        const float range=length(delta);
        sum+=max(0.,dot(n,delta)/max(range,.0001)-.16)*(1.-smoothstep(radius*.28,radius,range));
        weight+=1.;
    }
    const float occlusion=clamp(sum/max(weight,1.)*2.7,0.,.56)*smoothstep(2.,5.,length(spread/pixel));
    const float lamps=1.-smoothstep(.64,1.35,max(colour.r,max(colour.g,colour.b)));
    return 1.-occlusion*.56*lamps;
}

float3 cabinReflection(float2 uv,float3 body,float coverage,float aspect,
                       texture2d<half> cabin,texture2d<half> finish,depth2d<float> depth,
                       texture2d<half> exterior) {
    if (coverage<.96) return body;
    const float4 material=float4(finish.sample(cockpitPoint,uv));
    const float reflectance=length(material.xyz), rough=material.w;
    if (reflectance<.06 || rough>.64) return body;
    const float z=metricDepth(depth,uv);
    if (z>=cabinFar*.98) return body;
    const float3 p=cabinFromUV(uv,z,aspect), v=normalize(-p);
    float3 n=normalize(material.xyz);
    if (dot(n,v)<0.) n=-n;
    const float3 ray=reflect(-v,n), start=p+n*.012;
    float3 reflected=body;
    float confidence=0., previous=.015;
    for (int i=0;i<24;++i) {
        const float k=float(i), t=.025+k*.025+k*k*.0048;
        const float3 q=start+ray*t;
        if (q.z<=.03) break;
        float2 donor=cabinUV(q,aspect);
        if (any(donor<.008)||any(donor>.992)) break;
        const float d=metricDepth(depth,donor), gap=q.z-d, thickness=.018+t*.028;
        if (i>1 && d<cabinFar*.98 && gap>0. && gap<thickness) {
            float lo=previous, hi=t;
            for (int refine=0;refine<5;++refine) {
                const float mid=(lo+hi)*.5;
                const float3 s=start+ray*mid;
                if (s.z>metricDepth(depth,cabinUV(s,aspect))) hi=mid; else lo=mid;
            }
            donor=cabinUV(start+ray*hi,aspect);
            const float edge=min(min(donor.x,donor.y),min(1.-donor.x,1.-donor.y));
            const float4 hit=photographicCabin(cabin,donor);
            const float separation=length((donor-uv)*float2(cabin.get_width(),cabin.get_height()));
            const float3 hitNormal=float3(finish.sample(cockpitPoint,donor).xyz);
            const float facing=smoothstep(.02,.30,dot(surfaceUnit(hitNormal,n),-ray));
            confidence=smoothstep(.008,.10,edge)*smoothstep(3.,15.,separation)*smoothstep(.85,.99,hit.a)*
                       facing*(1.-smoothstep(thickness*.30,thickness,gap));
            reflected=hit.rgb/max(.001,hit.a);
            break;
        }
        previous=t;
    }
    if (ray.z>.06) {
        const float2 skyUV=cabinUV(ray,aspect);
        const float edge=min(min(skyUV.x,skyUV.y),min(1.-skyUV.x,1.-skyUV.y));
        if (edge>0.) {
            const float opening=1.-smoothstep(.02,.18,photographicCabin(cabin,skyUV).a);
            reflected=mix(float3(exterior.sample(cockpitLinear,skyUV).rgb),reflected,confidence);
            confidence=mix(opening*smoothstep(0.,.12,edge)*.74,1.,confidence);
        }
    }
    const float fresnel=powr(1.-saturate(dot(n,v)),5.);
    const float amount=reflectance*(.72+fresnel*.54)*(1.-smoothstep(.22,.75,rough));
    return mix(body,reflected,clamp(amount*confidence,0.,.52));
}

fragment half4 flightCabinComposite(Full in [[stage_in]],constant FlightScene& f [[buffer(0)]],
                                      texture2d<half> exterior [[texture(0)]],texture2d<half> glow [[texture(1)]],
                                      texture2d<half> cabin [[texture(2)]],depth2d<float> depth [[texture(3)]],
                                      texture2d<half> finish [[texture(4)]]) {
    const float2 uv=in.uv,pixel=1./float2(cabin.get_width(),cabin.get_height());
    float4 body=photographicCabin(cabin,uv);
    const float4 a=photographicCabin(cabin,uv+pixel*float2(-.8,-.8));
    const float4 b=photographicCabin(cabin,uv+pixel*float2(.8,-.8));
    const float4 c=photographicCabin(cabin,uv+pixel*float2(-.8,.8));
    const float4 d=photographicCabin(cabin,uv+pixel*float2(.8,.8));
    const float edge=max(max(abs(a.a-body.a),abs(b.a-body.a)),max(abs(c.a-body.a),abs(d.a-body.a)));
    const float energy=length(abs(a.rgb+d.rgb-b.rgb-c.rgb))*.5;
    body=mix(body,(a+b+c+d)*.25,.48*max(edge,smoothstep(.09,.43,energy)));
    if (body.a>.04) body.rgb*=cabinContactOcclusion(depth,uv,pixel,f.screen.x,body.rgb);
    const float field=vintageField(uv,f.screen.x);
    const float2 radial=vintageRadial(uv,f.screen.x);
    float3 halo=float3(glow.sample(cockpitLinear,uv).rgb)*2.;
    float4 gathered=body*2.;
    for (int i=0;i<8;++i) {
        const float a=(float(i)+.5)*2.3999632,r=sqrt((float(i)+.5)/8.);
        const float2 pupil=vintagePupil(radial,field,a,r)*pixel;
        halo+=float3(glow.sample(cockpitLinear,uv+pupil*(9.+field*32.)).rgb);
        if (field>.025) gathered+=photographicCabin(cabin,uv+pupil*field*field*4.8);
    }
    if (field>.025) body=mix(body,gathered*.10,field*.82);
    float3 colour=cabinReflection(uv,body.rgb/max(body.a,.0001),body.a,f.screen.x,cabin,finish,depth,exterior);
    colour=vintageGrade(colour,field)*body.a;

    float3 beams=0.;
    const float3 light=cabinSunDirection(f);
    const float3 v=normalize(cabinFromUV(uv,1.,f.screen.x));
    const float3 ray=f.cabinRight.xyz*v.x+f.cabinUp.xyz*v.y+f.cabinForward.xyz*v.z;
    const float phase=.60*powr(saturate(dot(ray,light)),12.);
    if (phase>.004 && f.optics.z>.001) {
        const float3 eye=f.cabinOffset.xyz;
        const float3 inverse=sign(ray+1e-6)/max(abs(ray),1e-6);
        const float3 a=(float3(-1.025,-.82,-1.462)-eye)*inverse;
        const float3 b=(float3(1.025,.56,1.14)-eye)*inverse;
        const float3 lo=min(a,b),hi=max(a,b);
        const float start=max(0.,max(lo.x,max(lo.y,lo.z)));
        const float end=min(min(hi.x,min(hi.y,hi.z)),metricDepth(depth,uv)/max(v.z,.001));
        if (end>start) {
            const float stride=(end-start)/8.;
            float scatter=0.;
            for (int i=0;i<8;++i) {
                const float t=start+(float(i)+.5)*stride;
                scatter+=cabinWindowTransmission(eye+ray*t,light,f.optics.w)*exp(-t*.075)*stride;
            }
            beams=mix(cabinWindowLight(uint(f.optics.x)),cabinStellarColour(f),.64)*scatter*phase*.075*f.optics.z;
        }
    }
    const float3 outside=float3(exterior.sample(cockpitLinear,uv).rgb);
    return half4(half3(colour+outside*(1.-body.a)+vintageGlare(halo*.10)*.49+beams),1.);
}
