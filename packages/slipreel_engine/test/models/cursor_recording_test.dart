import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('CursorRecording', () {
    test('should store and retrieve cursor positions', () {
      final recording = CursorRecording();

      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 0));
      recording.addPosition(
        CursorPosition(x: 100, y: 100, timestampMicros: 1000),
      );

      expect(recording.count, 2);
    });

    test('should interpolate position between two points', () {
      final recording = CursorRecording();

      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 0));
      recording.addPosition(
        CursorPosition(x: 100, y: 100, timestampMicros: 1000),
      );

      final pos = recording.getPositionAt(500);

      expect(pos, isNotNull);
      expect(pos!.x, closeTo(50, 0.1));
      expect(pos.y, closeTo(50, 0.1));
    });

    test('should return null for empty recording', () {
      final recording = CursorRecording();

      final pos = recording.getPositionAt(500);

      expect(pos, isNull);
    });

    test('should save and load from file', () async {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));
      recording.addPosition(CursorPosition(x: 30, y: 40, timestampMicros: 200));

      final tempFile = File('test_cursor.json');
      await recording.saveToFile(tempFile.path);

      final loaded = await CursorRecording.loadFromFile(tempFile.path);

      expect(loaded.count, 2);
      expect(loaded.positions[0].x, 10);
      expect(loaded.positions[1].y, 40);
      expect(
        loaded.version,
        1,
        reason: 'bulk load should publish one logical mutation revision',
      );

      await tempFile.delete();
    });

    test('saves and loads cursor state alongside position', () async {
      // End-to-end check that the new state field survives a full
      // recording → save → load cycle. Without this the painter
      // would see arrow on every frame even after the schema change.
      final recording = CursorRecording();
      recording.addPosition(
        CursorPosition(
          x: 0,
          y: 0,
          timestampMicros: 0,
          state: CursorState.iBeam,
        ),
      );
      recording.addPosition(
        CursorPosition(
          x: 1,
          y: 1,
          timestampMicros: 100,
          state: CursorState.pointingHand,
        ),
      );

      final tempFile = File(
        'test_cursor_state_${DateTime.now().microsecondsSinceEpoch}.json',
      );
      try {
        await recording.saveToFile(tempFile.path);
        final loaded = await CursorRecording.loadFromFile(tempFile.path);
        expect(loaded.count, 2);
        expect(loaded.positions[0].state, CursorState.iBeam);
        expect(loaded.positions[1].state, CursorState.pointingHand);
      } finally {
        if (await tempFile.exists()) await tempFile.delete();
      }
    });

    test(
      'loadFromFile defaults missing state to arrow (legacy recordings)',
      () async {
        // Legacy files predate the state field; their JSON has no
        // 'state' key. Loading must succeed and pick arrow as default
        // — anything else would silently corrupt how old clips render.
        final tempFile = File(
          'test_cursor_legacy_${DateTime.now().microsecondsSinceEpoch}.json',
        );
        try {
          await tempFile.writeAsString(
            '[{"x": 5.0, "y": 6.0, "timestampMicros": 0, "isClicked": false}]',
          );
          final loaded = await CursorRecording.loadFromFile(tempFile.path);
          expect(loaded.count, 1);
          expect(loaded.positions[0].state, CursorState.arrow);
        } finally {
          if (await tempFile.exists()) await tempFile.delete();
        }
      },
    );

    test('should handle division by zero when timestamps are equal', () {
      final recording = CursorRecording();

      // Add two positions with the same timestamp
      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 100));
      recording.addPosition(
        CursorPosition(x: 100, y: 100, timestampMicros: 100),
      );

      // Should not crash and return one of the positions
      final pos = recording.getPositionAt(100);

      expect(pos, isNotNull);
      expect(pos!.timestampMicros, 100);
    });

    test('should throw error when loading non-existent file', () async {
      expect(
        () => CursorRecording.loadFromFile('non_existent_file.json'),
        throwsA(isA<Exception>()),
      );
    });

    test('should throw error when saving to invalid path', () async {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));

      expect(
        () =>
            recording.saveToFile('/invalid/path/that/does/not/exist/file.json'),
        throwsA(isA<Exception>()),
      );
    });

    test('positions list should be unmodifiable', () {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));

      final positions = recording.positions;

      // Attempting to modify the list should throw
      expect(
        () => positions.add(CursorPosition(x: 30, y: 40, timestampMicros: 200)),
        throwsUnsupportedError,
      );
    });

    test('positions snapshot is reused until the recording mutates', () {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));

      final first = recording.positions;
      expect(identical(recording.positions, first), isTrue);

      recording.addPosition(CursorPosition(x: 30, y: 40, timestampMicros: 200));
      final second = recording.positions;
      expect(identical(second, first), isFalse);
      expect(second, hasLength(2));
      expect(first, hasLength(1), reason: 'published snapshots stay immutable');

      recording.clear();
      expect(recording.positions, isEmpty);
    });

    test('binary search should work with large dataset', () {
      final recording = CursorRecording();

      // Add 1000 positions
      for (int i = 0; i < 1000; i++) {
        recording.addPosition(
          CursorPosition(
            x: i.toDouble(),
            y: i.toDouble(),
            timestampMicros: i * 1000,
          ),
        );
      }

      // Test exact match
      final exact = recording.getPositionAt(500000);
      expect(exact, isNotNull);
      expect(exact!.x, 500);

      // Test interpolation
      final interpolated = recording.getPositionAt(500500);
      expect(interpolated, isNotNull);
      expect(interpolated!.x, closeTo(500.5, 0.1));
    });

    group('loadFromFile timestamp handling', () {
      // The native plugin started writing video-relative microseconds
      // (small values, typically <60s) for new recordings. Legacy files
      // captured before that change stored mach_absolute_time (billions
      // of micros since boot). loadFromFile must rebase the legacy form
      // and leave the modern form alone — rebasing modern timestamps
      // shifts the cursor track forward by the SCStream warmup gap and
      // misaligns the cursor-follow zoom focal with the burned-in
      // sprite.
      late File tempFile;

      setUp(() {
        tempFile = File(
          'test_cursor_${DateTime.now().microsecondsSinceEpoch}.json',
        );
      });

      tearDown(() async {
        if (await tempFile.exists()) {
          await tempFile.delete();
        }
      });

      test('preserves video-relative timestamps when first sample is small '
          '(modern recording)', () async {
        // First sample at 311ms — exactly the SCStream warmup gap shape
        // we observed in production. Must not be shifted to 0.
        final original = CursorRecording();
        original.addPosition(
          CursorPosition(x: 1, y: 1, timestampMicros: 311035),
        );
        original.addPosition(
          CursorPosition(x: 2, y: 2, timestampMicros: 327000),
        );
        original.addPosition(
          CursorPosition(x: 3, y: 3, timestampMicros: 5360329),
        );
        await original.saveToFile(tempFile.path);

        final loaded = await CursorRecording.loadFromFile(tempFile.path);

        expect(loaded.count, 3);
        expect(
          loaded.positions[0].timestampMicros,
          311035,
          reason:
              'first sample must keep its video-relative timestamp; '
              'rebasing to 0 destructively shifts the rest of the track '
              'forward by the warmup gap',
        );
        expect(loaded.positions[1].timestampMicros, 327000);
        expect(loaded.positions[2].timestampMicros, 5360329);
      });

      test('rebases mach_absolute_time timestamps when first sample is '
          'huge (legacy recording)', () async {
        // Legacy files had timestamps in the trillions (mach time since
        // boot). Without rebasing, every editor lookup would clamp to
        // the first sample because the play queries are in the
        // 0-based domain.
        const machBase = 1234567890123;
        final original = CursorRecording();
        original.addPosition(
          CursorPosition(x: 1, y: 1, timestampMicros: machBase),
        );
        original.addPosition(
          CursorPosition(x: 2, y: 2, timestampMicros: machBase + 16000),
        );
        original.addPosition(
          CursorPosition(x: 3, y: 3, timestampMicros: machBase + 5000000),
        );
        await original.saveToFile(tempFile.path);

        final loaded = await CursorRecording.loadFromFile(tempFile.path);

        expect(loaded.count, 3);
        expect(
          loaded.positions[0].timestampMicros,
          0,
          reason:
              'legacy mach timestamps must rebase so editor '
              'lookups in the 0-based video-time domain hit them',
        );
        expect(loaded.positions[1].timestampMicros, 16000);
        expect(loaded.positions[2].timestampMicros, 5000000);
      });

      test('detects format by first-sample threshold (60 seconds)', () async {
        // Just under 60s of micros is treated as video-relative;
        // just over is treated as legacy and rebased.
        const justUnder = 59 * 1000 * 1000;
        const justOver = 61 * 1000 * 1000;

        final modern = CursorRecording();
        modern.addPosition(
          CursorPosition(x: 1, y: 1, timestampMicros: justUnder),
        );
        modern.addPosition(
          CursorPosition(x: 2, y: 2, timestampMicros: justUnder + 16000),
        );
        await modern.saveToFile(tempFile.path);
        final loadedModern = await CursorRecording.loadFromFile(tempFile.path);
        expect(
          loadedModern.positions[0].timestampMicros,
          justUnder,
          reason: '59s first sample is plausible video-relative time',
        );

        final legacy = CursorRecording();
        legacy.addPosition(
          CursorPosition(x: 1, y: 1, timestampMicros: justOver),
        );
        legacy.addPosition(
          CursorPosition(x: 2, y: 2, timestampMicros: justOver + 16000),
        );
        await legacy.saveToFile(tempFile.path);
        final loadedLegacy = await CursorRecording.loadFromFile(tempFile.path);
        expect(
          loadedLegacy.positions[0].timestampMicros,
          0,
          reason:
              '61s first sample is implausible for a single clip; '
              'treat as legacy and rebase',
        );
        expect(loadedLegacy.positions[1].timestampMicros, 16000);
      });
    });

    group('chronological ingestion', () {
      // getPositionAt and the event index binary-search over the sample
      // list assuming ascending timestamps, but nothing enforced it at
      // ingestion — an out-of-order sidecar (hand-edited, or a capture
      // hiccup) silently broke every lookup after the inversion.
      // addPosition must keep the list sorted.
      CursorPosition p(int ms, double x) =>
          CursorPosition(x: x, y: 0, timestampMicros: ms * 1000);

      test('out-of-order addPosition keeps samples sorted', () {
        final rec = CursorRecording();
        rec.addPosition(p(0, 0));
        rec.addPosition(p(100, 100));
        rec.addPosition(p(50, 50)); // late arrival
        final ts = rec.positions.map((s) => s.timestampMicros).toList();
        expect(ts, [0, 50000, 100000]);
      });

      test('lookups after an out-of-order append stay correct', () {
        final rec = CursorRecording();
        rec.addPosition(p(0, 0));
        rec.addPosition(p(100, 100));
        rec.addPosition(p(50, 50));
        // 75ms sits between the 50ms and 100ms samples: linear
        // interpolation must give x = 75. With the inversion unsorted,
        // the binary search lands in the wrong bracket.
        final at = rec.getPositionAt(75 * 1000);
        expect(at, isNotNull);
        expect(at!.x, closeTo(75, 0.001));
      });

      test('in-order appends stay O(1) fast path (no reorder)', () {
        final rec = CursorRecording();
        for (var i = 0; i < 5; i++) {
          rec.addPosition(p(i * 16, i.toDouble()));
        }
        final ts = rec.positions.map((s) => s.timestampMicros).toList();
        expect(ts, [0, 16000, 32000, 48000, 64000]);
      });
    });
  });
}
