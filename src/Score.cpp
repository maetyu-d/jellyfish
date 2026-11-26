#include "Score.hpp"
#include "BubbleStrings.hpp"

#include <algorithm>
#include <cmath>
#include <stdexcept>

namespace pelagic {

constexpr std::array<float,4> roots{33,31,30,35};
constexpr float master = .72f;

void Score::start(const char* runtime, const char* definitions) {
    if (!runtime || !definitions) throw std::runtime_error("The embedded SuperCollider resources are missing.");
    engine.reset(scae_create());
    if (!engine) throw std::runtime_error("Could not allocate the embedded SuperCollider engine.");
    scae_config config{};
    config.struct_size = sizeof(config);
    config.abi_version = SCAE_ABI_VERSION;
    config.sample_rate = sampleRate;
    config.maximum_callback_frames = maximumFrames;
    config.runtime_root = runtime;
    config.synthdefs_directory = definitions;
    config.output_latency_seconds = .043;
    config.master_level = master;
    if (scae_start(engine.get(),&config) != SCAE_OK) {
        char diagnostic[1024]{};
        scae_copy_last_error(engine.get(),diagnostic,sizeof(diagnostic));
        stop();
        throw std::runtime_error(diagnostic[0] ? diagnostic : "Could not start embedded SuperCollider.");
    }
    analysis.reset(sampleRate);
    palette = 0;
    waterLevel = .22f;
    charge = 0;
    basin = 0;
    passage = 0;
    scae_set_transport(engine.get(),60.,0,1);
    bed = scae_note(engine.get(),"pelagic_bed",roots[0],.96f,1.f,31.5f,31.5f,nullptr,0);
    if (bed < 0) {
        stop();
        throw std::runtime_error("The ambient SuperCollider SynthDef could not start.");
    }
}

void Score::stop() {
    if (engine) scae_stop(engine.get());
    engine.reset();
    bed = -1;
}

void Score::render(float* left, float* right, unsigned frames) {
    while (frames) {
        const auto block = std::min(frames,maximumFrames);
        scae_render_interleaved(engine.get(),interleaved.data(),block);
        analysis.push(interleaved.data(),interleaved.data()+1,block,2);
        for (unsigned i = 0; i < block; ++i) {
            left[i] = interleaved[2*i];
            right[i] = interleaved[2*i+1];
        }
        left += block;
        right += block;
        frames -= block;
    }
}

void Score::update(unsigned nextPalette, Water water, float nextCharge, float nextBasin, float nextPassage) {
    if (!engine) return;
    scae_maintenance(engine.get());
    nextPalette %= roots.size();
    if (nextPalette != palette) {
        const auto tuned = scae_control_node(engine.get(),bed,"pitch",roots[nextPalette]);
        const auto coloured = scae_control_node(engine.get(),bed,"colour",float(nextPalette)/3.f);
        if (tuned > 0 && coloured > 0) palette = nextPalette;
    }
    const float flow = std::min(1.f,.22f+.69f*water.stream+.22f*water.eddy+.64f*water.wake);
    const float nextWater = water.kind == WaterKind::Still ? .07f : flow;
    if (std::abs(nextWater-waterLevel) > .013f)
        if (scae_control_node(engine.get(),bed,"water",nextWater) > 0) waterLevel = nextWater;
    if (std::abs(nextBasin-basin) > .014f || (nextBasin == 0.f && basin != 0.f))
        if (scae_control_node(engine.get(),bed,"basin",nextBasin) > 0) basin = nextBasin;
    if (std::abs(nextPassage-passage) > .012f || (nextPassage == 0.f && passage != 0.f))
        if (scae_control_node(engine.get(),bed,"passage",nextPassage) > 0) passage = nextPassage;
    if (std::abs(nextCharge-charge) > .028f || (nextCharge == 0.f && charge != 0.f)) {
        if (scae_control_node(engine.get(),bed,"charge",nextCharge) > 0) charge = nextCharge;
    }
}

void Score::pulse(bool held) {
    if (!engine) return;
    const char* instrument = held ? "pelagic_call" : "bell";
    const float pitch = roots[palette]+(held ? 7.f : 24.f);
    scae_note(engine.get(),instrument,pitch,held ? .67f : .48f,held ? 5.f : 2.3f,31.5f,31.5f,nullptr,0);
}

void Score::resonateBell(unsigned contraction) {
    if (!engine) return;
    constexpr std::array<float,3> intervals{-7.f,-5.f,0.f};
    constexpr std::array<float,3> pan{24.f,39.f,31.5f};
    constexpr std::array<float,3> strength{.36f,.39f,.45f};
    const auto i = std::min(contraction,2u);
    scae_note(engine.get(),"pelagic_call",roots[palette]+intervals[i],strength[i],4.7f,pan[i],31.5f,nullptr,0);
}

void Score::play(VoyageCue cue) {
    if (!engine || cue.sound == VoyageSound::None) return;
    if (cue.sound == VoyageSound::OpeningStroke) {
        scae_note(engine.get(),"pelagic_call",29.f,.50f,5.6f,31.5f,31.5f,nullptr,0);
        return;
    }
    constexpr std::array<float,5> melodyRoots{57.f,60.f,62.f,64.f,65.f};
    const float pitch = melodyRoots[cue.system%melodyRoots.size()];
    const scae_parameter tuning[]{{"variant",float(cue.system%2u)}};
    const float gain = cue.sound == VoyageSound::SystemBirth ? .60f : .49f;
    scae_note(engine.get(),"pelagic_signature",pitch,gain,4.3f,31.5f,31.5f,tuning,1);
}

void Score::echo(const Reply& reply, Vec listener, Vec right, Vec forward) {
    if (!engine) return;
    constexpr std::array<float,4> intervals{19.f,26.f,31.f,36.f};
    const Vec offset = reply.position-listener;
    const float distance = std::max(.01f,std::sqrt(offset.x*offset.x+offset.y*offset.y+offset.z*offset.z));
    const float pan = std::clamp((offset.x*right.x+offset.y*right.y+offset.z*right.z)/distance,-1.f,1.f);
    const float front = (offset.x*forward.x+offset.y*forward.y+offset.z*forward.z)/distance;
    const float gain = 1.f/(1.f+distance*(reply.crown ? .031f : .057f));
    const scae_parameter spatial[]{{"distance",distance},{"behind",std::max(0.f,-front)},{"spatialgain",gain}};
    const bool close = reply.crown && reply.sequence == 0;
    const float interval = reply.crown ? (close ? 24.f : 19.f) : intervals[reply.sequence%intervals.size()];
    const char* instrument = reply.crown ? "pelagic_reply" : "bell";
    scae_note(engine.get(),instrument,roots[palette]+interval,reply.crown ? (close ? .34f : .57f) : .30f,
              reply.crown ? (close ? 2.1f : 3.2f) : 1.75f,31.5f+29.f*pan,31.5f,spatial,3);
}

void Score::chime(const BubbleChime& chime,Vec listener,Vec right,Vec forward,float mixLevel) {
    if (!engine) return;
    constexpr std::array<float,regionScales> keys{55.f,57.f,52.f,53.f,50.f,48.f};
    constexpr std::array<float,7> scale{0.f,2.f,3.f,7.f,10.f,12.f,14.f};
    constexpr std::array<float,8> figure{0.f,7.f,12.f,3.f,10.f,14.f,7.f,2.f};
    const Vec offset=chime.position-listener;
    const float distance=std::max(.01f,std::hypot(offset.x,offset.y,offset.z));
    const float pan=(offset.x*right.x+offset.y*right.y+offset.z*right.z)/distance;
    const float front=(offset.x*forward.x+offset.y*forward.y+offset.z*forward.z)/distance;
    const bool melody=chime.sequenceLength!=0, final=melody && chime.step+1==chime.sequenceLength;
    const bool region=chime.bubble.kind==BubbleKind::Region;
    const float root=keys[std::min<std::size_t>(chime.layer,keys.size()-1)];
    const float degree=melody ? (final ? 12.f : figure[chime.step%figure.size()]) :
                                scale[chime.bubble.id%scale.size()]+(region ? -12.f : 5.f);
    const float gain=melody ? .88f/(1.f+.007f*distance) : mixLevel/(1.f+.035f*distance);
    const scae_parameter spatial[]{{"distance",melody ? .20f*distance : distance},
                                   {"behind",std::max(0.f,-front)*(melody ? .28f : 1.f)},{"spatialgain",gain}};
    scae_note(engine.get(),"bell",root+degree,melody ? (final ? .44f : .32f) : .24f,
              melody ? (final ? 2.9f : 1.35f) : (region ? 1.45f : .80f),
              31.5f+(melody ? 19.f : 27.f)*std::clamp(pan,-1.f,1.f),31.5f,spatial,3);
}

void Score::mute(bool muted) {
    if (engine) scae_set_master_level(engine.get(),muted ? 0.f : master);
}

} // namespace pelagic
