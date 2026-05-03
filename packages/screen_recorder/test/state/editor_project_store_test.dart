import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/rendering/cursor_click_effect.dart';
import 'package:screen_recorder/rendering/cursor_glyph.dart';
import 'package:screen_recorder/state/editor_project_state.dart';
import 'package:screen_recorder/state/editor_project_store.dart';

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
      final state = EditorProjectState(
        zoomRegions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0, 0, 100, 100),
            startTime: const Duration(seconds: 1),
            duration: const Duration(seconds: 2),
            zoomLevel: 2.5,
            followMode: FollowMode.predictive,
            predictiveWindow: const Duration(milliseconds: 1200),
            followCurve:
                const CubicBezierCurve(x1: 0.2, y1: 0.0, x2: 0.8, y2: 1.0),
          ),
        ],
        screenAnimationConfig:
            ScreenAnimationConfig.custom(
          curve:
              const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
          badgeDuration: const Duration(milliseconds: 420),
        ),
        cursorAnimationConfig:
            const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
        cursorSize: 1.75,
        cursorStyle: CursorStyle.bold,
        cursorClickEffect: CursorClickEffect.none,
        hideCursorOverlay: true,
        motionBlur: 0.4,
      );

      final json = state.toJson();
      final restored = EditorProjectState.fromJson(json);

      expect(restored.zoomRegions, state.zoomRegions);
      expect(restored.cursorSize, 1.75);
      expect(restored.cursorStyle, CursorStyle.bold);
      expect(restored.cursorClickEffect, CursorClickEffect.none);
      expect(restored.hideCursorOverlay, isTrue);
      expect(restored.motionBlur, closeTo(0.4, 1e-9));
    });

    test('refuses to load a future schemaVersion', () {
      final state = EditorProjectState.defaults();
      final json = state.toJson();
      json['schemaVersion'] =
          EditorProjectState.currentSchemaVersion + 1;

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
      expect(state.cursorSize, 1.0);
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
      File(EditorProjectStore(videoPath: videoPath).sidecarPath)
          .writeAsStringSync('not json {{{');
      final store = EditorProjectStore(videoPath: videoPath);
      final state = await store.load();
      expect(state.zoomRegions, isEmpty);
    });

    test('rapid concurrent saves serialize and the last one wins',
        () async {
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
  EditorProjectState copyAsZoomedExample() => EditorProjectState(
        zoomRegions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(0, 0, 50, 50),
            startTime: const Duration(milliseconds: 100),
            duration: const Duration(seconds: 1),
            zoomLevel: 3.0,
          ),
        ],
        screenAnimationConfig: screenAnimationConfig,
        cursorAnimationConfig: cursorAnimationConfig,
        cursorSize: 2.0,
        cursorStyle: cursorStyle,
        cursorClickEffect: cursorClickEffect,
        hideCursorOverlay: hideCursorOverlay,
        motionBlur: motionBlur,
      );

  EditorProjectState copyWithCursorSize(double size) => EditorProjectState(
        zoomRegions: zoomRegions,
        screenAnimationConfig: screenAnimationConfig,
        cursorAnimationConfig: cursorAnimationConfig,
        cursorSize: size,
        cursorStyle: cursorStyle,
        cursorClickEffect: cursorClickEffect,
        hideCursorOverlay: hideCursorOverlay,
        motionBlur: motionBlur,
      );
}
