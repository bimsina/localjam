#include "include/localjam_audio/localjam_audio_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "localjam_audio_plugin.h"

void LocaljamAudioPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  localjam_audio::LocaljamAudioPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
