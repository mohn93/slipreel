#ifndef PIPEWIRE_CAPTURE_MANAGER_H
#define PIPEWIRE_CAPTURE_MANAGER_H

#include <pipewire/pipewire.h>
#include <spa/param/video/format-utils.h>
#include <functional>
#include <vector>
#include <memory>
#include <string>
#include <cstdint>
#include <atomic>
#include <mutex>

namespace screen_recorder_linux {

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

class PipeWireCaptureManager {
public:
    PipeWireCaptureManager();
    ~PipeWireCaptureManager();

    // Initialize PipeWire
    bool Initialize();

    // Permission request via xdg-desktop-portal
    bool RequestPermission();
    bool CheckPermissions();

    // Enumerate available windows (via portal)
    std::vector<WindowInfoNative> GetAvailableWindows();

    // Enumerate available displays
    std::vector<ScreenInfoNative> GetAvailableScreens();

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

    std::atomic<bool> is_capturing_;
    FrameCallback frame_callback_;
    std::mutex callback_mutex_;

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
