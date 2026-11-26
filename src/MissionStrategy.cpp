#include "MissionStrategy.hpp"
#include "MissionRuntime.hpp"

#include "infinity/XalariaStrategy.hpp"
#include "infinity/XalariaStories.hpp"
#include "infinity/XalariaTraffic.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <iterator>
#include <tuple>
#include <utility>

namespace pelagic::missions {
namespace {

using missionui::Input;
using missionui::Page;
using missionui::Snapshot;
using infinity::ActivityBody;
using infinity::ActivityId;
using infinity::ActivityKind;
using infinity::CombatFit;
using infinity::CombatWeapon;
using infinity::FactionCampaign;
using infinity::FleetOrder;
using infinity::FleetShip;
using infinity::Kind;
using infinity::StrategicReport;
using infinity::XalariaStrategy;
using infinity::XPlace;

constexpr std::size_t sheetSize=7;

enum Command {
    ClaimHull, Captain, BuyFreighter, BuyWarship,
    Hold, FollowFlagship, Trade, Escort, Blockade, RecoverSalvage,
    LocalScan, Informant, Pledge, SalvageWreck, RescueCrew, Fees,
    CivilianFit, CorsairFit, GunshipFit, Arm, Pulse, Ion, Torpedo,
    Demand, Seize, Vouchers, Service, Board
};

bool strategyPage(Page page) {
    return page==Page::Fleet||page==Page::Intelligence||page==Page::Campaigns;
}

unsigned nativePage(Page page) {
    return page==Page::Intelligence ? 1 : page==Page::Campaigns ? 2 : 0;
}

void selectPage(XalariaStrategy& strategy,Page page) {
    const auto target=nativePage(page);
    if (strategy.page==target) return;
    strategy.page=target;
    strategy.row=0;
}

std::optional<ActivityId> toNative(const NativeRuntime& runtime,const Actor& actor) {
    const auto star=runtime.catalog->stars.find(actor.frame.system);
    if (star==runtime.catalog->stars.end()) return {};
    if (actor.frame.world&&!star->second.worlds.contains(*actor.frame.world)) return {};
    return runtime.native(actor);
}

std::vector<const StrategicReport*> reports(const XalariaStrategy& strategy) {
    std::vector<const StrategicReport*> earned;
    for (auto it=strategy.reports().rbegin();it!=strategy.reports().rend();++it)
        if (strategy.knowledge().contains(it->system)) earned.push_back(&*it);
    return earned;
}

std::vector<const FactionCampaign*> campaigns(const XalariaStrategy& strategy) {
    std::vector<const FactionCampaign*> found;
    for (const auto& [id,campaign]:strategy.campaigns())
        if (strategy.knowledge().contains(campaign.origin.system)||strategy.knowledge().contains(campaign.target.system))
            found.push_back(&campaign);
    return found;
}

const FleetShip* selectedShip(const XalariaStrategy& strategy) {
    if (strategy.fleet().empty()) return nullptr;
    auto it=strategy.fleet().begin();
    std::advance(it,std::min(strategy.row,strategy.fleet().size()-1));
    return &it->second;
}

std::size_t rowCount(const XalariaStrategy& strategy,Page page) {
    if (page==Page::Fleet) return strategy.fleet().size();
    if (page==Page::Intelligence) return reports(strategy).size();
    return campaigns(strategy).size();
}

std::size_t sheetCount(std::size_t rows) {
    return std::max<std::size_t>(1,(rows+sheetSize-1)/sheetSize);
}

std::size_t changeSheet(std::size_t sheet,std::size_t rows,Input direction) {
    const auto delta=direction==Input::PreviousSheet ? -1 : 1;
    return std::size_t(std::clamp(std::ptrdiff_t(sheet)+delta,std::ptrdiff_t(0),
                                  std::ptrdiff_t(sheetCount(rows)-1)));
}

void paginate(Snapshot& view,std::size_t sheet,std::size_t selected) {
    view.sheetCount=sheetCount(view.rows.size());
    view.sheet=std::min(sheet,view.sheetCount-1);
    const auto first=view.sheet*sheetSize;
    const auto last=std::min(first+sheetSize,view.rows.size());
    std::vector<missionui::Row> slice(std::make_move_iterator(view.rows.begin()+first),
                                       std::make_move_iterator(view.rows.begin()+last));
    view.rows=std::move(slice);
    view.selection=selected>=first&&selected<last ? selected-first : view.rows.size();
}

std::string starName(const NativeRuntime& runtime,std::uint32_t system) {
    const auto it=runtime.catalog->stars.find(system);
    return it==runtime.catalog->stars.end() ? "Unknown System" : it->second.name;
}

std::string seconds(double value) {
    return std::to_string(std::uint64_t(std::max(0.,value)))+" s";
}

std::string percent(double value) {
    return std::to_string(int(std::round(value)))+"%";
}

std::string campaignStatus(const FactionCampaign& item,double time) {
    if (item.finished) return item.victory ? "Surrendered" : "Withdrawn";
    if (time<item.departure) return "Preparing Expedition";
    if (time<item.arrival) return "Expedition Underway";
    return "Blockade Active";
}

void button(Snapshot& view,Command command,const char* title,char key=0,bool enabled=true) {
    view.buttons.push_back({{Input::Auxiliary,command},title,enabled,key});
}

void plotButton(Snapshot& view) {
    view.buttons.push_back({{Input::Route,0},"Plot Destination",true,'\r'});
}

Action plot(std::uint32_t system,std::string label,std::optional<XPlace> place={}) {
    Action result;
    result.kind=ActionKind::Plot;
    result.point.frame.system=system;
    result.point.label=std::move(label);
    if (place) {
        result.point.frame.world=place->world;
        result.point.place=Place{place->system,place->world,place->station,place->city};
    }
    return result;
}

struct CombatContact {
    ActivityBody body;
    double range{};
};

std::vector<CombatContact> contacts(const NativeRuntime& runtime,bool visibleOnly) {
    const auto player=runtime.combatPlayer();
    if (player.frame.kind()<Kind::System||player.transit) return {};
    const auto units=std::pow(10.,runtime.universe.describe(player.frame).frame.logRadius);
    std::vector<CombatContact> result;
    for (auto body:runtime.combat.localBodies(player)) {
        if (!infinity::isXalariaTraffic(body.id)||(visibleOnly&&body.disabled)) continue;
        const auto eye=runtime.universe.pointRelative(player.frame,player.position/units,body.id.home,0.);
        const auto offset=body.position-eye;
        const auto range=glm::length(offset);
        if (range>100000.) continue;
        if (visibleOnly) {
            const auto forward=runtime.universe.relative(player.frame,body.id.home,0.).orientation*player.forward;
            if (glm::dot(forward,offset)<range*.45) continue;
        }
        result.push_back({std::move(body),range});
    }
    std::stable_sort(result.begin(),result.end(),[](const auto& a,const auto& b) {
        return std::tuple(!a.body.hostile,a.body.id)<std::tuple(!b.body.hostile,b.body.id);
    });
    return result;
}

} // namespace

Snapshot MissionStrategy::snapshot(Page page,std::optional<std::uint32_t> plottedSystem) {
    auto& combat=runtime_.combat;
    auto& strategy=combat.strategy();
    const auto& economy=runtime_.economy;
    const auto active=runtime_.location().active;
    const auto docked=active && economy.dockedPlace().has_value();
    Snapshot view;
    view.page=page;
    view.location=starName(runtime_,economy.currentSystem());
    if (page==Page::Combat) {
        constexpr std::array weapons{"Pulse","Ion","Torpedo"};
        view.title="Armament";
        view.subtitle=std::string(infinity::combatFitName(combat.fit()))+"  /  Hull "+percent(combat.playerHull())+
            "  /  "+(combat.armed ? "Armed" : "Safe")+" · "+weapons[unsigned(combat.weapon)]+"  /  Heat "+
            percent(combat.heat())+"  /  "+std::to_string(combat.torpedoes())+" Torpedoes";
        const auto ship=combat.selected();
        if (ship) {
            view.body=ship->body.name+"\n"+ship->body.status+"\nHull "+percent(ship->body.hull)+
                "  /  Shield "+percent(ship->shield.fraction*100.);
        } else {
            view.body="Select a contact to request boarding or negotiate for its cargo.";
        }
        view.body+="\n\nWallet "+infinity::xMoney(economy.credits())+"  /  Warrant "+
            infinity::xMoney(combat.localWarrant())+"  /  Patrol Vouchers "+infinity::xMoney(combat.bountyDue());
        view.message=combat.message;
        view.empty="There are no nearby ships in sensor range.";
        const auto roster=contacts(runtime_,false);
        auto selectedRow=roster.size();
        for (const auto& item:roster) {
            if (combat.target==item.body.id) selectedRow=view.rows.size();
            view.rows.push_back({item.body.name,std::to_string(std::uint64_t(item.range))+" m",item.body.status});
        }
        paginate(view,combatSheet_,selectedRow);
        combatSheet_=view.sheet;
        button(view,CivilianFit,"Civilian · 1,000 GC",0,docked&&combat.fit()!=CombatFit::Civilian);
        button(view,CorsairFit,"Corsair · 3,500 GC",0,docked&&combat.fit()!=CombatFit::Corsair);
        button(view,GunshipFit,"Gunship · 9,000 GC",0,docked&&combat.fit()!=CombatFit::Gunship);
        button(view,Arm,combat.armed ? "Safe Weapons" : "Arm Weapons",'m',active);
        button(view,Pulse,"Pulse",'1',active);
        button(view,Ion,"Ion",'2',active&&combat.fit()!=CombatFit::Civilian);
        button(view,Torpedo,"Torpedo",'3',active&&combat.torpedoes()>0);
        const bool selected=active&&ship.has_value();
        button(view,Demand,"Demand Cargo",0,selected&&combat.armed);
        button(view,Seize,"Seize Boarded Cargo",0,selected&&runtime_.storyContext().boardedVessel.has_value());
        button(view,Vouchers,combat.localWarrant() ? "Settle Warrant" : "Redeem Patrol Vouchers",0,
               active&&(combat.localWarrant()||combat.bountyDue()));
        button(view,Service,combat.playerHull()<=0 ? "Emergency Recovery" : "Repair and Reload",0,
               docked||(active&&combat.playerHull()<=0));
        button(view,Board,"Request Boarding",0,selected);
        return view;
    }

    if (!strategyPage(page)) return view;
    selectPage(strategy,page);
    const auto allegiance=std::string(infinity::xFactionName(strategy.allegiance()));
    view.subtitle="Treasury "+infinity::xMoney(economy.credits())+"  /  Allegiance "+allegiance+
        "  /  Rescued Captains "+std::to_string(strategy.recruits().size());
    view.message=strategy.message;
    if (page==Page::Fleet) {
        view.title="Your Fleet";
        view.empty="Claim a surrendered hull after boarding, or buy a ship at a friendly shipyard.";
        for (const auto& [id,ship]:strategy.fleet()) {
            const auto state=ship.lost ? "Lost" : ship.captain.empty() ? "Captain Required" : ship.captain;
            view.rows.push_back({ship.name,state,std::string(infinity::fleetOrderName(ship.order))});
        }
        const auto* ship=selectedShip(strategy);
        if (ship) {
            view.body=ship->name+"\nHull "+percent(ship->hull)+"  /  Drives "+percent(ship->engines)+
                "  /  Loyalty "+std::to_string(ship->loyalty)+"  /  Missions "+std::to_string(ship->missions);
            view.body+="\nDestination · "+economy.placeName(ship->destination);
            view.body+=ship->underway ? " · ETA "+seconds(ship->arrival-strategy.time()) : " · Holding";
            for (std::size_t i=0;i<ship->cargo.size();++i) {
                if (ship->cargo[i]<=0) continue;
                view.body+="\n"+std::to_string(ship->cargo[i])+" "+std::string(infinity::xGoodInfo(infinity::XGood(i)).name);
            }
            if (ship->contraband) view.body+="\nContraband aboard";
        }
        view.body+="\n\nFleet Order Destination · "+(plottedSystem ? starName(runtime_,*plottedSystem) : "Choose a System in the Atlas");
        const auto context=runtime_.storyContext();
        button(view,ClaimHull,"Claim Boarded Hull",'c',context.boardedVessel.has_value());
        button(view,Captain,"Commission Captain / Repair",'h',active&&ship&&!ship->lost);
        button(view,BuyFreighter,"Buy Freighter",'b',docked);
        button(view,BuyWarship,"Buy Warship",'w',docked);
        const bool canOrder=active&&ship&&!ship->lost&&!ship->captain.empty();
        constexpr std::array labels{"Hold","Follow Flagship","Trade Route","Escort Route","Blockade","Recover Salvage"};
        for (unsigned i=0;i<labels.size();++i)
            button(view,Command(Hold+i),labels[i],char('0'+i),canOrder&&(!i||plottedSystem.has_value()));
    } else if (page==Page::Intelligence) {
        view.title="Earned Intelligence";
        view.empty="Dock, talk to a crew or scan local traffic to earn intelligence.";
        const auto earned=reports(strategy);
        for (const auto* report:earned)
            view.rows.push_back({report->text,starName(runtime_,report->system),seconds(report->seconds)});
        if (!earned.empty()) {
            const auto& item=*earned[std::min(strategy.row,earned.size()-1)];
            view.body=starName(runtime_,item.system)+"\n"+item.text;
            plotButton(view);
        }
    } else {
        view.title="Discovered Campaigns";
        view.empty="There are no discovered campaigns.";
        const auto found=campaigns(strategy);
        for (const auto* item:found)
            view.rows.push_back({economy.placeName(item->target),std::string(infinity::xFactionName(item->attacker)),
                                 campaignStatus(*item,strategy.time())});
        if (!found.empty()) {
            const auto& item=*found[std::min(strategy.row,found.size()-1)];
            view.body=economy.placeName(item.target)+"\n"+campaignStatus(item,strategy.time())+"  /  "+
                std::string(infinity::xFactionName(item.attacker))+" expedition";
            if (!item.finished&&strategy.time()<item.arrival) view.body+="\nETA "+seconds(item.arrival-strategy.time());
            if (const auto advisory=strategy.advisory(item.target);!advisory.empty()) view.body+="\n"+advisory;
            plotButton(view);
        }
    }
    strategy.row=view.rows.empty() ? 0 : std::min(strategy.row,view.rows.size()-1);
    paginate(view,strategy.row/sheetSize,strategy.row);
    button(view,LocalScan,"Scan Local Activity",'n',active);
    button(view,Informant,"Informant · 200 GC",'i',docked);
    button(view,Pledge,"Pledge Allegiance",'a',docked);
    button(view,SalvageWreck,"Salvage Wreck",'s',active&&combat.target.has_value());
    button(view,RescueCrew,"Rescue Crew",'r',active&&combat.target.has_value());
    button(view,Fees,"Collect Station Fees",'t',docked);
    return view;
}

Action MissionStrategy::dispatch(Page page,missionui::Action input,std::optional<std::uint32_t> plottedSystem) {
    auto& combat=runtime_.combat;
    auto& strategy=combat.strategy();
    if (page==Page::Combat) {
        if ((input.kind==Input::SelectRow&&input.value>=0&&std::size_t(input.value)<sheetSize)||
            input.kind==Input::PreviousSheet||input.kind==Input::NextSheet) {
            const auto roster=contacts(runtime_,false);
            if (input.kind==Input::PreviousSheet||input.kind==Input::NextSheet) {
                combatSheet_=changeSheet(combatSheet_,roster.size(),input.kind);
            } else {
                const auto row=combatSheet_*sheetSize+std::size_t(input.value);
                if (row<roster.size()) combat.target=roster[row].body.id;
            }
            return {};
        }
        if (input.kind!=Input::Auxiliary||!runtime_.location().active) return {};
        switch (input.value) {
            case CivilianFit: case CorsairFit: case GunshipFit:
                combat.refit(CombatFit(input.value-CivilianFit)); break;
            case Arm: toggleArmed(); break;
            case Pulse: case Ion: case Torpedo: selectWeapon(unsigned(input.value-Pulse)); break;
            case Demand:
                if (combat.target) combat.demand(*combat.target,runtime_.combatPlayer());
                break;
            case Seize:
                if (combat.target) combat.seize(*combat.target,runtime_.storyContext());
                break;
            case Vouchers: combat.claimBounty(); break;
            case Service:
                if (combat.playerHull()>0) combat.service();
                else if (combat.recover(runtime_.nav)) return runtime_.currentPoseAction();
                break;
            case Board:
                if (const auto actor=target()) {
                    auto approach=runtime_.vesselAction(*actor);
                    if (approach.kind!=ActionKind::None) return approach;
                    combat.message="This contact has no available boarding collar.";
                }
                break;
            default: break;
        }
        return {};
    }

    if (!strategyPage(page)) return {};
    selectPage(strategy,page);
    if (input.kind==Input::SelectRow&&input.value>=0&&std::size_t(input.value)<sheetSize) {
        const auto row=(strategy.row/sheetSize)*sheetSize+std::size_t(input.value);
        if (row<rowCount(strategy,page)) strategy.row=row;
        return {};
    }
    if (input.kind==Input::PreviousSheet||input.kind==Input::NextSheet) {
        strategy.row=changeSheet(strategy.row/sheetSize,rowCount(strategy,page),input.kind)*sheetSize;
        return {};
    }
    if (input.kind==Input::Route) {
        if (page==Page::Intelligence) {
            const auto earned=reports(strategy);
            if (!earned.empty()) {
                const auto* item=earned[std::min(strategy.row,earned.size()-1)];
                return plot(item->system,starName(runtime_,item->system));
            }
        } else if (page==Page::Campaigns) {
            const auto found=campaigns(strategy);
            if (!found.empty()) {
                const auto& place=found[std::min(strategy.row,found.size()-1)]->target;
                return plot(place.system,runtime_.economy.placeName(place),place);
            }
        }
        return {};
    }
    if (input.kind==Input::Scan) {
        localScan();
        return {};
    }
    if (input.kind!=Input::Auxiliary||!runtime_.location().active) return {};
    const auto* ship=selectedShip(strategy);
    switch (input.value) {
        case ClaimHull:
            if (strategy.capture(runtime_.storyContext())) strategy.row=strategy.fleet().size()-1;
            break;
        case Captain:
            if (ship) strategy.hire(ship->id,runtime_.storyContext());
            break;
        case BuyFreighter: case BuyWarship:
            if (strategy.purchase(input.value==BuyFreighter ? ActivityKind::Freighter : ActivityKind::Patrol))
                strategy.row=strategy.fleet().size()-1;
            break;
        case Hold: case FollowFlagship: case Trade: case Escort: case Blockade: case RecoverSalvage:
            if (ship&&(input.value==Hold||plottedSystem))
                strategy.order(ship->id,FleetOrder(input.value-Hold),plottedSystem.value_or(runtime_.economy.currentSystem()));
            break;
        case LocalScan: localScan(); break;
        case Informant: strategy.informer(); break;
        case Pledge: strategy.pledge(); break;
        case SalvageWreck: case RescueCrew:
            if (combat.target) strategy.salvage(*combat.target,runtime_.combatPlayer(),input.value==RescueCrew);
            break;
        case Fees: strategy.collectTaxes(); break;
        default: break;
    }
    return {};
}

std::optional<Actor> MissionStrategy::target() const {
    if (!runtime_.combat.target) return {};
    return runtime_.actor(*runtime_.combat.target);
}

std::optional<Actor> MissionStrategy::cycleTarget() {
    auto& target=runtime_.combat.target;
    const auto roster=contacts(runtime_,true);
    if (roster.empty()) {
        target.reset();
        return {};
    }
    const auto selected=std::find_if(roster.begin(),roster.end(),[&](const auto& item){return target==item.body.id;});
    const auto next=selected==roster.end()||std::next(selected)==roster.end() ? roster.begin() : std::next(selected);
    target=next->body.id;
    return runtime_.actor(*target);
}

void MissionStrategy::selectTarget(std::optional<Actor> actor) {
    runtime_.combat.target=actor ? toNative(runtime_,*actor) : std::nullopt;
}

void MissionStrategy::toggleArmed() {
    runtime_.combat.armed=!runtime_.combat.armed;
}

void MissionStrategy::selectWeapon(unsigned weapon) {
    if (weapon<=unsigned(CombatWeapon::Torpedo)) runtime_.combat.weapon=CombatWeapon(weapon);
}

bool MissionStrategy::fire() {
    return runtime_.fire();
}

bool MissionStrategy::underAttack() const {
    return runtime_.status().underAttack;
}

bool MissionStrategy::localScan() {
    const auto player=runtime_.combatPlayer();
    return player.frame.kind()>=Kind::System&&!player.transit&&runtime_.combat.strategy().scan(player);
}

bool MissionStrategy::heard(const Actor& actor) {
    if (!runtime_.location().active||actor.frame.system!=runtime_.location().frame.system) return false;
    const auto id=toNative(runtime_,actor);
    const auto player=runtime_.combatPlayer();
    if (!id) return false;
    const auto contact=infinity::xalariaTrafficContact(runtime_.economy,*id,player.gate,player.seconds);
    if (!contact) return false;
    const auto units=std::pow(10.,runtime_.universe.describe(player.frame).frame.logRadius);
    const auto eye=runtime_.universe.pointRelative(player.frame,player.position/units,id->home,0.);
    return glm::distance(eye,contact->body.position)<=100000.&&
        runtime_.combat.strategy().discover(contact->port.system,"hailed crew and flight plan");
}

} // namespace pelagic::missions
