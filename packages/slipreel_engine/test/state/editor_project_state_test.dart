import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  group('EditorProjectState.copyWith', () {
    test('returns an identical instance when no overrides are passed', () {
      // Foundation for the Riverpod migration (P0-2): every inspector
      // edit will route through `controller.state = state.copyWith(...)`,
      // and a parameterless copyWith must round-trip every field so
      // identity-style equality checks downstream stay reliable.
      final original = EditorProjectState.defaults();
      final copy = original.copyWith();

      expect(copy.zoomRegions, equals(original.zoomRegions));
      expect(copy.screenAnimationConfig, equals(original.screenAnimationConfig));
      expect(copy.cursorAnimationConfig, equals(original.cursorAnimationConfig));
      expect(copy.cursorSize, equals(original.cursorSize));
      expect(copy.cursorStyle, equals(original.cursorStyle));
      expect(copy.cursorClickEffect, equals(original.cursorClickEffect));
      expect(copy.hideCursorOverlay, equals(original.hideCursorOverlay));
      expect(copy.motionBlur, equals(original.motionBlur));
      expect(copy.cursorMovementBlur, equals(original.cursorMovementBlur));
      expect(copy.screenMovementBlur, equals(original.screenMovementBlur));
      expect(copy.screenZoomBlur, equals(original.screenZoomBlur));
      expect(copy.cursorShadow, equals(original.cursorShadow));
      expect(copy.clickSpring, equals(original.clickSpring));
      expect(copy.cursorDelay, equals(original.cursorDelay));
      expect(copy.cursorPostProcess, equals(original.cursorPostProcess));
      expect(copy.windowFrame, equals(original.windowFrame));
      // removed: playbackSpeed/fadeIn/fadeOut moved to ClipSlice in v7
      // (asserted in clip_slice_test.dart + slice migration tests).
    });

    test('overrides each named field independently without touching others',
        () {
      final original = EditorProjectState.defaults();

      final cursorSizeChange = original.copyWith(cursorSize: 5.0);
      expect(cursorSizeChange.cursorSize, 5.0);
      expect(cursorSizeChange.motionBlur, equals(original.motionBlur));
      expect(cursorSizeChange.cursorStyle, equals(original.cursorStyle));

      final motionBlurChange = original.copyWith(motionBlur: 0.75);
      expect(motionBlurChange.motionBlur, 0.75);
      expect(motionBlurChange.cursorSize, equals(original.cursorSize));

      final hideChange = original.copyWith(hideCursorOverlay: true);
      expect(hideChange.hideCursorOverlay, isTrue);
      expect(hideChange.cursorSize, equals(original.cursorSize));

      final delayChange = original.copyWith(
        cursorDelay: const Duration(milliseconds: 120),
      );
      expect(delayChange.cursorDelay, const Duration(milliseconds: 120));
      expect(delayChange.motionBlur, equals(original.motionBlur));
    });

    test('zoomRegions override replaces the list, not appends', () {
      // The controller will replace, never append in-place; copyWith
      // must mirror that. Verify by passing a freshly-constructed list
      // and confirming the new state's reference *is* the passed list,
      // not a copy of the original's.
      final original = EditorProjectState.defaults();
      final fresh = <ZoomRegion>[
        ZoomRegion(
          rect: const Rect.fromLTWH(0, 0, 10, 10),
          startTime: const Duration(milliseconds: 100),
          duration: const Duration(seconds: 1),
          zoomLevel: 2.0,
        ),
      ];
      final patched = original.copyWith(zoomRegions: fresh);
      expect(patched.zoomRegions, hasLength(1));
      expect(identical(patched.zoomRegions, fresh), isTrue);
      expect(original.zoomRegions, isEmpty); // original untouched
    });

    test(
      'overrides may downgrade derived enums to a different value '
      '(cursorStyle, cursorClickEffect, clickSpring, cursorPostProcess)',
      () {
        final original = EditorProjectState.defaults();
        const tighterSpring = ClickSpring(stiffness: 800, damping: 20);
        final swapped = original.copyWith(
          cursorStyle: CursorStyle.classic,
          cursorClickEffect: CursorClickEffect.none,
          clickSpring: tighterSpring,
          cursorPostProcess: const CursorPostProcess(
            endFreezeMs: 200,
            removeShakes: true,
            optimizeChanges: true,
          ),
        );
        expect(swapped.cursorStyle, CursorStyle.classic);
        expect(swapped.cursorClickEffect, CursorClickEffect.none);
        expect(swapped.clickSpring, tighterSpring);
        expect(swapped.cursorPostProcess.endFreezeMs, 200);

        // Original is untouched (immutable copyWith).
        expect(original.cursorStyle, CursorStyle.modernDark);
        expect(original.cursorClickEffect, CursorClickEffect.ripple);
        expect(original.clickSpring, ClickSpring.snappy);
        expect(original.cursorPostProcess, CursorPostProcess.none);
      },
    );

    test('carries a Timeline and exposes zoomRegions getter shim', () {
      // P2-10: regions now live on timeline.zoomTracks.first.regions.
      // The zoomRegions getter is the shim for code that hasn't been
      // updated to walk the timeline — it returns the active track's
      // regions, matching today's single-track UI.
      final defaults = EditorProjectState.defaults();
      expect(defaults.timeline, isA<Timeline>());
      expect(defaults.timeline.zoomTracks, hasLength(1));
      expect(defaults.zoomRegions, isEmpty);

      final region = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 1, 1),
        startTime: Duration.zero,
        duration: const Duration(seconds: 1),
        zoomLevel: 2.0,
      );
      final next = defaults.copyWith(zoomRegions: [region]);
      expect(next.timeline.zoomTracks.first.regions, hasLength(1));
      expect(next.zoomRegions, hasLength(1));
      expect(next.zoomRegions.first.zoomLevel, 2.0);
    });

    test(
      'copyWith(zoomRegions:) on a zero-tracks timeline synthesizes a '
      'single track instead of dropping the regions',
      () {
        // Reachable from a corrupt sidecar (Timeline.fromJson({}) yields
        // zero tracks). copyWith must produce a valid timeline so the
        // first inspector edit after a partial load doesn't silently
        // lose the regions the user just placed.
        final state = EditorProjectState.defaults()
            .copyWith(timeline: const Timeline(zoomTracks: []));
        expect(state.timeline.zoomTracks, isEmpty);

        final region = ZoomRegion(
          rect: const Rect.fromLTWH(0, 0, 1, 1),
          startTime: Duration.zero,
          duration: const Duration(seconds: 1),
          zoomLevel: 1.6,
        );
        final next = state.copyWith(zoomRegions: [region]);

        expect(next.timeline.zoomTracks, hasLength(1),
            reason: 'a fresh track must be synthesized, not silently dropped');
        expect(next.zoomRegions, hasLength(1));
        expect(next.zoomRegions.first.zoomLevel, 1.6);
      },
    );

    test('copyWith(timeline:) replaces the whole timeline atomically', () {
      // Allows the controller to swap in a multi-track timeline once
      // captions/audio land, without round-tripping through zoomRegions.
      final original = EditorProjectState.defaults();
      final replacement = Timeline(zoomTracks: [
        ZoomTrack(regions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0, 0, 1, 1),
            startTime: Duration.zero,
            duration: const Duration(seconds: 2),
            zoomLevel: 1.7,
          ),
        ]),
      ]);
      final patched = original.copyWith(timeline: replacement);
      expect(identical(patched.timeline, replacement), isTrue);
      expect(patched.zoomRegions.first.zoomLevel, 1.7);
    });

    test('timeline round-trips through toJson/fromJson', () {
      final original = EditorProjectState.defaults().copyWith(zoomRegions: [
        ZoomRegion(
          rect: const Rect.fromLTWH(0.1, 0.1, 0.5, 0.5),
          startTime: const Duration(milliseconds: 250),
          duration: const Duration(seconds: 3),
          zoomLevel: 1.4,
        ),
      ]);
      final json = original.toJson();
      // v3 shape: timeline replaces top-level zoomRegions
      expect(json['timeline'], isA<Map<String, dynamic>>());
      expect(json.containsKey('zoomRegions'), isFalse);

      final restored = EditorProjectState.fromJson(json, videoDuration: const Duration(seconds: 60));
      expect(restored.zoomRegions, hasLength(1));
      expect(restored.zoomRegions.first.zoomLevel, 1.4);
    });

    test('animation configs swap atomically as a single unit', () {
      // CursorAnimationConfig has nested spring state — copyWith must
      // accept the new instance whole, not try to merge fields.
      final original = EditorProjectState.defaults();
      final next = original.copyWith(
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.rapid,
        ),
        screenAnimationConfig: const ScreenAnimationConfig.preset(
          ScreenAnimationStyle.focused,
        ),
      );
      expect(next.cursorAnimationConfig.preset, CursorAnimationStyle.rapid);
      expect(next.screenAnimationConfig.preset, ScreenAnimationStyle.focused);
    });
  });

  // removed: audioMix round-trip / default — audio fields moved to
  // ClipSlice in v7 (asserted in clip_slice_test.dart + slice migration
  // tests).

  test('a v3 sidecar (no audioMix) migrates forward to current', () {
    final v3 = {
      'schemaVersion': 3,
      'timeline': {'zoomTracks': [{'regions': <dynamic>[]}]},
    };
    final migrated = migrateEditorProjectJson(v3, videoDuration: const Duration(seconds: 60));
    expect(migrated['schemaVersion'], EditorProjectState.currentSchemaVersion);
    // Audio defaults are now asserted on the synthesized clip.
    EditorProjectState.fromJson(v3, videoDuration: const Duration(seconds: 60));
  });

  test('toJson advertises currentSchemaVersion', () {
    expect(EditorProjectState.defaults().toJson()['schemaVersion'],
        EditorProjectState.currentSchemaVersion);
  });

  group('outputAspect', () {
    test('defaults to OutputAspect.auto', () {
      final state = EditorProjectState.defaults();
      expect(state.outputAspect, OutputAspect.auto);
    });

    test('copyWith updates outputAspect', () {
      final base = EditorProjectState.defaults();
      final next = base.copyWith(outputAspect: OutputAspect.vertical9x16);
      expect(next.outputAspect, OutputAspect.vertical9x16);
      expect(base.outputAspect, OutputAspect.auto, reason: 'immutable');
    });

    test('JSON round-trip preserves outputAspect for every variant', () {
      for (final variant in OutputAspect.values) {
        final state = EditorProjectState.defaults().copyWith(outputAspect: variant);
        final decoded = EditorProjectState.fromJson(state.toJson(), videoDuration: const Duration(seconds: 60));
        expect(decoded.outputAspect, variant, reason: 'variant=$variant');
      }
    });

    test('JSON without outputAspect defaults to auto', () {
      final json = EditorProjectState.defaults().toJson();
      json.remove('outputAspect');
      final decoded = EditorProjectState.fromJson(json, videoDuration: const Duration(seconds: 60));
      expect(decoded.outputAspect, OutputAspect.auto);
    });

    test('v4 JSON (pre-outputAspect) migrates forward to current and defaults aspect', () {
      final v4Json = EditorProjectState.defaults().toJson()
        ..['schemaVersion'] = 4
        ..remove('outputAspect');
      final decoded = EditorProjectState.fromJson(v4Json, videoDuration: const Duration(seconds: 60));
      expect(decoded.outputAspect, OutputAspect.auto);
    });
  });

  group('timelineScale field', () {
    test('default is 1.0', () {
      expect(EditorProjectState.defaults().timelineScale, 1.0);
    });

    test('copyWith updates only timelineScale', () {
      final base = EditorProjectState.defaults();
      final next = base.copyWith(timelineScale: 4.0);
      expect(next.timelineScale, 4.0);
      expect(next.cursorSize, base.cursorSize);
    });

    test('round-trips through toJson/fromJson', () {
      final base = EditorProjectState.defaults().copyWith(timelineScale: 3.5);
      final decoded = EditorProjectState.fromJson(base.toJson(), videoDuration: const Duration(seconds: 60));
      expect(decoded.timelineScale, 3.5);
    });

    test('missing key in JSON falls back to 1.0', () {
      final json = EditorProjectState.defaults().toJson()
        ..remove('timelineScale');
      expect(EditorProjectState.fromJson(json, videoDuration: const Duration(seconds: 60)).timelineScale, 1.0);
    });

    test('invalid JSON values fall back to 1.0', () {
      final base = EditorProjectState.defaults().toJson();
      for (final bad in <Object?>[-1, 0, 100, 'foo', null, double.nan, double.infinity]) {
        final json = {...base, 'timelineScale': bad};
        expect(
          EditorProjectState.fromJson(json, videoDuration: const Duration(seconds: 60)).timelineScale,
          1.0,
          reason: 'bad input: $bad',
        );
      }
    });

    test('equality and hashCode include timelineScale', () {
      final a = EditorProjectState.defaults().copyWith(timelineScale: 2.0);
      final b = EditorProjectState.defaults().copyWith(timelineScale: 2.0);
      final c = EditorProjectState.defaults().copyWith(timelineScale: 3.0);
      expect(a == b, isTrue);
      expect(a.hashCode == b.hashCode, isTrue);
      expect(a == c, isFalse);
    });
  });

  group('pendingScaleAnchor field (transient)', () {
    test('defaults to null', () {
      expect(EditorProjectState.defaults().pendingScaleAnchor, isNull);
    });

    test('copyWith sets and clears via clearPendingScaleAnchor flag', () {
      final base = EditorProjectState.defaults();
      final withAnchor =
          base.copyWith(pendingScaleAnchor: const Duration(seconds: 3));
      expect(withAnchor.pendingScaleAnchor, const Duration(seconds: 3));
      final cleared = withAnchor.copyWith(clearPendingScaleAnchor: true);
      expect(cleared.pendingScaleAnchor, isNull);
    });

    test('NOT serialized to JSON', () {
      final state = EditorProjectState.defaults()
          .copyWith(pendingScaleAnchor: const Duration(seconds: 5));
      expect(state.toJson().containsKey('pendingScaleAnchor'), isFalse);
    });

    test('NOT read from JSON (always starts null after fromJson)', () {
      final base = EditorProjectState.defaults().toJson();
      final hostile = {...base, 'pendingScaleAnchor': 12345};
      expect(EditorProjectState.fromJson(hostile, videoDuration: const Duration(seconds: 60)).pendingScaleAnchor, isNull);
    });

    test('NOT included in equality or hashCode', () {
      final a = EditorProjectState.defaults()
          .copyWith(pendingScaleAnchor: const Duration(seconds: 1));
      final b = EditorProjectState.defaults()
          .copyWith(pendingScaleAnchor: const Duration(seconds: 9));
      final c = EditorProjectState.defaults();
      expect(a == b, isTrue, reason: 'anchor must not affect ==');
      expect(a == c, isTrue);
      expect(a.hashCode == c.hashCode, isTrue);
    });
  });
}
