#ifndef SC_APP_ENGINE_H
#define SC_APP_ENGINE_H

#include <stddef.h>
#include <stdint.h>

#if defined(_WIN32)
#  if defined(SCAE_BUILDING_LIBRARY)
#    define SCAE_API __declspec(dllexport)
#  else
#    define SCAE_API __declspec(dllimport)
#  endif
#else
#  define SCAE_API __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C" {
#endif

#define SCAE_ABI_VERSION 1u

typedef struct scae_engine scae_engine;

typedef enum scae_result {
    SCAE_OK = 0,
    SCAE_INVALID_ARGUMENT = -1,
    SCAE_OUT_OF_MEMORY = -2,
    SCAE_NOT_READY = -3,
    SCAE_IO_ERROR = -4,
    SCAE_ENGINE_ERROR = -5,
    SCAE_ABI_MISMATCH = -6
} scae_result;

typedef struct scae_config {
    uint32_t struct_size;
    uint32_t abi_version;
    double sample_rate;
    uint32_t maximum_callback_frames;
    const char *runtime_root;
    const char *synthdefs_directory;
    double output_latency_seconds;
    float master_level;
} scae_config;

typedef struct scae_parameter {
    const char *name;
    float value;
} scae_parameter;

typedef struct scae_status {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t ready;
    uint32_t render_worker_realtime;
    double sample_rate;
    int32_t synthdef_count;
    int32_t active_voices;
    int32_t vst_host_node;
    int32_t vst_open_state;
    uint32_t vst_ready;
    float meter_left;
    float meter_right;
    uint64_t rendered_frames;
    uint64_t audio_callbacks;
    uint64_t queue_depth;
    uint64_t queue_peak;
    uint64_t dropped_packets;
    uint64_t render_failures;
    uint64_t invalid_parameters;
    uint64_t invalid_instruments;
    uint64_t node_end_notifications;
    uint64_t dropped_node_notifications;
    uint64_t render_deadline_misses;
    uint64_t max_render_time_usec;
    uint64_t audio_buffer_underruns;
    uint64_t render_worker_overruns;
    uint64_t max_worker_render_time_usec;
    uint64_t render_ahead_frames;
    uint64_t render_ahead_target_frames;
    uint64_t maximum_callback_frames;
    uint64_t vst_open_failures;
} scae_status;

SCAE_API uint32_t scae_abi_version(void);
SCAE_API const char *scae_version_string(void);

SCAE_API scae_engine *scae_create(void);
SCAE_API void scae_destroy(scae_engine *engine);

/* Starts the complete engine, loads every .scd file in sorted order, primes
   the render worker, and returns only when the engine is ready for callbacks. */
SCAE_API scae_result scae_start(scae_engine *engine, const scae_config *config);
SCAE_API void scae_stop(scae_engine *engine);
SCAE_API uint32_t scae_is_ready(const scae_engine *engine);

/* Realtime callback entry point. `interleaved_stereo` contains L,R float
   pairs and must hold `frames * 2` values. One audio thread may call this at a
   time. It never throws across the C boundary. */
SCAE_API uint32_t scae_render_interleaved(
    scae_engine *engine, float *interleaved_stereo, uint32_t frames);

/* Call periodically from a non-audio/control thread. */
SCAE_API void scae_maintenance(scae_engine *engine);

SCAE_API int32_t scae_note(
    scae_engine *engine,
    const char *instrument,
    float pitch,
    float velocity,
    float duration_beats,
    float position_x,
    float position_y,
    const scae_parameter *parameters,
    uint32_t parameter_count);
SCAE_API int32_t scae_trigger(
    scae_engine *engine, const char *name, float position_x, float position_y);
SCAE_API int32_t scae_control(
    scae_engine *engine, const char *target, const char *parameter, float value);
SCAE_API int32_t scae_control_node(
    scae_engine *engine, int32_t node_id, const char *parameter, float value);
SCAE_API void scae_set_transport(
    scae_engine *engine, double bpm, uint64_t tick, uint32_t playing);
SCAE_API void scae_set_master_level(scae_engine *engine, float level);
SCAE_API void scae_panic(scae_engine *engine);

SCAE_API scae_result scae_load_synthdefs_file(scae_engine *engine, const char *path);
SCAE_API scae_result scae_load_synthdef(
    scae_engine *engine, const char *name, const char *source);

SCAE_API int32_t scae_start_vst_host(
    scae_engine *engine, const char *synthdef, const char *plugin_path);
SCAE_API uint32_t scae_vst_midi(
    scae_engine *engine, int32_t node_id, int status, int data1, int data2, float detune);
SCAE_API uint32_t scae_vst_all_notes_off(scae_engine *engine, int32_t node_id);

SCAE_API scae_result scae_get_status(const scae_engine *engine, scae_status *status);
SCAE_API size_t scae_copy_last_error(const scae_engine *engine, char *destination, size_t capacity);
SCAE_API size_t scae_copy_last_instrument(
    const scae_engine *engine, char *destination, size_t capacity);

#ifdef __cplusplus
}
#endif

#endif
