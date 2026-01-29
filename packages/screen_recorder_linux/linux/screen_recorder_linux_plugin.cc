#include "include/screen_recorder_linux/screen_recorder_linux_plugin.h"
#include "screen_recorder_linux_plugin_private.h"

#include <flutter_linux/flutter_linux.h>
#include <gtk/gtk.h>
#include <sys/utsname.h>

#include <cstring>
#include <memory>

#ifdef USE_PIPEWIRE
#include "pipewire_capture_manager.h"
#else
#include "x11_capture_manager.h"
#endif

#define SCREEN_RECORDER_LINUX_PLUGIN(obj) \
  (G_TYPE_CHECK_INSTANCE_CAST((obj), screen_recorder_linux_plugin_get_type(), \
                              ScreenRecorderLinuxPlugin))

struct _ScreenRecorderLinuxPlugin {
  GObject parent_instance;
#ifdef USE_PIPEWIRE
  std::unique_ptr<screen_recorder_linux::PipeWireCaptureManager> capture_manager;
#else
  std::unique_ptr<screen_recorder_linux::X11CaptureManager> capture_manager;
#endif
  FlEventChannel* frames_channel;
  FlEventSink* frames_sink;
  FlEventChannel* audio_channel;
  FlEventChannel* cursor_channel;
};

G_DEFINE_TYPE(ScreenRecorderLinuxPlugin, screen_recorder_linux_plugin, g_object_get_type())

// Frame event channel handlers
static FlMethodErrorResponse* frames_listen_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  ScreenRecorderLinuxPlugin* self = SCREEN_RECORDER_LINUX_PLUGIN(user_data);
  self->frames_sink = fl_event_channel_get_event_sink(channel);
  return nullptr;
}

static FlMethodErrorResponse* frames_cancel_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  ScreenRecorderLinuxPlugin* self = SCREEN_RECORDER_LINUX_PLUGIN(user_data);
  self->frames_sink = nullptr;
  return nullptr;
}

// Audio event channel handlers (stubs for now - Task 31+ will implement)
static FlMethodErrorResponse* audio_listen_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  // Will be implemented in Task 31+
  return nullptr;
}

static FlMethodErrorResponse* audio_cancel_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  // Will be implemented in Task 31+
  return nullptr;
}

// Cursor event channel handlers (stubs for now - Task 31 will implement)
static FlMethodErrorResponse* cursor_listen_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  // Will be implemented in Task 31
  return nullptr;
}

static FlMethodErrorResponse* cursor_cancel_cb(
    FlEventChannel* channel,
    FlValue* args,
    gpointer user_data) {
  // Will be implemented in Task 31
  return nullptr;
}

// Helper to convert native window/screen info to FlValue
static FlValue* window_info_to_fl_value(const screen_recorder_linux::WindowInfoNative& window) {
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "id", fl_value_new_string(window.id.c_str()));
  fl_value_set_string_take(map, "title", fl_value_new_string(window.title.c_str()));
  fl_value_set_string_take(map, "ownerName", fl_value_new_string(window.owner_name.c_str()));
  fl_value_set_string_take(map, "x", fl_value_new_int(window.x));
  fl_value_set_string_take(map, "y", fl_value_new_int(window.y));
  fl_value_set_string_take(map, "width", fl_value_new_int(window.width));
  fl_value_set_string_take(map, "height", fl_value_new_int(window.height));
  fl_value_set_string_take(map, "isOnScreen", fl_value_new_bool(window.is_on_screen));
  return fl_value_ref(map);
}

static FlValue* screen_info_to_fl_value(const screen_recorder_linux::ScreenInfoNative& screen) {
  g_autoptr(FlValue) map = fl_value_new_map();
  fl_value_set_string_take(map, "id", fl_value_new_string(screen.id.c_str()));
  fl_value_set_string_take(map, "name", fl_value_new_string(screen.name.c_str()));
  fl_value_set_string_take(map, "width", fl_value_new_int(screen.width));
  fl_value_set_string_take(map, "height", fl_value_new_int(screen.height));
  fl_value_set_string_take(map, "isPrimary", fl_value_new_bool(screen.is_primary));
  return fl_value_ref(map);
}

// Implementation of get_platform_version for unit testing
FlMethodResponse* get_platform_version() {
  struct utsname uname_data = {};
  uname(&uname_data);
  g_autofree gchar* version = g_strdup_printf("Linux %s", uname_data.version);
  g_autoptr(FlValue) result = fl_value_new_string(version);
  return FL_METHOD_RESPONSE(fl_method_success_response_new(result));
}

// Called when a method call is received from Flutter.
static void screen_recorder_linux_plugin_handle_method_call(
    ScreenRecorderLinuxPlugin* self,
    FlMethodCall* method_call) {
  g_autoptr(FlMethodResponse) response = nullptr;

  const gchar* method = fl_method_call_get_name(method_call);

  if (strcmp(method, "requestPermissions") == 0) {
    bool granted = self->capture_manager->RequestPermission();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(granted)));
  } else if (strcmp(method, "checkPermissions") == 0) {
    bool has_permission = self->capture_manager->CheckPermissions();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_bool(has_permission)));
  } else if (strcmp(method, "getAvailableWindows") == 0) {
    auto windows = self->capture_manager->GetAvailableWindows();
    g_autoptr(FlValue) list = fl_value_new_list();
    for (const auto& window : windows) {
      g_autoptr(FlValue) window_map = window_info_to_fl_value(window);
      fl_value_append_take(list, window_map);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  } else if (strcmp(method, "getAvailableScreens") == 0) {
    auto screens = self->capture_manager->GetAvailableScreens();
    g_autoptr(FlValue) list = fl_value_new_list();
    for (const auto& screen : screens) {
      g_autoptr(FlValue) screen_map = screen_info_to_fl_value(screen);
      fl_value_append_take(list, screen_map);
    }
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  } else if (strcmp(method, "getAudioDevices") == 0) {
    // TODO: Implement audio device enumeration
    g_autoptr(FlValue) list = fl_value_new_list();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(list));
  } else if (strcmp(method, "startRecording") == 0) {
    FlValue* args = fl_method_call_get_args(method_call);
    FlValue* source_id_val = fl_value_lookup_string(args, "sourceId");
    FlValue* fps_val = fl_value_lookup_string(args, "frameRate");

    if (!source_id_val) {
      response = FL_METHOD_RESPONSE(fl_method_error_response_new(
          "INVALID_ARGUMENTS", "sourceId is required", nullptr));
    } else {
      const char* source_id = fl_value_get_string(source_id_val);
      int fps = fps_val ? fl_value_get_int(fps_val) : 30;

      bool success = self->capture_manager->StartCapture(
          source_id, fps,
          [self](const screen_recorder_linux::FrameDataNative& frame) {
            if (self->frames_sink) {
              g_autoptr(FlValue) frame_map = fl_value_new_map();
              g_autoptr(FlValue) data_value = fl_value_new_uint8_list(
                  frame.data.data(), frame.data.size());
              fl_value_set_string_take(frame_map, "data", data_value);
              fl_value_set_string_take(frame_map, "width", fl_value_new_int(frame.width));
              fl_value_set_string_take(frame_map, "height", fl_value_new_int(frame.height));
              fl_value_set_string_take(frame_map, "timestampMicros", fl_value_new_int(frame.timestamp_micros));
              fl_value_set_string_take(frame_map, "format", fl_value_new_string("bgra"));

              fl_event_sink_success(self->frames_sink, frame_map);
            }
          });

      if (success) {
        response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
      } else {
        response = FL_METHOD_RESPONSE(fl_method_error_response_new(
            "START_FAILED", "Failed to start recording", nullptr));
      }
    }
  } else if (strcmp(method, "stopRecording") == 0) {
    self->capture_manager->StopCapture();
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(fl_value_new_string("")));
  } else if (strcmp(method, "pauseRecording") == 0) {
    // TODO: Implement pause
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else if (strcmp(method, "resumeRecording") == 0) {
    // TODO: Implement resume
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static void screen_recorder_linux_plugin_dispose(GObject* object) {
  ScreenRecorderLinuxPlugin* self = SCREEN_RECORDER_LINUX_PLUGIN(object);

  if (self->capture_manager) {
    self->capture_manager->StopCapture();
    self->capture_manager.reset();
  }

  g_clear_object(&self->frames_channel);
  g_clear_object(&self->audio_channel);
  g_clear_object(&self->cursor_channel);

  G_OBJECT_CLASS(screen_recorder_linux_plugin_parent_class)->dispose(object);
}

static void screen_recorder_linux_plugin_class_init(ScreenRecorderLinuxPluginClass* klass) {
  G_OBJECT_CLASS(klass)->dispose = screen_recorder_linux_plugin_dispose;
}

static void screen_recorder_linux_plugin_init(ScreenRecorderLinuxPlugin* self) {
#ifdef USE_PIPEWIRE
  self->capture_manager = std::make_unique<screen_recorder_linux::PipeWireCaptureManager>();
#else
  self->capture_manager = std::make_unique<screen_recorder_linux::X11CaptureManager>();
#endif
  // TODO (Task 32): Add initialization check before using capture_manager
  self->capture_manager->Initialize();
  self->frames_sink = nullptr;
}

static void method_call_cb(FlMethodChannel* channel, FlMethodCall* method_call,
                           gpointer user_data) {
  ScreenRecorderLinuxPlugin* plugin = SCREEN_RECORDER_LINUX_PLUGIN(user_data);
  screen_recorder_linux_plugin_handle_method_call(plugin, method_call);
}

void screen_recorder_linux_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  ScreenRecorderLinuxPlugin* plugin = SCREEN_RECORDER_LINUX_PLUGIN(
      g_object_new(screen_recorder_linux_plugin_get_type(), nullptr));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  g_autoptr(FlMethodChannel) channel =
      fl_method_channel_new(fl_plugin_registrar_get_messenger(registrar),
                            "com.screenflow_studio.screen_recorder/methods",
                            FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel, method_call_cb,
                                            g_object_ref(plugin),
                                            g_object_unref);

  // Set up event channel for frames
  plugin->frames_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.screenflow_studio.screen_recorder/frames",
      FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      plugin->frames_channel,
      frames_listen_cb,
      frames_cancel_cb,
      g_object_ref(plugin),
      g_object_unref);

  // Register audio event channel
  plugin->audio_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.screenflow_studio.screen_recorder/audio",
      FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      plugin->audio_channel,
      audio_listen_cb,
      audio_cancel_cb,
      g_object_ref(plugin),
      g_object_unref);

  // Register cursor event channel
  plugin->cursor_channel = fl_event_channel_new(
      fl_plugin_registrar_get_messenger(registrar),
      "com.screenflow_studio.screen_recorder/cursor",
      FL_METHOD_CODEC(codec));
  fl_event_channel_set_stream_handlers(
      plugin->cursor_channel,
      cursor_listen_cb,
      cursor_cancel_cb,
      g_object_ref(plugin),
      g_object_unref);

  g_object_unref(plugin);
}
