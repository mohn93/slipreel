import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/animation_curve.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';

void main() {
  late Directory tmp;
  late String videoPath;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('editor_project_store_test');
    videoPath = '${tmp.path}/clip.mp4';
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('EditorProjectState JSON', () {
    test('full roundtrip preserves all fields', () {
      final state = EditorProjectState.defaults().copyWith(
        zoomRegions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0, 0, 100, 100),
            startTime: const Duration(seconds: 1),
            duration: const Duration(seconds: 2),
            zoomLevel: 2.5,
            followMode: FollowMode.predictive,
            predictiveWindow: const Duration(milliseconds: 1200),
          ),
        ],
        screenAnimationConfig: ScreenAnimationConfig.custom(
          curve: const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
          badgeDuration: const Duration(milliseconds: 420),
        ),
        cursorAnimationConfig: const CursorAnimationConfig.preset(
          CursorAnimationStyle.rapid,
        ),
        cursorSize: 1.75,
        cursorStyle: CursorStyle.bold,
        cursorClickEffect: CursorClickEffect.none,
        hideCursorOverlay: true,
        // Values stay within the recalibrated caps (master 0–0.5,
        // channels 0–1.0). The fromJson path clamps anything past
        // these to the cap — see the legacy-clamp test further down.
        motionBlur: 0.4,
        cursorMovementBlur: 0.7,
        screenMovementBlur: 0.85,
        screenZoomBlur: 0.95,
        cursorShadow: 0.65,
        clickSpring: const ClickSpring(stiffness: 420, damping: 0.7),
        cursorDelay: const Duration(milliseconds: 120),
        windowFrame: WindowFrame.modern(),
      );

      final json = state.toJson();
      final restored = EditorProjectState.fromJson(json);

      expect(restored.zoomRegions, state.zoomRegions);
      expect(restored.cursorSize, 1.75);
      expect(restored.cursorStyle, CursorStyle.bold);
      expect(restored.cursorShadow, 0.65);
      expect(restored.cursorClickEffect, CursorClickEffect.none);
      expect(restored.hideCursorOverlay, isTrue);
      expect(restored.motionBlur, closeTo(0.4, 1e-9));
      expect(restored.cursorMovementBlur, closeTo(0.7, 1e-9));
      expect(restored.screenMovementBlur, closeTo(0.85, 1e-9));
      expect(restored.screenZoomBlur, closeTo(0.95, 1e-9));
      expect(restored.clickSpring.stiffness, closeTo(420, 1e-9));
      expect(restored.clickSpring.damping, closeTo(0.7, 1e-9));
      expect(restored.cursorDelay, const Duration(milliseconds: 120));
      expect(restored.windowFrame, WindowFrame.modern());
    });

    test('legacy JSON without cursorDelayMicros falls back to the default', () {
      // Recordings saved before the cursor-delay knob landed must
      // continue to load — the new field reads as the default 50 ms.
      final json = EditorProjectState.defaults().toJson();
      json.remove('cursorDelayMicros');
      final restored = EditorProjectState.fromJson(json);
      expect(restored.cursorDelay, EditorProjectState.defaults().cursorDelay);
    });

    test('legacy motion-blur values past the new caps are clamped', () {
      // Recordings saved before the motion-blur ranges were rescaled
      // (master 0–2 → 0–0.5, channels 0–2 → 0–1) might serialize
      // values past the new caps. fromJson must clamp so the smear
      // doesn't blow out and the sliders don't reject the value.
      final json = EditorProjectState.defaults().toJson();
      json['motionBlur'] = 1.8;
      json['cursorMovementBlur'] = 1.95;
      json['screenMovementBlur'] = 1.5;
      json['screenZoomBlur'] = 2.0;
      final restored = EditorProjectState.fromJson(json);
      expect(restored.motionBlur, closeTo(0.5, 1e-9));
      expect(restored.cursorMovementBlur, closeTo(1.0, 1e-9));
      expect(restored.screenMovementBlur, closeTo(1.0, 1e-9));
      expect(restored.screenZoomBlur, closeTo(1.0, 1e-9));
    });

    test('refuses to load a future schemaVersion', () {
      final state = EditorProjectState.defaults();
      final json = state.toJson();
      json['schemaVersion'] = EditorProjectState.currentSchemaVersion + 1;

      expect(
        () => EditorProjectState.fromJson(json),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('EditorProjectStore', () {
    test('load returns defaults when the sidecar is missing', () async {
      final store = EditorProjectStore(videoPath: videoPath);
      final state = await store.load();
      expect(state.zoomRegions, isEmpty);
      expect(state.cursorSize, 2.0);
      expect(state.cursorStyle, CursorStyle.modernDark);
    });

    test('save then load preserves edits', () async {
      final store = EditorProjectStore(videoPath: videoPath);
      final state = EditorProjectState.defaults().copyAsZoomedExample();

      await store.save(state);
      expect(File(store.sidecarPath).existsSync(), isTrue);

      final restored = await store.load();
      expect(restored.zoomRegions.length, 1);
      expect(restored.zoomRegions.first.zoomLevel, 3.0);
      expect(restored.cursorSize, 2.0);
    });

    test('load returns defaults on a corrupt file', () async {
      // Garbage in → defaults out (the editor doesn't have anything
      // useful to do with a half-written sidecar; better to start
      // fresh than crash on launch).
      File(
        EditorProjectStore(videoPath: videoPath).sidecarPath,
      ).writeAsStringSync('not json {{{');
      final store = EditorProjectStore(videoPath: videoPath);
      final state = await store.load();
      expect(state.zoomRegions, isEmpty);
    });

    test('rapid concurrent saves serialize and the last one wins', () async {
      // Mutation queue guarantees ordering. Without it two saves
      // racing on rename() can produce mixed file content or fail
      // outright on some filesystems.
      final store = EditorProjectStore(videoPath: videoPath);
      final base = EditorProjectState.defaults();

      // Fire 10 saves with monotonically increasing cursorSize. The
      // final on-disk value must match the last one fired.
      final futures = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        futures.add(store.save(base.copyWithCursorSize(1.0 + i * 0.1)));
      }
      await Future.wait(futures);

      final loaded = await store.load();
      expect(loaded.cursorSize, closeTo(1.0 + 9 * 0.1, 1e-9));
    });
  });
}

extension on EditorProjectState {
  EditorProjectState copyAsZoomedExample() => copyWith(
        zoomRegions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0, 0, 50, 50),
            startTime: const Duration(milliseconds: 100),
            duration: const Duration(seconds: 1),
            zoomLevel: 3.0,
          ),
        ],
        cursorSize: 2.0,
      );

  EditorProjectState copyWithCursorSize(double size) =>
      copyWith(cursorSize: size);
}
