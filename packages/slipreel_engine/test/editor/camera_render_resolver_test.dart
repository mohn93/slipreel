import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/editor/camera_render_resolver.dart';
import 'package:slipreel_engine/models/camera_region.dart';

void main() {
  CameraRegion region(int startMs, int durMs,
          {double cx = 0.5, double cy = 0.5, double size = 0.25}) =>
      CameraRegion(
        startTime: Duration(milliseconds: startMs),
        duration: Duration(milliseconds: durMs),
        centerX: cx,
        centerY: cy,
        size: size,
      );

  Duration ms(int v) => Duration(milliseconds: v);

  test('no regions → null', () {
    expect(CameraRenderResolver.renderAt(ms(0), const []), isNull);
  });

  test('steady inside a region that starts at 0 → reveal 1 (no appear ramp)',
      () {
    final s = CameraRenderResolver.renderAt(ms(500), [region(0, 1000)]);
    expect(s, isNotNull);
    expect(s!.reveal, 1.0);
    expect(s.placement.centerX, 0.5);
  });

  test(
      'm14: two regions joined within joinTolerance stay fully revealed across '
      'the seam (no appear-ramp flicker)', () {
    // First region [100,1100), second [1103,2103): a 3ms gap < the 4ms
    // joinTolerance, so placementAt glides across it as one continuous run.
    // The reveal must NOT dip back toward 0 at the second region's start.
    final regions = [region(100, 1000), region(1103, 1000)];
    // Steady inside the first region: fully shown.
    expect(CameraRenderResolver.renderAt(ms(700), regions)!.reveal, 1.0);
    // Right at the second region's start — would replay the appear ramp (≈0)
    // if the runs weren't merged with joinTolerance.
    expect(CameraRenderResolver.renderAt(ms(1103), regions)!.reveal, 1.0);
    // Just inside the second region.
    expect(CameraRenderResolver.renderAt(ms(1150), regions)!.reveal, 1.0);
  });

  test('appear ramps 0→1 over 280ms when the run starts after t=0', () {
    final regions = [region(1000, 1000, cx: 0.8)];
    final atStart = CameraRenderResolver.renderAt(ms(1000), regions)!;
    final mid = CameraRenderResolver.renderAt(ms(1140), regions)!;
    final done = CameraRenderResolver.renderAt(ms(1280), regions)!;
    expect(atStart.reveal, 0.0); // first frame fully transparent (fading in)
    expect(mid.reveal, greaterThan(0.0));
    expect(mid.reveal, lessThan(1.0));
    expect(done.reveal, 1.0);
    // Placement is the region's throughout the appear.
    expect(atStart.placement.centerX, 0.8);
  });

  test('vanish tail lingers at the last placement, reveal ramps 1→0', () {
    final regions = [region(0, 1000, cx: 0.3)];
    // Region is half-open [0,1000): at 1000 it is no longer active → vanish.
    final tailStart = CameraRenderResolver.renderAt(ms(1000), regions)!;
    final tailMid = CameraRenderResolver.renderAt(ms(1180), regions)!;
    expect(tailStart.reveal, 1.0); // vanish just beginning
    expect(tailMid.reveal, greaterThan(0.0));
    expect(tailMid.reveal, lessThan(1.0));
    // Frozen at the region's placement through the whole vanish.
    expect(tailStart.placement.centerX, 0.3);
    expect(tailMid.placement.centerX, 0.3);
  });

  test('vanish ends after 280ms; deep gap → null', () {
    final regions = [region(0, 1000)];
    expect(CameraRenderResolver.renderAt(ms(1280), regions), isNull);
    expect(CameraRenderResolver.renderAt(ms(5000), regions), isNull);
  });

  test('appear monotonically increases across the ramp', () {
    final regions = [region(1000, 1000)];
    double r(int t) => CameraRenderResolver.renderAt(ms(t), regions)!.reveal;
    final samples = [1000, 1070, 1140, 1210, 1280].map(r).toList();
    for (var i = 1; i < samples.length; i++) {
      expect(samples[i], greaterThanOrEqualTo(samples[i - 1]));
    }
  });
}
