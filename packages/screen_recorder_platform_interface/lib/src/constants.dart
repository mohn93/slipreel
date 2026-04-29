/// Method channel constants for screen recorder plugin
class ScreenRecorderChannels {
  /// Main method channel for recording control and capability queries
  static const String recording = 'com.screenflow_studio.screen_recorder/recording';

  /// Event channel for video frame stream
  static const String frames = 'com.screenflow_studio.screen_recorder/frames';

  /// Event channel for audio sample stream
  static const String audio = 'com.screenflow_studio.screen_recorder/audio';

  /// Event channel for cursor position stream
  static const String cursor = 'com.screenflow_studio.screen_recorder/cursor';
}

/// Method names for the recording channel
class ScreenRecorderMethods {
  static const String getAvailableScreens = 'getAvailableScreens';
  static const String getAvailableWindows = 'getAvailableWindows';
  static const String getAudioDevices = 'getAudioDevices';
  static const String startRecording = 'startRecording';
  static const String pauseRecording = 'pauseRecording';
  static const String resumeRecording = 'resumeRecording';
  static const String stopRecording = 'stopRecording';
  static const String requestPermissions = 'requestPermissions';
  static const String checkPermissions = 'checkPermissions';
  static const String startLiveRecording = 'startLiveRecording';
  static const String stopLiveRecording = 'stopLiveRecording';
  static const String listSources = 'listSources';
  static const String captureThumbnail = 'captureThumbnail';
}
