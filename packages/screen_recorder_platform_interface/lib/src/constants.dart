/// Method channel constants for screen recorder plugin
class ScreenRecorderChannels {
  /// Main method channel for recording control and capability queries
  static const String recording = 'com.slipreel.screen_recorder/recording';

  /// Event channel for video frame stream
  static const String frames = 'com.slipreel.screen_recorder/frames';

  /// Event channel for audio sample stream
  static const String audio = 'com.slipreel.screen_recorder/audio';

  /// Event channel for cursor position stream
  static const String cursor = 'com.slipreel.screen_recorder/cursor';

  /// Event channel for the live microphone level (0..1) stream.
  static const String micLevel = 'com.slipreel.screen_recorder/micLevel';

  /// Event channel for global recording hotkey events.
  static const String hotkeys = 'com.slipreel.screen_recorder/hotkeys';

  /// Event channel for system sleep/wake events.
  static const String sleep = 'com.slipreel.screen_recorder/sleep';

  /// Event channel for keystroke events during recording.
  static const String keystrokes = 'com.slipreel.screen_recorder/keystrokes';

  /// Event channel for fatal recording errors raised mid-capture (e.g. the
  /// SCStream stops because the display was unplugged or permission revoked).
  static const String recordingError =
      'com.slipreel.screen_recorder/recordingError';
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
  static const String listDevices = 'listDevices';
  static const String startDeviceRecording = 'startDeviceRecording';
  static const String captureThumbnail = 'captureThumbnail';
  static const String selectRegion = 'selectRegion';
  static const String pickSource = 'pickSource';
  static const String showMicrophoneMenu = 'showMicrophoneMenu';
  static const String showSystemAudioMenu = 'showSystemAudioMenu';
  static const String startMicMonitor = 'startMicMonitor';
  static const String stopMicMonitor = 'stopMicMonitor';
  static const String isAccessibilityTrusted = 'isAccessibilityTrusted';
  static const String requestAccessibilityPermission =
      'requestAccessibilityPermission';
  static const String getScreenRecordingPermission = 'getScreenRecordingPermission';
  static const String getMicrophonePermission = 'getMicrophonePermission';
  static const String getAccessibilityPermission = 'getAccessibilityPermission';
  static const String requestMicrophonePermission = 'requestMicrophonePermission';
  static const String getCameraPermission = 'getCameraPermission';
  static const String requestCameraPermission = 'requestCameraPermission';
  static const String showCameraMenu = 'showCameraMenu';
  static const String showDeviceMenu = 'showDeviceMenu';
  static const String requestScreenRecordingPermission =
      'requestScreenRecordingPermission';
  static const String showScreenRecordingPermissionGuide =
      'showScreenRecordingPermissionGuide';
  static const String getStockCursorImages = 'getStockCursorImages';
  static const String registerRecordingHotkeys = 'registerRecordingHotkeys';
  static const String unregisterRecordingHotkeys = 'unregisterRecordingHotkeys';
  static const String startSleepObserver = 'startSleepObserver';
}
