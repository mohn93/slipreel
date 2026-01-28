#include "screen_recorder_windows_plugin.h"
#include "graphics_capture_manager.h"

// This must be included before many other Windows headers.
#include <windows.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>

#include <memory>
#include <sstream>

namespace screen_recorder_windows {

// static
void ScreenRecorderWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows *registrar) {

  auto method_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(),
          "com.screenflow_studio.screen_recorder/methods",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<ScreenRecorderWindowsPlugin>(registrar);

  method_channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto &call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  // Event channel for frames
  auto frames_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
      registrar->messenger(),
      "com.screenflow_studio.screen_recorder/frames",
      &flutter::StandardMethodCodec::GetInstance());

  auto frames_handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
      [plugin_pointer = plugin.get()](
          const flutter::EncodableValue* arguments,
          std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {

          plugin_pointer->frames_sink_ = std::move(events);
          return nullptr;
      },
      [plugin_pointer = plugin.get()](
          const flutter::EncodableValue* arguments)
          -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {

          plugin_pointer->frames_sink_ = nullptr;
          return nullptr;
      });

  frames_channel->SetStreamHandler(std::move(frames_handler));

  registrar->AddPlugin(std::move(plugin));
}

ScreenRecorderWindowsPlugin::ScreenRecorderWindowsPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar),
      capture_manager_(std::make_unique<GraphicsCaptureManager>()) {
}

ScreenRecorderWindowsPlugin::~ScreenRecorderWindowsPlugin() {
}

void ScreenRecorderWindowsPlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue> &method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

  const auto& method = method_call.method_name();

  if (method == "requestPermissions") {
    HWND window = registrar_->GetView()->GetNativeWindow();
    bool granted = capture_manager_->RequestPermission(window);
    result->Success(flutter::EncodableValue(granted));
  }
  else if (method == "checkPermissions") {
    bool has_permission = capture_manager_->CheckPermissions();
    result->Success(flutter::EncodableValue(has_permission));
  }
  else if (method == "getAvailableWindows") {
    auto windows = capture_manager_->GetAvailableWindows();
    flutter::EncodableList windows_list;

    for (const auto& window : windows) {
      flutter::EncodableMap window_map;
      window_map[flutter::EncodableValue("id")] = flutter::EncodableValue(window.id);
      window_map[flutter::EncodableValue("title")] = flutter::EncodableValue(window.title);
      window_map[flutter::EncodableValue("ownerName")] = flutter::EncodableValue(window.owner_name);
      window_map[flutter::EncodableValue("x")] = flutter::EncodableValue(window.x);
      window_map[flutter::EncodableValue("y")] = flutter::EncodableValue(window.y);
      window_map[flutter::EncodableValue("width")] = flutter::EncodableValue(window.width);
      window_map[flutter::EncodableValue("height")] = flutter::EncodableValue(window.height);
      window_map[flutter::EncodableValue("isOnScreen")] = flutter::EncodableValue(window.is_on_screen);
      windows_list.push_back(flutter::EncodableValue(window_map));
    }

    result->Success(flutter::EncodableValue(windows_list));
  }
  else if (method == "getAvailableScreens") {
    auto screens = capture_manager_->GetAvailableScreens();
    flutter::EncodableList screens_list;

    for (const auto& screen : screens) {
      flutter::EncodableMap screen_map;
      screen_map[flutter::EncodableValue("id")] = flutter::EncodableValue(screen.id);
      screen_map[flutter::EncodableValue("name")] = flutter::EncodableValue(screen.name);
      screen_map[flutter::EncodableValue("width")] = flutter::EncodableValue(screen.width);
      screen_map[flutter::EncodableValue("height")] = flutter::EncodableValue(screen.height);
      screen_map[flutter::EncodableValue("isPrimary")] = flutter::EncodableValue(screen.is_primary);
      screens_list.push_back(flutter::EncodableValue(screen_map));
    }

    result->Success(flutter::EncodableValue(screens_list));
  }
  else if (method == "getAudioDevices") {
    // TODO: Implement audio device enumeration
    flutter::EncodableList devices_list;
    result->Success(flutter::EncodableValue(devices_list));
  }
  else if (method == "startRecording") {
    const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (!arguments) {
      result->Error("INVALID_ARGUMENTS", "Expected map arguments");
      return;
    }

    auto source_id_it = arguments->find(flutter::EncodableValue("sourceId"));
    auto fps_it = arguments->find(flutter::EncodableValue("frameRate"));

    if (source_id_it == arguments->end()) {
      result->Error("MISSING_ARGUMENTS", "sourceId required");
      return;
    }

    const std::string source_id = std::get<std::string>(source_id_it->second);
    const int fps = fps_it != arguments->end() ? std::get<int>(fps_it->second) : 30;

    bool success = capture_manager_->StartCapture(source_id, fps,
        [this](const FrameDataNative& frame) {
            if (frames_sink_) {
              flutter::EncodableMap frame_map;
              frame_map[flutter::EncodableValue("data")] = flutter::EncodableValue(frame.data);
              frame_map[flutter::EncodableValue("width")] = flutter::EncodableValue(frame.width);
              frame_map[flutter::EncodableValue("height")] = flutter::EncodableValue(frame.height);
              frame_map[flutter::EncodableValue("timestampMicros")] =
                  flutter::EncodableValue(frame.timestamp_micros);
              frame_map[flutter::EncodableValue("format")] = flutter::EncodableValue("bgra");

              frames_sink_->Success(flutter::EncodableValue(frame_map));
            }
        });

    if (success) {
      result->Success();
    } else {
      result->Error("START_FAILED", "Failed to start capture");
    }
  }
  else if (method == "pauseRecording") {
    // TODO: Implement pause
    result->Success();
  }
  else if (method == "resumeRecording") {
    // TODO: Implement resume
    result->Success();
  }
  else if (method == "stopRecording") {
    capture_manager_->StopCapture();
    // TODO: Return actual output path
    result->Success(flutter::EncodableValue("C:\\Users\\recording.mp4"));
  }
  else {
    result->NotImplemented();
  }
}

}  // namespace screen_recorder_windows
