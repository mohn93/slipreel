import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

/// Maximum number of concurrent alerts visible in the stack. A 4th
/// alert evicts the oldest (index 0) so the newest is always visible.
const int kMaxAlertStackSize = 3;

/// Owns the live alert stack, the per-entry auto-dismiss timers, and
/// the single shared OverlayEntry that renders the stack on top of the
/// app. Singleton via [AppAlertsController.instance] so the static
/// [AppAlerts] facade can dispatch without a BuildContext.
///
/// The controller is split from the [AppAlerts] facade for testability:
/// unit tests instantiate a fresh controller per test; the public API
/// always routes through the singleton.
class AppAlertsController {
  AppAlertsController();

  /// Singleton used by the static [AppAlerts] facade.
  static final AppAlertsController instance = AppAlertsController();

  /// The live stack, newest at the end. Widgets subscribe via
  /// [ValueListenableBuilder]. Capped at [kMaxAlertStackSize].
  final ValueNotifier<List<AlertEntry>> stack =
      ValueNotifier<List<AlertEntry>>(const []);

  // ----- timer state ----------------------------------------------------
  //
  // For each non-sticky entry we track:
  //   - its currently-running Timer (null while paused),
  //   - the remaining duration when the last pause happened.
  //
  // Sticky entries (duration == Duration.zero) never appear in either
  // map — their absence means "no timer to run."
  final Map<Key, Timer> _timers = <Key, Timer>{};
  final Map<Key, Duration> _remaining = <Key, Duration>{};
  final Map<Key, DateTime> _runningSince = <Key, DateTime>{};

  // ----- overlay mounting (used by AlertStackOverlay) ------------------
  OverlayState? _overlay;
  OverlayEntry? _entry;

  /// Mounts (or re-mounts) the controller's OverlayEntry inside
  /// [overlay]. Idempotent across hot-restarts: any prior overlay,
  /// entry, and timers are torn down first.
  ///
  /// [builder] returns the widget to render inside the entry — wired
  /// from `main.dart` to `AlertStackOverlay(controller: this)`. Passed
  /// as a callback so the controller doesn't import widget code (keeps
  /// it testable without a Flutter binding for the controller layer).
  void attach(OverlayState overlay, WidgetBuilder builder) {
    // Tear down any prior mount.
    _entry?.remove();
    _entry = null;
    _disposeAllTimers();
    stack.value = const [];

    _overlay = overlay;
    _entry = OverlayEntry(builder: builder);
    overlay.insert(_entry!);
  }

  /// Append an entry to the stack, evict if necessary, and start its
  /// auto-dismiss timer (unless [AlertEntry.duration] is zero).
  void pushEntry(AlertEntry entry) {
    final next = List<AlertEntry>.from(stack.value)..add(entry);
    if (next.length > kMaxAlertStackSize) {
      final evicted = next.removeAt(0);
      _cancelTimer(evicted.key);
    }
    stack.value = next;

    if (entry.duration > Duration.zero) {
      _startTimer(entry);
    }
  }

  /// Removes [entry] immediately and cancels its timer if any.
  void dismiss(AlertEntry entry) {
    _cancelTimer(entry.key);
    final next = List<AlertEntry>.from(stack.value)
      ..removeWhere((e) => e.key == entry.key);
    if (!listEquals(next, stack.value)) {
      stack.value = next;
    }
  }

  /// Pauses the auto-dismiss timer for [entry], remembering how much
  /// time was left. Safe to call on sticky entries (no-op).
  void pauseTimer(AlertEntry entry) {
    final timer = _timers.remove(entry.key);
    if (timer == null) return;
    final startedAt = _runningSince.remove(entry.key);
    timer.cancel();
    if (startedAt != null) {
      final elapsed = clock.now().difference(startedAt);
      final previous = _remaining[entry.key] ?? entry.duration;
      final left = previous - elapsed;
      _remaining[entry.key] =
          left > Duration.zero ? left : const Duration(milliseconds: 1);
    }
  }

  /// Resumes the auto-dismiss timer for [entry] with the time that
  /// remained when [pauseTimer] was called. Safe to call on sticky
  /// entries or entries that were never started (no-op).
  void resumeTimer(AlertEntry entry) {
    if (_timers.containsKey(entry.key)) return; // already running
    final remaining = _remaining[entry.key];
    if (remaining == null) return;
    _runningSince[entry.key] = clock.now();
    _timers[entry.key] = Timer(remaining, () => dismiss(entry));
  }

  // ----- helpers --------------------------------------------------------

  void _startTimer(AlertEntry entry) {
    _remaining[entry.key] = entry.duration;
    _runningSince[entry.key] = clock.now();
    _timers[entry.key] = Timer(entry.duration, () => dismiss(entry));
  }

  void _cancelTimer(Key key) {
    _timers.remove(key)?.cancel();
    _remaining.remove(key);
    _runningSince.remove(key);
  }

  void _disposeAllTimers() {
    for (final t in _timers.values) {
      t.cancel();
    }
    _timers.clear();
    _remaining.clear();
    _runningSince.clear();
  }
}
