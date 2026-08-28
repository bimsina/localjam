/*
 * The single translation unit that materialises the vendored header-only
 * libraries (miniaudio, dr_wav, dr_flac, dr_mp3). Kept separate from
 * localjam_audio_core.cpp so the ~5 MB of third-party code is compiled as C,
 * once, and never recompiled while iterating on the engine.
 *
 * third_party/stb_vorbis.c is its own translation unit (it is already a .c
 * file) and is added to the build alongside this one.
 *
 * Build settings are in localjam_audio_third_party.h so every TU agrees.
 */

#include "localjam_audio_third_party.h"

#define MINIAUDIO_IMPLEMENTATION
#include "third_party/miniaudio.h"

#define DR_WAV_IMPLEMENTATION
#include "third_party/dr_wav.h"

#define DR_FLAC_IMPLEMENTATION
#include "third_party/dr_flac.h"

#define DR_MP3_IMPLEMENTATION
#include "third_party/dr_mp3.h"
