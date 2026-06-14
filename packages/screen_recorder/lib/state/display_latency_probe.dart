// packages/screen_recorder/lib/state/display_latency_probe.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'display_latency_smoother.dart';

/// Polls the vendored `video_player_avfoundation` patch for the current
/// AVPlayer-clock-vs-presented-frame latency and exposes a smoothed [Duration]
/// for the editor preview to subtract from the playhead. Preview-only — the
/// export path never uses this.
class DisplayLatencyProbe {
  DisplayLatencyProbe({
    required this.playerId,
    double alpha = 0.3,
    this.interval = const Duration(milliseconds: 125),
    MethodChannel channel = const MethodChannel('slipreel/video_sync'),
  })  : _channel = channel,
        _smoother = DisplayLatencySmoother(alpha: alpha);

  /// video_player's internal player id (null when unknown — probe stays at 0).
  final int? playerId;
  final Duration interval;
  final MethodChannel _channel;
  final DisplayLatencySmoother _smoother;
  final ValueNotifier<Duration> _latency = ValueNotifier<Duration>(Duration.zero);
  Timer? _timer;

  /// Smoothed display latency; safe to read every build.
  ValueListenable<Duration> get latency => _latency;

  /// Begin polling at [interval]. No-op if already started or playerId is null.
  void start() {
    if (_timer != null || playerId == null) return;
    _timer = Timer.periodic(interval, (_) => pollOnce());
  }

  /// One poll cycle. Exposed for tests. Swallows channel errors (treated as a
  /// null reading → value holds).
  @visibleForTesting
  Future<void> pollOnce() async {
    if (playerId == null) return;
    int? micros;
    try {
      micros = await _channel.invokeMethod<int>(
        'getDisplayLatencyMicros',
        {'playerId': playerId},
      );
    } catch (_) {
      micros = null;
    }
    _smoother.add(micros);
    _latency.value = _smoother.value;
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
    _latency.dispose();
  }
}
