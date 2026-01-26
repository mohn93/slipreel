import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'screen_recorder_macos_method_channel.dart';

export 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// The macOS implementation of [ScreenRecorderPlatform].
class ScreenRecorderMacos {
  /// Registers this class as the platform implementation.
  static void registerWith() {
    ScreenRecorderPlatform.instance = MethodChannelScreenRecorderMacos();
  }
}
