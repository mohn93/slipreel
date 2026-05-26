import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/debug/debug_probe.dart';

void main() {
  group('DebugProbe', () {
    test('default global is a NoopDebugProbe', () {
      expect(debugProbe, isA<NoopDebugProbe>());
    });

    test('NoopDebugProbe.install() does nothing and does not throw', () {
      const NoopDebugProbe().install();
    });

    test('NoopDebugProbe.navigatorObserver() returns null', () {
      expect(const NoopDebugProbe().navigatorObserver(), isNull);
    });
  });
}
