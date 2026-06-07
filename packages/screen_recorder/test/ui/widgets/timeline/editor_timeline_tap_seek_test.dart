import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/onboarding/tips_controller.dart';
import 'package:screen_recorder/onboarding/tips_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';
import 'package:screen_recorder/ui/widgets/timeline/cut_marker.dart';
import 'package:screen_recorder/ui/widgets/timeline/editor_timeline.dart';
import 'package:screen_recorder/ui/widgets/timeline/zoom_lane.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/clip_slice.dart';

Future<TipsController> _freshTips() async {
  SharedPreferences.setMockInitialValues({});
  final c = TipsController(TipsStore());
  await c.load();
  return c;
}

Widget _host(Widget child, TipsController tips, {double width = 600}) =>
    ProviderScope(
      overrides: [tipsControllerProvider.overrideWith((ref) => tips)],
      child: MaterialApp(
        theme: ThemeData(
          extensions: const [AppPalette.midnight],
          useMaterial3: true,
        ),
        home: Scaffold(
          body: SizedBox(width: width, height: 220, child: child),
        ),
      ),
    );

ClipSlice _slice(int start, int end) => ClipSlice(
  cutStart: Duration(seconds: start),
  cutEnd: Duration(seconds: end),
);

void _expectSeek(Duration? actual, Duration expected) {
  expect(actual, isNotNull);
  expect(actual!.inMilliseconds, closeTo(expected.inMilliseconds, 35));
}

void main() {
  testWidgets('tapping a slice area seeks the playhead', (tester) async {
    final tips = await _freshTips();
    Duration? seeked;

    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          clips: [_slice(0, 5), _slice(5, 10)],
          onSeek: (t) => seeked = t,
          onSliceSelected: (_) {},
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    final body = find.byKey(const ValueKey('slice-bar-body')).first;
    await tester.tap(body, kind: PointerDeviceKind.mouse);
    await tester.pump();

    _expectSeek(seeked, const Duration(milliseconds: 2480));
  });

  testWidgets('tapping empty zoom lane seeks the playhead', (tester) async {
    final tips = await _freshTips();
    Duration? seeked;

    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          onSeek: (t) => seeked = t,
          onZoomAdded: (_, __) {},
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    final zoomLaneTopLeft = tester.getTopLeft(find.byType(ZoomLane));
    await tester.tapAt(
      zoomLaneTopLeft + const Offset(112, 22),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    _expectSeek(seeked, const Duration(seconds: 2));
  });

  testWidgets('tapping an existing zoom pill seeks the playhead', (
    tester,
  ) async {
    final tips = await _freshTips();
    Duration? seeked;

    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          zoomRegions: [
            ZoomRegion(
              rect: const Rect.fromLTWH(0, 0, 100, 100),
              startTime: const Duration(seconds: 2),
              duration: const Duration(seconds: 2),
              zoomLevel: 2,
            ),
          ],
          onSeek: (t) => seeked = t,
          onZoomSelected: (_) {},
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    final zoomLaneTopLeft = tester.getTopLeft(find.byType(ZoomLane));
    await tester.tapAt(
      zoomLaneTopLeft + const Offset(168, 22),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    _expectSeek(seeked, const Duration(seconds: 3));
  });

  testWidgets('tapping a seam marker seeks the playhead', (tester) async {
    final tips = await _freshTips();
    Duration? seeked;

    await tester.pumpWidget(
      _host(
        EditorTimeline(
          duration: const Duration(seconds: 10),
          position: ValueNotifier<Duration>(Duration.zero),
          clips: [_slice(0, 5), _slice(5, 10)],
          onSeek: (t) => seeked = t,
          onMergeSeam: (_) {},
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CutMarker), kind: PointerDeviceKind.mouse);
    await tester.pump();

    _expectSeek(seeked, const Duration(seconds: 5));
  });
}
