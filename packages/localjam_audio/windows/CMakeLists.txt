# The Flutter tooling requires that developers have a version of Visual Studio
# installed that includes CMake 3.14 or later. You should not increase this
# version, as doing so will cause the plugin to fail to compile for some
# customers of the plugin.
cmake_minimum_required(VERSION 3.14)

# Project-level configuration. C is enabled alongside C++ because the vendored
# single-file audio libraries (miniaudio, dr_wav/dr_flac/dr_mp3, stb_vorbis) are
# compiled as C translation units — see ../src/third_party/LICENSES.md.
set(PROJECT_NAME "localjam_audio")
project(${PROJECT_NAME} LANGUAGES CXX C)

# Explicitly opt in to modern CMake behaviors to avoid warnings with recent
# versions of CMake.
cmake_policy(VERSION 3.14...3.25)

# This value is used when generating builds using this plugin, so it must
# not be changed
set(PLUGIN_NAME "localjam_audio_plugin")

# The shared engine, identical to the one the Linux plugin builds and the one
# ../src/test/core_test.cpp exercises against a real device.
# Resolved lexically rather than as "${CMAKE_CURRENT_SOURCE_DIR}/../src": at
# build time this directory is reached through
# flutter/ephemeral/.plugin_symlinks/localjam_audio, and stripping the last
# component keeps the path inside that symlinked view of the package.
get_filename_component(LOCALJAM_AUDIO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}" DIRECTORY)
set(LOCALJAM_AUDIO_SRC "${LOCALJAM_AUDIO_ROOT}/src")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "localjam_audio_plugin.cpp"
  "localjam_audio_plugin.h"
  "${LOCALJAM_AUDIO_SRC}/localjam_audio_core.cpp"
  "${LOCALJAM_AUDIO_SRC}/localjam_audio_core.h"
  "${LOCALJAM_AUDIO_SRC}/localjam_audio_deps.c"
  "${LOCALJAM_AUDIO_SRC}/third_party/stb_vorbis.c"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  "include/localjam_audio/localjam_audio_plugin_c_api.h"
  "localjam_audio_plugin_c_api.cpp"
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# The vendored libraries are third-party code kept byte-for-byte upstream; their
# warnings are not actionable here and /W4 + /WX (apply_standard_settings) would
# fail the build on them.
set_source_files_properties(
  "${LOCALJAM_AUDIO_SRC}/localjam_audio_deps.c"
  "${LOCALJAM_AUDIO_SRC}/third_party/stb_vorbis.c"
  PROPERTIES COMPILE_FLAGS "/W0 /WX-"
)

target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)

# Symbols are hidden by default to reduce the chance of accidental conflicts
# between plugins. This should not be removed; any symbols that should be
# exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

# Source include directories and library dependencies. Add any plugin-specific
# dependencies here.
target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")
target_include_directories(${PLUGIN_NAME} PRIVATE "${LOCALJAM_AUDIO_SRC}")
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# miniaudio's WASAPI backend. It loads ole32/ksuser symbols itself, but the
# link-time dependencies below are the ones its documentation lists for a static
# build on MSVC.
target_link_libraries(${PLUGIN_NAME} PRIVATE ole32 winmm)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(localjam_audio_bundled_libraries
  ""
  PARENT_SCOPE
)
