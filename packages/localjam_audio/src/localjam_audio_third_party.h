/*
 * Single place where the vendored third-party headers are configured and
 * included, so localjam_audio_core.cpp, localjam_audio_deps.c and the test
 * harness all see exactly the same feature switches.
 *
 * Include this header for DECLARATIONS ONLY. The implementations live in
 * localjam_audio_deps.c (miniaudio + dr_wav + dr_flac + dr_mp3) and in
 * third_party/stb_vorbis.c, each compiled as its own C translation unit.
 */

#ifndef LOCALJAM_AUDIO_THIRD_PARTY_H_
#define LOCALJAM_AUDIO_THIRD_PARTY_H_

/* --- miniaudio -------------------------------------------------------------
 * Only the raw device + resampler are used. Everything else is compiled out to
 * keep the plugin binary small and the attack surface boring: no recording, no
 * node graph / engine / resource manager, no miniaudio-side decoding or
 * encoding (the dr_ and stb_vorbis decoders below do that), no waveform or noise
 * generation. Backends are narrowed to the desktop ones this plugin targets.
 */
#define MA_NO_ENCODING
#define MA_NO_DECODING
#define MA_NO_GENERATION
#define MA_NO_NODE_GRAPH
#define MA_NO_ENGINE
#define MA_NO_RESOURCE_MANAGER

/* Backends: WASAPI (Windows), PulseAudio/ALSA/JACK (Linux), CoreAudio (macOS,
 * used only by src/test — this file is never built into an iOS/macOS plugin).
 * DirectSound/WinMM stay enabled as WASAPI fallbacks on old Windows. */
#define MA_NO_WEBAUDIO
#define MA_NO_AAUDIO
#define MA_NO_OPENSL
#define MA_NO_SNDIO
#define MA_NO_AUDIO4
#define MA_NO_OSS
#define MA_NO_CUSTOM

#include "third_party/miniaudio.h"

/* --- dr_libs ---------------------------------------------------------------
 * dr_wav keeps its encoder: the local test harness writes its fixture WAV with
 * it, and it is a few KB. dr_flac/dr_mp3 are decode-only by nature.
 */
#include "third_party/dr_flac.h"
#include "third_party/dr_mp3.h"
#include "third_party/dr_wav.h"

/* --- stb_vorbis ------------------------------------------------------------
 * stb_vorbis.c is a .c file that doubles as its own header under
 * STB_VORBIS_HEADER_ONLY, and — unlike the headers above — has no `extern "C"`
 * guard of its own, so C++ callers must supply one. <stdio.h> is pulled in
 * first, outside the linkage block, because stb_vorbis includes it and system
 * headers must not be re-declared with C linkage from inside a C++ TU.
 */
#include <stdio.h>

#if defined(__cplusplus)
extern "C" {
#endif

#define STB_VORBIS_HEADER_ONLY
#include "third_party/stb_vorbis.c"
#undef STB_VORBIS_HEADER_ONLY

#if defined(__cplusplus)
} /* extern "C" */
#endif

#endif /* LOCALJAM_AUDIO_THIRD_PARTY_H_ */
