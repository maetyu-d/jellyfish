#include "XalariaWeather.hpp"
#include "ShipFlight.hpp"

#include <algorithm>
#include <chrono>
#include <cmath>
#include <fstream>
#include <future>
#include <iomanip>
#include <limits>
#include <map>
#include <numbers>
#include <stdexcept>

namespace pelagic {
namespace {

using Point = simd_double3;
constexpr double pi = std::numbers::pi;
constexpr double tau = 2.*pi;
constexpr double interval = 8.;

struct Climate {
    std::uint64_t seed{};
    std::uint64_t inherited{};
    double radius{}, temperature{}, pressure{}, gravity{}, moisture{}, day{}, scaleHeight{}, wind{};
    Point axis{};
};

double smooth(double lo,double hi,double x) {
    x=std::clamp((x-lo)/(hi-lo),0.,1.);
    return x*x*(3.-2.*x);
}

std::uint64_t mixKey(std::uint64_t x) {
    x+=0x9e3779b97f4a7c15ULL;
    x=(x^(x>>30))*0xbf58476d1ce4e5b9ULL;
    x=(x^(x>>27))*0x94d049bb133111ebULL;
    return x^(x>>31);
}

double randomUnit(std::uint64_t key,std::uint64_t counter) {
    return double(mixKey(key^mixKey(counter))>>11)*0x1.0p-53;
}

float weatherPhase(std::uint64_t key) {
    const float phase=float(key%10000)*.0371f;
    return phase-std::floor(phase);
}

double valueNoise(Point p,std::uint64_t seed) {
    const Point cell={std::floor(p.x),std::floor(p.y),std::floor(p.z)};
    Point f=p-cell;
    f=f*f*(3.-2.*f);
    const auto corner=[&](int x,int y,int z) {
        auto h=mixKey(seed^std::uint64_t(std::int64_t(cell.x)+x));
        h=mixKey(h^std::uint64_t(std::int64_t(cell.y)+y));
        h=mixKey(h^std::uint64_t(std::int64_t(cell.z)+z));
        return randomUnit(h,0)*2.-1.;
    };
    const auto mix=[](double a,double b,double t) { return a*(1.-t)+b*t; };
    const double a=mix(corner(0,0,0),corner(1,0,0),f.x), b=mix(corner(0,1,0),corner(1,1,0),f.x);
    const double c=mix(corner(0,0,1),corner(1,0,1),f.x), d=mix(corner(0,1,1),corner(1,1,1),f.x);
    return mix(mix(a,b,f.y),mix(c,d,f.y),f.z);
}

double frontNoise(Point p,std::uint64_t seed) {
    double amplitude=.5, sum=0.;
    for (unsigned i=0;i<3;++i) {
        sum+=valueNoise(p,seed)*amplitude;
        p=p*2.03+Point{17.1,3.7,9.2};
        amplitude*=.5;
    }
    return sum;
}

struct CloudLayers { double base, top; };

CloudLayers cloudLayers(const Climate& c) {
    const double base=std::min(std::clamp((1.-c.moisture)*3200.+500.,500.,6500.),c.scaleHeight*1.4);
    const double depth=std::clamp(c.scaleHeight*.70,600.,11000.);
    return {base,std::min(base+depth,c.scaleHeight*4.)};
}

double discharge(const Climate& c,double t) {
    if (c.moisture<.25 || c.temperature<250.) return 0.;
    const double cycle=t/(9.+randomUnit(c.seed,71)*13.)+randomUnit(c.seed,72);
    const double primary=smooth(.982,1.,std::cos(cycle*tau));
    const double echo=smooth(.994,1.,std::cos((cycle-.026)*tau));
    return std::max(primary*primary,echo*echo*.65);
}

// Infinity Weather.cpp v2. The atlas uses zero altitude and ground wetness
// uses the same sampler at the camera's physical altitude.
class WeatherSampler {
public:
    WeatherSampler(const Climate& climate,double seconds)
        : c_(climate), time_(seconds), axis_(simd_normalize(climate.axis)),
          radius_(std::max(10000.,climate.radius)) {
        const auto east=simd_normalize(simd_cross(std::abs(axis_.y)>.95 ? Point{0.,0.,1.} : Point{0.,1.,0.},axis_));
        const auto north=simd_cross(east,axis_);
        const auto key=mixKey(c_.seed^0x77656174686572ULL^(std::uint64_t(2)<<32));
        const double omega=tau/std::max(1000.,c_.day);
        const double deformation=std::sqrt(std::max(1.,c_.gravity*c_.scaleHeight))/(omega*radius_);
        const double evolution=time_/std::max(14400.,radius_/std::max(40.,c_.wind*20.));
        evolution_={std::sin(evolution*.31),std::cos(evolution*.23)-1.,std::sin(evolution*.17)};
        for (unsigned i=0;i<cyclones_.size();++i) {
            auto& cyclone=cyclones_[i];
            cyclone.hemisphere=i<2 ? 1. : -1.;
            const double latitude=cyclone.hemisphere*(.30+randomUnit(key,i*5)*.65);
            const double drift=time_*c_.wind/radius_*(.45+randomUnit(key,i*5+1));
            const double longitude=std::fmod(randomUnit(key,i*5+2)*tau+drift,tau);
            cyclone.centre=east*(std::cos(latitude)*std::cos(longitude))+axis_*std::sin(latitude)+
                           north*(std::cos(latitude)*std::sin(longitude));
            cyclone.east=simd_normalize(simd_cross(axis_,cyclone.centre));
            cyclone.north=simd_cross(cyclone.centre,cyclone.east);
            cyclone.radius=std::clamp(deformation*(.15+randomUnit(key,i*5+3)*.12),.065,.25);
            const double lifetime=43200.+randomUnit(key,i*5+4)*86400.;
            const double cycle=.5+.5*std::sin(time_*tau/lifetime+i*2.4);
            cyclone.strength=(.25+.75*cycle*cycle)*smooth(.05,.55,c_.moisture);
        }
    }

    struct Reading {
        std::array<double,4> channels{};
        double rain{};
    };

    Reading sample(Point d,double altitude=0.) const {
        d=simd_normalize(d);
        const double pressureBar=c_.pressure*std::exp(-std::max(0.,altitude)/std::max(1.,c_.scaleHeight));
        if (pressureBar<1.e-5) return {};
        const double vertical=simd_dot(d,axis_);
        const double latitude=std::asin(std::clamp(vertical,-1.,1.));
        const double zonal=.45-1.15*std::cos(latitude*3.);
        const double drift=time_*c_.wind/radius_;
        const auto q=simd_act(simd_quaternion(-std::fmod(drift*zonal,tau),axis_),d);
        const double pressure=frontNoise(q*5.+evolution_*.5,c_.seed);
        const double eddy=valueNoise(q*19.+evolution_,mixKey(c_.seed^1));
        const double tropicalLift=std::exp(-latitude*latitude*13.);
        const double subsidence=std::exp(-std::pow((std::abs(latitude)-.50)/.19,2));
        const double jet=std::exp(-std::pow((std::abs(latitude+pressure*.26)-.92)/.24,2));
        const double front=jet*std::exp(-std::pow(pressure+eddy*.12,2)*30.);
        double temperature=std::max(30.,c_.temperature+30.*(.333333-vertical*vertical)-
                                        std::clamp(altitude,0.,16000.)*.004);
        const double convection=c_.moisture*smooth(245.,305.,temperature)*
            smooth(-.15,.42,eddy+pressure*.45)*(.30+tropicalLift*.70);
        temperature+=pressure*4.;
        const double boiling=373.15+27.*std::log(std::max(.006,pressureBar));
        const double condensate=(1.-smooth(boiling-8.,boiling+8.,temperature))*smooth(105.,165.,temperature);
        double cloud=smooth(-.25,.44,pressure*.65+eddy*.20+c_.moisture*.78+tropicalLift*.15+
                                   front*.24-subsidence*.16-.30);
        const Point east=simd_cross(axis_,d), meridian=axis_-d*vertical;
        Point wind=(east*zonal+meridian*(-std::sin(latitude*6.)*.25+pressure*.35))*c_.wind;
        double spiral=0.;
        for (const auto& cyclone:cyclones_) {
            const double separation=std::atan2(simd_length(simd_cross(d,cyclone.centre)),simd_dot(d,cyclone.centre));
            const double r=separation/cyclone.radius;
            if (r>3.) continue;
            const double angle=std::atan2(simd_dot(d,cyclone.north),simd_dot(d,cyclone.east));
            const double envelope=std::exp(-r*r*.72)*(1.-smooth(2.4,3.,r));
            const double arms=.5+.5*std::sin(angle*2.*cyclone.hemisphere-r*8.);
            const double eye=smooth(.13,.40,r);
            const double band=envelope*(.38+arms*.62)*eye*cyclone.strength;
            cloud=std::max(cloud,band*1.25)*(1.-(1.-eye)*envelope*cyclone.strength*.68);
            spiral=std::max(spiral,band);
            const auto swirl=simd_cross(cyclone.centre,d);
            const auto inward=cyclone.centre-d*simd_dot(cyclone.centre,d);
            const double norm=std::max(1e-8,simd_length(swirl));
            wind+=(swirl*(cyclone.hemisphere/norm)+inward/norm*.18)*c_.wind*envelope*eye*cyclone.strength*1.7;
        }
        cloud=std::clamp(cloud*condensate*smooth(.005,.14,c_.moisture),0.,1.);
        double storm=std::clamp(smooth(.50,.94,cloud)*(.18+convection*.70+front*.50+spiral*.90),0.,1.);
        const double speed=simd_length(wind);
        const double dust=std::clamp((1.-smooth(.08,.20,c_.moisture))*smooth(5.,16.,speed)*
                                      smooth(-.10,.30,eddy+std::abs(pressure)*.6),0.,1.);
        storm=std::max(storm,dust*.85);
        const double base=cloudLayers(c_).base;
        const double belowCloud=1.-smooth(base*.8,base,altitude);
        double precipitation=std::clamp(c_.moisture*smooth(.48,.94,cloud)*(.55+storm*.8),0.,1.)*belowCloud;
        const bool isDust=precipitation<=.09 && dust>.08 && speed>8.;
        if (isDust) precipitation=dust*belowCloud;
        return {{cloud,storm,precipitation,dust},isDust ? 0. : precipitation};
    }

private:
    Climate c_;
    double time_;
    Point axis_;
    double radius_;
    Point evolution_{};
    struct Cyclone {
        Point centre{}, east{}, north{};
        double hemisphere{}, radius{}, strength{};
    };
    std::array<Cyclone,4> cyclones_{};
};

std::shared_ptr<const XalariaWeatherField> bake(const Climate& climate,double seconds) {
    auto field=std::make_shared<XalariaWeatherField>();
    auto& pixels=field->pixels;
    constexpr auto width=XalariaWeatherField::width, height=XalariaWeatherField::height;
    pixels.reserve(width*height*4*4/3+8);
    const WeatherSampler sampler(climate,seconds);
    for (unsigned y=0;y<height;++y) {
        const double latitude=pi*(.5-double(y)/(height-1));
        for (unsigned x=0;x<width;++x) {
            const double longitude=tau*((x+.5)/width-.5);
            const Point direction=y==0 ? Point{0.,1.,0.} : y+1==height ? Point{0.,-1.,0.} :
                Point{std::cos(latitude)*std::cos(longitude),std::sin(latitude),
                      std::cos(latitude)*std::sin(longitude)};
            for (double value:sampler.sample(direction).channels) pixels.push_back(std::uint8_t(std::lround(value*255.)));
        }
    }
    std::size_t previous=0;
    for (unsigned w=width,h=height;w>1 || h>1;) {
        const unsigned nw=std::max(1u,w/2), nh=std::max(1u,h/2);
        const auto begin=pixels.size();
        for (unsigned y=0;y<nh;++y) for (unsigned x=0;x<nw;++x) for (unsigned c=0;c<4;++c) {
            unsigned sum=0;
            for (unsigned j=0;j<2;++j) for (unsigned i=0;i<2;++i)
                sum+=pixels[previous+(std::min(h-1,2*y+j)*w+std::min(w-1,2*x+i))*4+c];
            pixels.push_back(std::uint8_t((sum+2)/4));
        }
        previous=begin;
        w=nw;
        h=nh;
    }
    return field;
}

Point xyz(Quad q) { return {q.x,q.y,q.z}; }

} // namespace

struct XalariaWeather::State {
    std::map<std::pair<unsigned,std::string>,Climate> climates;
    struct Snapshot {
        std::uint64_t seed{};
        double seconds{};
        Fields fields;
    };
    Snapshot ready;
    std::future<Snapshot> pending;
    std::uint64_t active{};
    float ramp{};
};

XalariaWeather::XalariaWeather(const std::filesystem::path& catalogue) : state_(std::make_unique<State>()) {
    std::ifstream in(catalogue);
    std::string header;
    if (!std::getline(in,header) || header!="XALARIA_WEATHER\t1")
        throw std::runtime_error("Invalid Xalaria weather catalogue");
    unsigned id;
    std::string name;
    while (in>>id>>std::quoted(name)) {
        Climate c;
        double x,y,z;
        if (!(in>>c.seed>>c.inherited>>c.radius>>c.temperature>>c.pressure>>c.gravity>>c.moisture>>c.day
                >>c.scaleHeight>>c.wind>>x>>y>>z))
            throw std::runtime_error("Invalid Xalaria world climate");
        c.axis={x,y,z};
        if (!state_->climates.emplace(std::make_pair(id,name),c).second)
            throw std::runtime_error("Invalid Xalaria world climate");
    }
    if (!in.eof() || state_->climates.empty()) throw std::runtime_error("Invalid Xalaria weather catalogue");
}

XalariaWeather::~XalariaWeather() = default;

XalariaWeather::Fields XalariaWeather::prepare(const ShipFlight& flight, FlightScene& scene,double delta,
                                             unsigned width,unsigned height) {
    scene.cloudShell={};
    scene.terrainView.z=0.f;
    if (flight.region()) return {};
    const auto eye=xyz(scene.eye), forward=xyz(scene.forward), right=xyz(scene.right), up=xyz(scene.up);
    const double vertical=1./1.428148, horizontal=vertical*scene.screen.x;
    const unsigned id=flight.systemId();
    const Climate* visible=nullptr;
    double nearest=std::numeric_limits<double>::infinity();
    unsigned index=0;
    bool known=false;
    for (unsigned i=1;i<unsigned(scene.navigation.z);++i) {
        auto& body=scene.bodies[i];
        if (body.surface.x>.5f) continue;
        const auto row=state_->climates.find({id,flight.bodyName(i)});
        if (row==state_->climates.end()) continue;
        known=true;
        const auto& c=row->second;
        body.appearance.pole.w=float(c.pressure);
        body.colour.w=float(c.temperature);
        scene.cloudDeckPhases[i]=weatherPhase(c.inherited);
        const double strength=c.pressure*288./std::max(60.,c.temperature);
        if (strength<=.01) continue;
        const Point offset=xyz(body.position)-eye;
        const double range=simd_length(offset), radius=body.position.w;
        if (range<=.99*radius || range>=8.*radius) continue;
        const double gap=(range/radius-1.)*c.radius;
        if (gap>=nearest) continue;
        const double shell=radius*(1.+std::max(5.6*c.scaleHeight,cloudLayers(c).top)/c.radius);
        const double ahead=simd_dot(offset,forward);
        if (ahead< -shell ||
            std::abs(simd_dot(offset,right))>ahead*horizontal+shell*std::hypot(1.,horizontal) ||
            std::abs(simd_dot(offset,up))>ahead*vertical+shell*std::hypot(1.,vertical)) continue;
        nearest=gap;
        index=i;
        visible=&c;
    }
    if (known) scene.atmosphere={};
    if (!visible) return {};
    const auto& c=*visible;
    const auto layers=cloudLayers(c);
    const double heightRatio=std::clamp(c.scaleHeight/c.radius,1.e-5,.02);
    const auto direction=simd_normalize(eye-xyz(scene.bodies[index].position));
    const auto sun=simd_normalize(xyz(scene.bodies[0].position)-xyz(scene.bodies[index].position));
    const double strength=std::clamp(c.pressure*288./std::max(60.,c.temperature),0.,6.);
    const double tangent=std::sqrt(tau*c.radius*c.scaleHeight)/1000.;
    const double night=1.-smooth(-.26,-.10,simd_dot(direction,sun));
    const double low=1.-smooth(1.,4.444,nearest/c.scaleHeight);
    scene.atmosphere={float(index),float(heightRatio),
        float(std::lerp(strength,std::min(strength,1.5/(.029*tangent)),low*night)),float(c.radius/1000.)};
    const double time=std::max(0.,flight.systemTime());
    if (index==unsigned(scene.terrainView.x) && nearest<layers.base) {
        auto local=xyz(scene.terrainEye)+xyz(scene.terrainEyeResidual);
        if (simd_length_squared(local)<=1.) local=direction*(c.radius+nearest);
        const auto sample=WeatherSampler(c,time).sample(local,simd_length(local)-c.radius);
        scene.terrainView.z=float(sample.rain);
    }
    if (c.moisture<.005 || c.temperature<85. || !width || !height) return {};

    const double start=std::floor(time/interval)*interval;
    auto& state=*state_;
    if (state.pending.valid() && state.pending.wait_for(std::chrono::seconds(0))==std::future_status::ready)
        state.ready=state.pending.get();
    if (state.active!=c.seed) {
        state.active=c.seed;
        state.ramp=0.;
    }
    if (!state.pending.valid() && (state.ready.seed!=c.seed || state.ready.seconds!=start)) {
        auto existing=state.ready.seed==c.seed && state.ready.seconds+interval==start ? state.ready.fields[1] : nullptr;
        state.pending=std::async(std::launch::async,[c,start,existing] {
            return State::Snapshot{c.seed,start,{existing ? existing : bake(c,start),bake(c,start+interval)}};
        });
    }
    if (state.ready.seed!=c.seed || !state.ready.fields[0]) return {};
    state.ramp=std::min(1.f,state.ramp+float(std::max(0.,delta)/.35));
    const double speed=time*c.wind/1000.;
    scene.cloudShell={float(1.+layers.base/c.radius),float(1.+layers.top/c.radius),float(c.pressure),state.ramp};
    scene.cloudOptics={float(std::clamp((time-state.ready.seconds)/interval,0.,1.)),weatherPhase(c.seed),
                       float(c.moisture),float(discharge(c,time))};
    scene.cloudMotion={float(std::fmod(speed*.29,256.)),float(std::fmod(speed*.07,256.)),
                       float(std::fmod(speed*.13,256.)),float((layers.top-layers.base)/1000.)};
    scene.cloudProjection={float(index),1.f/float(width),1.f/float(height),float(c.radius/1000.)};
    return state.ready.fields;
}

} // namespace pelagic
