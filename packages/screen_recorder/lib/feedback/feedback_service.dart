import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/utils/breadcrumbs.dart';

import '../analytics/analytics_event.dart';
import '../analytics/posthog_sink.dart';
import '../diagnostics/pii_scrubber.dart';

enum FeedbackType { idea, problem }

class FeedbackReport {
  const FeedbackReport({
    required this.type,
    required this.message,
    this.email,
    this.attachDiagnostics = false,
  });
  final FeedbackType type;
  final String message;
  final String? email;
  final bool attachDiagnostics;
}

/// Sends user-initiated feedback. Always-on: submitting is the consent, so this
/// is not gated by the analytics or diagnostics toggles. Offline-tolerant via
/// its own PostHogSink queue.
class FeedbackService {
  FeedbackService({
    required PostHogSink sink,
    required Breadcrumbs breadcrumbs,
    required PiiScrubber scrubber,
    required Map<String, Object?> meta,
    DateTime Function() now = DateTime.now,
  })  : _sink = sink,
        _breadcrumbs = breadcrumbs,
        _scrubber = scrubber,
        _meta = meta,
        _now = now;

  final PostHogSink _sink;
  final Breadcrumbs _breadcrumbs;
  final PiiScrubber _scrubber;
  final Map<String, Object?> _meta;
  final DateTime Function() _now;

  Future<void> load() => _sink.load();

  Future<void> submit(FeedbackReport report) async {
    _sink.enqueue(PostHogEvent(
      name: 'feedback_submitted',
      timestamp: _now(),
      properties: {
        ..._meta,
        'type': report.type.name,
        'message': _scrubber.scrub(report.message),
        if (report.email != null && report.email!.isNotEmpty) 'email': report.email,
        if (report.attachDiagnostics)
          'breadcrumbs': _scrubber.scrubAll(_breadcrumbs.snapshot()),
      },
    ));
    await _sink.flush();
  }

  void setDistinctId(String id) => _sink.setDistinctId(id);

  Future<void> flush() => _sink.flush();

  Future<void> dispose() => _sink.dispose();
}

final feedbackServiceProvider = Provider<FeedbackService>(
  (ref) => throw UnimplementedError('Override feedbackServiceProvider in main()'),
);
