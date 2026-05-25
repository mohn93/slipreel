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
}
