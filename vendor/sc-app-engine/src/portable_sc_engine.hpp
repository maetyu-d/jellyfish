#pragma once

#include <SC_WorldOptions.h>

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdint>
#include <cstring>
#include <deque>
#include <map>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <unordered_map>
#include <unordered_set>
#include <vector>

namespace scapp {

struct AudioFrame final {
    float left = 0.0f;
    float right = 0.0f;
};

struct Position2 final {
    float x = 31.5f;
    float y = 31.5f;
};

using Parameters = std::vector<std::pair<std::string, float>>;

static_assert(sizeof(AudioFrame) == sizeof(float) * 2,
              "The public C ABI requires tightly packed interleaved stereo frames");

static_assert(std::atomic<std::size_t>::is_always_lock_free,
              "The realtime packet queue requires lock-free native indices");
static_assert(std::atomic<std::uint32_t>::is_always_lock_free,
              "The callback lifetime gate requires lock-free native counters");
static_assert(std::atomic<float>::is_always_lock_free,
              "The realtime meter and gain controls require lock-free floats");

class EmbeddedScEngine final {
public:
    static constexpr int host_render_quantum = 64;

    EmbeddedScEngine();
    ~EmbeddedScEngine();

    bool prepare(double sample_rate,
                 int maximum_block_size,
                 const std::string &runtime_root,
                 const std::string &synth_library_path);
    void release() noexcept;
    int mix(AudioFrame *output, int frames);

    std::int32_t note(const std::string &instrument,
                      float pitch,
                      float velocity,
                      float duration_beats,
                      const Position2 &position,
                      const Parameters &parameters);
    std::int32_t trigger(const std::string &name, const Position2 &position);
    std::int32_t control(const std::string &target, const std::string &parameter, float value);
    std::int32_t control_node(std::int32_t node_id, const std::string &parameter, float value);
    std::int32_t start_vst_host(const std::string &synthdef, const std::string &plugin_path);
    bool vst_midi(std::int32_t node_id, int status, int data1, int data2, float detune = 0.0f);
    bool vst_all_notes_off(std::int32_t node_id);
    void panic();
    void set_transport(double bpm, std::uint64_t tick, bool playing);
    void set_master_level(float level);
    bool load_synthdef(const std::string &name, const std::string &source);
    bool load_synthdefs_file(const std::string &path);
    bool prime_audio();
    void configure_render_ahead(double output_latency_seconds);
    void maintenance();

    bool is_ready() const noexcept { return ready_.load(std::memory_order_acquire); }
    std::string status() const;
    std::string last_error() const;
    float meter_left() const noexcept { return meter_left_.load(std::memory_order_relaxed); }
    float meter_right() const noexcept { return meter_right_.load(std::memory_order_relaxed); }
    int active_voice_count() const noexcept { return active_voices_.load(std::memory_order_relaxed); }
    std::uint64_t rendered_frames() const noexcept { return rendered_frames_.load(std::memory_order_relaxed); }
    int synthdef_count() const noexcept { return synthdef_count_.load(std::memory_order_relaxed); }
    std::uint64_t queue_depth() const noexcept { return queue_depth_.load(std::memory_order_relaxed); }
    std::uint64_t queue_peak() const noexcept { return queue_peak_.load(std::memory_order_relaxed); }
    std::uint64_t dropped_packets() const noexcept { return dropped_packets_.load(std::memory_order_relaxed); }
    std::uint64_t render_failures() const noexcept { return render_failures_.load(std::memory_order_relaxed); }
    std::uint64_t invalid_parameters() const noexcept { return invalid_parameters_.load(std::memory_order_relaxed); }
    std::uint64_t invalid_instruments() const noexcept { return invalid_instruments_.load(std::memory_order_relaxed); }
    std::uint64_t node_end_notifications() const noexcept { return node_end_notifications_.load(std::memory_order_relaxed); }
    std::uint64_t dropped_node_notifications() const noexcept { return dropped_node_notifications_.load(std::memory_order_relaxed); }
    std::uint64_t audio_callbacks() const noexcept { return audio_callbacks_.load(std::memory_order_relaxed); }
    std::uint64_t render_deadline_misses() const noexcept { return render_deadline_misses_.load(std::memory_order_relaxed); }
    std::uint64_t max_render_time_usec() const noexcept { return max_render_time_usec_.load(std::memory_order_relaxed); }
    std::uint64_t audio_buffer_underruns() const noexcept { return audio_buffer_underruns_.load(std::memory_order_relaxed); }
    std::uint64_t render_worker_overruns() const noexcept { return render_worker_overruns_.load(std::memory_order_relaxed); }
    std::uint64_t max_worker_render_time_usec() const noexcept { return max_worker_render_time_usec_.load(std::memory_order_relaxed); }
    std::uint64_t render_ahead_frames() const noexcept { return audio_ring_.size(); }
    std::uint64_t render_ahead_target_frames() const noexcept {
        const auto override_frames = render_ahead_override_frames_.load(std::memory_order_relaxed);
        const auto configured = override_frames > 0
            ? override_frames : render_ahead_target_frames_.load(std::memory_order_relaxed);
        return std::max<std::size_t>(configured,
            maximum_callback_frames_.load(std::memory_order_relaxed) * 2);
    }
    std::uint64_t maximum_callback_frames() const noexcept { return maximum_callback_frames_.load(std::memory_order_relaxed); }
    bool render_worker_realtime() const noexcept { return render_worker_realtime_.load(std::memory_order_relaxed); }
    std::int32_t vst_host_node() const noexcept { return vst_host_node_.load(std::memory_order_relaxed); }
    bool vst_ready() const noexcept { return vst_ready_.load(std::memory_order_acquire); }
    int vst_open_state() const noexcept { return vst_open_state_.load(std::memory_order_acquire); }
    std::uint64_t vst_open_failures() const noexcept { return vst_open_failures_.load(std::memory_order_relaxed); }
    double sample_rate() const noexcept { return sample_rate_; }
    std::string last_started_instrument() const;

private:
    static constexpr std::size_t maximum_queued_packets = 4096;
    static constexpr std::size_t maximum_realtime_packet_bytes = 4096;
    static constexpr std::size_t maximum_node_notifications = 4096;
    static constexpr std::size_t maximum_render_ahead_frames = 16384;
    static constexpr int render_worker_block_frames = 512;
    static constexpr std::size_t startup_render_ahead_frames = 8192;

    template <typename T, std::size_t Capacity>
    class SpscRing final {
    public:
        bool try_push(const T &value) noexcept {
            const auto write = write_index_.load(std::memory_order_relaxed);
            const auto next = increment(write);
            if (next == read_index_.load(std::memory_order_acquire)) return false;
            slots_[write] = value;
            write_index_.store(next, std::memory_order_release);
            return true;
        }

        bool try_pop(T &value) noexcept {
            const auto read = read_index_.load(std::memory_order_relaxed);
            if (read == write_index_.load(std::memory_order_acquire)) return false;
            value = slots_[read];
            read_index_.store(increment(read), std::memory_order_release);
            return true;
        }

        std::size_t size() const noexcept {
            const auto write = write_index_.load(std::memory_order_acquire);
            const auto read = read_index_.load(std::memory_order_acquire);
            return write >= read ? write - read : slot_count - (read - write);
        }

        std::size_t available() const noexcept { return Capacity - size(); }

        void consumer_discard_all() noexcept {
            read_index_.store(write_index_.load(std::memory_order_acquire), std::memory_order_release);
        }

        void reset_quiescent() noexcept {
            read_index_.store(0, std::memory_order_relaxed);
            write_index_.store(0, std::memory_order_relaxed);
        }

    private:
        static constexpr std::size_t slot_count = Capacity + 1;
        static constexpr std::size_t increment(std::size_t index) noexcept {
            return index + 1 == slot_count ? 0 : index + 1;
        }

        std::array<T, slot_count> slots_ {};
        alignas(64) std::atomic<std::size_t> write_index_ { 0 };
        alignas(64) std::atomic<std::size_t> read_index_ { 0 };
    };

    struct RealtimePacket final {
        std::uint32_t size = 0;
        std::array<char, maximum_realtime_packet_bytes> bytes {};
    };

    class RealtimePacketQueue final {
    public:
        bool try_push(const std::vector<char> &packet) noexcept {
            if (packet.empty() || packet.size() > maximum_realtime_packet_bytes) return false;
            const auto write = write_index_.load(std::memory_order_relaxed);
            const auto next = increment(write);
            if (next == read_index_.load(std::memory_order_acquire)) return false;
            auto &slot = slots_[write];
            slot.size = static_cast<std::uint32_t>(packet.size());
            std::memcpy(slot.bytes.data(), packet.data(), packet.size());
            write_index_.store(next, std::memory_order_release);
            return true;
        }

        bool try_pop(RealtimePacket &packet) noexcept {
            const auto read = read_index_.load(std::memory_order_relaxed);
            if (read == write_index_.load(std::memory_order_acquire)) return false;
            const auto &slot = slots_[read];
            packet.size = slot.size;
            std::memcpy(packet.bytes.data(), slot.bytes.data(), slot.size);
            read_index_.store(increment(read), std::memory_order_release);
            return true;
        }

        std::size_t size() const noexcept {
            const auto write = write_index_.load(std::memory_order_acquire);
            const auto read = read_index_.load(std::memory_order_acquire);
            return write >= read ? write - read : slot_count - (read - write);
        }

        std::size_t available() const noexcept { return maximum_queued_packets - size(); }

        void consumer_discard_all() noexcept {
            read_index_.store(write_index_.load(std::memory_order_acquire), std::memory_order_release);
        }

        void reset_quiescent() noexcept {
            read_index_.store(0, std::memory_order_relaxed);
            write_index_.store(0, std::memory_order_relaxed);
        }

    private:
        static constexpr std::size_t slot_count = maximum_queued_packets + 1;
        static constexpr std::size_t increment(std::size_t index) noexcept {
            return index + 1 == slot_count ? 0 : index + 1;
        }

        std::array<RealtimePacket, slot_count> slots_ {};
        alignas(64) std::atomic<std::size_t> write_index_ { 0 };
        alignas(64) std::atomic<std::size_t> read_index_ { 0 };
    };

    struct OscArgument;

    using WorldNewFn = World *(*)(WorldOptions *);
    using WorldCleanupFn = void (*)(World *, bool);
    using WorldSendPacketFn = bool (*)(World *, int, char *, ReplyFunc);
    using WorldRenderHostAudioFn = bool (*)(World *, const float *, float *, int, int, int);
    using CompileSynthDefFn = bool (*)(const char *, const char *, const char *, char *, int);
    using InitialiseLangFn = bool (*)(const char *, char *, int);
    using ShutdownLangFn = void (*)();

    static std::vector<char> osc_message(const std::string &address,
                                         const std::vector<OscArgument> &arguments);
    static std::vector<std::pair<std::string, std::string>> extract_synthdefs(const std::string &source);
    std::string normalise_instrument(const std::string &name) const;
    static float default_level(const std::string &instrument);
    static float pan_for_x(float x);

    bool load_api(const std::string &runtime_root);
    void release_unlocked() noexcept;
    bool load_synthdefs_file_unlocked(const std::string &path, bool replace_count);
    bool compile_and_send(const std::string &name, const std::string &source);
    bool compile_synthdef(const std::string &name, const std::string &source, std::vector<char> &bytes);
    bool queue_packet(std::vector<char> packet);
    bool queue_packets(std::vector<std::vector<char>> packets);
    void flush_packets();
    bool send_packet(std::vector<char> packet);
    bool send_realtime_packet(RealtimePacket &packet);
    void drain_node_notifications();
    void publish_ready_synthdefs();
    bool wait_for_synthdefs(const std::vector<std::string> &names, std::chrono::milliseconds timeout);
    void register_pending_synthdefs(const std::vector<std::string> &names, std::int32_t sync_id);
    std::int32_t send_synthdef_sync();
    static void reply_callback(ReplyAddress *address, char *data, int size);
    int render_interleaved(float *output, int frames);
    bool render_output_block(AudioFrame *output, int frames);
    void start_render_worker();
    void stop_render_worker() noexcept;
    void render_worker_loop();
    void prefill_render_ahead(double seconds);
    void clear_output(AudioFrame *output, int frames) const;
    std::int32_t next_node_id();

    mutable std::mutex lifecycle_mutex_;
    mutable std::mutex queue_producer_mutex_;
    mutable std::mutex voice_mutex_;
    mutable std::mutex compile_mutex_;
    mutable std::mutex synthdef_mutex_;
    RealtimePacketQueue packet_queue_;
    RealtimePacket packet_scratch_;
    RealtimePacket panic_packet_;
    SpscRing<std::int32_t, maximum_node_notifications> ended_node_queue_;
    SpscRing<AudioFrame, maximum_render_ahead_frames> audio_ring_;
    std::map<std::string, std::int32_t> active_nodes_;
    std::deque<std::int32_t> voice_nodes_;
    std::unordered_map<std::string, float> instrument_levels_;
    std::unordered_set<std::string> loaded_synthdefs_;
    std::unordered_map<std::string, std::int32_t> pending_synthdefs_;
    std::string last_started_instrument_;

    std::string runtime_root_;
    std::string plugin_path_;
    std::string error_;
    std::vector<float> render_buffer_;
    std::vector<float> mix_buffer_;
    std::vector<float> pending_output_;
    int pending_read_frame_ = 0;
    int pending_frames_ = 0;
    int maximum_block_size_ = 8192;
    double sample_rate_ = 0.0;
    float limiter_gain_ = 0.85f;

    std::atomic<bool> ready_ { false };
    std::atomic<double> bpm_ { 120.0 };
    std::atomic<std::uint64_t> tick_ { 0 };
    std::atomic<bool> playing_ { false };
    std::atomic<float> master_level_ { 0.85f };
    std::atomic<float> meter_left_ { 0.0f };
    std::atomic<float> meter_right_ { 0.0f };
    std::atomic<int> active_voices_ { 0 };
    std::atomic<std::uint64_t> rendered_frames_ { 0 };
    std::atomic<int> synthdef_count_ { 0 };
    std::atomic<std::uint64_t> queue_depth_ { 0 };
    std::atomic<std::uint64_t> queue_peak_ { 0 };
    std::atomic<std::uint64_t> dropped_packets_ { 0 };
    std::atomic<std::uint64_t> render_failures_ { 0 };
    std::atomic<std::uint64_t> invalid_parameters_ { 0 };
    std::atomic<std::uint64_t> invalid_instruments_ { 0 };
    std::atomic<std::uint64_t> node_end_notifications_ { 0 };
    std::atomic<std::uint64_t> dropped_node_notifications_ { 0 };
    std::atomic<std::uint64_t> audio_callbacks_ { 0 };
    std::atomic<std::uint64_t> render_deadline_misses_ { 0 };
    std::atomic<std::uint64_t> max_render_time_usec_ { 0 };
    std::atomic<std::uint64_t> audio_buffer_underruns_ { 0 };
    std::atomic<std::uint64_t> render_worker_overruns_ { 0 };
    std::atomic<std::uint64_t> max_worker_render_time_usec_ { 0 };
    std::atomic<std::size_t> render_ahead_target_frames_ { 1024 };
    std::atomic<std::size_t> render_ahead_override_frames_ { 0 };
    std::atomic<std::size_t> maximum_callback_frames_ { 0 };
    std::atomic<bool> render_worker_running_ { false };
    std::atomic<bool> render_worker_realtime_ { false };
    std::atomic<bool> startup_prefill_active_ { false };
    std::atomic<int> transition_protection_blocks_ { 0 };
    std::atomic<std::int32_t> vst_host_node_ { -1 };
    std::atomic<bool> vst_ready_ { false };
    // 0=idle, 1=opening, 2=ready, 3=failed. Kept numeric in the callback so
    // VST replies require no allocation or lock acquisition.
    std::atomic<int> vst_open_state_ { 0 };
    std::atomic<std::uint64_t> vst_open_failures_ { 0 };
    std::atomic<std::int32_t> node_counter_ { 10000 };
    std::atomic<std::int32_t> sync_counter_ { 1 };
    std::atomic<std::int32_t> completed_sync_id_ { 0 };
    std::atomic<std::uint32_t> callbacks_in_flight_ { 0 };
    std::atomic<bool> panic_requested_ { false };
    std::atomic_flag render_in_progress_ = ATOMIC_FLAG_INIT;
    std::thread render_worker_;

    WorldOptions world_options_ {};
    World *world_ = nullptr;
    void *server_library_ = nullptr;
    void *language_library_ = nullptr;
    WorldNewFn world_new_ = nullptr;
    WorldCleanupFn world_cleanup_ = nullptr;
    WorldSendPacketFn world_send_packet_ = nullptr;
    WorldRenderHostAudioFn world_render_host_audio_ = nullptr;
    CompileSynthDefFn compile_synthdef_fn_ = nullptr;
    InitialiseLangFn initialise_language_ = nullptr;
    ShutdownLangFn shutdown_language_ = nullptr;
};

} // namespace scapp
