import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_pipeline.dart';

void main() {
  test('camera composites only when sidecar+enabled+regions+movie all true', () {
    expect(shouldCompositeCamera(
        hasSidecar: true, enabled: true, hasRegions: true, movieExists: true), isTrue);
    for (final missing in ['sidecar', 'enabled', 'regions', 'movie']) {
      expect(
        shouldCompositeCamera(
          hasSidecar: missing != 'sidecar',
          enabled: missing != 'enabled',
          hasRegions: missing != 'regions',
          movieExists: missing != 'movie',
        ),
        isFalse,
        reason: 'missing $missing should disable the camera pass',
      );
    }
  });
}
