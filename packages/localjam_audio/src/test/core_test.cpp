/*
 * core_test.cpp — end-to-end verification of localjam_audio_core against a REAL
 * audio device.
 *
 * Why this exists: the Windows and Linux plugin sources are thin channel
 * translators that cannot be compiled, let alone run, on a macOS development
 * machine. Everything that could actually be wrong — the silence-priming
 * schedule, the maturity gate, the overshoot/late-anchor path, the position
 * formula, the resample-ratio bookkeeping, pause/stop/re-schedule lifecycle —
 * lives in the shared core, and the shared core builds and runs anywhere
 * miniaudio has a backend. This binary is how that code earns trust.
 *
 * Run it with src/test/build.sh. It opens the default output device and plays
 * (quietly) for about twenty seconds.
 *
 * WHAT IS MEASURED
 *   1. start error   — where the first media frame actually landed versus where
 *                      the session anchor wanted it, per the FINAL refined clock
 *                      model. Non-circular: S is computed from an early model
 *                      and this compares it against the settled one, so an
 *                      unstable or immature mapping shows up here. Budget 5 ms.
 *   2. position error — lj_position_us versus the pure anchor formula
 *                      P + (now - anchor) * rate. This is exactly the check the
 *                      Dart §5.4 drift loop runs, so it is the number that
 *                      decides whether a client ever slews. Budget 15 ms
 *                      (§5.4's "ignore" threshold).
 *   3. rate slope    — d(position)/d(time) at rate 1.005 / 0.995.
 *   4. source-frame audit — INDEPENDENT of the clock model. The fixture's
 *                      channel 0 is a linear ramp encoding its own frame index,
 *                      so every callback's first media sample says which source
 *                      frame was really emitted. Compared against what the
 *                      position formula claims for that output frame, this
 *                      catches ring, trim and resample-ratio bugs that a
 *                      self-consistent clock check cannot.
 */

#include "../localjam_audio_core.h"
#include "../localjam_audio_internal.h"
#include "../localjam_audio_third_party.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

namespace {

// ------------------------------------------------------------- test fixture

constexpr uint32_t kSampleRate = 48000;
constexpr uint32_t kChannels = 2;
constexpr double kDurationSec = 5.0;
constexpr uint64_t kTotalFrames =
    static_cast<uint64_t>(kSampleRate * kDurationSec);

// Channel 0 is a strictly linear ramp over the whole file: value = frame /
// total * kRampSpan. Linear interpolation (what ma_linear_resampler does)
// preserves a straight line exactly, so the value read back at ANY output frame
// identifies the source frame it came from — that is what makes the audit in
// CheckSourceFrames independent of the scheduling math. Channel 1 is a quiet
// tone so the fixture is recognisably audio and not just DC.
constexpr float kRampSpan = 0.5f;

double SampleToFrame(float sample) {
  return static_cast<double>(sample) / kRampSpan *
         static_cast<double>(kTotalFrames);
}

bool WriteFixture(const std::string& path) {
  drwav_data_format format{};
  format.container = drwav_container_riff;
  format.format = DR_WAVE_FORMAT_IEEE_FLOAT;
  format.channels = kChannels;
  format.sampleRate = kSampleRate;
  format.bitsPerSample = 32;

  drwav wav;
  if (!drwav_init_file_write(&wav, path.c_str(), &format, nullptr)) {
    return false;
  }
  std::vector<float> block(4096 * kChannels);
  uint64_t written = 0;
  while (written < kTotalFrames) {
    const uint64_t n = std::min<uint64_t>(4096, kTotalFrames - written);
    for (uint64_t i = 0; i < n; ++i) {
      const uint64_t frame = written + i;
      block[i * kChannels] =
          static_cast<float>(static_cast<double>(frame) /
                             static_cast<double>(kTotalFrames)) *
          kRampSpan;
      block[i * kChannels + 1] = static_cast<float>(
          0.15 * std::sin(2.0 * 3.14159265358979 * 440.0 *
                          static_cast<double>(frame) / kSampleRate));
    }
    drwav_write_pcm_frames(&wav, n, block.data());
    written += n;
  }
  drwav_uninit(&wav);
  return true;
}

// ----------------------------------------------------------------- harness

int g_failures = 0;
int g_checks = 0;

void Check(bool ok, const std::string& what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
    std::printf("  FAIL  %s\n", what.c_str());
  } else {
    std::printf("  ok    %s\n", what.c_str());
  }
}

void CheckWithin(double value, double limit, const char* name,
                 const char* unit) {
  char buf[256];
  std::snprintf(buf, sizeof(buf), "%s = %.3f %s (budget %.3f %s)", name, value,
                unit, limit, unit);
  Check(std::fabs(value) <= limit, buf);
}

struct Harness {
  std::mutex mtx;
  std::vector<std::string> logs;
  std::vector<std::string> events;
  std::vector<lj_tap_sample> taps;

  static void Log(void* user, const char* message) {
    auto* h = static_cast<Harness*>(user);
    std::lock_guard<std::mutex> lock(h->mtx);
    h->logs.emplace_back(message);
    std::printf("        | %s\n", message);
  }

  static void Event(void* user, const lj_event* event) {
    auto* h = static_cast<Harness*>(user);
    std::lock_guard<std::mutex> lock(h->mtx);
    std::string line = lj_event_type_name(event->kind);
    if (event->has_latency != 0) {
      line += "(outputLatencyUs=" + std::to_string(event->output_latency_us) +
              ")";
    }
    if (event->route_id != nullptr) {
      line += "(routeId=" + std::string(event->route_id) + ")";
    }
    if (event->kind == LJ_EVENT_ROUTE_CHANGED) {
      line += "(oldDeviceUnavailable=" +
              std::to_string(event->old_device_unavailable) + ")";
    }
    if (event->code != nullptr) {
      line += "(code=" + std::string(event->code) + ", message=" +
              (event->message == nullptr ? "" : event->message) + ")";
    }
    h->events.push_back(line);
    std::printf("        * event %s\n", line.c_str());
  }

  // Audio-thread callback: appends to a pre-reserved vector, no allocation in
  // the steady state.
  static void Tap(void* user, const lj_tap_sample* sample) {
    auto* h = static_cast<Harness*>(user);
    if (h->taps.size() < h->taps.capacity()) {
      h->taps.push_back(*sample);
    }
  }

  // Reads "<key>=<int>" out of the engine's own diagnostic traces — the same
  // lines the Android backend prints ("start error: ... errorUs="), so field
  // logs and this harness read alike. Latest occurrence wins.
  bool LogInt(const char* key, int64_t* out) {
    std::lock_guard<std::mutex> lock(mtx);
    const std::string needle = std::string(key) + "=";
    for (auto it = logs.rbegin(); it != logs.rend(); ++it) {
      const size_t at = it->find(needle);
      if (at != std::string::npos) {
        *out = std::strtoll(it->c_str() + at + needle.size(), nullptr, 10);
        return true;
      }
    }
    return false;
  }

  bool StartErrorUs(int64_t* out) { return LogInt("errorUs", out); }

  void Reset() {
    std::lock_guard<std::mutex> lock(mtx);
    logs.clear();
    events.clear();
    taps.clear();
  }

  bool SawEvent(const char* name) {
    std::lock_guard<std::mutex> lock(mtx);
    for (const std::string& e : events) {
      if (e.rfind(name, 0) == 0) {
        return true;
      }
    }
    return false;
  }

  // The first event starting with `name`, or "" (copied: events may grow).
  std::string FirstEvent(const char* name) {
    std::lock_guard<std::mutex> lock(mtx);
    for (const std::string& e : events) {
      if (e.rfind(name, 0) == 0) {
        return e;
      }
    }
    return "";
  }

  bool SawLog(const char* needle) {
    std::lock_guard<std::mutex> lock(mtx);
    for (const std::string& l : logs) {
      if (l.find(needle) != std::string::npos) {
        return true;
      }
    }
    return false;
  }

  int CountLogs(const char* needle) {
    std::lock_guard<std::mutex> lock(mtx);
    int n = 0;
    for (const std::string& l : logs) {
      if (l.find(needle) != std::string::npos) {
        ++n;
      }
    }
    return n;
  }

  // Waits up to `timeout_ms` for an event starting with `name`.
  bool AwaitEvent(const char* name, int timeout_ms);
};

bool Harness::AwaitEvent(const char* name, int timeout_ms) {
  const int64_t deadline = lj_now_us() + static_cast<int64_t>(timeout_ms) * 1000;
  while (lj_now_us() < deadline) {
    if (SawEvent(name)) {
      return true;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(5));
  }
  return SawEvent(name);
}

// "<backend>:<16 lowercase hex digits>", the documented desktop route-id form.
bool LooksLikeRouteId(const std::string& id) {
  const size_t colon = id.rfind(':');
  if (colon == std::string::npos || colon == 0 || id.size() - colon - 1 != 16) {
    return false;
  }
  for (size_t i = colon + 1; i < id.size(); ++i) {
    const char c = id[i];
    if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
      return false;
    }
  }
  return true;
}

void SleepMs(int ms) {
  std::this_thread::sleep_for(std::chrono::milliseconds(ms));
}

// Expected media position under the §5.3/§5.4 anchor formula.
double ExpectedUs(int64_t now, int64_t anchor_us, double position_us,
                  double rate) {
  const double v = position_us + static_cast<double>(now - anchor_us) * rate;
  return std::min(std::max(v, 0.0), kDurationSec * 1e6);
}

struct PositionStats {
  int samples = 0;
  double max_abs_error_us = 0;
  double mean_error_us = 0;
  double first_slope = 0;
};

// Polls lj_position_us for `duration_ms`, comparing every reading against the
// anchor formula. Ignores the pre-start window, where the formula deliberately
// extrapolates below the anchor position and lj_position_us clamps at 0.
PositionStats PollPosition(lj_engine* engine, int64_t anchor_us,
                           double position_us, double rate, int duration_ms,
                           int settle_ms) {
  PositionStats stats;
  double sum = 0;
  const int64_t deadline = lj_now_us() + duration_ms * 1000;
  int64_t first_t = 0;
  double first_p = 0;
  int64_t last_t = 0;
  double last_p = 0;
  while (lj_now_us() < deadline) {
    SleepMs(25);
    const int64_t now = lj_now_us();
    int64_t pos = 0;
    if (lj_position_us(engine, &pos) == 0) {
      continue;
    }
    if (now < anchor_us + settle_ms * 1000) {
      continue;  // still priming / just started
    }
    const double expected = ExpectedUs(now, anchor_us, position_us, rate);
    const double err = static_cast<double>(pos) - expected;
    ++stats.samples;
    sum += err;
    stats.max_abs_error_us = std::max(stats.max_abs_error_us, std::fabs(err));
    if (first_t == 0) {
      first_t = now;
      first_p = static_cast<double>(pos);
    }
    last_t = now;
    last_p = static_cast<double>(pos);
  }
  if (stats.samples > 0) {
    stats.mean_error_us = sum / stats.samples;
  }
  if (last_t > first_t) {
    stats.first_slope = (last_p - first_p) / static_cast<double>(last_t - first_t);
  }
  return stats;
}

// The clock-model-independent audit described at the top of the file.
void CheckSourceFrames(Harness* h, lj_engine* engine, double rate,
                       const char* label) {
  const uint32_t dev_rate = lj_device_sample_rate(engine);
  if (dev_rate == 0) {
    Check(false, std::string(label) + ": no device rate");
    return;
  }
  // Baseline comes from the engine's own trace, not from what the caller asked
  // for: a late anchor is re-anchored forward (P moves), and the trim branch
  // starts the media media_skip_out output frames past S. Both are printed.
  int64_t anchor_media_us = 0;
  int64_t media_skip_out = 0;
  if (!h->LogInt("anchorMediaUs", &anchor_media_us)) {
    Check(false, std::string(label) + ": no playAt trace to audit against");
    return;
  }
  h->LogInt("mediaSkipOut", &media_skip_out);
  std::vector<lj_tap_sample> taps;
  {
    std::lock_guard<std::mutex> lock(h->mtx);
    taps = h->taps;
  }
  // Find S: the first output frame that carried media.
  int64_t s_frame = -1;
  for (const lj_tap_sample& t : taps) {
    if (t.first_media_out_frame >= 0) {
      s_frame = t.first_media_out_frame;
      break;
    }
  }
  if (s_frame < 0) {
    Check(false, std::string(label) + ": no media callbacks were tapped");
    return;
  }

  double worst_us = 0;
  int checked = 0;
  for (const lj_tap_sample& t : taps) {
    if (t.first_media_out_frame < 0) {
      continue;
    }
    // Skip the first 200 ms of media: the resampler's low-pass state is still
    // settling, which perturbs the ramp value (a group-delay transient, not a
    // scheduling error).
    if (t.first_media_out_frame < s_frame + dev_rate / 5) {
      continue;
    }
    // What the engine's own invariant claims for this output frame:
    //   output frame S + k carries media position P + k * rate / devRate
    // The media position of output frame S + k is P + k * rate / devRate; the
    // first frame that actually carried media is S + media_skip_out, so the
    // baseline shifts by the trim (zero on the normal path).
    const double claimed_us =
        static_cast<double>(anchor_media_us) +
        static_cast<double>(t.first_media_out_frame - s_frame +
                            media_skip_out) *
            rate * 1e6 / dev_rate;
    // What the audio itself says, decoded from the ramp:
    const double actual_us =
        SampleToFrame(t.first_media_sample) * 1e6 / kSampleRate;
    worst_us = std::max(worst_us, std::fabs(actual_us - claimed_us));
    ++checked;
  }
  char buf[256];
  std::snprintf(buf, sizeof(buf),
                "%s: source-frame audit over %d callbacks, worst |audio - "
                "claimed| = %.3f ms (budget 5.000 ms)",
                label, checked, worst_us / 1000.0);
  Check(checked > 0 && worst_us < 5000.0, buf);
}

}  // namespace

int main(int argc, char** argv) {
  (void)argc;
  (void)argv;

  const std::string dir = "/tmp/localjam_audio_core_test";
  std::string mkdir_cmd = "mkdir -p " + dir;
  if (std::system(mkdir_cmd.c_str()) != 0) {
    std::printf("could not create %s\n", dir.c_str());
    return 1;
  }
  const std::string fixture = dir + "/ramp.wav";
  std::printf("=== fixture: %s (%.1f s, %u Hz x%uch, f32)\n", fixture.c_str(),
              kDurationSec, kSampleRate, kChannels);
  if (!WriteFixture(fixture)) {
    std::printf("could not write the fixture wav\n");
    return 1;
  }

  Harness harness;
  harness.taps.reserve(200000);

  lj_engine* engine = nullptr;
  char err[512] = {0};
  if (lj_create(&engine, &Harness::Event, &harness, &Harness::Log, &harness, err,
                sizeof(err)) != LJ_OK) {
    std::printf("lj_create failed: %s\n", err);
    return 1;
  }
  lj_set_tap(engine, &Harness::Tap, &harness);

  // ---------------------------------------------------- overshoot-trim mode
  //
  // Built as a second binary whose maturity gate (LJ_MATURITY_SPAN_US) is
  // forced to outlast LJ_MIN_LEAD_US, so the anchor instant is guaranteed to
  // pass while the clock model is still settling. That is the ONE branch a
  // healthy machine never reaches by itself: silence cannot be un-emitted, so
  // the media is trimmed instead. What must survive is the invariant — the
  // position stays on the ORIGINAL session anchor line, because the media start
  // advanced by exactly the lateness at ×rate. If that broke, every late-joining
  // client would sit at a constant offset the §5.4 drift loop could not close.
  if (std::getenv("LJ_TEST_TRIM") != nullptr) {
    std::printf("\n=== overshoot-trim path (forced late maturity)\n");
    int64_t dur = 0;
    if (lj_load(engine, fixture.c_str(), &dur, err, sizeof(err)) != LJ_OK) {
      std::printf("load failed: %s\n", err);
      return 1;
    }
    const int64_t trim_anchor = lj_now_us() + 200000;
    err[0] = 0;
    const lj_status s =
        lj_play_at(engine, trim_anchor, 500000, 1.0, err, sizeof(err));
    Check(s == LJ_OK, std::string("playAt returns LJ_OK (") +
                          lj_status_code(s) + ": " + err + ")");
    PositionStats trim = PollPosition(engine, trim_anchor, 500000, 1.0, 2500, 700);
    int64_t skip = 0;
    Check(harness.LogInt("mediaSkipOut", &skip) && skip > 0,
          "the trim branch was actually taken (mediaSkipOut = " +
              std::to_string(skip) + " output frames)");
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "trimmed start still tracks the ORIGINAL anchor line: max "
                  "|err| = %.3f ms over %d samples (budget 15.000 ms)",
                  trim.max_abs_error_us / 1000.0, trim.samples);
    Check(trim.samples > 10 && trim.max_abs_error_us < 15000.0, buf);
    CheckSourceFrames(&harness, engine, 1.0, "trim");
    lj_destroy(engine);
    std::printf("\n=== %d/%d checks passed\n", g_checks - g_failures, g_checks);
    return g_failures == 0 ? 0 : 1;
  }

  // ------------------------------------------------------------------ load
  std::printf("\n=== 1. load\n");
  int64_t duration_us = 0;
  err[0] = 0;
  lj_status st = lj_load(engine, fixture.c_str(), &duration_us, err, sizeof(err));
  Check(st == LJ_OK, std::string("load returns LJ_OK (") +
                         lj_status_code(st) + ": " + err + ")");
  {
    char buf[128];
    std::snprintf(buf, sizeof(buf), "duration = %lld us (expected %lld us)",
                  static_cast<long long>(duration_us),
                  static_cast<long long>(kDurationSec * 1e6));
    Check(std::llabs(duration_us - static_cast<int64_t>(kDurationSec * 1e6)) <
              1000,
          buf);
  }

  // ------------------------------- probeDuration, route id, bad arguments
  std::printf("\n=== 1b. probeDuration / currentRouteId / argument validation\n");
  {
    int64_t probed = 0;
    err[0] = 0;
    lj_status s = lj_probe_duration(fixture.c_str(), &probed, err, sizeof(err));
    Check(s == LJ_OK && probed == duration_us,
          "probeDuration = load's duration (" + std::to_string(probed) +
              " us)");
    s = lj_probe_duration((dir + "/does_not_exist.wav").c_str(), &probed, err,
                          sizeof(err));
    Check(s == LJ_ERR_LOAD_FAILED,
          std::string("probe of a missing file -> ") + lj_status_code(s));
    s = lj_probe_duration(nullptr, &probed, err, sizeof(err));
    Check(s == LJ_ERR_BAD_ARGS,
          std::string("probe without a path -> ") + lj_status_code(s));

    char route[256] = {0};
    const int have_route = lj_current_route_id(route, sizeof(route));
    Check(have_route == 1 && LooksLikeRouteId(route),
          std::string("currentRouteId (no engine, no device needed): ") +
              route);
    char again[256] = {0};
    Check(lj_current_route_id(again, sizeof(again)) == 1 &&
              std::strcmp(route, again) == 0,
          "currentRouteId is stable across calls");

    // Dart passes these straight through; none of them may reach undefined
    // arithmetic (int64 overflow, llround of inf) — they must be refused.
    const double bad_rates[] = {0.0, -1.0, NAN, INFINITY, 1e300, 64.0};
    bool all_refused = true;
    for (double rate : bad_rates) {
      if (lj_play_at(engine, lj_now_us() + 300000, 0, rate, err,
                     sizeof(err)) != LJ_ERR_BAD_ARGS ||
          lj_set_rate(engine, rate, err, sizeof(err)) != LJ_ERR_BAD_ARGS) {
        all_refused = false;
      }
    }
    Check(all_refused, "out-of-range / non-finite rates -> bad_args");
    s = lj_play_at(engine, INT64_MIN, 0, 1.0, err, sizeof(err));
    Check(s == LJ_ERR_BAD_POSITION,
          std::string("anchor INT64_MIN (position runs off the file) -> ") +
              lj_status_code(s));
    s = lj_play_at(engine, lj_now_us() + 300000, INT64_MAX, 1.0, err,
                   sizeof(err));
    Check(s == LJ_ERR_BAD_POSITION,
          std::string("position INT64_MAX -> ") + lj_status_code(s));
    s = lj_play_at(engine, INT64_MAX, 0, 1.0, err, sizeof(err));
    Check(s == LJ_ERR_BAD_ARGS,
          std::string("anchor INT64_MAX (beyond LJ_MAX_LEAD_US) -> ") +
              lj_status_code(s));
    lj_stop(engine);
  }

  // ------------------------------------------------ unsupported format code
  std::printf("\n=== 2. unsupported format\n");
  {
    const std::string m4a = dir + "/fake.m4a";
    FILE* f = std::fopen(m4a.c_str(), "wb");
    // Minimal ISO base-media header: size + 'ftyp' + 'M4A '.
    const unsigned char head[] = {0x00, 0x00, 0x00, 0x20, 'f', 't', 'y', 'p',
                                  'M',  '4',  'A',  ' ',  0,   0,   0,   0};
    std::fwrite(head, 1, sizeof(head), f);
    std::fclose(f);
    int64_t d = 0;
    err[0] = 0;
    const lj_status s = lj_load(engine, m4a.c_str(), &d, err, sizeof(err));
    Check(s == LJ_ERR_UNSUPPORTED_FORMAT &&
              std::strcmp(lj_status_code(s), "unsupported_format") == 0,
          std::string("m4a -> unsupported_format (") + lj_status_code(s) + ")");
    std::printf("        message: %s\n", err);
    int64_t probed = -1;
    const lj_status ps = lj_probe_duration(m4a.c_str(), &probed, err,
                                           sizeof(err));
    Check(ps == LJ_ERR_UNSUPPORTED_FORMAT && probed == -1,
          std::string("probeDuration of m4a -> ") + lj_status_code(ps) +
              " (channel replies null)");
    // Reload the real fixture; the failed load cleared the engine's state.
    lj_load(engine, fixture.c_str(), &duration_us, err, sizeof(err));
  }

  // ---------------------------------------------- scheduled start, rate 1.0
  std::printf("\n=== 3. playAt(now + 500 ms, position 0, rate 1.0)\n");
  harness.Reset();
  int64_t anchor = lj_now_us() + 500000;
  err[0] = 0;
  st = lj_play_at(engine, anchor, 0, 1.0, err, sizeof(err));
  Check(st == LJ_OK, std::string("playAt returns LJ_OK (") +
                         lj_status_code(st) + ": " + err + ")");
  {
    // probeDuration must not disturb a live schedule (the position checks
    // below would catch it) and must still answer.
    int64_t probed = 0;
    Check(lj_probe_duration(fixture.c_str(), &probed, err, sizeof(err)) ==
                  LJ_OK &&
              probed == duration_us,
          "probeDuration while scheduled");
    char route[256] = {0};
    Check(lj_current_route_id(route, sizeof(route)) == 1 &&
              LooksLikeRouteId(route),
          std::string("currentRouteId while a device is open: ") + route);
  }
  {
    const int64_t latency = lj_output_latency_us(engine);
    std::printf("        device: %u Hz, latency %lld frames / %lld us\n",
                lj_device_sample_rate(engine),
                static_cast<long long>(lj_device_latency_frames(engine)),
                static_cast<long long>(latency));
  }
  PositionStats stats = PollPosition(engine, anchor, 0, 1.0, 2500, 250);
  {
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "position error vs anchor formula: max |err| = %.3f ms, mean "
                  "%.3f ms over %d samples (budget 15.000 ms)",
                  stats.max_abs_error_us / 1000.0, stats.mean_error_us / 1000.0,
                  stats.samples);
    Check(stats.samples > 10 && stats.max_abs_error_us < 15000.0, buf);
  }
  {
    int64_t start_error = 0;
    if (harness.StartErrorUs(&start_error)) {
      CheckWithin(static_cast<double>(start_error) / 1000.0, 5.0,
                  "start error", "ms");
    } else {
      Check(false, "engine logged a measured start error");
    }
  }
  CheckSourceFrames(&harness, engine, 1.0, "rate 1.0");

  // ------------------------------------------------------ rate slew (§5.4)
  std::printf("\n=== 4. setRate +0.5%% / -0.5%% (drift slew)\n");
  for (double rate : {1.005, 0.995}) {
    int64_t pos_before = 0;
    lj_position_us(engine, &pos_before);
    const int64_t t_before = lj_now_us();
    st = lj_set_rate(engine, rate, err, sizeof(err));
    Check(st == LJ_OK, std::string("setRate(") + std::to_string(rate) + ")");
    SleepMs(150);  // let the re-anchor settle
    const int64_t t0 = lj_now_us();
    int64_t p0 = 0;
    lj_position_us(engine, &p0);
    SleepMs(1200);
    const int64_t t1 = lj_now_us();
    int64_t p1 = 0;
    lj_position_us(engine, &p1);
    const double slope = static_cast<double>(p1 - p0) /
                         static_cast<double>(t1 - t0);
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "position slope at rate %.3f = %.5f (error %.4f %%, budget "
                  "0.10 %%)",
                  rate, slope, (slope / rate - 1.0) * 100.0);
    Check(std::fabs(slope / rate - 1.0) < 0.001, buf);
    (void)pos_before;
    (void)t_before;
  }
  lj_set_rate(engine, 1.0, err, sizeof(err));

  // -------------------------------------------------------- pause and stop
  std::printf("\n=== 5. pause / stop\n");
  Check(lj_pause(engine) == LJ_OK, "pause returns LJ_OK");
  {
    int64_t pos = 0;
    Check(lj_position_us(engine, &pos) == 0,
          "positionUs is null while paused (Dart contract)");
  }
  Check(lj_stop(engine) == LJ_OK, "stop returns LJ_OK");
  {
    int64_t pos = 0;
    Check(lj_position_us(engine, &pos) == 0, "positionUs is null after stop");
  }

  // ----------------------------------------------- late anchor (§5.3 join)
  std::printf("\n=== 6. late anchor: playAt(now - 300 ms, position 1.0 s)\n");
  harness.Reset();
  {
    const int64_t requested = lj_now_us() - 300000;
    const int64_t requested_pos = 1000000;
    err[0] = 0;
    st = lj_play_at(engine, requested, requested_pos, 1.0, err, sizeof(err));
    Check(st == LJ_OK, std::string("late playAt returns LJ_OK (") +
                           lj_status_code(st) + ": " + err + ")");
    // The engine must land ON the session anchor line, not on a delayed one:
    // the effective anchor moves forward by (LJ_MIN_LEAD_US + lateness) and the
    // position advances by exactly the same amount at ×rate, so the ORIGINAL
    // (requested, requested_pos) line is still the truth.
    PositionStats late =
        PollPosition(engine, requested, static_cast<double>(requested_pos), 1.0,
                     2000, 800);
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "late-join position stays on the ORIGINAL anchor line: max "
                  "|err| = %.3f ms over %d samples (budget 15.000 ms)",
                  late.max_abs_error_us / 1000.0, late.samples);
    Check(late.samples > 10 && late.max_abs_error_us < 15000.0, buf);
    int64_t start_error = 0;
    if (harness.StartErrorUs(&start_error)) {
      std::printf("        measured start error on the late path: %lld us\n",
                  static_cast<long long>(start_error));
    }
  }

  // --------------------------------------- re-schedule while already playing
  std::printf("\n=== 7. second playAt while playing\n");
  harness.Reset();
  {
    anchor = lj_now_us() + 400000;
    err[0] = 0;
    st = lj_play_at(engine, anchor, 2000000, 1.0, err, sizeof(err));
    Check(st == LJ_OK, std::string("re-schedule returns LJ_OK (") +
                           lj_status_code(st) + ": " + err + ")");
    PositionStats re = PollPosition(engine, anchor, 2000000, 1.0, 1500, 250);
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "re-scheduled position error: max |err| = %.3f ms over %d "
                  "samples (budget 15.000 ms)",
                  re.max_abs_error_us / 1000.0, re.samples);
    Check(re.samples > 5 && re.max_abs_error_us < 15000.0, buf);
    int64_t start_error = 0;
    if (harness.StartErrorUs(&start_error)) {
      CheckWithin(static_cast<double>(start_error) / 1000.0, 5.0,
                  "start error (re-schedule, warm clock model)", "ms");
    }
    CheckSourceFrames(&harness, engine, 1.0, "re-schedule");
  }

  // ------------------------------------------------------ bad position code
  std::printf("\n=== 8. bad position\n");
  {
    err[0] = 0;
    const lj_status s =
        lj_play_at(engine, lj_now_us() + 300000, 60000000, 1.0, err, sizeof(err));
    Check(s == LJ_ERR_BAD_POSITION, std::string("position past EOF -> ") +
                                        lj_status_code(s));
    std::printf("        message: %s\n", err);
  }

  // ------------------------------------------------------ playbackFinished
  std::printf("\n=== 9. playbackFinished at end of file\n");
  harness.Reset();
  {
    st = lj_play_at(engine, lj_now_us() + 300000, duration_us - 700000, 1.0, err,
                    sizeof(err));
    Check(st == LJ_OK, "playAt near the end of the file");
    const int64_t deadline = lj_now_us() + 4000000;
    while (lj_now_us() < deadline && !harness.SawEvent("playbackFinished")) {
      SleepMs(50);
    }
    Check(harness.SawEvent("playbackFinished"),
          "playbackFinished fired within 4 s");
    int64_t pos = 0;
    Check(lj_position_us(engine, &pos) == 0,
          "positionUs is null once finished");
  }

  // ------------------------------------------------- decode failure (error)
  // The file disappears between load and the decoder thread opening it. That
  // used to be reported as engineRestarted, which made the Dart engine
  // re-schedule — and fail the same way — forever. It is a playbackError.
  std::printf("\n=== 10. decoder failure -> playbackError\n");
  harness.Reset();
  {
    const std::string doomed = dir + "/doomed.wav";
    const int copied =
        std::system(("cp '" + fixture + "' '" + doomed + "'").c_str());
    int64_t d = 0;
    Check(copied == 0 &&
              lj_load(engine, doomed.c_str(), &d, err, sizeof(err)) == LJ_OK,
          "load a copy of the fixture");
    std::remove(doomed.c_str());
    st = lj_play_at(engine, lj_now_us() + 300000, 0, 1.0, err, sizeof(err));
    Check(st == LJ_OK, "playAt is accepted (the decoder opens later)");
    const int64_t deadline = lj_now_us() + 3000000;
    while (lj_now_us() < deadline &&
           !harness.SawEvent("playbackError(code=decode_failed")) {
      SleepMs(50);
    }
    Check(harness.SawEvent("playbackError(code=decode_failed"),
          "playbackError{code: decode_failed} fired");
    Check(!harness.SawEvent("engineRestarted"), "and no engineRestarted");
    int64_t pos = 0;
    Check(lj_position_us(engine, &pos) == 0,
          "positionUs is null after the failure (output stopped)");
  }

  // --------------------------------------------- output switch (WASAPI-like)
  // The notification sequence miniaudio's WASAPI backend produces on EVERY
  // default-output change — stopped, rerouted, started — replayed into the
  // engine while it plays on the real device. It used to end the schedule with
  // playbackError{device_lost}; it is a route change that keeps playing.
  std::printf("\n=== 11. output switch (stop, reroute, start) keeps playing\n");
  harness.Reset();
  lj_load(engine, fixture.c_str(), &duration_us, err, sizeof(err));
  {
    anchor = lj_now_us() + 400000;
    st = lj_play_at(engine, anchor, 0, 1.0, err, sizeof(err));
    Check(st == LJ_OK, "playAt");
    SleepMs(700);  // playing, and the engine has noted which output it is on
    const int opened_before = harness.CountLogs("device: ");
    lj_test_signal_device(engine, LJ_TEST_DEVICE_STOPPED);
    lj_test_signal_device(engine, LJ_TEST_DEVICE_REROUTED);
    lj_test_signal_device(engine, LJ_TEST_DEVICE_STARTED);
    Check(harness.AwaitEvent("routeChanged", 2000), "routeChanged fired");
    const std::string ev = harness.FirstEvent("routeChanged");
    Check(ev.find("oldDeviceUnavailable=0") != std::string::npos &&
              ev.find("outputLatencyUs=") != std::string::npos &&
              ev.find("routeId=") != std::string::npos,
          "  ...as a plain switch with the new latency and route id: " + ev);
    SleepMs(300);
    Check(!harness.SawEvent("playbackError"), "  ...and NOT playbackError");
    Check(harness.SawLog("re-measuring the device clock"),
          "  ...the device clock was re-measured");
    Check(harness.CountLogs("device: ") == opened_before,
          "  ...on the same open device (no re-open)");
    PositionStats after = PollPosition(engine, anchor, 0, 1.0, 1000, 0);
    char buf[256];
    std::snprintf(buf, sizeof(buf),
                  "  ...still playing on the anchor line: max |err| = %.3f ms "
                  "over %d samples (budget 15.000 ms)",
                  after.max_abs_error_us / 1000.0, after.samples);
    Check(after.samples > 10 && after.max_abs_error_us < 15000.0, buf);
    // Output is audible again once the switch is decided.
    bool unmuted_media = false;
    {
      std::lock_guard<std::mutex> lock(harness.mtx);
      for (auto it = harness.taps.rbegin(); it != harness.taps.rend(); ++it) {
        if (it->first_media_out_frame >= 0) {
          unmuted_media = it->muted == 0;
          break;
        }
      }
    }
    Check(unmuted_media, "  ...and unmuted");
    lj_stop(engine);
  }

  // ------------------------------------- unplugged, OS falls back to speaker
  // Same sequence, but the output the device was on is no longer listed by the
  // system: the headphones were unplugged and WASAPI rerouted to the speaker.
  // The music must stop rather than come out of the speaker.
  std::printf("\n=== 12. unplug with fallback (old output gone) stops\n");
  harness.Reset();
  {
    st = lj_play_at(engine, lj_now_us() + 300000, 1000000, 1.0, err,
                    sizeof(err));
    Check(st == LJ_OK, "playAt");
    SleepMs(500);
    lj_test_signal_device(engine, LJ_TEST_FORGET_ROUTE);
    lj_test_signal_device(engine, LJ_TEST_DEVICE_STOPPED);
    lj_test_signal_device(engine, LJ_TEST_DEVICE_REROUTED);
    lj_test_signal_device(engine, LJ_TEST_DEVICE_STARTED);
    Check(harness.AwaitEvent("routeChanged", 2000), "routeChanged fired");
    const std::string ev = harness.FirstEvent("routeChanged");
    Check(ev.find("oldDeviceUnavailable=1") != std::string::npos,
          "  ...with oldDeviceUnavailable: " + ev);
    int64_t pos = 0;
    Check(lj_position_us(engine, &pos) == 0, "  ...output stopped");
    // Nothing that reached the device between the reroute and the decision
    // was audible: every media callback after the stop signal was muted.
    bool leaked = false;
    {
      std::lock_guard<std::mutex> lock(harness.mtx);
      bool seen_mute = false;
      for (const lj_tap_sample& t : harness.taps) {
        seen_mute = seen_mute || t.muted != 0;
        if (seen_mute && t.first_media_out_frame >= 0 && t.muted == 0) {
          leaked = true;
        }
      }
    }
    Check(!leaked, "  ...no unmuted media after the stop signal");
    SleepMs(300);
    Check(!harness.SawEvent("playbackError"), "  ...no playbackError");
    harness.Reset();
    st = lj_play_at(engine, lj_now_us() + 300000, 0, 1.0, err, sizeof(err));
    SleepMs(600);
    Check(st == LJ_OK && lj_position_us(engine, &pos) == 1,
          "  ...an explicit playAt plays again (on the fallback output)");
    lj_stop(engine);
  }

  // ------------------------------------------ stopped, nothing to fall back to
  std::printf("\n=== 13. output stopped and never restarted -> lost\n");
  harness.Reset();
  {
    st = lj_play_at(engine, lj_now_us() + 300000, 0, 1.0, err, sizeof(err));
    Check(st == LJ_OK, "playAt");
    SleepMs(500);
    const int64_t stopped_at = lj_now_us();
    lj_test_signal_device(engine, LJ_TEST_DEVICE_STOPPED);
    Check(harness.AwaitEvent("routeChanged", 2000), "routeChanged fired");
    const int64_t waited_us = lj_now_us() - stopped_at;
    const std::string ev = harness.FirstEvent("routeChanged");
    Check(ev.find("oldDeviceUnavailable=1") != std::string::npos,
          "  ...with oldDeviceUnavailable: " + ev);
    Check(waited_us >= LJ_ROUTE_DEBOUNCE_US,
          "  ...only after the reroute debounce (" +
              std::to_string(waited_us / 1000) + " ms)");
    int64_t pos = 0;
    Check(lj_position_us(engine, &pos) == 0, "  ...output stopped");
    SleepMs(300);
    Check(!harness.SawEvent("playbackError"),
          "  ...a route change, not playbackError{device_lost}");
    const int opened_before = harness.CountLogs("device: ");
    st = lj_play_at(engine, lj_now_us() + 300000, 0, 1.0, err, sizeof(err));
    SleepMs(600);
    Check(st == LJ_OK && lj_position_us(engine, &pos) == 1 &&
              harness.CountLogs("device: ") == opened_before + 1,
          "  ...the next playAt opens a fresh device and plays");
    lj_stop(engine);
  }

  lj_destroy(engine);

  std::printf("\n=== %d/%d checks passed\n", g_checks - g_failures, g_checks);
  return g_failures == 0 ? 0 : 1;
}
