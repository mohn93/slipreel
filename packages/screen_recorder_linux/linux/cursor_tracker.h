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
