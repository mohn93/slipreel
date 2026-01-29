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
