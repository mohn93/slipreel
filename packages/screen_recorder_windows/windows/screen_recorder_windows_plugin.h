#ifndef FLUTTER_PLUGIN_SCREEN_RECORDER_WINDOWS_PLUGIN_H_
#define FLUTTER_PLUGIN_SCREEN_RECORDER_WINDOWS_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/event_channel.h>

#include <memory>
#include <mutex>

namespace screen_recorder_windows {

class GraphicsCaptureManager;
class CursorTracker;

class ScreenRecorderWindowsPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows *registrar);

  ScreenRecorderWindowsPlugin(flutter::PluginRegistrarWindows* registrar);

  virtual ~ScreenRecorderWindowsPlugin();

  // Disallow copy and assign.
  ScreenRecorderWindowsPlugin(const ScreenRecorderWindowsPlugin&) = delete;
  ScreenRecorderWindowsPlugin& operator=(const ScreenRecorderWindowsPlugin&) = delete;

  // Called when a method is called on this plugin's channel from Dart.
  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue> &method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> frames_sink_;
  std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> cursor_sink_;

 private:
  flutter::PluginRegistrarWindows* registrar_;
  std::unique_ptr<GraphicsCaptureManager> capture_manager_;
  std::unique_ptr<CursorTracker> cursor_tracker_;
  std::mutex frames_sink_mutex_;
  std::mutex cursor_sink_mutex_;
};

}  // namespace screen_recorder_windows

#endif  // FLUTTER_PLUGIN_SCREEN_RECORDER_WINDOWS_PLUGIN_H_
