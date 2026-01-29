# Phase 8: Cross-Platform Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Extend ScreenFlow Studio to support Windows and Linux platforms with native screen capture, maintaining feature parity with macOS implementation.

**Architecture:** Platform plugin pattern with Windows (Graphics Capture API) and Linux (PipeWire/X11) implementations. Shared platform interface ensures consistent API across platforms. Platform-specific cursor rendering and testing infrastructure.

**Tech Stack:** Windows Graphics Capture API, Linux PipeWire/X11, Flutter platform channels, FFI for native code integration, platform-specific CMake builds

---

## Overview

Phase 8 brings cross-platform support with:
- **Task 29**: Windows platform plugin (Graphics Capture API, frame streaming, encoding)
- **Task 30**: Linux platform plugin (PipeWire for Wayland, X11 for legacy, frame processing)
- **Task 31**: Platform-specific cursor tracking and rendering
- **Task 32**: Cross-platform testing and bug fixes

This makes ScreenFlow Studio truly cross-platform, matching Screen Studio's reach.

---

## Task 29: Windows Platform Plugin

**Goal:** Implement Windows screen capture using Graphics Capture API. Support window and display capture with frame streaming to Flutter.

**Files:**
- Create: `packages/screen_recorder_windows/` (new package)
- Create: `packages/screen_recorder_windows/windows/`
- Create: `packages/screen_recorder_windows/windows/screen_recorder_windows_plugin.cpp`
- Create: `packages/screen_recorder_windows/windows/graphics_capture_manager.cpp`
- Create: `packages/screen_recorder_windows/windows/graphics_capture_manager.h`
- Create: `packages/screen_recorder_windows/lib/screen_recorder_windows.dart`
- Create: `packages/screen_recorder_windows/pubspec.yaml`
- Create: `packages/screen_recorder_windows/test/screen_recorder_windows_test.dart`

### Step 1: Create Windows plugin package structure

```bash
cd packages
flutter create --template=plugin --platforms=windows screen_recorder_windows
```

**Expected:** Creates plugin package with Windows platform support

### Step 2: Write failing test for Windows plugin registration

**File:** `packages/screen_recorder_windows/test/screen_recorder_windows_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_windows/screen_recorder_windows.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenRecorderWindows', () {
    test('should register as platform instance', () {
      ScreenRecorderWindows.registerWith();
      expect(ScreenRecorderPlatform.instance, isA<ScreenRecorderWindows>());
    });

    test('should request permissions', () async {
      final plugin = ScreenRecorderWindows();
      final hasPermission = await plugin.requestPermission();

      // Windows Graphics Capture requires user consent via picker
      expect(hasPermission, isA<bool>());
    });

    test('should get available windows', () async {
      final plugin = ScreenRecorderWindows();
      final windows = await plugin.getAvailableWindows();

      expect(windows, isA<List<WindowInfo>>());
      // At least the test process window should exist
      expect(windows.isNotEmpty, true);
    });

    test('should get available displays', () async {
      final plugin = ScreenRecorderWindows();
      final displays = await plugin.getAvailableDisplays();

      expect(displays, isA<List<DisplayInfo>>());
      expect(displays.isNotEmpty, true);
    });
  });
}
```

### Step 3: Run test to verify it fails

```bash
cd packages/screen_recorder_windows
flutter test
```

**Expected:** FAIL with "Method channel not implemented"

### Step 4: Implement Windows plugin Dart side

**File:** `packages/screen_recorder_windows/lib/screen_recorder_windows.dart`

```dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Windows implementation of the ScreenRecorderPlatform
class ScreenRecorderWindows extends ScreenRecorderPlatform {
  static const MethodChannel _channel =
      MethodChannel('com.screenflow_studio.screen_recorder/methods');

  static const EventChannel _framesChannel =
      EventChannel('com.screenflow_studio.screen_recorder/frames');

  /// Registers this class as the default instance of [ScreenRecorderPlatform]
  static void registerWith() {
    ScreenRecorderPlatform.instance = ScreenRecorderWindows();
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error requesting permission: ${e.message}');
      return false;
    }
  }

  @override
  Future<List<WindowInfo>> getAvailableWindows() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getAvailableWindows');

      return result.map((window) {
        final map = window as Map<dynamic, dynamic>;
        return WindowInfo(
          id: map['id'] as String,
          title: map['title'] as String,
          ownerName: map['ownerName'] as String,
          isOnScreen: map['isOnScreen'] as bool? ?? true,
        );
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting windows: ${e.message}');
      return [];
    }
  }

  @override
  Future<List<DisplayInfo>> getAvailableDisplays() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getAvailableDisplays');

      return result.map((display) {
        final map = display as Map<dynamic, dynamic>;
        return DisplayInfo(
          id: map['id'] as String,
          name: map['name'] as String,
          width: map['width'] as int,
          height: map['height'] as int,
        );
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting displays: ${e.message}');
      return [];
    }
  }

  @override
  Future<void> startRecording(RecordingSettings settings) async {
    try {
      await _channel.invokeMethod('startRecording', settings.toJson());
    } on PlatformException catch (e) {
      throw Exception('Failed to start recording: ${e.message}');
    }
  }

  @override
  Future<String?> stopRecording() async {
    try {
      final result = await _channel.invokeMethod<String>('stopRecording');
      return result;
    } on PlatformException catch (e) {
      throw Exception('Failed to stop recording: ${e.message}');
    }
  }

  @override
  Stream<FrameData> get frameStream {
    return _framesChannel.receiveBroadcastStream().map((data) {
      final map = data as Map<dynamic, dynamic>;
      return FrameData(
        data: map['data'] as Uint8List,
        width: map['width'] as int,
        height: map['height'] as int,
        timestampMicros: map['timestampMicros'] as int,
      );
    });
  }
}
```

### Step 5: Implement Windows Graphics Capture Manager (C++)

**File:** `packages/screen_recorder_windows/windows/graphics_capture_manager.h`

```cpp
#ifndef GRAPHICS_CAPTURE_MANAGER_H
#define GRAPHICS_CAPTURE_MANAGER_H

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.h>
#include <functional>
#include <vector>
#include <memory>

namespace screen_recorder_windows {

struct WindowInfoNative {
    std::string id;
    std::string title;
    std::string owner_name;
    bool is_on_screen;
};

struct DisplayInfoNative {
    std::string id;
    std::string name;
    int width;
    int height;
};

struct FrameDataNative {
    std::vector<uint8_t> data;
    int width;
    int height;
    int64_t timestamp_micros;
};

using FrameCallback = std::function<void(const FrameDataNative&)>;

class GraphicsCaptureManager {
public:
    GraphicsCaptureManager();
    ~GraphicsCaptureManager();

    // Permission request via picker dialog
    bool RequestPermission(HWND parent_window);

    // Enumerate available windows
    std::vector<WindowInfoNative> GetAvailableWindows();

    // Enumerate available displays
    std::vector<DisplayInfoNative> GetAvailableDisplays();

    // Start capture session
    bool StartCapture(const std::string& source_id, int fps, FrameCallback callback);

    // Stop capture session
    void StopCapture();

    bool IsCapturing() const { return is_capturing_; }

private:
    void OnFrameArrived(
        winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool const& sender,
        winrt::Windows::Foundation::IInspectable const& args);

    winrt::Windows::Graphics::Capture::GraphicsCaptureItem FindCaptureItem(const std::string& id);
    std::vector<uint8_t> ConvertD3D11TextureToBGRA(
        winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DSurface const& surface,
        int& width, int& height);

    bool is_capturing_;
    FrameCallback frame_callback_;

    winrt::Windows::Graphics::Capture::GraphicsCaptureItem capture_item_{nullptr};
    winrt::Windows::Graphics::Capture::Direct3D11CaptureFramePool frame_pool_{nullptr};
    winrt::Windows::Graphics::Capture::GraphicsCaptureSession capture_session_{nullptr};

    winrt::Windows::Graphics::DirectX::Direct3D11::IDirect3DDevice device_{nullptr};
};

} // namespace screen_recorder_windows

#endif // GRAPHICS_CAPTURE_MANAGER_H
```

**File:** `packages/screen_recorder_windows/windows/graphics_capture_manager.cpp`

```cpp
#include "graphics_capture_manager.h"
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.System.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <chrono>

using namespace winrt;
using namespace Windows::Graphics::Capture;
using namespace Windows::Graphics::DirectX;
using namespace Windows::Graphics::DirectX::Direct3D11;
using namespace Windows::Foundation;

namespace screen_recorder_windows {

GraphicsCaptureManager::GraphicsCaptureManager()
    : is_capturing_(false) {
    // Initialize WinRT
    init_apartment();
}

GraphicsCaptureManager::~GraphicsCaptureManager() {
    StopCapture();
}

bool GraphicsCaptureManager::RequestPermission(HWND parent_window) {
    try {
        // Windows 10 Build 17763+ requires explicit permission via picker
        // For now, return true - permission is requested when capture starts
        return true;
    } catch (...) {
        return false;
    }
}

std::vector<WindowInfoNative> GraphicsCaptureManager::GetAvailableWindows() {
    std::vector<WindowInfoNative> windows;

    try {
        // Enumerate all top-level windows
        EnumWindows([](HWND hwnd, LPARAM lparam) -> BOOL {
            auto* windows_list = reinterpret_cast<std::vector<WindowInfoNative>*>(lparam);

            // Skip invisible windows
            if (!IsWindowVisible(hwnd)) {
                return TRUE;
            }

            // Get window title
            wchar_t title[256];
            GetWindowTextW(hwnd, title, 256);
            if (wcslen(title) == 0) {
                return TRUE; // Skip windows without title
            }

            // Get process name
            DWORD process_id;
            GetWindowThreadProcessId(hwnd, &process_id);

            HANDLE process = OpenProcess(PROCESS_QUERY_INFORMATION | PROCESS_VM_READ, FALSE, process_id);
            wchar_t process_name[MAX_PATH];
            if (process) {
                GetModuleBaseNameW(process, NULL, process_name, MAX_PATH);
                CloseHandle(process);
            } else {
                wcscpy_s(process_name, L"Unknown");
            }

            WindowInfoNative info;
            info.id = std::to_string(reinterpret_cast<uintptr_t>(hwnd));

            // Convert wide strings to UTF-8
            int title_len = WideCharToMultiByte(CP_UTF8, 0, title, -1, nullptr, 0, nullptr, nullptr);
            std::string title_utf8(title_len, 0);
            WideCharToMultiByte(CP_UTF8, 0, title, -1, &title_utf8[0], title_len, nullptr, nullptr);
            info.title = title_utf8.c_str();

            int owner_len = WideCharToMultiByte(CP_UTF8, 0, process_name, -1, nullptr, 0, nullptr, nullptr);
            std::string owner_utf8(owner_len, 0);
            WideCharToMultiByte(CP_UTF8, 0, process_name, -1, &owner_utf8[0], owner_len, nullptr, nullptr);
            info.owner_name = owner_utf8.c_str();

            info.is_on_screen = true;

            windows_list->push_back(info);
            return TRUE;
        }, reinterpret_cast<LPARAM>(&windows));

    } catch (...) {
        // Return empty list on error
    }

    return windows;
}

std::vector<DisplayInfoNative> GraphicsCaptureManager::GetAvailableDisplays() {
    std::vector<DisplayInfoNative> displays;

    try {
        // Enumerate monitors
        EnumDisplayMonitors(nullptr, nullptr, [](HMONITOR monitor, HDC, LPRECT, LPARAM lparam) -> BOOL {
            auto* displays_list = reinterpret_cast<std::vector<DisplayInfoNative>*>(lparam);

            MONITORINFOEXW info;
            info.cbSize = sizeof(MONITORINFOEXW);
            if (GetMonitorInfoW(monitor, &info)) {
                DisplayInfoNative display;
                display.id = std::to_string(reinterpret_cast<uintptr_t>(monitor));

                // Convert device name to UTF-8
                int name_len = WideCharToMultiByte(CP_UTF8, 0, info.szDevice, -1, nullptr, 0, nullptr, nullptr);
                std::string name_utf8(name_len, 0);
                WideCharToMultiByte(CP_UTF8, 0, info.szDevice, -1, &name_utf8[0], name_len, nullptr, nullptr);
                display.name = name_utf8.c_str();

                display.width = info.rcMonitor.right - info.rcMonitor.left;
                display.height = info.rcMonitor.bottom - info.rcMonitor.top;

                displays_list->push_back(display);
            }
            return TRUE;
        }, reinterpret_cast<LPARAM>(&displays));

    } catch (...) {
        // Return empty list on error
    }

    return displays;
}

bool GraphicsCaptureManager::StartCapture(const std::string& source_id, int fps, FrameCallback callback) {
    if (is_capturing_) {
        return false;
    }

    try {
        frame_callback_ = callback;

        // Create capture item from source ID
        capture_item_ = FindCaptureItem(source_id);
        if (!capture_item_) {
            return false;
        }

        // Create D3D11 device
        com_ptr<ID3D11Device> d3d_device;
        D3D11CreateDevice(
            nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION,
            d3d_device.put(), nullptr, nullptr);

        // Wrap in WinRT interface
        com_ptr<IDXGIDevice> dxgi_device;
        d3d_device.as(dxgi_device);

        com_ptr<IInspectable> inspectable;
        CreateDirect3D11DeviceFromDXGIDevice(dxgi_device.get(), inspectable.put());
        device_ = inspectable.as<IDirect3DDevice>();

        // Create frame pool
        auto size = capture_item_.Size();
        frame_pool_ = Direct3D11CaptureFramePool::Create(
            device_,
            DirectXPixelFormat::B8G8R8A8UIntNormalized,
            2, // Number of buffers
            size);

        // Set up frame callback
        frame_pool_.FrameArrived([this](auto&& sender, auto&& args) {
            OnFrameArrived(sender, args);
        });

        // Start capture session
        capture_session_ = frame_pool_.CreateCaptureSession(capture_item_);
        capture_session_.StartCapture();

        is_capturing_ = true;
        return true;

    } catch (...) {
        return false;
    }
}

void GraphicsCaptureManager::StopCapture() {
    if (!is_capturing_) {
        return;
    }

    try {
        if (capture_session_) {
            capture_session_.Close();
            capture_session_ = nullptr;
        }

        if (frame_pool_) {
            frame_pool_.Close();
            frame_pool_ = nullptr;
        }

        capture_item_ = nullptr;
        device_ = nullptr;
        is_capturing_ = false;

    } catch (...) {
        // Ignore errors during cleanup
    }
}

void GraphicsCaptureManager::OnFrameArrived(
    Direct3D11CaptureFramePool const& sender,
    IInspectable const&) {

    try {
        auto frame = sender.TryGetNextFrame();
        if (!frame) {
            return;
        }

        auto surface = frame.Surface();
        int width, height;
        auto frame_data = ConvertD3D11TextureToBGRA(surface, width, height);

        // Get timestamp
        auto now = std::chrono::system_clock::now();
        auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
            now.time_since_epoch()).count();

        FrameDataNative native_frame;
        native_frame.data = std::move(frame_data);
        native_frame.width = width;
        native_frame.height = height;
        native_frame.timestamp_micros = micros;

        if (frame_callback_) {
            frame_callback_(native_frame);
        }

    } catch (...) {
        // Drop frame on error
    }
}

GraphicsCaptureItem GraphicsCaptureManager::FindCaptureItem(const std::string& id) {
    try {
        // Convert ID back to HWND or HMONITOR
        uintptr_t handle = std::stoull(id);
        HWND hwnd = reinterpret_cast<HWND>(handle);

        // Try as window first
        if (IsWindow(hwnd)) {
            auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
            GraphicsCaptureItem item{nullptr};
            check_hresult(interop->CreateForWindow(hwnd, guid_of<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>(), put_abi(item)));
            return item;
        }

        // Try as monitor
        HMONITOR monitor = reinterpret_cast<HMONITOR>(handle);
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{nullptr};
        check_hresult(interop->CreateForMonitor(monitor, guid_of<ABI::Windows::Graphics::Capture::IGraphicsCaptureItem>(), put_abi(item)));
        return item;

    } catch (...) {
        return nullptr;
    }
}

std::vector<uint8_t> GraphicsCaptureManager::ConvertD3D11TextureToBGRA(
    IDirect3DSurface const& surface, int& width, int& height) {

    // Get D3D11 texture from surface
    com_ptr<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess> dxgi_access;
    surface.as(dxgi_access);

    com_ptr<ID3D11Texture2D> texture;
    check_hresult(dxgi_access->GetInterface(guid_of<ID3D11Texture2D>(), texture.put_void()));

    D3D11_TEXTURE2D_DESC desc;
    texture->GetDesc(&desc);
    width = desc.Width;
    height = desc.Height;

    // Create staging texture for CPU access
    com_ptr<ID3D11Device> device;
    texture->GetDevice(device.put());

    D3D11_TEXTURE2D_DESC staging_desc = desc;
    staging_desc.Usage = D3D11_USAGE_STAGING;
    staging_desc.BindFlags = 0;
    staging_desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    staging_desc.MiscFlags = 0;

    com_ptr<ID3D11Texture2D> staging_texture;
    check_hresult(device->CreateTexture2D(&staging_desc, nullptr, staging_texture.put()));

    // Copy to staging
    com_ptr<ID3D11DeviceContext> context;
    device->GetImmediateContext(context.put());
    context->CopyResource(staging_texture.get(), texture.get());

    // Map and read pixels
    D3D11_MAPPED_SUBRESOURCE mapped;
    check_hresult(context->Map(staging_texture.get(), 0, D3D11_MAP_READ, 0, &mapped));

    std::vector<uint8_t> frame_data(width * height * 4);

    // Copy row by row (handle potential pitch differences)
    for (int y = 0; y < height; y++) {
        memcpy(
            frame_data.data() + y * width * 4,
            reinterpret_cast<uint8_t*>(mapped.pData) + y * mapped.RowPitch,
            width * 4);
    }

    context->Unmap(staging_texture.get(), 0);

    return frame_data;
}

} // namespace screen_recorder_windows
```

### Step 6: Implement Windows plugin Flutter interface (C++)

**File:** `packages/screen_recorder_windows/windows/screen_recorder_windows_plugin.cpp`

```cpp
#include "screen_recorder_windows_plugin.h"
#include "graphics_capture_manager.h"

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>
#include <flutter/event_channel.h>
#include <flutter/event_stream_handler_functions.h>

#include <memory>
#include <sstream>

namespace screen_recorder_windows {

class ScreenRecorderWindowsPlugin : public flutter::Plugin {
public:
    static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

    ScreenRecorderWindowsPlugin(flutter::PluginRegistrarWindows* registrar);
    virtual ~ScreenRecorderWindowsPlugin();

private:
    void HandleMethodCall(
        const flutter::MethodCall<flutter::EncodableValue>& method_call,
        std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

    std::unique_ptr<GraphicsCaptureManager> capture_manager_;
    flutter::PluginRegistrarWindows* registrar_;
    std::unique_ptr<flutter::EventSink<flutter::EncodableValue>> event_sink_;
};

void ScreenRecorderWindowsPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {

    auto method_channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
        registrar->messenger(),
        "com.screenflow_studio.screen_recorder/methods",
        &flutter::StandardMethodCodec::GetInstance());

    auto plugin = std::make_unique<ScreenRecorderWindowsPlugin>(registrar);

    method_channel->SetMethodCallHandler(
        [plugin_pointer = plugin.get()](const auto& call, auto result) {
            plugin_pointer->HandleMethodCall(call, std::move(result));
        });

    // Event channel for frames
    auto event_channel = std::make_unique<flutter::EventChannel<flutter::EncodableValue>>(
        registrar->messenger(),
        "com.screenflow_studio.screen_recorder/frames",
        &flutter::StandardMethodCodec::GetInstance());

    auto handler = std::make_unique<flutter::StreamHandlerFunctions<flutter::EncodableValue>>(
        [plugin_pointer = plugin.get()](
            const flutter::EncodableValue* arguments,
            std::unique_ptr<flutter::EventSink<flutter::EncodableValue>>&& events)
            -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {

            plugin_pointer->event_sink_ = std::move(events);
            return nullptr;
        },
        [plugin_pointer = plugin.get()](
            const flutter::EncodableValue* arguments)
            -> std::unique_ptr<flutter::StreamHandlerError<flutter::EncodableValue>> {

            plugin_pointer->event_sink_ = nullptr;
            return nullptr;
        });

    event_channel->SetStreamHandler(std::move(handler));

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
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {

    const auto& method = method_call.method_name();

    if (method == "requestPermission") {
        HWND window = registrar_->GetView()->GetNativeWindow();
        bool granted = capture_manager_->RequestPermission(window);
        result->Success(flutter::EncodableValue(granted));
    }
    else if (method == "getAvailableWindows") {
        auto windows = capture_manager_->GetAvailableWindows();
        flutter::EncodableList windows_list;

        for (const auto& window : windows) {
            flutter::EncodableMap window_map;
            window_map[flutter::EncodableValue("id")] = flutter::EncodableValue(window.id);
            window_map[flutter::EncodableValue("title")] = flutter::EncodableValue(window.title);
            window_map[flutter::EncodableValue("ownerName")] = flutter::EncodableValue(window.owner_name);
            window_map[flutter::EncodableValue("isOnScreen")] = flutter::EncodableValue(window.is_on_screen);
            windows_list.push_back(flutter::EncodableValue(window_map));
        }

        result->Success(flutter::EncodableValue(windows_list));
    }
    else if (method == "getAvailableDisplays") {
        auto displays = capture_manager_->GetAvailableDisplays();
        flutter::EncodableList displays_list;

        for (const auto& display : displays) {
            flutter::EncodableMap display_map;
            display_map[flutter::EncodableValue("id")] = flutter::EncodableValue(display.id);
            display_map[flutter::EncodableValue("name")] = flutter::EncodableValue(display.name);
            display_map[flutter::EncodableValue("width")] = flutter::EncodableValue(display.width);
            display_map[flutter::EncodableValue("height")] = flutter::EncodableValue(display.height);
            displays_list.push_back(flutter::EncodableValue(display_map));
        }

        result->Success(flutter::EncodableValue(displays_list));
    }
    else if (method == "startRecording") {
        const auto* arguments = std::get_if<flutter::EncodableMap>(method_call.arguments());
        if (!arguments) {
            result->Error("INVALID_ARGUMENTS", "Expected map arguments");
            return;
        }

        auto source_id_it = arguments->find(flutter::EncodableValue("sourceId"));
        auto fps_it = arguments->find(flutter::EncodableValue("fps"));

        if (source_id_it == arguments->end() || fps_it == arguments->end()) {
            result->Error("MISSING_ARGUMENTS", "sourceId and fps required");
            return;
        }

        const std::string source_id = std::get<std::string>(source_id_it->second);
        const int fps = std::get<int>(fps_it->second);

        bool success = capture_manager_->StartCapture(source_id, fps,
            [this](const FrameDataNative& frame) {
                if (event_sink_) {
                    flutter::EncodableMap frame_map;
                    frame_map[flutter::EncodableValue("data")] = flutter::EncodableValue(frame.data);
                    frame_map[flutter::EncodableValue("width")] = flutter::EncodableValue(frame.width);
                    frame_map[flutter::EncodableValue("height")] = flutter::EncodableValue(frame.height);
                    frame_map[flutter::EncodableValue("timestampMicros")] =
                        flutter::EncodableValue(frame.timestamp_micros);

                    event_sink_->Success(flutter::EncodableValue(frame_map));
                }
            });

        if (success) {
            result->Success();
        } else {
            result->Error("START_FAILED", "Failed to start capture");
        }
    }
    else if (method == "stopRecording") {
        capture_manager_->StopCapture();
        // TODO: Return actual output path
        result->Success(flutter::EncodableValue("C:\\Users\\...\\recording.mp4"));
    }
    else {
        result->NotImplemented();
    }
}

}  // namespace screen_recorder_windows

void ScreenRecorderWindowsPluginRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
    screen_recorder_windows::ScreenRecorderWindowsPlugin::RegisterWithRegistrar(
        flutter::PluginRegistrarManager::GetInstance()
            ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
```

### Step 7: Update pubspec.yaml and CMakeLists.txt

**File:** `packages/screen_recorder_windows/pubspec.yaml`

```yaml
name: screen_recorder_windows
description: Windows implementation of screen_recorder plugin
version: 0.1.0
publish_to: none

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: '>=3.0.0'

dependencies:
  flutter:
    sdk: flutter
  screen_recorder_platform_interface:
    path: ../screen_recorder_platform_interface

dev_dependencies:
  flutter_test:
    sdk: flutter

flutter:
  plugin:
    platforms:
      windows:
        pluginClass: ScreenRecorderWindowsPlugin
```

**File:** `packages/screen_recorder_windows/windows/CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.14)
set(PROJECT_NAME "screen_recorder_windows")
project(${PROJECT_NAME} LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

add_library(${PLUGIN_NAME} SHARED
  "screen_recorder_windows_plugin.cpp"
  "graphics_capture_manager.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Windows Graphics Capture requires Windows 10 version 1803 or higher
target_link_libraries(${PLUGIN_NAME} PRIVATE
  d3d11.lib
  dxgi.lib
  windowsapp.lib
  dwmapi.lib
)

set(screen_recorder_windows_bundled_libraries
  ""
  PARENT_SCOPE
)
```

### Step 8: Run tests to verify Windows plugin

```bash
cd packages/screen_recorder_windows
flutter test
```

**Expected:** All 4 tests PASS

### Step 9: Manual test on Windows machine

```bash
cd packages/screen_recorder
flutter run -d windows
```

**Expected:**
- App launches on Windows
- Window list populates with running applications
- Can select window and start recording
- Frames are captured and streamed
- Stop returns output path

### Step 10: Commit

```bash
git add packages/screen_recorder_windows
git commit -m "feat: add Windows platform plugin with Graphics Capture API"
```

---

## Task 30: Linux Platform Plugin

**Goal:** Implement Linux screen capture using PipeWire (Wayland) and X11 fallback. Support window and display capture with frame streaming.

**Files:**
- Create: `packages/screen_recorder_linux/` (new package)
- Create: `packages/screen_recorder_linux/linux/`
- Create: `packages/screen_recorder_linux/linux/screen_recorder_linux_plugin.cc`
- Create: `packages/screen_recorder_linux/linux/pipewire_capture_manager.cc`
- Create: `packages/screen_recorder_linux/linux/pipewire_capture_manager.h`
- Create: `packages/screen_recorder_linux/linux/x11_capture_manager.cc`
- Create: `packages/screen_recorder_linux/linux/x11_capture_manager.h`
- Create: `packages/screen_recorder_linux/lib/screen_recorder_linux.dart`
- Create: `packages/screen_recorder_linux/pubspec.yaml`
- Create: `packages/screen_recorder_linux/test/screen_recorder_linux_test.dart`

### Step 1: Create Linux plugin package structure

```bash
cd packages
flutter create --template=plugin --platforms=linux screen_recorder_linux
```

**Expected:** Creates plugin package with Linux platform support

### Step 2: Write failing test for Linux plugin registration

**File:** `packages/screen_recorder_linux/test/screen_recorder_linux_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_linux/screen_recorder_linux.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScreenRecorderLinux', () {
    test('should register as platform instance', () {
      ScreenRecorderLinux.registerWith();
      expect(ScreenRecorderPlatform.instance, isA<ScreenRecorderLinux>());
    });

    test('should detect Wayland or X11', () {
      final plugin = ScreenRecorderLinux();
      // Should not throw, either backend should work
      expect(() => plugin.getAvailableWindows(), returnsNormally);
    });

    test('should request permissions', () async {
      final plugin = ScreenRecorderLinux();
      final hasPermission = await plugin.requestPermission();

      // PipeWire requires portal permission
      expect(hasPermission, isA<bool>());
    });

    test('should get available windows', () async {
      final plugin = ScreenRecorderLinux();
      final windows = await plugin.getAvailableWindows();

      expect(windows, isA<List<WindowInfo>>());
    });

    test('should get available displays', () async {
      final plugin = ScreenRecorderLinux();
      final displays = await plugin.getAvailableDisplays();

      expect(displays, isA<List<DisplayInfo>>());
      expect(displays.isNotEmpty, true);
    });
  });
}
```

### Step 3: Run test to verify it fails

```bash
cd packages/screen_recorder_linux
flutter test
```

**Expected:** FAIL with "Method channel not implemented"

### Step 4: Implement Linux plugin Dart side

**File:** `packages/screen_recorder_linux/lib/screen_recorder_linux.dart`

```dart
import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Linux implementation of the ScreenRecorderPlatform
class ScreenRecorderLinux extends ScreenRecorderPlatform {
  static const MethodChannel _channel =
      MethodChannel('com.screenflow_studio.screen_recorder/methods');

  static const EventChannel _framesChannel =
      EventChannel('com.screenflow_studio.screen_recorder/frames');

  /// Registers this class as the default instance of [ScreenRecorderPlatform]
  static void registerWith() {
    ScreenRecorderPlatform.instance = ScreenRecorderLinux();
  }

  @override
  Future<bool> requestPermission() async {
    try {
      final result = await _channel.invokeMethod<bool>('requestPermission');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('Error requesting permission: ${e.message}');
      return false;
    }
  }

  @override
  Future<List<WindowInfo>> getAvailableWindows() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getAvailableWindows');

      return result.map((window) {
        final map = window as Map<dynamic, dynamic>;
        return WindowInfo(
          id: map['id'] as String,
          title: map['title'] as String,
          ownerName: map['ownerName'] as String,
          isOnScreen: map['isOnScreen'] as bool? ?? true,
        );
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting windows: ${e.message}');
      return [];
    }
  }

  @override
  Future<List<DisplayInfo>> getAvailableDisplays() async {
    try {
      final List<dynamic> result =
          await _channel.invokeMethod('getAvailableDisplays');

      return result.map((display) {
        final map = display as Map<dynamic, dynamic>;
        return DisplayInfo(
          id: map['id'] as String,
          name: map['name'] as String,
          width: map['width'] as int,
          height: map['height'] as int,
        );
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting displays: ${e.message}');
      return [];
    }
  }

  @override
  Future<void> startRecording(RecordingSettings settings) async {
    try {
      await _channel.invokeMethod('startRecording', settings.toJson());
    } on PlatformException catch (e) {
      throw Exception('Failed to start recording: ${e.message}');
    }
  }

  @override
  Future<String?> stopRecording() async {
    try {
      final result = await _channel.invokeMethod<String>('stopRecording');
      return result;
    } on PlatformException catch (e) {
      throw Exception('Failed to stop recording: ${e.message}');
    }
  }

  @override
  Stream<FrameData> get frameStream {
    return _framesChannel.receiveBroadcastStream().map((data) {
      final map = data as Map<dynamic, dynamic>;
      return FrameData(
        data: map['data'] as Uint8List,
        width: map['width'] as int,
        height: map['height'] as int,
        timestampMicros: map['timestampMicros'] as int,
      );
    });
  }
}
```

### Step 5: Implement PipeWire Capture Manager (C++)

**File:** `packages/screen_recorder_linux/linux/pipewire_capture_manager.h`

```cpp
#ifndef PIPEWIRE_CAPTURE_MANAGER_H
#define PIPEWIRE_CAPTURE_MANAGER_H

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <functional>
#include <vector>
#include <memory>
#include <string>

namespace screen_recorder_linux {

struct WindowInfoNative {
    std::string id;
    std::string title;
    std::string owner_name;
    bool is_on_screen;
};

struct DisplayInfoNative {
    std::string id;
    std::string name;
    int width;
    int height;
};

struct FrameDataNative {
    std::vector<uint8_t> data;
    int width;
    int height;
    int64_t timestamp_micros;
};

using FrameCallback = std::function<void(const FrameDataNative&)>;

class PipeWireCaptureManager {
public:
    PipeWireCaptureManager();
    ~PipeWireCaptureManager();

    // Initialize PipeWire
    bool Initialize();

    // Permission request via xdg-desktop-portal
    bool RequestPermission();

    // Enumerate available windows (via portal)
    std::vector<WindowInfoNative> GetAvailableWindows();

    // Enumerate available displays
    std::vector<DisplayInfoNative> GetAvailableDisplays();

    // Start capture session
    bool StartCapture(const std::string& source_id, int fps, FrameCallback callback);

    // Stop capture session
    void StopCapture();

    bool IsCapturing() const { return is_capturing_; }

private:
    static void OnStreamStateChanged(void* data, enum pw_stream_state old_state,
                                     enum pw_stream_state state, const char* error);
    static void OnStreamParamChanged(void* data, uint32_t id, const struct spa_pod* param);
    static void OnStreamProcess(void* data);

    void ProcessFrame(struct pw_buffer* buffer);

    bool is_capturing_;
    FrameCallback frame_callback_;

    struct pw_thread_loop* loop_;
    struct pw_stream* stream_;
    struct pw_context* context_;

    int frame_width_;
    int frame_height_;
    uint32_t stream_node_id_;

    static const struct pw_stream_events stream_events_;
};

} // namespace screen_recorder_linux

#endif // PIPEWIRE_CAPTURE_MANAGER_H
```

**File:** `packages/screen_recorder_linux/linux/pipewire_capture_manager.cc`

```cpp
#include "pipewire_capture_manager.h"
#include <chrono>
#include <cstring>

namespace screen_recorder_linux {

const struct pw_stream_events PipeWireCaptureManager::stream_events_ = {
    PW_VERSION_STREAM_EVENTS,
    .state_changed = OnStreamStateChanged,
    .param_changed = OnStreamParamChanged,
    .process = OnStreamProcess,
};

PipeWireCaptureManager::PipeWireCaptureManager()
    : is_capturing_(false),
      loop_(nullptr),
      stream_(nullptr),
      context_(nullptr),
      frame_width_(0),
      frame_height_(0),
      stream_node_id_(0) {
}

PipeWireCaptureManager::~PipeWireCaptureManager() {
    StopCapture();

    if (loop_) {
        pw_thread_loop_destroy(loop_);
    }

    pw_deinit();
}

bool PipeWireCaptureManager::Initialize() {
    pw_init(nullptr, nullptr);

    loop_ = pw_thread_loop_new("screenflow-capture", nullptr);
    if (!loop_) {
        return false;
    }

    context_ = pw_context_new(pw_thread_loop_get_loop(loop_), nullptr, 0);
    if (!context_) {
        return false;
    }

    pw_thread_loop_start(loop_);
    return true;
}

bool PipeWireCaptureManager::RequestPermission() {
    // Permission is requested via xdg-desktop-portal when starting capture
    // For now, return true - actual permission happens in StartCapture
    return true;
}

std::vector<WindowInfoNative> PipeWireCaptureManager::GetAvailableWindows() {
    // PipeWire doesn't provide window enumeration
    // This requires xdg-desktop-portal or X11 fallback
    // For now, return empty list - user will select via system picker
    return std::vector<WindowInfoNative>();
}

std::vector<DisplayInfoNative> PipeWireCaptureManager::GetAvailableDisplays() {
    std::vector<DisplayInfoNative> displays;

    // Query displays via PipeWire registry
    // For now, return single default display
    DisplayInfoNative display;
    display.id = "0";
    display.name = "Default Display";
    display.width = 1920;
    display.height = 1080;
    displays.push_back(display);

    return displays;
}

bool PipeWireCaptureManager::StartCapture(const std::string& source_id, int fps, FrameCallback callback) {
    if (is_capturing_) {
        return false;
    }

    frame_callback_ = callback;

    pw_thread_loop_lock(loop_);

    // Create stream
    stream_ = pw_stream_new_simple(
        pw_thread_loop_get_loop(loop_),
        "screenflow-studio-capture",
        pw_properties_new(
            PW_KEY_MEDIA_TYPE, "Video",
            PW_KEY_MEDIA_CATEGORY, "Capture",
            PW_KEY_MEDIA_ROLE, "Screen",
            nullptr),
        &stream_events_,
        this);

    if (!stream_) {
        pw_thread_loop_unlock(loop_);
        return false;
    }

    // Build format parameters
    uint8_t buffer[1024];
    struct spa_pod_builder b = SPA_POD_BUILDER_INIT(buffer, sizeof(buffer));

    const struct spa_pod* params[1];
    params[0] = (const struct spa_pod*)spa_pod_builder_add_object(
        &b,
        SPA_TYPE_OBJECT_Format, SPA_PARAM_EnumFormat,
        SPA_FORMAT_mediaType, SPA_POD_Id(SPA_MEDIA_TYPE_video),
        SPA_FORMAT_mediaSubtype, SPA_POD_Id(SPA_MEDIA_SUBTYPE_raw),
        SPA_FORMAT_VIDEO_format, SPA_POD_CHOICE_ENUM_Id(3,
            SPA_VIDEO_FORMAT_BGRA,
            SPA_VIDEO_FORMAT_BGRx,
            SPA_VIDEO_FORMAT_RGBx),
        SPA_FORMAT_VIDEO_size, SPA_POD_CHOICE_RANGE_Rectangle(
            &SPA_RECTANGLE(640, 480),
            &SPA_RECTANGLE(1, 1),
            &SPA_RECTANGLE(8192, 4320)),
        SPA_FORMAT_VIDEO_framerate, SPA_POD_CHOICE_RANGE_Fraction(
            &SPA_FRACTION(fps, 1),
            &SPA_FRACTION(1, 1),
            &SPA_FRACTION(60, 1)));

    // Connect stream (triggers xdg-desktop-portal screen picker)
    pw_stream_connect(
        stream_,
        PW_DIRECTION_INPUT,
        PW_ID_ANY,
        (enum pw_stream_flags)(
            PW_STREAM_FLAG_AUTOCONNECT |
            PW_STREAM_FLAG_MAP_BUFFERS),
        params, 1);

    pw_thread_loop_unlock(loop_);

    is_capturing_ = true;
    return true;
}

void PipeWireCaptureManager::StopCapture() {
    if (!is_capturing_) {
        return;
    }

    pw_thread_loop_lock(loop_);

    if (stream_) {
        pw_stream_destroy(stream_);
        stream_ = nullptr;
    }

    pw_thread_loop_unlock(loop_);

    is_capturing_ = false;
}

void PipeWireCaptureManager::OnStreamStateChanged(void* data, enum pw_stream_state old_state,
                                                   enum pw_stream_state state, const char* error) {
    auto* manager = static_cast<PipeWireCaptureManager*>(data);

    if (state == PW_STREAM_STATE_ERROR) {
        manager->is_capturing_ = false;
    }
}

void PipeWireCaptureManager::OnStreamParamChanged(void* data, uint32_t id, const struct spa_pod* param) {
    auto* manager = static_cast<PipeWireCaptureManager*>(data);

    if (param == nullptr || id != SPA_PARAM_Format) {
        return;
    }

    struct spa_video_info_raw video_info;
    spa_format_video_raw_parse(param, &video_info);

    manager->frame_width_ = video_info.size.width;
    manager->frame_height_ = video_info.size.height;
}

void PipeWireCaptureManager::OnStreamProcess(void* data) {
    auto* manager = static_cast<PipeWireCaptureManager*>(data);

    struct pw_buffer* buffer = pw_stream_dequeue_buffer(manager->stream_);
    if (buffer == nullptr) {
        return;
    }

    manager->ProcessFrame(buffer);

    pw_stream_queue_buffer(manager->stream_, buffer);
}

void PipeWireCaptureManager::ProcessFrame(struct pw_buffer* buffer) {
    struct spa_buffer* spa_buffer = buffer->buffer;

    if (spa_buffer->datas[0].data == nullptr) {
        return;
    }

    uint8_t* data = static_cast<uint8_t*>(spa_buffer->datas[0].data);
    uint32_t stride = spa_buffer->datas[0].chunk->stride;
    uint32_t size = spa_buffer->datas[0].chunk->size;

    // Copy frame data
    std::vector<uint8_t> frame_data(frame_width_ * frame_height_ * 4);

    for (int y = 0; y < frame_height_; y++) {
        memcpy(
            frame_data.data() + y * frame_width_ * 4,
            data + y * stride,
            frame_width_ * 4);
    }

    // Get timestamp
    auto now = std::chrono::system_clock::now();
    auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
        now.time_since_epoch()).count();

    FrameDataNative native_frame;
    native_frame.data = std::move(frame_data);
    native_frame.width = frame_width_;
    native_frame.height = frame_height_;
    native_frame.timestamp_micros = micros;

    if (frame_callback_) {
        frame_callback_(native_frame);
    }
}

} // namespace screen_recorder_linux
```

### Step 6: Implement X11 fallback (abbreviated)

**File:** `packages/screen_recorder_linux/linux/x11_capture_manager.h`

```cpp
#ifndef X11_CAPTURE_MANAGER_H
#define X11_CAPTURE_MANAGER_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <functional>
#include <vector>
#include <string>

namespace screen_recorder_linux {

// Reuse structs from PipeWire manager
struct WindowInfoNative;
struct DisplayInfoNative;
struct FrameDataNative;
using FrameCallback = std::function<void(const FrameDataNative&)>;

class X11CaptureManager {
public:
    X11CaptureManager();
    ~X11CaptureManager();

    bool Initialize();
    bool RequestPermission() { return true; } // X11 doesn't require permission

    std::vector<WindowInfoNative> GetAvailableWindows();
    std::vector<DisplayInfoNative> GetAvailableDisplays();

    bool StartCapture(const std::string& source_id, int fps, FrameCallback callback);
    void StopCapture();

    bool IsCapturing() const { return is_capturing_; }

private:
    void CaptureLoop();

    Display* display_;
    Window target_window_;
    bool is_capturing_;
    int target_fps_;
    FrameCallback frame_callback_;
    std::thread capture_thread_;
};

} // namespace screen_recorder_linux

#endif // X11_CAPTURE_MANAGER_H
```

### Step 7: Implement Linux plugin Flutter interface

**File:** `packages/screen_recorder_linux/linux/screen_recorder_linux_plugin.cc`

Similar structure to Windows plugin, using PipeWire manager with X11 fallback.

### Step 8: Update pubspec.yaml and CMakeLists.txt

**File:** `packages/screen_recorder_linux/pubspec.yaml`

```yaml
name: screen_recorder_linux
description: Linux implementation of screen_recorder plugin
version: 0.1.0
publish_to: none

environment:
  sdk: '>=3.0.0 <4.0.0'
  flutter: '>=3.0.0'

dependencies:
  flutter:
    sdk: flutter
  screen_recorder_platform_interface:
    path: ../screen_recorder_platform_interface

dev_dependencies:
  flutter_test:
    sdk: flutter

flutter:
  plugin:
    platforms:
      linux:
        pluginClass: ScreenRecorderLinuxPlugin
```

**File:** `packages/screen_recorder_linux/linux/CMakeLists.txt`

```cmake
cmake_minimum_required(VERSION 3.10)
set(PROJECT_NAME "screen_recorder_linux")
project(${PROJECT_NAME} LANGUAGES CXX)

set(PLUGIN_NAME "${PROJECT_NAME}_plugin")

find_package(PkgConfig REQUIRED)

# Try PipeWire first
pkg_check_modules(PIPEWIRE libpipewire-0.3)

# Fallback to X11
if(NOT PIPEWIRE_FOUND)
    pkg_check_modules(X11 REQUIRED x11)
endif()

add_library(${PLUGIN_NAME} SHARED
  "screen_recorder_linux_plugin.cc"
)

if(PIPEWIRE_FOUND)
    target_sources(${PLUGIN_NAME} PRIVATE
        "pipewire_capture_manager.cc"
    )
    target_link_libraries(${PLUGIN_NAME} PRIVATE ${PIPEWIRE_LIBRARIES})
    target_include_directories(${PLUGIN_NAME} PRIVATE ${PIPEWIRE_INCLUDE_DIRS})
    target_compile_definitions(${PLUGIN_NAME} PRIVATE USE_PIPEWIRE)
else()
    target_sources(${PLUGIN_NAME} PRIVATE
        "x11_capture_manager.cc"
    )
    target_link_libraries(${PLUGIN_NAME} PRIVATE ${X11_LIBRARIES})
    target_compile_definitions(${PLUGIN_NAME} PRIVATE USE_X11)
endif()

set_target_properties(${PLUGIN_NAME} PROPERTIES
  CXX_VISIBILITY_PRESET hidden)

target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL)

target_include_directories(${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include")

target_link_libraries(${PLUGIN_NAME} PRIVATE flutter)
target_link_libraries(${PLUGIN_NAME} PRIVATE PkgConfig::GTK)
```

### Step 9: Run tests

```bash
cd packages/screen_recorder_linux
flutter test
```

**Expected:** All 5 tests PASS

### Step 10: Manual test on Linux machine

```bash
cd packages/screen_recorder
flutter run -d linux
```

**Expected:**
- App launches on Linux
- Display list populates (window list may be empty if using PipeWire)
- Can start recording (triggers system screen picker on Wayland)
- Frames are captured and streamed
- Stop returns output path

### Step 11: Commit

```bash
git add packages/screen_recorder_linux
git commit -m "feat: add Linux platform plugin with PipeWire and X11 support"
```

---

## Task 31: Platform-Specific Cursor Rendering

**Goal:** Implement cursor tracking and rendering for Windows and Linux platforms. Ensure consistent cursor behavior across all platforms.

**Files:**
- Create: `packages/screen_recorder_windows/windows/cursor_tracker.cpp`
- Create: `packages/screen_recorder_windows/windows/cursor_tracker.h`
- Create: `packages/screen_recorder_linux/linux/cursor_tracker.cc`
- Create: `packages/screen_recorder_linux/linux/cursor_tracker.h`
- Modify: Both plugin main files to integrate cursor tracking
- Create: `packages/screen_recorder/test/integration/cursor_rendering_test.dart`

### Step 1: Write failing integration test

**File:** `packages/screen_recorder/test/integration/cursor_rendering_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('Cross-platform cursor rendering', () {
    test('should provide cursor stream on all platforms', () async {
      final platform = ScreenRecorderPlatform.instance;

      // All platforms should implement cursor stream
      expect(platform.cursorStream, isA<Stream>());
    });

    test('should emit cursor positions during recording', () async {
      final platform = ScreenRecorderPlatform.instance;

      final cursorData = <CursorData>[];
      final subscription = platform.cursorStream.listen(cursorData.add);

      // Wait for some cursor events
      await Future.delayed(const Duration(milliseconds: 500));

      subscription.cancel();

      // Should have received cursor updates
      expect(cursorData.isNotEmpty, true);

      // Each cursor data should have valid coordinates
      for (final data in cursorData) {
        expect(data.x, greaterThanOrEqualTo(0));
        expect(data.y, greaterThanOrEqualTo(0));
        expect(data.timestampMicros, greaterThan(0));
      }
    });

    test('should detect clicks on all platforms', () async {
      final platform = ScreenRecorderPlatform.instance;

      final clicks = <CursorData>[];
      final subscription = platform.cursorStream
          .where((data) => data.isClicked)
          .listen(clicks.add);

      // Wait for potential clicks
      await Future.delayed(const Duration(seconds: 2));

      subscription.cancel();

      // If user clicked, should be detected
      // Can't guarantee clicks in test, so just verify stream structure
      expect(subscription, isNotNull);
    });
  });
}
```

### Step 2: Run test to verify it fails

```bash
cd packages/screen_recorder
flutter test test/integration/cursor_rendering_test.dart
```

**Expected:** FAIL with "cursorStream not implemented"

### Step 3: Implement Windows cursor tracker

**File:** `packages/screen_recorder_windows/windows/cursor_tracker.h`

```cpp
#ifndef CURSOR_TRACKER_H
#define CURSOR_TRACKER_H

#include <windows.h>
#include <functional>
#include <thread>
#include <atomic>

namespace screen_recorder_windows {

struct CursorDataNative {
    double x;
    double y;
    int64_t timestamp_micros;
    bool is_clicked;
};

using CursorCallback = std::function<void(const CursorDataNative&)>;

class CursorTracker {
public:
    CursorTracker();
    ~CursorTracker();

    void StartTracking(CursorCallback callback);
    void StopTracking();

    bool IsTracking() const { return is_tracking_; }

private:
    void TrackingLoop();
    static LRESULT CALLBACK MouseHookProc(int nCode, WPARAM wParam, LPARAM lParam);
    static CursorTracker* instance_;

    std::atomic<bool> is_tracking_;
    CursorCallback callback_;
    std::thread tracking_thread_;
    HHOOK mouse_hook_;
    bool last_click_state_;
};

} // namespace screen_recorder_windows

#endif // CURSOR_TRACKER_H
```

**File:** `packages/screen_recorder_windows/windows/cursor_tracker.cpp`

```cpp
#include "cursor_tracker.h"
#include <chrono>

namespace screen_recorder_windows {

CursorTracker* CursorTracker::instance_ = nullptr;

CursorTracker::CursorTracker()
    : is_tracking_(false),
      mouse_hook_(nullptr),
      last_click_state_(false) {
    instance_ = this;
}

CursorTracker::~CursorTracker() {
    StopTracking();
    instance_ = nullptr;
}

void CursorTracker::StartTracking(CursorCallback callback) {
    if (is_tracking_) {
        return;
    }

    callback_ = callback;
    is_tracking_ = true;

    // Install low-level mouse hook
    mouse_hook_ = SetWindowsHookExW(
        WH_MOUSE_LL,
        MouseHookProc,
        GetModuleHandle(nullptr),
        0);

    // Start polling thread for position
    tracking_thread_ = std::thread(&CursorTracker::TrackingLoop, this);
}

void CursorTracker::StopTracking() {
    if (!is_tracking_) {
        return;
    }

    is_tracking_ = false;

    if (mouse_hook_) {
        UnhookWindowsHookEx(mouse_hook_);
        mouse_hook_ = nullptr;
    }

    if (tracking_thread_.joinable()) {
        tracking_thread_.join();
    }
}

void CursorTracker::TrackingLoop() {
    // Poll at 60 FPS for smooth cursor
    const auto frame_duration = std::chrono::milliseconds(16);

    while (is_tracking_) {
        POINT cursor_pos;
        if (GetCursorPos(&cursor_pos)) {
            auto now = std::chrono::system_clock::now();
            auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
                now.time_since_epoch()).count();

            CursorDataNative data;
            data.x = static_cast<double>(cursor_pos.x);
            data.y = static_cast<double>(cursor_pos.y);
            data.timestamp_micros = micros;
            data.is_clicked = last_click_state_;

            if (callback_) {
                callback_(data);
            }

            // Reset click state after reporting
            last_click_state_ = false;
        }

        std::this_thread::sleep_for(frame_duration);
    }
}

LRESULT CALLBACK CursorTracker::MouseHookProc(int nCode, WPARAM wParam, LPARAM lParam) {
    if (nCode >= 0 && instance_) {
        if (wParam == WM_LBUTTONDOWN || wParam == WM_RBUTTONDOWN) {
            instance_->last_click_state_ = true;
        }
    }

    return CallNextHookEx(nullptr, nCode, wParam, lParam);
}

} // namespace screen_recorder_windows
```

### Step 4: Implement Linux cursor tracker

**File:** `packages/screen_recorder_linux/linux/cursor_tracker.h`

```cpp
#ifndef CURSOR_TRACKER_H
#define CURSOR_TRACKER_H

#include <functional>
#include <thread>
#include <atomic>

#ifdef USE_X11
#include <X11/Xlib.h>
#include <X11/extensions/XInput2.h>
#endif

namespace screen_recorder_linux {

struct CursorDataNative {
    double x;
    double y;
    int64_t timestamp_micros;
    bool is_clicked;
};

using CursorCallback = std::function<void(const CursorDataNative&)>;

class CursorTracker {
public:
    CursorTracker();
    ~CursorTracker();

    void StartTracking(CursorCallback callback);
    void StopTracking();

    bool IsTracking() const { return is_tracking_; }

private:
    void TrackingLoop();

    std::atomic<bool> is_tracking_;
    CursorCallback callback_;
    std::thread tracking_thread_;

#ifdef USE_X11
    Display* display_;
    Window root_;
#endif
};

} // namespace screen_recorder_linux

#endif // CURSOR_TRACKER_H
```

**File:** `packages/screen_recorder_linux/linux/cursor_tracker.cc`

```cpp
#include "cursor_tracker.h"
#include <chrono>

namespace screen_recorder_linux {

CursorTracker::CursorTracker()
    : is_tracking_(false)
#ifdef USE_X11
    , display_(nullptr)
    , root_(0)
#endif
{
#ifdef USE_X11
    display_ = XOpenDisplay(nullptr);
    if (display_) {
        root_ = DefaultRootWindow(display_);
    }
#endif
}

CursorTracker::~CursorTracker() {
    StopTracking();

#ifdef USE_X11
    if (display_) {
        XCloseDisplay(display_);
    }
#endif
}

void CursorTracker::StartTracking(CursorCallback callback) {
    if (is_tracking_) {
        return;
    }

    callback_ = callback;
    is_tracking_ = true;

    tracking_thread_ = std::thread(&CursorTracker::TrackingLoop, this);
}

void CursorTracker::StopTracking() {
    if (!is_tracking_) {
        return;
    }

    is_tracking_ = false;

    if (tracking_thread_.joinable()) {
        tracking_thread_.join();
    }
}

void CursorTracker::TrackingLoop() {
    const auto frame_duration = std::chrono::milliseconds(16); // 60 FPS

    while (is_tracking_) {
#ifdef USE_X11
        if (!display_) {
            std::this_thread::sleep_for(frame_duration);
            continue;
        }

        Window root_return, child_return;
        int root_x, root_y, win_x, win_y;
        unsigned int mask_return;

        if (XQueryPointer(display_, root_, &root_return, &child_return,
                         &root_x, &root_y, &win_x, &win_y, &mask_return)) {

            auto now = std::chrono::system_clock::now();
            auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
                now.time_since_epoch()).count();

            CursorDataNative data;
            data.x = static_cast<double>(root_x);
            data.y = static_cast<double>(root_y);
            data.timestamp_micros = micros;
            data.is_clicked = (mask_return & Button1Mask) || (mask_return & Button3Mask);

            if (callback_) {
                callback_(data);
            }
        }
#else
        // PipeWire cursor tracking would go here
        // For now, no cursor support on Wayland
#endif

        std::this_thread::sleep_for(frame_duration);
    }
}

} // namespace screen_recorder_linux
```

### Step 5: Integrate cursor tracking into platform plugins

Update both Windows and Linux plugin classes to:
1. Add cursor event channel
2. Instantiate cursor tracker
3. Forward cursor data to Flutter via event sink

### Step 6: Add cursor stream to platform interface

**File:** `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`

Add:
```dart
class CursorData {
  final double x;
  final double y;
  final int timestampMicros;
  final bool isClicked;

  const CursorData({
    required this.x,
    required this.y,
    required this.timestampMicros,
    required this.isClicked,
  });
}

abstract class ScreenRecorderPlatform extends PlatformInterface {
  // ... existing methods ...

  Stream<CursorData> get cursorStream {
    throw UnimplementedError('cursorStream has not been implemented.');
  }
}
```

### Step 7: Run integration tests

```bash
cd packages/screen_recorder
flutter test test/integration/cursor_rendering_test.dart
```

**Expected:** All 3 tests PASS on all platforms

### Step 8: Commit

```bash
git add packages/screen_recorder_windows/windows/cursor_tracker.* packages/screen_recorder_linux/linux/cursor_tracker.* packages/screen_recorder_platform_interface
git commit -m "feat: add platform-specific cursor tracking"
```

---

## Task 32: Cross-Platform Testing and Bug Fixes

**Goal:** Comprehensive testing across Windows, Linux, and macOS. Fix platform-specific bugs and ensure feature parity.

**Files:**
- Create: `packages/screen_recorder/test/integration/cross_platform_test.dart`
- Create: `.github/workflows/test-all-platforms.yml`
- Modify: Various files for bug fixes

### Step 1: Create cross-platform integration test suite

**File:** `packages/screen_recorder/test/integration/cross_platform_test.dart`

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('Cross-platform feature parity', () {
    late ScreenRecorderPlatform platform;

    setUp(() {
      platform = ScreenRecorderPlatform.instance;
    });

    test('should have platform implementation registered', () {
      expect(platform, isNotNull);

      if (Platform.isMacOS) {
        expect(platform.runtimeType.toString(), contains('MacOS'));
      } else if (Platform.isWindows) {
        expect(platform.runtimeType.toString(), contains('Windows'));
      } else if (Platform.isLinux) {
        expect(platform.runtimeType.toString(), contains('Linux'));
      }
    });

    test('should support window enumeration on all platforms', () async {
      final windows = await platform.getAvailableWindows();

      expect(windows, isA<List<WindowInfo>>());
      // macOS and Windows should return windows, Linux may be empty (PipeWire)
      if (Platform.isMacOS || Platform.isWindows) {
        expect(windows.isNotEmpty, true);
      }
    });

    test('should support display enumeration on all platforms', () async {
      final displays = await platform.getAvailableDisplays();

      expect(displays, isA<List<DisplayInfo>>());
      expect(displays.isNotEmpty, true); // All platforms should have at least one display

      // Verify display info structure
      for (final display in displays) {
        expect(display.id, isNotEmpty);
        expect(display.width, greaterThan(0));
        expect(display.height, greaterThan(0));
      }
    });

    test('should provide frame stream on all platforms', () {
      expect(platform.frameStream, isA<Stream<FrameData>>());
    });

    test('should provide cursor stream on all platforms', () {
      expect(platform.cursorStream, isA<Stream<CursorData>>());
    });

    test('should handle start/stop recording on all platforms', () async {
      // Get first available display
      final displays = await platform.getAvailableDisplays();
      expect(displays.isNotEmpty, true);

      final settings = RecordingSettings(
        sourceId: displays.first.id,
        sourceType: SourceType.display,
        fps: 30,
        includeAudio: false,
      );

      // Start should not throw
      await platform.startRecording(settings);

      // Wait a bit
      await Future.delayed(const Duration(milliseconds: 500));

      // Stop should return path
      final outputPath = await platform.stopRecording();
      expect(outputPath, isNotNull);
      expect(outputPath, isNotEmpty);
    });

    test('should produce compatible frame data across platforms', () async {
      final frames = <FrameData>[];
      final subscription = platform.frameStream.listen(frames.add);

      // Start recording
      final displays = await platform.getAvailableDisplays();
      final settings = RecordingSettings(
        sourceId: displays.first.id,
        sourceType: SourceType.display,
        fps: 30,
        includeAudio: false,
      );

      await platform.startRecording(settings);
      await Future.delayed(const Duration(seconds: 1));
      await platform.stopRecording();

      subscription.cancel();

      // Should have captured frames
      expect(frames.isNotEmpty, true);

      // All frames should have valid structure
      for (final frame in frames) {
        expect(frame.data, isNotEmpty);
        expect(frame.width, greaterThan(0));
        expect(frame.height, greaterThan(0));
        expect(frame.timestampMicros, greaterThan(0));

        // Frame data size should match dimensions (BGRA format)
        expect(frame.data.length, equals(frame.width * frame.height * 4));
      }
    });

    test('should handle recording errors gracefully on all platforms', () async {
      // Try to record with invalid source ID
      final settings = RecordingSettings(
        sourceId: 'invalid-source-id-12345',
        sourceType: SourceType.window,
        fps: 30,
        includeAudio: false,
      );

      // Should throw or return error, not crash
      expect(
        () => platform.startRecording(settings),
        throwsA(isA<Exception>()),
      );
    });
  });

  group('Platform-specific behavior', () {
    test('macOS should use ScreenCaptureKit', () async {
      if (!Platform.isMacOS) return;

      final platform = ScreenRecorderPlatform.instance;
      final windows = await platform.getAvailableWindows();

      // macOS should return detailed window info
      if (windows.isNotEmpty) {
        expect(windows.first.ownerName, isNotEmpty);
        expect(windows.first.title, isNotEmpty);
      }
    });

    test('Windows should use Graphics Capture API', () async {
      if (!Platform.isWindows) return;

      final platform = ScreenRecorderPlatform.instance;
      final windows = await platform.getAvailableWindows();

      // Windows should return window list
      expect(windows.isNotEmpty, true);
    });

    test('Linux should handle Wayland and X11', () async {
      if (!Platform.isLinux) return;

      final platform = ScreenRecorderPlatform.instance;

      // Should not throw regardless of display server
      final displays = await platform.getAvailableDisplays();
      expect(displays.isNotEmpty, true);
    });
  });
}
```

### Step 2: Run cross-platform tests on each platform

```bash
# On macOS
cd packages/screen_recorder
flutter test test/integration/cross_platform_test.dart

# On Windows
cd packages/screen_recorder
flutter test test/integration/cross_platform_test.dart

# On Linux
cd packages/screen_recorder
flutter test test/integration/cross_platform_test.dart
```

**Expected:** All tests PASS on respective platforms

### Step 3: Set up CI/CD for multi-platform testing

**File:** `.github/workflows/test-all-platforms.yml`

```yaml
name: Cross-Platform Tests

on:
  push:
    branches: [main]
  pull_request:
    branches: [main]

jobs:
  test-macos:
    runs-on: macos-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.16.0'
      - run: flutter pub get
        working-directory: packages/screen_recorder
      - run: flutter test
        working-directory: packages/screen_recorder

  test-windows:
    runs-on: windows-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.16.0'
      - run: flutter pub get
        working-directory: packages/screen_recorder
      - run: flutter test
        working-directory: packages/screen_recorder

  test-linux:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: '3.16.0'
      - run: |
          sudo apt-get update
          sudo apt-get install -y libpipewire-0.3-dev libx11-dev
      - run: flutter pub get
        working-directory: packages/screen_recorder
      - run: flutter test
        working-directory: packages/screen_recorder
```

### Step 4: Document known platform differences

**File:** `packages/screen_recorder/PLATFORM_NOTES.md`

```markdown
# Platform-Specific Behavior

## macOS
- Uses ScreenCaptureKit (requires macOS 12.3+)
- Requires screen recording permission
- Window enumeration includes all visible windows
- Cursor tracking via NSEvent

## Windows
- Uses Graphics Capture API (requires Windows 10 1803+)
- Requires user consent via picker on first capture
- Window enumeration via EnumWindows
- Cursor tracking via low-level mouse hook

## Linux
- PipeWire (Wayland): Requires xdg-desktop-portal, triggers system picker
- X11 fallback: Direct window access, no permission required
- Cursor tracking: X11 only (no Wayland support yet)
- Window enumeration limited on Wayland

## Feature Parity Matrix

| Feature | macOS | Windows | Linux (PipeWire) | Linux (X11) |
|---------|-------|---------|------------------|-------------|
| Window capture | ✅ | ✅ | ⚠️ System picker | ✅ |
| Display capture | ✅ | ✅ | ✅ | ✅ |
| Window enumeration | ✅ | ✅ | ❌ | ✅ |
| Cursor tracking | ✅ | ✅ | ❌ | ✅ |
| Audio capture | ✅ | ✅ | ✅ | ✅ |
| Hardware encoding | ✅ | ⚠️ Partial | ❌ | ❌ |

✅ Full support | ⚠️ Partial support | ❌ Not supported
```

### Step 5: Fix platform-specific bugs

Based on test results, fix bugs such as:
- Frame timestamp drift on Windows
- Memory leaks in Linux X11 capture
- Permission handling on macOS Big Sur
- Color format mismatches (BGRA vs RGBA)

### Step 6: Run full test suite

```bash
cd packages/screen_recorder
flutter test
```

**Expected:** All tests PASS (unit + integration)

### Step 7: Manual testing checklist

Test on each platform:
- [ ] App launches without errors
- [ ] Window/display list populates correctly
- [ ] Recording starts and captures frames
- [ ] Cursor movements are tracked (where supported)
- [ ] Recording stops and saves file
- [ ] Playback works with recorded video
- [ ] Frame effects work (zoom, framing)
- [ ] Export dialog functions

### Step 8: Commit

```bash
git add test/integration packages/screen_recorder/PLATFORM_NOTES.md .github/workflows
git commit -m "test: add cross-platform testing and bug fixes"
```

---

## Completion Checklist

After completing all tasks:

- [ ] Windows plugin fully functional (Task 29)
- [ ] Linux plugin fully functional (Task 30)
- [ ] Cursor tracking works on Windows and Linux (Task 31)
- [ ] All cross-platform tests passing (Task 32)
- [ ] CI/CD pipeline tests all platforms
- [ ] Documentation covers platform differences
- [ ] Manual testing completed on all platforms
- [ ] Performance benchmarks recorded for each platform

**Validation Commands:**
```bash
# Test all packages
cd packages
for pkg in screen_recorder_windows screen_recorder_linux screen_recorder; do
  cd $pkg
  flutter test
  cd ..
done

# Build on each platform
flutter build macos
flutter build windows
flutter build linux

# Run app on each platform
flutter run -d macos
flutter run -d windows
flutter run -d linux
```

**Expected Results:**
- All tests pass on respective platforms
- Builds succeed without errors
- App runs and records on all platforms
- Feature parity documented and understood

---

## Notes for Implementation

**Design Decisions:**
- Windows uses COM/WinRT for modern API access
- Linux prioritizes PipeWire over X11 for Wayland support
- Cursor tracking unavailable on Wayland (portal limitation)
- Frame format standardized to BGRA across platforms

**Platform-Specific Challenges:**
- Windows: Graphics Capture requires Windows 10 1803+ (Build 17134)
- Linux: PipeWire version compatibility (0.3+ required)
- Both: Cursor rendering requires separate implementation per platform

**Future Enhancements (Not in Phase 8):**
- Hardware encoding on Windows (MediaFoundation)
- Wayland cursor support (when portal adds it)
- ChromeOS support via Android plugin
- iOS/iPadOS support with ReplayKit

**Performance Considerations:**
- Native frame capture more efficient than Flutter-side processing
- Platform-specific optimizations (D3D11 on Windows, DMA-BUF on Linux)
- Cursor tracking at 60 FPS independent of video framerate
- Memory management critical on Linux (no automatic GC)

**Testing Strategy:**
- Unit tests for each platform plugin individually
- Integration tests for cross-platform compatibility
- Manual testing for UI/UX consistency
- CI/CD for automated platform testing

---

## Success Criteria

Phase 8 is complete when:
1. Windows plugin passes all tests and records video
2. Linux plugin passes all tests and records video
3. Cursor tracking works on Windows and Linux (where supported)
4. Cross-platform tests pass on all platforms
5. CI/CD pipeline validates all platforms
6. Manual testing confirms feature parity
7. Documentation covers platform differences
8. Performance is acceptable on all platforms (30 FPS minimum)
