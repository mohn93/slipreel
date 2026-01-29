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

bool PipeWireCaptureManager::CheckPermissions() {
    // On Wayland with PipeWire, permission is per-session
    // Return true as we can always attempt to start capture
    return true;
}

std::vector<WindowInfoNative> PipeWireCaptureManager::GetAvailableWindows() {
    // PipeWire doesn't provide window enumeration
    // This requires xdg-desktop-portal or X11 fallback
    // For now, return empty list - user will select via system picker
    return std::vector<WindowInfoNative>();
}

std::vector<ScreenInfoNative> PipeWireCaptureManager::GetAvailableScreens() {
    std::vector<ScreenInfoNative> screens;

    // Query displays via PipeWire registry
    // For now, return single default display
    // TODO (Task 32): Query actual display resolution instead of hardcoded 1920x1080
    ScreenInfoNative screen;
    screen.id = "0";
    screen.name = "Default Display";
    screen.width = 1920;
    screen.height = 1080;
    screen.is_primary = true;
    screens.push_back(screen);

    return screens;
}

bool PipeWireCaptureManager::StartCapture(const std::string& source_id, int fps, FrameCallback callback) {
    if (is_capturing_) {
        return false;
    }

    {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        frame_callback_ = callback;
    }

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
    // TODO (Task 32): Fix buffer overflow risk in SPA pod builder
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

    {
        std::lock_guard<std::mutex> lock(callback_mutex_);
        if (frame_callback_) {
            frame_callback_(native_frame);
        }
    }
}

} // namespace screen_recorder_linux
