import 'package:flutter/services.dart';

import '../state/window_mode.dart';

/// Real [WindowChrome] backed by the app-level `slipreel/window` channel
/// handled in `macos/Runner/MainFlutterWindow.swift`.
class MethodChannelWindowChrome implements WindowChrome {
  static const _channel = MethodChannel('slipreel/window');

  @override
  Future<void> setMode(WindowMode mode) async {
    await _channel.invokeMethod<void>('setMode', {'mode': mode.name});
  }

  @override
  Future<String?> showGearMenu() async {
    return _channel.invokeMethod<String>('showGearMenu');
  }

  @override
  Future<void> startWindowDrag() async {
    await _channel.invokeMethod<void>('startWindowDrag');
  }

  @override
  Future<void> setBarSize(double width, double height) async {
    await _channel
        .invokeMethod<void>('setBarSize', {'width': width, 'height': height});
  }
}
