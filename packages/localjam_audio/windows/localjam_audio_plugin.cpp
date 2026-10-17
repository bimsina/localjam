// Windows shell for the LocalJam scheduled-audio engine.
//
// NOT YET BUILT WITH MSVC. Written on macOS, where no Windows toolchain exists;
// it (and the core) compile cleanly with MinGW-w64 GCC (-Wall -Wextra -Werror)
// against the Flutter Windows embedder and C++ client-wrapper headers of the
// engine this repo pins, which catches type/name/signature mistakes but is not
// MSVC /W4 /WX and links nothing. It is deliberately kept as close as possible
// to the stock `flutter create --template=plugin --platforms=windows` output,
// and it contains no scheduling, decoding or timing logic at all — all of that
// lives in ../src/localjam_audio_core.{h,cpp}, which IS compiled and run against
// a real audio device by ../src/test/core_test.cpp. What remains here is
// argument decoding, result encoding and thread hopping.
//
// FORMAT SUPPORT: wav, flac, mp3, ogg-vorbis. m4a/aac/alac are not decodable by
// this backend and `load` fails with the "unsupported_format" error code — see
// the FORMATS section of localjam_audio_core.h and README.md.

#include "localjam_audio_plugin.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/event_stream_handler_functions.h>
#include <flutter/flutter_view.h>
#include <flutter/standard_method_codec.h>

#include <deque>
#include <memory>
#include <optional>
#include <string>
#include <utility>
#include <variant>

namespace localjam_audio {

namespace {

// Buffer for the error messages the core writes.
constexpr size_t kErrLen = 512;

// Registered (not hard-coded) so the id is unique process- and system-wide and
// cannot collide with another plugin's WM_APP message. Posted to the top-level
// window whenever the engine has events, so they are delivered to Dart on the
// PLATFORM thread — the only thread a Flutter channel may be used from.
UINT DrainEventsMessage() {
  static const UINT kMessage =
      ::RegisterWindowMessageW(L"LocaljamAudioDrainEvents");
  return kMessage;
}

const flutter::EncodableMap* ArgumentsMap(
    const flutter::MethodCall<flutter::EncodableValue>& call) {
  return std::get_if<flutter::EncodableMap>(call.arguments());
}

// Reads an integer argument that Dart may have encoded as int32 or int64.
bool GetInt(const flutter::EncodableMap* args, const char* key, int64_t* out) {
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  if (const auto* v32 = std::get_if<int32_t>(&it->second)) {
    *out = *v32;
    return true;
  }
  if (const auto* v64 = std::get_if<int64_t>(&it->second)) {
    *out = *v64;
    return true;
  }
  return false;
}

// Reads a double argument; Dart sends `rate` as a double, but accept ints too.
bool GetDouble(const flutter::EncodableMap* args, const char* key,
               double* out) {
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  if (const auto* d = std::get_if<double>(&it->second)) {
    *out = *d;
    return true;
  }
  int64_t as_int = 0;
  if (GetInt(args, key, &as_int)) {
    *out = static_cast<double>(as_int);
    return true;
  }
  return false;
}

bool GetString(const flutter::EncodableMap* args, const char* key,
               std::string* out) {
  if (args == nullptr) {
    return false;
  }
  const auto it = args->find(flutter::EncodableValue(key));
  if (it == args->end()) {
    return false;
  }
  if (const auto* s = std::get_if<std::string>(&it->second)) {
    *out = *s;
    return true;
  }
  return false;
}

void Fail(
    const std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>&
        result,
    lj_status status, const char* message) {
  result->Error(lj_status_code(status), message);
}

}  // namespace

// static
void LocaljamAudioPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto plugin = std::make_unique<LocaljamAudioPlugin>();

  auto channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "localjam_audio",
          &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  auto event_channel =
      std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
          registrar->messenger(), "localjam_audio/events",
          &flutter::StandardMethodCodec::GetInstance());
  event_channel->SetStreamHandler(
      std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
          [plugin_pointer = plugin.get()](
              const flutter::EncodableValue*,
              std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&&
                  events)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            plugin_pointer->SetEventSink(std::move(events));
            return nullptr;
          },
          [plugin_pointer = plugin.get()](const flutter::EncodableValue*)
              -> std::unique_ptr<
                  flutter::StreamHandlerError<flutter::EncodableValue>> {
            plugin_pointer->SetEventSink(nullptr);
            return nullptr;
          }));

  // Cross-thread event delivery. The engine's monitor thread queues events and
  // posts our registered window message to the top-level window; the delegate
  // below then runs on the PLATFORM thread, which is the only thread a Flutter
  // channel may be used from.
  if (flutter::FlutterView* view = registrar->GetView()) {
    plugin->SetEventWindow(::GetAncestor(view->GetNativeWindow(), GA_ROOT));
  }
  registrar->RegisterTopLevelWindowProcDelegate(
      [plugin_pointer = plugin.get()](HWND, UINT message, WPARAM,
                                      LPARAM) -> std::optional<LRESULT> {
        if (message != DrainEventsMessage()) {
          return std::nullopt;
        }
        plugin_pointer->DrainEvents();
        return 0;
      });

  registrar->AddPlugin(std::move(plugin));
  // `channel` and `event_channel` go out of scope here, exactly as in the stock
  // plugin template: SetMethodCallHandler / SetStreamHandler register with the
  // messenger by channel name and the channel object itself is not needed
  // afterwards.
}

LocaljamAudioPlugin::LocaljamAudioPlugin() {
  char err[kErrLen] = {0};
  if (lj_create(&engine_, &LocaljamAudioPlugin::OnEngineEvent, this,
                /*log_cb=*/nullptr, /*log_user_data=*/nullptr, err,
                sizeof(err)) != LJ_OK) {
    engine_ = nullptr;
  }
}

LocaljamAudioPlugin::~LocaljamAudioPlugin() {
  {
    // Late worker-thread queries drop their results from now on.
    std::lock_guard<std::mutex> lock(replies_->mutex);
    replies_->window = nullptr;
    replies_->done.clear();
  }
  lj_destroy(engine_);
  engine_ = nullptr;
}

void LocaljamAudioPlugin::SetEventWindow(HWND hwnd) {
  event_window_ = hwnd;
  std::lock_guard<std::mutex> lock(replies_->mutex);
  replies_->window = hwnd;
}

// static
flutter::EncodableValue LocaljamAudioPlugin::RunQuery(bool route,
                                                      const std::string& path) {
  if (route) {
    char id[512] = {0};
    if (lj_current_route_id(id, sizeof(id)) == 0) {
      return flutter::EncodableValue();
    }
    return flutter::EncodableValue(std::string(id));
  }
  // Touches no engine state. Unreadable or unsupported (m4a...) -> null: the
  // duration is unknown, which is not an error for the caller.
  char err[kErrLen] = {0};
  int64_t duration_us = 0;
  if (lj_probe_duration(path.c_str(), &duration_us, err, sizeof(err)) !=
      LJ_OK) {
    return flutter::EncodableValue();
  }
  return flutter::EncodableValue(duration_us);
}

// static
void CALLBACK LocaljamAudioPlugin::QueryWork(PTP_CALLBACK_INSTANCE instance,
                                             void* context) {
  (void)instance;
  std::unique_ptr<Query> query(static_cast<Query*>(context));
  flutter::EncodableValue value = RunQuery(query->route, query->path);
  HWND window = nullptr;
  {
    std::lock_guard<std::mutex> lock(query->replies->mutex);
    window = query->replies->window;
    if (window == nullptr) {
      return;  // the plugin is gone; the unanswered result is dropped
    }
    query->replies->done.emplace_back(std::move(query->result),
                                      std::move(value));
  }
  ::PostMessageW(window, DrainEventsMessage(), 0, 0);
}

void LocaljamAudioPlugin::StartQuery(Result result, bool route,
                                     std::string path) {
  bool have_window = false;
  {
    std::lock_guard<std::mutex> lock(replies_->mutex);
    have_window = replies_->window != nullptr;
  }
  if (have_window) {
    auto* query = new (std::nothrow) Query();
    if (query != nullptr) {
      query->replies = replies_;
      query->result = std::move(result);
      query->route = route;
      query->path = std::move(path);
      if (::TrySubmitThreadpoolCallback(&LocaljamAudioPlugin::QueryWork, query,
                                        nullptr)) {
        return;
      }
      // No pool thread: take everything back and answer inline.
      result = std::move(query->result);
      path = std::move(query->path);
      delete query;
    }
  }
  result->Success(RunQuery(route, path));
}

void LocaljamAudioPlugin::SetEventSink(
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink) {
  sink_ = std::move(sink);
}

// static
void LocaljamAudioPlugin::OnEngineEvent(void* user_data, const lj_event* event) {
  auto* self = static_cast<LocaljamAudioPlugin*>(user_data);
  if (self == nullptr || event == nullptr) {
    return;
  }
  {
    std::lock_guard<std::mutex> lock(self->queue_mutex_);
    // Bounded: if the view is headless (no HWND to post to) or Dart is not
    // listening, nothing drains this and it must not grow without limit.
    if (self->queue_.size() >= 64) {
      self->queue_.pop_front();
    }
    self->queue_.push_back(QueuedEvent{
        event->kind, event->output_latency_us, event->has_latency != 0,
        event->code != nullptr, event->code == nullptr ? "" : event->code,
        event->message == nullptr ? "" : event->message,
        event->route_id != nullptr,
        event->route_id == nullptr ? "" : event->route_id,
        event->old_device_unavailable != 0});
  }
  if (self->event_window_ != nullptr) {
    ::PostMessageW(self->event_window_, DrainEventsMessage(), 0, 0);
  }
}

void LocaljamAudioPlugin::DrainEvents() {
  std::deque<std::pair<Result, flutter::EncodableValue>> answers;
  {
    std::lock_guard<std::mutex> lock(replies_->mutex);
    answers.swap(replies_->done);
  }
  for (auto& answer : answers) {
    answer.first->Success(answer.second);
  }
  std::deque<QueuedEvent> drained;
  {
    std::lock_guard<std::mutex> lock(queue_mutex_);
    drained.swap(queue_);
  }
  if (!sink_) {
    return;
  }
  for (const QueuedEvent& e : drained) {
    flutter::EncodableMap payload{
        {flutter::EncodableValue("type"),
         flutter::EncodableValue(lj_event_type_name(e.kind))},
    };
    if (e.has_latency) {
      payload[flutter::EncodableValue("outputLatencyUs")] =
          flutter::EncodableValue(e.latency_us);
    }
    if (e.has_error) {
      payload[flutter::EncodableValue("code")] = flutter::EncodableValue(e.code);
      payload[flutter::EncodableValue("message")] =
          flutter::EncodableValue(e.message);
    }
    if (e.kind == LJ_EVENT_ROUTE_CHANGED) {
      if (e.has_route_id) {
        payload[flutter::EncodableValue("routeId")] =
            flutter::EncodableValue(e.route_id);
      }
      payload[flutter::EncodableValue("oldDeviceUnavailable")] =
          flutter::EncodableValue(e.old_device_unavailable);
    }
    sink_->Success(flutter::EncodableValue(payload));
  }
}

void LocaljamAudioPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  // probeDuration and currentRouteId touch no engine but block on I/O (a file
  // header — for mp3 a parse over every frame header — or the audio
  // server), so they run on a thread-pool thread and are answered from the
  // platform thread via the drain message (StartQuery). Everything else runs
  // synchronously here: every core call is microseconds except `load`, which
  // for mp3 does that same parse — and must replace the loaded file before
  // the next call is handled, so it stays on this thread.
  const std::string& method = method_call.method_name();
  const flutter::EncodableMap* args = ArgumentsMap(method_call);
  char err[kErrLen] = {0};

  // Engine-free methods first: they answer even if the engine could not be
  // created.
  if (method == "nowUs") {
    result->Success(flutter::EncodableValue(lj_now_us()));
    return;
  }

  if (method == "probeDuration") {
    std::string path;
    if (!GetString(args, "path", &path)) {
      Fail(result, LJ_ERR_BAD_ARGS, "probeDuration requires {path: String}");
      return;
    }
    StartQuery(std::move(result), /*route=*/false, std::move(path));
    return;
  }

  if (method == "currentRouteId") {
    StartQuery(std::move(result), /*route=*/true, std::string());
    return;
  }

  if (engine_ == nullptr) {
    result->Error("disposed", "the audio engine could not be created");
    return;
  }

  if (method == "load") {
    std::string path;
    if (!GetString(args, "path", &path)) {
      Fail(result, LJ_ERR_BAD_ARGS, "load requires {path: String}");
      return;
    }
    int64_t duration_us = 0;
    const lj_status status =
        lj_load(engine_, path.c_str(), &duration_us, err, sizeof(err));
    if (status != LJ_OK) {
      Fail(result, status, err);
      return;
    }
    result->Success(flutter::EncodableValue(duration_us));
    return;
  }

  if (method == "playAt") {
    int64_t native_time_us = 0;
    int64_t position_us = 0;
    if (!GetInt(args, "nativeTimeUs", &native_time_us) ||
        !GetInt(args, "positionUs", &position_us)) {
      Fail(result, LJ_ERR_BAD_ARGS,
           "playAt requires nativeTimeUs and positionUs");
      return;
    }
    double rate = 1.0;
    GetDouble(args, "rate", &rate);
    const lj_status status =
        lj_play_at(engine_, native_time_us, position_us, rate, err,
                   sizeof(err));
    if (status != LJ_OK) {
      Fail(result, status, err);
      return;
    }
    result->Success();
    return;
  }

  if (method == "pause") {
    lj_pause(engine_);
    result->Success();
    return;
  }

  if (method == "stop") {
    lj_stop(engine_);
    result->Success();
    return;
  }

  if (method == "positionUs") {
    int64_t position_us = 0;
    if (lj_position_us(engine_, &position_us) == 0) {
      // Dart's `Future<int?> positionUs()` expects null when nothing is playing
      // or scheduled: an empty EncodableValue is the standard codec's null.
      result->Success(flutter::EncodableValue());
      return;
    }
    result->Success(flutter::EncodableValue(position_us));
    return;
  }

  if (method == "setRate") {
    double rate = 0.0;
    if (!GetDouble(args, "rate", &rate)) {
      Fail(result, LJ_ERR_BAD_ARGS, "setRate requires {rate: double}");
      return;
    }
    const lj_status status = lj_set_rate(engine_, rate, err, sizeof(err));
    if (status != LJ_OK) {
      Fail(result, status, err);
      return;
    }
    result->Success();
    return;
  }

  if (method == "outputLatencyUs") {
    result->Success(flutter::EncodableValue(lj_output_latency_us(engine_)));
    return;
  }

  if (method == "dispose") {
    lj_destroy(engine_);
    engine_ = nullptr;
    char create_err[kErrLen] = {0};
    // Recreate immediately so a later call does not have to error out: dispose
    // releases the device and every schedule, which is all the Dart contract
    // asks for.
    if (lj_create(&engine_, &LocaljamAudioPlugin::OnEngineEvent, this, nullptr,
                  nullptr, create_err, sizeof(create_err)) != LJ_OK) {
      engine_ = nullptr;
    }
    result->Success();
    return;
  }

  result->NotImplemented();
}

}  // namespace localjam_audio
