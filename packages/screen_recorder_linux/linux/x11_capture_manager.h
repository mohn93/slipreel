#ifndef X11_CAPTURE_MANAGER_H
#define X11_CAPTURE_MANAGER_H

#include <X11/Xlib.h>
#include <X11/Xutil.h>
#include <functional>
#include <vector>
#include <string>
#include <thread>
#include <atomic>
#include <mutex>
#include <cstdint>

namespace screen_recorder_linux {

// Reuse structs from PipeWire manager
struct WindowInfoNative;
struct ScreenInfoNative;
struct FrameDataNative;
using FrameCallback = std::function<void(const FrameDataNative&)>;

class X11CaptureManager {
public:
    X11CaptureManager();
    ~X11CaptureManager();

    bool Initialize();
    bool RequestPermission() { return true; } // X11 doesn't require permission
    bool CheckPermissions() { return true; }

    std::vector<WindowInfoNative> GetAvailableWindows();
    std::vector<ScreenInfoNative> GetAvailableScreens();

    bool StartCapture(const std::string& source_id, int fps, FrameCallback callback);
    void StopCapture();

    bool IsCapturing() const { return is_capturing_; }

private:
    void CaptureLoop();
    std::string GetWindowTitle(Window window);

    Display* display_;
    Window target_window_;
    std::atomic<bool> is_capturing_;
    int target_fps_;
    FrameCallback frame_callback_;
    std::mutex callback_mutex_;
    std::thread capture_thread_;
};

} // namespace screen_recorder_linux

#endif // X11_CAPTURE_MANAGER_H
