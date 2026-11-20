#include "portable_sc_engine.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <dlfcn.h>
#include <fstream>
#include <iterator>
#include <limits>
#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_time.h>
#include <mach/thread_policy.h>
#include <pthread.h>
#include <signal.h>
#endif
#include <sstream>
#include <unistd.h>

namespace scapp {
namespace {
constexpr std::int32_t source_group_id = 1;
// Recorded by VSTPlugin's SynthDef metadata for
// music1-3.scd. The reverb graph is topologically sorted,
// so its VST unit is index 92 rather than its lexical position in the source.
constexpr std::int32_t vst_unit_index = 92;
constexpr int output_channels = 2;
constexpr float output_limit = 0.92f;
constexpr float limiter_ceiling = 0.86f;
constexpr int maximum_voices = 64;
constexpr std::size_t maximum_packets_per_callback = 256;
constexpr std::size_t maximum_parameter_name_length = 64;
constexpr double vst_open_render_ahead_seconds = 0.140;
constexpr double music_transition_render_ahead_seconds = 0.100;
constexpr int music_transition_protection_blocks = 96;

std::atomic<EmbeddedScEngine *> reply_engine { nullptr };

std::size_t padded_string_size(const char *data, int size) {
    if (data == nullptr || size <= 0) return 0;
    const auto length = strnlen(data, static_cast<std::size_t>(size));
    if (length == static_cast<std::size_t>(size)) return 0;
    return (length + 4) & ~std::size_t(3);
}

std::int32_t read_int32_be(const char *data) {
    return static_cast<std::int32_t>((static_cast<std::uint32_t>(static_cast<unsigned char>(data[0])) << 24)
        | (static_cast<std::uint32_t>(static_cast<unsigned char>(data[1])) << 16)
        | (static_cast<std::uint32_t>(static_cast<unsigned char>(data[2])) << 8)
        | static_cast<std::uint32_t>(static_cast<unsigned char>(data[3])));
}

float read_float32_be(const char *data) {
    const auto bits = static_cast<std::uint32_t>(read_int32_be(data));
    float value = 0.0f;
    std::memcpy(&value, &bits, sizeof(value));
    return value;
}

bool valid_control_name(const std::string &name) {
    if (name.empty() || name.size() > maximum_parameter_name_length
        || !(std::isalpha(static_cast<unsigned char>(name.front())) || name.front() == '_')) return false;
    return std::all_of(name.begin() + 1, name.end(), [](unsigned char value) {
        return std::isalnum(value) || value == '_';
    });
}

float finite_or(float value, float fallback, std::atomic<std::uint64_t> &counter) {
    if (std::isfinite(value)) return value;
    counter.fetch_add(1, std::memory_order_relaxed);
    return fallback;
}

#if defined(__APPLE__)
bool signal_vst_hosts(const std::string &expected_host_path, int signal_number) {
    std::array<pid_t, 32> child_pids {};
    const auto bytes = proc_listchildpids(
        getpid(), child_pids.data(), static_cast<int>(sizeof(child_pids)));
    if (bytes <= 0) return false;
    const auto count = std::min<std::size_t>(
        static_cast<std::size_t>(bytes) / sizeof(pid_t), child_pids.size());
    bool signalled = false;
    for (std::size_t index = 0; index < count; ++index) {
        std::array<char, PROC_PIDPATHINFO_MAXSIZE> child_path {};
        if (proc_pidpath(child_pids[index], child_path.data(),
                         static_cast<uint32_t>(child_path.size())) <= 0) continue;
        if (expected_host_path == child_path.data()
            && kill(child_pids[index], signal_number) == 0) signalled = true;
    }
    return signalled;
}
#endif

void append_padded_string(std::vector<char> &packet, const std::string &value) {
    packet.insert(packet.end(), value.begin(), value.end());
    packet.push_back('\0');
    while ((packet.size() % 4) != 0) {
        packet.push_back('\0');
    }
}

void append_int32(std::vector<char> &packet, std::int32_t value) {
    const auto bits = static_cast<std::uint32_t>(value);
    packet.push_back(static_cast<char>((bits >> 24) & 0xff));
    packet.push_back(static_cast<char>((bits >> 16) & 0xff));
    packet.push_back(static_cast<char>((bits >> 8) & 0xff));
    packet.push_back(static_cast<char>(bits & 0xff));
}

void append_float32(std::vector<char> &packet, float value) {
    std::uint32_t bits = 0;
    static_assert(sizeof(bits) == sizeof(value));
    std::memcpy(&bits, &value, sizeof(bits));
    append_int32(packet, static_cast<std::int32_t>(bits));
}

void append_blob(std::vector<char> &packet, const std::vector<char> &blob) {
    append_int32(packet, static_cast<std::int32_t>(blob.size()));
    packet.insert(packet.end(), blob.begin(), blob.end());
    while ((packet.size() % 4) != 0) {
        packet.push_back('\0');
    }
}

std::size_t find_matching_parenthesis(const std::string &text, std::size_t open) {
    int depth = 0;
    bool in_string = false;
    bool escaping = false;
    bool in_line_comment = false;
    bool in_block_comment = false;

    for (std::size_t index = open; index < text.size(); ++index) {
        const char value = text[index];
        const char next = index + 1 < text.size() ? text[index + 1] : '\0';
        if (in_line_comment) {
            if (value == '\n' || value == '\r') in_line_comment = false;
            continue;
        }
        if (in_block_comment) {
            if (value == '*' && next == '/') {
                in_block_comment = false;
                ++index;
            }
            continue;
        }
        if (in_string) {
            if (escaping) escaping = false;
            else if (value == '\\') escaping = true;
            else if (value == '"') in_string = false;
            continue;
        }
        if (value == '/' && next == '/') {
            in_line_comment = true;
            ++index;
            continue;
        }
        if (value == '/' && next == '*') {
            in_block_comment = true;
            ++index;
            continue;
        }
        if (value == '"') {
            in_string = true;
            continue;
        }
        if (value == '$') {
            ++index;
            continue;
        }
        if (value == '(') ++depth;
        else if (value == ')' && --depth == 0) return index;
    }
    return std::string::npos;
}

} // namespace

struct EmbeddedScEngine::OscArgument {
    enum class Type { integer, floating, string, blob };
    Type type;
    std::int32_t integer_value = 0;
    float float_value = 0.0f;
    std::string string_value;
    std::vector<char> blob_value;

    static OscArgument integer(std::int32_t value) {
        OscArgument argument {};
        argument.type = Type::integer;
        argument.integer_value = value;
        return argument;
    }
    static OscArgument floating(float value) {
        OscArgument argument {};
        argument.type = Type::floating;
        argument.float_value = value;
        return argument;
    }
    static OscArgument string(std::string value) {
        OscArgument argument {};
        argument.type = Type::string;
        argument.string_value = std::move(value);
        return argument;
    }
    static OscArgument blob(std::vector<char> value) {
        OscArgument argument {};
        argument.type = Type::blob;
        argument.blob_value = std::move(value);
        return argument;
    }
};

EmbeddedScEngine::EmbeddedScEngine() = default;
EmbeddedScEngine::~EmbeddedScEngine() { release(); }

bool EmbeddedScEngine::prepare(double sample_rate,
                               int maximum_block_size,
                               const std::string &runtime_root,
                               const std::string &synth_library_path) {
    std::lock_guard<std::mutex> compile_lock(compile_mutex_);
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    release_unlocked();

    sample_rate_ = sample_rate;
    limiter_gain_ = master_level_.load(std::memory_order_relaxed);
    maximum_block_size_ = std::max(maximum_block_size, host_render_quantum);
    runtime_root_ = runtime_root;
    plugin_path_ = runtime_root_ + "/plugins";
    render_buffer_.assign(static_cast<std::size_t>(maximum_block_size_ + host_render_quantum) * output_channels, 0.0f);
    mix_buffer_.assign(static_cast<std::size_t>(maximum_block_size_) * output_channels, 0.0f);
    pending_output_.assign(static_cast<std::size_t>(host_render_quantum) * output_channels, 0.0f);
    const auto panic_message = osc_message("/g_freeAll", { OscArgument::integer(source_group_id) });
    panic_packet_.size = static_cast<std::uint32_t>(panic_message.size());
    std::memcpy(panic_packet_.bytes.data(), panic_message.data(), panic_message.size());

    if (!load_api(runtime_root_)) {
        release_unlocked();
        return false;
    }

    world_options_ = WorldOptions();
    world_options_.mRealTime = true;
    world_options_.mRendezvous = false;
    world_options_.mVerbosity = -1;
    world_options_.mLoadGraphDefs = 0;
    world_options_.mPreferredSampleRate = static_cast<uint32>(sample_rate_);
    world_options_.mPreferredHardwareBufferFrameSize = host_render_quantum;
    world_options_.mBufLength = host_render_quantum;
    world_options_.mNumInputBusChannels = 0;
    world_options_.mNumOutputBusChannels = output_channels;
    world_options_.mNumAudioBusChannels = 1024;
    world_options_.mUGensPluginPath = plugin_path_.c_str();

    world_ = world_new_(&world_options_);
    if (world_ == nullptr) {
        error_ = "Embedded SuperCollider World_New failed";
        release_unlocked();
        return false;
    }

    reply_engine.store(this, std::memory_order_release);
    send_packet(osc_message("/notify", {
        OscArgument::integer(1),
    }));

    send_packet(osc_message("/g_new", {
        OscArgument::integer(source_group_id),
        OscArgument::integer(0),
        OscArgument::integer(0),
    }));

    if (!load_synthdefs_file_unlocked(synth_library_path, true)) {
        release_unlocked();
        return false;
    }

    ready_.store(true, std::memory_order_release);
    error_.clear();
    return true;
}

void EmbeddedScEngine::release() noexcept {
    std::lock_guard<std::mutex> compile_lock(compile_mutex_);
    std::lock_guard<std::mutex> lock(lifecycle_mutex_);
    release_unlocked();
}

void EmbeddedScEngine::release_unlocked() noexcept {
    // Close the callback gate first, then wait on the control thread for any
    // callback that already crossed it. New callbacks observe ready=false and
    // return silence without touching World state or taking a lock.
    ready_.store(false, std::memory_order_release);
    while (callbacks_in_flight_.load(std::memory_order_acquire) != 0) usleep(100);
    stop_render_worker();
    // VSTPlugin releases native plug-ins on SuperCollider's non-realtime
    // worker. Queue close + node retirement followed by /sync, then keep the
    // host-audio driver advancing until that asynchronous teardown has really
    // completed. A fixed sleep is not sufficient: if World_Cleanup deletes the
    // audio driver while the sandbox close is still in its NRT queue, the
    // driver's destructor can wait forever for that same queue to drain.
    const auto vst_node = vst_host_node_.load(std::memory_order_relaxed);
    if (world_ != nullptr && world_render_host_audio_ != nullptr && vst_node > 0) {
        send_packet(osc_message("/u_cmd", {
            OscArgument::integer(vst_node), OscArgument::integer(vst_unit_index),
            OscArgument::string("/close"),
        }));
        send_packet(osc_message("/n_free", { OscArgument::integer(vst_node) }));
        const auto shutdown_sync = sync_counter_.fetch_add(1, std::memory_order_relaxed);
        send_packet(osc_message("/sync", { OscArgument::integer(shutdown_sync) }));
        std::array<float, host_render_quantum * output_channels> scratch {};
        const auto close_deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
        while (std::chrono::steady_clock::now() < close_deadline) {
            world_render_host_audio_(world_, nullptr, scratch.data(), host_render_quantum, 0, output_channels);
#if defined(__APPLE__)
            if (completed_sync_id_.load(std::memory_order_acquire) >= shutdown_sync
                && !signal_vst_hosts(plugin_path_ + "/host", 0)) break;
#else
            if (completed_sync_id_.load(std::memory_order_acquire) >= shutdown_sync) break;
#endif
            usleep(1000);
        }
#if defined(__APPLE__)
        if (signal_vst_hosts(plugin_path_ + "/host", SIGTERM)) {
            // VSTPlugin 0.6.2's sandbox destructor uses an unbounded waitpid.
            // A third-party plug-in can ignore its shared-memory Quit command
            // after a long session. Terminating only our exact direct-child helper releases
            // that wait; keep advancing SC until the queued /sync completes.
            const auto terminate_deadline =
                std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (completed_sync_id_.load(std::memory_order_acquire) < shutdown_sync
                   && std::chrono::steady_clock::now() < terminate_deadline) {
                world_render_host_audio_(
                    world_, nullptr, scratch.data(), host_render_quantum, 0, output_channels);
                usleep(1000);
            }
        }
#endif
    }
    EmbeddedScEngine *expected = this;
    reply_engine.compare_exchange_strong(expected, nullptr, std::memory_order_acq_rel);
    if (world_ != nullptr && world_cleanup_ != nullptr) {
        world_cleanup_(world_, false);
    }
    world_ = nullptr;
    if (shutdown_language_ != nullptr) shutdown_language_();
    if (server_library_ != nullptr) {
        dlclose(server_library_);
        server_library_ = nullptr;
    }
    // Keep the DSO resident, but explicitly stop the process-global language
    // threads. Its registered atexit hook is idempotent; without this call,
    // joinable scheduler threads reach C++ static destruction and terminate.
    language_library_ = nullptr;
    world_new_ = nullptr;
    world_cleanup_ = nullptr;
    world_send_packet_ = nullptr;
    world_render_host_audio_ = nullptr;
    compile_synthdef_fn_ = nullptr;
    initialise_language_ = nullptr;
    shutdown_language_ = nullptr;
    {
        std::lock_guard<std::mutex> producer_lock(queue_producer_mutex_);
        packet_queue_.reset_quiescent();
        queue_depth_.store(0);
    }
    render_buffer_.clear();
    mix_buffer_.clear();
    pending_output_.clear();
    pending_read_frame_ = 0;
    pending_frames_ = 0;
    sample_rate_ = 0.0;
    limiter_gain_ = 0.85f;
    {
        std::lock_guard<std::mutex> voice_lock(voice_mutex_);
        active_nodes_.clear();
        voice_nodes_.clear();
        last_started_instrument_.clear();
    }
    ended_node_queue_.reset_quiescent();
    audio_ring_.reset_quiescent();
    instrument_levels_.clear();
    {
        std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
        loaded_synthdefs_.clear();
        pending_synthdefs_.clear();
    }
    node_counter_.store(10000);
    active_voices_.store(0);
    meter_left_.store(0.0f);
    meter_right_.store(0.0f);
    rendered_frames_.store(0);
    synthdef_count_.store(0);
    queue_peak_.store(0);
    dropped_packets_.store(0);
    render_failures_.store(0);
    invalid_parameters_.store(0);
    invalid_instruments_.store(0);
    node_end_notifications_.store(0);
    dropped_node_notifications_.store(0);
    audio_callbacks_.store(0);
    render_deadline_misses_.store(0);
    max_render_time_usec_.store(0);
    audio_buffer_underruns_.store(0);
    render_worker_overruns_.store(0);
    max_worker_render_time_usec_.store(0);
    render_worker_realtime_.store(false);
    render_ahead_override_frames_.store(0);
    maximum_callback_frames_.store(0);
    startup_prefill_active_.store(false);
    transition_protection_blocks_.store(0);
    vst_host_node_.store(-1);
    vst_ready_.store(false);
    vst_open_state_.store(0);
    vst_open_failures_.store(0);
    sync_counter_.store(1, std::memory_order_relaxed);
    completed_sync_id_.store(0, std::memory_order_relaxed);
    panic_requested_.store(false, std::memory_order_relaxed);
    render_in_progress_.clear(std::memory_order_release);
}

bool EmbeddedScEngine::load_api(const std::string &runtime_root) {
    const auto server_path = runtime_root + "/lib/libscsynth.dylib";
    const auto language_path = runtime_root + "/lib/libweldsclang.dylib";
    server_library_ = dlopen(server_path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (server_library_ == nullptr) {
        error_ = std::string("Could not load embedded libscsynth: ") + dlerror();
        return false;
    }

    world_new_ = reinterpret_cast<WorldNewFn>(dlsym(server_library_, "World_New"));
    world_cleanup_ = reinterpret_cast<WorldCleanupFn>(dlsym(server_library_, "World_Cleanup"));
    world_send_packet_ = reinterpret_cast<WorldSendPacketFn>(dlsym(server_library_, "World_SendPacket"));
    world_render_host_audio_ = reinterpret_cast<WorldRenderHostAudioFn>(dlsym(server_library_, "World_RenderHostAudio"));
    if (!world_new_ || !world_cleanup_ || !world_send_packet_ || !world_render_host_audio_) {
        error_ = "Embedded libscsynth is missing the host-audio API";
        return false;
    }

    language_library_ = dlopen(language_path.c_str(), RTLD_NOW | RTLD_LOCAL);
    if (language_library_ == nullptr) {
        error_ = std::string("Could not load embedded SuperCollider language: ") + dlerror();
        return false;
    }
    initialise_language_ = reinterpret_cast<InitialiseLangFn>(dlsym(language_library_, "WeldSCLang_Initialise"));
    compile_synthdef_fn_ = reinterpret_cast<CompileSynthDefFn>(dlsym(language_library_, "WeldSCLang_CompileSynthDef"));
    shutdown_language_ = reinterpret_cast<ShutdownLangFn>(dlsym(language_library_, "WeldSCLang_Shutdown"));
    if (!initialise_language_ || !compile_synthdef_fn_ || !shutdown_language_) {
        error_ = "Embedded SuperCollider language compiler API is incomplete";
        return false;
    }

    std::array<char, 8192> error {};
    if (!initialise_language_(runtime_root.c_str(), error.data(), static_cast<int>(error.size()))) {
        error_ = std::string("Embedded SuperCollider language init failed: ") + error.data();
        return false;
    }
    return true;
}

std::vector<char> EmbeddedScEngine::osc_message(const std::string &address,
                                                 const std::vector<OscArgument> &arguments) {
    std::vector<char> packet;
    append_padded_string(packet, address);
    std::string tags = ",";
    for (const auto &argument : arguments) {
        switch (argument.type) {
            case OscArgument::Type::integer: tags += 'i'; break;
            case OscArgument::Type::floating: tags += 'f'; break;
            case OscArgument::Type::string: tags += 's'; break;
            case OscArgument::Type::blob: tags += 'b'; break;
        }
    }
    append_padded_string(packet, tags);
    for (const auto &argument : arguments) {
        switch (argument.type) {
            case OscArgument::Type::integer: append_int32(packet, argument.integer_value); break;
            case OscArgument::Type::floating: append_float32(packet, argument.float_value); break;
            case OscArgument::Type::string: append_padded_string(packet, argument.string_value); break;
            case OscArgument::Type::blob: append_blob(packet, argument.blob_value); break;
        }
    }
    return packet;
}

std::vector<std::pair<std::string, std::string>> EmbeddedScEngine::extract_synthdefs(const std::string &source) {
    std::vector<std::pair<std::string, std::string>> definitions;
    std::size_t cursor = 0;
    while ((cursor = source.find("SynthDef(", cursor)) != std::string::npos) {
        const auto open = cursor + std::strlen("SynthDef");
        const auto close = find_matching_parenthesis(source, open);
        if (close == std::string::npos) break;
        auto slash = source.find('\\', open);
        if (slash == std::string::npos || slash > close) {
            cursor = close + 1;
            continue;
        }
        auto end = slash + 1;
        while (end < close && (std::isalnum(static_cast<unsigned char>(source[end])) || source[end] == '_')) ++end;
        const auto name = source.substr(slash + 1, end - slash - 1);
        if (!name.empty()) definitions.emplace_back(name, source.substr(cursor, close + 1 - cursor));
        cursor = close + 1;
    }
    return definitions;
}

bool EmbeddedScEngine::load_synthdefs_file(const std::string &path) {
    std::lock_guard<std::mutex> compile_lock(compile_mutex_);
    if (compile_synthdef_fn_ == nullptr || !is_ready()) {
        error_ = "Embedded SuperCollider is not ready";
        return false;
    }
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        error_ = "Could not open SynthDef library: " + path;
        return false;
    }
    const std::string source((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    const auto definitions = extract_synthdefs(source);
    if (definitions.empty()) {
        error_ = "No SynthDef expressions found in " + path;
        return false;
    }
    for (const auto &[name, _definition] : definitions) {
        std::string canonical = name;
        std::transform(canonical.begin(), canonical.end(), canonical.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        if (!valid_control_name(name) || canonical != name
            || name == "master" || name == "mono" || name == "midi") {
            error_ = "SynthDef name must be a lowercase, non-reserved identifier: " + name;
            return false;
        }
    }
    std::vector<std::vector<char>> compiled_definitions;
    compiled_definitions.reserve(definitions.size());
    for (const auto &[name, definition] : definitions) {
        std::vector<char> bytes;
        if (!compile_synthdef(name, definition, bytes)) return false;
        compiled_definitions.push_back(std::move(bytes));
    }
    const auto callbacks_before = audio_callbacks_.load(std::memory_order_acquire);
    {
        // release()/prepare() share compile_mutex_, so the World cannot change
        // while these packets are handed over. Avoid lifecycle_mutex_ here:
        // the native audio callback remains free to render throughout a live
        // compile and never has to substitute a silent block.
        if (world_ == nullptr || !is_ready()) {
            error_ = "Embedded SuperCollider stopped during SynthDef compilation";
            return false;
        }
        for (auto &bytes : compiled_definitions) {
            if (!send_packet(osc_message("/d_recv", { OscArgument::blob(std::move(bytes)) }))) {
                error_ = "Embedded SuperCollider rejected a compiled SynthDef packet";
                return false;
            }
        }
    }
    std::vector<std::string> definition_names;
    definition_names.reserve(definitions.size());
    for (const auto &[name, _definition] : definitions) definition_names.push_back(name);
    const auto sync_id = send_synthdef_sync();
    if (sync_id < 0) {
        error_ = "Embedded SuperCollider rejected the SynthDef readiness barrier";
        return false;
    }
    register_pending_synthdefs(definition_names, sync_id);
    // /sync is ordered after every /d_recv above. If the live callback is
    // already running, wait for SuperCollider's matching /synced reply before
    // promising that an immediate note can use the definition. During boot,
    // prime_audio() drives the World until those acknowledgements arrive.
    if (callbacks_before > 0) {
        if (!wait_for_synthdefs(definition_names, std::chrono::milliseconds(250))) {
            error_ = "Timed out waiting for live SynthDef registration: " + path;
            return false;
        }
    }
    return true;
}

bool EmbeddedScEngine::load_synthdefs_file_unlocked(const std::string &path, bool replace_count) {
    std::ifstream input(path, std::ios::binary);
    if (!input) {
        error_ = "Could not open SynthDef library: " + path;
        return false;
    }
    const std::string source((std::istreambuf_iterator<char>(input)), std::istreambuf_iterator<char>());
    const auto definitions = extract_synthdefs(source);
    if (definitions.empty()) {
        error_ = "No SynthDef expressions found in " + path;
        return false;
    }
    for (const auto &[name, _definition] : definitions) {
        std::string canonical = name;
        std::transform(canonical.begin(), canonical.end(), canonical.begin(),
                       [](unsigned char c) { return std::tolower(c); });
        if (!valid_control_name(name) || canonical != name
            || name == "master" || name == "mono" || name == "midi") {
            error_ = "SynthDef name must be a lowercase, non-reserved identifier: " + name;
            return false;
        }
    }
    if (replace_count) {
        std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
        loaded_synthdefs_.clear();
        pending_synthdefs_.clear();
        synthdef_count_.store(0);
    }
    for (const auto &[name, definition] : definitions) {
        if (!compile_and_send(name, definition)) return false;
    }
    return true;
}

bool EmbeddedScEngine::load_synthdef(const std::string &name, const std::string &source) {
    std::lock_guard<std::mutex> compile_lock(compile_mutex_);
    if (compile_synthdef_fn_ == nullptr || !is_ready()) {
        error_ = "Embedded SuperCollider is not ready";
        return false;
    }
    std::string canonical = name;
    std::transform(canonical.begin(), canonical.end(), canonical.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    if (!valid_control_name(name) || canonical != name
        || name == "master" || name == "mono" || name == "midi") {
        error_ = "SynthDef name must be a lowercase, non-reserved identifier: " + name;
        return false;
    }
    std::vector<char> bytes;
    if (!compile_synthdef(name, source, bytes)) return false;
    const auto callbacks_before = audio_callbacks_.load(std::memory_order_acquire);
    {
        if (world_ == nullptr || !is_ready()) {
            error_ = "Embedded SuperCollider stopped during SynthDef compilation";
            return false;
        }
        if (!send_packet(osc_message("/d_recv", { OscArgument::blob(std::move(bytes)) }))) {
            error_ = "Embedded SuperCollider rejected SynthDef packet: " + name;
            return false;
        }
    }
    const auto sync_id = send_synthdef_sync();
    if (sync_id < 0) {
        error_ = "Embedded SuperCollider rejected the SynthDef readiness barrier: " + name;
        return false;
    }
    register_pending_synthdefs({ name }, sync_id);
    if (callbacks_before > 0) {
        if (!wait_for_synthdefs({ name }, std::chrono::milliseconds(250))) {
            error_ = "Timed out waiting for live SynthDef registration: " + name;
            return false;
        }
    }
    return true;
}

void EmbeddedScEngine::configure_render_ahead(double output_latency_seconds) {
    if (!std::isfinite(output_latency_seconds)) output_latency_seconds = 0.02;
    const auto requested = static_cast<std::size_t>(std::ceil(
        std::clamp(output_latency_seconds, 0.005, 0.250) * std::max(1.0, sample_rate_)));
    // Keep at least two common 512-frame host callbacks ready. A target equal
    // to one callback can be emptied atomically before the worker gets a chance
    // to schedule its next 256-frame block, even when rendering is otherwise
    // comfortably real-time.
    // The configured latency is the musical render cushion. Add one callback
    // block as a scheduling margin because CoreAudio can begin consuming the
    // oldest 512 frames while the worker is still producing its replacement.
    const auto requested_with_margin = requested + render_worker_block_frames;
    const auto rounded = ((std::max<std::size_t>(requested_with_margin, render_worker_block_frames * 2)
        + render_worker_block_frames - 1) / render_worker_block_frames) * render_worker_block_frames;
    render_ahead_target_frames_.store(
        std::min<std::size_t>(rounded, maximum_render_ahead_frames - render_worker_block_frames),
        std::memory_order_release);
}

void EmbeddedScEngine::prefill_render_ahead(double seconds) {
    const auto requested = static_cast<std::size_t>(
        std::ceil(std::max(0.0, seconds) * std::max(1.0, sample_rate_)));
    const auto rounded = std::min<std::size_t>(
        ((requested + render_worker_block_frames - 1) / render_worker_block_frames)
            * render_worker_block_frames,
        maximum_render_ahead_frames - render_worker_block_frames);
    const auto existing = render_ahead_override_frames_.load(std::memory_order_acquire);
    const auto target = std::max(existing, rounded);
    render_ahead_override_frames_.store(target, std::memory_order_release);
    if (!render_worker_running_.load(std::memory_order_acquire)) return;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (audio_ring_.size() < target && std::chrono::steady_clock::now() < deadline
           && is_ready()) usleep(250);
}

bool EmbeddedScEngine::prime_audio() {
    std::lock_guard<std::mutex> lifecycle_lock(lifecycle_mutex_);
    if (world_ == nullptr || world_render_host_audio_ == nullptr || !is_ready()) return false;
    while (render_in_progress_.test_and_set(std::memory_order_acquire)) usleep(100);
    struct RenderGateGuard final {
        std::atomic_flag &gate;
        ~RenderGateGuard() { gate.clear(std::memory_order_release); }
    } render_gate { render_in_progress_ };
    flush_packets();
    std::array<float, host_render_quantum * output_channels> scratch {};
    bool all_synthdefs_ready = false;
    for (int index = 0; index < 256; ++index) {
        if (!world_render_host_audio_(world_, nullptr, scratch.data(), host_render_quantum, 0, output_channels)) {
            error_ = "Embedded SuperCollider startup warm-up failed";
            return false;
        }
        publish_ready_synthdefs();
        {
            std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
            all_synthdefs_ready = pending_synthdefs_.empty();
        }
        if (index >= 7 && all_synthdefs_ready) break;
        // /d_recv completion runs on SuperCollider's non-realtime worker.
        // Yield between offline warm-up blocks so that worker can complete and
        // deliver the matching /synced acknowledgement.
        usleep(1000);
    }
    if (!all_synthdefs_ready) {
        error_ = "Embedded SuperCollider did not acknowledge all startup SynthDefs";
        return false;
    }
    pending_read_frame_ = 0;
    pending_frames_ = 0;
    audio_ring_.reset_quiescent();
    // Many audio hosts prime a newly started stream with a short burst of
    // back-to-back callbacks. Pre-render that one-time burst while the app
    // is still on its loading boundary, then fall back to the selected low-
    // latency target on the first real callback.
    render_ahead_override_frames_.store(startup_render_ahead_frames, std::memory_order_release);
    startup_prefill_active_.store(true, std::memory_order_release);
    start_render_worker();
    const auto target = startup_render_ahead_frames;
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(2);
    while (audio_ring_.size() < target && std::chrono::steady_clock::now() < deadline
           && render_worker_running_.load(std::memory_order_acquire)) {
        usleep(250);
    }
    if (audio_ring_.size() < target) {
        error_ = "Embedded SuperCollider render-ahead worker did not prime";
        stop_render_worker();
        return false;
    }
    return true;
}

bool EmbeddedScEngine::compile_and_send(const std::string &name, const std::string &source) {
    std::vector<char> bytes;
    if (!compile_synthdef(name, source, bytes)) return false;
    if (!send_packet(osc_message("/d_recv", { OscArgument::blob(std::move(bytes)) }))) {
        error_ = "Embedded SuperCollider rejected SynthDef packet: " + name;
        return false;
    }
    const auto sync_id = send_synthdef_sync();
    if (sync_id < 0) {
        error_ = "Embedded SuperCollider rejected the SynthDef readiness barrier: " + name;
        return false;
    }
    register_pending_synthdefs({ name }, sync_id);
    return true;
}

bool EmbeddedScEngine::compile_synthdef(const std::string &name,
                                         const std::string &source,
                                         std::vector<char> &bytes) {
    char path[] = "/tmp/godotcollider_sc_XXXXXX";
    const int descriptor = mkstemp(path);
    if (descriptor < 0) {
        error_ = "Could not create SynthDef compiler temporary file";
        return false;
    }
    close(descriptor);
    unlink(path);
    std::array<char, 8192> error {};
    if (!compile_synthdef_fn_(source.c_str(), path, name.c_str(), error.data(), static_cast<int>(error.size()))) {
        error_ = "SynthDef compile failed for " + name + ": " + error.data();
        unlink(path);
        return false;
    }
    std::ifstream compiled(path, std::ios::binary);
    if (!compiled) {
        error_ = "SynthDef compiler produced no file for " + name;
        unlink(path);
        return false;
    }
    bytes.assign(std::istreambuf_iterator<char>(compiled), std::istreambuf_iterator<char>());
    compiled.close();
    unlink(path);
    if (bytes.empty()) {
        error_ = "SynthDef compiler produced no bytes for " + name;
        return false;
    }
    return true;
}

bool EmbeddedScEngine::queue_packet(std::vector<char> packet) {
    std::vector<std::vector<char>> packets;
    packets.push_back(std::move(packet));
    return queue_packets(std::move(packets));
}

bool EmbeddedScEngine::queue_packets(std::vector<std::vector<char>> packets) {
    if (packets.empty()) return true;
    std::lock_guard<std::mutex> producer_lock(queue_producer_mutex_);
    // release_unlocked publishes ready=false before clearing this queue. A
    // command that raced shutdown must not repopulate the stopped session.
    if (!is_ready()) return false;
    if (packets.size() > packet_queue_.available()
        || std::any_of(packets.begin(), packets.end(), [](const auto &packet) {
            return packet.empty() || packet.size() > maximum_realtime_packet_bytes;
        })) {
        dropped_packets_.fetch_add(packets.size(), std::memory_order_relaxed);
        return false;
    }
    for (const auto &packet : packets) {
        if (!packet_queue_.try_push(packet)) {
            // Capacity was checked while holding the sole-producer lock, so
            // this can only indicate an internal queue invariant failure.
            dropped_packets_.fetch_add(1, std::memory_order_relaxed);
            return false;
        }
    }
    const auto depth = static_cast<std::uint64_t>(packet_queue_.size());
    queue_depth_.store(depth, std::memory_order_relaxed);
    auto peak = queue_peak_.load(std::memory_order_relaxed);
    while (depth > peak && !queue_peak_.compare_exchange_weak(peak, depth, std::memory_order_relaxed)) {}
    return true;
}

void EmbeddedScEngine::flush_packets() {
    if (panic_requested_.exchange(false, std::memory_order_acq_rel)) {
        packet_queue_.consumer_discard_all();
        queue_depth_.store(0, std::memory_order_relaxed);
        send_realtime_packet(panic_packet_);
    }
    std::size_t sent = 0;
    while (sent < maximum_packets_per_callback && packet_queue_.try_pop(packet_scratch_)) {
        send_realtime_packet(packet_scratch_);
        ++sent;
    }
    queue_depth_.store(static_cast<std::uint64_t>(packet_queue_.size()), std::memory_order_relaxed);
}

bool EmbeddedScEngine::send_packet(std::vector<char> packet) {
    if (world_ == nullptr || world_send_packet_ == nullptr || packet.empty()) return false;
    if (world_send_packet_(world_, static_cast<int>(packet.size()), packet.data(), &EmbeddedScEngine::reply_callback)) {
        return true;
    }
    dropped_packets_.fetch_add(1, std::memory_order_relaxed);
    return false;
}

bool EmbeddedScEngine::send_realtime_packet(RealtimePacket &packet) {
    if (world_ == nullptr || world_send_packet_ == nullptr || packet.size == 0
        || packet.size > packet.bytes.size()) return false;
    if (world_send_packet_(world_, static_cast<int>(packet.size), packet.bytes.data(),
                           &EmbeddedScEngine::reply_callback)) return true;
    dropped_packets_.fetch_add(1, std::memory_order_relaxed);
    return false;
}

std::int32_t EmbeddedScEngine::send_synthdef_sync() {
    const auto sync_id = sync_counter_.fetch_add(1, std::memory_order_relaxed);
    if (sync_id <= 0 || !send_packet(osc_message("/sync", { OscArgument::integer(sync_id) }))) return -1;
    return sync_id;
}

void EmbeddedScEngine::reply_callback(ReplyAddress *, char *data, int size) {
    auto *engine = reply_engine.load(std::memory_order_acquire);
    if (engine == nullptr || data == nullptr || size < 12) return;
    const auto address_size = padded_string_size(data, size);
    if (address_size == 0 || address_size + 8 > static_cast<std::size_t>(size)) return;
    const auto tags = data + address_size;
    const auto tag_size = padded_string_size(tags, size - static_cast<int>(address_size));
    const auto payload = address_size + tag_size;
    if (tag_size == 0 || tags[0] != ',') return;
    if (std::strcmp(data, "/vst_open") == 0 && tags[1] == 'i' && tags[2] == 'i'
        && payload + 8 <= static_cast<std::size_t>(size)) {
        const auto node_id = read_int32_be(data + payload);
        if (node_id != engine->vst_host_node_.load(std::memory_order_relaxed)) return;
        const auto success = tags[3] == 'f' && payload + 12 <= static_cast<std::size_t>(size)
            && read_float32_be(data + payload + 8) != 0.0f;
        engine->vst_ready_.store(success, std::memory_order_release);
        engine->vst_open_state_.store(success ? 2 : 3, std::memory_order_release);
        engine->render_ahead_override_frames_.store(0, std::memory_order_release);
        if (!success) engine->vst_open_failures_.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    if (std::strcmp(data, "/synced") == 0 && tags[1] == 'i'
        && payload + 4 <= static_cast<std::size_t>(size)) {
        const auto sync_id = read_int32_be(data + payload);
        auto completed = engine->completed_sync_id_.load(std::memory_order_relaxed);
        while (sync_id > completed
               && !engine->completed_sync_id_.compare_exchange_weak(
                   completed, sync_id, std::memory_order_release, std::memory_order_relaxed)) {}
        return;
    }
    if (std::strcmp(data, "/n_end") != 0 || tags[1] != 'i' || payload + 4 > static_cast<std::size_t>(size)) return;
    const auto node_id = read_int32_be(data + payload);
    if (!engine->ended_node_queue_.try_push(node_id)) {
        engine->dropped_node_notifications_.fetch_add(1, std::memory_order_relaxed);
    }
}

void EmbeddedScEngine::drain_node_notifications() {
    std::lock_guard<std::mutex> lock(voice_mutex_);
    std::int32_t node_id = 0;
    std::uint64_t ended_count = 0;
    while (ended_node_queue_.try_pop(node_id)) {
        voice_nodes_.erase(std::remove(voice_nodes_.begin(), voice_nodes_.end(), node_id), voice_nodes_.end());
        for (auto iterator = active_nodes_.begin(); iterator != active_nodes_.end();) {
            if (iterator->second == node_id) iterator = active_nodes_.erase(iterator);
            else ++iterator;
        }
        ++ended_count;
    }
    if (ended_count == 0) return;
    active_voices_.store(static_cast<int>(voice_nodes_.size()), std::memory_order_relaxed);
    node_end_notifications_.fetch_add(ended_count, std::memory_order_relaxed);
}

void EmbeddedScEngine::register_pending_synthdefs(const std::vector<std::string> &names,
                                                   std::int32_t sync_id) {
    std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
    for (const auto &name : names) pending_synthdefs_[name] = sync_id;
}

void EmbeddedScEngine::publish_ready_synthdefs() {
    const auto completed_sync_id = completed_sync_id_.load(std::memory_order_acquire);
    std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
    bool changed = false;
    for (auto iterator = pending_synthdefs_.begin(); iterator != pending_synthdefs_.end();) {
        if (completed_sync_id >= iterator->second) {
            loaded_synthdefs_.insert(iterator->first);
            iterator = pending_synthdefs_.erase(iterator);
            changed = true;
        } else {
            ++iterator;
        }
    }
    if (changed) synthdef_count_.store(static_cast<int>(loaded_synthdefs_.size()), std::memory_order_relaxed);
}

bool EmbeddedScEngine::wait_for_synthdefs(const std::vector<std::string> &names,
                                           std::chrono::milliseconds timeout) {
    const auto deadline = std::chrono::steady_clock::now() + timeout;
    do {
        publish_ready_synthdefs();
        {
            std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
            if (std::all_of(names.begin(), names.end(), [&](const auto &name) {
                    return loaded_synthdefs_.find(name) != loaded_synthdefs_.end();
                })) return true;
        }
        usleep(1000);
    } while (std::chrono::steady_clock::now() < deadline && is_ready());
    publish_ready_synthdefs();
    std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
    return std::all_of(names.begin(), names.end(), [&](const auto &name) {
        return loaded_synthdefs_.find(name) != loaded_synthdefs_.end();
    });
}

void EmbeddedScEngine::maintenance() {
    drain_node_notifications();
    publish_ready_synthdefs();
}

std::int32_t EmbeddedScEngine::next_node_id() {
    return node_counter_.fetch_add(1, std::memory_order_relaxed);
}

std::int32_t EmbeddedScEngine::note(const std::string &requested_instrument,
                                    float pitch,
                                    float velocity,
                                    float duration_beats,
                                    const Position2 &position,
                                    const Parameters &parameters) {
    if (!is_ready()) return -1;
    // Reconcile self-freeing SynthDefs before applying the voice cap. This is
    // especially important now that note submission and rendering can run on
    // separate threads.
    drain_node_notifications();
    const auto instrument = normalise_instrument(requested_instrument);
    if (instrument.empty()) {
        invalid_instruments_.fetch_add(1, std::memory_order_relaxed);
        error_ = "Unknown or unloaded SynthDef: " + requested_instrument;
        return -1;
    }
    const auto node_id = next_node_id();
    pitch = finite_or(pitch, 60.0f, invalid_parameters_);
    velocity = finite_or(velocity, 0.7f, invalid_parameters_);
    duration_beats = finite_or(duration_beats, 1.0f, invalid_parameters_);
    const auto position_x = finite_or(position.x, 31.5f, invalid_parameters_);
    const auto duration = std::max(0.01f, duration_beats) * static_cast<float>(60.0 / std::clamp(bpm_.load(), 1.0, 999.0));
    auto pan = pan_for_x(position_x);
    float sustain = duration;
    int out = 0;
    std::vector<std::pair<std::string, float>> extra;

    for (const auto &[key, value] : parameters) {
        if (!valid_control_name(key)) {
            invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
            continue;
        }
        if (!std::isfinite(value)) {
            invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
            continue;
        }
        if (key == "pan") pan = std::clamp(value, -1.0f, 1.0f);
        else if (key == "sustain") sustain = std::clamp(value, 0.01f, 3600.0f);
        else if (key == "out") {
            if (value != 0.0f) invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
            out = 0;
        } else extra.emplace_back(key, std::clamp(value, -1000000.0f, 1000000.0f));
    }

    float level = default_level(instrument);
    {
        std::lock_guard<std::mutex> lock(voice_mutex_);
        if (const auto found = instrument_levels_.find(instrument); found != instrument_levels_.end()) level = found->second;
    }
    std::vector<OscArgument> arguments {
        OscArgument::string(instrument), OscArgument::integer(node_id),
        OscArgument::integer(1), OscArgument::integer(source_group_id),
        OscArgument::string("out"), OscArgument::floating(static_cast<float>(out)),
        OscArgument::string("pitch"), OscArgument::floating(std::clamp(pitch, 0.0f, 127.0f)),
        OscArgument::string("amp"), OscArgument::floating(std::clamp(velocity, 0.0f, 1.0f) * 0.45f * level),
        OscArgument::string("sustain"), OscArgument::floating(sustain),
        OscArgument::string("pan"), OscArgument::floating(pan),
    };
    for (const auto &[key, value] : extra) {
        arguments.push_back(OscArgument::string(key));
        arguments.push_back(OscArgument::floating(value));
    }
    const bool heavy_music_transition = instrument.rfind("swarming_subtractive_music", 0) == 0
        || instrument.rfind("fuzzy_phase_arpeggios", 0) == 0;
    if (heavy_music_transition) prefill_render_ahead(music_transition_render_ahead_seconds);
    std::vector<std::vector<char>> packets;
    {
        std::lock_guard<std::mutex> lock(voice_mutex_);
        if (static_cast<int>(voice_nodes_.size()) >= maximum_voices) {
            packets.push_back(osc_message("/n_free", { OscArgument::integer(voice_nodes_.front()) }));
        }
        packets.push_back(osc_message("/s_new", arguments));
        if (!queue_packets(std::move(packets))) {
            if (heavy_music_transition) render_ahead_override_frames_.store(0, std::memory_order_release);
            return -1;
        }
        if (static_cast<int>(voice_nodes_.size()) >= maximum_voices) voice_nodes_.pop_front();
        active_nodes_[instrument] = node_id;
        voice_nodes_.push_back(node_id);
        last_started_instrument_ = instrument;
        active_voices_.store(static_cast<int>(voice_nodes_.size()), std::memory_order_relaxed);
    }
    if (heavy_music_transition) transition_protection_blocks_.store(
        music_transition_protection_blocks, std::memory_order_release);
    return node_id;
}

std::int32_t EmbeddedScEngine::trigger(const std::string &name, const Position2 &position) {
    return note(name, name == "kick" ? 36.0f : name == "hat" ? 80.0f : 60.0f,
                0.78f, 0.18f, position, Parameters());
}

std::int32_t EmbeddedScEngine::control(const std::string &target,
                                       const std::string &requested_parameter,
                                       float value) {
    if (!is_ready()) return -1;
    if (!std::isfinite(value)) {
        invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
        return -1;
    }
    std::string normalised_target = target;
    std::transform(normalised_target.begin(), normalised_target.end(), normalised_target.begin(),
                   [](unsigned char c) { return std::tolower(c); });
    std::string parameter = requested_parameter;
    std::transform(parameter.begin(), parameter.end(), parameter.begin(), [](unsigned char c) { return std::tolower(c); });
    // `master` is a control target, never a SynthDef. Resolve it before the
    // loaded-SynthDef registry so note("master") cannot enqueue a bogus node.
    if (normalised_target == "master" || parameter == "master") {
        set_master_level(value);
        return 0;
    }
    const auto instrument = normalise_instrument(target);
    if (instrument.empty()) {
        invalid_instruments_.fetch_add(1, std::memory_order_relaxed);
        return -1;
    }
    if (parameter == "volume" || parameter == "gain" || parameter == "amp" || parameter == "cc7") parameter = "level";
    if (parameter == "cc10") parameter = "pan";
    if (!valid_control_name(parameter)) {
        invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
        return -1;
    }
    std::lock_guard<std::mutex> voice_lock(voice_mutex_);
    if (parameter == "level") instrument_levels_[instrument] = std::clamp(value, 0.0f, 1.25f);
    const auto found = active_nodes_.find(instrument);
    if (found == active_nodes_.end()) return 0;
    const auto sc_parameter = parameter == "level" ? "amp" : parameter;
    const auto sc_value = parameter == "level" ? std::clamp(value, 0.0f, 1.25f) * 0.45f
                                                  : parameter == "pan" ? std::clamp(value, -1.0f, 1.0f) : value;
    if (!queue_packet(osc_message("/n_set", {
        OscArgument::integer(found->second), OscArgument::string(sc_parameter), OscArgument::floating(sc_value),
    }))) return -1;
    return found->second;
}

std::int32_t EmbeddedScEngine::control_node(std::int32_t node_id,
                                            const std::string &parameter,
                                            float value) {
    if (!is_ready() || node_id <= 0 || !valid_control_name(parameter) || !std::isfinite(value)) {
        invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
        return -1;
    }
    const auto safe_value = std::clamp(value, -1000000.0f, 1000000.0f);
	// `run` is a node lifecycle command rather than a SynthDef control. Pausing
	// preserves expensive plug-in state while removing the inactive node from
	// the real-time DSP traversal; resuming is immediate and requires no reload.
	if (parameter == "run") {
		const bool resuming = safe_value >= 0.5f;
		if (resuming) prefill_render_ahead(music_transition_render_ahead_seconds);
		if (!queue_packet(osc_message("/n_run", {
			OscArgument::integer(node_id), OscArgument::integer(resuming ? 1 : 0),
		}))) {
			if (resuming) render_ahead_override_frames_.store(0, std::memory_order_release);
			return -1;
		}
		if (resuming) transition_protection_blocks_.store(
			music_transition_protection_blocks, std::memory_order_release);
		return node_id;
	}
    const bool mode_transition = parameter == "mode";
    if (mode_transition) prefill_render_ahead(music_transition_render_ahead_seconds);
    if (!queue_packet(osc_message("/n_set", {
        OscArgument::integer(node_id), OscArgument::string(parameter), OscArgument::floating(safe_value),
    }))) {
        if (mode_transition) render_ahead_override_frames_.store(0, std::memory_order_release);
        return -1;
    }
    if (mode_transition) transition_protection_blocks_.store(
        music_transition_protection_blocks, std::memory_order_release);
    return node_id;
}

std::int32_t EmbeddedScEngine::start_vst_host(const std::string &synthdef,
                                              const std::string &plugin_path) {
    if (!is_ready() || synthdef.empty() || plugin_path.empty()) return -1;
    const auto resolved_synthdef = normalise_instrument(synthdef);
    if (resolved_synthdef.empty() || resolved_synthdef == "master") {
        invalid_instruments_.fetch_add(1, std::memory_order_relaxed);
        error_ = "Unknown or unloaded VST host SynthDef: " + synthdef;
        return -1;
    }
    // A cold sandboxed VST3 probe can stall SuperCollider's render call for
    // tens of milliseconds. Fill a temporary 140 ms cushion before submitting
    // /open so the host continues consuming uninterrupted audio while that work
    // completes. Once /vst_open replies, the worker drains back to the user's
    // selected normal latency preset without a discontinuity.
    prefill_render_ahead(vst_open_render_ahead_seconds);
    const auto node_id = next_node_id();
    std::vector<std::vector<char>> packets;
    const auto previous_node = vst_host_node_.load(std::memory_order_relaxed);
    if (previous_node > 0) {
        // A sandboxed plug-in can occasionally fail to finish opening. Retrying
        // must retire its Synth node first or each attempt leaves another VST
        // bridge and helper process attached to the World.
        packets.push_back(osc_message("/n_free", { OscArgument::integer(previous_node) }));
    }
    packets.push_back(osc_message("/s_new", {
        OscArgument::string(resolved_synthdef), OscArgument::integer(node_id),
        OscArgument::integer(1), OscArgument::integer(source_group_id),
        OscArgument::string("out"), OscArgument::floating(0.0f),
    }));
    packets.push_back(osc_message("/u_cmd", {
        OscArgument::integer(node_id), OscArgument::integer(vst_unit_index), OscArgument::string("/open"),
        OscArgument::string(plugin_path), OscArgument::integer(0), OscArgument::integer(1),
        // Some in-process VST3 factories fail during bundleExit on macOS.
        // Sandbox the plug-in in VSTPlugin's bundled helper so its teardown
        // cannot terminate the host application.
        OscArgument::integer(1),
    }));
    if (!queue_packets(std::move(packets))) {
        render_ahead_override_frames_.store(0, std::memory_order_release);
        return -1;
    }
    vst_host_node_.store(node_id, std::memory_order_relaxed);
    vst_ready_.store(false, std::memory_order_release);
    vst_open_state_.store(1, std::memory_order_release);
    // If shutdown began between queueing and publishing this node, remove the
    // stale diagnostic rather than letting it leak into the next session.
    if (!is_ready()) {
        auto expected_node = node_id;
        vst_host_node_.compare_exchange_strong(expected_node, -1, std::memory_order_relaxed);
        return -1;
    }
    return node_id;
}

bool EmbeddedScEngine::vst_midi(std::int32_t node_id,
                                int status,
                                int data1,
                                int data2,
                                float detune) {
    if (!is_ready() || node_id <= 0 || !std::isfinite(detune)) return false;
    std::vector<char> message {
        static_cast<char>(std::clamp(status, 0, 255)),
        static_cast<char>(std::clamp(data1, 0, 127)),
        static_cast<char>(std::clamp(data2, 0, 127)),
    };
    return queue_packet(osc_message("/u_cmd", {
        OscArgument::integer(node_id), OscArgument::integer(vst_unit_index), OscArgument::string("/midi_msg"),
        OscArgument::blob(std::move(message)), OscArgument::floating(detune),
    }));
}

bool EmbeddedScEngine::vst_all_notes_off(std::int32_t node_id) {
    if (!is_ready() || node_id <= 0) return false;
    std::vector<std::vector<char>> packets;
    packets.reserve(32);
    for (int channel = 0; channel < 16; ++channel) {
        for (const int controller : {64, 123}) {
            std::vector<char> message {
                static_cast<char>(0xB0 | channel), static_cast<char>(controller), 0,
            };
            packets.push_back(osc_message("/u_cmd", {
                OscArgument::integer(node_id), OscArgument::integer(vst_unit_index), OscArgument::string("/midi_msg"),
                OscArgument::blob(std::move(message)), OscArgument::floating(0.0f),
            }));
        }
    }
    return queue_packets(std::move(packets));
}

void EmbeddedScEngine::panic() {
    // The audio consumer performs the discard and sends the prebuilt packet.
    // This preserves SPSC ownership and performs no allocation in mix().
    panic_requested_.store(true, std::memory_order_release);
    std::lock_guard<std::mutex> voice_lock(voice_mutex_);
    active_nodes_.clear();
    voice_nodes_.clear();
    active_voices_.store(0);
    vst_host_node_.store(-1, std::memory_order_relaxed);
    vst_ready_.store(false, std::memory_order_release);
    vst_open_state_.store(0, std::memory_order_release);
    render_ahead_override_frames_.store(0, std::memory_order_release);
    transition_protection_blocks_.store(0, std::memory_order_release);
}

void EmbeddedScEngine::set_transport(double next_bpm, std::uint64_t next_tick, bool next_playing) {
    if (!std::isfinite(next_bpm)) {
        invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
        next_bpm = 120.0;
    }
    bpm_.store(std::clamp(next_bpm, 1.0, 999.0));
    tick_.store(next_tick);
    playing_.store(next_playing);
}

void EmbeddedScEngine::set_master_level(float level) {
    if (!std::isfinite(level)) {
        invalid_parameters_.fetch_add(1, std::memory_order_relaxed);
        return;
    }
    master_level_.store(std::clamp(level, 0.0f, 1.25f));
}

int EmbeddedScEngine::render_interleaved(float *output, int frames) {
    int copied = 0;
    if (pending_frames_ > 0) {
        const int count = std::min(frames, pending_frames_);
        std::copy_n(pending_output_.data() + pending_read_frame_ * output_channels,
                    count * output_channels, output);
        copied += count;
        pending_read_frame_ += count;
        pending_frames_ -= count;
        if (pending_frames_ == 0) pending_read_frame_ = 0;
    }
    if (copied < frames) {
        const int required = frames - copied;
        const int rendered = ((required + host_render_quantum - 1) / host_render_quantum) * host_render_quantum;
        if (rendered > maximum_block_size_) {
            render_failures_.fetch_add(1, std::memory_order_relaxed);
            return copied;
        }
        std::fill_n(render_buffer_.data(), rendered * output_channels, 0.0f);
        if (!world_render_host_audio_(world_, nullptr, render_buffer_.data(), rendered, 0, output_channels)) {
            render_failures_.fetch_add(1, std::memory_order_relaxed);
            return copied;
        }
        std::copy_n(render_buffer_.data(), required * output_channels, output + copied * output_channels);
        copied += required;
        pending_frames_ = rendered - required;
        pending_read_frame_ = 0;
        if (pending_frames_ > 0) {
            std::copy_n(render_buffer_.data() + required * output_channels,
                        pending_frames_ * output_channels, pending_output_.data());
        }
    }
    return copied;
}

bool EmbeddedScEngine::render_output_block(AudioFrame *output, int frames) {
    if (!is_ready() || world_ == nullptr || frames > maximum_block_size_) {
        render_failures_.fetch_add(1, std::memory_order_relaxed);
        clear_output(output, frames);
        return false;
    }
    flush_packets();
    if (static_cast<int>(render_buffer_.size()) < (frames + host_render_quantum) * output_channels) {
        render_failures_.fetch_add(1, std::memory_order_relaxed);
        clear_output(output, frames);
        return false;
    }
    std::fill_n(mix_buffer_.data(), frames * output_channels, 0.0f);
    const int rendered = render_interleaved(mix_buffer_.data(), frames);
    const float level = master_level_.load(std::memory_order_relaxed);
    float peak_left = 0.0f;
    float peak_right = 0.0f;
    float peak = 0.0f;
    for (int frame = 0; frame < rendered; ++frame) {
        peak_left = std::max(peak_left, std::abs(mix_buffer_[frame * 2]));
        peak_right = std::max(peak_right, std::abs(mix_buffer_[frame * 2 + 1]));
    }
    peak = std::max(peak_left, peak_right);
    float target_gain = level;
    if (peak * target_gain > limiter_ceiling) {
        target_gain = limiter_ceiling / std::max(peak, 0.000001f);
    }
    const float safe_sample_rate = static_cast<float>(std::max(1.0, sample_rate_));
    const float attack_coefficient = std::exp(-1.0f / (0.0025f * safe_sample_rate));
    const float release_coefficient = std::exp(-1.0f / (0.140f * safe_sample_rate));
    for (int frame = 0; frame < frames; ++frame) {
        const float coefficient = target_gain < limiter_gain_ ? attack_coefficient : release_coefficient;
        limiter_gain_ = target_gain + coefficient * (limiter_gain_ - target_gain);
        const float left = frame < rendered ? mix_buffer_[frame * 2] * limiter_gain_ : 0.0f;
        const float right = frame < rendered ? mix_buffer_[frame * 2 + 1] * limiter_gain_ : 0.0f;
        output[frame].left = std::isfinite(left) ? std::clamp(left, -output_limit, output_limit) : 0.0f;
        output[frame].right = std::isfinite(right) ? std::clamp(right, -output_limit, output_limit) : 0.0f;
    }
    meter_left_.store(std::min(1.0f, peak_left * limiter_gain_));
    meter_right_.store(std::min(1.0f, peak_right * limiter_gain_));
    rendered_frames_.fetch_add(static_cast<std::uint64_t>(frames));
    return rendered == frames;
}

void EmbeddedScEngine::start_render_worker() {
    if (render_worker_running_.exchange(true, std::memory_order_acq_rel)) return;
    render_worker_ = std::thread(&EmbeddedScEngine::render_worker_loop, this);
}

void EmbeddedScEngine::stop_render_worker() noexcept {
    render_worker_running_.store(false, std::memory_order_release);
    if (render_worker_.joinable()) render_worker_.join();
}

void EmbeddedScEngine::render_worker_loop() {
#if defined(__APPLE__)
    pthread_setname_np("ScAppEngine");
    // The worker feeds (rather than runs inside) CoreAudio's callback, but it
    // still has an audio deadline. User-interactive QoS prevents background
    // scheduler stalls without requesting fragile hard real-time privileges.
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    mach_timebase_info_data_t timebase {};
    mach_timebase_info(&timebase);
    const auto seconds_to_ticks = [&timebase](double seconds) -> std::uint32_t {
        const auto nanoseconds = seconds * 1000000000.0;
        return static_cast<std::uint32_t>(std::max(1.0,
            nanoseconds * static_cast<double>(timebase.denom) / static_cast<double>(timebase.numer)));
    };
    const auto period_seconds = static_cast<double>(render_worker_block_frames) / std::max(1.0, sample_rate_);
    thread_time_constraint_policy_data_t realtime_policy {
        seconds_to_ticks(period_seconds),
        seconds_to_ticks(period_seconds * 0.42),
        seconds_to_ticks(period_seconds * 0.90),
        1,
    };
    const auto mach_thread = mach_thread_self();
    const auto realtime_result = thread_policy_set(
        mach_thread,
        THREAD_TIME_CONSTRAINT_POLICY,
        reinterpret_cast<thread_policy_t>(&realtime_policy),
        THREAD_TIME_CONSTRAINT_POLICY_COUNT);
    render_worker_realtime_.store(realtime_result == KERN_SUCCESS, std::memory_order_release);
    mach_port_deallocate(mach_task_self(), mach_thread);
#endif
    std::array<AudioFrame, render_worker_block_frames> block {};
    while (render_worker_running_.load(std::memory_order_acquire) && is_ready()) {
        const auto override_frames = render_ahead_override_frames_.load(std::memory_order_acquire);
        const auto configured_target = override_frames > 0
            ? override_frames : render_ahead_target_frames_.load(std::memory_order_acquire);
        const auto target = std::min<std::size_t>(
            std::max<std::size_t>(configured_target,
                maximum_callback_frames_.load(std::memory_order_acquire) * 2),
            maximum_render_ahead_frames - render_worker_block_frames);
        if (audio_ring_.size() + block.size() > target || audio_ring_.available() < block.size()) {
            // A short bounded poll keeps replenishment prompt without spinning
            // a core continuously while the cushion is full.
            usleep(50);
            continue;
        }
        const auto started = std::chrono::steady_clock::now();
        render_output_block(block.data(), static_cast<int>(block.size()));
        const auto elapsed = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
            std::chrono::steady_clock::now() - started).count());
        auto maximum = max_worker_render_time_usec_.load(std::memory_order_relaxed);
        while (elapsed > maximum
               && !max_worker_render_time_usec_.compare_exchange_weak(maximum, elapsed, std::memory_order_relaxed)) {}
        const auto deadline = static_cast<std::uint64_t>(
            (static_cast<double>(block.size()) / std::max(1.0, sample_rate_)) * 1000000.0);
        if (elapsed > deadline) render_worker_overruns_.fetch_add(1, std::memory_order_relaxed);
        for (const auto &frame : block) {
            if (!audio_ring_.try_push(frame)) break;
        }
        auto remaining = transition_protection_blocks_.load(std::memory_order_acquire);
        while (remaining > 0 && !transition_protection_blocks_.compare_exchange_weak(
                   remaining, remaining - 1, std::memory_order_acq_rel, std::memory_order_acquire)) {}
        if (remaining == 1) {
            render_ahead_override_frames_.store(0, std::memory_order_release);
        }
    }
}

int EmbeddedScEngine::mix(AudioFrame *output, int frames) {
    if (output == nullptr || frames <= 0) return 0;
    callbacks_in_flight_.fetch_add(1, std::memory_order_acq_rel);
    struct CallbackFlightGuard final {
        std::atomic<std::uint32_t> &counter;
        ~CallbackFlightGuard() { counter.fetch_sub(1, std::memory_order_release); }
    } callback_flight { callbacks_in_flight_ };
    const auto render_started = std::chrono::steady_clock::now();
    if (startup_prefill_active_.exchange(false, std::memory_order_acq_rel)) {
        render_ahead_override_frames_.store(0, std::memory_order_release);
    }
    auto maximum_callback = maximum_callback_frames_.load(std::memory_order_relaxed);
    while (static_cast<std::size_t>(frames) > maximum_callback
           && !maximum_callback_frames_.compare_exchange_weak(
               maximum_callback, static_cast<std::size_t>(frames), std::memory_order_release,
               std::memory_order_relaxed)) {}
    if (!is_ready()) {
        clear_output(output, frames);
        return frames;
    }
    int copied = 0;
    while (copied < frames && audio_ring_.try_pop(output[copied])) ++copied;
    if (copied < frames) {
        clear_output(output + copied, frames - copied);
        audio_buffer_underruns_.fetch_add(1, std::memory_order_relaxed);
    }
    const auto elapsed = static_cast<std::uint64_t>(std::chrono::duration_cast<std::chrono::microseconds>(
        std::chrono::steady_clock::now() - render_started).count());
    audio_callbacks_.fetch_add(1, std::memory_order_relaxed);
    auto maximum = max_render_time_usec_.load(std::memory_order_relaxed);
    while (elapsed > maximum
           && !max_render_time_usec_.compare_exchange_weak(maximum, elapsed, std::memory_order_relaxed)) {}
    const auto deadline = static_cast<std::uint64_t>(
        (static_cast<double>(frames) / std::max(1.0, sample_rate_)) * 1000000.0);
    if (elapsed > deadline) render_deadline_misses_.fetch_add(1, std::memory_order_relaxed);
    return frames;
}

void EmbeddedScEngine::clear_output(AudioFrame *output, int frames) const {
    for (int frame = 0; frame < frames; ++frame) output[frame] = { 0.0f, 0.0f };
}

std::string EmbeddedScEngine::normalise_instrument(const std::string &name) const {
    std::string result = name;
    std::transform(result.begin(), result.end(), result.begin(), [](unsigned char c) { return std::tolower(c); });
    if (result == "mono") result = "bass";
    if (result == "midi") result = "tone";
    if (!valid_control_name(result)) return {};
    std::lock_guard<std::mutex> synthdef_lock(synthdef_mutex_);
    return loaded_synthdefs_.find(result) != loaded_synthdefs_.end() ? result : std::string {};
}

std::string EmbeddedScEngine::last_started_instrument() const {
    std::lock_guard<std::mutex> voice_lock(voice_mutex_);
    return last_started_instrument_;
}

float EmbeddedScEngine::default_level(const std::string &instrument) {
    static const std::unordered_map<std::string, float> levels {
        {"kick", .95f}, {"snare", .78f}, {"hat", .55f}, {"bass", .82f}, {"tone", .68f},
        {"grain", .62f}, {"drone", .50f}, {"sub", .62f}, {"pad", .52f}, {"choir", .50f},
		{"pluck", .58f}, {"bell", .46f}, {"big_bell", .46f}, {"giant_bell", .46f}, {"fm", .52f}, {"acid", .56f}, {"string", .52f},
        {"noise", .36f}, {"lead", .56f}, {"perc", .42f}, {"metal", .38f},
    };
    const auto found = levels.find(instrument);
    return found == levels.end() ? .68f : found->second;
}

float EmbeddedScEngine::pan_for_x(float x) {
    return std::clamp((x / 63.0f) * 1.8f - 0.9f, -0.9f, 0.9f);
}

std::string EmbeddedScEngine::status() const {
    return is_ready() ? "EMBEDDED SC READY" : error_.empty() ? "EMBEDDED SC OFF" : "EMBEDDED SC ERROR";
}

std::string EmbeddedScEngine::last_error() const {
    return error_;
}

} // namespace scapp
