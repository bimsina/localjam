/*
 * core_unit_test.cpp — device-free checks of the shared desktop core.
 *
 * core_test.cpp proves the scheduling math against a real output device; this
 * binary covers what a real device cannot be made to do on demand, and runs in
 * well under a second with no audio hardware at all:
 *
 *   1. The route state machine (lj_internal::RouteWatch) replayed with the
 *      exact notification orderings the backends produce: a WASAPI default
 *      device change stops, reroutes and restarts the stream (and must NOT read
 *      as a lost device — it used to, as playbackError{device_lost}, on every
 *      Windows output switch); an unplug with nothing to fall back to never
 *      restarts; PulseAudio suspends without a state change; a device can die
 *      without any notification at all.
 *   2. Stream sizing: the decode chunk always fits the ring (a chunk larger
 *      than the ring stalled the decoder forever) and nothing is sized from a
 *      header value alone.
 *   3. Crafted files: absurd sample rates and frame counts are refused at
 *      load/probe instead of sizing gigabyte buffers.
 *   4. Route-id hashing matches the iOS/macOS plugin's FNV-1a 64.
 */

#include "../localjam_audio_core.h"
#include "../localjam_audio_internal.h"

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

namespace {

using lj_internal::DeviceSignal;
using lj_internal::RouteVerdict;
using lj_internal::RouteWatch;

int g_failures = 0;
int g_checks = 0;

void Check(bool ok, const std::string& what) {
  ++g_checks;
  if (!ok) {
    ++g_failures;
  }
  std::printf("  %s  %s\n", ok ? "ok  " : "FAIL", what.c_str());
}

const char* Name(RouteVerdict v) {
  switch (v) {
    case RouteVerdict::kNone:
      return "none";
    case RouteVerdict::kResumed:
      return "resumed";
    case RouteVerdict::kRerouted:
      return "rerouted";
    case RouteVerdict::kOutputLost:
      return "outputLost";
  }
  return "?";
}

void CheckVerdict(RouteVerdict got, RouteVerdict want, const std::string& what) {
  Check(got == want, what + " -> " + Name(got) + " (want " + Name(want) + ")");
}

constexpr int64_t kMs = 1000;
constexpr int64_t kDebounce = LJ_ROUTE_DEBOUNCE_US;

// ------------------------------------------------------------- route watch

void TestRouteWatch() {
  std::printf("\n=== 1. route state machine\n");

  {
    // miniaudio WASAPI, OnDefaultDeviceChanged: ma_device_stop -> reroute ->
    // ma_device_start, synchronously, before the monitor ever polls.
    RouteWatch w;
    w.OnSignal(DeviceSignal::kStopped, 0, false);
    w.OnSignal(DeviceSignal::kRerouted, 1 * kMs, false);
    w.OnSignal(DeviceSignal::kStarted, 2 * kMs, false);
    CheckVerdict(w.Poll(10 * kMs, true), RouteVerdict::kRerouted,
                 "WASAPI default switch (stop, reroute, start)");
    CheckVerdict(w.Poll(20 * kMs, true), RouteVerdict::kNone,
                 "  ...reported once");
    CheckVerdict(w.Poll(20 * kMs + kDebounce, true), RouteVerdict::kNone,
                 "  ...and never turns into a lost device");
    Check(!w.down() && !w.lost(), "  ...output up afterwards (unmuted)");
  }

  {
    // The same switch with the monitor polling BETWEEN the notifications, with
    // the device state still "stopped" mid-reroute: the very sequence the old
    // code reported as playbackError{device_lost}.
    RouteWatch w;
    w.OnSignal(DeviceSignal::kStopped, 0, false);
    CheckVerdict(w.Poll(1 * kMs, false), RouteVerdict::kNone,
                 "WASAPI reroute polled mid-flight: stopped, state not started");
    Check(w.down(), "  ...output muted while undecided");
    w.OnSignal(DeviceSignal::kRerouted, 3 * kMs, false);
    CheckVerdict(w.Poll(4 * kMs, false), RouteVerdict::kNone,
                 "  ...rerouted, not restarted yet");
    w.OnSignal(DeviceSignal::kStarted, 5 * kMs, false);
    CheckVerdict(w.Poll(6 * kMs, true), RouteVerdict::kRerouted,
                 "  ...restarted: a reroute, not a loss");
  }

  {
    // WASAPI headphones unplugged with speakers available, endpoint-state
    // notification first: ma_device_stop (detached), then the default-device
    // change reroutes and restarts tens of ms later. A reroute verdict — the
    // core then finds the old endpoint gone and STOPS (no jump to speaker).
    RouteWatch w;
    w.OnSignal(DeviceSignal::kStopped, 0, false);
    CheckVerdict(w.Poll(10 * kMs, false), RouteVerdict::kNone,
                 "unplug with fallback: endpoint gone, default not moved yet");
    CheckVerdict(w.Poll(40 * kMs, false), RouteVerdict::kNone,
                 "  ...still inside the debounce");
    w.OnSignal(DeviceSignal::kRerouted, 45 * kMs, false);
    w.OnSignal(DeviceSignal::kStarted, 46 * kMs, false);
    CheckVerdict(w.Poll(50 * kMs, true), RouteVerdict::kRerouted,
                 "  ...default moved to the speaker");
    Check(lj_internal::RerouteLostOldDevice(true, false),
          "  ...previous endpoint no longer listed -> oldDeviceUnavailable");
    Check(!lj_internal::RerouteLostOldDevice(true, true),
          "  user switched outputs (previous still listed) -> keep playing");
    Check(!lj_internal::RerouteLostOldDevice(false, false),
          "  no record of the previous output -> keep playing (never a false "
          "unplug)");
  }

  {
    // Unplugged with nothing to fall back to: stopped, never restarted
    // (OnDefaultDeviceChanged with a NULL default does nothing).
    RouteWatch w;
    w.OnSignal(DeviceSignal::kStopped, 0, false);
    bool early = false;
    for (int64_t t = 10 * kMs; t < kDebounce; t += 10 * kMs) {
      early = early || w.Poll(t, false) != RouteVerdict::kNone;
    }
    Check(!early, "no fallback output: nothing decided inside the debounce");
    CheckVerdict(w.Poll(kDebounce, false), RouteVerdict::kOutputLost,
                 "  ...output lost once the debounce expires");
    Check(w.lost() && w.down(), "  ...latched (stays muted, device not reused)");
    w.OnSignal(DeviceSignal::kRerouted, kDebounce + 50 * kMs, false);
    w.OnSignal(DeviceSignal::kStarted, kDebounce + 51 * kMs, false);
    CheckVerdict(w.Poll(kDebounce + 60 * kMs, true), RouteVerdict::kNone,
                 "  ...a later replug does not resurrect the schedule");
  }

  {
    // The device dies with the hardware and the backend sends nothing.
    RouteWatch w;
    CheckVerdict(w.Poll(0, true), RouteVerdict::kNone, "healthy device");
    CheckVerdict(w.Poll(10 * kMs, false), RouteVerdict::kNone,
                 "silent death: state not started, no notification");
    CheckVerdict(w.Poll(10 * kMs + kDebounce - 1, false), RouteVerdict::kNone,
                 "  ...1 us before the debounce");
    CheckVerdict(w.Poll(10 * kMs + kDebounce, false), RouteVerdict::kOutputLost,
                 "  ...lost at the debounce");
  }

  {
    // PulseAudio sink suspended and resumed: "stopped"/"started" with the
    // ma_device state left at started throughout.
    RouteWatch w;
    w.OnSignal(DeviceSignal::kStopped, 0, false);
    CheckVerdict(w.Poll(10 * kMs, true), RouteVerdict::kNone,
                 "PulseAudio suspend (state still started) counts as down");
    Check(w.down(), "  ...muted");
    w.OnSignal(DeviceSignal::kStarted, 50 * kMs, false);
    CheckVerdict(w.Poll(60 * kMs, true), RouteVerdict::kResumed,
                 "  ...resume: same route, re-measure the clock, no event");
    Check(!w.down(), "  ...unmuted");
  }

  {
    // PulseAudio stream moved to another sink: only "rerouted".
    RouteWatch w;
    w.OnSignal(DeviceSignal::kRerouted, 0, false);
    CheckVerdict(w.Poll(5 * kMs, true), RouteVerdict::kRerouted,
                 "PulseAudio stream move (rerouted alone)");
  }

  {
    // Our own close: ma_device_uninit's "stopped" is expected.
    RouteWatch w;
    w.OnSignal(DeviceSignal::kStopped, 0, true);
    Check(!w.down(), "our own stop is never a loss (not even muted)");
    CheckVerdict(w.Poll(kDebounce * 2, true), RouteVerdict::kNone,
                 "  ...and decides nothing");
  }

  {
    // A suspension that outlasts the debounce is a loss even if it resumes.
    RouteWatch w;
    w.OnSignal(DeviceSignal::kStopped, 0, false);
    CheckVerdict(w.Poll(kDebounce, true), RouteVerdict::kOutputLost,
                 "suspended for the whole debounce -> lost");
    w.OnSignal(DeviceSignal::kStarted, kDebounce + kMs, false);
    CheckVerdict(w.Poll(kDebounce + 2 * kMs, true), RouteVerdict::kNone,
                 "  ...the late resume changes nothing");
  }

  {
    // Two switches in a row are two reroutes.
    RouteWatch w;
    for (int i = 0; i < 2; ++i) {
      const int64_t t = static_cast<int64_t>(i) * 100 * kMs;
      w.OnSignal(DeviceSignal::kStopped, t, false);
      w.OnSignal(DeviceSignal::kRerouted, t + kMs, false);
      w.OnSignal(DeviceSignal::kStarted, t + 2 * kMs, false);
      CheckVerdict(w.Poll(t + 5 * kMs, true), RouteVerdict::kRerouted,
                   "back-to-back switch #" + std::to_string(i + 1));
    }
  }
}

// ------------------------------------------------------------------ sizing

void TestSizing() {
  std::printf("\n=== 2. stream sizing\n");
  const uint32_t rates[] = {LJ_MIN_SAMPLE_RATE, 8000,   22050,  44100,
                            48000,              96000,  192000, LJ_MAX_SAMPLE_RATE,
                            // Never reach the decoder (refused at load), but
                            // the sizing must not depend on that.
                            1,                  3999,   20000000u,
                            2147483647u,        4294967295u};
  bool all_fit = true;
  bool all_bounded = true;
  std::string worst;
  for (uint32_t rate : rates) {
    for (uint32_t ch = 1; ch <= 2; ++ch) {
      const lj_internal::StreamSizing z =
          lj_internal::ComputeStreamSizing(rate, ch);
      if (z.chunk_frames == 0 || z.chunk_frames > z.ring_frames / 2) {
        all_fit = false;
        worst = std::to_string(rate) + " Hz x" + std::to_string(ch);
      }
      // The ring may be floored at 2048 frames; otherwise <= LJ_RING_MAX_BYTES.
      const size_t bytes = z.ring_frames * ch * sizeof(float);
      if (bytes > static_cast<size_t>(LJ_RING_MAX_BYTES) &&
          z.ring_frames > 2048) {
        all_bounded = false;
        worst = std::to_string(rate) + " Hz x" + std::to_string(ch);
      }
    }
  }
  Check(all_fit, "decode chunk is non-empty and <= ring/2 at every rate " +
                     (worst.empty() ? std::string() : "(fails " + worst + ")"));
  Check(all_bounded, "ring never exceeds LJ_RING_MAX_BYTES, whatever the rate");
  const lj_internal::StreamSizing z = lj_internal::ComputeStreamSizing(48000, 2);
  Check(z.chunk_frames == 2400 && z.ring_frames == 384000,
        "48 kHz stereo keeps its tuned sizes (chunk " +
            std::to_string(z.chunk_frames) + ", ring " +
            std::to_string(z.ring_frames) + ")");
}

// ------------------------------------------------------------ crafted files

void Put16(std::vector<uint8_t>* b, uint16_t v) {
  b->push_back(static_cast<uint8_t>(v & 0xff));
  b->push_back(static_cast<uint8_t>(v >> 8));
}
void Put32(std::vector<uint8_t>* b, uint32_t v) {
  for (int i = 0; i < 4; ++i) {
    b->push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
  }
}
void Put64(std::vector<uint8_t>* b, uint64_t v) {
  for (int i = 0; i < 8; ++i) {
    b->push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
  }
}
void PutTag(std::vector<uint8_t>* b, const char* tag) {
  b->insert(b->end(), tag, tag + 4);
}

// 16-bit PCM WAV declaring `sample_rate` with `frames` frames of silence.
std::vector<uint8_t> Wav(uint32_t sample_rate, uint16_t channels,
                         uint32_t frames) {
  const uint32_t block = channels * 2u;
  const uint32_t data = frames * block;
  std::vector<uint8_t> b;
  PutTag(&b, "RIFF");
  Put32(&b, 36 + data);
  PutTag(&b, "WAVE");
  PutTag(&b, "fmt ");
  Put32(&b, 16);
  Put16(&b, 1);
  Put16(&b, channels);
  Put32(&b, sample_rate);
  Put32(&b, sample_rate * block);  // wraps for absurd rates; dr_wav ignores it
  Put16(&b, static_cast<uint16_t>(block));
  Put16(&b, 16);
  PutTag(&b, "data");
  Put32(&b, data);
  b.resize(b.size() + data, 0);
  return b;
}

// RF64 WAV whose ds64 chunk declares `frames` (a 64-bit count) while the file
// holds one second of audio: the shape of a crafted "endless" upload.
std::vector<uint8_t> Rf64(uint64_t frames) {
  const uint32_t rate = 44100;
  const uint16_t channels = 2;
  const uint32_t block = channels * 2u;
  std::vector<uint8_t> b;
  PutTag(&b, "RF64");
  Put32(&b, 0xFFFFFFFFu);
  PutTag(&b, "WAVE");
  PutTag(&b, "ds64");
  Put32(&b, 28);
  Put64(&b, frames * block + 72);  // RIFF size
  Put64(&b, frames * block);       // data size
  Put64(&b, frames);               // sample count
  Put32(&b, 0);                    // table length
  PutTag(&b, "fmt ");
  Put32(&b, 16);
  Put16(&b, 1);
  Put16(&b, channels);
  Put32(&b, rate);
  Put32(&b, rate * block);
  Put16(&b, static_cast<uint16_t>(block));
  Put16(&b, 16);
  PutTag(&b, "data");
  Put32(&b, 0xFFFFFFFFu);
  b.resize(b.size() + rate * block, 0);
  return b;
}

// A FLAC stream that is only its STREAMINFO block (no audio frames): enough
// for dr_flac to report rate / channels / total samples, which is all load and
// probeDuration read. FLAC's 20-bit rate field reaches 1,048,575 Hz — far past
// what dr_wav would ever accept — so this is how a crafted upload claims an
// absurd rate.
std::vector<uint8_t> FlacHeaderOnly(uint32_t sample_rate, uint64_t frames) {
  std::vector<uint8_t> b;
  PutTag(&b, "fLaC");
  b.push_back(0x80);  // last metadata block, type 0 (STREAMINFO)
  b.push_back(0);
  b.push_back(0);
  b.push_back(34);
  b.push_back(0x10);  // min block size 4096
  b.push_back(0x00);
  b.push_back(0x10);  // max block size 4096
  b.push_back(0x00);
  for (int i = 0; i < 6; ++i) {
    b.push_back(0);  // min/max frame size unknown
  }
  // rate(20) | channels-1 (3) | bits-1 (5) | total samples (36), big-endian.
  const uint64_t packed = (static_cast<uint64_t>(sample_rate & 0xFFFFF) << 44) |
                          (uint64_t{1} << 41) | (uint64_t{15} << 36) |
                          (frames & 0xFFFFFFFFFULL);
  for (int i = 7; i >= 0; --i) {
    b.push_back(static_cast<uint8_t>((packed >> (8 * i)) & 0xff));
  }
  b.resize(b.size() + 16, 0);  // MD5
  return b;
}

std::string WriteFile(const std::string& dir, const char* name,
                      const std::vector<uint8_t>& bytes) {
  const std::string path = dir + "/" + name;
  if (FILE* f = std::fopen(path.c_str(), "wb")) {
    if (!bytes.empty()) {
      std::fwrite(bytes.data(), 1, bytes.size(), f);
    }
    std::fclose(f);
  }
  return path;
}

void TestCraftedFiles(const std::string& dir) {
  std::printf("\n=== 3. crafted files (load / probeDuration)\n");
  lj_engine* engine = nullptr;
  char err[512] = {0};
  if (lj_create(&engine, nullptr, nullptr, lj_log_discard, nullptr, err,
                sizeof(err)) != LJ_OK) {
    Check(false, std::string("lj_create: ") + err);
    return;
  }

  struct Case {
    const char* name;
    uint32_t rate;
    bool ok;
    bool flac;
  };
  const Case cases[] = {
      {"sr_1.wav", 1, false, false},
      {"sr_3999.wav", 3999, false, false},
      {"sr_4000.wav", 4000, true, false},
      {"sr_384000.wav", 384000, true, false},
      {"sr_384001.wav", 384001, false, false},
      {"sr_20M.wav", 20000000u, false, false},
      {"sr_2g.wav", 2147483647u, false, false},
      {"sr_max.wav", 4294967295u, false, false},
      {"sr_1.flac", 1, false, true},
      {"sr_44100.flac", 44100, true, true},
      {"sr_384000.flac", 384000, true, true},
      {"sr_655350.flac", 655350, false, true},
      {"sr_1048575.flac", 1048575, false, true},
  };
  for (const Case& c : cases) {
    const std::string path =
        WriteFile(dir, c.name,
                  c.flac ? FlacHeaderOnly(c.rate, 4000) : Wav(c.rate, 2, 4000));
    int64_t probed = -1;
    err[0] = '\0';
    const lj_status ps = lj_probe_duration(path.c_str(), &probed, err,
                                           sizeof(err));
    int64_t loaded = -1;
    const lj_status ls = lj_load(engine, path.c_str(), &loaded, err,
                                 sizeof(err));
    const bool as_expected =
        c.ok ? (ps == LJ_OK && ls == LJ_OK && probed == loaded && loaded > 0)
             : (ps == LJ_ERR_LOAD_FAILED && ls == LJ_ERR_LOAD_FAILED &&
                probed == -1);
    Check(as_expected, std::string(c.name) + ": probe=" +
                           lj_status_code(ps) + " load=" + lj_status_code(ls) +
                           (c.ok ? " (accepted)" : " (refused)"));
  }
  {
    // After a refused load nothing is loaded (Apple parity).
    const std::string bad = WriteFile(dir, "sr_bad_again.wav", Wav(1, 2, 400));
    int64_t d = 0;
    lj_load(engine, bad.c_str(), &d, err, sizeof(err));
    const lj_status s = lj_play_at(engine, lj_now_us() + 300000, 0, 1.0, err,
                                   sizeof(err));
    Check(s == LJ_ERR_NO_FILE,
          std::string("playAt after a refused load -> ") + lj_status_code(s));
  }
  {
    const std::string huge = WriteFile(dir, "rf64_2^40.wav",
                                       Rf64(uint64_t{1} << 40));
    int64_t probed = -1;
    const lj_status ps = lj_probe_duration(huge.c_str(), &probed, err,
                                           sizeof(err));
    int64_t loaded = -1;
    const lj_status ls = lj_load(engine, huge.c_str(), &loaded, err,
                                 sizeof(err));
    // dr_wav may trust the ds64 count (then it must be refused) or clamp it
    // to the bytes actually present (then it is a plain 1 s file).
    const bool refused = ps == LJ_ERR_LOAD_FAILED && ls == LJ_ERR_LOAD_FAILED;
    const bool clamped = ps == LJ_OK && ls == LJ_OK && loaded <= 1000000;
    Check(refused || clamped,
          std::string("RF64 declaring 2^40 frames: probe=") +
              lj_status_code(ps) + " load=" + lj_status_code(ls) +
              " duration=" + std::to_string(loaded) +
              (refused ? " (refused)" : " (clamped to the data present)"));
  }
  {
    // FLAC's 36-bit sample count: 2^36-1 frames is inside LJ_MAX_FRAMES (it is
    // a plausible if absurd 18 days at 44.1 kHz) and loads; the schedule then
    // fails cleanly at seek time. 2^37 + 1 cannot be represented, so the
    // header-only maximum is checked at the boundary instead.
    const std::string flac = WriteFile(dir, "flac_2^36.flac",
                                       FlacHeaderOnly(44100, 0xFFFFFFFFFULL));
    int64_t probed = -1;
    const lj_status ps = lj_probe_duration(flac.c_str(), &probed, err,
                                           sizeof(err));
    Check(ps == LJ_OK && probed > 0,
          std::string("FLAC declaring 2^36-1 frames: probe=") +
              lj_status_code(ps) + " (within LJ_MAX_FRAMES)");
    Check(lj_internal::FrameCountOk(LJ_MAX_FRAMES) &&
              !lj_internal::FrameCountOk(LJ_MAX_FRAMES + 1) &&
              !lj_internal::FrameCountOk(0),
          "frame-count bound: (0, 2^37]");
  }
  lj_destroy(engine);
}

// ------------------------------------------------------------------- hashing

void TestHash() {
  std::printf("\n=== 4. route-id hash\n");
  // FNV-1a 64 reference vectors; LocaljamAudioPlugin.swift's stableHash
  // produces the same digits for the same bytes.
  Check(lj_internal::StableHash("", 0) == "cbf29ce484222325",
        "FNV-1a 64 of \"\" = cbf29ce484222325");
  Check(lj_internal::StableHash("a", 1) == "af63dc4c8601ec8c",
        "FNV-1a 64 of \"a\" = af63dc4c8601ec8c");
  Check(lj_internal::StableHash("foobar", 6) == "85944171f73967e8",
        "FNV-1a 64 of \"foobar\" = 85944171f73967e8");
}

// --------------------------------------------------------- MP3 media frame 0

// Media frame P is the gapless frame P on every platform (README "Media
// position"): a LAME tag is applied, and without one the 529-frame decoder
// delay is dropped as Android's and Apple's decoders do. The fixtures are
// the Android test ones (tool/gapless_fixtures.sh), 3 s of audio each.
void TestMp3MediaFrameZero() {
  std::printf("\n=== 5. MP3 media frame 0\n");
  std::string here = __FILE__;
  here = here.substr(0, here.find_last_of('/'));
  const std::string dir = here + "/../../android/src/test/resources/gapless/";
  struct Case {
    const char* file;
    int64_t want_us;
  } cases[] = {
      // LAME-tagged: exactly the 3 s that were encoded.
      {"lame_cbr_44100_stereo.mp3", 3000000},
      {"lame_vbr_22050_mono.mp3", 3000000},
      // No tag: 116 frames x 1152 minus the decoder delay.
      {"noxing_44100_mono.mp3", (116 * 1152 - 529) * 1000000LL / 44100},
  };
  char err[256];
  for (const Case& c : cases) {
    int64_t probed = -1;
    const lj_status s =
        lj_probe_duration((dir + c.file).c_str(), &probed, err, sizeof(err));
    Check(s == LJ_OK && std::llabs(probed - c.want_us) <= 1,
          std::string(c.file) + ": " + std::to_string(probed) + " us (want " +
              std::to_string(c.want_us) + ")");
  }
}

}  // namespace

int main() {
  const char* tmp = std::getenv("TMPDIR");
  const std::string dir =
      std::string(tmp != nullptr && tmp[0] != '\0' ? tmp : "/tmp") +
      "/localjam_audio_core_unit_test";
  const std::string mkdir_cmd = "mkdir -p '" + dir + "'";
  if (std::system(mkdir_cmd.c_str()) != 0) {
    std::printf("could not create %s\n", dir.c_str());
    return 1;
  }
  TestRouteWatch();
  TestSizing();
  TestCraftedFiles(dir);
  TestHash();
  TestMp3MediaFrameZero();
  std::printf("\n=== %d/%d unit checks passed\n", g_checks - g_failures,
              g_checks);
  return g_failures == 0 ? 0 : 1;
}
