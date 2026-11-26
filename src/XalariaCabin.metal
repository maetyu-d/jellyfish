// Xalaria–Infinity v0.68.0 Hyperion cockpit materials and tone curve, adapted to Metal.
constant float xalariaFocal = 1.428148; // cotangent of half of the 70 degree vertical field of view.
constant float cabinNear = .025, cabinFar = 13.;

float3 surfaceUnit(float3 value,float3 fallback) {
    return dot(value,value)>1e-15 ? normalize(value) : fallback;
}
float3 cabinWindowLight(uint look) {
    if (look==1u) return float3(.62,1.,.43);
    if (look==2u) return float3(.35,.74,1.);
    if (look==3u) return float3(1.,.48,.72);
    return float3(1.,.47,.21);
}
float3 cabinStellarColour(constant FlightScene& f) {
    const float3 c = f.bodies[0].colour.xyz;
    return max(c,.015)/max(.015,max(c.r,max(c.g,c.b)));
}
float3 cabinSunDirection(constant FlightScene& f) {
    const float3 light=surfaceUnit(-f.ship.xyz,float3(0.,1.,0.));
    return normalize(float3(dot(light,f.shipRight.xyz),dot(light,f.shipUp.xyz),-dot(light,f.shipForward.xyz)));
}
float3 materialBump(float3 normal,float3 p,float height,float strength) {
    const float3 a=dfdx(p), b=dfdy(p);
    const float3 dx=cross(b,normal),dy=cross(normal,a);
    const float determinant=dot(a,dx);
    const float3 slope=(dx*dfdx(height)+dy*dfdy(height))*sign(determinant);
    return surfaceUnit(normal*abs(determinant)-slope*strength*28.,normal);
}
float3 referenceFirePalette(float t){
 float3 black=float3(0.);
 float3 soot=float3(.075,.014,.005);       // deep umber
 float3 charred=float3(.220,.012,.006);    // blackened red
 float3 crimson=float3(.460,.025,.009);    // deep crimson
 float3 flame=float3(.880,.140,.012);      // scarlet
 float3 orange=float3(1.,.430,.018);     // burning orange
 float3 gold=float3(1.,.940,.075);         // yellow heat
 float3 whiteHeat=float3(1.,.995,.720);    // white-yellow heat
 if(t<.12)return mix(black,soot,smoothstep(0.,.12,t));
 if(t<.30)return mix(soot,charred,smoothstep(.12,.30,t));
 if(t<.48)return mix(charred,crimson,smoothstep(.30,.48,t));
 if(t<.65)return mix(crimson,flame,smoothstep(.48,.65,t));
 if(t<.80)return mix(flame,orange,smoothstep(.65,.80,t));
 if(t<.92)return mix(orange,gold,smoothstep(.80,.92,t));
 return mix(gold,whiteHeat,smoothstep(.92,1.,t));
}
float3 charredSunset(float3 c){
 float y=dot(c,float3(.299,.587,.114)),peak=max(c.r,max(c.g,c.b));
 // Peak-aware brightness retains hot orange and gold in saturated emitters.
 float energy=pow(clamp(y*.58+peak*.42,0.,1.),1.08);
 // A steeper pivot separates deep wine/umber from incandescent yellow.
 float heat=clamp((energy-.45)*1.55+.45,0.,1.);
 float3 warm=referenceFirePalette(heat);
 return clamp(mix(warm,c*float3(1.,.60,.20),.04),float3(0.),float3(1.));
}
float3 verdantPalette(float t){
 float3 ink=float3(.006,.019,.013);
 float3 pine=float3(.023,.135,.076);
 float3 emerald=float3(.045,.335,.170);
 float3 fern=float3(.19,.56,.27);
 float3 lime=float3(.55,.78,.25);
 float3 paleSun=float3(.96,.98,.57);
 if(t<.22)return mix(ink,pine,smoothstep(0.,.22,t));
 if(t<.43)return mix(pine,emerald,smoothstep(.22,.43,t));
 if(t<.63)return mix(emerald,fern,smoothstep(.43,.63,t));
 if(t<.83)return mix(fern,lime,smoothstep(.63,.83,t));
 return mix(lime,paleSun,smoothstep(.83,1.,t));
}
float3 verdantGrade(float3 c,float peak){
 float energy=clamp(dot(c,float3(.24,.66,.10))*.72+max(c.r,max(c.g,c.b))*.28,0.,1.);
 float3 grade=verdantPalette(pow(energy,.88));
 // Lamps and hot minerals retain copper and amber against the green air.
 float copper=smoothstep(.14,.58,c.r-c.g)*smoothstep(.24,.72,energy);
 grade=mix(grade,float3(.82,.35,.08)*energy,copper*.66);
 return mix(grade,float3(.98,1.,.64),smoothstep(2.,8.,peak)*.80);
}
float3 tidalPalette(float t){
 float3 ink=float3(.005,.012,.027);
 float3 navy=float3(.017,.045,.095);
 float3 cobalt=float3(.051,.151,.27);
 float3 blue=float3(.12,.32,.45);
 float3 sea=float3(.34,.60,.71);
 float3 foam=float3(.87,.955,.98);
 if(t<.20)return mix(ink,navy,smoothstep(0.,.20,t));
 if(t<.40)return mix(navy,cobalt,smoothstep(.20,.40,t));
 if(t<.60)return mix(cobalt,blue,smoothstep(.40,.60,t));
 if(t<.81)return mix(blue,sea,smoothstep(.60,.81,t));
 return mix(sea,foam,smoothstep(.81,1.,t));
}
float3 tidalGrade(float3 c,float peak){
 float energy=clamp(dot(c,float3(.22,.62,.16))*.59+max(c.r,max(c.g,c.b))*.41,0.,1.);
 float3 grade=tidalPalette(pow(energy,.87));
 // Keep warm fixtures legible against the cool reflected light.
 float amber=smoothstep(.18,.68,c.r-c.b)*smoothstep(.37,.76,energy);
 grade=mix(grade,float3(.92,.69,.32)*energy,amber*.56);
 return mix(grade,float3(.89,.96,1.),smoothstep(2.,8.,peak)*.78);
}
float3 acidPalette(float t){
 float3 ink=float3(.010,.020,.029);
 float3 plum=float3(.19,.029,.115);
 float3 raspberry=float3(.70,.072,.36);
 float3 fuchsia=float3(.97,.23,.60);
 float3 rose=float3(1.,.61,.82);
 float3 bleach=float3(1.,.94,.96);
 if(t<.23)return mix(ink,plum,smoothstep(0.,.23,t));
 if(t<.43)return mix(plum,raspberry,smoothstep(.23,.43,t));
 if(t<.60)return mix(raspberry,fuchsia,smoothstep(.43,.60,t));
 if(t<.81)return mix(fuchsia,rose,smoothstep(.60,.81,t));
 return mix(rose,bleach,smoothstep(.81,1.,t));
}
float3 acidGrade(float3 c,float peak){
 float energy=clamp(dot(c,float3(.30,.58,.12))*.65+max(c.r,max(c.g,c.b))*.35,0.,1.);
 float t=pow(energy,.94);
 float3 grade=acidPalette(t);
 // Slate stays cool in shadow. The stain retains pink down into the pits.
 float stain=smoothstep(.025,.32,c.r-c.g);
 float shadow=(1.-smoothstep(.22,.58,t))*(1.-stain*.85);
 float3 slate=mix(float3(.009,.018,.026),float3(.24,.31,.34),smoothstep(.04,.53,t));
 grade=mix(grade,slate,shadow*.96);
 // Sulphur follows the mineral and light colour, independently of exposure.
 float sulphur=smoothstep(.045,.20,(c.g-c.b)/max(c.r,.08))*smoothstep(.22,.42,t);
 float3 yellow=mix(float3(.51,.47,.075),float3(1.,.971,.27),smoothstep(.32,.76,t));
 yellow=mix(yellow,float3(1.,.99,.68),smoothstep(.77,1.,t));
 grade=mix(grade,yellow,sulphur);
 return mix(grade,float3(1.,.99,.76),smoothstep(2.,8.,peak)*.84);
}
float3 chiaroscuro(float3 colour){
 float peak=max(colour.r,max(colour.g,colour.b));
 float value=mix(dot(colour,float3(.299,.587,.114)),peak,.34);
 // A deep but continuous toe keeps shadow detail without lifting blacks.
 // The shoulder keeps the colour of strong light and emissive fixtures.
 float toe=mix(.18,1.,smoothstep(.026,.53,value));
 float shoulder=1.+.10*smoothstep(.45,.91,value);
 return clamp(colour*toe*shoulder,float3(0.),float3(1.));
}
float3 xalariaTone(float3 c,float built, uint look){
 float brightness=dot(c,float3(.299,.587,.114));c=max(float3(0.),mix(float3(brightness),c,mix(1.28,1.06,built)));
 c=max(c*1.36,float3(0.));
 float peak=max(c.r,max(c.g,c.b)),mappedPeak=(peak*(2.51*peak+.03))/(peak*(2.43*peak+.59)+.14);
 float3 film=(c*(2.51*c+.03))/(c*(2.43*c+.59)+.14);
 c=clamp(mix(film,c/max(peak,.0001)*mappedPeak,.86),float3(0.),float3(1.));
 c=pow(c,float3(1./2.2));
 if(built>=.999)return chiaroscuro(c);
 // Retain the small incandescent range above the ordinary surface exposure.
 float3 grade=float3(0.);
 if(float(look==0u)>0.)
  grade+=mix(charredSunset(c),float3(1.,.995,.64),smoothstep(2.,8.,peak)*.90)*float(look==0u);
 if(float(look==1u)>0.)grade+=verdantGrade(c,peak)*float(look==1u);
 if(float(look==2u)>0.)grade+=tidalGrade(c,peak)*float(look==2u);
 if(float(look==3u)>0.)grade+=acidGrade(c,peak)*float(look==3u);
 return chiaroscuro(mix(grade,c,built));
}
float3 builtTangent(float3 N,float3 grain){
 float3 fallback=abs(N.y)<.8?cross(N,float3(0.,1.,0.)):cross(N,float3(0.,0.,1.));
 return surfaceUnit(grain-N*dot(N,grain),surfaceUnit(fallback,float3(1.,0.,0.)));
}
float3 builtBrdf(float3 body,float3 N,float3 V,float3 L,float rough,float metal,float3 tangent,float anisotropy){
 float nv=max(dot(N,V),.015),nl=max(dot(N,L),0.);
 float3 H=surfaceUnit(V+L,N),T=builtTangent(N,tangent),B=cross(N,T);
 float nh=max(dot(N,H),0.),vh=max(dot(V,H),0.);
 float alpha=max(.035,rough*rough);
 float aspect=sqrt(1.-clamp(anisotropy,0.,.8)*.85);
 float ax=alpha/aspect,ay=alpha*aspect;
 float3 h=float3(dot(T,H)/ax,dot(B,H)/ay,nh);
 float denominator=dot(h,h);
 float distribution=1./max(3.141593*ax*ay*denominator*denominator,.00001);
 float lv=length(float3(dot(T,V)*ax,dot(B,V)*ay,nv));
 float ll=length(float3(dot(T,L)*ax,dot(B,L)*ay,nl));
 float visibility=.5/max(nl*lv+nv*ll,.0001);
 float3 f0=mix(float3(.04),body,metal);
 float3 fresnel=f0+(1.-f0)*pow(1.-vh,5.);
 // A bounded multiple-scattering correction keeps brushed alloy bright
 // without whitening paint. The original high-contrast display curve stays.
 float3 compensation=float3(1.)+f0*(rough*.38);
 float3 specular=distribution*visibility*fresnel*compensation;
 float3 diffuse=(1.-fresnel)*(1.-metal)*body/3.141593;
 return (diffuse+specular)*nl*3.8;
}

float canopyTubeShadow(float3 p,float3 light,float3 a,float3 b,float radius,float angular){
 float3 axis=b-a,q=p-a;
 float along=dot(axis,light),length2=dot(axis,axis);
 float u=clamp((dot(q,axis)-dot(q,light)*along)/max(.00001,length2-along*along),0.,1.);
 float3 closest=a+axis*u;
 float travel=dot(closest-p,light);
 if(travel<.008)return 1.;
 float distance=length(p+light*travel-closest);
 float penumbra=max(.0025,fwidth(distance)*1.35)+travel*clamp(angular,.002,.055);
 return smoothstep(radius-penumbra,radius+penumbra,distance);
}

float canopyFrameSun(float3 p,float3 light,float angular){
 if(p.z>1.16 || abs(p.x)>1.10)return 1.;
 float visibility=1.;
 for(int side=0;side<2;++side){
  float x=side==0?-.812:.812;
  visibility=min(visibility,canopyTubeShadow(p,light,float3(x,-.25,-1.285),float3(x,.40,-1.285),.018,angular));
  visibility=min(visibility,canopyTubeShadow(p,light,float3(side==0?-.72:.72,.607,-1.285),float3(x,.40,-1.285),.016,angular));
  for(int clampIndex=0;clampIndex<3;++clampIndex){
   float y=-.22+float(clampIndex)*.30;
   visibility=min(visibility,canopyTubeShadow(p,light,float3(x,y-.013,-1.285),float3(x,y+.013,-1.285),.026,angular));
  }
 }
 visibility=min(visibility,canopyTubeShadow(p,light,float3(-.72,.607,-1.285),float3(.72,.607,-1.285),.018,angular));
 return visibility;
}float cabinBox(float2 p,float2 halfExtent,float soft){
 float2 edge=halfExtent-abs(p);
 return smoothstep(0.,soft,min(edge.x,edge.y));
}

float cabinFinishNoise(float3 p,float3 origin){
 float footprint=max(length(dfdx(p)),length(dfdy(p)));
 // Gloss relief is filtered before Nyquist, rather than after it shimmers.
 float resolved=1.-smoothstep(.20,.68,footprint);
 return mix(.5,strataNoiseSample(p,origin),resolved);
}

float cabinWeave(float3 p,float3 N,float frequency){
 float3 weight=abs(N);
 weight/=max(.001,weight.x+weight.y+weight.z);
 float3 f=p*frequency;
 float3 fibres=sin(f);
 float3 cells=float3(fibres.y*fibres.z,fibres.x*fibres.z,fibres.x*fibres.y);
 float3 footprint=fwidth(f);
 float3 visible=float3(1.)-smoothstep(float3(.56),float3(2.6),
                                   float3(max(footprint.y,footprint.z),max(footprint.x,footprint.z),
                                        max(footprint.x,footprint.y)));
 return .5+dot(cells*visible,weight)*.5;
}

float cabinTread(float3 p){
 float2 tile=floor(p.xz/.045);
 float2 cell=fract(p.xz/.045)-.5;
 cell.x*=mix(-1.,1.,fract((tile.x+tile.y)*.5)*2.);
 float2 axis=float2(.7071,.7071);
 float2 bar=float2(dot(cell,axis),dot(cell,float2(-axis.y,axis.x)));
 float footprint=max(length(dfdx(p.xz)),length(dfdy(p.xz)))/.045;
 return cabinBox(bar,float2(.34,.098),.066)*(1.-smoothstep(.16,.78,footprint));
}

float cabinContactShade(float3 p){
 float height=p.z>1.16?p.y+1.10:p.y+.82;
 float hull=p.z>3.72?1.64:p.z>1.83&&p.z<3.40&&abs(p.x)>.81?2.11:.79;
 float rim=exp(-abs(hull-abs(p.x))*14.);
 float lower=exp(-abs(height)*10.);
 float rib=0., ceilingRim=0.;
 if(p.z>3.72){
  float z=min(min(abs(p.z-3.95),abs(p.z-4.97)),min(abs(p.z-6.13),abs(p.z-7.26)));
  rib=exp(-z*23.)*smoothstep(1.0,1.58,abs(p.x));
  ceilingRim=rim*exp(-abs(p.y-1.19)*14.);
 }else if(p.z>1.17){
  float z=min(min(abs(p.z-2.03),abs(p.z-3.22)),abs(p.z-3.49));
  rib=exp(-z*22.)*exp(-abs(abs(p.x)-.79)*12.);
  ceilingRim=rim*exp(-abs(p.y-.97)*14.);
 }
 return 1.-rim*lower*.48-rib*.24-ceilingRim*.21;
}

float cabinWindowTransmission(float3 p,float3 light,float angular){
 // Trace to the approximate canopy envelope. Roof, sill and aft wall
 // stop direct stellar light. Soften the frame edges across the glass.
 float3 inv=sign(light+float3(.00001))/max(abs(light),float3(.00001));
 float3 limits=mix(float3(-1.025,-.82,-1.462),float3(1.025,.56,1.14),step(float3(0.),light));
 float3 t=max(float3(0.),(limits-p)*inv);
 float3 front=p+light*t.z,side=p+light*t.x;
 float aperture=0.;
 // The proxy envelope stands in for a deep, bevelled pressure frame.
 // Feather its edge over that depth, then widen by the stellar disc.
 // Fully covered shadows and the unobstructed key keep their contrast.
 float sourceRadius=clamp(angular,.002,.055);
 if(t.z<=min(t.x,t.y) && light.z<0.)
  aperture=cabinBox(front.xy-float2(0.,.09),float2(.86,.425),.12+t.z*sourceRadius);
 else if(t.x<min(t.y,t.z))
  aperture=cabinBox(side.zy-float2(-.13,.12),float2(1.17,.405),.12+t.x*sourceRadius);
 if(aperture<.001)return 0.;
 return aperture*canopyFrameSun(p,light,angular);
}

// Reflect the fixed roof light strips and the console glow into nearby
// materials. The intersections remain in hull coordinates during freelook.
float3 cabinFixtureReflection(float3 p,float3 ray,float roughness){
 float blur=.018+roughness*.21;
 float roofHeight=.584-p.y, consoleHeight=p.y+.415;
 float3 roof=p+ray*(max(0.,roofHeight)/max(.045,ray.y));
 float3 lower=p+ray*(max(0.,consoleHeight)/max(.06,-ray.y));
 float footprint=clamp(fwidth(roof.x)*.65,0.,.18);
 float strip=exp(-abs(abs(roof.x)-.59)/(blur+footprint))*(blur/(blur+footprint));
 strip*=cabinBox(float2(0.,roof.z+.14),float2(1.,.89),.18);
 float central=cabinBox(float2(roof.x,roof.z+.30),float2(.16,.19),.075+blur);
 float dashboard=cabinBox(lower.xz-float2(0.,-1.17),float2(.39,.13),.06+blur);
 float consoles=cabinBox(float2(abs(lower.x),lower.z)-float2(.85,-.51),float2(.16,.28),.075+blur);
 float roofVisible=smoothstep(.035,.12,ray.y)*smoothstep(0.,.035,roofHeight);
 float consoleVisible=smoothstep(.045,.14,-ray.y)*smoothstep(0.,.035,consoleHeight);
 float collar=0.;
 if(ray.z<-.045 && p.z> -1.33){
  float3 hit=p+ray*((-1.338-p.z)/ray.z);
  float width=.006+blur*.55;
  collar=exp(-pow((hit.y-.491)/width,2.))*(.006/width)*
         smoothstep(.28,.33,abs(hit.x))*(1.-smoothstep(.69,.73,abs(hit.x)));
 }
 return float3(1.,.78,.50)*(strip*.83+central*.27)*roofVisible/(1.+roughness*2.)
       +float3(.15,.72,.64)*(dashboard*.34+consoles*.25)*consoleVisible
       +float3(1.,.58,.25)*collar*2.4;
}

float3 deckFixtureReflection(float3 p,float3 ray,float roughness){
 float3 c=float3(0.);
 bool cargo=p.z>=3.72;
 float blur=.016+roughness*.18;
 if(ray.y>.025){
  float t=((cargo?1.106:.917)-p.y)/ray.y;
  if(t>0.){
   float3 hit=p+t*ray;
   float nearest=clamp(4.45+floor((hit.z-4.45)/1.04+.5)*1.04,4.45,6.53);
   float s=cargo?cabinBox(float2(abs(hit.x)-.76,hit.z-nearest),float2(.07+blur,.24+blur),blur):
                  cabinBox(float2(abs(hit.x)-.49,hit.z-2.50),float2(.041+blur,1.04),blur);
   c+=mix(float3(.90,.88,.73),float3(1.,.55,.22),cargo?1.:0.)*s*.88;
  }
 }
 if(ray.y<-.035 && p.y>-.98){
  float3 hit=p+ray*((-1.076-p.y)/ray.y);
  float rail=cabinBox(float2(abs(hit.x)-.53,hit.z-4.53),float2(.022+blur,2.81),blur);
  c+=float3(.10,.69,.82)*rail*.66;
 }
 return c;
}

float3 deckLamp(float3 p,float3 N,float3 V,float3 body,float roughness,float metal,
              float3 position,float3 colour,float intensity){
 float3 offset=position-p;
 float range2=dot(offset,offset);
 float3 L=surfaceUnit(offset,float3(0.,1.,0.));
 // Fixtures have finite lenses. Broaden their lobe by their apparent size
 // before evaluating it, so small lights cannot become flashing pinpoints.
 float effective=pow(min(1.,pow(max(.28,roughness),4.)+.0012/(.16+range2)),.25);
 return colour*builtBrdf(body,N,V,L,effective,metal,float3(1.,0.,.13),0.)*
        intensity/(.28+range2)*.90;
}

float3 cabinStripLight(float3 p,float3 N,float3 V,float3 body,float rough,float metal,
                    float3 grain,float machining,float side,float3 colour,float power){
 // Integrate the actual long roof strip for diffuse illumination. The
 // reflected aperture below is continuous, rather than eight point glints.
 float3 diffuse=float3(0.);
 for(int tap=0;tap<8;++tap){
  float z=mix(-.98,.72,(float(tap)+.5)/8.);
  float3 delta=float3(side,.578,z)-p;
  float range2=dot(delta,delta);
  float facing=max(dot(N,surfaceUnit(delta,float3(0.,1.,0.))),0.);
  diffuse+=body*(1.-metal)*facing/(.28+range2);
 }
 float3 R=reflect(-V,N);
 float height=.578-p.y;
 float distance=height/max(R.y,.025);
 float3 hit=p+R*distance;
 // Analytic aperture integration with roughness-dependent width gives a
 // long, unbroken fixture reflection even during roll and strong boost.
 float blur=max(.018,abs(distance)*rough*rough*.60);
 float across=blur*(1.+machining*.45),along=blur*(1.-machining*.26);
 float x=(atan((side+.036-hit.x)/across)-atan((side-.036-hit.x)/across))/3.141593;
 float z=(atan((.72-hit.z)/along)-atan((-.98-hit.z)/along))/3.141593;
 float aperture=max(0.,x*z)*smoothstep(.025,.13,R.y)*smoothstep(0.,.08,height);
 float nv=max(0.,dot(N,V));
 float3 f0=mix(float3(.04),body,metal);
 float3 fresnel=f0+(max(float3(1.-rough),f0)-f0)*pow(1.-nv,5.);
 return colour*power*(diffuse*(1.55/8.)+fresnel*aperture*2.7);
}

float cabinSeamGrid(float2 uv){
 float2 grid=uv/float2(.41,.56);
 float2 footprint=fwidth(grid);
 float2 cell=fract(grid);
 float2 edge=min(cell,1.-cell);
 float2 spread=max(float2(.010),footprint*.7);
 float2 lines=(1.-smoothstep(float2(.004),float2(.012)+spread,edge))*
            (1.-smoothstep(float2(.018),float2(.09),footprint));
 return max(lines.x,lines.y);
}

float cabinPanelSeam(float3 p,float3 N){
 float3 weight=abs(N);
 weight*=weight;
 weight*=weight;
 weight/=max(.001,weight.x+weight.y+weight.z);
 return dot(weight,float3(cabinSeamGrid(p.zy),cabinSeamGrid(p.xz),cabinSeamGrid(p.xy)));
}
float3 shadeCabin(float3 base,float alpha,float3 p,float3 local,float3 N,float3 V,float3 L,thread float4& reflection, constant FlightScene& flight){
 float encoded=floor(alpha*255.+.5);
 float finish=floor(encoded/16.),emission=(encoded-floor(encoded/16.)*16.)/15.;
 float polymer=1.-step(.25,abs(finish-1.));
 float brushed=1.-step(.25,abs(finish-2.));
 float bronze=1.-step(.25,abs(finish-3.));
 float display=1.-step(.25,abs(finish-4.));
 float textile=1.-step(.25,abs(finish-5.));
 float tread=1.-step(.25,abs(finish-6.));
 float ceramic=1.-step(.25,abs(finish-7.));
 float composite=1.-step(.25,abs(finish-12.));
 float deck=step(1.16,p.z);
 float3 body;
 float height,rough,metal;
 {
  float grain=cabinFinishNoise(local*170.,float3(0.));
  float wear=strataNoise(local*17.3+float3(5.,9.,1.),float3(0.));
  float brushedGrain=cabinFinishNoise(local*float3(12.,220.,12.),float3(0.));
  float coarse=smoothstep(.42,.69,wear+grain*.14)*mix(1.,.38,deck);
  body=base*mix(.81+wear*.29+(grain-.5)*.15,.95+wear*.11+(grain-.5)*.09,deck);
  body=mix(body,body*.64+float3(.069,.061,.049),coarse*.17*(1.-polymer)*(1.-display));
  body*=1.+(brushedGrain-.5)*.25*(brushed+bronze);
  float relief=mix(grain,brushedGrain,brushed+bronze)-.5;
  float weave=textile>.5?cabinWeave(local,N,238.):0.;
  float grip=tread>.5?cabinTread(local):0.;
  float painted=1.-step(.25,finish);
  float seam=painted*cabinPanelSeam(local,N);
  body*=1.+textile*(weave*.26-.10)+tread*(grip*.34-.08);
  body*=1.-seam*.19;
  relief+=weave*textile*.45+grip*tread*.8-seam*.29;
  height=relief*mix(mix(.00028,.00016,deck),.00006,display);
  rough=mix(.43,.79,polymer+textile+tread)-brushed*.16-bronze*.14-display*.31-ceramic*.20;
  rough+=(grain-.5)*.10+coarse*.07;
  metal=brushed*.84+bronze*.86;
  // Hand-polished crests and recessed oxidation belong to the finish,
  // rather than adding noisy geometry or inheriting the regional material.
  float handling=smoothstep(.34,.73,cabinFinishNoise(local*float3(9.,14.,11.)+float3(5.,2.,17.),float3(0.)));
  float patina=smoothstep(.51,.72,wear)*bronze;
  body=mix(body,body*float3(.46,.67,.59),patina*.58);
  rough+=patina*.17-handling*(brushed*.07+polymer*.08);
  body*=1.+handling*(brushed*.12+ceramic*.055);
  if(composite>.5){
   float tow=cabinWeave(local,N,148.);
   float fibre=cabinWeave(local,N,520.);
   body=base*(.62+tow*.27+fibre*.10);
   height=(tow-.5)*.00008;
   rough=.28+(.5-fibre)*.045+handling*.035;
   metal=.09;
  }
 }
 float3 panelNormal=N;
 N=materialBump(N,p,height,.025);
 rough=clamp(rough,.19,.94);
 float3 dx=dfdx(N-panelNormal),dy=dfdy(N-panelNormal);
 float variance=min(.16,max(dot(dx,dx),dot(dy,dy))*.4);
 rough=pow(min(1.,pow(rough,4.)+variance),.25);
 float3 tint=mix(cabinWindowLight(uint(flight.optics.x)),cabinStellarColour(flight),.45);
 float sunlight=deck<.5 && flight.optics.z>.001?
                cabinWindowTransmission(p,L,flight.optics.w)*flight.optics.z:0.;
 float seal=cabinContactShade(p);
 float3 grainDirection=builtTangent(panelNormal,float3(1.,.07,.13));
 float machining=brushed*.65+bronze*.44;
 float3 lit=builtBrdf(body,N,V,L,rough,metal,grainDirection,machining)*tint*sunlight*2.15;
 // Warm key and cool instrument bounce describe the bevels independently.
 // The light positions remain attached to the physical roof and console.
 if(deck<.5){
  lit+=cabinStripLight(p,N,V,body,rough,metal,grainDirection,machining,-.59,
                     float3(1.,.76,.49),.62);
  lit+=cabinStripLight(p,N,V,body,rough,metal,grainDirection,machining,.59,
                     float3(.48,.72,1.),.44);
  // Recessed collar lamps wash the inner bevels and dashboard. Broad
  // physical sources keep the result smooth while the ship accelerates.
  lit+=deckLamp(p,N,V,body,rough,metal,float3(-.51,.486,-1.325),
                float3(1.,.58,.25),.12);
  lit+=deckLamp(p,N,V,body,rough,metal,float3(.51,.486,-1.325),
                float3(1.,.70,.38),.10);
 }
 lit+=body*tint*(.007+.021*max(dot(N,L),0.))*(1.-deck*.87);
 // Light the interior from the roof strips with actual distance falloff.
 float3 fixture=float3(p.x<0.?-.59:.59,.578,clamp(p.z,-.98,.72));
 float3 toLamp=fixture-p;
 float range2=max(dot(toLamp,toLamp),.007);
 float3 downLight=normalize(toLamp+float3(1e-12));
 float fill=(.012+.20*pow(max(dot(N,downLight),0.),1.24))/(.56+range2*1.9);
 lit+=body*(float3(.006,.012,.019)+float3(1.,.84,.63)*fill)*(1.-deck*.86);
 if(deck>.5){
  lit+=deckLamp(p,N,V,body,rough,metal,float3(p.x<0.?-.49:.49,.91,clamp(p.z,1.35,7.1)),
                float3(.96,.82,.63),.38);
 }
 float3 screenPosition=float3(clamp(p.x,-.35,.35),-.420,-1.176);
 float3 screenRay=screenPosition-p;
 float screenRange=dot(screenRay,screenRay);
 float screenFacing=max(dot(N,normalize(screenRay+float3(1e-8))),0.);
 lit+=body*float3(.055,.43,.32)*exp(-screenRange*13.)*(.07+.32*screenFacing)*(1.-display);
 float facing=clamp(dot(N,V),0.,1.);
 float fresnel=pow(1.-facing,5.);
 float3 ray=reflect(-V,normalize(mix(panelNormal,N,.24)));
 float3 reflected=deck>.5?deckFixtureReflection(p,ray,rough):cabinFixtureReflection(p,ray,rough);
 float3 sheen=mix(float3(.028),body,metal)+float3(.026)*ceramic;
 lit+=reflected*sheen*(.40+fresnel*1.25)*(1.-rough*.79);
 // Brushed alloys stretch the fixture image along the machining direction.
 // It is a broad, filtered lobe, not a high-frequency sparkling normal.
 if(brushed+bronze>.5){
  float3 tangent=normalize(float3(1.,.07,.13)-panelNormal*dot(float3(1.,.07,.13),panelNormal)+float3(1e-6));
  float3 wide=normalize(ray+tangent*.19);
  float3 narrow=normalize(ray-tangent*.19);
  float3 stretch=deck>.5?(deckFixtureReflection(p,wide,rough)+deckFixtureReflection(p,narrow,rough))*.5:
               (cabinFixtureReflection(p,wide,rough)+cabinFixtureReflection(p,narrow,rough))*.5;
  lit+=stretch*mix(float3(.30),body,.62)*(.42+fresnel*.78)*(1.-rough);
 }
 // A thin clear finish on enamel and ceramic catches a second, restrained lobe.
 lit+=reflected*float3(.045,.052,.062)*(ceramic+polymer*.23+composite*.82)*(1.+fresnel*2.);
 lit*=seal;
 // Retain the actual bumped surface and finish for the cabin reflection
 // resolve. Unpainted alloy reflects more than opaque paint or fabric.
 float mirror=(.085+metal*.70+ceramic*.09+composite*.16)*(1.-display*.88);
 reflection=float4(N*mirror,rough);
 float3 colour=xalariaTone(lit+base*emission*1.24,1.,uint(flight.optics.x));
 // The cabin compositor extracts energy above one before rolling off the lamp cores.
 return colour+base*(emission*emission*1.14);
}
