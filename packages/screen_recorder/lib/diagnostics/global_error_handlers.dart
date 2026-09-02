import 'dart:ui';

import 'package:flutter/foundation.dart';

typedef CaptureFn = void Function(Object error, StackTrace? stack, {bool handled});

/// Routes uncaught Flutter/Dart errors into diagnostics while preserving the
/// existing debug console behavior. Call once, early in main(). Async errors
/// outside the Flutter pipeline are covered by wrapping runApp in
/// runZonedGuarded in main() (see Task 9).
void installGlobalErrorHandlers({required CaptureFn onCapture}) {
  final previous = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    previous?.call(details); // keep dumping in debug
    onCapture(details.exception, details.stack, handled: false);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    onCapture(error, stack, handled: false);
    return true;
  };
}
