/*
 * localjam_audio_core.cpp — implementation of the shared scheduling engine.
 * The design rationale (clock domain, silence priming, the maturity gate, the
 * position formula, the rate/pitch trade-off, format support, threading) is all
 * in localjam_audio_core.h; this file assumes you have read it.
 */

#include "localjam_audio_core.h"

#include "localjam_audio_internal.h"
#include "localjam_audio_third_party.h"

#include <algorithm>
#include <atomic>
#include <cctype>
#include <chrono>
#include <cmath>
#include <condition_variable>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

// ---------------------------------------------------------------- utilities

int64_t NowUs() {
  // std::chrono::steady_clock is the documented scheduling timebase: it is
  // CLOCK_MONOTONIC on Linux and QueryPerformanceCounter on Windows, and is
  // never perturbed by wall-clock adjustments. Every timestamp in this file
  // lives in this one domain.
  return std::chrono::duration_cast<std::chrono::microseconds>(
             std::chrono::steady_clock::now().time_since_epoch())
      .count();
}

void SetErr(char* err, size_t err_len, const char* fmt, ...) {
  if (err == nullptr || err_len == 0) {
    return;
  }
  va_list args;
  va_start(args, fmt);
  vsnprintf(err, err_len, fmt, args);
  va_end(args);
}

int64_t RoundToI64(double v) { return static_cast<int64_t>(std::llround(v)); }

// Releases an already-held mutex for a scope and re-takes it on the way out.
// Used around the miniaudio calls that block on the audio thread.
class ReverseLock {
 public:
  explicit ReverseLock(std::mutex& mutex) : mutex_(mutex) { mutex_.unlock(); }
  ~ReverseLock() { mutex_.lock(); }
  ReverseLock(const ReverseLock&) = delete;
  ReverseLock& operator=(const ReverseLock&) = delete;

 private:
  std::mutex& mutex_;
};

// ----------------------------------------------------------------- decoder

enum class Codec { kUnknown, kWav, kFlac, kMp3, kVorbis, kUnsupported };

// The MPEG Layer III synthesis delay (528 + 1 frames) that every gapless
// decoder removes from the start of the stream.
constexpr uint64_t kMp3DecoderDelay = 529;

// What magic-byte sniffing found, for error messages.
struct Probe {
  Codec codec = Codec::kUnknown;
  const char* container = "unknown";
};

bool HasPrefix(const unsigned char* buf, size_t len, size_t at,
               const char* magic) {
  const size_t n = std::strlen(magic);
  return len >= at + n && std::memcmp(buf + at, magic, n) == 0;
}

const char* ContainerName(Codec codec) {
  switch (codec) {
    case Codec::kWav:
      return "wav";
    case Codec::kFlac:
      return "flac";
    case Codec::kMp3:
      return "mp3";
    case Codec::kVorbis:
      return "ogg";
    default:
      return "unknown";
  }
}

// Magic-byte sniffing first, extension only as a fallback: a mislabelled
// extension must not send the wrong decoder at a file, and an m4a must be
// recognised as m4a (rather than "load_failed") so the caller gets the
// actionable "unsupported_format" answer.
Probe SniffFile(const char* path) {
  Probe probe;
  unsigned char head[64] = {0};
  size_t read = 0;
  if (FILE* f = std::fopen(path, "rb")) {
    read = std::fread(head, 1, sizeof(head), f);
    std::fclose(f);
  }

  if (HasPrefix(head, read, 0, "RIFF") && HasPrefix(head, read, 8, "WAVE")) {
    return {Codec::kWav, "wav"};
  }
  if (HasPrefix(head, read, 0, "fLaC")) {
    return {Codec::kFlac, "flac"};
  }
  if (HasPrefix(head, read, 0, "OggS")) {
    // Could be Opus or Speex in an Ogg container; stb_vorbis will reject those
    // and we surface it as unsupported_format below.
    return {Codec::kVorbis, "ogg"};
  }
  if (HasPrefix(head, read, 0, "ID3") ||
      (read >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0)) {
    return {Codec::kMp3, "mp3"};
  }
  // ISO base media (m4a/mp4/alac) — recognised precisely so the error can name
  // it. See the "FORMATS" section of the header for why it is not decoded here.
  if (HasPrefix(head, read, 4, "ftyp")) {
    return {Codec::kUnsupported, "m4a/mp4 (AAC or ALAC)"};
  }
  if (read >= 4 && head[0] == 0x30 && head[1] == 0x26 && head[2] == 0xB2 &&
      head[3] == 0x75) {
    return {Codec::kUnsupported, "asf/wma"};
  }
  if (HasPrefix(head, read, 0, "FORM") || HasPrefix(head, read, 0, ".snd")) {
    return {Codec::kUnsupported, "aiff/au"};
  }

  // Extension fallback for headerless or oddly-tagged files.
  const std::string p(path == nullptr ? "" : path);
  const size_t dot = p.find_last_of('.');
  if (dot != std::string::npos) {
    std::string ext = p.substr(dot + 1);
    for (char& c : ext) {
      c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    }
    if (ext == "wav" || ext == "wave") return {Codec::kWav, "wav"};
    if (ext == "flac") return {Codec::kFlac, "flac"};
    if (ext == "mp3") return {Codec::kMp3, "mp3"};
    if (ext == "ogg" || ext == "oga") return {Codec::kVorbis, "ogg"};
    if (ext == "m4a" || ext == "mp4" || ext == "aac" || ext == "m4b") {
      return {Codec::kUnsupported, "m4a/aac"};
    }
    if (ext == "wma") return {Codec::kUnsupported, "wma"};
    if (ext == "aiff" || ext == "aif") return {Codec::kUnsupported, "aiff"};
    if (ext == "opus") return {Codec::kUnsupported, "opus"};
  }
  return probe;
}

// Thin uniform wrapper over the four vendored decoders. All of them expose
// exactly what the engine needs — sample rate, channels, exact total frame
// count, frame-accurate seek, and f32 interleaved reads — so no decoded audio
// is ever buffered beyond the ring.
class Decoder {
 public:
  ~Decoder() { Close(); }

  bool Open(const char* path, Codec codec, std::string* error) {
    Close();
    codec_ = codec;
    switch (codec) {
      case Codec::kWav:
        if (!drwav_init_file(&wav_, path, nullptr)) {
          *error = "dr_wav could not open the file";
          return false;
        }
        open_ = true;
        sample_rate_ = wav_.sampleRate;
        channels_ = wav_.channels;
        total_frames_ = wav_.totalPCMFrameCount;
        break;
      case Codec::kFlac:
        flac_ = drflac_open_file(path, nullptr);
        if (flac_ == nullptr) {
          *error = "dr_flac could not open the file";
          return false;
        }
        open_ = true;
        sample_rate_ = flac_->sampleRate;
        channels_ = flac_->channels;
        total_frames_ = flac_->totalPCMFrameCount;
        break;
      case Codec::kMp3:
        if (!drmp3_init_file(&mp3_, path, nullptr)) {
          *error = "dr_mp3 could not open the file";
          return false;
        }
        open_ = true;
        sample_rate_ = mp3_.sampleRate;
        channels_ = mp3_.channels;
        // The only O(file) step in load: a parse-only pass over the frame
        // headers (no decoding) that yields an EXACT frame count. mp3 has no
        // reliable duration field, and every µs of the anchor formula depends
        // on the count being right.
        total_frames_ = drmp3_get_pcm_frame_count(&mp3_);
        // Media frame P is the gapless frame P on every platform (README
        // "Media position"). dr_mp3 applies a LAME tag (its delay then
        // includes the 529-frame decoder delay), but without one it keeps
        // the decoder delay, which Android's and Apple's decoders drop:
        // drop it here too, or every frame plays 529 frames late against
        // them (measured against the source, before and after).
        if (mp3_.delayInPCMFrames == 0 && total_frames_ > kMp3DecoderDelay) {
          mp3_.delayInPCMFrames = kMp3DecoderDelay;
          total_frames_ -= kMp3DecoderDelay;
        }
        break;
      case Codec::kVorbis: {
        int err = 0;
        vorbis_ = stb_vorbis_open_filename(path, &err, nullptr);
        if (vorbis_ == nullptr) {
          *error =
              "stb_vorbis could not open the file (Ogg Opus and Ogg Speex are "
              "not Vorbis and are not supported)";
          return false;
        }
        open_ = true;
        const stb_vorbis_info info = stb_vorbis_get_info(vorbis_);
        sample_rate_ = info.sample_rate;
        channels_ = static_cast<uint32_t>(info.channels);
        total_frames_ = stb_vorbis_stream_length_in_samples(vorbis_);
        break;
      }
      default:
        *error = "no decoder for this codec";
        return false;
    }
    if (sample_rate_ == 0 || channels_ == 0 || total_frames_ == 0) {
      *error = "decoder reported an empty or malformed stream";
      Close();
      return false;
    }
    if (channels_ > 2) {
      *error = "only mono and stereo files are supported";
      Close();
      return false;
    }
    // Header values are untrusted (peers upload files to a host): every size
    // the engine derives from them — ring, decode chunk, resampler — must stay
    // bounded. Same limits as iOS/macOS (see LJ_MIN_SAMPLE_RATE).
    if (!lj_internal::SampleRateOk(sample_rate_)) {
      *error = "unsupported sample rate (" + std::to_string(sample_rate_) +
               " Hz; supported " + std::to_string(LJ_MIN_SAMPLE_RATE) + "-" +
               std::to_string(LJ_MAX_SAMPLE_RATE) + " Hz)";
      Close();
      return false;
    }
    if (!lj_internal::FrameCountOk(total_frames_)) {
      *error = "the stream declares an implausible length (" +
               std::to_string(total_frames_) + " frames)";
      Close();
      return false;
    }
    return true;
  }

  void Close() {
    if (!open_) {
      return;
    }
    switch (codec_) {
      case Codec::kWav:
        drwav_uninit(&wav_);
        break;
      case Codec::kFlac:
        drflac_close(flac_);
        flac_ = nullptr;
        break;
      case Codec::kMp3:
        drmp3_uninit(&mp3_);
        break;
      case Codec::kVorbis:
        stb_vorbis_close(vorbis_);
        vorbis_ = nullptr;
        break;
      default:
        break;
    }
    open_ = false;
  }

  bool Seek(uint64_t frame) {
    switch (codec_) {
      case Codec::kWav:
        return drwav_seek_to_pcm_frame(&wav_, frame) != 0;
      case Codec::kFlac:
        return drflac_seek_to_pcm_frame(flac_, frame) != 0;
      case Codec::kMp3:
        return drmp3_seek_to_pcm_frame(&mp3_, frame) != 0;
      case Codec::kVorbis:
        return stb_vorbis_seek(vorbis_, static_cast<unsigned int>(frame)) != 0;
      default:
        return false;
    }
  }

  // Returns frames actually read; a short read means end of stream.
  uint64_t Read(float* out, uint64_t frames) {
    switch (codec_) {
      case Codec::kWav:
        return drwav_read_pcm_frames_f32(&wav_, frames, out);
      case Codec::kFlac:
        return drflac_read_pcm_frames_f32(flac_, frames, out);
      case Codec::kMp3:
        return drmp3_read_pcm_frames_f32(&mp3_, frames, out);
      case Codec::kVorbis: {
        const int got = stb_vorbis_get_samples_float_interleaved(
            vorbis_, static_cast<int>(channels_), out,
            static_cast<int>(frames * channels_));
        return got < 0 ? 0 : static_cast<uint64_t>(got);
      }
      default:
        return 0;
    }
  }

  uint32_t sample_rate() const { return sample_rate_; }
  uint32_t channels() const { return channels_; }
  uint64_t total_frames() const { return total_frames_; }

 private:
  Codec codec_ = Codec::kUnknown;
  bool open_ = false;
  uint32_t sample_rate_ = 0;
  uint32_t channels_ = 0;
  uint64_t total_frames_ = 0;

  drwav wav_{};
  drmp3 mp3_{};
  drflac* flac_ = nullptr;
  stb_vorbis* vorbis_ = nullptr;
};

// -------------------------------------------------------------------- ring

// Bounded single-producer / single-consumer PCM ring (f32 interleaved) between
// the decoder thread and the device callback. The consumer (audio thread) NEVER
// blocks and never allocates: a starved read returns short and the callback
// emits silence for the remainder, which is a glitch but leaves the frame<->time
// anchor math untouched. The producer sleeps when full — that is both the
// backpressure that bounds memory and the mechanism that parks the decoder
// while paused.
class PcmRing {
 public:
  PcmRing(size_t frames, uint32_t channels)
      : channels_(channels), cap_frames_(frames), data_(frames * channels) {}

  size_t capacity_frames() const { return cap_frames_; }

  size_t available() const {
    return static_cast<size_t>(write_.load(std::memory_order_acquire) -
                               read_.load(std::memory_order_relaxed));
  }

  size_t space() const { return cap_frames_ - available(); }

  // Producer. Returns frames written (may be short when nearly full).
  size_t Write(const float* src, size_t frames) {
    const size_t n = std::min(frames, space());
    const uint64_t w = write_.load(std::memory_order_relaxed);
    for (size_t done = 0; done < n;) {
      const size_t idx = static_cast<size_t>((w + done) % cap_frames_);
      const size_t run = std::min(n - done, cap_frames_ - idx);
      std::memcpy(&data_[idx * channels_], src + done * channels_,
                  run * channels_ * sizeof(float));
      done += run;
    }
    write_.store(w + n, std::memory_order_release);
    return n;
  }

  // Consumer (audio thread). Returns frames read.
  size_t Read(float* dst, size_t frames) {
    const size_t n = std::min(frames, available());
    const uint64_t r = read_.load(std::memory_order_relaxed);
    for (size_t done = 0; done < n;) {
      const size_t idx = static_cast<size_t>((r + done) % cap_frames_);
      const size_t run = std::min(n - done, cap_frames_ - idx);
      std::memcpy(dst + done * channels_, &data_[idx * channels_],
                  run * channels_ * sizeof(float));
      done += run;
    }
    read_.store(r + n, std::memory_order_release);
    return n;
  }

  void SetEos() { eos_.store(true, std::memory_order_release); }
  bool eos() const { return eos_.load(std::memory_order_acquire); }

  // Never throws: it is the decoder thread's last resort, including when the
  // failure being reported is an allocation failure.
  void SetError(const char* why) noexcept {
    if (!failed_.load(std::memory_order_acquire)) {
      try {
        error_ = why;
      } catch (...) {
        // Out of memory even for the message: the flag alone still fails the
        // schedule (as decode_failed with an empty message).
      }
      failed_.store(true, std::memory_order_release);
    }
    SetEos();
  }
  bool failed() const { return failed_.load(std::memory_order_acquire); }
  const std::string& error() const { return error_; }

 private:
  uint32_t channels_;
  size_t cap_frames_;
  std::vector<float> data_;
  std::atomic<uint64_t> write_{0};
  std::atomic<uint64_t> read_{0};
  std::atomic<bool> eos_{false};
  std::atomic<bool> failed_{false};
  std::string error_;
};

// ---------------------------------------------------------------- schedule

struct LoadedFile {
  std::string path;
  Codec codec = Codec::kUnknown;
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  uint64_t total_frames = 0;
  int64_t duration_us = 0;
};

// One lj_play_at. Immutable identity plus the mutable mapping fields; all of it
// is guarded by the engine mutex except the ring (its own atomics) and the
// retire flag (atomic, so the decoder thread can exit without the mutex — which
// is what lets the control path join it while holding nothing the audio thread
// needs).
struct Schedule {
  uint64_t generation = 0;

  // --- anchor (immutable once installed)
  int64_t target_us = 0;       // effective anchor instant (>= now + MIN_LEAD)
  int64_t anchor_media_us = 0; // 'P', frame-exact
  uint64_t start_frame = 0;    // media source frame at P
  uint32_t src_rate = 0;
  uint32_t channels = 0;

  // --- mutable mapping
  double rate = 1.0;
  int64_t silence_frames = -1;    // 'S', output-frame index of the first media
                                  // frame; -1 until the clock model matures
  bool skip_resolved = false;     // S frozen, overshoot trim decided
  int64_t media_skip_out = 0;     // overshoot: output frames of media trimmed
  int64_t first_media_out_frame = -1;
  int64_t pending_src_skip = 0;   // source frames still to drop for the trim
  bool media_started = false;
  int64_t end_out_frame = -1;     // output index one past the last media frame
  int64_t underrun_frames = 0;
  // Set on the audio thread, which must not allocate: `failure` is a string
  // literal there, or NULL when the reason is the ring's own error message.
  bool failed = false;
  const char* failure = nullptr;
  bool start_error_logged = false;

  // Set by the audio thread, printed by the monitor thread: the callback must
  // never call the log sink (it can block on a pipe or a lock).
  bool prime_pending = false;
  int64_t prime_origin_us = 0;
  int64_t prime_w = 0;

  // --- resampler feed (audio thread only, preallocated)
  ma_resampler resampler{};
  bool resampler_ready = false;
  std::vector<float> feed;
  size_t feed_frames = 0;

  std::unique_ptr<PcmRing> ring;
  std::atomic<bool> retired{false};
  std::thread decoder_thread;
};

// The device-callback clock model: the line W(t) = (t - origin) * rate / 1e6
// through the (frames handed over, callback time) pairs, plus the maturity gate
// that keeps the start-up prefill burst out of it. See the header.
struct ClockModel {
  int callbacks = 0;
  int64_t first_cb_us = 0;
  int64_t first_cb_frames = 0;
  bool mature = false;
  bool origin_valid = false;
  int64_t origin_us = 0;      // running minimum — the best estimate
  int64_t origin_max_us = 0;  // running maximum — jitter spread, logged only
  int mature_samples = 0;

  void Reset() { *this = ClockModel(); }

  // `frames` = output frames handed over BEFORE this callback, `now` = callback
  // entry time.
  void Observe(int64_t frames, int64_t now, uint32_t dev_rate) {
    if (dev_rate == 0) {
      return;
    }
    if (callbacks == 0) {
      first_cb_us = now;
      first_cb_frames = frames;
    }
    ++callbacks;
    if (!mature) {
      const int64_t span = now - first_cb_us;
      if (callbacks >= LJ_MATURITY_CALLBACKS && span >= LJ_MATURITY_SPAN_US) {
        // Implied consumption rate over the span must look like real-time
        // playback; during the prefill burst it is many times dev_rate.
        const double implied =
            static_cast<double>(frames - first_cb_frames) * 1e6 / span;
        if (implied > dev_rate * 0.5 && implied < dev_rate * 2.0) {
          mature = true;
        } else {
          // Re-base and keep waiting rather than dragging the burst along.
          first_cb_us = now;
          first_cb_frames = frames;
        }
      }
    }
    if (!mature) {
      return;
    }
    const int64_t candidate =
        now - RoundToI64(static_cast<double>(frames) * 1e6 / dev_rate);
    if (!origin_valid) {
      origin_valid = true;
      origin_us = candidate;
      origin_max_us = candidate;
    } else {
      // Minimum, not average: the device asks for frames when it needs them, so
      // jitter can only DELAY a callback, never advance it. The smallest
      // observed intercept is therefore the closest to the true one.
      origin_us = std::min(origin_us, candidate);
      origin_max_us = std::max(origin_max_us, candidate);
    }
    ++mature_samples;
  }

  // Output-frame index being presented at the output at `now`.
  double PresentedFrame(int64_t now, uint32_t dev_rate,
                        int64_t latency_frames) const {
    return static_cast<double>(now - origin_us) * dev_rate / 1e6 -
           static_cast<double>(latency_frames);
  }
};

enum class State { kIdle, kLoaded, kPlaying, kPaused, kFinished };

struct PendingEvent {
  lj_event_kind kind;
  int64_t latency_us;
  int has_latency;
  std::string code;     // playbackError only
  std::string message;  // playbackError only
  std::string route_id;  // routeChanged only; empty = unknown
  int old_device_unavailable;  // routeChanged only
};

// One device notification, queued by the (lock-free) notification handler for
// the monitor thread, which feeds it to the RouteWatch in arrival order.
struct DeviceSignalRecord {
  lj_internal::DeviceSignal signal;
  int64_t at_us;
  bool expected;    // stop_expected_pub at the time: we were closing it
  uint64_t epoch;   // which opened device it came from
};

// The system's default playback device as seen at some instant, through a
// private miniaudio context (see QuerySystemRoutes).
struct RouteSnapshot {
  bool valid = false;
  std::string key;       // the backend's device id, else its name
  std::string route_id;  // "<backend>:<hash(key)>"
};

// Identity of a device for the "is it still there" question and for route ids:
// the backend's own id (WASAPI endpoint id, PulseAudio sink name, CoreAudio
// UID, ALSA hw id) with the union's zero padding trimmed, so the key does not
// depend on miniaudio's union size; the name only when a backend leaves the id
// empty.
std::string DeviceKey(const ma_device_info& info) {
  const unsigned char* bytes = reinterpret_cast<const unsigned char*>(&info.id);
  size_t n = sizeof(info.id);
  while (n > 0 && bytes[n - 1] == 0) {
    --n;
  }
  if (n > 0) {
    return "id:" + std::string(reinterpret_cast<const char*>(bytes), n);
  }
  return std::string("name:") + info.name;
}

struct RouteEnumState {
  const std::string* wanted = nullptr;
  bool wanted_listed = false;
  bool have_default = false;
  ma_device_info default_info{};
};

ma_bool32 RouteEnumCallback(ma_context* context, ma_device_type type,
                            const ma_device_info* info, void* user) {
  (void)context;
  auto* state = static_cast<RouteEnumState*>(user);
  if (type != ma_device_type_playback || info == nullptr || state == nullptr) {
    return MA_TRUE;
  }
  try {
    if (state->wanted != nullptr && !state->wanted_listed &&
        DeviceKey(*info) == *state->wanted) {
      state->wanted_listed = true;
    }
  } catch (...) {
    state->wanted_listed = true;  // could not tell: "still there"
  }
  if (info->isDefault && !state->have_default) {
    state->default_info = *info;
    state->have_default = true;
  }
  return MA_TRUE;
}

// Asks the audio server which playback device is the default and, when
// `old_key` is given, whether that device is still among the active ones
// (*old_listed; true when that cannot be determined). Uses a private,
// throwaway miniaudio context: no engine or device is touched, so it is safe on
// any thread — but it blocks on the server, so never on a UI thread and never
// with the engine mutex held.
RouteSnapshot QuerySystemRoutes(const std::string* old_key, bool* old_listed) {
  RouteSnapshot snapshot;
  if (old_listed != nullptr) {
    *old_listed = true;
  }
  ma_context context;
  if (ma_context_init(nullptr, 0, nullptr, &context) != MA_SUCCESS) {
    return snapshot;
  }
  // Uninitialised on every way out, the exceptional ones included.
  struct ContextGuard {
    ma_context* context;
    ~ContextGuard() { ma_context_uninit(context); }
  } guard{&context};
  try {
    RouteEnumState state;
    state.wanted = old_key;
    const ma_result enumerated =
        ma_context_enumerate_devices(&context, RouteEnumCallback, &state);
    if (!state.have_default) {
      ma_device_info info;
      if (ma_context_get_device_info(&context, ma_device_type_playback,
                                     nullptr, &info) == MA_SUCCESS &&
          info.name[0] != '\0') {
        state.default_info = info;
        state.have_default = true;
      }
    }
    if (state.have_default) {
      snapshot.valid = true;
      snapshot.key = DeviceKey(state.default_info);
      snapshot.route_id =
          std::string(ma_get_backend_name(context.backend)) + ":" +
          lj_internal::StableHash(snapshot.key.data(), snapshot.key.size());
    }
    if (old_listed != nullptr && old_key != nullptr &&
        enumerated == MA_SUCCESS) {
      *old_listed = state.wanted_listed;
    }
  } catch (...) {
    snapshot = RouteSnapshot();
  }
  return snapshot;
}

}  // namespace

// ------------------------------------------------------------------- engine

struct lj_engine {
  lj_event_cb event_cb = nullptr;
  void* event_user = nullptr;
  lj_log_cb log_cb = nullptr;
  void* log_user = nullptr;

  lj_tap_cb tap = nullptr;
  void* tap_user = nullptr;

  std::mutex mtx;
  State state = State::kIdle;
  LoadedFile loaded;

  // The device outlives individual schedules on purpose. Keeping it open means
  // the clock model stays MATURE across stop/pause/re-schedule, so the second
  // and later lj_play_at calls (which is what a jam session does constantly —
  // every §5.4 hard resync is one) prime against an already-settled mapping
  // instead of paying the start-up warm-up again. It is re-created only when a
  // newly loaded file needs a different channel count.
  ma_device device{};
  bool device_open = false;
  bool device_started = false;
  uint32_t dev_rate = 0;
  uint32_t dev_channels = 0;
  int64_t latency_frames = 0;
  int64_t out_frames_written = 0;  // 'W'
  ClockModel clock;

  // Re-measuring the device clock after the output moved or resumed (see
  // "Routes" in the header). The callback timeline has a gap there, so the old
  // origin is stale; a fresh model matures alongside it and replaces it — with
  // the new route's latency — once mature. Until then, a schedule still
  // priming holds its silence instead of starting media on the stale mapping.
  bool rebase_pending = false;
  ClockModel rebase;
  int64_t rebase_latency_frames = 0;

  std::unique_ptr<Schedule> sched;
  uint64_t generation = 0;

  // The event queue has its OWN mutex, and everything the device notification
  // handler needs is published as an atomic. That is not tidiness:
  // ma_device_start/ma_device_uninit fire notifications SYNCHRONOUSLY on the
  // calling thread, and backends fire them from their own threads mid-reroute,
  // so a notification handler that took `mtx` would deadlock against the very
  // lj_play_at that started the device. Lock order is always
  // mtx -> events_mtx, never the reverse.
  std::mutex events_mtx;
  std::deque<PendingEvent> events;
  std::deque<DeviceSignalRecord> signals;  // guarded by events_mtx
  std::atomic<bool> published_playing{false};
  std::atomic<bool> stop_expected_pub{true};
  // Which opened device notifications belong to; bumped per open.
  std::atomic<uint64_t> device_epoch_pub{0};
  // Silences the callback's output (it keeps consuming media, so the frame
  // mapping is untouched) from the first unexpected stop/reroute notification
  // until the monitor has decided what that change was. Set by the handler,
  // cleared by the monitor under events_mtx (see UnmuteIfQuietLocked).
  std::atomic<bool> route_mute{false};

  // Route following, guarded by mtx (see "Routes" in the header).
  lj_internal::RouteWatch route_watch;
  uint64_t device_epoch = 0;
  // The output was lost (latched): the device is not reused, and the next
  // EnsureDevice opens a fresh one.
  bool device_lost = false;
  // A reroute verdict is being resolved outside the lock.
  bool reroute_pending = false;
  // The default output when this device was opened / last rerouted: the
  // "previous device" a reroute is checked against.
  RouteSnapshot route_snapshot;
  uint64_t snapshot_epoch = 0;

  std::thread monitor;
  std::atomic<bool> monitor_stop{false};
  std::condition_variable monitor_cv;

  void Log(const char* fmt, ...);
  void Emit(lj_event_kind kind, int64_t latency_us, int has_latency,
            const char* code = nullptr, const char* message = nullptr);
  void EmitRouteChanged(bool old_device_unavailable, bool has_latency,
                        int64_t latency_us, const RouteSnapshot& route);
  // Must hold mtx. Keeps the atomic mirror the notification handler reads in
  // step with `state`.
  void SetStateLocked(State next) {
    state = next;
    published_playing.store(next == State::kPlaying, std::memory_order_release);
  }
  void OnData(float* out, ma_uint32 frame_count);
  void OnNotification(const ma_device_notification* n);
  void MonitorMain();

  // What a monitor tick must still do after releasing mtx (route queries block
  // on the audio server, so they never run under the lock).
  enum class RouteWork { kNone, kSnapshot, kDecideReroute, kReportLost };
  RouteWork RouteTickLocked(int64_t now, std::unique_ptr<Schedule>* dead,
                            uint64_t* work_epoch, std::string* old_key,
                            bool* have_old);
  void RouteWorkUnlocked(RouteWork work, uint64_t work_epoch,
                         const std::string& old_key, bool have_old,
                         std::unique_ptr<Schedule>* dead);
  // Must hold mtx. Retires a playing/paused schedule because its output is
  // gone; returns it for destruction outside the lock.
  std::unique_ptr<Schedule> StopForLostOutputLocked();
  // Must hold mtx. Starts re-measuring the device clock (see `rebase`).
  void BeginClockRebaseLocked(int64_t new_latency_frames);
  // Must hold mtx. miniaudio's visible buffer depth of the open device, in
  // client-rate frames (§7; see "Output latency" in the header).
  int64_t DeviceLatencyFramesLocked() const;
  // Must hold mtx. Lifts route_mute once every queued notification has been
  // through the watch, the watch has the output up and no reroute verdict is
  // still being resolved. The handler queues and mutes under events_mtx, which
  // this takes too, so a notification can never slip between check and lift.
  void UnmuteIfQuietLocked();

  // Must hold mtx. Detaches the active schedule so the caller can join+free it
  // outside the lock.
  std::unique_ptr<Schedule> RetireLocked();

  // Device lifecycle. These take and release mtx THEMSELVES and must be called
  // with it NOT held: ma_device_start and ma_device_uninit block until the audio
  // thread quiesces, and the audio thread takes mtx on every callback, so
  // holding it across either call deadlocks the moment a callback is in flight.
  void CloseDevice();
  bool EnsureDevice(const LoadedFile& file, char* err, size_t err_len);

  double PositionUsLocked(int64_t now) const;
};

namespace {

void DestroySchedule(std::unique_ptr<Schedule> sched) {
  if (!sched) {
    return;
  }
  sched->retired.store(true, std::memory_order_release);
  if (sched->decoder_thread.joinable()) {
    sched->decoder_thread.join();
  }
  if (sched->resampler_ready) {
    ma_resampler_uninit(&sched->resampler, nullptr);
    sched->resampler_ready = false;
  }
}

void DeviceDataCallback(ma_device* device, void* output, const void* input,
                        ma_uint32 frame_count) {
  (void)input;
  auto* engine = static_cast<lj_engine*>(device->pUserData);
  if (engine != nullptr) {
    engine->OnData(static_cast<float*>(output), frame_count);
  }
}

void DeviceNotificationCallback(const ma_device_notification* notification) {
  if (notification == nullptr || notification->pDevice == nullptr) {
    return;
  }
  auto* engine = static_cast<lj_engine*>(notification->pDevice->pUserData);
  if (engine != nullptr) {
    engine->OnNotification(notification);
  }
}

// Source frames consumed per output frame.
double RatioFor(double rate, uint32_t src_rate, uint32_t dev_rate) {
  return rate * static_cast<double>(src_rate) / static_cast<double>(dev_rate);
}

}  // namespace

// -------------------------------------------------------------- engine impl

void lj_engine::Log(const char* fmt, ...) {
  char buf[512];
  va_list args;
  va_start(args, fmt);
  vsnprintf(buf, sizeof(buf), fmt, args);
  va_end(args);
  if (log_cb != nullptr) {
    log_cb(log_user, buf);
  } else {
    std::fprintf(stderr, "[localjam_audio] %s\n", buf);
  }
}

void lj_engine::Emit(lj_event_kind kind, int64_t latency_us, int has_latency,
                     const char* code, const char* message) {
  // Queued, never delivered inline: notifications can arrive on the audio
  // thread, on a backend thread, or synchronously inside an lj_* call, and none
  // of those may re-enter the caller. The monitor thread drains this.
  try {
    std::lock_guard<std::mutex> lock(events_mtx);
    events.push_back(PendingEvent{kind, latency_us, has_latency,
                                  code == nullptr ? "" : code,
                                  message == nullptr ? "" : message, "", 0});
  } catch (...) {
    // Out of memory: the event is lost, the process is not.
  }
}

void lj_engine::EmitRouteChanged(bool old_device_unavailable, bool has_latency,
                                 int64_t latency_us,
                                 const RouteSnapshot& route) {
  try {
    std::lock_guard<std::mutex> lock(events_mtx);
    events.push_back(PendingEvent{LJ_EVENT_ROUTE_CHANGED, latency_us,
                                  has_latency ? 1 : 0, "", "",
                                  route.valid ? route.route_id : "",
                                  old_device_unavailable ? 1 : 0});
  } catch (...) {
  }
}

void lj_engine::OnData(float* out, ma_uint32 frame_count) {
  const int64_t now = NowUs();
  std::lock_guard<std::mutex> lock(mtx);

  const uint32_t channels = dev_channels == 0 ? 1 : dev_channels;
  std::memset(out, 0, static_cast<size_t>(frame_count) * channels *
                          sizeof(float));

  const int64_t w = out_frames_written;
  clock.Observe(w, now, dev_rate);
  if (rebase_pending) {
    // The output moved or resumed: the old origin predates a gap in the
    // callback timeline. Swap in the freshly measured model (and the new
    // route's latency) once it is as mature as the original had to be.
    rebase.Observe(w, now, dev_rate);
    if (rebase.origin_valid && rebase.mature_samples >= LJ_MATURITY_CALLBACKS) {
      clock = rebase;
      latency_frames = rebase_latency_frames;
      rebase_pending = false;
    }
  }
  out_frames_written = w + frame_count;

  lj_tap_sample tap_sample{now, w, frame_count, -1, 0.0f, 0};

  Schedule* s = sched.get();
  if (s == nullptr || state != State::kPlaying || s->failed) {
    if (tap != nullptr) {
      tap_sample.muted = route_mute.load(std::memory_order_acquire) ? 1 : 0;
      tap(tap_user, &tap_sample);
    }
    return;
  }

  // A schedule still priming must not start its media on a mapping that is
  // being re-measured: hold the silence until the new model is in.
  const bool hold_priming = rebase_pending && !s->skip_resolved;

  // Refine S against every fresh callback until media actually starts, exactly
  // like the Android priming loop refines against fresher HAL timestamps: the
  // first mature sample can be jittery, later ones are steadier.
  if (!s->skip_resolved && clock.origin_valid && !hold_priming) {
    const int64_t computed = std::max<int64_t>(
        0, RoundToI64(static_cast<double>(s->target_us - clock.origin_us) *
                          dev_rate / 1e6 -
                      static_cast<double>(latency_frames)));
    if (s->silence_frames < 0) {
      s->prime_pending = true;
      s->prime_origin_us = clock.origin_us;
      s->prime_w = w;
    }
    s->silence_frames = computed;
  }

  ma_uint32 done = 0;
  if (s->silence_frames >= 0 && !hold_priming) {
    // ---- Phase 1: silence padding up to output frame S.
    const int64_t pad = s->silence_frames - w;
    if (pad > 0) {
      done = static_cast<ma_uint32>(
          std::min<int64_t>(frame_count, pad));  // buffer already zeroed
    }

    if (done < frame_count) {
      // ---- Phase 2: resolve the overshoot trim exactly once. If the target
      // instant passed while the clock model matured, silence cannot be
      // un-emitted; the media is advanced instead so that output frame S + k
      // still carries media position P + k*rate/devRate. That keeps the SESSION
      // anchor the truth and lets the §5.4 drift check converge to zero.
      if (!s->skip_resolved) {
        const int64_t first_media = w + done;
        s->media_skip_out = std::max<int64_t>(0, first_media - s->silence_frames);
        s->pending_src_skip = RoundToI64(
            static_cast<double>(s->media_skip_out) *
            RatioFor(s->rate, s->src_rate, dev_rate));
        s->first_media_out_frame = first_media;
        s->skip_resolved = true;
      }

      // ---- Phase 3: media, pulled from the ring through the resampler.
      const ma_uint32 media_begin = done;
      const size_t feed_cap = s->feed.size() / channels;
      int guard = 0;
      while (done < frame_count && s->end_out_frame < 0 && ++guard < 4096) {
        if (s->feed_frames == 0) {
          if (s->ring->failed()) {
            s->failed = true;  // the ring holds the message
            break;
          }
          s->feed_frames = s->ring->Read(s->feed.data(), feed_cap);
          if (s->feed_frames == 0) {
            if (s->ring->eos()) {
              // All decoded audio has been handed over: this is where the
              // segment ends. The monitor thread turns it into playbackFinished
              // once the frame is actually presented.
              s->end_out_frame = w + done;
            } else {
              s->underrun_frames += frame_count - done;
            }
            break;
          }
        }
        if (s->pending_src_skip > 0) {
          const size_t drop = static_cast<size_t>(
              std::min<int64_t>(s->pending_src_skip,
                                static_cast<int64_t>(s->feed_frames)));
          if (drop < s->feed_frames) {
            std::memmove(s->feed.data(), s->feed.data() + drop * channels,
                         (s->feed_frames - drop) * channels * sizeof(float));
          }
          s->feed_frames -= drop;
          s->pending_src_skip -= static_cast<int64_t>(drop);
          continue;
        }
        ma_uint64 in_frames = s->feed_frames;
        ma_uint64 out_frames = frame_count - done;
        if (ma_resampler_process_pcm_frames(
                &s->resampler, s->feed.data(), &in_frames,
                out + static_cast<size_t>(done) * channels,
                &out_frames) != MA_SUCCESS) {
          s->failed = true;
          s->failure = "resampler failed";
          break;
        }
        if (in_frames > 0 && in_frames < s->feed_frames) {
          std::memmove(s->feed.data(), s->feed.data() + in_frames * channels,
                       (s->feed_frames - in_frames) * channels * sizeof(float));
        }
        s->feed_frames -= static_cast<size_t>(in_frames);
        if (!s->media_started && out_frames > 0) {
          s->media_started = true;
        }
        done += static_cast<ma_uint32>(out_frames);
        if (in_frames == 0 && out_frames == 0) {
          break;  // no progress; leave the rest silent this cycle
        }
      }
      if (done > media_begin) {
        tap_sample.first_media_out_frame = w + media_begin;
        tap_sample.first_media_sample =
            out[static_cast<size_t>(media_begin) * channels];
      }
    }
  }

  if (route_mute.load(std::memory_order_acquire)) {
    // The output is changing under us (see "Routes" in the header): keep the
    // bookkeeping above, emit nothing audible.
    std::memset(out, 0, static_cast<size_t>(frame_count) * channels *
                            sizeof(float));
    tap_sample.muted = 1;
  }

  if (tap != nullptr) {
    tap(tap_user, &tap_sample);
  }
}

void lj_engine::OnNotification(const ma_device_notification* n) {
  // Runs with NO engine lock — see the comment on events_mtx — on whatever
  // thread the backend notifies from. It only records what happened; the
  // monitor thread decides what it means (RouteWatch) and acts under mtx.
  lj_internal::DeviceSignal signal = lj_internal::DeviceSignal::kStarted;
  switch (n->type) {
    case ma_device_notification_type_started:
      signal = lj_internal::DeviceSignal::kStarted;
      break;
    case ma_device_notification_type_stopped:
      signal = lj_internal::DeviceSignal::kStopped;
      break;
    case ma_device_notification_type_rerouted:
      signal = lj_internal::DeviceSignal::kRerouted;
      break;
    case ma_device_notification_type_interruption_began:
      Emit(LJ_EVENT_INTERRUPTION_BEGAN, 0, 0);
      return;
    case ma_device_notification_type_interruption_ended:
      Emit(LJ_EVENT_INTERRUPTION_ENDED, 0, 0);
      return;
    default:
      return;
  }
  const bool expected = stop_expected_pub.load(std::memory_order_acquire);
  try {
    std::lock_guard<std::mutex> lock(events_mtx);
    signals.push_back(DeviceSignalRecord{
        signal, NowUs(), expected,
        device_epoch_pub.load(std::memory_order_acquire)});
    // A stop we did not ask for, or a reroute: whatever the device renders
    // next may be on an output we are about to abandon (WASAPI falls back to
    // the speaker when headphones are unplugged). Silent until the monitor has
    // decided — usually within one 10 ms tick.
    if (signal == lj_internal::DeviceSignal::kRerouted ||
        (signal == lj_internal::DeviceSignal::kStopped && !expected)) {
      route_mute.store(true, std::memory_order_release);
    }
  } catch (...) {
    // Out of memory: a lost notification is caught by the state poll.
    route_mute.store(true, std::memory_order_release);
  }
}

std::unique_ptr<Schedule> lj_engine::RetireLocked() {
  ++generation;
  if (!sched) {
    return nullptr;
  }
  sched->retired.store(true, std::memory_order_release);
  return std::move(sched);
}

void lj_engine::CloseDevice() {
  {
    std::lock_guard<std::mutex> lock(mtx);
    if (!device_open) {
      return;
    }
    device_open = false;
    stop_expected_pub.store(true, std::memory_order_release);
  }
  // Unlocked: uninit waits for the audio thread, which needs mtx to finish its
  // current callback. The device fields it reads are still valid here; they are
  // cleared below, once no callback can be running any more.
  ma_device_uninit(&device);
  {
    std::lock_guard<std::mutex> lock(mtx);
    device_started = false;
    device_lost = false;
    dev_rate = 0;
    dev_channels = 0;
    latency_frames = 0;
    out_frames_written = 0;
    clock.Reset();
    rebase_pending = false;
    route_watch.Reset();
    reroute_pending = false;
    route_mute.store(false, std::memory_order_release);
  }
}

bool lj_engine::EnsureDevice(const LoadedFile& file, char* err,
                            size_t err_len) {
  {
    std::lock_guard<std::mutex> lock(mtx);
    // A lost device is never reused: it would accept the schedule and then
    // never call back, i.e. silently never play. A device that is merely DOWN
    // (mid-reroute, inside the RouteWatch debounce) is reused: closing it
    // would race miniaudio's own reroute of it, and if it does not come back
    // the watch retires this schedule and reports the lost output.
    if (device_open && dev_channels == file.channels && !device_lost) {
      return true;
    }
  }
  CloseDevice();

  ma_device_config config = ma_device_config_init(ma_device_type_playback);
  config.playback.format = ma_format_f32;
  config.playback.channels = file.channels;
  // sampleRate 0 = the device's own default. Deliberate: our resampler already
  // converts src -> device rate, so asking miniaudio for a different rate would
  // stack a second resampler on top and hide latency inside it.
  config.sampleRate = 0;
  config.dataCallback = DeviceDataCallback;
  config.notificationCallback = DeviceNotificationCallback;
  config.pUserData = this;

  // No callback can run until ma_device_start below, so the fields the callback
  // reads are all published before it does.
  if (ma_device_init(nullptr, &config, &device) != MA_SUCCESS) {
    SetErr(err, err_len, "could not open an audio output device");
    return false;
  }
  std::lock_guard<std::mutex> setup(mtx);
  device_open = true;
  dev_rate = device.sampleRate;
  dev_channels = device.playback.channels;
  latency_frames = DeviceLatencyFramesLocked();

  out_frames_written = 0;
  clock.Reset();
  rebase_pending = false;
  route_watch.Reset();
  reroute_pending = false;
  device_lost = false;
  route_mute.store(false, std::memory_order_release);
  // Notifications of this device from here on (the "started" below included)
  // carry the new epoch; stragglers from a closed device are ignored.
  ++device_epoch;
  device_epoch_pub.store(device_epoch, std::memory_order_release);

  // ma_device_start fires the "started" notification synchronously on THIS
  // thread and may invoke the data callback before returning, so mtx is dropped
  // for the duration (OnNotification needs no lock at all; OnData needs mtx).
  stop_expected_pub.store(false, std::memory_order_release);
  ma_result start_result;
  {
    ReverseLock unlocked(mtx);
    start_result = ma_device_start(&device);
  }
  if (start_result != MA_SUCCESS) {
    // Roll the half-open device back, or the next lj_play_at would see
    // device_open and reuse a device that is not running. A failed start means
    // no audio thread ever began, so uninit here cannot block on a callback.
    stop_expected_pub.store(true, std::memory_order_release);
    device_open = false;
    device_started = false;
    dev_rate = 0;
    dev_channels = 0;
    latency_frames = 0;
    clock.Reset();
    ma_device_uninit(&device);
    SetErr(err, err_len, "could not start the audio output device");
    return false;
  }
  device_started = true;
  Log("device: %u Hz x%uch (internal %u Hz, %u frames x%u periods) -> "
      "latency %lld frames (%lld us)",
      dev_rate, dev_channels, device.playback.internalSampleRate,
      device.playback.internalPeriodSizeInFrames, device.playback.internalPeriods,
      static_cast<long long>(latency_frames),
      static_cast<long long>(RoundToI64(static_cast<double>(latency_frames) *
                                        1e6 / dev_rate)));
  return true;
}

int64_t lj_engine::DeviceLatencyFramesLocked() const {
  // Output latency (§7): miniaudio's visible buffer depth, converted from the
  // internal device rate to the client rate the callback works in. See the
  // header for what this can and cannot see. Re-read after a reroute: the new
  // device's buffer is not the old one's.
  if (dev_rate == 0) {
    return 0;
  }
  const uint32_t internal_rate = device.playback.internalSampleRate == 0
                                     ? dev_rate
                                     : device.playback.internalSampleRate;
  const double buffer_frames =
      static_cast<double>(device.playback.internalPeriodSizeInFrames) *
      static_cast<double>(device.playback.internalPeriods);
  return RoundToI64(buffer_frames * static_cast<double>(dev_rate) /
                    static_cast<double>(internal_rate));
}

void lj_engine::BeginClockRebaseLocked(int64_t new_latency_frames) {
  rebase.Reset();
  rebase_latency_frames = new_latency_frames;
  rebase_pending = true;
}

void lj_engine::UnmuteIfQuietLocked() {
  if (route_watch.down() || reroute_pending) {
    return;
  }
  std::lock_guard<std::mutex> lock(events_mtx);
  if (signals.empty()) {
    route_mute.store(false, std::memory_order_release);
  }
}

std::unique_ptr<Schedule> lj_engine::StopForLostOutputLocked() {
  if (!sched || (state != State::kPlaying && state != State::kPaused)) {
    return nullptr;
  }
  std::unique_ptr<Schedule> dead = RetireLocked();
  SetStateLocked(loaded.duration_us > 0 ? State::kLoaded : State::kIdle);
  return dead;
}

lj_engine::RouteWork lj_engine::RouteTickLocked(int64_t now,
                                                std::unique_ptr<Schedule>* dead,
                                                uint64_t* work_epoch,
                                                std::string* old_key,
                                                bool* have_old) {
  // Every notification since the last tick, in arrival order, into the watch.
  {
    std::lock_guard<std::mutex> lock(events_mtx);
    for (const DeviceSignalRecord& r : signals) {
      if (r.epoch == device_epoch) {
        route_watch.OnSignal(r.signal, r.at_us, r.expected);
      }
    }
    signals.clear();
  }
  if (!device_open || !device_started || device_lost || reroute_pending) {
    return RouteWork::kNone;
  }
  *work_epoch = device_epoch;
  // Reading the state under mtx is safe: CloseDevice clears device_open under
  // mtx before uninit. It is an atomic inside miniaudio, so a backend thread
  // mid-reroute is no race.
  const bool started = ma_device_get_state(&device) == ma_device_state_started;
  switch (route_watch.Poll(now, started)) {
    case lj_internal::RouteVerdict::kNone:
      break;
    case lj_internal::RouteVerdict::kResumed:
      Log("output resumed after a stop: re-measuring the device clock");
      BeginClockRebaseLocked(DeviceLatencyFramesLocked());
      break;
    case lj_internal::RouteVerdict::kRerouted:
      // Whether the previous device still exists decides between "user
      // switched outputs" and "unplugged, the OS fell back to the speaker" —
      // a question for the audio server, asked outside the lock. Stays muted
      // meanwhile.
      reroute_pending = true;
      *have_old = route_snapshot.valid && snapshot_epoch == device_epoch;
      if (*have_old) {
        *old_key = route_snapshot.key;
      }
      return RouteWork::kDecideReroute;
    case lj_internal::RouteVerdict::kOutputLost:
      device_lost = true;
      Log("output lost: the device stopped by itself and did not come back "
          "within %lld us; stopping (the next playAt opens a new device)",
          static_cast<long long>(LJ_ROUTE_DEBOUNCE_US));
      *dead = StopForLostOutputLocked();
      return RouteWork::kReportLost;
  }
  UnmuteIfQuietLocked();
  if (snapshot_epoch != device_epoch) {
    return RouteWork::kSnapshot;
  }
  return RouteWork::kNone;
}

void lj_engine::RouteWorkUnlocked(RouteWork work, uint64_t work_epoch,
                                  const std::string& old_key, bool have_old,
                                  std::unique_ptr<Schedule>* dead) {
  switch (work) {
    case RouteWork::kNone:
      return;
    case RouteWork::kSnapshot: {
      // The device just opened: remember which output it is on, so a later
      // reroute can tell whether that output is still there.
      const RouteSnapshot now_route = QuerySystemRoutes(nullptr, nullptr);
      std::lock_guard<std::mutex> lock(mtx);
      if (device_open && device_epoch == work_epoch) {
        route_snapshot = now_route;
        snapshot_epoch = work_epoch;
      }
      return;
    }
    case RouteWork::kReportLost: {
      // Already stopped under the lock; this only names where the system
      // would play now (if anywhere) for the event.
      EmitRouteChanged(true, false, 0, QuerySystemRoutes(nullptr, nullptr));
      return;
    }
    case RouteWork::kDecideReroute: {
      bool old_listed = true;
      const RouteSnapshot now_route =
          QuerySystemRoutes(have_old ? &old_key : nullptr, &old_listed);
      const bool old_gone =
          lj_internal::RerouteLostOldDevice(have_old, old_listed);
      std::lock_guard<std::mutex> lock(mtx);
      if (!device_open || device_epoch != work_epoch) {
        return;  // closed or replaced meanwhile; the new device starts afresh
      }
      reroute_pending = false;
      if (now_route.valid) {
        route_snapshot = now_route;
        snapshot_epoch = work_epoch;
      }
      if (old_gone) {
        // Unplugged, and the backend already moved us to whatever was left
        // (WASAPI: the speaker). Stop — whatever was scheduled, even a playAt
        // that raced in meanwhile — and leave it stopped: the user decides.
        Log("rerouted because the previous output went away: stopping");
        *dead = StopForLostOutputLocked();
        EmitRouteChanged(true, false, 0, now_route);
      } else {
        const int64_t new_latency = DeviceLatencyFramesLocked();
        Log("rerouted to another output: re-measuring the device clock "
            "(latency %lld frames)",
            static_cast<long long>(new_latency));
        BeginClockRebaseLocked(new_latency);
        EmitRouteChanged(
            false, true,
            RoundToI64(static_cast<double>(new_latency) * 1e6 /
                       static_cast<double>(dev_rate)),
            now_route);
      }
      UnmuteIfQuietLocked();
      return;
    }
  }
}

double lj_engine::PositionUsLocked(int64_t now) const {
  const Schedule* s = sched.get();
  if (s == nullptr) {
    return 0.0;
  }
  double us;
  if (s->silence_frames < 0 || !clock.origin_valid) {
    // Still priming: the pure anchor formula. It is the SAME line the
    // frame-based form below describes, just not yet expressed in frames.
    us = static_cast<double>(s->anchor_media_us) +
         static_cast<double>(now - s->target_us) * s->rate;
  } else {
    const double f_now = clock.PresentedFrame(now, dev_rate, latency_frames);
    us = static_cast<double>(s->anchor_media_us) +
         (f_now - static_cast<double>(s->silence_frames)) * s->rate * 1e6 /
             dev_rate;
  }
  const double max_us = static_cast<double>(loaded.duration_us);
  return std::min(std::max(us, 0.0), max_us);
}

void lj_engine::MonitorMain() {
  // One thread for the whole engine: completion detection, the measured
  // start-error log, failure handling, route following, and event delivery.
  // Nothing here runs on the audio thread.
  while (!monitor_stop.load(std::memory_order_acquire)) {
    std::deque<PendingEvent> drained;
    std::unique_ptr<Schedule> dead;
    std::unique_ptr<Schedule> dead_by_route;
    RouteWork route_work = RouteWork::kNone;
    uint64_t route_epoch = 0;
    std::string old_route_key;
    bool have_old_route = false;
    try {
      std::unique_lock<std::mutex> lock(mtx);
      monitor_cv.wait_for(lock, std::chrono::milliseconds(10));
      const int64_t now = NowUs();
      // Output route: device notifications and the polled device state (see
      // "Routes" in the header).
      route_work = RouteTickLocked(now, &dead_by_route, &route_epoch,
                                   &old_route_key, &have_old_route);
      Schedule* s = sched.get();
      if (s != nullptr && state == State::kPlaying) {
        if (s->prime_pending) {
          // Deferred from the audio thread, which must not call the log sink.
          s->prime_pending = false;
          Log("prime: origin=%lld L=%lld devRate=%u target=%lld W=%lld -> "
              "S(silenceFrames)=%lld (%s %lld)",
              static_cast<long long>(s->prime_origin_us),
              static_cast<long long>(latency_frames), dev_rate,
              static_cast<long long>(s->target_us),
              static_cast<long long>(s->prime_w),
              static_cast<long long>(s->silence_frames),
              s->silence_frames >= s->prime_w ? "pad" : "trim media",
              static_cast<long long>(
                  std::llabs(s->silence_frames - s->prime_w)));
        }
        if (s->failed) {
          // Not engineRestarted: re-scheduling the same file would fail the
          // same way, and the Dart engine would re-apply forever.
          const std::string why =
              s->failure != nullptr ? std::string(s->failure) : s->ring->error();
          Log("schedule failed: %s", why.c_str());
          dead = RetireLocked();
          SetStateLocked(loaded.duration_us > 0 ? State::kLoaded
                                              : State::kIdle);
          Emit(LJ_EVENT_PLAYBACK_ERROR, 0, 0, "decode_failed", why.c_str());
        } else {
          if (!s->start_error_logged && s->media_started && clock.origin_valid) {
            s->start_error_logged = true;
            // The live check on scheduling accuracy, in the spirit of the
            // Android "start error: errorUs=" line. `measured` uses the FINAL,
            // refined clock model; `intended` is where the session anchor
            // wanted the first media frame (shifted by any overshoot trim, in
            // real time — output frames run at devRate regardless of rate).
            const double measured =
                static_cast<double>(clock.origin_us) +
                (static_cast<double>(s->first_media_out_frame) +
                 static_cast<double>(latency_frames)) *
                    1e6 / dev_rate;
            const double intended =
                static_cast<double>(s->target_us) +
                static_cast<double>(s->media_skip_out) * 1e6 / dev_rate;
            Log("start error: firstMediaOutFrame=%lld measuredUs=%lld "
                "intendedUs=%lld errorUs=%lld (mediaSkipOut=%lld, "
                "originSpreadUs=%lld over %d samples)",
                static_cast<long long>(s->first_media_out_frame),
                static_cast<long long>(RoundToI64(measured)),
                static_cast<long long>(RoundToI64(intended)),
                static_cast<long long>(RoundToI64(measured - intended)),
                static_cast<long long>(s->media_skip_out),
                static_cast<long long>(clock.origin_max_us - clock.origin_us),
                clock.mature_samples);
          }
          if (s->end_out_frame >= 0 && clock.origin_valid &&
              clock.PresentedFrame(now, dev_rate, latency_frames) >=
                  static_cast<double>(s->end_out_frame)) {
            Log("playbackFinished (generation=%llu, underrunFrames=%lld)",
                static_cast<unsigned long long>(s->generation),
                static_cast<long long>(s->underrun_frames));
            dead = RetireLocked();
            SetStateLocked(State::kFinished);
            Emit(LJ_EVENT_PLAYBACK_FINISHED, 0, 0);
          }
        }
      }
    } catch (...) {
      // Out of memory for a log line or an event: skip this tick, never
      // std::terminate the host app from a background thread.
    }
    // Outside the lock: route questions block on the audio server.
    std::unique_ptr<Schedule> dead_by_reroute;
    try {
      RouteWorkUnlocked(route_work, route_epoch, old_route_key,
                        have_old_route, &dead_by_reroute);
    } catch (...) {
      // Out of memory mid-decision: do not leave the watch parked on it.
      std::lock_guard<std::mutex> lock(mtx);
      if (device_epoch == route_epoch) {
        reroute_pending = false;
      }
    }
    {
      std::lock_guard<std::mutex> lock(events_mtx);
      drained.swap(events);
    }
    DestroySchedule(std::move(dead));
    DestroySchedule(std::move(dead_by_route));
    DestroySchedule(std::move(dead_by_reroute));
    for (const PendingEvent& e : drained) {
      if (event_cb != nullptr) {
        const lj_event event{
            e.kind,
            e.latency_us,
            e.has_latency,
            e.code.empty() ? nullptr : e.code.c_str(),
            e.message.empty() ? nullptr : e.message.c_str(),
            e.route_id.empty() ? nullptr : e.route_id.c_str(),
            e.old_device_unavailable};
        try {
          event_cb(event_user, &event);
        } catch (...) {
          // A shell's callback must not take the monitor thread down.
        }
      }
    }
  }
}

// ---------------------------------------------------------------- decoder thread

namespace {

// Identifies and opens `path` and reads its stream parameters into `out`, then
// closes it again. The one place lj_load and lj_probe_duration share, so a
// probe reports exactly the duration a load would.
lj_status ProbeFile(const char* path, LoadedFile* out, char* err,
                    size_t err_len) {
  const Probe probe = SniffFile(path);
  if (probe.codec == Codec::kUnsupported) {
    SetErr(err, err_len,
           "%s is a %s file; the Windows/Linux backend decodes wav, flac, mp3 "
           "and ogg-vorbis only (no system codecs are used, so AAC/ALAC/WMA "
           "cannot be played). Transcode the track to flac or ogg.",
           path, probe.container);
    return LJ_ERR_UNSUPPORTED_FORMAT;
  }
  if (probe.codec == Codec::kUnknown) {
    SetErr(err, err_len,
           "could not identify the audio format of %s (expected wav, flac, mp3 "
           "or ogg-vorbis)",
           path);
    return LJ_ERR_UNSUPPORTED_FORMAT;
  }

  Decoder decoder;
  std::string error;
  if (!decoder.Open(path, probe.codec, &error)) {
    SetErr(err, err_len, "Could not open audio file at %s: %s", path,
           error.c_str());
    return LJ_ERR_LOAD_FAILED;
  }

  out->path = path;
  out->codec = probe.codec;
  out->sample_rate = decoder.sample_rate();
  out->channels = decoder.channels();
  out->total_frames = decoder.total_frames();
  // Duration is DECODER-derived and exact: every decoder here reports a true
  // PCM frame count (dr_mp3 by parsing every frame header). Unlike the Android
  // metadata-derived value there is no codec-frame slop, so position clamping
  // and playAt range checks are exact.
  out->duration_us = RoundToI64(static_cast<double>(out->total_frames) * 1e6 /
                                out->sample_rate);
  return LJ_OK;
}

// `rate` is accepted by playAt/setRate (see LJ_MIN_RATE in the header).
bool RateOk(double rate) {
  return std::isfinite(rate) && rate >= LJ_MIN_RATE && rate <= LJ_MAX_RATE;
}

void DecoderMainUnguarded(Schedule* s, const LoadedFile& file) {
  Decoder decoder;
  std::string error;
  if (!decoder.Open(file.path.c_str(), file.codec, &error)) {
    s->ring->SetError(("decoder open failed: " + error).c_str());
    return;
  }
  if (!decoder.Seek(s->start_frame)) {
    s->ring->SetError("decoder seek failed");
    return;
  }

  const uint32_t channels = file.channels;
  // Never larger than half the ring: the loop below waits for room for a whole
  // chunk, so a chunk that cannot fit would wait forever (see
  // lj_internal::ComputeStreamSizing).
  const size_t chunk_frames =
      lj_internal::ComputeStreamSizing(file.sample_rate, channels).chunk_frames;
  std::vector<float> chunk(chunk_frames * channels);

  while (!s->retired.load(std::memory_order_acquire)) {
    if (s->ring->space() < chunk_frames) {
      // Backpressure: this is what bounds memory to the ring size, and it is
      // also what parks the decoder while paused (the callback stops draining).
      std::this_thread::sleep_for(std::chrono::milliseconds(2));
      continue;
    }
    const uint64_t got = decoder.Read(chunk.data(), chunk_frames);
    if (got == 0) {
      s->ring->SetEos();
      return;
    }
    size_t written = 0;
    while (written < got && !s->retired.load(std::memory_order_acquire)) {
      written += s->ring->Write(chunk.data() + written * channels,
                                static_cast<size_t>(got) - written);
      if (written < got) {
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
      }
    }
    if (got < chunk_frames) {
      s->ring->SetEos();
      return;
    }
  }
}

void DecoderMain(Schedule* s, LoadedFile file) {
  // Produces the PCM for one schedule into its bounded ring. Owns a private
  // decoder — no sharing across schedules, so a new lj_play_at never fights an
  // old decoder over stream position. Exits the moment its schedule is retired,
  // checking only an atomic (never the engine mutex), which is what lets the
  // control path join it without touching anything the audio thread needs.
  //
  // An exception escaping a std::thread is std::terminate, i.e. the whole host
  // app; a decoder that cannot allocate fails its schedule (decode_failed).
  try {
    DecoderMainUnguarded(s, file);
  } catch (...) {
    s->ring->SetError("the decoder ran out of memory");
  }
}

lj_status LoadUnguarded(lj_engine* engine, const char* path,
                        int64_t* out_duration_us, char* err, size_t err_len) {
  // Replace any previously loaded file; stop playback first (Dart contract).
  std::unique_ptr<Schedule> dead;
  {
    std::lock_guard<std::mutex> lock(engine->mtx);
    dead = engine->RetireLocked();
    engine->SetStateLocked(State::kIdle);
    engine->loaded = LoadedFile();
  }
  DestroySchedule(std::move(dead));

  LoadedFile file;
  const lj_status probed = ProbeFile(path, &file, err, err_len);
  if (probed != LJ_OK) {
    return probed;
  }

  {
    std::lock_guard<std::mutex> lock(engine->mtx);
    engine->loaded = file;
    engine->SetStateLocked(State::kLoaded);
  }
  engine->Log("load: %s -> %lld us @ %u Hz x%uch (%llu frames, %s, streaming "
              "decode)",
              path, static_cast<long long>(file.duration_us), file.sample_rate,
              file.channels,
              static_cast<unsigned long long>(file.total_frames),
              ContainerName(file.codec));
  *out_duration_us = file.duration_us;
  return LJ_OK;
}

lj_status PlayAtUnguarded(lj_engine* engine, int64_t native_time_us,
                          int64_t position_us, double rate, char* err,
                          size_t err_len) {
  std::unique_ptr<Schedule> dead;
  LoadedFile file;
  {
    std::lock_guard<std::mutex> lock(engine->mtx);
    if (engine->state == State::kIdle || engine->loaded.sample_rate == 0) {
      SetErr(err, err_len, "playAt before load");
      return LJ_ERR_NO_FILE;
    }
    file = engine->loaded;
    // Calling while already playing/scheduled retires the old schedule.
    dead = engine->RetireLocked();
    engine->SetStateLocked(State::kLoaded);
  }
  DestroySchedule(std::move(dead));

  // Outside the lock: opening/starting the device blocks on the audio thread.
  if (!engine->EnsureDevice(file, err, err_len)) {
    return LJ_ERR_ENGINE_START_FAILED;
  }

  std::lock_guard<std::mutex> lock(engine->mtx);

  // Never an uncontrolled "ASAP" start (same rationale as iOS and Android): a
  // late anchor is re-anchored LJ_MIN_LEAD_US into the future with the position
  // advanced at ×rate (§5.3 late join), so the priming loop lands the start
  // precisely instead of inheriting an unpredictable spin-up delay that drift
  // correction could never remove.
  //
  // Both inputs come straight from Dart, so the arithmetic is done in double
  // and range-checked before anything is converted back: int64 subtraction or
  // llround of an out-of-range value would be undefined behaviour.
  const int64_t now = NowUs();
  int64_t anchor_us = native_time_us;
  double start_pos = static_cast<double>(position_us);
  if (anchor_us < now + LJ_MIN_LEAD_US) {
    start_pos += std::round((static_cast<double>(now + LJ_MIN_LEAD_US) -
                             static_cast<double>(anchor_us)) *
                            rate);
    anchor_us = now + LJ_MIN_LEAD_US;
  }

  const double start_frame_exact =
      std::round(start_pos * file.sample_rate / 1e6);
  if (!std::isfinite(start_frame_exact) || start_frame_exact < 0.0 ||
      start_frame_exact >= static_cast<double>(file.total_frames)) {
    SetErr(err, err_len,
           "start position %.0f us is outside the file (duration %lld us)",
           start_pos, static_cast<long long>(file.duration_us));
    return LJ_ERR_BAD_POSITION;
  }
  const int64_t start_frame = static_cast<int64_t>(start_frame_exact);
  const int64_t start_pos_us = static_cast<int64_t>(start_pos);
  // Keep the anchor frame-exact so the position formula carries no rounding
  // bias (mirrors iOS segmentStartUs / Android anchorMediaUs).
  const int64_t anchor_media_us =
      RoundToI64(static_cast<double>(start_frame) * 1e6 / file.sample_rate);

  auto s = std::unique_ptr<Schedule>(new Schedule());
  s->generation = engine->generation;
  s->target_us = anchor_us;
  s->anchor_media_us = anchor_media_us;
  s->start_frame = static_cast<uint64_t>(start_frame);
  s->src_rate = file.sample_rate;
  s->channels = file.channels;
  s->rate = rate;

  // Bounded by LJ_RING_MAX_BYTES whatever the file declares (see
  // lj_internal::ComputeStreamSizing); the decoder thread derives its chunk
  // from the same sizing.
  const size_t ring_frames =
      lj_internal::ComputeStreamSizing(file.sample_rate, file.channels)
          .ring_frames;
  s->ring.reset(new PcmRing(ring_frames, file.channels));
  // Feed buffer sized generously above one device period so the callback never
  // needs more than a couple of ring reads.
  s->feed.assign(4096 * static_cast<size_t>(file.channels), 0.0f);

  ma_resampler_config rc = ma_resampler_config_init(
      ma_format_f32, file.channels, file.sample_rate, engine->dev_rate,
      ma_resample_algorithm_linear);
  if (ma_resampler_init(&rc, nullptr, &s->resampler) != MA_SUCCESS) {
    SetErr(err, err_len, "could not initialise the resampler");
    return LJ_ERR_ENGINE_START_FAILED;
  }
  s->resampler_ready = true;
  // ratio = source frames consumed per output frame. This is where `rate` is
  // realised (plain resample: pitch shifts by the ratio; ~9 cents at the ±0.5%
  // §5.4 slews — see the header).
  ma_resampler_set_rate_ratio(
      &s->resampler,
      static_cast<float>(RatioFor(rate, file.sample_rate, engine->dev_rate)));

  Schedule* raw = s.get();
  try {
    raw->decoder_thread = std::thread([raw, file] { DecoderMain(raw, file); });
  } catch (...) {
    DestroySchedule(std::move(s));  // releases the resampler
    SetErr(err, err_len, "could not start the decoder thread");
    return LJ_ERR_INTERNAL;
  }

  engine->sched = std::move(s);
  engine->SetStateLocked(State::kPlaying);
  engine->Log(
      "playAt: requested nativeTimeUs=%lld positionUs=%lld rate=%.6f -> "
      "effective anchorUs=%lld startPosUs=%lld startFrame=%lld "
      "anchorMediaUs=%lld (now=%lld leadUs=%lld, ringFrames=%zu, "
      "clockMature=%d)",
      static_cast<long long>(native_time_us),
      static_cast<long long>(position_us), rate,
      static_cast<long long>(anchor_us), static_cast<long long>(start_pos_us),
      static_cast<long long>(start_frame),
      static_cast<long long>(anchor_media_us), static_cast<long long>(now),
      static_cast<long long>(anchor_us - now), ring_frames,
      engine->clock.origin_valid ? 1 : 0);
  return LJ_OK;
}

}  // namespace

// -------------------------------------------------------------- public API

extern "C" {

const char* lj_status_code(lj_status status) {
  switch (status) {
    case LJ_OK:
      return "ok";
    case LJ_ERR_BAD_ARGS:
      return "bad_args";
    case LJ_ERR_NO_FILE:
      return "no_file";
    case LJ_ERR_LOAD_FAILED:
      return "load_failed";
    case LJ_ERR_UNSUPPORTED_FORMAT:
      return "unsupported_format";
    case LJ_ERR_BAD_POSITION:
      return "bad_position";
    case LJ_ERR_ENGINE_START_FAILED:
      return "engine_start_failed";
    case LJ_ERR_INTERNAL:
      break;
  }
  return "internal";
}

const char* lj_event_type_name(lj_event_kind kind) {
  switch (kind) {
    case LJ_EVENT_ROUTE_CHANGED:
      return "routeChanged";
    case LJ_EVENT_INTERRUPTION_BEGAN:
      return "interruptionBegan";
    case LJ_EVENT_INTERRUPTION_ENDED:
      return "interruptionEnded";
    case LJ_EVENT_ENGINE_RESTARTED:
      return "engineRestarted";
    case LJ_EVENT_PLAYBACK_ERROR:
      return "playbackError";
    case LJ_EVENT_PLAYBACK_FINISHED:
      break;
  }
  return "playbackFinished";
}

void lj_log_discard(void* user_data, const char* message) {
  (void)user_data;
  (void)message;
}

int64_t lj_now_us(void) { return NowUs(); }

lj_status lj_create(lj_engine** out_engine, lj_event_cb event_cb,
                    void* event_user_data, lj_log_cb log_cb,
                    void* log_user_data, char* err, size_t err_len) {
  if (out_engine == nullptr) {
    SetErr(err, err_len, "lj_create requires an out parameter");
    return LJ_ERR_BAD_ARGS;
  }
  auto* engine = new (std::nothrow) lj_engine();
  if (engine == nullptr) {
    SetErr(err, err_len, "out of memory");
    return LJ_ERR_INTERNAL;
  }
  engine->event_cb = event_cb;
  engine->event_user = event_user_data;
  engine->log_cb = log_cb;
  engine->log_user = log_user_data;
  try {
    engine->monitor = std::thread([engine] { engine->MonitorMain(); });
  } catch (...) {
    delete engine;
    SetErr(err, err_len, "could not start the engine's monitor thread");
    return LJ_ERR_INTERNAL;
  }
  *out_engine = engine;
  return LJ_OK;
}

void lj_destroy(lj_engine* engine) {
  if (engine == nullptr) {
    return;
  }
  engine->monitor_stop.store(true, std::memory_order_release);
  engine->monitor_cv.notify_all();
  if (engine->monitor.joinable()) {
    engine->monitor.join();
  }
  std::unique_ptr<Schedule> dead;
  {
    std::lock_guard<std::mutex> lock(engine->mtx);
    dead = engine->RetireLocked();
    engine->SetStateLocked(State::kIdle);
    engine->loaded = LoadedFile();
  }
  DestroySchedule(std::move(dead));
  engine->CloseDevice();  // must not be called with mtx held
  delete engine;
}

lj_status lj_load(lj_engine* engine, const char* path, int64_t* out_duration_us,
                  char* err, size_t err_len) {
  if (engine == nullptr || path == nullptr || out_duration_us == nullptr) {
    SetErr(err, err_len, "load requires {path: String}");
    return LJ_ERR_BAD_ARGS;
  }
  try {
    return LoadUnguarded(engine, path, out_duration_us, err, err_len);
  } catch (...) {
    SetErr(err, err_len, "out of memory while loading %s", path);
    return LJ_ERR_INTERNAL;
  }
}

lj_status lj_play_at(lj_engine* engine, int64_t native_time_us,
                     int64_t position_us, double rate, char* err,
                     size_t err_len) {
  if (engine == nullptr) {
    SetErr(err, err_len, "playAt on a disposed engine");
    return LJ_ERR_BAD_ARGS;
  }
  if (!RateOk(rate)) {
    SetErr(err, err_len, "playAt rate must be within [%g, %g]", LJ_MIN_RATE,
           LJ_MAX_RATE);
    return LJ_ERR_BAD_ARGS;
  }
  if (static_cast<double>(native_time_us) - static_cast<double>(NowUs()) >
      static_cast<double>(LJ_MAX_LEAD_US)) {
    SetErr(err, err_len,
           "playAt nativeTimeUs is more than %lld s ahead of the native clock",
           static_cast<long long>(LJ_MAX_LEAD_US / 1000000));
    return LJ_ERR_BAD_ARGS;
  }

  try {
    return PlayAtUnguarded(engine, native_time_us, position_us, rate, err,
                           err_len);
  } catch (...) {
    // Out of memory, or no thread for the decoder: refuse this schedule
    // rather than std::terminate the host app.
    SetErr(err, err_len, "could not set up playback (out of resources)");
    return LJ_ERR_INTERNAL;
  }
}

lj_status lj_pause(lj_engine* engine) {
  if (engine == nullptr) {
    return LJ_ERR_BAD_ARGS;
  }
  std::lock_guard<std::mutex> lock(engine->mtx);
  if (engine->state == State::kPlaying) {
    // The callback stops draining the ring; the decoder then blocks on the full
    // ring (backpressure). The device keeps running so its clock model stays
    // mature. Resume is lj_play_at, exactly like Android.
    engine->SetStateLocked(State::kPaused);
  }
  return LJ_OK;
}

lj_status lj_stop(lj_engine* engine) {
  if (engine == nullptr) {
    return LJ_ERR_BAD_ARGS;
  }
  std::unique_ptr<Schedule> dead;
  {
    std::lock_guard<std::mutex> lock(engine->mtx);
    dead = engine->RetireLocked();
    engine->SetStateLocked(engine->loaded.sample_rate == 0 ? State::kIdle
                                                          : State::kLoaded);
  }
  DestroySchedule(std::move(dead));
  return LJ_OK;
}

int lj_position_us(lj_engine* engine, int64_t* out_us) {
  if (engine == nullptr || out_us == nullptr) {
    return 0;
  }
  const int64_t now = NowUs();
  std::lock_guard<std::mutex> lock(engine->mtx);
  // Contract: null when nothing is playing or scheduled — paused and finished
  // included, matching iOS's `guard state == .playing`.
  if (engine->state != State::kPlaying || !engine->sched) {
    return 0;
  }
  *out_us = RoundToI64(engine->PositionUsLocked(now));
  return 1;
}

lj_status lj_set_rate(lj_engine* engine, double rate, char* err,
                      size_t err_len) {
  if (engine == nullptr || !RateOk(rate)) {
    SetErr(err, err_len, "setRate requires {rate: double within [%g, %g]}",
           LJ_MIN_RATE, LJ_MAX_RATE);
    return LJ_ERR_BAD_ARGS;
  }
  const int64_t now = NowUs();
  std::lock_guard<std::mutex> lock(engine->mtx);
  Schedule* s = engine->sched.get();
  if (s == nullptr) {
    return LJ_OK;  // nothing scheduled; the next playAt carries the rate
  }
  // Re-anchor (S, P) AT the instant of the change: output frames before it
  // advanced media time at the old rate, frames after at the new one. Doing it
  // in one step keeps the position formula exact across any number of slews
  // with no accumulated error (the iOS/Android bookkeeping, expressed in the
  // output-frame domain).
  if (s->silence_frames >= 0 && engine->clock.origin_valid) {
    const double pos = engine->PositionUsLocked(now);
    const double f_now = engine->clock.PresentedFrame(now, engine->dev_rate,
                                                      engine->latency_frames);
    s->anchor_media_us = RoundToI64(pos);
    s->silence_frames = RoundToI64(f_now);
  } else {
    // Still priming: the anchor formula is in force, so re-anchor that instead.
    s->anchor_media_us = RoundToI64(engine->PositionUsLocked(now));
    s->target_us = now;
  }
  s->rate = rate;
  if (s->resampler_ready) {
    ma_resampler_set_rate_ratio(
        &s->resampler, static_cast<float>(RatioFor(rate, s->src_rate,
                                                   engine->dev_rate)));
  }
  engine->Log("setRate: %.6f (re-anchored S=%lld P=%lld us at now=%lld)", rate,
              static_cast<long long>(s->silence_frames),
              static_cast<long long>(s->anchor_media_us),
              static_cast<long long>(now));
  return LJ_OK;
}

int64_t lj_output_latency_us(lj_engine* engine) {
  if (engine == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(engine->mtx);
  if (engine->dev_rate == 0) {
    return 0;
  }
  return RoundToI64(static_cast<double>(engine->latency_frames) * 1e6 /
                    engine->dev_rate);
}

lj_status lj_probe_duration(const char* path, int64_t* out_duration_us,
                            char* err, size_t err_len) {
  if (path == nullptr || out_duration_us == nullptr) {
    SetErr(err, err_len, "probeDuration requires {path: String}");
    return LJ_ERR_BAD_ARGS;
  }
  try {
    LoadedFile file;
    const lj_status status = ProbeFile(path, &file, err, err_len);
    if (status == LJ_OK) {
      *out_duration_us = file.duration_us;
    }
    return status;
  } catch (...) {
    SetErr(err, err_len, "out of memory while probing %s", path);
    return LJ_ERR_INTERNAL;
  }
}

int lj_current_route_id(char* out, size_t out_len) {
  if (out == nullptr || out_len == 0) {
    return 0;
  }
  out[0] = '\0';
  // The system default output: the open device follows it (miniaudio
  // auto-routing), so it is also where an open device plays — and asking for
  // it needs no engine, which is what lets the plugins run this off the UI
  // thread without racing dispose.
  const RouteSnapshot route = QuerySystemRoutes(nullptr, nullptr);
  if (!route.valid) {
    return 0;
  }
  std::snprintf(out, out_len, "%s", route.route_id.c_str());
  return 1;
}

void lj_set_tap(lj_engine* engine, lj_tap_cb tap, void* user_data) {
  if (engine == nullptr) {
    return;
  }
  std::lock_guard<std::mutex> lock(engine->mtx);
  engine->tap = tap;
  engine->tap_user = user_data;
}

uint32_t lj_device_sample_rate(lj_engine* engine) {
  if (engine == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(engine->mtx);
  return engine->dev_rate;
}

int64_t lj_device_latency_frames(lj_engine* engine) {
  if (engine == nullptr) {
    return 0;
  }
  std::lock_guard<std::mutex> lock(engine->mtx);
  return engine->latency_frames;
}

void lj_test_signal_device(lj_engine* engine, lj_test_signal signal) {
  if (engine == nullptr) {
    return;
  }
  if (signal == LJ_TEST_FORGET_ROUTE) {
    std::lock_guard<std::mutex> lock(engine->mtx);
    if (engine->device_open && engine->route_snapshot.valid) {
      engine->route_snapshot.key = "id:localjam-test-unplugged-device";
    }
    return;
  }
  {
    std::lock_guard<std::mutex> lock(engine->mtx);
    if (!engine->device_open) {
      return;
    }
  }
  ma_device_notification n;
  std::memset(&n, 0, sizeof(n));
  n.pDevice = &engine->device;
  switch (signal) {
    case LJ_TEST_DEVICE_STARTED:
      n.type = ma_device_notification_type_started;
      break;
    case LJ_TEST_DEVICE_STOPPED:
      n.type = ma_device_notification_type_stopped;
      break;
    default:
      n.type = ma_device_notification_type_rerouted;
      break;
  }
  engine->OnNotification(&n);
}

}  // extern "C"
