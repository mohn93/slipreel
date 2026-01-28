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
#include <string>

namespace screen_recorder_windows {

struct WindowInfoNative {
    std::string id;
    std::string title;
    std::string owner_name;
    int x;
    int y;
    int width;
    int height;
    bool is_on_screen;
};

struct ScreenInfoNative {
    std::string id;
    std::string name;
    int width;
    int height;
    bool is_primary;
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

    // Check if permissions are granted
    bool CheckPermissions();

    // Enumerate available windows
    std::vector<WindowInfoNative> GetAvailableWindows();

    // Enumerate available displays
    std::vector<ScreenInfoNative> GetAvailableScreens();

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
