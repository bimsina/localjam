#!/usr/bin/env bash
#
# Builds and runs the shared-core verification harness (src/test/core_test.cpp)
# on the current machine, against its real default output device.
#
#   ./src/test/build.sh          build and run
#   ./src/test/build.sh --build  build only
#
# The core is platform-independent C++17 on top of miniaudio, so this is the same
# code the Windows and Linux plugins compile — the only thing that differs is
# which miniaudio backend it lands on (CoreAudio here, WASAPI there,
# PulseAudio/ALSA on Linux). Verifying it here is what makes the unbuildable
# platform glue trustworthy.
#
# Linked frameworks/libraries follow the miniaudio build documentation.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="$(dirname "$here")"
out="${here}/build"
mkdir -p "$out"

uname_s="$(uname -s)"
case "$uname_s" in
  Darwin)
    cc=${CC:-clang}
    cxx=${CXX:-clang++}
    # miniaudio's CoreAudio backend. -lpthread/-lm are implicit in libSystem.
    link_flags=(-framework CoreFoundation -framework CoreAudio
                -framework AudioToolbox -framework AudioUnit)
    ;;
  Linux)
    cc=${CC:-cc}
    cxx=${CXX:-c++}
    # miniaudio dlopen()s ALSA/PulseAudio/JACK at runtime; only dl/pthread/m are
    # needed at link time.
    link_flags=(-ldl -lpthread -lm)
    ;;
  *)
    echo "unsupported host: $uname_s" >&2
    exit 1
    ;;
esac

warn=(-Wall -Wextra -Wno-unused-parameter)

echo "==> compiling third-party implementations (once; cached)"
if [ ! -f "$out/localjam_audio_deps.o" ] || \
   [ "$src/localjam_audio_deps.c" -nt "$out/localjam_audio_deps.o" ] || \
   [ "$src/localjam_audio_third_party.h" -nt "$out/localjam_audio_deps.o" ]; then
  "$cc" -std=c99 -O2 -g -c "$src/localjam_audio_deps.c" \
    -o "$out/localjam_audio_deps.o"
fi
if [ ! -f "$out/stb_vorbis.o" ] || \
   [ "$src/third_party/stb_vorbis.c" -nt "$out/stb_vorbis.o" ]; then
  # stb_vorbis has long-standing benign warnings; it is vendored verbatim.
  "$cc" -std=c99 -O2 -g -w -c "$src/third_party/stb_vorbis.c" \
    -o "$out/stb_vorbis.o"
fi

echo "==> compiling the core"
"$cxx" -std=c++17 -O2 -g "${warn[@]}" -c "$src/localjam_audio_core.cpp" \
  -o "$out/localjam_audio_core.o"

echo "==> compiling and linking the test"
"$cxx" -std=c++17 -O2 -g "${warn[@]}" "$here/core_test.cpp" \
  "$out/localjam_audio_core.o" "$out/localjam_audio_deps.o" \
  "$out/stb_vorbis.o" "${link_flags[@]}" -o "$out/core_test"

echo "==> compiling the overshoot-trim variant"
# Same core, but with the clock-model maturity gate forced to outlast
# LJ_MIN_LEAD_US so the anchor is guaranteed to pass during priming. That is the
# only way to reach the trim branch deterministically on a healthy machine.
"$cxx" -std=c++17 -O2 -g "${warn[@]}" -DLJ_MATURITY_SPAN_US=400000 \
  -c "$src/localjam_audio_core.cpp" -o "$out/localjam_audio_core_trim.o"
"$cxx" -std=c++17 -O2 -g "${warn[@]}" "$here/core_test.cpp" \
  "$out/localjam_audio_core_trim.o" "$out/localjam_audio_deps.o" \
  "$out/stb_vorbis.o" "${link_flags[@]}" -o "$out/core_test_trim"

echo "==> built $out/core_test and $out/core_test_trim"
if [ "${1:-}" != "--build" ]; then
  echo "==> running (this plays ~25 s of quiet audio on the default device)"
  "$out/core_test"
  echo
  echo "==> running the overshoot-trim variant"
  LJ_TEST_TRIM=1 "$out/core_test_trim"
fi
