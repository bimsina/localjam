# Vendored third-party sources

All four libraries below are single-file, dependency-free, and available under
public-domain-equivalent terms, which is why they can be checked in verbatim and
compiled straight into the Windows/Linux plugin binaries. Each file carries its
full licence text at the bottom of the file itself; nothing here modifies or
overrides that.

| File | Version | Upstream | Licence |
| --- | --- | --- | --- |
| `miniaudio.h` | 0.11.25 | https://github.com/mackron/miniaudio | Public domain (Unlicense) **or** MIT-0, at your option |
| `dr_wav.h` | 0.14.x | https://github.com/mackron/dr_libs | Public domain (Unlicense) **or** MIT-0, at your option |
| `dr_flac.h` | 0.13.x | https://github.com/mackron/dr_libs | Public domain (Unlicense) **or** MIT-0, at your option |
| `dr_mp3.h` | 0.7.x | https://github.com/mackron/dr_libs | Public domain (Unlicense) **or** MIT-0, at your option |
| `stb_vorbis.c` | 1.22 | https://github.com/nothings/stb | Public domain (Unlicense) **or** MIT, at your option |

None of them require attribution in a shipped binary; this file exists so the
provenance is obvious to anyone auditing the tree.

## Why vendored rather than fetched at build time

The Flutter desktop build (`flutter build windows` / `flutter build linux`) runs
CMake with no package manager and no guaranteed network access. `FetchContent`
against GitHub would make every clean build depend on the network and on
upstream tags staying put. Five files totalling ~5 MB of header-only C is the
cheaper trade.

## Files are unmodified

`miniaudio.h`, `dr_wav.h`, `dr_flac.h`, `dr_mp3.h` and `stb_vorbis.c` are byte
-for-byte upstream. All LocalJam-specific configuration (feature switches,
`STB_VORBIS_HEADER_ONLY`, the `extern "C"` wrapper stb_vorbis lacks) lives in
`../localjam_audio_third_party.h` and `../localjam_audio_deps.c`, so re-vendoring
a newer version is a straight file copy.

## What miniaudio is configured to do

`../localjam_audio_deps.c` disables everything the engine does not use —
recording, the node graph, the resource manager, miniaudio's own decoders and
encoders, generation, and every non-desktop backend — leaving WASAPI on Windows,
PulseAudio/ALSA/JACK on Linux, and CoreAudio on macOS (used only by the local
test harness). Decoding is done by the `dr_*`/`stb_vorbis` libraries directly
rather than through `ma_decoder`, so the same four decoders are used on every
platform.
