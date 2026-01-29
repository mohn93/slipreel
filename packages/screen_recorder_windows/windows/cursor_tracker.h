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
