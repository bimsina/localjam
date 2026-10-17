/*
 * localjam_audio_internal.h — the PURE decision logic of the shared desktop
 * core (localjam_audio_core.cpp), split out so it can be unit-tested without an
 * audio device or a miniaudio backend: src/test/core_unit_test.cpp drives it
 * with simulated notification sequences and crafted stream parameters.
 *
 * Internal to the plugin. Not part of the C API in localjam_audio_core.h, and
 * header-only (nothing here needs its own translation unit in the Windows/Linux
 * CMake builds).
 */

#ifndef LOCALJAM_AUDIO_INTERNAL_H_
#define LOCALJAM_AUDIO_INTERNAL_H_

#include <stddef.h>
#include <stdint.h>

#include <algorithm>
#include <string>

#include "localjam_audio_core.h"

namespace lj_internal {

// ------------------------------------------------------------ stream limits

// Sample rates a file may declare. Below 4 kHz is the same floor the iOS/macOS
// plugin enforces (AVAudioPlayerNode never sees an IO cycle near 32 Hz); above
// 384 kHz is no music anyone jams to. Both bounds also keep every
// header-derived size below (ring, decode chunk, resampler) small: a crafted
// header claiming 2^32-1 Hz used to size a 1.7 GB decode chunk.
constexpr uint32_t kMinSampleRate = LJ_MIN_SAMPLE_RATE;
constexpr uint32_t kMaxSampleRate = LJ_MAX_SAMPLE_RATE;

inline bool SampleRateOk(uint32_t sample_rate) {
  return sample_rate >= kMinSampleRate && sample_rate <= kMaxSampleRate;
}

// Frame counts beyond this are a crafted header, not a recording (2^37 frames
// is 99 h even at 384 kHz). Same bound as the iOS/macOS plugin, where it keeps
// the scheduleSegment loop short.
inline bool FrameCountOk(uint64_t frames) {
  return frames > 0 && frames <= static_cast<uint64_t>(LJ_MAX_FRAMES);
}

// Sizes of the per-schedule PCM ring and of one decode step into it.
struct StreamSizing {
  size_t ring_frames;
  size_t chunk_frames;
};

// The decoder thread only writes a chunk once the ring has room for ALL of it,
// so a chunk larger than the ring would wait forever — a silent stall while
// the position keeps advancing. Hence chunk <= ring / 2 always, whatever the
// tuning macros or the file claim; and both stay bounded by
// LJ_RING_MAX_BYTES, never by a header value alone.
inline StreamSizing ComputeStreamSizing(uint32_t sample_rate,
                                        uint32_t channels) {
  const size_t ch = channels == 0 ? 1 : static_cast<size_t>(channels);
  const size_t bytes_per_frame = ch * sizeof(float);
  size_t ring = std::min<size_t>(
      static_cast<size_t>(LJ_RING_SECONDS) * static_cast<size_t>(sample_rate),
      static_cast<size_t>(LJ_RING_MAX_BYTES) / bytes_per_frame);
  ring = std::max<size_t>(ring, 2048);
  size_t chunk = std::max<size_t>(1024, static_cast<size_t>(sample_rate) / 20);
  chunk = std::min(chunk, ring / 2);
  return StreamSizing{ring, chunk};
}

// ---------------------------------------------------------------- route ids

// FNV-1a 64, rendered as 16 hex digits: the same hash the iOS/macOS plugin
// applies to port/device UIDs. Deterministic across runs (route ids key
// persisted per-route calibration) and opaque (device ids can embed a
// Bluetooth MAC address).
inline std::string StableHash(const void* data, size_t len) {
  const unsigned char* bytes = static_cast<const unsigned char*>(data);
  uint64_t hash = 0xcbf29ce484222325ULL;
  for (size_t i = 0; i < len; ++i) {
    hash ^= static_cast<uint64_t>(bytes[i]);
    hash *= 0x00000100000001b3ULL;
  }
  static const char kHex[] = "0123456789abcdef";
  std::string out(16, '0');
  for (int i = 15; i >= 0; --i) {
    out[static_cast<size_t>(i)] = kHex[hash & 0xF];
    hash >>= 4;
  }
  return out;
}

// --------------------------------------------------------------- route watch

// How long the output may be down before it counts as gone. Backends reroute by
// STOPPING the stream, re-initialising it on the new device and starting it
// again (miniaudio's WASAPI default-device handling); on Windows the "old
// endpoint unplugged" and "new default endpoint" notifications also arrive
// separately. Only a stop that is not followed by a restart within this window
// means the output went away.
#ifndef LJ_ROUTE_DEBOUNCE_US
#define LJ_ROUTE_DEBOUNCE_US 200000
#endif

enum class DeviceSignal { kStarted, kStopped, kRerouted };

enum class RouteVerdict {
  // Nothing to act on.
  kNone,
  // The output stopped by itself and came back on its own, with no reroute
  // (e.g. a PulseAudio sink suspend/resume). Timing broke across the gap, so
  // the clock model must be re-measured; no event — the route did not change.
  kResumed,
  // The output is running on a (possibly) different device. The caller decides
  // whether the PREVIOUS device still exists: if it does, the user switched
  // outputs (routeChanged, keep playing); if not, it was unplugged and the
  // reroute is the OS falling back to the speaker (stop, routeChanged
  // {oldDeviceUnavailable: true}) — see RerouteLostOldDevice.
  kRerouted,
  // The output stopped by itself and did not come back within the debounce:
  // it went away with nothing to fall back to (or the driver died). Stop, report
  // routeChanged{oldDeviceUnavailable: true}. Latched until Reset.
  kOutputLost,
};

// Pure state machine over the device notifications and the polled device
// state. It owns no device and takes the time as an argument, so the
// notification orderings the backends produce can be replayed in a test.
//
// Fed by the engine's monitor thread: every notification in arrival order
// (OnSignal), then one Poll per tick with the device's own started flag.
class RouteWatch {
 public:
  void Reset() { *this = RouteWatch(); }

  // `expected`: we stopped or closed the device ourselves (never a loss).
  void OnSignal(DeviceSignal signal, int64_t at_us, bool expected) {
    if (lost_) {
      return;
    }
    switch (signal) {
      case DeviceSignal::kStopped:
        if (expected) {
          return;
        }
        stopped_ = true;
        if (down_since_us_ < 0) {
          down_since_us_ = at_us;
        }
        break;
      case DeviceSignal::kStarted:
        stopped_ = false;
        break;
      case DeviceSignal::kRerouted:
        rerouted_ = true;
        break;
    }
  }

  // `device_started`: the device reports itself started. Backends that suspend
  // a stream without changing that state (PulseAudio) still send "stopped",
  // which keeps the output counted as down until "started" arrives.
  RouteVerdict Poll(int64_t now_us, bool device_started) {
    if (lost_) {
      return RouteVerdict::kNone;
    }
    const bool running = device_started && !stopped_;
    if (!running) {
      if (down_since_us_ < 0) {
        // Died without a notification: backends skip "stopped" exactly when
        // the stream died with the hardware.
        down_since_us_ = now_us;
      }
      if (now_us - down_since_us_ >= LJ_ROUTE_DEBOUNCE_US) {
        lost_ = true;
        down_since_us_ = -1;
        rerouted_ = false;
        return RouteVerdict::kOutputLost;
      }
      return RouteVerdict::kNone;
    }
    const bool was_down = down_since_us_ >= 0;
    down_since_us_ = -1;
    if (rerouted_) {
      rerouted_ = false;
      return RouteVerdict::kRerouted;
    }
    return was_down ? RouteVerdict::kResumed : RouteVerdict::kNone;
  }

  // The output is down and the debounce has not decided yet (or it is lost):
  // whatever the callback still renders must not be heard.
  bool down() const { return lost_ || down_since_us_ >= 0 || stopped_; }
  bool lost() const { return lost_; }

 private:
  int64_t down_since_us_ = -1;
  bool stopped_ = false;
  bool rerouted_ = false;
  bool lost_ = false;
};

// After RouteVerdict::kRerouted: did the reroute happen because the previous
// output device went away? Only when we know which device that was and the
// system no longer lists it. Unknown (no snapshot yet) counts as "still there"
// — keep playing — because a false "unplugged" would stop the music for a
// plain output switch.
inline bool RerouteLostOldDevice(bool have_old_device, bool old_device_listed) {
  return have_old_device && !old_device_listed;
}

}  // namespace lj_internal

#endif  // LOCALJAM_AUDIO_INTERNAL_H_
