import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/services/destination_handlers.dart';
import 'package:screen_recorder/ui/screens/playback/export_controller.dart';
import 'package:slipreel_engine/export/export_cancellation.dart';

/// Minimal fake — the entitlement guard must return before `handler` is
/// ever touched, so both methods throw if invoked.
class _UnusedHandler implements DestinationHandler {
  @override
  Future<String?> resolveOutputPath({required String suggestedFileName}) {
    throw StateError('handler must not be used when unentitled');
  }

  @override
  Future<DestinationResult> deliver(String outputPath) {
    throw StateError('handler must not be used when unentitled');
  }
}

void main() {
  test('run returns ExportNotEntitled without invoking the pipeline', () async {
    var pipelineCalled = false;
    final controller = ExportController(
      isExportEntitled: () => false,
      runPipeline: ({
        required void Function(double progress) onProgress,
        required CancelToken cancelToken,
      }) async {
        pipelineCalled = true;
        throw StateError('pipeline must not run when unentitled');
      },
    );

    final outcome = await controller.run(
      outputPath: '/tmp/out.mp4',
      handler: _UnusedHandler(),
      onProgress: (_) {},
    );

    expect(outcome, isA<ExportNotEntitled>());
    expect(pipelineCalled, isFalse);
  });
}
