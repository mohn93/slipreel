import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/licensing/license_store.dart';
import 'package:screen_recorder/licensing/trial_exports.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/utils/perf_summary.dart';
import 'package:screen_recorder/ui/screens/playback/export_controller.dart';
import 'package:screen_recorder/services/destination_handlers.dart';

ExportPerfSummary _summary({List<String> warnings = const []}) =>
    ExportPerfSummary(
      inputDurationSeconds: 1,
      wallTimeSeconds: 1,
      decodeMsPerFrame: 1,
      compositeMsPerFrame: 1,
      encodeMsPerFrame: 1,
      outputBytes: 100,
      outputCodec: 'h264',
      usedHardwareEncoder: true,
      warnings: warnings,
    );

class _FakeHandler implements DestinationHandler {
  @override
  Future<String?> resolveOutputPath({required String suggestedFileName}) async =>
      '/tmp/out.mp4';
  @override
  Future<DestinationResult> deliver(String outputPath) async =>
      const DestinationResult(message: 'Saved', revealPath: '/tmp/out.mp4');
}

/// Resolves a path fine but throws during delivery — models the clipboard/link
/// handlers' real I/O failing after a successful encode.
class _ThrowingHandler implements DestinationHandler {
  @override
  Future<String?> resolveOutputPath({required String suggestedFileName}) async =>
      '/tmp/out.mp4';
  @override
  Future<DestinationResult> deliver(String outputPath) async =>
      throw Exception('deliver boom');
}

void main() {
  test('trial delivery spends three slots, then blocks the pipeline; paid bypasses quota', () async {
    final trial = TrialExports(InMemorySecureKV());
    var paid = false;
    var calls = 0;
    final c = ExportController(
      trialExports: trial,
      isExportEntitled: () => paid,
      runPipeline: ({required onProgress, required cancelToken}) async {
        calls++;
        return _summary();
      },
    );
    for (var i = 0; i < 3; i++) {
      expect(await c.run(outputPath: '/tmp/out.mp4', handler: _FakeHandler(), onProgress: (_) {}), isA<ExportSuccess>());
    }
    expect(await c.run(outputPath: '/tmp/out.mp4', handler: _FakeHandler(), onProgress: (_) {}), isA<ExportNotEntitled>());
    expect(calls, 3);
    paid = true;
    expect(await c.run(outputPath: '/tmp/out.mp4', handler: _FakeHandler(), onProgress: (_) {}), isA<ExportSuccess>());
    expect(await trial.remaining, 0);
  });
  test('trial is refunded after delivery failure or pipeline cancellation', () async {
    final trial = TrialExports(InMemorySecureKV());
    for (final cancel in [false, true]) {
      final c = ExportController(
        trialExports: trial,
        isExportEntitled: () => false,
        runPipeline: ({required onProgress, required cancelToken}) async {
          if (cancel) throw const ExportCancelledException();
          return _summary();
        },
      );
      final outcome = await c.run(outputPath: '/tmp/out.mp4', handler: _ThrowingHandler(), onProgress: (_) {});
      expect(outcome, cancel ? isA<ExportCancelled>() : isA<ExportFailure>());
      expect(await trial.remaining, 3);
    }
  });

  test('run reports progress, delivers, returns success', () async {
    final progress = <double>[];
    final c = ExportController(
      isExportEntitled: () => true,
      runPipeline: ({required onProgress, required cancelToken}) async {
        onProgress(0.5);
        onProgress(1.0);
        return _summary();
      },
    );
    final outcome = await c.run(
      outputPath: '/tmp/out.mp4',
      handler: _FakeHandler(),
      onProgress: progress.add,
    );
    expect(progress, [0.5, 1.0]);
    expect(outcome, isA<ExportSuccess>());
    expect((outcome as ExportSuccess).result.message, 'Saved');
  });

  test('run returns failure when delivery throws (pipeline succeeded)',
      () async {
    final c = ExportController(
      isExportEntitled: () => true,
      runPipeline: ({required onProgress, required cancelToken}) async {
        onProgress(1.0);
        return _summary();
      },
    );
    final outcome = await c.run(
      outputPath: '/tmp/out.mp4',
      handler: _ThrowingHandler(),
      onProgress: (_) {},
    );
    expect(outcome, isA<ExportFailure>());
  });

  test('run returns failure when the pipeline throws', () async {
    final c = ExportController(
      isExportEntitled: () => true,
      runPipeline: ({required onProgress, required cancelToken}) async {
        throw Exception('boom');
      },
    );
    final outcome = await c.run(
      outputPath: '/tmp/out.mp4',
      handler: _FakeHandler(),
      onProgress: (_) {},
    );
    expect(outcome, isA<ExportFailure>());
  });

  test('run returns cancelled on ExportCancelledException', () async {
    final c = ExportController(
      isExportEntitled: () => true,
      runPipeline: ({required onProgress, required cancelToken}) async {
        throw const ExportCancelledException();
      },
    );
    final outcome = await c.run(
      outputPath: '/tmp/out.mp4',
      handler: _FakeHandler(),
      onProgress: (_) {},
    );
    expect(outcome, isA<ExportCancelled>());
  });

  test('surfaceExportWarnings forwards each warning to the sink', () {
    final shown = <String>[];
    surfaceExportWarnings(
      _summary(warnings: const ['Camera could not be decoded.']),
      shown.add,
    );
    expect(shown, ['Camera could not be decoded.']);
  });

  test('surfaceExportWarnings shows nothing when there are no warnings', () {
    final shown = <String>[];
    surfaceExportWarnings(_summary(), shown.add);
    expect(shown, isEmpty);
  });
}
