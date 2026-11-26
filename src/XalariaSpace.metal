// Infinity / Xalaria v0.68.0 Hyperion space optics, ported from GLSL to Metal.
// The original texture lookup is evaluated from its integer table recipe.
// Integer evaluation of the original MaterialTexture.cpp 256x256 two-channel lookup.
float xalariaNoiseLookup(int2 p) {
    uint h = uint(p.x&255)*1973u+uint(p.y&255)*9277u+89173u;
    h = (h^(h>>16u))*2246822519u;
    h = (h^(h>>13u))*3266489917u;
    return float((h^(h>>16u))>>24u)/255.;
}
float2 xalariaNoisePixel(int2 p) {
    return float2(xalariaNoiseLookup(p),xalariaNoiseLookup(p+int2(37,17)));
}
float strataNoiseSample(float3 p,float3 origin) {
    const float3 cell=floor(p)+origin;
    const int2 uv=int2(cell.xy+float2(37.,17.)*cell.z);
    float3 f=fract(p); f=f*f*(3.-2.*f);
    const float2 a=mix(xalariaNoisePixel(uv),xalariaNoisePixel(uv+int2(1,0)),f.x);
    const float2 b=mix(xalariaNoisePixel(uv+int2(0,1)),xalariaNoisePixel(uv+int2(1,1)),f.x);
    const float2 sample=mix(a,b,f.y);
    return mix(sample.r,sample.g,f.z);
}
float strataNoise(float3 p, float3 origin) {
    const float resolve = 1.-smoothstep(.6,2.,max(length(dfdx(p)),length(dfdy(p))));
    return mix(.5,strataNoiseSample(p,origin),resolve);
}

// hyperion_space_glass.sh
// The two warped sheet families share the same field in the background,
// reflected surfaces and refraction pass. Only the celestial ray sets their phase.
float2 spaceGlassFold(float3 d,float phase,float seconds){
 float3 p=d*2.88;
 float drift=seconds*.006;
 float ridge=p.y+.55*sin(p.x*1.38+phase*6.283)+.29*cos(p.z*1.45+drift);
 ridge+=.13*sin(p.x*2.4-p.z*1.75+phase*2.5);
 ridge+=.054*sin(p.x*5.3+p.y*2.1+sin(p.z*3.9)*.8+phase*7.);
 float side=p.z*.69-p.x*.58+.36*cos(p.y*1.91+phase*3.+drift);
 side+=.11*sin(p.y*3.1+p.x*1.64);
 return float2(ridge,side);
}
float spaceGlassThickness(float2 fold){
 float a=fold.x*2.25+.13*sin(fold.y*3.7);
 float b=fold.y*2.60+.16*cos(fold.x*2.3)+1.3;
 return .47*cos(a)+.27*sin(b)+.077*sin(a*3.1-b*1.9);
}
float3 spaceGlassGlow(float3 d,float phase,float seconds){
 float2 fold=spaceGlassFold(d,phase,seconds);
 float a=fold.x*2.25+.13*sin(fold.y*3.7);
 float b=fold.y*2.60+.16*cos(fold.x*2.3)+1.3;
 float cut=sin(a),crossing=sin(b);
 float aa=max(fwidth(cut)*1.15,.004);
 float lip=1.-smoothstep(.012,.036+aa,abs(cut));
 float fine=exp(-abs(sin(a-.13-.055*sin(b*4.)))*24.);
 float glass=exp(-abs(sin(a+.23))*5.8);
 float farSheet=exp(-abs(crossing)*12.);
 float3 N=normalize(float3(.47*cos(d.x*4.+phase),.78+.20*sin(d.z*3.),.38*cos(d.y*3.-phase)));
 float fresnel=pow(1.-clamp(abs(dot(d,N)),0.,1.),3.);
 float glint=.22+.78*pow(.5+.5*sin(b*.85+phase),3.);
 float flow=.58+.22*sin(d.x*19.+sin(d.z*9.)*2.+phase)+.15*sin(d.z*33.-d.y*17.);
 float bevel=exp(-abs(sin(a+.36+.051*sin(b*2.4)))*12.);
 float satin=pow(.5+.5*cos(b*2.1+a*.72),3.)*glass;
 float overlap=smoothstep(.22,.91,glass*farSheet);
 float ripple=a*4.4+sin(b*5.1)*.83;
 float rippleAA=1.-smoothstep(.55,1.8,fwidth(ripple));
 float striae=pow(.5+.5*sin(ripple),9.)*rippleAA*glass;
 float body=glass*(.16+fresnel*.72)*flow;
 // Dark internal laminations separate transmitted glass from incandescent
 // edges; the folded sheets read as depth instead of solid neon tubing.
 float lamination=.5+.5*sin(a*2.14+cos(b*1.17)*.76);
 float internal=pow(lamination,5.)*glass;
 float3 c=float3(.075,.016,.007)*body;
 c+=float3(.49,.094,.013)*glass*glass*glint*(.17+fresnel*.41);
 c+=float3(.24,.038,.008)*satin*(.23+.77*fresnel);
 c+=float3(.48,.155,.031)*bevel*(.22+.54*glint)*(.34+.66*fresnel);
 c+=float3(.29,.104,.025)*striae*(.28+.72*glint);
 c+=float3(.86,.28,.047)*overlap*(.18+.48*fresnel);
 float hair=a*9.2+sin(b*3.4)*1.53+sin(d.z*17.)*.3;
 float hairline=pow(.5+.5*cos(hair),17.)*(1.-smoothstep(.33,1.6,fwidth(hair)));
 c+=float3(.40,.112,.021)*hairline*glass*glint*(.24+.51*fresnel);
 c+=float3(.24,.057,.013)*internal*(.18+.82*fresnel);
 c+=float3(1.25,.54,.12)*fine*(.10+.50*glint)*(.38+fresnel);
 c+=float3(2.4,1.40,.34)*lip*(.10+.67*fresnel)*glint;
 float reflectedLip=exp(-abs(sin(a+.065))*38.);
 reflectedLip*=1.-smoothstep(.12,.8,fwidth(a)*38.);
 c+=float3(.67,.38,.13)*reflectedLip*glint*(.18+.82*fresnel);
 c+=float3(.69,.14,.035)*farSheet*(.19+.42*fresnel)*(.44+.56*flow);
 return c;
}

// hyperion_tidal.sh
// Long swells carry smaller ripples in the same direction. Filter each
// wavelength in screen space so distant crests do not turn into a grid.
float3 tidalSwells(float2 p,float seconds,float footprint){
 float2 q=p+float2(.32*sin(p.y*.39+seconds*.34),.58*sin(p.x*.76-seconds*.26));
 float2 a=float2(.62,1.65),b=float2(-1.24,2.71),c=float2(2.36,5.67),d=float2(-3.58,9.21);
 float4 phase=float4(dot(q,a),dot(q,b),dot(q,c),dot(q,d))-seconds*float4(.81,1.13,1.63,2.04);
 float4 frequency=float4(length(a),length(b),length(c),length(d));
 float4 weight=float4(.19,.075,.023,.009)*(1.-smoothstep(float4(.45),float4(1.65),frequency*footprint));
 float4 slope=cos(phase)*weight;
 return float3(dot(sin(phase),weight),a*slope.x+b*slope.y+c*slope.z+d*slope.w);
}

// A curved current is evaluated in the celestial field, with its own axis
// and tangent. The gaps and swells share that frame as the ship rolls.
float4 tidalCurrent(float3 ray,float3 axis,float3 course,float2 shape,float phase,float seconds){
 float3 side=cross(axis,course);
 float along=dot(ray,course),crossing=dot(ray,side);
 float centre=dot(ray,axis)-shape.x
              +.17*sin(along*3.6+crossing*2.0+phase)
              +.067*sin(crossing*5.8-along*2.7+phase*.71);
 float width=shape.y*(.87+.20*cos(along*7.6+phase)+.13*sin(crossing*5.1-phase));
 float edge=centre/width;
 float water=1.-smoothstep(.74,1.10,abs(edge));
 float2 p=float2(along*8.4+crossing*4.1,centre*16.+1.5*sin(crossing*3.7+phase));
 p+=float2(phase*.48,phase*.29);
 float footprint=max(length(dfdx(p)),length(dfdy(p)));
 float3 swell=tidalSwells(p,seconds,footprint);
 float3 across=axis-ray*dot(ray,axis);
 across*=rsqrt(max(dot(across,across),.001));
 float3 tangent=cross(ray,across);
 float3 normal=normalize(-ray*.72+across*(clamp(edge,-1.3,1.3)*.63-swell.z)-tangent*swell.y);
 float3 reflected=reflect(ray,normal);
 float3 light=normalize(float3(-.31,.29,-.92));
 float facing=clamp(dot(normal,-ray),0.,1.);
 float fresnel=.024+.72*pow(1.-facing,4.);
 float reflection=max(dot(reflected,light),0.);
 // Break reflections into moving glints and let smaller flecks collect on
 // the high side of each swell.
 float2 windDrift=float2(.12,.63)*seconds;
 float wind=strataNoise(float3(p*float2(2.45,5.6)-windDrift,4.4+phase),float3(0.));
 float2 drift=p+float2(wind*.36,swell.x*.82);
 float eddies=strataNoise(float3(drift*float2(1.2,3.1)-windDrift*.42,11.6+phase),float3(0.));
 drift+=float2(.34,-.16)*(eddies-.5);
 float spray=strataNoise(float3(drift*float2(8.1,16.6)-windDrift*2.4,16.8+phase),float3(0.));
 float surf=strataNoise(float3(drift*float2(3.4,7.6)-windDrift*1.45,21.+phase),float3(0.));
 float chop=smoothstep(.31,.68,wind);
 float swellLight=clamp(.40+swell.x*1.44+dot(normal,light)*.39+(wind-.5)*.20,0.,1.);
 float3 ocean=mix(float3(.0011,.004,.014),float3(.014,.082,.169),swellLight);
 ocean*=mix(.25,1.12,smoothstep(-.21,.14,swell.x));
 float thinRim=exp(-abs(abs(edge)-.79)*11.);
 ocean+=float3(.010,.071,.108)*thinRim*(.18+.82*eddies)*(.36+.64*fresnel);
 ocean+=float3(.055,.107,.175)*fresnel*(.41+.59*pow(reflection,4.));
 ocean+=float3(.27,.49,.69)*pow(reflection,35.)*(.18+.82*chop);
 float fringe=exp(-abs(swell.x-.117+(surf-.5)*.11)*21.);
 float shimmer=pow(clamp(reflection,0.,1.),4.)*.56+.44*chop;
 ocean+=float3(.048,.112,.20)*fringe*shimmer*smoothstep(.26,.66,surf);
 float crest=smoothstep(.115,.202,swell.x+(wind-.5)*.068);
 float lace=1.-abs(spray*2.-1.);
 float torn=1.-smoothstep(.055,.19,abs(surf-.52+(spray-.5)*.25));
 float foam=crest*smoothstep(.42,.72,wind*.58+lace*.42)*(1.-smoothstep(.060,.24,footprint));
 float foamSpill=crest*smoothstep(.49,.81,spray)*smoothstep(.38,.66,surf)*.40;
 float lightBand=pow(max(0.,1.-abs(surf*2.-1.)),9.)*smoothstep(.14,.28,swell.x)*
                 (1.-smoothstep(.027,.14,footprint));
 ocean+=float3(.09,.37,.55)*lightBand;
 ocean=mix(ocean,float3(.54,.83,1.0),min(.91,foam*(.29+.56*lace+.30*torn)+foamSpill));
 return float4(ocean,water);
}

float3 tidalSky(float3 ray,float3 space,float phase,float seconds){
 float dust=dot(space,float3(.27,.58,.15));
 float3 sky=float3(.0015,.0036,.008)+float3(.34,.53,.79)*dust*.19;
 float3 farAxis=normalize(float3(.58,.72,-.38)),farCourse=normalize(cross(farAxis,float3(.31,-.64,.79)));
 float3 midAxis=normalize(float3(-.68,.39,.63)),midCourse=normalize(cross(midAxis,float3(.72,.56,.19)));
 float3 nearAxis=normalize(float3(.23,-.46,.86)),nearCourse=normalize(cross(nearAxis,float3(.89,.41,.18)));
 float4 distant=tidalCurrent(ray,farAxis,farCourse,float2(.16,.24),phase*6.+2.4,seconds*.77);
 float4 middle=tidalCurrent(ray,midAxis,midCourse,float2(-.07,.31),phase*6.+4.7,seconds*.87);
 float4 nearby=tidalCurrent(ray,nearAxis,nearCourse,float2(.18,.28),phase*6.+.8,seconds);
 sky=mix(sky,distant.rgb*.48,distant.a);
 sky=mix(sky,middle.rgb*.74,middle.a);
 return mix(sky,nearby.rgb,nearby.a);
}

// hyperion_acid.sh
// Broad oxidation, chipped mineral crust and fine pits share the material's
// local coordinates. The filtered noise resolves each layer as it gets close.
float3 acidEtching(float3 p){
 float grain=strataNoise(p*11.6+float3(6.,13.,-4.),float3(0.));
 float chips=strataNoise(p*3.1+float3(-5.,8.,17.),float3(0.));
 float broad=strataNoise(p,float3(0.));
 float reaction=broad*.60+chips*.29+grain*.11;
 float crust=smoothstep(.48,.70,reaction);
 float oxide=smoothstep(.26,.55,reaction);
 float pits=smoothstep(.46,.81,grain)*(.25+.75*chips);
 return float3(crust,oxide,pits);
}

float3 acidMineral(float3 etch){
 float3 slate=float3(.032,.047,.058);
 float3 oxide=float3(.26,.038,.145);
 float3 chalk=float3(.79,.76,.15);
 float chipped=etch.x*smoothstep(.11,.67,etch.x);
 return mix(mix(slate,oxide,etch.y*etch.y),chalk,chipped)*(1.-etch.z*.61);
}

float4 acidSurfaceCoating(float3 direction, float phase, bool streamed) {
    const float3 etch=acidEtching(direction*(streamed ? 1100. : 29.)+float3(phase*19.,4.,8.));
    return float4(acidMineral(etch),etch.z);
}

float3 acidSurfaceLight(float3 radiance, float4 coating, float day) {
    return radiance*(1.-coating.w*.24)+coating.rgb*(.018+.069*day);
}

float3 acidSky(float3 ray,float phase){
 float3 p=ray*float3(4.1,5.7,4.1)+float3(9.,18.,7.+phase*12.);
 float warp=strataNoiseSample(p*.67,float3(0.));
 float3 grainFrame=p+float3(1.24,-1.35,.88)*(warp-.5);
 float3 etch=acidEtching(grainFrame);
 float flakes=strataNoise(grainFrame*7.8+float3(6.,-5.,3.),float3(0.));
 float exposure=.49+dot(ray,float3(.49,.25,-.15))*.68;
 float stain=smoothstep(.19,.67,exposure+(etch.y-.5)*.58);
 float bleach=smoothstep(.49,.86,exposure+(etch.x-.35)*.70);
 bleach*=smoothstep(.24,.72,warp*.46+flakes*.29+etch.x*.25)*.82;
 float lee=clamp(.23+.77*etch.y-.33*etch.z,0.,1.);
 float3 sky=mix(float3(.006,.005,.016),float3(.69,.026,.39),stain*lee);
 sky=mix(sky,float3(1.46,1.34,.16),bleach*(.44+flakes*.56));
 float edge=bleach*(1.-bleach)*4.*smoothstep(.39,.64,flakes);
 sky+=float3(.38,.036,.21)*edge*stain;
 float grains=strataNoise(grainFrame*23.4+float3(2.,3.,9.),float3(0.));
 float corrosion=pow(max(0.,1.-abs(flakes-.55)*2.4),8.)*etch.y*edge;
 return sky*(.70+grains*.37-etch.z*.27)+float3(.66,.24,.31)*corrosion*.22;
}

// hyperion_deep_stars.sh
float3 deepStarHash(float2 cell,float seed){
 float3 p=fract(float3(cell.x,cell.y,cell.x)*float3(.1031,.1030,.0973)+seed);
 p+=dot(p,p.yxz+33.33);
 return fract((p.xxy+p.yzz)*p.zyx);
}
float3 deepStarPlane(float3 ray,float phase,float cells,float seed){
 float2 plane=ray.xy/max(abs(ray.z),.15);
 float field=1.-smoothstep(.76,1.12,max(abs(plane.x),abs(plane.y)));
 if(field<.001)return float3(0.);
 float2 p=plane*cells,base=floor(p);
 float footprint=max(length(dfdx(p)),length(dfdy(p)));
 float variance=max(.008,footprint*footprint*.38);
 float3 sum=float3(0.);
 float face=seed+step(0.,ray.z)*19.+phase*113.;
 for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){
  float2 cell=base+float2(float(x),float(y));
  float3 key=deepStarHash(cell,face);
  if(key.z<.88)continue;
  float2 centre=cell+.12+key.xy*.76;
  float2 offset=p-centre;
  float pointSpread=exp(-dot(offset,offset)/max(.0001,2.*variance));
  // Integrated subpixel flux, with a fixed stellar magnitude. Camera
  // rotation changes pixel coverage without randomly blinking the stars.
  float energy=(.00002+pow(key.z,42.)*.016)/variance;
  float3 colour=mix(float3(1.,.62,.32),float3(.56,.76,1.),key.x);
  colour=mix(colour,float3(1.,.98,.91),key.y*.72);
  sum+=colour*pointSpread*energy;
 }
 return sum*field;
}
float3 deepStars(float3 direction,float phase){
 // Overlapping celestial projections have no cube-face seam and no
 // preferred up. Their fade depends on a fixed sky direction, never time.
 float3 c=float3(0.);
 c+=deepStarPlane(direction,phase,39.,.17);
 c+=deepStarPlane(direction.yzx,phase,39.,3.81);
 c+=deepStarPlane(direction.zxy,phase,39.,7.23);
 c+=deepStarPlane(direction,phase,109.,11.43)*.18;
 c+=deepStarPlane(direction.yzx,phase,109.,13.17)*.18;
 c+=deepStarPlane(direction.zxy,phase,109.,17.63)*.18;
 return c;
}

// hyperion_vintage_lens.sh
// A wide-open vintage photographic look, rather than a glass prescription.
// The image circle lives in sensor coordinates and has no animation or history.
float vintageField(float2 uv,float aspect){
 float2 sensor=(uv-.5)*float2(aspect,1.);
 float radius=length(sensor)/length(float2(aspect,1.)*.5);
 return smoothstep(.23,.96,radius);
}
float2 vintageRadial(float2 uv,float aspect){
 float2 sensor=(uv-.5)*float2(aspect,1.);
 return length(sensor)>.00001?normalize(sensor):float2(1.,0.);
}
float2 vintagePupil(float2 radial,float field,float angle,float radius){
 float2 tangent=float2(-radial.y,radial.x);
 // Pupil clipping and sagittal/tangential separation turn off-axis points
 // into soft cat's eyes whose long axes follow the image circle.
 float clipped=1.-field*.62;
 float2 pupil=radial*cos(angle)*clipped+tangent*sin(angle)*(1.+field*.42);
 pupil+=radial*field*.11*radius;
 return pupil*radius;
}
float3 vintageGlare(float3 light){
 float peak=max(light.r,max(light.g,light.b));
 float3 glow=light/(.72+peak);
 float luminance=dot(glow,float3(.299,.587,.114));
 // Mostly source-coloured scatter, with a faint warm veil from the optics.
 return mix(glow,float3(luminance),.13)*float3(1.055,1.008,.955);
}
float3 vintageGrade(float3 colour,float field){
 float3 c=max(colour,float3(0.));
 // Preserve the scene's contrast and colour separation: no lifted black
 // level, flattened gain, desaturation or additional highlight compression.
 // The vintage character comes from the aperture, glow and field softness.
 c*=float3(1.012,1.003,.988);
 return c*(1.-field*field*.105);
}

// Dust-lane integration from fs_hyperion_sky.sc
float3 nebula(float3 d, float phase, float density) {
 float3 seed=float3(9.1+phase*15.,31.7-phase*11.,7.8+phase*23.);
 float3 axis=normalize(float3(.32,.81,-.29));
 float warp=strataNoiseSample(d*3.1+seed,float3(0.));
 float curl=strataNoiseSample(d*4.7+seed.yzx,float3(0.));
 float laneAxis=dot(d,axis)+.46*(warp-.5)+.18*sin(d.z*4.8+d.x*3.6+phase*6.283);
 float lane=exp(-laneAxis*laneAxis*8.6);
 float counter=dot(d,normalize(float3(-.73,.37,.57)))+.27*(curl-.5);
 float veils=exp(-counter*counter*8.);
 float3 bend=float3(warp-.5,curl-.5,warp-curl)*.95;
 float3 result=float3(0.);
 float transmission=1.;
 for(int sampleIndex=0;sampleIndex<6;++sampleIndex){
  float i=float(sampleIndex);
  float3 p=d*(2.0+i*.81)+seed+bend*(1.0+i*.13);
  float broad=strataNoiseSample(p,float3(0.));
  float filaments=strataNoiseSample(p*2.72+float3(13.6,3.7,4.6),float3(0.));
  float knots=strataNoiseSample(p*5.9+float3(3.,6.3,17.),float3(0.));
  float body=smoothstep(.35,.70,broad*.56+filaments*.30+knots*.14);
  float rim=4.*body*(1.-body)*smoothstep(.31,.71,filaments);
  float nearSide=strataNoiseSample(p+float3(-.27,.22,.13),float3(0.));
  float light=clamp(.09+.79*rim+max(0.,broad-nearSide)*2.1,0.,1.);
  float filament=pow(max(0.,1.-abs(filaments*.73+knots*.27-.49)*3.7),5.);
  float erosion=smoothstep(.25,.69,knots);
  float fissure=smoothstep(.28,.65,filaments*.62+knots*.38);
  float column=body*(.06+.83*lane+.20*veils)*density*(.52+.53*fissure+.21*erosion);
  float opacity=1.-exp(-column*(.58+.49*(1.-light)));
  float3 soot=float3(.014,.0029,.0022),ember=float3(.46,.055,.009),ion=float3(1.05,.33,.034);
  float3 glow=mix(mix(soot,ember,light*light),ion,pow(light,5.)*.73);
  glow+=float3(.91,.25,.065)*filament*rim*(.15+.85*lane)*(.37+.63*erosion);
  glow*=.72+.28*smoothstep(.24,.73,nearSide);
  result+=transmission*opacity*glow;
  transmission*=1.-opacity;
 }
 return result+transmission*float3(.0019,.00085,.0010);
}

// hyperion_region_fog.sh, evaluated along the same world-fixed rays as the star field.
float3 xalariaFog(float3 direction,float seconds,float sunGlow,thread float& transmission) {
 float drift=sin(seconds*.055)*.17;
 float beltAxis=(direction.y+.29*sin(direction.z*4.1+direction.x*1.6))*2.25;
 float belt=exp(-beltAxis*beltAxis);
 // Integrate successive cloud layers front to back. Each has independent
 // folds and colour, with brighter edges where light enters the mist.
 float3 scattered=float3(0.);
 transmission=1.;
 for(int layer=0;layer<5;layer++){
  float i=float(layer);
  float3 q=direction*(3.2+i*1.65)+float3(9.+i*1.57,16.-i*.81,2.+drift*(1.+i*.23));
  float broad=strataNoiseSample(q,float3(0.));
  float wisps=strataNoiseSample(q*2.17+float3(3.,-1.,.2),float3(0.));
  float folds=strataNoiseSample(q*4.07+float3(-4.,8.,.7),float3(0.));
  float fibres=strataNoise(q*float3(7.9,2.7,5.1)+float3(wisps*1.3,4.,folds*.8),float3(0.));
  float volume=smoothstep(.30,.73,broad*.45+wisps*.33+folds*.17+fibres*.05);
  float side=strataNoiseSample(q+float3(.39,.24,-.16),float3(0.));
  float litDepth=strataNoiseSample(q+float3(.79,.48,-.32),float3(0.));
  float edge=max(0.,broad-side*.61-litDepth*.39);
  float rim=4.*volume*(1.-volume)*smoothstep(.37,.65,wisps);
  float filaments=pow(max(0.,1.-abs(folds*.66+fibres*.34-.51)*4.4),5.);
  float glow=clamp(rim*(.36+.47*belt)+edge*2.9+sunGlow*.80+filaments*.12,0.,1.);
  float shadow=exp(-max(0.,side*.55+litDepth*.45-.31)*(1.8+volume*2.8));
  float3 lit=mix(float3(.025,.22,.12),float3(.54,.92,.19),i*.16+.23*belt);
  float3 scatterLight=mix(float3(.002,.009,.007),lit,pow(glow,1.55)*shadow);
  scatterLight+=float3(.27,.67,.20)*filaments*rim*shadow*(.055+.08*belt);
  scatterLight+=float3(.58,.53,.082)*sunGlow*(.58+rim*.42);
  float opacity=1.-exp(-(.012+volume*volume*(.63+.64*belt))*(.77+fibres*.35));
  scattered+=transmission*opacity*scatterLight;
  transmission*=1.-opacity;
 }
 return scattered;
}

float3 xalariaSpace(float3 d,uint look,float phase,float seconds) {
 const float density=.55; // Native catalogue galaxy has zero gas fraction.
 float3 c=float3(0.);
 if(look==0u) c=nebula(d,phase,density)+spaceGlassGlow(d,phase,seconds)*1.75;
 const float dust=strataNoiseSample(d*6.4+phase*13.,float3(0.));
 if(look==1u) c=float3(.0034,.010,.0055)+float3(.010,.030,.014)*dust*density;
 if(look==2u) c=tidalSky(d,float3(.07,.10,.16)*dust*density,phase,seconds);
 if(look==3u) c=acidSky(d,phase);
 return c+deepStars(d,phase);
}

// hyperion_planets.sh and hyperion_ring_density.sh, using the shared bubble-local orbital data.
float3 giantClouds(float3 n,float3 axis,float3 lowColour,float3 highColour,float3 localLight,
                   float phase,float seconds,float bands,float contrast,float haze,float subtype){
 float latitude=dot(n,axis);
 float3 east=normalize(cross(axis,abs(axis.y)<.9?float3(0.,1.,0.):float3(1.,0.,0.))),north=cross(axis,east);
 float longitude=atan2(dot(n,north),dot(n,east)+1e-8);
 float jet=latitude*bands*3.14159265;
 float drift=sin(jet*.57)*seconds*.00025;
 float3 clouds=float3(dot(n,east),dot(n,north),latitude);
 float billow=strataNoise(clouds*float3(6.,6.,14.)+float3(phase*30.,2.,drift),float3(0.));
 float ripple=strataNoise(clouds*float3(16.,16.,91.)+float3(drift,phase*13.,billow*1.7),float3(5.,0.,0.));
 float curls=strataNoise(clouds*float3(43.,43.,190.)+float3(phase*21.,drift*2.,ripple*.9),float3(0.));
 float belt=jet+(billow-.5)*mix(2.8,1.35,haze)+mix(.24,.55,phase)*sin(longitude*5.+latitude*12.-drift);
 float storm=0.,spiral=0.,eye=0.,eyewall=0.,feeders=0.,ovals=0.;
 const int stormCount = haze>.69 ? 1 : subtype>8.5 ? 2 : 3;
 for(int i=0;i<stormCount;i++){
  float index=float(i);
  float lat=(i==1?-1.:1.)*(.18+phase*.22+index*.14);
  float heading=phase*6.283+index*2.39+seconds*.00011;
  float3 centre=axis*sin(lat)+(east*cos(heading)+north*sin(heading))*cos(lat);
  float3 tangent=normalize(cross(axis,centre)),meridian=cross(centre,tangent);
  const float width=mix(.20,.41,fract(phase*2.31+index*.39));
  const float height=width*mix(.37,.61,phase);
  float2 q=float2(dot(n-centre,tangent)/(width-index*.031),dot(n-centre,meridian)/(height-index*.020));
  float distance2=dot(q,q),facing=smoothstep(.72,.96,dot(n,centre));
  float core=exp(-distance2*1.20)*facing;
  float spin=atan2(q.y,q.x+1e-8)*2.-log(distance2+.024)*5.1+billow*2.8;
  float arms=.5+.5*sin(spin);
  float spinResolved=1.-smoothstep(.48,1.6,fwidth(spin));
  arms=mix(.5,arms,spinResolved);
  belt+=core*(arms-.30)*5.6;
  storm=max(storm,core);
  spiral=max(spiral,core*pow(arms,3.));
  eye=max(eye,exp(-distance2*34.)*facing);
  eyewall=max(eyewall,exp(-abs(sqrt(distance2)-.34)*16.)*facing*
              (.38+.62*arms));
  feeders=max(feeders,exp(-distance2*.45)*pow(arms,7.)*facing*(.35+.65*curls));
  // A wake of smaller vortices follows each major storm in its sheared
  // latitude band. Projected on the globe, rather than pasted on screen.
  for(int wake=1;wake<=3;++wake){
   float k=float(wake);
   float2 satellite=(q-float2(.83+k*.61,.22*sin(k*2.4+phase*5.)))/float2(.25+.023*k,.21);
   float d2=dot(satellite,satellite);
   float ring=exp(-abs(sqrt(d2)-.62)*9.);
   float inside=exp(-d2*4.);
   ovals+=facing*(ring*.30-inside*.22);
  }
 }
 float belts=mix(.5,.5+.5*sin(belt),1.-smoothstep(.6,2.,fwidth(belt)));
 float shear=.5+.5*sin(belt*2.13+ripple*2.3);
 shear=mix(.5,shear,1.-smoothstep(.45,1.4,fwidth(belt)*2.13));
 // Broad haze suppresses the coloured underlying jets. Cold, clear
 // envelopes keep their methane-blue depth and sharper equatorial belts.
 const float clear=1.-smoothstep(.50,.71,haze);
 const float amber=1.-smoothstep(6.7,7.5,subtype);
 const float violet=smoothstep(.61,.78,haze)*(1.-amber);
 const float3 absorption=mix(float3(.85,1.,1.),float3(.32,.53,1.38),clear*(1.-amber));
 const float3 hazeTint=mix(float3(1.),float3(1.16,.91,1.14),violet);
 const float3 low=lowColour*mix(.60,.30,clear)*absorption;
 const float3 high=highColour*mix(1.28,.80,clear)*absorption*hazeTint;
 const float jetMask=mix(belts,smoothstep(.24,.76,belts),clear*.64);
 float3 albedo=mix(low,high,mix(.5,jetMask,clamp(contrast*2.1+clear*.36,.16,.96)));
 albedo*=.49+.31*billow+.31*ripple+.24*shear+.13*curls;
 albedo=mix(albedo,low*.70+high*(.35+spiral*.83),storm*mix(.82,.40,haze));
 albedo=mix(albedo,low*.55,eye*.78);
 albedo+=high*(eyewall*.31+feeders*.22+max(0.,ovals));
 albedo*=1.+min(0.,ovals);
 float3 lightFrame=float3(dot(localLight,east),dot(localLight,north),dot(localLight,axis));
 float sunward=strataNoise(clouds*float3(6.,6.,14.)+float3(phase*30.,2.,drift)+lightFrame*.46,float3(0.));
 float reliefShade=clamp(.79+(billow-sunward)*2.7,.32,1.16);
 albedo*=mix(1.,reliefShade,smoothstep(-.12,.25,dot(n,localLight))*.74);
 // A high, optically thick envelope hides turbulence below it.
 return mix(albedo,mix(low,high,.64+.21*powr(abs(latitude),2.5)),smoothstep(.46,.82,haze)*.87);
}
// Optical depth of the catalogue debris field. Derivative
// filtering resolves bands without allocating a per-planet ring texture.
float xalariaRingDensity(float4 ring,float radius,float footprint){
 float width=ring.y-ring.x;
 if(ring.z<=0.||width<=0.)return 0.;
 // Integrate pixel coverage of the annulus. A thin ring still contributes
 // where its band falls between sample centres or is foreshortened.
 float halfPixel=max(.00001,footprint*.5);
 float lo=max(ring.x,radius-halfPixel),hi=min(ring.y,radius+halfPixel);
 if(hi<=lo)return 0.;
 float coverage=(hi-lo)/(2.*halfPixel);
 float centre=.5*(lo+hi);
 float coreWidth=min(width,6.);
 float radial=centre-ring.x;
 float u=radial/coreWidth,du=footprint/coreWidth;
 float taper=smoothstep(0.,.035,u)*(1.-smoothstep(.965,1.,radial/width));
 float edge=coverage*mix(taper,1.,smoothstep(.035,.16,du));
 float gap=(1.-smoothstep(.014,.022,abs(u-(.54+ring.w*.12))))*(1.-smoothstep(.018,.058,du));
 float narrow=(1.-smoothstep(.004,.010,abs(u-(.27+ring.w*.07))))*(1.-smoothstep(.007,.024,du));
 float division=(1.-smoothstep(.002,.008,abs(u-(.81+ring.w*.07))))*(1.-smoothstep(.006,.021,du));
 float broad=.48+.27*sin(u*81.+ring.w*6.283)*(1.-smoothstep(.014,.049,du));
 float filaments=.16*sin(u*275.+ring.w*13.)*(1.-smoothstep(.003,.014,du))
                 +.08*sin(u*637.+ring.w*21.)*(1.-smoothstep(.0015,.006,du));
 float belt=exp(-abs(u-.37)*8.);
 float braids=.065*cos(u*1124.+ring.w*17.+sin(u*96.)*.7)*(1.-smoothstep(.0008,.0033,du));
 filaments+=braids;
 float zones=.65+.55*smoothstep(.17,.52,u)-.37*smoothstep(.63,.89,u)+belt*.21;
 // Broad belts carry a diffuse dust tail. A narrow detached ring still
 // retains its own radial profile, even well outside the parent globe.
 float radialFalloff=exp(-max(0.,.36*(radial-3.5)));
 float extended=mix(1.,.025+.975*radialFalloff,smoothstep(5.,11.,width));
 return ring.z*edge*(1.-gap*.98)*(1.-narrow*.86)*(1.-division*.69)*zones*max(.035,broad+filaments)*extended;
}

// hyperion_star_types.sh, with the main-sequence profile as the default.
// Coordinates are stellar-local unit normals. Derivative-filtered convection
// keeps the same features under zoom, rotation and a change of render units.
float3 typedPhotosphere(float3 n,float3 colour,float mu,float seconds,float spinRate,float4 stellar){
 float kind=stellar.x,phase=stellar.w;
 float spin=kind>7.5&&kind<8.5?0.:fract(seconds*spinRate)*6.283;
 float cs=cos(spin),sn=sin(spin);n.xz=float2(cs*n.x+sn*n.z,-sn*n.x+cs*n.z);
 float3 p=n*stellar.y+phase*float3(17.,31.,11.);
 float cell=strataNoise(p,float3(0.)),fine=strataNoise(p*2.03+9.,float3(0.));
 float rising=smoothstep(.24,.78,cell*.77+fine*.23);
 float fineGrain=strataNoise(p*4.11+float3(18.,4.,7.),float3(0.));
 float lanes=(1.-smoothstep(.04,.145,abs(cell-.44)))*smoothstep(.32,.74,fine);
 float activeRegion=strataNoise(n*4.8+phase*31.,float3(0.));
 float activeBelt=.52+.48*(1.-smoothstep(.10,.48,abs(abs(n.y)-.26)));
 float magnetic=smoothstep(.44,.76,activeRegion*.79+fine*.14+fineGrain*.07)*activeBelt;
 float spotStrength=.38+.62*stellar.z;
 float umbra=smoothstep(.47,.78,magnetic)*spotStrength;
 float penumbra=smoothstep(.25,.56,magnetic)*spotStrength;
 float faculae=4.*penumbra*(1.-penumbra)*smoothstep(.37,.82,fineGrain);
 float convection=clamp(rising-lanes*.32+fineGrain*.16,0.,1.);
 float meso=strataNoise(n*float3(13.,17.,13.)+phase*27.,float3(0.));
 float cells=smoothstep(.31,.70,cell);
 float cellEdge=exp(-abs(cell-.43)*28.)*(.40+.60*fine);
 float network=pow(max(0.,1.-abs(cell-.58)*4.6),7.)*
               smoothstep(.33,.78,fineGrain)*(.31+.69*activeRegion);
 float value=(.13+convection*1.20)*(1.-penumbra*.47-umbra*.51)+faculae*.51+network*.31;
 if(kind<6.5 || kind>9.5){
  value*=.69+meso*.47+cells*.19;
  value+=cellEdge*.19*(1.-umbra*.8);
  colour=mix(colour*float3(1.,.62,.36),mix(colour,float3(1.),.14),cells);
 }
 // Cool intergranular lanes and bright cell walls preserve large convective
 // relief through the optical shoulder. Fine fibrils are footprint-filtered.
 if(kind<6.5 || kind>9.5){
  float cellWall=exp(-abs(cell-.51-fine*.09)*21.);
  float granularEdge=(1.-smoothstep(.022,.12,abs(cell-.38)))*smoothstep(.28,.75,fine);
  float fibrilPhase=fine*67.+fineGrain*11.;
  float fibrils=pow(.5+.5*sin(fibrilPhase),5.)*(1.-smoothstep(.55,1.9,fwidth(fibrilPhase)));
  value*=1.-granularEdge*.45;
  value+=cellWall*(.05+fibrils*.19)*(.23+.77*faculae);
 }
 if(kind>9.5){
  float veil=strataNoise(n*float3(7.,13.,7.)+phase*29.,float3(0.));
  float carbonBand=smoothstep(.42,.69,veil)*(.4+.6*(1.-mu));
  colour=mix(colour,colour*float3(.66,.25,.15),carbonBand*.54);
 }
 if(kind>6.5&&kind<7.5)value=.96+convection*.06; // compact cooling white dwarf
 if(kind>7.5&&kind<8.5){ // exposure-averaged magnetic caps; never strobe
  float cap=pow(abs(dot(n,normalize(float3(.35,.86,.37)))),18.);
  value=.64+cap*.7;
 }
 if(kind>8.5&&kind<9.5){
  float belt=sin(n.y*24.+(cell-.5)*3.+phase*6.283);
  value=.42+convection*.45+belt*.17;
  colour=mix(colour,colour*float3(.62,.28,.13),smoothstep(.1,.8,belt)*.6);
 }
 if(kind<6.5 || kind>9.5){
  // Nonlinear granulation must fade before a convection cell shrinks to
  // a pixel. Broad magnetic regions survive this spatial filtering.
  float footprint=max(length(dfdx(p)),length(dfdy(p)));
  float resolved=1.-smoothstep(.18,.65,footprint);
  value=mix(.62*(1.-umbra*.58),value,resolved);
  if((kind>2.5 && kind<4.5) || kind>9.5)value=.15+value*.54;
 }
 float limb=.42+.58*pow(clamp(mu,0.,1.),.65);
 return colour*max(.06,value)*limb;
}

float geologyProfile(float3 p){
 float province=strataNoise(p*.19+float3(8.,3.,17.),float3(0.));
 float uplift=smoothstep(.39,.69,province);
 float ridge=1.-abs(strataNoise(p,float3(0.))*2.-1.);
 float cut=strataNoise(p*2.71+float3(7.,13.,3.),float3(0.));
 // Broad sedimentary plains separate the folded mountain provinces.
 // The same height field is sampled by the view and sunward relief rays.
 return clamp(.20+province*.23+uplift*(ridge*ridge*.38+cut*.12),0.,1.);
}
float4 orbitalGeology(float3 n,float3 view,float3 light,float phase){
 float3 q=n*31.+float3(phase*31.,8.,phase*19.);
 float3 warp=float3(strataNoise(q*.21,float3(0.)),
                strataNoise(q*.21+17.,float3(0.)),strataNoise(q*.21+39.,float3(0.)))-.5;
 q+=warp*5.6;
 float3 viewTangent=view-n*dot(view,n);
 float grazing=1.-clamp(dot(view,n),0.,1.);
 float3 shift=-viewTangent*(.36+.40*grazing);
 float rayHeight=1.,height=geologyProfile(q);
 float3 hit=q;
 // A bounded, globe-local relief intersection supplies parallax between
 // ridges and their gullies. This cannot alter the retained collision mesh.
 for(int step=0;step<7;++step){
  float reach=(float(step)+.5)/7.;
  float3 samplePoint=q+shift*reach;
  float surface=geologyProfile(samplePoint);
  float crossed=smoothstep(-.08,.08,surface-(1.-reach));
  float take=crossed*rayHeight;
  hit=mix(hit,samplePoint,take);
  height=mix(height,surface,take);
  rayHeight*=1.-crossed;
 }
 float3 sunTangent=light-n*dot(light,n);
 float slope=max(.10,dot(n,light));
 float shadow=0.;
 for(int step=1;step<=3;++step){
  float distance=float(step)*.22;
  float blocker=geologyProfile(hit+sunTangent*distance);
  shadow=max(shadow,smoothstep(.025,.16,blocker-height-distance*slope*.8));
 }
 float fine=strataNoise(hit*4.7+13.,float3(0.));
 float bedding=.5+.5*sin((height+warp.y*.11)*33.);
 bedding=mix(.5,bedding,1.-smoothstep(.6,2.,fwidth(height*33.)));
 return float4(height,fine,bedding,1.-shadow*.64);
}

// Hyperion impact basins retain separate crater fields on airless worlds.
float basinHash(float seed){
 float3 p=fract(float3(seed)*float3(.1031,.1030,.0973));
 p+=dot(p,p.yzx+33.33);
 return fract((p.x+p.y)*p.z);
}
float4 impactBasins(float3 n,float3 light,float phase,thread float& coverage){
 float height=0.,rims=0.,ejecta=0.,visibility=1.;
 coverage=0.;
 float footprint=max(length(dfdx(n)),length(dfdy(n)));
 for(int index=0;index<18;++index){
  float seed=float(index)*7.31+phase*113.;
  float3 centre=normalize(float3(basinHash(seed+1.),basinHash(seed+9.),basinHash(seed+23.))-.5);
  float size=index<4?.13+basinHash(seed+37.)*.12:.025+basinHash(seed+37.)*.085;
  float resolved=1.-smoothstep(.16,.60,footprint/size);
  float3 offset=(n-centre)/size;
  float r=length(offset);
  if(r>2.1 || resolved<.001)continue;
  float aa=max(.014,footprint/size);
  float floorMask=1.-smoothstep(.12,.98,r*r);
  float rim=exp(-pow((r-1.035)/(.095+aa),2.));
  float terrace=exp(-pow((r-.77)/(.065+aa),2.))*.14;
  float central=exp(-r*r/((index<4?.13:.065)+aa))*.24;
  height+=size*(-floorMask*.045+(rim+terrace+central)*.012)*resolved;
  coverage=max(coverage,(1.-smoothstep(.70,1.36,r))*resolved);
  rims+=rim*resolved;
  float3 rayDirection=normalize(n-centre*dot(n,centre)+float3(1e-8));
  float rayPhase=dot(rayDirection,float3(17.3,29.1,11.7))+seed;
  float rays=mix(.226,pow(.5+.5*sin(rayPhase),6.),1.-smoothstep(.6,2.,fwidth(rayPhase)));
  float skirt=exp(-max(0.,r-1.)*3.5)*smoothstep(.9,1.12,r);
  ejecta+=skirt*(.36+rays*.64)*resolved;
  float3 tangent=light-centre*dot(light,centre);
  float horizontal=max(length(tangent),.001);
  float3 towardSun=tangent/horizontal;
  float along=dot(offset,towardSun);
  float across2=max(0.,dot(offset,offset)-along*along);
  float toRim=max(.035,sqrt(max(.0,1.-across2))-along);
  float requiredSlope=(.012+floorMask*.045)/toRim;
  float lit=smoothstep(requiredSlope-.035,requiredSlope+.035,dot(n,light)/horizontal);
  visibility=min(visibility,mix(1.,.26+.74*lit,floorMask*resolved));
 }
 return float4(height,min(1.,rims),min(1.,ejecta),visibility);
}

// Orbital cloud bands, illumination and the magnetic envelope from Hyperion.
float3 xalariaClouds(float3 n,float3 axis,float3 lowColour,float3 highColour,float3 localLight,
                   float phase,float seconds,float bands,float contrast,thread float& cloudHeight){
 float latitude=dot(n,axis);
 float3 east=normalize(cross(axis,abs(axis.y)<.9?float3(0.,1.,0.):float3(1.,0.,0.))),north=cross(axis,east);
 float longitude=atan2(dot(n,north),dot(n,east)+1e-8);
 float jet=latitude*bands*3.14159265;
 float drift=sin(jet*.57)*seconds*.00025;
 float3 clouds=float3(dot(n,east),dot(n,north),latitude);
 float billow=strataNoise(clouds*float3(6.,6.,14.)+float3(phase*30.,2.,drift),float3(0.));
 float ripple=strataNoise(clouds*float3(16.,16.,91.)+float3(drift,phase*13.,billow*1.7),float3(5.,0.,0.));
 float curls=strataNoise(clouds*float3(43.,43.,190.)+float3(phase*21.,drift*2.,ripple*.9),float3(0.));
 float belt=jet+(billow-.5)*2.6+.35*sin(longitude*5.+latitude*12.-drift);
 float storm=0.,spiral=0.,eye=0.,eyewall=0.,feeders=0.,ovals=0.;
 for(int i=0;i<3;i++){
  float index=float(i);
  float lat=(i==1?-1.:1.)*(.18+phase*.22+index*.14);
  float heading=phase*6.283+index*2.39+seconds*.00011;
  float3 centre=axis*sin(lat)+(east*cos(heading)+north*sin(heading))*cos(lat);
  float3 tangent=normalize(cross(axis,centre)),meridian=cross(centre,tangent);
  float2 q=float2(dot(n-centre,tangent)/(.31-index*.051),dot(n-centre,meridian)/(.15-index*.025));
  float distance2=dot(q,q),facing=smoothstep(.72,.96,dot(n,centre));
  float core=exp(-distance2*1.20)*facing;
  float spin=atan2(q.y,q.x+1e-8)*2.-log(distance2+.024)*5.1+billow*2.8;
  float arms=.5+.5*sin(spin);
  float spinResolved=1.-smoothstep(.48,1.6,fwidth(spin));
  arms=mix(.5,arms,spinResolved);
  belt+=core*(arms-.30)*5.6;
  storm=max(storm,core);
  spiral=max(spiral,core*pow(arms,3.));
  eye=max(eye,exp(-distance2*34.)*facing);
  eyewall=max(eyewall,exp(-abs(sqrt(distance2)-.34)*16.)*facing*
              (.38+.62*arms));
  feeders=max(feeders,exp(-distance2*.45)*pow(arms,7.)*facing*(.35+.65*curls));
  // A wake of smaller vortices follows each major storm in its sheared
  // latitude band. Projected on the globe, rather than pasted on screen.
  for(int wake=1;wake<=3;++wake){
   float k=float(wake);
   float2 satellite=(q-float2(.83+k*.61,.22*sin(k*2.4+phase*5.)))/float2(.25+.023*k,.21);
   float d2=dot(satellite,satellite);
   float ring=exp(-abs(sqrt(d2)-.62)*9.);
   float inside=exp(-d2*4.);
   ovals+=facing*(ring*.30-inside*.22);
  }
 }
 float belts=mix(.5,.5+.5*sin(belt),1.-smoothstep(.6,2.,fwidth(belt)));
 float shear=.5+.5*sin(belt*2.13+ripple*2.3);
 shear=mix(.5,shear,1.-smoothstep(.45,1.4,fwidth(belt)*2.13));
 float3 low=lowColour*.50,high=highColour*1.28;
 float3 albedo=mix(low,high,mix(.5,belts,contrast*.85+.15));
 albedo*=.49+.31*billow+.31*ripple+.24*shear+.13*curls;
 albedo=mix(albedo,low*.70+high*(.35+spiral*.83),storm*.70);
 albedo=mix(albedo,low*.55,eye*.78);
 albedo+=high*(eyewall*.31+feeders*.22+max(0.,ovals));
 albedo*=1.+min(0.,ovals);
 float3 lightFrame=float3(dot(localLight,east),dot(localLight,north),dot(localLight,axis));
 float sunward=strataNoise(clouds*float3(6.,6.,14.)+float3(phase*30.,2.,drift)+lightFrame*.46,float3(0.));
 float reliefShade=clamp(.79+(billow-sunward)*2.7,.32,1.16);
 albedo*=mix(1.,reliefShade,smoothstep(-.12,.25,dot(n,localLight))*.74);
 cloudHeight=belts*.22+billow*.42+ripple*.15+curls*.07+eyewall*.23+feeders*.13-eye*.26;
 return albedo;
}

float3 xalariaBrdf(float3 albedo,float3 N,float3 V,float3 L,float rough,float metallic) {
 float3 H=normalize(V+L+float3(1e-20));float nv=max(dot(N,V),.001),nl=max(dot(N,L),0.),nh=max(dot(N,H),0.),vh=max(dot(V,H),0.);
 float a=rough*rough,a2=a*a,denom=nh*nh*(a2-1.)+1.;float D=a2/max(3.14159*denom*denom,.00001);
 float k=(rough+1.)*(rough+1.)/8.;float G=nv/(nv*(1.-k)+k)*nl/(nl*(1.-k)+k);
 float3 F0=mix(float3(.035),albedo,metallic),F=F0+(1.-F0)*pow(1.-vh,5.);
 return ((1.-F)*(1.-metallic)*albedo/3.14159+F*D*G/max(4.*nv*max(nl,.001),.001))*nl*3.8;
}
float3 reflectedEnvironment(float3 R,float3 up,float day,float phase,float rough,float3 sun){
 float h=dot(R,up),horizon=exp(-abs(h-.015)/mix(.025,.22,rough));
 float3 zenith=mix(float3(.008,.003,.002),float3(.045,.016,.009),day);
 float3 sky=mix(zenith,float3(3.2,.85,.12),horizon*(.40+.60*day));
 // Broad firelit cloud cards form readable reflections on smooth glass.
 float cloud=.5+.5*sin(R.x*5.+R.z*3.+phase*6.);
 sky+=float3(.38,.055,.009)*pow(cloud,4.)*exp(-abs(h-.17)*5.)*(1.-rough*.70);

 float alignment=max(0.,dot(R,sun));
 float glint=pow(alignment,mix(1800.,14.,rough*rough));
 sky+=float3(7.,2.8,.45)*glint*(.25+.75*day);
 sky+=spaceGlassGlow(R,phase,0.)*pow(1.-rough,3.)*.18;
 float3 ground=float3(.018,.006,.003)+float3(.18,.025,.008)*horizon;
 return mix(ground,sky,smoothstep(-.12,.06,h));
}
// Rough dielectric Fresnel: unresolved rough facets do not turn an entire
// grazing landscape into a white mirror. Wet coatings retain their glints.
float3 environmentReflectance(float3 f0,float fresnel,float rough){
 return f0+(max(float3(1.-rough),f0)-f0)*fresnel;
}
float3 diffuseEnvironment(float3 N,float3 up,float3 albedo,float day,float air){
 float skyFacing=clamp(dot(N,up)*.5+.5,0.,1.);
 float3 sky=mix(float3(.018,.028,.055),float3(.070,.12,.21),air)*(.15+.85*day);
 float3 bounce=mix(float3(.025,.017,.012),albedo*.09,air)*(.15+.85*day);
 return albedo*mix(bounce,sky,skyFacing);
}
float3 stellarCoronaEnvelope(float3 local,float altitude,float aa,float phase,float3 light){
 float3 pole=normalize(float3(.31+phase*.37,.87,-.29));
 float latitude=dot(local,pole);
 float3 q=local*(7.+altitude*2.3)+float3(phase*23.,7.,13.);
 float broad=strataNoise(q,float3(0.));
 float curl=strataNoise(q*2.17+float3(5.,broad*1.7,11.),float3(0.));
 float fibre=strataNoise(q*5.3+curl*.8,float3(0.));
 float sheet=pow(1.-abs(curl*2.-1.),6.);
 float equator=exp(-latitude*latitude*4.1);
 float stream=exp(-altitude/(.13+.43*broad*broad));
 float polar=pow(abs(latitude),6.)*exp(-altitude/.23);
 float inner=exp(-altitude/max(.022,aa))*(.26+fibre*.54);
 float corona=(sheet*(.10+.21*equator)+.016)*stream+polar*.021+inner*.24;
 float rim=1.-smoothstep(1.25,1.70,altitude);
 float3 cool=mix(light,float3(.52,.68,.92),.17);
 return mix(light,cool,smoothstep(.10,.72,altitude))*corona*rim;
}
