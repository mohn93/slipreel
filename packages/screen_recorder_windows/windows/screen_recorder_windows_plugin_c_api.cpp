#include "include/screen_recorder_windows/screen_recorder_windows_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "screen_recorder_windows_plugin.h"

void ScreenRecorderWindowsPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  screen_recorder_windows::ScreenRecorderWindowsPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
