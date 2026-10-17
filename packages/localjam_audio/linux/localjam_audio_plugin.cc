// Linux shell for the LocalJam scheduled-audio engine.
//
// Verified by `flutter build linux` (-Wall -Werror) and the example's
// integration tests, run headless in an Ubuntu 24.04 arm64 container with no
// sound card; not yet on real Linux audio hardware. It is deliberately kept as
// close as possible to the stock
// `flutter create --template=plugin --platforms=linux` output, and it contains
// no scheduling, decoding or timing logic at all — all of that lives in
// ../src/localjam_audio_core.{h,cpp}, which IS compiled and run against a real
// audio device by ../src/test/core_test.cpp. What remains here is argument
// decoding, result encoding and thread hopping.
//
// miniaudio picks its backend at runtime: PulseAudio if a server is reachable,
// otherwise ALSA, otherwise JACK. Nothing needs to be linked for that (it is all
// dlopen'd), which is why the CMakeLists only adds dl/pthread/m.
//
// FORMAT SUPPORT: wav, flac, mp3, ogg-vorbis. m4a/aac/alac are not decodable by
// this backend and `load` fails with the "unsupported_format" error code — see
// the FORMATS section of localjam_audio_core.h and README.md.

#include "include/localjam_audio/localjam_audio_plugin.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>

#include <cstring>

#include "localjam_audio_core.h"

#define LOCALJAM_AUDIO_PLUGIN(obj)                                     \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), localjam_audio_plugin_get_type(), \
                              LocaljamAudioPlugin))

// Buffer for the error messages the core writes.
#define LOCALJAM_AUDIO_ERR_LEN 512

struct _LocaljamAudioPlugin {
  GObject parent_instance;
  lj_engine* engine;
  FlEventChannel* event_channel;  // owned reference
  gboolean has_listener;
};

G_DEFINE_TYPE(LocaljamAudioPlugin, localjam_audio_plugin, g_object_get_type())

// ---------------------------------------------------------------- events

// Engine events arrive on the engine's monitor thread; GLib channels may only
// be used from the main loop, so each one is hopped through g_idle_add. The
// payload holds a strong reference to the plugin, so a queued event can never
// outlive it.
typedef struct {
  LocaljamAudioPlugin* self;
  lj_event_kind kind;
  gint64 output_latency_us;
  gboolean has_latency;
  gchar* code;      // owned; non-null for playbackError
  gchar* message;   // owned; non-null for playbackError
  gchar* route_id;  // owned; routeChanged, null when unknown
  gboolean old_device_unavailable;  // routeChanged
} LocaljamAudioEvent;

static gboolean localjam_audio_emit_event(gpointer user_data) {
  LocaljamAudioEvent* event = static_cast<LocaljamAudioEvent*>(user_data);
  LocaljamAudioPlugin* self = event->self;
  if (self->event_channel != nullptr && self->has_listener) {
    g_autoptr(FlValue) payload = fl_value_new_map();
    fl_value_set_string_take(payload, "type",
                             fl_value_new_string(lj_event_type_name(event->kind)));
    if (event->has_latency) {
      fl_value_set_string_take(payload, "outputLatencyUs",
                               fl_value_new_int(event->output_latency_us));
    }
    if (event->code != nullptr) {
      fl_value_set_string_take(payload, "code", fl_value_new_string(event->code));
      fl_value_set_string_take(
          payload, "message",
          fl_value_new_string(event->message != nullptr ? event->message : ""));
    }
    if (event->kind == LJ_EVENT_ROUTE_CHANGED) {
      if (event->route_id != nullptr) {
        fl_value_set_string_take(payload, "routeId",
                                 fl_value_new_string(event->route_id));
      }
      fl_value_set_string_take(
          payload, "oldDeviceUnavailable",
          fl_value_new_bool(event->old_device_unavailable));
    }
    fl_event_channel_send(self->event_channel, payload, nullptr, nullptr);
  }
  g_object_unref(self);
  g_free(event->code);
  g_free(event->message);
  g_free(event->route_id);
  g_free(event);
  return G_SOURCE_REMOVE;
}

// The event's strings only live for the duration of this callback, so they
// are copied into the queued payload.
static void localjam_audio_on_engine_event(void* user_data,
                                           const lj_event* engine_event) {
  LocaljamAudioPlugin* self = LOCALJAM_AUDIO_PLUGIN(user_data);
  LocaljamAudioEvent* event = g_new0(LocaljamAudioEvent, 1);
  event->self = LOCALJAM_AUDIO_PLUGIN(g_object_ref(self));
  event->kind = engine_event->kind;
  event->output_latency_us = engine_event->output_latency_us;
  event->has_latency = engine_event->has_latency != 0 ? TRUE : FALSE;
  event->code = g_strdup(engine_event->code);        // g_strdup(NULL) == NULL
  event->message = g_strdup(engine_event->message);
  event->route_id = g_strdup(engine_event->route_id);
  event->old_device_unavailable =
      engine_event->old_device_unavailable != 0 ? TRUE : FALSE;
  g_idle_add(localjam_audio_emit_event, event);
}

static FlMethodErrorResponse* localjam_audio_listen_cb(FlEventChannel* channel,
                                                       FlValue* args,
                                                       gpointer user_data) {
  (void)channel;
  (void)args;
  LOCALJAM_AUDIO_PLUGIN(user_data)->has_listener = TRUE;
  return nullptr;
}

static FlMethodErrorResponse* localjam_audio_cancel_cb(FlEventChannel* channel,
                                                       FlValue* args,
                                                       gpointer user_data) {
  (void)channel;
  (void)args;
  LOCALJAM_AUDIO_PLUGIN(user_data)->has_listener = FALSE;
  return nullptr;
}

// --------------------------------------------------------------- helpers

// Reads an integer argument. Dart's standard codec may send an int as int32 or
// int64; fl_value_get_int covers both.
static gboolean localjam_audio_get_int(FlValue* args, const gchar* key,
                                       int64_t* out) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_INT) {
    return FALSE;
  }
  *out = fl_value_get_int(value);
  return TRUE;
}

static gboolean localjam_audio_get_double(FlValue* args, const gchar* key,
                                          double* out) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return FALSE;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr) {
    return FALSE;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    *out = fl_value_get_float(value);
    return TRUE;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    *out = static_cast<double>(fl_value_get_int(value));
    return TRUE;
  }
  return FALSE;
}

static const gchar* localjam_audio_get_string(FlValue* args, const gchar* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) {
    return nullptr;
  }
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr || fl_value_get_type(value) != FL_VALUE_TYPE_STRING) {
    return nullptr;
  }
  return fl_value_get_string(value);
}

static FlMethodResponse* localjam_audio_fail(lj_status status,
                                             const gchar* message) {
  return FL_METHOD_RESPONSE(fl_method_error_response_new(
      lj_status_code(status), message, nullptr));
}

static FlMethodResponse* localjam_audio_ok_null() {
  g_autoptr(FlValue) result = fl_value_new_null();
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

static FlMethodResponse* localjam_audio_ok_int(int64_t value) {
  g_autoptr(FlValue) result = fl_value_new_int(value);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// ------------------------------------------------- off-main-loop queries

// probeDuration and currentRouteId touch no engine but block on I/O — a file
// header (mp3: a parse over every frame header), the audio server — so they
// run on GLib's worker pool and answer from the main loop: GTask delivers its
// callback in the main context it was created in. The task holds a reference
// to the plugin and to the method call until then.
typedef struct {
  gchar* path;  // probeDuration; null for currentRouteId
} LocaljamAudioQuery;

static void localjam_audio_value_free(gpointer value) {
  fl_value_unref(static_cast<FlValue*>(value));
}

static void localjam_audio_query_free(gpointer data) {
  LocaljamAudioQuery* query = static_cast<LocaljamAudioQuery*>(data);
  g_free(query->path);
  g_free(query);
}

static void localjam_audio_query_thread(GTask* task, gpointer source_object,
                                        gpointer task_data,
                                        GCancellable* cancellable) {
  (void)source_object;
  (void)cancellable;
  LocaljamAudioQuery* query = static_cast<LocaljamAudioQuery*>(task_data);
  FlValue* result = nullptr;
  if (query->path != nullptr) {
    // Unreadable or unsupported (m4a...) -> null: the duration is unknown,
    // which is not an error for the caller.
    char err[LOCALJAM_AUDIO_ERR_LEN] = {0};
    int64_t duration_us = 0;
    result = lj_probe_duration(query->path, &duration_us, err, sizeof(err)) ==
                     LJ_OK
                 ? fl_value_new_int(duration_us)
                 : fl_value_new_null();
  } else {
    char route[512] = {0};
    result = lj_current_route_id(route, sizeof(route)) != 0
                 ? fl_value_new_string(route)
                 : fl_value_new_null();
  }
  g_task_return_pointer(task, result, localjam_audio_value_free);
}

static void localjam_audio_query_done(GObject* source_object,
                                      GAsyncResult* async_result,
                                      gpointer user_data) {
  (void)source_object;
  FlMethodCall* method_call = FL_METHOD_CALL(user_data);
  g_autoptr(FlValue) result = static_cast<FlValue*>(
      g_task_propagate_pointer(G_TASK(async_result), nullptr));
  g_autoptr(FlValue) null_value = fl_value_new_null();
  g_autoptr(FlMethodResponse) response = FL_METHOD_RESPONSE(
      fl_method_success_response_new(result != nullptr ? result : null_value));
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("localjam_audio: failed to send response: %s", error->message);
  }
  g_object_unref(method_call);
}

static void localjam_audio_run_query(LocaljamAudioPlugin* self,
                                     FlMethodCall* method_call,
                                     const gchar* path) {
  LocaljamAudioQuery* query = g_new0(LocaljamAudioQuery, 1);
  query->path = g_strdup(path);  // g_strdup(NULL) == NULL: currentRouteId
  GTask* task = g_task_new(self, nullptr, localjam_audio_query_done,
                           g_object_ref(method_call));
  g_task_set_task_data(task, query, localjam_audio_query_free);
  g_task_run_in_thread(task, localjam_audio_query_thread);
  g_object_unref(task);
}

// --------------------------------------------------------- method channel

// Returns the response, or null when the call is answered later (a query
// running on a worker thread).
static FlMethodResponse* localjam_audio_handle(LocaljamAudioPlugin* self,
                                               FlMethodCall* method_call) {
  // Everything else runs synchronously on the main loop: every core call is
  // microseconds except `load`, which for mp3 does one parse-only pass to
  // count frames exactly (see localjam_audio_core.h) — and must replace the
  // loaded file before the next call is handled, so it stays here.
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  char err[LOCALJAM_AUDIO_ERR_LEN] = {0};

  // Engine-free methods first: they answer even if the engine could not be
  // created.
  if (strcmp(method, "nowUs") == 0) {
    return localjam_audio_ok_int(lj_now_us());
  }

  if (strcmp(method, "probeDuration") == 0) {
    const gchar* path = localjam_audio_get_string(args, "path");
    if (path == nullptr) {
      return localjam_audio_fail(LJ_ERR_BAD_ARGS,
                                 "probeDuration requires {path: String}");
    }
    localjam_audio_run_query(self, method_call, path);
    return nullptr;
  }

  if (strcmp(method, "currentRouteId") == 0) {
    localjam_audio_run_query(self, method_call, nullptr);
    return nullptr;
  }

  if (self->engine == nullptr) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(
        "disposed", "the audio engine could not be created", nullptr));
  }

  if (strcmp(method, "load") == 0) {
    const gchar* path = localjam_audio_get_string(args, "path");
    if (path == nullptr) {
      return localjam_audio_fail(LJ_ERR_BAD_ARGS, "load requires {path: String}");
    }
    int64_t duration_us = 0;
    lj_status status =
        lj_load(self->engine, path, &duration_us, err, sizeof(err));
    if (status != LJ_OK) {
      return localjam_audio_fail(status, err);
    }
    return localjam_audio_ok_int(duration_us);
  }

  if (strcmp(method, "playAt") == 0) {
    int64_t native_time_us = 0;
    int64_t position_us = 0;
    if (!localjam_audio_get_int(args, "nativeTimeUs", &native_time_us) ||
        !localjam_audio_get_int(args, "positionUs", &position_us)) {
      return localjam_audio_fail(LJ_ERR_BAD_ARGS,
                                 "playAt requires nativeTimeUs and positionUs");
    }
    double rate = 1.0;
    localjam_audio_get_double(args, "rate", &rate);
    lj_status status = lj_play_at(self->engine, native_time_us, position_us,
                                  rate, err, sizeof(err));
    if (status != LJ_OK) {
      return localjam_audio_fail(status, err);
    }
    return localjam_audio_ok_null();
  }

  if (strcmp(method, "pause") == 0) {
    lj_pause(self->engine);
    return localjam_audio_ok_null();
  }

  if (strcmp(method, "stop") == 0) {
    lj_stop(self->engine);
    return localjam_audio_ok_null();
  }

  if (strcmp(method, "positionUs") == 0) {
    int64_t position_us = 0;
    if (lj_position_us(self->engine, &position_us) == 0) {
      // Dart's `Future<int?> positionUs()` expects null when nothing is playing
      // or scheduled.
      return localjam_audio_ok_null();
    }
    return localjam_audio_ok_int(position_us);
  }

  if (strcmp(method, "setRate") == 0) {
    double rate = 0.0;
    if (!localjam_audio_get_double(args, "rate", &rate)) {
      return localjam_audio_fail(LJ_ERR_BAD_ARGS,
                                 "setRate requires {rate: double}");
    }
    lj_status status = lj_set_rate(self->engine, rate, err, sizeof(err));
    if (status != LJ_OK) {
      return localjam_audio_fail(status, err);
    }
    return localjam_audio_ok_null();
  }

  if (strcmp(method, "outputLatencyUs") == 0) {
    return localjam_audio_ok_int(lj_output_latency_us(self->engine));
  }

  if (strcmp(method, "dispose") == 0) {
    lj_destroy(self->engine);
    self->engine = nullptr;
    // Recreate immediately so a later call does not have to error out: dispose
    // releases the device and every schedule, which is all the Dart contract
    // asks for.
    char create_err[LOCALJAM_AUDIO_ERR_LEN] = {0};
    if (lj_create(&self->engine, localjam_audio_on_engine_event, self, nullptr,
                  nullptr, create_err, sizeof(create_err)) != LJ_OK) {
      self->engine = nullptr;
    }
    return localjam_audio_ok_null();
  }

  return FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  (void)channel;
  LocaljamAudioPlugin* self = LOCALJAM_AUDIO_PLUGIN(user_data);
  g_autoptr(FlMethodResponse) response = localjam_audio_handle(self, method_call);
  if (response == nullptr) {
    return;  // answered from the main loop once the worker is done
  }
  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("localjam_audio: failed to send response: %s", error->message);
  }
}

// ------------------------------------------------------------- GObject

static void localjam_audio_plugin_dispose(GObject* object) {
  LocaljamAudioPlugin* self = LOCALJAM_AUDIO_PLUGIN(object);
  // lj_destroy joins the engine's monitor thread, so no further event callback
  // can be in flight once it returns.
  lj_destroy(self->engine);
  self->engine = nullptr;
  g_clear_object(&self->event_channel);
  G_OBJECT_CLASS(localjam_audio_plugin_parent_class)->dispose(object);
}

static void localjam_audio_plugin_class_init(LocaljamAudioPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = localjam_audio_plugin_dispose;
}

static void localjam_audio_plugin_init(LocaljamAudioPlugin* self) {
  char err[LOCALJAM_AUDIO_ERR_LEN] = {0};
  self->engine = nullptr;
  self->event_channel = nullptr;
  self->has_listener = FALSE;
  if (lj_create(&self->engine, localjam_audio_on_engine_event, self, nullptr,
                nullptr, err, sizeof(err)) != LJ_OK) {
    g_warning("localjam_audio: could not create the audio engine: %s", err);
    self->engine = nullptr;
  }
}

void localjam_audio_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  LocaljamAudioPlugin* plugin = LOCALJAM_AUDIO_PLUGIN(
      g_object_new(localjam_audio_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "localjam_audio", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      channel, method_call_cb, g_object_ref(plugin), g_object_unref);

  // Held for the plugin's lifetime because events are pushed onto it, unlike
  // the method channel which only ever receives.
  plugin->event_channel =
      fl_event_channel_new(fl_plugin_registrar_get_messenger(registrar),
                           "localjam_audio/events", FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      plugin->event_channel, localjam_audio_listen_cb, localjam_audio_cancel_cb,
      g_object_ref(plugin), g_object_unref);

  g_object_unref(plugin);
}
