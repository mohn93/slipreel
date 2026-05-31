import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/zoom_preview_override.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  test('starts null', () {
    final n = ZoomPreviewOverride();
    expect(n.value, isNull);
  });

  test('notifies on set and clear', () {
    final n = ZoomPreviewOverride();
    var ticks = 0;
    n.addListener(() => ticks++);

    final region = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );

    n.value = region;
    expect(n.value, same(region));
    expect(ticks, 1);

    n.value = null;
    expect(n.value, isNull);
    expect(ticks, 2);
  });
}
