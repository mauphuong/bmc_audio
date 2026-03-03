//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <bmc_audio/bmc_audio_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) bmc_audio_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "BmcAudioPlugin");
  bmc_audio_plugin_register_with_registrar(bmc_audio_registrar);
}
