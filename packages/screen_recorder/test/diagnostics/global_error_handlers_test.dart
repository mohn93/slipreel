import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/global_error_handlers.dart';

class _Recorder {
  final captures = <Object>[];
}

void main() {
  test('FlutterError.onError forwards to the capture callback', () {
    final rec = _Recorder();
    final previous = FlutterError.onError;
    addTearDown(() => FlutterError.onError = previous);

    installGlobalErrorHandlers(
      onCapture: (error, stack, {handled = false}) => rec.captures.add(error),
    );

    FlutterError.reportError(FlutterErrorDetails(exception: StateError('boom')));
    expect(rec.captures, hasLength(1));
    expect(rec.captures.single, isA<StateError>());
  });
}
