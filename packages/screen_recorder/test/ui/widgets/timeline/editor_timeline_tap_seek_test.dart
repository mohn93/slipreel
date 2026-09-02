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

double _scrollOffset(WidgetTester tester) {
  final scroll = tester.widget<SingleChildScrollView>(
    find.byType(SingleChildScrollView),
  );
  return scroll.controller!.offset;
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

  testWidgets('tapping a zoom pill seeks via the keep-selection path', (
    tester,
  ) async {
    final tips = await _freshTips();
    Duration? seeked;
    Duration? keepSeeked;

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
          onSeekKeepSelection: (t) => keepSeeked = t,
          onZoomSelected: (_) {},
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Press the pill body. A click on a bar now moves the playhead AND
    // selects the bar: the seek routes through onSeekKeepSelection (which
    // leaves selection to the pill's own handler) and must NOT go through
    // onSeek, whose "click anywhere" path would clear the selection.
    await tester.tap(
      find.byKey(const ValueKey('zoom-pill-body-0')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(keepSeeked, isNotNull,
        reason: 'a pill tap should move the playhead');
    expect(seeked, isNull,
        reason: 'a pill tap must use the keep-selection seek, not onSeek');
  });

  testWidgets('seek commits at the pressed x, not the release x', (
    tester,
  ) async {
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

    // Press in the empty lane area at the 2s mark, then drift a few px (still
    // within the 8px tap slop, so it stays a tap) before releasing. The
    // committed seek must land on the PRESS x — this guards the fix where a
    // seek that was committing at the release frame drifted during playback.
    final zoomLaneTopLeft = tester.getTopLeft(find.byType(ZoomLane));
    final downPos = zoomLaneTopLeft + const Offset(112, 22);
    final gesture = await tester.startGesture(
      downPos,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(5, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    // 5px ≈ 89ms at this scale — well past the 35ms tolerance, so a
    // release-x commit (~2089ms) would fail this. The press x is 2000ms.
    _expectSeek(seeked, const Duration(seconds: 2));
  });

  testWidgets('clicking a zoom pill control (resize handle) does not seek', (
    tester,
  ) async {
    final tips = await _freshTips();
    Duration? seeked;
    Duration? keepSeeked;

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
          onSeekKeepSelection: (t) => keepSeeked = t,
          onZoomSelected: (_) {},
          onZoomChanged: (_, __) {},
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // A pill's resize handle (and its delete button) is a control, not a seek
    // target — they route through onBarSuppressSeek. A stationary tap on the
    // left edge must NOT commit a seek to the edge's position, via EITHER the
    // clearing path (onSeek) or the keep-selection path (regression: with the
    // bar-suppression removed, a control tap seeked). Both null means the
    // control suppressed the seek; had the tap hit empty timeline, onSeek would
    // have fired, and had it hit the pill body, onSeekKeepSelection would have.
    final pill = tester.getRect(find.byKey(const ValueKey('zoom-pill-body-0')));
    await tester.tapAt(
      Offset(pill.left + 3, pill.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();

    expect(seeked, isNull, reason: 'a pill control must not seek via onSeek');
    expect(keepSeeked, isNull,
        reason: 'a pill control must not seek via onSeekKeepSelection');
  });

  testWidgets('bar drag repositions without committing a seek', (tester) async {
    final tips = await _freshTips();
    Duration? seeked;
    Duration? keepSeeked;

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
          onSeekKeepSelection: (t) => keepSeeked = t,
          onZoomSelected: (_) {},
          onZoomChanged: (_, __) {},
        ),
        tips,
      ),
    );
    await tester.pumpAndSettle();

    // Drag the pill body well past the 8px tap slop — a reposition, not a tap.
    // Neither seek callback should fire.
    final center = tester.getCenter(
      find.byKey(const ValueKey('zoom-pill-body-0')),
    );
    final gesture = await tester.startGesture(
      center,
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    await gesture.moveBy(const Offset(40, 0));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(seeked, isNull, reason: 'a bar drag must not seek');
    expect(keepSeeked, isNull, reason: 'a bar drag must not seek');
  });

  testWidgets(
    'seek uses the pointer-down scroll frame when auto-follow scrolls mid-tap',
    (tester) async {
      final tips = await _freshTips();
      Duration? seeked;
      // scale=4.0, total=10s, viewport=600 → content=2400, pps=240, inset=20.
      final position = ValueNotifier<Duration>(Duration.zero);

      await tester.pumpWidget(
        _host(
          EditorTimeline(
            duration: const Duration(seconds: 10),
            position: position,
            onSeek: (t) => seeked = t,
            onZoomAdded: (_, __) {},
            timelineScale: 4.0,
            isPlaying: true,
          ),
          tips,
        ),
      );
      await tester.pumpAndSettle();
      expect(_scrollOffset(tester), 0.0);

      // Press in the empty lane body while the offset is 0.
      final laneRect = tester.getRect(find.byType(ZoomLane));
      final downPos = Offset(laneRect.left + 120, laneRect.top + 6);
      final gesture = await tester.startGesture(
        downPos,
        kind: PointerDeviceKind.mouse,
      );
      await tester.pump();

      // While the finger is held STILL, playback advances and auto-follow
      // snaps the scroll — the content shifts out from under the finger.
      position.value = const Duration(milliseconds: 2500);
      await tester.pump();
      expect(_scrollOffset(tester), greaterThan(100.0),
          reason: 'auto-follow should have jumped the scroll mid-gesture');

      await gesture.up();
      await tester.pump();

      // The commit must use the pointer-DOWN offset (0), landing near the
      // press frame (~0.5s here). Had it used the post-snap offset (~460px at
      // pps=240) it would land ~1.9s later, around 2.4s. The exact ms depends
      // on host geometry, so assert the fix's frame vs the bug's frame by a
      // wide margin rather than a brittle exact value.
      expect(seeked, isNotNull);
      expect(seeked!.inMilliseconds, lessThan(1200),
          reason: 'seek used the pressed-frame offset, not the scrolled one');
      expect(seeked!.inMilliseconds, greaterThan(100),
          reason: 'and it still landed at the press position, not the origin');
    },
  );

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
