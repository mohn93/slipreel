import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

class CountdownState {
  const CountdownState({this.remaining = 0, this.active = false});
  final int remaining;
  final bool active;

  CountdownState copyWith({int? remaining, bool? active}) => CountdownState(
        remaining: remaining ?? this.remaining,
        active: active ?? this.active,
      );

  static const initial = CountdownState();
}

class CountdownController extends StateNotifier<CountdownState> {
  CountdownController() : super(CountdownState.initial);

  Timer? _timer;
  void Function()? _onComplete;

  /// Starts a countdown. If `seconds == 0`, fires `onComplete` next microtask
  /// and stays inactive. If already active, the call is a no-op.
  void run({required int seconds, required void Function() onComplete}) {
    if (state.active) return;
    if (seconds <= 0) {
      scheduleMicrotask(onComplete);
      return;
    }
    _onComplete = onComplete;
    state = CountdownState(remaining: seconds, active: true);
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      final next = state.remaining - 1;
      if (next <= 0) {
        _timer?.cancel();
        _timer = null;
        state = const CountdownState(remaining: 0, active: false);
        final cb = _onComplete;
        _onComplete = null;
        cb?.call();
      } else {
        state = state.copyWith(remaining: next);
      }
    });
  }

  /// Cancel without firing `onComplete`.
  void cancel() {
    _timer?.cancel();
    _timer = null;
    _onComplete = null;
    if (state.active) {
      state = CountdownState.initial;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }
}

final countdownControllerProvider =
    StateNotifierProvider<CountdownController, CountdownState>(
  (ref) => CountdownController(),
);
