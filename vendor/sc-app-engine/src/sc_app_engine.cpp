#include "sc_app_engine.h"
#include "portable_sc_engine.hpp"

#include <algorithm>
#include <cstring>
#include <filesystem>
#include <memory>
#include <mutex>
#include <new>
#include <string>
#include <vector>

struct scae_engine {
    scapp::EmbeddedScEngine core;
    mutable std::mutex control_mutex;
    std::string api_error;
};

namespace {

std::mutex active_engine_mutex;
scae_engine *active_engine = nullptr;

bool claim_active_engine(scae_engine *engine) {
    std::lock_guard<std::mutex> lock(active_engine_mutex);
    if (active_engine != nullptr && active_engine != engine) return false;
    active_engine = engine;
    return true;
}

void release_active_engine(scae_engine *engine) {
    std::lock_guard<std::mutex> lock(active_engine_mutex);
    if (active_engine == engine) active_engine = nullptr;
}

scae_result copy_text(const std::string &text, char *destination, size_t capacity, size_t &required) {
    required = text.size() + 1;
    if (destination == nullptr || capacity == 0) return SCAE_OK;
    const auto count = std::min(text.size(), capacity - 1);
    std::memcpy(destination, text.data(), count);
    destination[count] = '\0';
    return SCAE_OK;
}

std::vector<std::filesystem::path> synthdef_paths(const char *directory) {
    std::vector<std::filesystem::path> result;
    std::error_code error;
    for (std::filesystem::directory_iterator iterator(directory, error), end;
         !error && iterator != end; iterator.increment(error)) {
        if (iterator->is_regular_file(error) && iterator->path().extension() == ".scd") {
            result.push_back(iterator->path());
        }
    }
    std::sort(result.begin(), result.end());
    return result;
}

} // namespace

extern "C" {

uint32_t scae_abi_version(void) { return SCAE_ABI_VERSION; }
const char *scae_version_string(void) { return "0.2.0"; }

scae_engine *scae_create(void) {
    try {
        return new (std::nothrow) scae_engine;
    } catch (...) {
        return nullptr;
    }
}

void scae_destroy(scae_engine *engine) {
    if (engine == nullptr) return;
    try {
        scae_stop(engine);
        delete engine;
    } catch (...) {
        /* C ABI teardown is deliberately no-throw. */
    }
}

scae_result scae_start(scae_engine *engine, const scae_config *config) {
    if (engine == nullptr || config == nullptr
        || config->struct_size < sizeof(scae_config)
        || config->runtime_root == nullptr || config->synthdefs_directory == nullptr
        || config->sample_rate < 8000.0 || config->maximum_callback_frames == 0) {
        return SCAE_INVALID_ARGUMENT;
    }
    if (config->abi_version != SCAE_ABI_VERSION) return SCAE_ABI_MISMATCH;
    try {
        std::lock_guard<std::mutex> lock(engine->control_mutex);
        engine->api_error.clear();
        if (!claim_active_engine(engine)) {
            engine->api_error = "Only one SuperCollider App Engine may be active in a process";
            return SCAE_ENGINE_ERROR;
        }
        engine->core.release();
        const auto files = synthdef_paths(config->synthdefs_directory);
        if (files.empty()) {
            engine->api_error = "SynthDef directory is missing or contains no .scd files";
            release_active_engine(engine);
            return SCAE_IO_ERROR;
        }
        if (!engine->core.prepare(
                config->sample_rate,
                static_cast<int>(config->maximum_callback_frames),
                config->runtime_root,
                files.front().string())) {
            release_active_engine(engine);
            return SCAE_ENGINE_ERROR;
        }
        for (std::size_t index = 1; index < files.size(); ++index) {
            if (!engine->core.load_synthdefs_file(files[index].string())) {
                engine->core.release();
                release_active_engine(engine);
                return SCAE_ENGINE_ERROR;
            }
        }
        engine->core.configure_render_ahead(config->output_latency_seconds);
        engine->core.set_master_level(config->master_level);
        if (!engine->core.prime_audio()) {
            engine->core.release();
            release_active_engine(engine);
            return SCAE_ENGINE_ERROR;
        }
        return SCAE_OK;
    } catch (...) {
        release_active_engine(engine);
        return SCAE_ENGINE_ERROR;
    }
}

void scae_stop(scae_engine *engine) {
    if (engine == nullptr) return;
    try {
        std::lock_guard<std::mutex> lock(engine->control_mutex);
        engine->core.release();
        release_active_engine(engine);
    } catch (...) {}
}

uint32_t scae_is_ready(const scae_engine *engine) {
    return engine != nullptr && engine->core.is_ready() ? 1u : 0u;
}

uint32_t scae_render_interleaved(scae_engine *engine, float *output, uint32_t frames) {
    if (output == nullptr || frames == 0) return 0;
    if (engine == nullptr) {
        std::fill_n(output, static_cast<std::size_t>(frames) * 2, 0.0f);
        return frames;
    }
    try {
        return static_cast<uint32_t>(engine->core.mix(
            reinterpret_cast<scapp::AudioFrame *>(output), static_cast<int>(frames)));
    } catch (...) {
        std::fill_n(output, static_cast<std::size_t>(frames) * 2, 0.0f);
        return frames;
    }
}

void scae_maintenance(scae_engine *engine) {
    if (engine == nullptr) return;
    try { engine->core.maintenance(); } catch (...) {}
}

int32_t scae_note(scae_engine *engine, const char *instrument, float pitch, float velocity,
                  float duration_beats, float position_x, float position_y,
                  const scae_parameter *parameters, uint32_t parameter_count) {
    if (engine == nullptr || instrument == nullptr
        || (parameter_count > 0 && parameters == nullptr)) return -1;
    try {
        scapp::Parameters values;
        values.reserve(parameter_count);
        for (uint32_t index = 0; index < parameter_count; ++index) {
            if (parameters[index].name == nullptr) return -1;
            values.emplace_back(parameters[index].name, parameters[index].value);
        }
        return engine->core.note(instrument, pitch, velocity, duration_beats,
                                 {position_x, position_y}, values);
    } catch (...) {
        return -1;
    }
}

int32_t scae_trigger(scae_engine *engine, const char *name, float x, float y) {
    if (engine == nullptr || name == nullptr) return -1;
    try { return engine->core.trigger(name, {x, y}); } catch (...) { return -1; }
}

int32_t scae_control(scae_engine *engine, const char *target, const char *parameter, float value) {
    if (engine == nullptr || target == nullptr || parameter == nullptr) return -1;
    try { return engine->core.control(target, parameter, value); } catch (...) { return -1; }
}

int32_t scae_control_node(scae_engine *engine, int32_t node_id, const char *parameter, float value) {
    if (engine == nullptr || parameter == nullptr) return -1;
    try { return engine->core.control_node(node_id, parameter, value); } catch (...) { return -1; }
}

void scae_set_transport(scae_engine *engine, double bpm, uint64_t tick, uint32_t playing) {
    if (engine == nullptr) return;
    try { engine->core.set_transport(bpm, tick, playing != 0); } catch (...) {}
}

void scae_set_master_level(scae_engine *engine, float level) {
    if (engine == nullptr) return;
    try { engine->core.set_master_level(level); } catch (...) {}
}

void scae_panic(scae_engine *engine) {
    if (engine == nullptr) return;
    try { engine->core.panic(); } catch (...) {}
}

scae_result scae_load_synthdefs_file(scae_engine *engine, const char *path) {
    if (engine == nullptr || path == nullptr) return SCAE_INVALID_ARGUMENT;
    try {
        std::lock_guard<std::mutex> lock(engine->control_mutex);
        return engine->core.load_synthdefs_file(path) ? SCAE_OK : SCAE_ENGINE_ERROR;
    } catch (...) { return SCAE_ENGINE_ERROR; }
}

scae_result scae_load_synthdef(scae_engine *engine, const char *name, const char *source) {
    if (engine == nullptr || name == nullptr || source == nullptr) return SCAE_INVALID_ARGUMENT;
    try {
        std::lock_guard<std::mutex> lock(engine->control_mutex);
        return engine->core.load_synthdef(name, source) ? SCAE_OK : SCAE_ENGINE_ERROR;
    } catch (...) { return SCAE_ENGINE_ERROR; }
}

int32_t scae_start_vst_host(scae_engine *engine, const char *synthdef, const char *plugin_path) {
    if (engine == nullptr || synthdef == nullptr || plugin_path == nullptr) return -1;
    try { return engine->core.start_vst_host(synthdef, plugin_path); } catch (...) { return -1; }
}

uint32_t scae_vst_midi(scae_engine *engine, int32_t node_id, int status,
                       int data1, int data2, float detune) {
    if (engine == nullptr) return 0;
    try { return engine->core.vst_midi(node_id, status, data1, data2, detune) ? 1u : 0u; }
    catch (...) { return 0; }
}

uint32_t scae_vst_all_notes_off(scae_engine *engine, int32_t node_id) {
    if (engine == nullptr) return 0;
    try { return engine->core.vst_all_notes_off(node_id) ? 1u : 0u; }
    catch (...) { return 0; }
}

scae_result scae_get_status(const scae_engine *engine, scae_status *status) {
    if (engine == nullptr || status == nullptr || status->struct_size < sizeof(uint32_t) * 2) {
        return SCAE_INVALID_ARGUMENT;
    }
    try {
        scae_status value {};
        value.struct_size = sizeof(value);
        value.abi_version = SCAE_ABI_VERSION;
        value.ready = engine->core.is_ready();
        value.render_worker_realtime = engine->core.render_worker_realtime();
        value.sample_rate = engine->core.sample_rate();
        value.synthdef_count = engine->core.synthdef_count();
        value.active_voices = engine->core.active_voice_count();
        value.vst_host_node = engine->core.vst_host_node();
        value.vst_open_state = engine->core.vst_open_state();
        value.vst_ready = engine->core.vst_ready();
        value.meter_left = engine->core.meter_left();
        value.meter_right = engine->core.meter_right();
        value.rendered_frames = engine->core.rendered_frames();
        value.audio_callbacks = engine->core.audio_callbacks();
        value.queue_depth = engine->core.queue_depth();
        value.queue_peak = engine->core.queue_peak();
        value.dropped_packets = engine->core.dropped_packets();
        value.render_failures = engine->core.render_failures();
        value.invalid_parameters = engine->core.invalid_parameters();
        value.invalid_instruments = engine->core.invalid_instruments();
        value.node_end_notifications = engine->core.node_end_notifications();
        value.dropped_node_notifications = engine->core.dropped_node_notifications();
        value.render_deadline_misses = engine->core.render_deadline_misses();
        value.max_render_time_usec = engine->core.max_render_time_usec();
        value.audio_buffer_underruns = engine->core.audio_buffer_underruns();
        value.render_worker_overruns = engine->core.render_worker_overruns();
        value.max_worker_render_time_usec = engine->core.max_worker_render_time_usec();
        value.render_ahead_frames = engine->core.render_ahead_frames();
        value.render_ahead_target_frames = engine->core.render_ahead_target_frames();
        value.maximum_callback_frames = engine->core.maximum_callback_frames();
        value.vst_open_failures = engine->core.vst_open_failures();
        const auto caller_size = status->struct_size;
        std::memcpy(status, &value, std::min<std::size_t>(caller_size, sizeof(value)));
        return SCAE_OK;
    } catch (...) { return SCAE_ENGINE_ERROR; }
}

size_t scae_copy_last_error(const scae_engine *engine, char *destination, size_t capacity) {
    if (engine == nullptr) return 0;
    try {
        size_t required = 0;
        const auto text = engine->api_error.empty() ? engine->core.last_error() : engine->api_error;
        copy_text(text, destination, capacity, required);
        return required;
    } catch (...) { return 0; }
}

size_t scae_copy_last_instrument(const scae_engine *engine, char *destination, size_t capacity) {
    if (engine == nullptr) return 0;
    try {
        size_t required = 0;
        copy_text(engine->core.last_started_instrument(), destination, capacity, required);
        return required;
    } catch (...) { return 0; }
}

} // extern "C"
