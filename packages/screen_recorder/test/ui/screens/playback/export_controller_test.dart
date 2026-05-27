import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/utils/perf_summary.dart';
import 'package:screen_recorder/ui/screens/playback/export_controller.dart';
import 'package:screen_recorder/services/destination_handlers.dart';

ExportPerfSummary _summary() => const ExportPerfSummary(
      inputDurationSeconds: 1,
      wallTimeSeconds: 1,
      decodeMsPerFrame: 1,
      compositeMsPerFrame: 1,
      encodeMsPerFrame: 1,
      outputBytes: 100,
      outputCodec: 'h264',
      usedHardwareEncoder: true,
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
  test('run reports progress, delivers, returns success', () async {
    final progress = <double>[];
    final c = ExportController(
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
}
