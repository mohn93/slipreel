import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'recording_state.dart';

enum ThresholdAction { toast30, toast60, modal90, hardStop }

class LongRecordingWatcher {
  LongRecordingWatcher({
    required ProviderContainer container,
    required void Function(ThresholdAction) onFire,
  })  : _container = container,
        _onFire = onFire {
    _sub = container.listen(recordingControllerProvider, _onChange);
  }

  // ignore: unused_field
  final ProviderContainer _container;
  final void Function(ThresholdAction) _onFire;
  ProviderSubscription<RecordingState>? _sub;

  static const _thresholds = <(Duration, ThresholdAction)>[
    (Duration(minutes: 30), ThresholdAction.toast30),
    (Duration(minutes: 60), ThresholdAction.toast60),
    (Duration(minutes: 90), ThresholdAction.modal90),
    (Duration(minutes: 120), ThresholdAction.hardStop),
  ];

  final Set<ThresholdAction> _fired = {};

  void _onChange(RecordingState? prev, RecordingState next) {
    if (next.status == RecordingStatus.idle ||
        next.status == RecordingStatus.error ||
        next.status == RecordingStatus.completed) {
      _fired.clear();
      return;
    }
    for (final entry in _thresholds) {
      if (next.duration >= entry.$1 && !_fired.contains(entry.$2)) {
        _fired.add(entry.$2);
        _onFire(entry.$2);
      }
    }
  }

  void dispose() {
    _sub?.close();
    _sub = null;
  }
}

final longRecordingWatcherProvider = Provider<LongRecordingWatcher>(
  (ref) => throw UnimplementedError(
    'Override longRecordingWatcherProvider in main()',
  ),
);
