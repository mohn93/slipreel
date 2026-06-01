import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  group('setTimelineScale', () {
    test('updates state when value differs', () {
      final c = EditorProjectController();
      c.setTimelineScale(2.0);
      expect(c.current.timelineScale, 2.0);
    });

    test('clamps above 8.0', () {
      final c = EditorProjectController();
      c.setTimelineScale(15.0);
      expect(c.current.timelineScale, 8.0);
    });

    test('clamps below 1.0', () {
      final c = EditorProjectController();
      c.setTimelineScale(0.25);
      expect(c.current.timelineScale, 1.0);
    });

    test('no-op when scale equals current and anchor is null', () {
      final c = EditorProjectController();
      final before = c.current;
      c.setTimelineScale(1.0);  // already 1.0
      expect(identical(c.current, before), isTrue,
          reason: 'no state object should be emitted');
    });

    test('emits when scale equals current but anchor is non-null', () {
      final c = EditorProjectController();
      final before = c.current;
      c.setTimelineScale(1.0, anchorTime: const Duration(seconds: 3));
      expect(identical(c.current, before), isFalse);
      expect(c.current.pendingScaleAnchor, const Duration(seconds: 3));
    });

    test('successive calls with different anchors at same scale both emit', () {
      final c = EditorProjectController();
      c.setTimelineScale(2.0, anchorTime: const Duration(seconds: 1));
      final after1 = c.current;
      c.setTimelineScale(2.0, anchorTime: const Duration(seconds: 5));
      final after2 = c.current;
      expect(identical(after1, after2), isFalse);
      expect(after2.pendingScaleAnchor, const Duration(seconds: 5));
    });

    test('null anchor on the call sets pendingScaleAnchor to null', () {
      final c = EditorProjectController();
      c.setTimelineScale(2.0, anchorTime: const Duration(seconds: 3));
      c.setTimelineScale(3.0);  // no anchor
      expect(c.current.timelineScale, 3.0);
      expect(c.current.pendingScaleAnchor, isNull);
    });
  });

  group('clearPendingScaleAnchor', () {
    test('clears the anchor without changing scale', () {
      final c = EditorProjectController();
      c.setTimelineScale(4.0, anchorTime: const Duration(seconds: 2));
      c.clearPendingScaleAnchor();
      expect(c.current.timelineScale, 4.0);
      expect(c.current.pendingScaleAnchor, isNull);
    });

    test('no-op when anchor is already null', () {
      final c = EditorProjectController();
      final before = c.current;
      c.clearPendingScaleAnchor();
      expect(identical(c.current, before), isTrue);
    });
  });
}
