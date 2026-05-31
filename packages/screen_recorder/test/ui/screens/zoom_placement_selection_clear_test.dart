import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/zoom_preview_override.dart';
import 'package:slipreel_engine/models/zoom_region.dart';

void main() {
  test('selection-change helper clears the override', () {
    int? selectedIndex;
    final override = ZoomPreviewOverride();

    void setSelectedIndex(int? next) {
      if (next != selectedIndex) override.value = null;
      selectedIndex = next;
    }

    // Seed: a drag is in flight on region 0.
    selectedIndex = 0;
    override.value = ZoomRegion(
      rect: const Rect.fromLTWH(0, 0, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );
    expect(override.value, isNotNull);

    // User clicks a different region on the timeline.
    setSelectedIndex(1);
    expect(override.value, isNull,
        reason: 'override must clear when selection changes');

    // No-op when the same index is re-asserted.
    override.value = ZoomRegion(
      rect: const Rect.fromLTWH(50, 50, 100, 100),
      startTime: Duration.zero,
      duration: const Duration(seconds: 1),
      zoomLevel: 2.0,
    );
    setSelectedIndex(1);
    expect(override.value, isNotNull,
        reason: 'override stable when index does not change');
  });
}
