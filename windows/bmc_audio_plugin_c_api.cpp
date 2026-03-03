#include "include/bmc_audio/bmc_audio_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "bmc_audio_plugin.h"

void BmcAudioPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  bmc_audio::BmcAudioPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
