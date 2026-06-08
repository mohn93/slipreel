import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/timeline_selection.dart';

void main() {
  test('CameraSelected is value-equal by index', () {
    expect(const CameraSelected(2), const CameraSelected(2));
    expect(const CameraSelected(2) == const CameraSelected(3), isFalse);
    expect(const CameraSelected(2).hashCode, const CameraSelected(2).hashCode);
  });

  test('CameraSelected is a TimelineSelection distinct from ZoomSelected', () {
    const TimelineSelection sel = CameraSelected(0);
    expect(sel, isA<CameraSelected>());
    expect(sel == const ZoomSelected(0), isFalse);
  });
}
