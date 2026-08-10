import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/camera_region.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  CameraRegion region() => CameraRegion(
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        centerX: 0.8,
        centerY: 0.8,
        size: 0.22,
      );

  group('Timeline.cameraTracks', () {
    test('defaults to no camera tracks; activeCameraRegions is empty', () {
      final t = Timeline.defaults();
      expect(t.cameraTracks, isEmpty);
      expect(t.activeCameraRegions, isEmpty);
    });

    test('activeCameraRegions returns the first track regions', () {
      final t = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      expect(t.activeCameraRegions, hasLength(1));
    });

    test('CameraTrack constructor does not retain a mutable region list', () {
      final source = [region()];
      final track = CameraTrack(regions: source);
      source.clear();
      expect(track.regions, hasLength(1));
      expect(() => track.regions.clear(), throwsUnsupportedError);
    });

    test('json round-trips camera tracks alongside zoom + clips', () {
      final t = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      final back = Timeline.fromJson(t.toJson());
      expect(back.activeCameraRegions, [region()]);
      expect(back, t);
    });

    test('fromJson with no cameraTracks key yields an empty list (old sidecar)', () {
      final back = Timeline.fromJson(const {'zoomTracks': [], 'clips': []});
      expect(back.cameraTracks, isEmpty);
    });

    test('equality includes camera tracks', () {
      final a = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      final b = Timeline(cameraTracks: [CameraTrack(regions: [region()])]);
      expect(a, b);
      expect(a == Timeline.defaults(), isFalse);
    });
  });
}
