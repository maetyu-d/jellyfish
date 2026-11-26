#include "XalariaInstruments.hpp"
#include "XalariaAtlasFont.hpp"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <numbers>
#include <string_view>

namespace pelagic {
namespace {

// Flight layout, casing, instrument surfaces and glyph metrics from Xalaria v0.68.0.
namespace font = infinity::atlasFontData;
constexpr Vec pearl{.93f,.949f,.896f}, ice{.62f,.77f,.81f}, muted{.48f,.61f,.59f};
constexpr Vec signal{.24f,.78f,.68f}, lamp{.87f,.79f,.63f}, rule{.12f,.25f,.25f};
constexpr Vec amber{1.f,.73f,.29f}, terminalInk{.022f,.044f,.050f};
struct Palette { Vec paper, card, tint; };

Palette palette(XalariaLook look) {
    switch (look) {
        case XalariaLook::VerdantFog: return {{.012f,.026f,.017f},{.017f,.037f,.024f},{.95f,1.14f,.74f}};
        case XalariaLook::TidalBlue: return {{.011f,.022f,.033f},{.017f,.033f,.051f},{.82f,1.06f,1.20f}};
        case XalariaLook::AcidEtch: return {{.023f,.014f,.021f},{.037f,.024f,.033f},{1.15f,1.10f,.79f}};
        case XalariaLook::CharredGlass: return {{.022f,.011f,.008f},{.038f,.021f,.015f},{1.25f,1.10f,.72f}};
    }
    return {};
}

float dot(Vec a,Vec b) { return a.x*b.x+a.y*b.y+a.z*b.z; }
float length(Vec p) { return std::sqrt(dot(p,p)); }
Vec unit(Vec p) { return p*(1.f/std::max(1.e-20f,length(p))); }
Vec cross(Vec a,Vec b) { return {a.y*b.z-a.z*b.y,a.z*b.x-a.x*b.z,a.x*b.y-a.y*b.x}; }

struct Rect { float x,y,w,h; };

std::uint32_t rgba(Vec colour,float alpha) {
    const auto byte=[](float v) { return std::uint32_t(std::lround(std::clamp(v,0.f,1.f)*255.f)); };
    return byte(colour.x)|(byte(colour.y)<<8u)|(byte(colour.z)<<16u)|(byte(alpha)<<24u);
}

const font::Glyph& glyph(unsigned char value) {
    return font::glyphs[(value >= 32 && value < 127 ? value : '?')-32];
}
bool continuation(unsigned char value) { return (value&0xc0u)==0x80u; }
float measure(std::string_view s,float size) {
    float result{};
    for (unsigned char c : s)
        if (!continuation(c)) result += glyph(c).advance64*size/(64*font::em);
    return result;
}

class Canvas {
public:
    explicit Canvas(std::vector<InstrumentVertex>& out,float opacity = 1.f)
        : out_(out), opacity_(opacity) {}
    Canvas(std::vector<InstrumentVertex>& out,Vec origin,Vec right,Vec down)
        : out_(out),origin_(origin+unit(cross(right,down))*-.005f),right_(right*(1.f/360.f)),
          down_(unit(down)*(length(right)/360.f)),height_(length(down)*360.f/length(right)) {}
    float height() const { return height_; }
    Vec at(float x,float y) const { return origin_+right_*x+down_*y; }
    void quad(Rect box,Vec rgb,float a=1.f,float u=-1,float v=-1,float s=-1,float t=-1) {
        const auto colour=rgba(rgb,a*opacity_);
        const auto vertex=[&](float x,float y,float u,float v) {
            const auto p=at(x,y);
            return InstrumentVertex{p.x,p.y,p.z,u,v,colour};
        };
        const auto a0=vertex(box.x,box.y,u,v), b=vertex(box.x+box.w,box.y,s,v);
        const auto c=vertex(box.x,box.y+box.h,u,t), d=vertex(box.x+box.w,box.y+box.h,s,t);
        out_.insert(out_.end(),{a0,b,c,b,d,c});
    }
    void line(float x,float y,float u,float v,Vec rgb,float opacity=1.f,float width=1.f) {
        const float len=std::hypot(u-x,v-y);
        if (len < .001f) return;
        const float a=(v-y)*width/(2.f*len), b=(x-u)*width/(2.f*len);
        const auto colour=rgba(rgb,opacity*opacity_);
        const auto vertex=[&](float x,float y) {
            const auto p=at(x,y);
            return InstrumentVertex{p.x,p.y,p.z,-1,-1,colour};
        };
        const auto p=vertex(x+a,y+b), q=vertex(u+a,v+b), r=vertex(x-a,y-b), s=vertex(u-a,v-b);
        out_.insert(out_.end(),{p,q,r,q,s,r});
    }
    void text(std::string_view label,float x,float y,float room,float size,Vec colour,bool right=false) {
        std::string fitted;
        if (measure(label,size)>room) {
            float width=measure("...",size);
            for (unsigned char c : label) {
                if (continuation(c)) continue;
                width += glyph(c).advance64*size/(64*font::em);
                if (width>room) break;
                fitted += c<127 ? char(c) : '?';
            }
            if (fitted.empty()) return;
            fitted += "...";
            label=fitted;
        }
        if (right) x+=room-measure(label,size);
        const float scale=size/font::em, baseline=y+size*.79f;
        for (unsigned char c : label) {
            if (continuation(c)) continue;
            const auto& g=glyph(c);
            if (g.w) quad({x+g.left*scale,baseline+g.top*scale,g.w*scale,g.h*scale},colour,1.f,
                          float(g.x)/font::width,float(g.y)/font::height,
                          float(g.x+g.w)/font::width,float(g.y+g.h)/font::height);
            x+=g.advance64*size/(64*font::em);
        }
    }
    void ellipse(float x,float y,float rx,float ry,Vec colour,float opacity=1.f) {
        for (unsigned i=0;i<48;++i) {
            const float a=float(i)*(2.f*std::numbers::pi_v<float>/48.f);
            const float b=a+2.f*std::numbers::pi_v<float>/48.f;
            line(x+rx*std::cos(a),y+ry*std::sin(a),x+rx*std::cos(b),y+ry*std::sin(b),colour,opacity);
        }
    }
    void diamond(float x,float y,float r,Vec colour) {
        line(x-r,y,x,y-r,colour); line(x,y-r,x+r,y,colour);
        line(x+r,y,x,y+r,colour); line(x,y+r,x-r,y,colour);
    }
private:
    std::vector<InstrumentVertex>& out_;
    float opacity_{1.f};
    Vec origin_{},right_{1,0,0},down_{0,1,0};
    float height_{900.f};
};

std::string quantity(double metres,bool speed = false) {
    double divisor=1.;
    const char* unit="m";
    const double a=std::abs(metres);
    if (speed && a>=299792458.) {
        char c[36];
        std::snprintf(c,sizeof(c),"%.2f c",metres/299792458.);
        return c;
    }
    if (a>=9.4607304725808e14 && !speed) { divisor=9.4607304725808e15; unit="ly"; }
    else if (a>=1.495978707e10 && !speed) { divisor=1.495978707e11; unit="AU"; }
    else if (a>=1000.) { divisor=1000.; unit="km"; }
    else if (a >= .0005 && a < 1.) { divisor=.001; unit="mm"; }
    else if (a < .0005) metres=0.;
    const double value=metres/divisor;
    char text[36];
    const auto unitName=std::string_view(unit);
    const char* format=std::abs(value)>=100000. ? "%.1e %s%s" : unitName=="AU" || unitName=="ly" ? "%.2f %s%s" :
                       std::abs(value)<100. ? "%.1f %s%s" : "%.0f %s%s";
    std::snprintf(text,sizeof(text),format,value,unit,speed?"/s":"");
    return text;
}

std::string percent(float fraction) { return std::to_string(int(std::round(fraction*100)))+"%"; }

void bar(Canvas& c,float x,float y,float width,float value,Vec colour) {
    c.quad({x,y,width,2.f},colour*.27f);
    if (value > 0.f) c.quad({x,y,width*value,2.f},colour);
}

void physicalScreens(XalariaInstruments& out,const ShipFlight& pilot,const FlightScene& f,Vec bearing,
                     const std::string& speed,const std::string& range,const std::string& stopping) {
    const auto target=pilot.targetName();
    Canvas drive(out.screens,{-.39f,-.352f,-1.25f},{.78f,0,0},{0,-.160f,.179f});
    drive.quad({0,0,360,drive.height()},terminalInk);
    drive.text("Velocity",18,12,174,18,signal);
    drive.text(pilot.warping()?"Time to exit":"Stop distance",210,12,132,18,signal);
    drive.quad({18,34,324,1},rule);
    drive.quad({197,10,1,86},rule);
    drive.text(speed,18,41,172,std::min(27.f,171.f/std::max(1.f,measure(speed,1.f))),lamp);
    drive.text(stopping,210,41,132,std::min(23.f,131.f/std::max(1.f,measure(stopping,1.f))),lamp);
    drive.text(pilot.warping()?"WARP DRIVE":"PLANETARY FLIGHT",18,78,172,17,signal);
    const float roll=std::atan2(f.shipRight.y,f.shipUp.y)*180.f/std::numbers::pi_v<float>;
    const int bank=int(std::round(roll));
    drive.text(bank==0 ? "Bank 0" : "Bank "+std::string(bank>0?"L":"R")+std::to_string(std::abs(bank)),
               210,78,132,17,signal);

    Canvas port(out.screens,{-.907f,-.322f,-.27f},{0,0,-.53f},{.18f,-.157f,0});
    port.quad({0,0,360,port.height()},terminalInk);
    port.text("Throttle",18,21,163,23,pearl);
    port.text(percent(f.controls.w),198,17,144,29,amber,true);
    bar(port,18,58,324,f.controls.w,amber);
    port.quad({18,81,324,1},rule);
    port.text("Flight assist",18,101,163,23,pearl);
    port.text(pilot.assisted()?"On":"Off",191,98,151,27,signal,true);

    Canvas starboard(out.screens,{.907f,-.322f,-.80f},{0,0,.53f},{-.18f,-.157f,0});
    starboard.quad({0,0,360,starboard.height()},terminalInk);
    starboard.text("Navigation",18,15,176,20,signal);
    starboard.quad({18,41,176,1},rule);
    starboard.quad({205,16,1,129},rule);
    starboard.text(target,18,50,176,25,lamp);
    starboard.text(range,18,85,132,18,signal);
    if (bearing.z>0.f) starboard.text("Aft",155,85,39,18,amber);
    starboard.text("Hull "+percent(float(pilot.missionHull()/100.)),18,124,176,20,signal);
    starboard.ellipse(274,81,52,52,rule);
    starboard.ellipse(274,81,22,22,rule);
    starboard.line(221,81,327,81,rule);
    starboard.line(274,28,274,134,rule);
    const float polar=std::acos(std::clamp(-bearing.z,-1.f,1.f))/std::numbers::pi_v<float>;
    const float plane=std::max(.001f,std::hypot(bearing.x,bearing.y));
    starboard.diamond(274+45*polar*bearing.x/plane,81-45*polar*bearing.y/plane,5,lamp);

    Canvas overhead(out.screens,{-.167f,.472f,.122f},{.334f,0,0},{0,0,-.35f});
    overhead.quad({0,0,360,overhead.height()},terminalInk);
    const auto row=[&](float y,std::string_view name,std::string_view value,Vec colour) {
        overhead.quad({18,y,324,90},{.04f,.11f,.11f});
        overhead.quad({18,y,5,90},colour);
        overhead.text(name,34,y+30,122,26,lamp);
        overhead.text(value,164,y+30,165,26,colour,true);
    };
    row(39,"Gear","Up",muted);
    row(143,"Assist",pilot.assisted()?"On":"Off",pilot.assisted()?signal:amber);
    row(247,"Dock","Free",muted);
}
} // namespace

std::vector<std::uint8_t> xalariaFontPixels() {
    std::vector<std::uint8_t> pixels;
    pixels.reserve(font::width*font::height);
    for (const auto run : font::coverageRuns)
        pixels.insert(pixels.end(),(run&255u)+1u,std::uint8_t(run>>8u));
    return pixels;
}

XalariaInstruments xalariaInstruments(const ShipFlight& pilot,const FlightScene& f,const Ocean& ocean,float opacity) {
    XalariaInstruments out;
    out.screens.reserve(5600);
    out.overlay.reserve(6800);
    const auto target=f.bodies[unsigned(f.navigation.x)].position;
    const Vec difference={target.x,target.y,target.z};
    const auto direction=length(difference)>1.e-16f ? unit(difference) : Vec{0,0,-1};
    const auto dotBasis=[&](Quad axis) { return dot(direction,{axis.x,axis.y,axis.z}); };
    const Vec bearing{dotBasis(f.shipRight),dotBasis(f.shipUp),-dotBasis(f.shipForward)};
    const auto speed=quantity(pilot.speed()*1000.,true);
    const auto range=quantity(pilot.targetRange()*1000.);
    const auto stop=pilot.warping() ? std::to_string(int(std::ceil(pilot.warpEta())))+" s" :
                                    quantity(pilot.stoppingDistance());
    physicalScreens(out,pilot,f,bearing,speed,range,stop);
    if (opacity <= .004f) return out;

    const auto look=static_cast<XalariaLook>(unsigned(f.optics.x));
    const auto colours=palette(look);
    const auto tone=[&](Vec rgb) {
        const float y=dot(rgb,{.299f,.587f,.114f});
        return colours.tint*y;
    };
    const auto soft=tone(muted), light=tone(pearl), accent=tone(ice);
    constexpr std::array<const char*,4> lookNames{"CHARRED GLASS","VERDANT FOG","TIDAL BLUE","ACID ETCH"};
    Canvas hud(out.overlay,opacity);
    // The original flight grid is 900 high. Reflow the four cards only for narrow windows.
    const float width=900*f.screen.x, middle=width*.5f;
    const auto card=[&](Rect r) {
        hud.quad(r,colours.card,.94f);
        hud.quad({r.x,r.y,1.4f,r.h},soft,.6f);
    };
    hud.quad({0,0,width,46},colours.paper,.98f);
    hud.text("INFINITY",26,15,135,19,light);
    hud.text("FLIGHT",middle-28,17,72,14,accent);
    hud.text("G CHASE VIEW",width-178,20,154,10,soft,true);
    hud.line(24,45,width-24,45,soft,.36f);
    card({24,64,196,58});
    hud.text("SHIP / FULL SIZE",38,75,168,10,soft);
    hud.text("12.0 m",38,94,168,22,light);
    const float noticeWidth=std::min(650.f,width*.43f);
    card({middle-noticeWidth*.5f,64,noticeWidth,36});
    const auto driveStatus=pilot.warpStatus();
    hud.text(driveStatus.empty()?"Y SELECT A WORLD / J WARP":driveStatus,
             middle-noticeWidth*.5f+13,77,noticeWidth-26,12,accent);

    const auto region=pilot.region();
    const auto bodies=region ? ocean.systemBubbles().subspan(region->firstSystem,region->systems) : std::span<const SystemBubble>{};
    const unsigned count=region ? region->systems : unsigned(f.navigation.z);
    const float contactWidth=std::min(274.f,width*.20f);
    card({24,145,contactWidth,119});
    hud.text("CONTACTS "+std::to_string(count),38,156,contactWidth-28,12,accent);
    for (unsigned i=0;i<std::min(count,3u);++i) {
        const auto* record=region ? ocean.systemById(unsigned(bodies[i].catalogue.x)) : nullptr;
        const auto name=region ? (record ? record->name : std::string("System")) : pilot.bodyName(i);
        const float y=181.f+24.f*i;
        hud.text(name,38,y,contactWidth*.55f,11,light);
        hud.text(quantity(pilot.contactRange(i)*1000.),24+contactWidth*.64f,y,contactWidth*.31f,10,soft,true);
    }
    const float navigationWidth=std::min(318.f,width*.24f), right=width-24-navigationWidth;
    card({right,145,navigationWidth,133});
    hud.text("NAVIGATION",right+14,157,navigationWidth-28,12,accent);
    hud.text(pilot.locationName(),right+14,185,navigationWidth-28,15,light);
    hud.text(lookNames[unsigned(look)],right+14,209,navigationWidth-28,10,soft);
    const float grid= (navigationWidth-32)/16.f;
    const auto& atlas=ocean.regionStars();
    const unsigned cell=pilot.regionCell();
    for (unsigned x=0;x<regionSide;++x) for (unsigned y=0;y<regionSide;++y) {
        const auto star=atlas[cell*regionArea+y*regionSide+x]&63u;
        if (star==0) continue;
        hud.quad({right+16+(float(x)+.5f)*grid*16.f/regionSide,233.f+1.43f*float(y),1.45f,1.45f},
                 soft,.24f+.56f*float(star)/63.f);
    }
    hud.ellipse(right+navigationWidth*.5f,245,11,11,accent,.69f);
    hud.diamond(right+navigationWidth*.5f,245,3.8f,light);

    const float cardArea=width-84.f;
    const float nav=std::min(430.f,cardArea*.31f), systems=std::min(290.f,cardArea*.22f);
    const float flight=(cardArea-nav-systems)*.48f, scope=cardArea-nav-systems-flight;
    const float x1=24.f, x2=x1+nav+12, x3=x2+flight+12, x4=x3+scope+12;
    for (auto r : {Rect{x1,758,nav,124},Rect{x2,758,flight,124},Rect{x3,758,scope,124},Rect{x4,758,systems,124}}) card(r);
    hud.text("DESTINATION",x1+14,770,nav-28,12,accent);
    hud.text(pilot.targetName(),x1+14,792,nav-28,21,light);
    hud.text(range,x1+14,834,nav-28,13,accent);
    hud.text(region?"Y NEXT SYSTEM":pilot.warpAvailable()?"Y NEXT WORLD / J WARP":"Y NEXT WORLD",
             x1+14,863,nav-28,10,soft);
    hud.text(pilot.warping()?"WARP VELOCITY":"VELOCITY",x2+14,770,flight-28,12,accent);
    hud.text(speed,x2+14,792,flight-28,29,light);
    hud.text((pilot.warping()?"EXIT IN ":"STOP ")+stop,x2+14,834,flight-28,12,accent);
    hud.text(pilot.warping()?"B CANCEL WARP":pilot.assisted()?"ASSIST":"INERTIAL",x2+14,863,flight-28,11,soft);
    hud.text("NAVIGATION SCOPE",x3+14,770,scope-28,12,accent);
    hud.text(bearing.z>0.f?"DESTINATION AFT":"DESTINATION AHEAD",x3+14,790,scope-28,10,accent);
    const float rx=x3+scope*.5f, ry=834.f, radius=std::min(90.f,scope*.38f);
    hud.ellipse(rx,ry,radius,23,soft,.70f);
    hud.ellipse(rx,ry,radius*.5f,11.5f,soft,.36f);
    for (unsigned i=0;i<std::min(count,12u);++i) {
        const auto p=pilot.contactPosition(i);
        const Vec v=unit(Vec{p.x,p.y,p.z});
        const auto axis=[&](Quad a){return dot(v,{a.x,a.y,a.z});};
        hud.diamond(rx+axis(f.shipRight)*radius*.85f,ry-axis(f.shipForward)*20-axis(f.shipUp)*17,2.5f,soft*.55f);
    }
    hud.line(rx-4,ry+4,rx,ry-5,light); hud.line(rx,ry-5,rx+4,ry+4,light);
    hud.line(rx+4,ry+4,rx-4,ry+4,light);
    hud.diamond(rx+bearing.x*radius*.85f,ry+bearing.z*20-bearing.y*17,5,accent);
    const float gauge=std::max(12.f,(systems-42.f)*.5f);
    const float second=x4+28+gauge;
    hud.text("THROTTLE",x4+14,770,gauge,11,accent);
    hud.text("HULL",second,770,gauge,11,accent);
    hud.text(percent(f.controls.w),x4+14,792,gauge,26,light);
    const float hull=float(pilot.missionHull()/100.);
    hud.text(percent(hull),second,792,gauge,24,light);
    bar(hud,x4+14,831,gauge,f.controls.w,accent);
    bar(hud,second,831,gauge,hull,light);
    hud.text(pilot.nearFilm()?"FILM LIMIT":"B BRAKE / F ASSIST",x4+14,863,systems-28,10,soft);

    hud.quad({0,884,width,16},colours.paper);
    hud.text("W / S THROTTLE",26,888,150,9,soft);
    hud.text(region?"Y NEXT SYSTEM / SHIFT LOOK / R LEVEL":"Y NEXT WORLD / SHIFT LOOK / R LEVEL",
             middle-117,888,260,9,soft);
    hud.text("G CHASE VIEW",width-162,888,138,9,soft,true);
    const auto cx=middle, cy=450.f;
    hud.ellipse(cx,cy,6.4f,6.4f,accent,.76f);
    hud.line(cx-18,cy,cx-8,cy,accent,.76f);
    hud.line(cx+8,cy,cx+18,cy,accent,.76f);
    const float cameraDepth=dotBasis(f.forward);
    if (cameraDepth>.01f) {
        const float scale=450.f*1.428148f/cameraDepth;
        const float x=cx+dotBasis(f.right)*scale,y=cy-dotBasis(f.up)*scale;
        const float r=std::clamp(target.w*scale/std::max(1.e-14f,length(difference)),11.f,55.f);
        if (x>125+r&&x<width-125-r&&y>105+r&&y<742-r&&std::hypot(x-cx,y-cy)>20.f) {
            for (const float side : {-1.f,1.f}) {
                hud.line(x+side*r,y-9,x+side*r,y+9,accent,.75f);
                hud.line(x+side*r,y-9,x+side*(r-5),y-9,accent,.75f);
                hud.line(x+side*r,y+9,x+side*(r-5),y+9,accent,.75f);
            }
        }
    }
    return out;
}
} // namespace pelagic
