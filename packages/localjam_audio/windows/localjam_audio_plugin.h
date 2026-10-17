#ifndef FLUTTER_PLUGIN_LOCALJAM_AUDIO_PLUGIN_H_
#define FLUTTER_PLUGIN_LOCALJAM_AUDIO_PLUGIN_H_

#include <windows.h>

#include <flutter/event_channel.h>
#include <flutter/event_sink.h>
#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

#include "localjam_audio_core.h"

namespace localjam_audio {

// Windows shell for the shared engine in src/localjam_audio_core.{h,cpp}.
// Method channel "localjam_audio", event channel "localjam_audio/events" —
// the same contract the iOS/macOS and Android plugins implement.
class LocaljamAudioPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  LocaljamAudioPlugin();
  virtual ~LocaljamAudioPlugin();

  LocaljamAudioPlugin(const LocaljamAudioPlugin&) = delete;
  LocaljamAudioPlugin& operator=(const LocaljamAudioPlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  // Event-channel StreamHandler hooks (platform thread).
  void SetEventSink(
      std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink);

  // Top-level window to post the drain message to; set at registration.
  void SetEventWindow(HWND hwnd);

  // Drains queued engine events — and finished worker-thread queries — to
  // Dart. MUST be called on the platform thread (it is, from the window-proc
  // delegate).
  void DrainEvents();

 private:
  struct QueuedEvent {
    lj_event_kind kind;
    int64_t latency_us;
    bool has_latency;
    bool has_error;  // playbackError: code + message below
    std::string code;
    std::string message;
    bool has_route_id;  // routeChanged: route_id below
    std::string route_id;
    bool old_device_unavailable;  // routeChanged
  };

  using Result = std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  // probeDuration / currentRouteId answers computed on a thread-pool thread,
  // waiting to be sent from the platform thread (the only thread a
  // MethodResult may answer on). Shared with the workers, so a worker that
  // finishes after the plugin is gone finds `window` null and drops its
  // result instead of touching a dead plugin.
  struct Replies {
    std::mutex mutex;
    HWND window = nullptr;
    std::deque<std::pair<Result, flutter::EncodableValue>> done;
  };

  // One query for the thread pool; owns the pending result.
  struct Query {
    std::shared_ptr<Replies> replies;
    Result result;
    bool route = false;  // currentRouteId; otherwise probeDuration of `path`
    std::string path;
  };

  static flutter::EncodableValue RunQuery(bool route, const std::string& path);
  static void CALLBACK QueryWork(PTP_CALLBACK_INSTANCE instance, void* context);
  // Runs RunQuery off the platform thread and answers `result` later; runs it
  // inline when there is no window to wake up (headless) or no pool thread.
  void StartQuery(Result result, bool route, std::string path);

  // Engine event callback. Runs on the engine's monitor thread — never the
  // audio thread, and never re-entrantly inside an lj_* call. Copies the
  // event's strings (they die with the callback).
  static void OnEngineEvent(void* user_data, const lj_event* event);

  lj_engine* engine_ = nullptr;

  // Written on the platform thread, read there too, but the queue behind it is
  // filled from the monitor thread.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  std::mutex queue_mutex_;
  std::deque<QueuedEvent> queue_;
  HWND event_window_ = nullptr;

  std::shared_ptr<Replies> replies_ = std::make_shared<Replies>();
};

}  // namespace localjam_audio

#endif  // FLUTTER_PLUGIN_LOCALJAM_AUDIO_PLUGIN_H_
