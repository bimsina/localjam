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
  void SetEventWindow(HWND hwnd) { event_window_ = hwnd; }

  // Drains queued engine events to Dart. MUST be called on the platform thread
  // (it is, from the window-proc delegate).
  void DrainEvents();

 private:
  struct QueuedEvent {
    lj_event_kind kind;
    int64_t latency_us;
    bool has_latency;
  };

  // Engine event callback. Runs on the engine's monitor thread — never the
  // audio thread, and never re-entrantly inside an lj_* call.
  static void OnEngineEvent(void* user_data, lj_event_kind kind,
                            int64_t output_latency_us, int has_latency);

  lj_engine* engine_ = nullptr;

  // Written on the platform thread, read there too, but the queue behind it is
  // filled from the monitor thread.
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> sink_;

  std::mutex queue_mutex_;
  std::deque<QueuedEvent> queue_;
  HWND event_window_ = nullptr;
};

}  // namespace localjam_audio

#endif  // FLUTTER_PLUGIN_LOCALJAM_AUDIO_PLUGIN_H_
