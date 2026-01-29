#include "x11_capture_manager.h"
#include "pipewire_capture_manager.h"
#include <X11/Xatom.h>
#include <X11/extensions/XShm.h>
#include <sys/ipc.h>
#include <sys/shm.h>
#include <cstring>
#include <chrono>
#include <thread>

namespace screen_recorder_linux {

X11CaptureManager::X11CaptureManager()
    : display_(nullptr),
      target_window_(0),
      is_capturing_(false),
      target_fps_(30) {
}

X11CaptureManager::~X11CaptureManager() {
    StopCapture();

    if (display_) {
        XCloseDisplay(display_);
    }
}

bool X11CaptureManager::Initialize() {
    display_ = XOpenDisplay(nullptr);
    if (!display_) {
        return false;
    }
    return true;
}

std::string X11CaptureManager::GetWindowTitle(Window window) {
    XTextProperty text_prop;
    if (XGetWMName(display_, window, &text_prop) != 0 && text_prop.value) {
        std::string title(reinterpret_cast<char*>(text_prop.value));
        XFree(text_prop.value);
        return title;
    }
    return "Unknown";
}

std::vector<WindowInfoNative> X11CaptureManager::GetAvailableWindows() {
    std::vector<WindowInfoNative> windows;

    if (!display_) {
        return windows;
    }

    Window root = DefaultRootWindow(display_);
    Atom atom = XInternAtom(display_, "_NET_CLIENT_LIST", True);

    if (atom == None) {
        return windows;
    }

    Atom actual_type;
    int actual_format;
    unsigned long num_items, bytes_after;
    unsigned char* data = nullptr;

    if (XGetWindowProperty(display_, root, atom, 0, ~0L, False, AnyPropertyType,
                          &actual_type, &actual_format, &num_items, &bytes_after,
                          &data) == Success && data) {

        Window* window_list = reinterpret_cast<Window*>(data);

        for (unsigned long i = 0; i < num_items; i++) {
            Window win = window_list[i];

            XWindowAttributes attrs;
            if (XGetWindowAttributes(display_, win, &attrs)) {
                WindowInfoNative info;
                info.id = std::to_string(win);
                info.title = GetWindowTitle(win);
                info.owner_name = "";
                info.x = attrs.x;
                info.y = attrs.y;
                info.width = attrs.width;
                info.height = attrs.height;
                info.is_on_screen = (attrs.map_state == IsViewable);

                windows.push_back(info);
            }
        }

        XFree(data);
    }

    return windows;
}

std::vector<ScreenInfoNative> X11CaptureManager::GetAvailableScreens() {
    std::vector<ScreenInfoNative> screens;

    if (!display_) {
        return screens;
    }

    int screen_count = ScreenCount(display_);

    for (int i = 0; i < screen_count; i++) {
        Screen* screen = ScreenOfDisplay(display_, i);

        ScreenInfoNative info;
        info.id = std::to_string(i);
        info.name = "Screen " + std::to_string(i);
        info.width = WidthOfScreen(screen);
        info.height = HeightOfScreen(screen);
        info.is_primary = (i == DefaultScreen(display_));

        screens.push_back(info);
    }

    return screens;
}

bool X11CaptureManager::StartCapture(const std::string& source_id, int fps, FrameCallback callback) {
    if (is_capturing_) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        frame_callback_ = callback;
    }
    target_fps_ = fps;

    // Parse source_id - could be window ID or screen ID
    try {
        unsigned long window_id = std::stoull(source_id);
        target_window_ = static_cast<Window>(window_id);
    } catch (...) {
        // If parsing fails, use root window
        target_window_ = DefaultRootWindow(display_);
    }

    // Verify window exists
    XWindowAttributes attrs;
    if (!XGetWindowAttributes(display_, target_window_, &attrs)) {
        return false;
    }

    is_capturing_ = true;
    capture_thread_ = std::thread(&X11CaptureManager::CaptureLoop, this);

    return true;
}

void X11CaptureManager::StopCapture() {
    if (!is_capturing_) {
        return;
    }

    is_capturing_ = false;

    if (capture_thread_.joinable()) {
        capture_thread_.join();
    }
}

void X11CaptureManager::CaptureLoop() {
    int frame_delay_ms = 1000 / target_fps_;

    while (is_capturing_) {
        auto frame_start = std::chrono::steady_clock::now();

        XWindowAttributes attrs;
        if (!XGetWindowAttributes(display_, target_window_, &attrs)) {
            break;
        }

        XImage* image = XGetImage(display_, target_window_, 0, 0,
                                  attrs.width, attrs.height, AllPlanes, ZPixmap);

        if (!image) {
            std::this_thread::sleep_for(std::chrono::milliseconds(frame_delay_ms));
            continue;
        }

        // Convert XImage to BGRA format
        int width = image->width;
        int height = image->height;
        std::vector<uint8_t> frame_data(width * height * 4);

        // TODO (Task 32): Optimize X11 pixel conversion - use direct buffer access instead of XGetPixel
        for (int y = 0; y < height; y++) {
            for (int x = 0; x < width; x++) {
                unsigned long pixel = XGetPixel(image, x, y);

                int idx = (y * width + x) * 4;
                // Convert to BGRA
                frame_data[idx + 0] = (pixel >> 0) & 0xFF;  // B
                frame_data[idx + 1] = (pixel >> 8) & 0xFF;  // G
                frame_data[idx + 2] = (pixel >> 16) & 0xFF; // R
                frame_data[idx + 3] = 255;                   // A
            }
        }

        XDestroyImage(image);

        // Get timestamp
        auto now = std::chrono::system_clock::now();
        auto micros = std::chrono::duration_cast<std::chrono::microseconds>(
            now.time_since_epoch()).count();

        FrameDataNative native_frame;
        native_frame.data = std::move(frame_data);
        native_frame.width = width;
        native_frame.height = height;
        native_frame.timestamp_micros = micros;

        {
            std::lock_guard<std::mutex> lock(callback_mutex_);
            if (frame_callback_) {
                frame_callback_(native_frame);
            }
        }

        // Maintain target FPS
        auto frame_end = std::chrono::steady_clock::now();
        auto elapsed = std::chrono::duration_cast<std::chrono::milliseconds>(
            frame_end - frame_start).count();

        if (elapsed < frame_delay_ms) {
            std::this_thread::sleep_for(
                std::chrono::milliseconds(frame_delay_ms - elapsed));
        }
    }
}

} // namespace screen_recorder_linux
