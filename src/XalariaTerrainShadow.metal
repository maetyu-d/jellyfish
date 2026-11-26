// Hyperion's snapped terrain shadow and receiver-plane depth comparison.
struct FlightTerrainSun {
    float4 right, up, depth, settings;
    float4 gearPoint, gearNormal;
};

float3 terrainShadowCoordinate(float3 point, constant FlightTerrainSun& sun) {
    const float4 v=float4(point,1.);
    return float3(dot(v,sun.right),dot(v,sun.up),dot(v,sun.depth));
}

struct FlightTerrainShadowVertex {
    float4 position [[position]];
};

vertex FlightTerrainShadowVertex flightTerrainShadowVertex(uint index [[vertex_id]],
                                                            device const float4* vertices [[buffer(0)]],
                                                            constant FlightTerrainSun& sun [[buffer(4)]]) {
    const auto q=terrainShadowCoordinate(vertices[index*3u].xyz,sun);
    return {float4(q.x*2.-1.,1.-q.y*2.,q.z,1.)};
}

float xalariaSurfaceSun(float3 point, float sunDot, constant FlightTerrainSun& sun,
                       depth2d<float> shadowMap) {
    if (sun.settings.x<.5) return 1.;
    const float3 q=terrainShadowCoordinate(point,sun);
    if (q.z<=0. || q.z>=1. || min(q.x,q.y)<=.002 || max(q.x,q.y)>=.998) return 1.;
    const float3 dx=dfdx(q),dy=dfdy(q);
    const float determinant=dx.x*dy.y-dx.y*dy.x;
    const float2 gradient=abs(determinant)>1.e-16 ?
        float2(dx.z*dy.y-dy.z*dx.y,dy.z*dx.x-dx.z*dy.x)/determinant : float2(0.);
    const float texel=sun.settings.y;
    const float2 p=q.xy/texel-.5, base=(floor(p)+.5)*texel, f=fract(p);
    const float receiver=q.z-max(.00006,.00016*(1.-saturate(sunDot)));
    constexpr sampler nearest(coord::normalized,address::clamp_to_edge,filter::nearest);
    const float2 b=base+float2(texel,0.),c=base+float2(0.,texel),d=base+texel;
    const float aa=step(receiver+dot(gradient,base-q.xy),shadowMap.sample(nearest,base));
    const float bb=step(receiver+dot(gradient,b-q.xy),shadowMap.sample(nearest,b));
    const float cc=step(receiver+dot(gradient,c-q.xy),shadowMap.sample(nearest,c));
    const float dd=step(receiver+dot(gradient,d-q.xy),shadowMap.sample(nearest,d));
    const float visibility=mix(mix(aa,bb,f.x),mix(cc,dd,f.x),f.y);
    const float edge=smoothstep(.015,.085,min(min(q.x,q.y),min(1.-q.x,1.-q.y)));
    return mix(1.,visibility,edge);
}

float xalariaGearContact(float3 point, constant FlightTerrainSun& sun) {
    if (sun.gearNormal.w<=0.) return 1.;
    float3 delta=point-sun.gearPoint.xyz;
    delta-=sun.gearNormal.xyz*dot(delta,sun.gearNormal.xyz);
    const float contact=exp(-dot(delta,delta)/max(sun.gearPoint.w*sun.gearPoint.w,1.e-24));
    return 1.-contact*sun.gearNormal.w;
}
