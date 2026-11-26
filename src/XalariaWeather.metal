// Xalaria–Infinity Hyperion weather optics. The weather atlas remains in
// catalogue body coordinates through the volume, surface shadow and resolve.
constant sampler weatherFieldSampler(coord::normalized,s_address::repeat,t_address::clamp_to_edge,
                                     mag_filter::linear,min_filter::linear,mip_filter::linear);
constant sampler weatherPoint(coord::normalized,address::clamp_to_edge,filter::nearest);

float3 xalariaOpticalWeather(float3 n,float lod,constant FlightScene& f,
                            texture2d<half> current,texture2d<half> following) {
    float2 uv=float2(atan2(n.z,n.x)/tau+.5,acos(clamp(n.y,-1.,1.))/pi);
    uv.y=uv.y*(63./64.)+.5/64.;
    return mix(float3(current.sample(weatherFieldSampler,uv,level(lod)).rgb),
               float3(following.sample(weatherFieldSampler,uv,level(lod)).rgb),f.cloudOptics.x);
}

float xalariaWeatherSun(float3 n,float3 light,unsigned index,constant FlightScene& f,
                        texture2d<half> current,texture2d<half> following) {
    if (f.cloudShell.w<=0. || index!=uint(f.cloudProjection.x)) return 1.;
    const float sun=dot(n,light);
    if (sun<-.03) return 1.;
    const float height=(f.cloudShell.x+f.cloudShell.y)*.5-1.;
    const float3 cloud=xalariaOpticalWeather(normalize(n+light*height/max(.15,sun)),0.,f,current,following);
    return 1.-cloud.r*min(.65,f.cloudShell.z*.9)*smoothstep(-.03,.15,sun)*f.cloudShell.w;
}

struct PreviewWeatherSource {
    float sun(float3,float3,uint,constant FlightScene&) const { return 1.; }
};

struct NativeWeatherSource {
    texture2d<half> current, following;
    float sun(float3 n,float3 light,uint index,constant FlightScene& f) const {
        return xalariaWeatherSun(n,light,index,f,current,following);
    }
};

// Distant cloud deck from hyperion_orbital_clouds.sh. This layer blends out
// close to the surface so the separate banks provide the low-altitude view.
float xalariaOrbitalCloudDensity(float3 n,float phase,float seconds) {
    const float3 drift=float3(seconds*.000012,0.,-seconds*.000009);
    const float3 q=n*8.8+float3(phase*31.,11.,23.)+drift;
    const float weather=strataNoise(q,float3(0.));
    const float curl=strataNoise(q*2.37+float3(4.,weather*1.7,13.),float3(0.));
    const float cells=strataNoise(q*6.1+curl*.9,float3(0.));
    const float cirrus=strataNoise(q*float3(6.7,2.1,4.3)+float3(curl*2.,7.,weather),float3(0.));
    const float belt=sin(n.y*15.+weather*4.2+n.z*2.1)*.055;
    const float mass=weather*.54+curl*.30+cells*.16+belt;
    const float front=smoothstep(.46,.65,mass);
    const float erosion=smoothstep(.23,.68,cells*.64+cirrus*.36);
    const float wisps=smoothstep(.49,.63,weather*.58+cirrus*.42)*smoothstep(.54,.74,cirrus)*.16;
    return clamp(front*(.50+.50*erosion)+wisps,0.,1.);
}

float3 xalariaCloudBillow(float3 n,float height) {
    float3 dx=dfdx(n),dy=dfdy(n);
    const float3 m=max(abs(dx),abs(dy));
    const float span=max(m.x,max(m.y,m.z));
    if (span<1.e-20) return n;
    dx/=span;
    dy/=span;
    const float3 a=cross(dy,n), b=cross(n,dx);
    const float det=dot(dx,a);
    float3 gradient=sign(det)*((dfdx(height)/span)*a+(dfdy(height)/span)*b)/max(abs(det),1.e-10);
    gradient*=min(1.,.52/max(length(gradient),.001));
    return normalize(n-gradient);
}

float3 xalariaOrbitalCloudLightWithUp(float3 ground,float3 n,float3 up,float3 view,float3 light,float phase,
                                     float seconds,float pressure,float temperature,float eyeRadius) {
    const float altitude=smoothstep(1.015,1.075,eyeRadius);
    const float temperate=smoothstep(165.,240.,temperature)*(1.-smoothstep(375.,510.,temperature));
    const float air=smoothstep(.08,.65,pressure)*temperate*altitude;
    if (air<.001) return ground;
    const float density=xalariaOrbitalCloudDensity(n,phase,seconds);
    const float coverage=(1.-exp(-density*2.7))*air;
    const float sun=dot(n,light);
    const float3 tangent=light-n*sun;
    const float shadow=xalariaOrbitalCloudDensity(normalize(n+tangent*.022),phase,seconds)*air;
    const float radialSun=dot(up,light);
    const float day=smoothstep(-.13,.18,radialSun);
    ground*=exp(-shadow*day*1.05);
    const float3 billow=xalariaCloudBillow(n,density*.011);
    const float billowSun=max(0.,dot(billow,light));
    float optical=0.;
    for (int step=1;step<=3;++step) {
        const float reach=float(step);
        const float blocker=xalariaOrbitalCloudDensity(normalize(n+tangent*reach*.010),phase,seconds);
        optical+=max(0.,blocker-density*.51-reach*.075);
    }
    const float selfShadow=exp(-optical*3.5);
    const float upper=xalariaOrbitalCloudDensity(normalize(n-tangent*.006),phase,seconds);
    const float relief=clamp(.48+(density-upper)*6.2,.16,1.12);
    const float silver=pow(1.-clamp(dot(up,view),0.,1.),3.)*day;
    const float banks=pow(clamp(coverage,0.,1.),.52);
    const float powder=(1.-exp(-coverage*4.8))*(1.-banks*.58);
    const float3 ambient=float3(.028,.043,.070)*(.46+density*.54);
    const float3 direct=float3(.82,.88,.96)*(.21+billowSun*.75)*relief*selfShadow;
    float3 cloud=mix(float3(.003,.006,.012),ambient+direct,day);
    cloud+=float3(1.,.66,.34)*pow(1.-abs(radialSun),8.)*day*.12;
    cloud+=float3(.42,.61,.82)*silver*(.18+powder*.43);
    cloud+=float3(.24,.31,.40)*powder*day*.18;
    return mix(ground,cloud,coverage*.94);
}

float3 xalariaOrbitalCloudLight(float3 ground,float3 n,float3 view,float3 light,float phase,float seconds,
                               float pressure,float temperature,float eyeRadius) {
    return xalariaOrbitalCloudLightWithUp(ground,n,n,view,light,phase,seconds,pressure,temperature,eyeRadius);
}

float2 weatherSpan(float3 eye,float3 ray,float radius) {
    const float b=-dot(eye,ray), distance=length(cross(eye,ray));
    const float discriminant=(radius-distance)*(radius+distance);
    if (discriminant<0.) return float2(1.,-1.);
    const float h=sqrt(discriminant);
    return float2(b-h,b+h);
}

float3 cloudRay(float2 uv,constant FlightScene& f) {
    const float2 q=(uv*2.-1.)*float2(f.screen.x,-1.)/xalariaFocal;
    return normalize(f.forward.xyz+f.right.xyz*q.x+f.up.xyz*q.y);
}

// Two segments of the hollow shell, with the solid clipped by the real
// terrain depth. The inner empty span never contributes optical thickness.
float4 cloudSpan(float3 eye,float3 ray,float depth,constant FlightScene& f) {
    const float2 outer=weatherSpan(eye,ray,f.cloudShell.y);
    const float2 inner=weatherSpan(eye,ray,f.cloudShell.x);
    const float begin=max(0.,outer.x);
    float end=outer.y;
    const float2 ground=weatherSpan(eye,ray,1.);
    if (ground.y>ground.x && ground.x>0.) end=min(end,ground.x);
    if (depth>0.) end=min(end,depth/(max(.0001,dot(ray,f.forward.xyz))*f.cloudProjection.w*1000.));
    if (end<=begin) return float4(0.);
    if (inner.y>begin && inner.x<end)
        return float4(begin,clamp(inner.x,begin,end),clamp(inner.y,begin,end),end);
    return float4(begin,end,end,end);
}

float cloudMass(float cover,float billow,float erosion,float height,float top) {
    const float profile=smoothstep(0.,.15,height)*(1.-smoothstep(.50,1.,height/top));
    return max(0.,cover-(1.-billow)*.40-(1.-erosion)*.14)*2.05*profile;
}

float3 cloudPigment(float phase) {
    const float heat=.5+.5*sin(tau*phase);
    const float3 oxide=mix(float3(.045,.004,.0015),float3(.90,.12,.008),smoothstep(.08,.80,heat));
    return mix(oxide,float3(1.65,.72,.045),pow(heat,9.)*.72);
}

fragment half4 flightCloudVolume(Full in [[stage_in]],constant FlightScene& f [[buffer(0)]],
                                 texture2d<float> opaque [[texture(0)]],
                                 texture2d<half> current [[texture(1)]],
                                 texture2d<half> following [[texture(2)]]) {
    if (f.cloudShell.w<=0.) return half4(0.,0.,0.,1.);
    const FlightBody body=f.bodies[uint(f.cloudProjection.x)];
    const float3 o=(f.eye.xyz-body.position.xyz)/body.position.w;
    const float3 d=cloudRay(in.uv,f);
    const float4 span=cloudSpan(o,d,opaque.sample(weatherPoint,in.uv).r,f);
    const float first=span.y-span.x, total=first+span.w-span.z;
    if (total<=0.) return half4(0.,0.,0.,1.);
    const float radiusKm=f.cloudProjection.w, thickness=f.cloudMotion.w;
    const float count=clamp(ceil(total*radiusKm/max(.5,thickness*.08)),12.,20.);
    const float stepSize=total/count, kmStep=stepSize*radiusKm;
    const float jitter=fract(52.9829189*fract(dot(floor(in.uv/f.cloudProjection.yz),float2(.06711056,.00583715))));
    const float3 light=normalize(f.bodies[0].position.xyz-body.position.xyz);
    const float scatteringAngle=dot(d,light);
    float transmission=1.;
    float3 sum=0.;
    const float forward=pow(max(0.,scatteringAngle),14.);
    const float phase=.12+.24*pow(max(0.,scatteringAngle),2.)+1.05*forward;
    const float middle=total*.5, middleT=middle<first ? span.x+middle : span.z+middle-first;
    const float3 middleN=normalize(o+d*middleT);
    const float palette=f.cloudOptics.y+dot(middleN,float3(.53,.71,.46))*.96+scatteringAngle*.15;
    const float3 opalLow=cloudPigment(palette), opalMid=cloudPigment(palette+.18), opalHigh=cloudPigment(palette+.36);
    float3 weather=0.;
    float lightNear=.5, lightFar=.5;
    bool shadowReady=false;
    const float pixelAngle=(2./xalariaFocal)*f.cloudProjection.z;
    for (int i=0;i<20;++i) {
        if (float(i)>=count || transmission<.012) break;
        const float along=(float(i)+.45+jitter*.10)*stepSize;
        const float t=along<first ? span.x+along : span.z+along-first;
        const float3 p=o+d*t, n=normalize(p);
        const float h=(length(p)-f.cloudShell.x)/(f.cloudShell.y-f.cloudShell.x);
        const float footprint=max(kmStep,t*radiusKm*pixelAngle);
        const float resolved=1.-smoothstep(12.,65.,footprint);
        if (i%4==0) {
            const float lod=clamp(log2(max(1.,t*pixelAngle*64./pi)),0.,7.);
            weather=xalariaOpticalWeather(n,lod,f,current,following);
            shadowReady=false;
        }
        const float cover=max(0.,weather.r-.035)*(.42+f.cloudOptics.z*.58);
        if (cover<.025) continue;
        float3 q=n*(radiusKm*.018)+f.cloudMotion.xyz+n*(h*thickness*.12)+f.cloudOptics.y*float3(31.,17.,47.);
        const float macro=resolved>.005 ? strataNoiseSample(q*.38+float3(19.,7.,4.),float3(0.)) : .5;
        q+=float3(.49,-.37,.28)*(macro-.5);
        const float billow=resolved>.005 ? mix(.5,strataNoiseSample(q,float3(0.)),resolved) : .5;
        const float detail=resolved>.05 ?
            mix(.5,strataNoiseSample(q*mix(2.67,7.8,1.-smoothstep(2.,15.,footprint))+19.,float3(0.)),resolved) : .5;
        const float topHeight=min(.99,.55+cover*.16+weather.g*.16+macro*.15+billow*.11);
        float density=cloudMass(cover,billow,detail,h,topHeight);
        const float cirrus=smoothstep(.77,.90,h)*(1.-smoothstep(.94,1.,h))*smoothstep(.45,.70,weather.r)*detail*.07;
        density=(density+cirrus)*clamp(f.cloudShell.z*.8,0.,1.);
        if (density<.002) continue;
        const float sun=dot(n,light), day=smoothstep(-.12,.14,sun);
        if (day>.002 && resolved>.005 && (!shadowReady || i%2==0)) {
            lightNear=mix(.5,strataNoiseSample(q+light*.51,float3(0.)),resolved);
            lightFar=resolved>.28 ? mix(.5,strataNoiseSample(q+light*1.31,float3(0.)),resolved) : lightNear;
            shadowReady=true;
        }
        const float nearMass=cloudMass(cover,lightNear,.56,h+sun*.17,topHeight);
        const float farMass=cloudMass(cover,lightFar,.54,h+sun*.42,topHeight);
        const float column=(density*.16+nearMass*.45+farMass*.39)*max(.24,topHeight-h+.16);
        const float selfShadow=exp(-column*3.7/max(.16,.23+sun));
        const float gradient=clamp(.61+(billow-lightNear)*2.8,.14,1.15);
        const float powder=1.-exp(-density*kmStep*.32), silver=pow(1.-clamp(density,0.,1.),2.)*forward;
        const float3 ambient=mix(float3(.006,.009,.025),float3(.105,.160,.252),day)*(.43+.57*h)*(.47+billow*.63);
        const float3 sunlight=mix(float3(1.12,.34,.17),float3(1.02,.96,.86),smoothstep(.02,.45,sun));
        float3 colour=ambient+sunlight*day*(selfShadow*(.25+phase*2.)*gradient+powder*.14);
        const float rim=pow(max(0.,1.-density),2.)*(1.-exp(-density*20.));
        colour+=sunlight*day*(silver*.54+rim*.25)*(.19+.81*selfShadow);
        colour*=1.-weather.g*.32;
        const float shade=clamp(h*.17+billow*.13,0.,.36);
        const float3 opal=shade<.18 ? mix(opalLow,opalMid,shade/.18) : mix(opalMid,opalHigh,(shade-.18)/.18);
        colour+=(float3(.30,.48,.85)+opalHigh*.35)*f.cloudOptics.w*pow(weather.g,4.)*2.2;
        colour*=mix(float3(1.),.22+opal*1.45,.40);
        colour+=opal*(.018+day*(silver*.09+pow(max(0.,1.-abs(sun)*3.),3.)*.09));
        const float opacity=1.-exp(-density*kmStep*.24);
        sum+=transmission*colour*opacity;
        transmission*=1.-opacity;
    }
    const float weight=f.cloudShell.w;
    return half4(half3(sum*weight),half(1.-(1.-transmission)*weight));
}

float4 resolveXalariaClouds(float2 uv,float3 ray,float depth,constant FlightScene& f,
                            texture2d<float> opaque,texture2d<half> clouds,thread float2& clip) {
    clip=0.;
    if (f.cloudShell.w<=0.) return float4(0.,0.,0.,1.);
    const FlightBody body=f.bodies[uint(f.cloudProjection.x)];
    const float3 eye=(f.eye.xyz-body.position.xyz)/body.position.w;
    const float4 span=cloudSpan(eye,ray,depth,f);
    if ((span.y-span.x)+(span.w-span.z)<=0.) return float4(0.,0.,0.,1.);
    const float2 texel=f.cloudProjection.yz, pixel=uv/texel-.5, base=floor(pixel), sub=fract(pixel);
    float total=0.;
    float4 colour=0.;
    for (int y=0;y<2;++y) for (int x=0;x<2;++x) {
        const float2 tap=(base+float2(x,y)+.5)*texel;
        const float other=opaque.sample(weatherPoint,tap).r;
        const float compatible=(depth==0. && other==0.) ? 1. :
            smoothstep(.93,.99,min(depth,other)/max(max(depth,other),1.e-20));
        const float weight=(x==0 ? 1.-sub.x : sub.x)*(y==0 ? 1.-sub.y : sub.y)*compatible;
        colour+=float4(clouds.sample(weatherPoint,tap))*weight;
        total+=weight;
    }
    const float4 result=total>.0001 ? colour/total : float4(0.,0.,0.,1.);
    clip=float2(span.x+(span.y-span.x)*.35,1.-result.a);
    return result;
}
