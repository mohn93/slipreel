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
