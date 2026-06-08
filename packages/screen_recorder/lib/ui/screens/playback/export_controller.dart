import 'package:slipreel_engine/export/export_cancellation.dart';
import 'package:slipreel_engine/utils/app_logger.dart';
import 'package:slipreel_engine/utils/perf_summary.dart';

import '../../../services/destination_handlers.dart';

/// Headless outcome of an export run. The widget maps these to UI.
sealed class ExportOutcome {
  const ExportOutcome();
}

class ExportSuccess extends ExportOutcome {
  const ExportSuccess(this.summary, this.result);
  final ExportPerfSummary summary;
  final DestinationResult result;
}

class ExportFailure extends ExportOutcome {
  const ExportFailure(this.error);
  final Object error;
}

class ExportCancelled extends ExportOutcome {
  const ExportCancelled();
}

/// Signature for running the chosen export pipeline. Injected so the widget
/// passes a closure that builds the right `ExportPipeline`/`GifExportPipeline`
/// and the test passes a fake.
typedef RunPipeline = Future<ExportPerfSummary> Function({
  required void Function(double progress) onProgress,
  required CancelToken cancelToken,
});

/// Runs an export pipeline and delivers the output, returning a typed outcome.
/// Contains NO UI — dialogs/snackbars stay in the widget.
class ExportController {
  ExportController({required this.runPipeline});

  final RunPipeline runPipeline;
  final CancelToken cancelToken = CancelToken();

  /// Runs the pipeline (reporting progress), then delivers via [handler].
  /// Returns [ExportSuccess], [ExportFailure], or [ExportCancelled].
  Future<ExportOutcome> run({
    required String outputPath,
    required DestinationHandler handler,
    required void Function(double progress) onProgress,
  }) async {
    try {
      final summary = await runPipeline(
        onProgress: onProgress,
        cancelToken: cancelToken,
      );
      final result = await handler.deliver(outputPath);
      return ExportSuccess(summary, result);
    } on ExportCancelledException {
      return const ExportCancelled();
    } catch (e, stackTrace) {
      // Broad catch is intentional: ffmpeg/codec/IO errors (from the pipeline
      // and handler.deliver) are varied and Object-typed, so we funnel them all
      // into ExportFailure for uniform UI handling. Logging the error + stack
      // here preserves diagnosability so genuine bugs (TypeError, etc.) aren't
      // silently downgraded to a plain "Export failed" message with no trace.
      AppLogger.ffmpeg.e('Export run failed', error: e, stackTrace: stackTrace);
      return ExportFailure(e);
    }
  }

  void cancel() => cancelToken.cancel();
}

/// Forwards each export warning (e.g. the camera failed to decode so the
/// export finished without the camera overlay) to [show]. Kept separate from
/// the UI so it's unit-testable without an AppAlerts overlay; callers pass
/// `AppAlerts.warning`.
void surfaceExportWarnings(
    ExportPerfSummary summary, void Function(String) show) {
  for (final w in summary.warnings) {
    show(w);
  }
}
