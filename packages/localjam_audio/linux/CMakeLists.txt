# The Flutter tooling requires that developers have CMake 3.10 or later
# installed. You should not increase this version, as doing so will cause
# the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration. C is enabled alongside C++ because the vendored
# single-file audio libraries (miniaudio, dr_wav/dr_flac/dr_mp3, stb_vorbis) are
# compiled as C translation units — see ../src/third_party/LICENSES.md.
set(PROJECT_NAME "localjam_audio")
project(${PROJECT_NAME} LANGUAGES CXX C)

# This value is used when generating builds using this plugin, so it must
# not be changed.
set(PLUGIN_NAME "localjam_audio_plugin")

# The shared engine, identical to the one the Windows plugin builds and the one
# ../src/test/core_test.cpp exercises against a real device.
# Resolved lexically rather than as "${CMAKE_CURRENT_SOURCE_DIR}/../src": at
# build time this directory is reached through
# flutter/ephemeral/.plugin_symlinks/localjam_audio, and stripping the last
# component keeps the path inside that symlinked view of the package.
get_filename_component(LOCALJAM_AUDIO_ROOT "${CMAKE_CURRENT_SOURCE_DIR}" DIRECTORY)
set(LOCALJAM_AUDIO_SRC "${LOCALJAM_AUDIO_ROOT}/src")

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES
  "localjam_audio_plugin.cc"
  "${LOCALJAM_AUDIO_SRC}/localjam_audio_core.cpp"
  "${LOCALJAM_AUDIO_SRC}/localjam_audio_deps.c"
  "${LOCALJAM_AUDIO_SRC}/third_party/stb_vorbis.c"
)

# Define the plugin library target. Its name must not be changed (see comment
# on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED
  ${PLUGIN_SOURCES}
)

# Apply a standard set of build settings that are configured in the
# application-level CMakeLists.txt. This can be removed for plugins that want
# full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# The vendored libraries are third-party code kept byte-for-byte upstream; their
# warnings are not actionable here.
set_source_files_properties(
  "${LOCALJAM_AUDIO_SRC}/localjam_audio_deps.c"
  "${LOCALJAM_AUDIO_SRC}/third_party/stb_vorbis.c"
  PROPERTIES COMPILE_FLAGS "-w"
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
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)

# miniaudio dlopen()s ALSA / PulseAudio / JACK at runtime, so none of them is a
# build-time dependency: only libdl, pthreads and libm are needed at link time.
# This is what keeps the plugin installable on a machine with any one of those
# servers present.
find_package(Threads REQUIRED)
target_link_libraries(${PLUGIN_NAME} PRIVATE ${CMAKE_DL_LIBS} Threads::Threads m)

# List of absolute paths to libraries that should be bundled with the plugin.
# This list could contain prebuilt libraries, or libraries created by an
# external build triggered from this build file.
set(localjam_audio_bundled_libraries
  ""
  PARENT_SCOPE
)
