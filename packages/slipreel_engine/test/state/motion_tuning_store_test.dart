@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/state/motion_tuning_store.dart';

/// Returns a temp file path unique to this test invocation so the
/// store's load/save round-trip doesn't collide between cases.
String _tempPath(String suffix) {
  final dir = Directory.systemTemp.createTempSync('motion_tuning_store_');
  // The directory is leaked intentionally — flutter_test's harness
  // cleans up via process exit and per-test isolation is more
  // important than tidiness here.
  return '${dir.path}/$suffix';
}

void main() {
  group('MotionTuningStore', () {
    test('load() returns null when the file does not exist', () async {
      final store = MotionTuningStore(path: _tempPath('missing.json'));
      expect(await store.load(), isNull);
    });

    test('save() then load() round-trips an arbitrary tuning', () async {
      final store = MotionTuningStore(path: _tempPath('roundtrip.json'));
      const custom = MotionTuning(
        cursorAtRestPxPerSec: 65,
        cursorFeedforwardStrength: 0.75,
        sceneBlurExposureMs: 20,
      );

      await store.save(custom);
      final loaded = await store.load();

      expect(loaded, isNotNull);
      expect(loaded!.cursorAtRestPxPerSec, 65);
      expect(loaded.cursorFeedforwardStrength, 0.75);
      expect(loaded.sceneBlurExposureMs, 20);
    });

    test('load migrates an unversioned legacy scene calibration', () async {
      final path = _tempPath('legacy.json');
      await File(path).writeAsString(
        '{"cursorAtRestPxPerSec":60,'
        '"sceneBlurExposureMs":16,"sceneBlurMaxTranslation":60}',
      );
      final loaded = await MotionTuningStore(path: path).load();

      expect(loaded, isNotNull);
      expect(loaded!.cursorAtRestPxPerSec, 60);
      expect(loaded.sceneBlurExposureMs, 32);
      expect(loaded.sceneBlurMaxTranslation, 64);
      expect(loaded.sceneBlurSampleCount, 21);
    });

    test(
      'load() returns null on corrupt JSON (silently — does not throw)',
      () async {
        final path = _tempPath('corrupt.json');
        await File(path).writeAsString('{not valid json');
        final store = MotionTuningStore(path: path);
        expect(await store.load(), isNull);
      },
    );

    test('save() is atomic — write to tmp + rename, so a partial write '
        'can not leave the file in an unreadable state', () async {
      final path = _tempPath('atomic.json');
      final store = MotionTuningStore(path: path);
      await store.save(MotionTuning.snappy);

      // The tmp file should NOT linger after a successful save.
      expect(await File('$path.tmp').exists(), isFalse);
      expect(await File(path).exists(), isTrue);
    });
  });
}
