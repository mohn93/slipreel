# Desktop Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace bottom-anchored `ScaffoldMessenger.showSnackBar` calls with a desktop-style floating alert that drops in from the top of the window — dark theme, type-coded icon, soft shadow, optional action button, max-3 vertical stack with eviction.

**Architecture:** A singleton `AppAlertsController` holds the alert stack as a `ValueNotifier<List<_AlertEntry>>` and a single shared `OverlayEntry` whose builder renders an `_AlertStackOverlay`. The `AppAlerts` static facade (`AppAlerts.success/error/warning/info`) gives a BuildContext-free API. `main.dart` calls `AppAlerts.attach(overlay)` on the first frame. The Settings screen adds a demo section. 14 existing snackbar callsites migrate mechanically.

**Tech Stack:** Dart 3 / Flutter (Material 3), Riverpod (existing), `fake_async` for timer tests, FVM 3.41.5 (`~/fvm/versions/3.41.5/bin/flutter`).

**Spec:** `docs/superpowers/specs/2026-06-01-desktop-alerts-design.md`.

---

## File Structure

**Create:**
- `packages/screen_recorder/lib/ui/app_alerts/app_alert_types.dart` — `AlertType` enum + `AppAlertAction` model + internal `_AlertEntry` record.
- `packages/screen_recorder/lib/ui/app_alerts/app_alerts_controller.dart` — singleton controller, stack, timer, attach, pending buffer.
- `packages/screen_recorder/lib/ui/app_alerts/app_alerts.dart` — public static facade (`AppAlerts.success/error/warning/info`).
- `packages/screen_recorder/lib/ui/app_alerts/alert_pill.dart` — the pill widget (chrome + animation + hover-pause + click).
- `packages/screen_recorder/lib/ui/app_alerts/alert_stack_overlay.dart` — column of pills wired to the controller.
- `packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart`
- `packages/screen_recorder/test/ui/app_alerts/alert_pill_test.dart`

**Modify:**
- `packages/screen_recorder/lib/main.dart` — attach the controller after first frame.
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` — add an "Alert demo" section.
- Migration targets (Task 8):
  - `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (6 callsites)
  - `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart` (1 callsite)
  - `packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart` (1 callsite)

---

## Tasks

### Task 1: Foundational types (`AlertType`, `AppAlertAction`, `_AlertEntry`)

**Files:**
- Create: `packages/screen_recorder/lib/ui/app_alerts/app_alert_types.dart`
- Test: `packages/screen_recorder/test/ui/app_alerts/app_alert_types_test.dart`

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/ui/app_alerts/app_alert_types_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

void main() {
  group('AlertType', () {
    test('default durations match spec', () {
      expect(AlertType.success.defaultDuration, const Duration(seconds: 4));
      expect(AlertType.info.defaultDuration, const Duration(seconds: 4));
      expect(AlertType.error.defaultDuration, const Duration(seconds: 6));
      expect(AlertType.warning.defaultDuration, const Duration(seconds: 6));
    });

    test('accent colors match spec', () {
      expect(AlertType.success.accent, const Color(0xFF34C759));
      expect(AlertType.error.accent, const Color(0xFFFF453A));
      expect(AlertType.warning.accent, const Color(0xFFFF9F0A));
      expect(AlertType.info.accent, const Color(0xFF0A84FF));
    });

    test('icons map to the spec set', () {
      expect(AlertType.success.icon, Icons.check_circle_rounded);
      expect(AlertType.error.icon, Icons.error_rounded);
      expect(AlertType.warning.icon, Icons.warning_amber_rounded);
      expect(AlertType.info.icon, Icons.info_rounded);
    });
  });

  group('AppAlertAction', () {
    test('stores label and callback', () {
      var fired = 0;
      final a = AppAlertAction(label: 'Retry', onPressed: () => fired++);
      expect(a.label, 'Retry');
      a.onPressed();
      expect(fired, 1);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/app_alert_types_test.dart`
Expected: FAIL with "Target of URI doesn't exist: 'package:screen_recorder/ui/app_alerts/app_alert_types.dart'".

- [ ] **Step 3: Implement the types**

```dart
// packages/screen_recorder/lib/ui/app_alerts/app_alert_types.dart
import 'package:flutter/material.dart';

/// Type of alert. Drives the icon, accent color, and default duration.
enum AlertType {
  success,
  error,
  warning,
  info;

  IconData get icon => switch (this) {
        AlertType.success => Icons.check_circle_rounded,
        AlertType.error => Icons.error_rounded,
        AlertType.warning => Icons.warning_amber_rounded,
        AlertType.info => Icons.info_rounded,
      };

  Color get accent => switch (this) {
        AlertType.success => const Color(0xFF34C759),
        AlertType.error => const Color(0xFFFF453A),
        AlertType.warning => const Color(0xFFFF9F0A),
        AlertType.info => const Color(0xFF0A84FF),
      };

  Duration get defaultDuration => switch (this) {
        AlertType.success || AlertType.info => const Duration(seconds: 4),
        AlertType.error || AlertType.warning => const Duration(seconds: 6),
      };
}

/// Optional action button shown on the right side of an alert.
class AppAlertAction {
  const AppAlertAction({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}

/// One live entry in the alert stack. Identity is by [key] so the
/// widget tree can match entries across rebuilds even if message text
/// or action are equal.
class AlertEntry {
  AlertEntry({
    required this.type,
    required this.message,
    required this.duration,
    this.action,
  }) : key = UniqueKey();

  final AlertType type;
  final String message;
  final Duration duration;
  final AppAlertAction? action;
  final Key key;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/app_alert_types_test.dart`
Expected: PASS — 5 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/app_alerts/app_alert_types.dart \
        packages/screen_recorder/test/ui/app_alerts/app_alert_types_test.dart
git commit -m "feat(app): add AlertType + AppAlertAction + AlertEntry foundations"
```

---

### Task 2: `AppAlertsController` singleton + tests

**Files:**
- Create: `packages/screen_recorder/lib/ui/app_alerts/app_alerts_controller.dart`
- Test: `packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart`

The controller owns: the stack `ValueNotifier`, the pending pre-attach buffer, the per-entry timers (with pause/resume), and lazy-mount/unmount of a single OverlayEntry.

For testability the controller's overlay mounting is a SEAM — we expose `_stack` and `pushEntry/pauseTimer/resumeTimer/dismiss` as testable methods. The OverlayEntry mounting itself is exercised in Task 5's widget test, not here.

- [ ] **Step 1: Write the failing tests**

```dart
// packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart
import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

void main() {
  group('AppAlertsController', () {
    test('pushEntry adds to stack', () {
      final c = AppAlertsController();
      c.pushEntry(AlertEntry(
        type: AlertType.info,
        message: 'hello',
        duration: Duration.zero,
      ));
      expect(c.stack.value.length, 1);
      expect(c.stack.value.single.message, 'hello');
    });

    test('stack caps at 3, evicting the oldest', () {
      final c = AppAlertsController();
      for (var i = 0; i < 5; i++) {
        c.pushEntry(AlertEntry(
          type: AlertType.info,
          message: '$i',
          duration: Duration.zero,
        ));
      }
      expect(c.stack.value.length, 3);
      expect(c.stack.value.map((e) => e.message).toList(), ['2', '3', '4']);
    });

    test('non-zero duration auto-dismisses after the duration elapses', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.success,
          message: 'gone soon',
          duration: const Duration(seconds: 4),
        );
        c.pushEntry(e);
        expect(c.stack.value.length, 1);

        async.elapse(const Duration(seconds: 3));
        expect(c.stack.value.length, 1, reason: 'still visible at 3s');

        async.elapse(const Duration(seconds: 2));
        expect(c.stack.value.length, 0, reason: 'dismissed by 5s');
      });
    });

    test('Duration.zero never auto-dismisses', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.info,
          message: 'sticky',
          duration: Duration.zero,
        );
        c.pushEntry(e);
        async.elapse(const Duration(minutes: 5));
        expect(c.stack.value.length, 1);
      });
    });

    test('pauseTimer + resumeTimer extends remaining time', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.error,
          message: 'paused',
          duration: const Duration(seconds: 6),
        );
        c.pushEntry(e);

        async.elapse(const Duration(seconds: 2));
        c.pauseTimer(e);
        async.elapse(const Duration(seconds: 30));
        // Still visible: 2s elapsed, then paused for 30s.
        expect(c.stack.value.length, 1);

        c.resumeTimer(e);
        async.elapse(const Duration(seconds: 3));
        expect(c.stack.value.length, 1, reason: '5s of effective time elapsed');

        async.elapse(const Duration(seconds: 2));
        expect(c.stack.value.length, 0, reason: '6s effective; auto-dismissed');
      });
    });

    test('dismiss removes the entry immediately and cancels its timer', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        final e = AlertEntry(
          type: AlertType.success,
          message: 'click',
          duration: const Duration(seconds: 4),
        );
        c.pushEntry(e);
        c.dismiss(e);
        expect(c.stack.value, isEmpty);

        async.elapse(const Duration(seconds: 10));
        expect(c.stack.value, isEmpty,
            reason: 'timer must not push or re-dismiss after manual dismiss');
      });
    });

    test('pushEntry before attach buffers; flushes on attach', () {
      fakeAsync((async) {
        final c = AppAlertsController();
        c.pushEntry(AlertEntry(
          type: AlertType.info,
          message: 'queued',
          duration: const Duration(seconds: 4),
        ));
        // Stack is populated regardless of attach (attach only matters for
        // the OverlayEntry mounting, exercised in widget tests).
        expect(c.stack.value.length, 1);

        async.elapse(const Duration(seconds: 5));
        expect(c.stack.value, isEmpty, reason: 'timer fires normally');
      });
    });
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/app_alerts_controller_test.dart`
Expected: FAIL — `AppAlertsController` doesn't exist yet.

If the package doesn't already depend on `fake_async`, add it to `packages/screen_recorder/pubspec.yaml` under `dev_dependencies`:
```yaml
dev_dependencies:
  fake_async: ^1.3.1
```
Then run `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter pub get` before the test command above. If it's already there (check by `grep fake_async packages/screen_recorder/pubspec.yaml`), skip this.

- [ ] **Step 3: Implement the controller**

```dart
// packages/screen_recorder/lib/ui/app_alerts/app_alerts_controller.dart
import 'dart:async';

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
      final elapsed = DateTime.now().difference(startedAt);
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
    _runningSince[entry.key] = DateTime.now();
    _timers[entry.key] = Timer(remaining, () => dismiss(entry));
  }

  // ----- helpers --------------------------------------------------------

  void _startTimer(AlertEntry entry) {
    _remaining[entry.key] = entry.duration;
    _runningSince[entry.key] = DateTime.now();
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/app_alerts_controller_test.dart`
Expected: PASS — 7 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/app_alerts/app_alerts_controller.dart \
        packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart \
        packages/screen_recorder/pubspec.yaml \
        packages/screen_recorder/pubspec.lock
git commit -m "feat(app): AppAlertsController singleton with stack + timers"
```

Only stage `pubspec.yaml` / `pubspec.lock` if you actually added `fake_async`. If they're unchanged, drop them from `git add`.

---

### Task 3: `AppAlerts` public facade

**Files:**
- Create: `packages/screen_recorder/lib/ui/app_alerts/app_alerts.dart`
- Test: extend `packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart`

- [ ] **Step 1: Add failing tests at the bottom of the existing controller test file**

Append to `packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart` (inside the same `main()`):

```dart
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';

// ... at the bottom of main():

group('AppAlerts facade', () {
  setUp(() {
    AppAlertsController.instance.stack.value = const [];
  });

  test('success() pushes an AlertType.success entry', () {
    AppAlerts.success('saved');
    final s = AppAlertsController.instance.stack.value;
    expect(s.length, 1);
    expect(s.single.type, AlertType.success);
    expect(s.single.message, 'saved');
    expect(s.single.duration, AlertType.success.defaultDuration);
  });

  test('error() respects custom duration override', () {
    AppAlerts.error('boom', duration: const Duration(seconds: 10));
    final s = AppAlertsController.instance.stack.value;
    expect(s.single.type, AlertType.error);
    expect(s.single.duration, const Duration(seconds: 10));
  });

  test('warning() and info() route to the right types', () {
    AppAlerts.warning('w');
    AppAlerts.info('i');
    final types = AppAlertsController.instance.stack.value
        .map((e) => e.type)
        .toList();
    expect(types, [AlertType.warning, AlertType.info]);
  });

  test('action argument round-trips to the entry', () {
    var fired = 0;
    AppAlerts.success(
      'done',
      action: AppAlertAction(label: 'Show', onPressed: () => fired++),
    );
    final entry = AppAlertsController.instance.stack.value.single;
    expect(entry.action?.label, 'Show');
    entry.action!.onPressed();
    expect(fired, 1);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/app_alerts_controller_test.dart`
Expected: FAIL — `AppAlerts` import unresolved.

- [ ] **Step 3: Implement the facade**

```dart
// packages/screen_recorder/lib/ui/app_alerts/app_alerts.dart
import 'package:flutter/widgets.dart';

import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

/// BuildContext-free static API for firing top-of-window alerts.
///
/// All four methods enqueue the alert into the shared
/// [AppAlertsController.instance]. The controller's [OverlayEntry] is
/// installed once at app start (see `main.dart` → [attach]); calls
/// made before that still land on the stack and become visible as
/// soon as the overlay is mounted.
class AppAlerts {
  AppAlerts._();

  /// Wires the controller into the app's root [Overlay]. Called once
  /// from `main.dart` inside a post-frame callback. Idempotent across
  /// hot-restart.
  static void attach(OverlayState overlay, WidgetBuilder builder) =>
      AppAlertsController.instance.attach(overlay, builder);

  static void success(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.success, message, action, duration);

  static void error(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.error, message, action, duration);

  static void warning(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.warning, message, action, duration);

  static void info(String message,
          {AppAlertAction? action, Duration? duration}) =>
      _push(AlertType.info, message, action, duration);

  static void _push(AlertType type, String message,
      AppAlertAction? action, Duration? duration) {
    AppAlertsController.instance.pushEntry(AlertEntry(
      type: type,
      message: message,
      duration: duration ?? type.defaultDuration,
      action: action,
    ));
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/app_alerts_controller_test.dart`
Expected: PASS — original 7 + 4 new = 11 tests.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/app_alerts/app_alerts.dart \
        packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart
git commit -m "feat(app): AppAlerts public facade"
```

---

### Task 4: `AlertPill` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/app_alerts/alert_pill.dart`
- Test: `packages/screen_recorder/test/ui/app_alerts/alert_pill_test.dart`

- [ ] **Step 1: Write the failing widget tests**

```dart
// packages/screen_recorder/test/ui/app_alerts/alert_pill_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/app_alerts/alert_pill.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

void main() {
  Future<void> pump(WidgetTester tester, AlertEntry entry, {
    VoidCallback? onDismiss,
    VoidCallback? onHoverEnter,
    VoidCallback? onHoverExit,
  }) {
    return tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: AlertPill(
            entry: entry,
            onDismiss: onDismiss ?? () {},
            onHoverEnter: onHoverEnter ?? () {},
            onHoverExit: onHoverExit ?? () {},
          ),
        ),
      ),
    ));
  }

  testWidgets('renders the message text', (tester) async {
    await pump(
      tester,
      AlertEntry(
        type: AlertType.info,
        message: 'hello world',
        duration: Duration.zero,
      ),
    );
    expect(find.text('hello world'), findsOneWidget);
  });

  testWidgets('renders the type icon', (tester) async {
    await pump(
      tester,
      AlertEntry(
        type: AlertType.success,
        message: 'ok',
        duration: Duration.zero,
      ),
    );
    expect(find.byIcon(Icons.check_circle_rounded), findsOneWidget);
  });

  testWidgets('tap on the pill body fires onDismiss', (tester) async {
    var dismissed = 0;
    await pump(
      tester,
      AlertEntry(
        type: AlertType.info,
        message: 'click me',
        duration: Duration.zero,
      ),
      onDismiss: () => dismissed++,
    );
    await tester.tap(find.text('click me'));
    expect(dismissed, 1);
  });

  testWidgets('action button fires its callback (NOT onDismiss synchronously)',
      (tester) async {
    var actionFired = 0;
    var dismissed = 0;
    await pump(
      tester,
      AlertEntry(
        type: AlertType.success,
        message: 'done',
        duration: Duration.zero,
        action: AppAlertAction(label: 'Show', onPressed: () => actionFired++),
      ),
      onDismiss: () => dismissed++,
    );
    await tester.tap(find.text('Show'));
    expect(actionFired, 1);
    // Action button is responsible for dismissing — happens via its own
    // wrapper, not by the outer GestureDetector. We assert exactly 1.
    expect(dismissed, 1);
  });

  testWidgets('hover (MouseRegion enter/exit) fires hover callbacks',
      (tester) async {
    var enter = 0;
    var exit = 0;
    await pump(
      tester,
      AlertEntry(
        type: AlertType.error,
        message: 'hover me',
        duration: const Duration(seconds: 6),
      ),
      onHoverEnter: () => enter++,
      onHoverExit: () => exit++,
    );

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    addTearDown(gesture.removePointer);
    await gesture.addPointer(location: Offset.zero);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(AlertPill)));
    await tester.pump();
    expect(enter, 1);

    await gesture.moveTo(const Offset(2000, 2000));
    await tester.pump();
    expect(exit, 1);
  });
}
```

Add to top of the test file if missing:
```dart
import 'package:flutter/gestures.dart' show PointerDeviceKind;
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/alert_pill_test.dart`
Expected: FAIL with "Target of URI doesn't exist".

- [ ] **Step 3: Implement the pill widget**

```dart
// packages/screen_recorder/lib/ui/app_alerts/alert_pill.dart
import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';

/// One floating alert pill. Pure widget — animation lifecycle is owned
/// by [AlertStackOverlay] via [AnimatedSwitcher] / `key`-driven mount
/// and unmount. This widget is responsible for: chrome, layout,
/// hover-pause callbacks, click-to-dismiss, and the optional action
/// button.
class AlertPill extends StatelessWidget {
  const AlertPill({
    super.key,
    required this.entry,
    required this.onDismiss,
    required this.onHoverEnter,
    required this.onHoverExit,
  });

  final AlertEntry entry;
  final VoidCallback onDismiss;
  final VoidCallback onHoverEnter;
  final VoidCallback onHoverExit;

  @override
  Widget build(BuildContext context) {
    final action = entry.action;
    return MouseRegion(
      onEnter: (_) => onHoverEnter(),
      onExit: (_) => onHoverExit(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: action == null ? onDismiss : null,
        // When an action button is present we keep the body tap-to-dismiss
        // behavior for clicks outside the button; nested GestureDetector on
        // the button stops propagation.
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            minWidth: 240,
            maxWidth: 560,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF000000).withValues(alpha: 0.92),
              border: Border.all(
                color: const Color(0xFFFFFFFF).withValues(alpha: 0.08),
              ),
              borderRadius: BorderRadius.circular(12),
              boxShadow: const [
                BoxShadow(
                  color: Color.fromRGBO(0, 0, 0, 0.45),
                  blurRadius: 28,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(entry.type.icon, size: 20, color: entry.type.accent),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      entry.message,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (action != null) ...[
                    const SizedBox(width: 12),
                    GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: () {
                        action.onPressed();
                        onDismiss();
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 2,
                        ),
                        child: Text(
                          action.label,
                          style: TextStyle(
                            color: entry.type.accent,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/alert_pill_test.dart`
Expected: PASS — 5 tests.

If the "action button" test fails with `dismissed == 0`, the action's `onTap` is missing the trailing `onDismiss()` call — verify the implementation matches the snippet.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/app_alerts/alert_pill.dart \
        packages/screen_recorder/test/ui/app_alerts/alert_pill_test.dart
git commit -m "feat(app): AlertPill widget — chrome + tap + hover callbacks"
```

---

### Task 5: `AlertStackOverlay` widget (top-center column + entry animations)

**Files:**
- Create: `packages/screen_recorder/lib/ui/app_alerts/alert_stack_overlay.dart`

This widget is mostly visual glue with no public API surface to unit-test directly — the controller and pill are already covered. We add ONE smoke widget test to verify it renders pills from the controller's stack and reacts to changes.

- [ ] **Step 1: Write the failing smoke test**

Append to `packages/screen_recorder/test/ui/app_alerts/alert_pill_test.dart` (the existing file — keep all tests together for this directory):

```dart
import 'package:screen_recorder/ui/app_alerts/alert_stack_overlay.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

// ... at the bottom of main():

group('AlertStackOverlay', () {
  testWidgets('renders pills for every entry in the controller stack',
      (tester) async {
    final controller = AppAlertsController();
    controller.pushEntry(AlertEntry(
      type: AlertType.success,
      message: 'one',
      duration: Duration.zero,
    ));
    controller.pushEntry(AlertEntry(
      type: AlertType.error,
      message: 'two',
      duration: Duration.zero,
    ));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: AlertStackOverlay(controller: controller),
      ),
    ));

    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);

    controller.dismiss(controller.stack.value.first);
    await tester.pumpAndSettle();
    expect(find.text('one'), findsNothing);
    expect(find.text('two'), findsOneWidget);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/alert_pill_test.dart`
Expected: FAIL — `AlertStackOverlay` doesn't exist.

- [ ] **Step 3: Implement the stack overlay**

```dart
// packages/screen_recorder/lib/ui/app_alerts/alert_stack_overlay.dart
import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/app_alerts/alert_pill.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';

/// Reads [AppAlertsController.stack] and renders a top-center vertical
/// column of [AlertPill]s with entry/exit animations.
///
/// Hover on a pill pauses its controller-side auto-dismiss timer; mouse
/// leave resumes it. Tap on a pill (or its action button) dismisses
/// via the controller.
class AlertStackOverlay extends StatelessWidget {
  const AlertStackOverlay({super.key, required this.controller});

  final AppAlertsController controller;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Align(
        alignment: Alignment.topCenter,
        child: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: ValueListenableBuilder<List<AlertEntry>>(
            valueListenable: controller.stack,
            builder: (context, stack, _) {
              return AnimatedSize(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final entry in stack) ...[
                      _AnimatedPill(
                        key: entry.key,
                        entry: entry,
                        controller: controller,
                      ),
                      if (entry != stack.last) const SizedBox(height: 8),
                    ],
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Wraps [AlertPill] with the enter slide+fade animation. Exit
/// animation is handled by the parent stack removing the entry — the
/// AnimatedSize collapses the row and the GC handles teardown.
class _AnimatedPill extends StatefulWidget {
  const _AnimatedPill({
    super.key,
    required this.entry,
    required this.controller,
  });

  final AlertEntry entry;
  final AppAlertsController controller;

  @override
  State<_AnimatedPill> createState() => _AnimatedPillState();
}

class _AnimatedPillState extends State<_AnimatedPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ac = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..forward();

  late final Animation<Offset> _slide = Tween<Offset>(
    begin: const Offset(0, -1.2),
    end: Offset.zero,
  ).animate(CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic));

  late final Animation<double> _fade =
      CurvedAnimation(parent: _ac, curve: Curves.easeOutCubic);

  @override
  void dispose() {
    _ac.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _fade,
      child: SlideTransition(
        position: _slide,
        child: AlertPill(
          entry: widget.entry,
          onDismiss: () => widget.controller.dismiss(widget.entry),
          onHoverEnter: () => widget.controller.pauseTimer(widget.entry),
          onHoverExit: () => widget.controller.resumeTimer(widget.entry),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test test/ui/app_alerts/`
Expected: PASS — all tests in the `app_alerts` directory green.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/app_alerts/alert_stack_overlay.dart \
        packages/screen_recorder/test/ui/app_alerts/alert_pill_test.dart
git commit -m "feat(app): AlertStackOverlay — top-center column with enter animation"
```

---

### Task 6: Wire `AppAlerts.attach` into `main.dart`

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`

- [ ] **Step 1: Add the attach call**

Open `packages/screen_recorder/lib/main.dart`. Two changes:

(a) Add imports near the existing screen_recorder imports:
```dart
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/app_alerts/alert_stack_overlay.dart';
import 'package:screen_recorder/ui/app_alerts/app_alerts_controller.dart';
```

(b) Find the existing `MaterialApp(...)` return inside the App widget's `build` (around line 407). Wrap it with a `Builder` that runs a post-frame callback to attach the alerts overlay, OR more cleanly, add a `builder:` callback to `MaterialApp` that injects the post-frame attach. The cleanest is to use the existing `navigatorKey` so we don't need a Builder:

Replace the existing `build` body's first statement so the post-frame attach runs every build pass (idempotent — `attach` tears down any previous overlay):

```dart
@override
Widget build(BuildContext context) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final overlay = rootNavigatorKey.currentState?.overlay;
    if (overlay != null) {
      AppAlerts.attach(
        overlay,
        (_) => AlertStackOverlay(controller: AppAlertsController.instance),
      );
    }
  });

  return MaterialApp(
    navigatorKey: rootNavigatorKey,
    // ... rest unchanged
```

The `addPostFrameCallback` fires after `MaterialApp` has built its `Navigator` and `Overlay`, so `overlay` is non-null on the first frame.

- [ ] **Step 2: Verify it compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/main.dart`
Expected: No errors.

- [ ] **Step 3: Manual smoke test (optional but recommended)**

If the app is already running via `flutter run`, hot-restart. The alert system is mounted but no callsites use it yet — verify the app launches with no regressions:
- Bar mode chrome appears.
- Opening a recording shows the editor with the canvas toolbar.

No alerts will be visible yet. The next task adds a way to fire them.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(app): mount AlertStackOverlay at app start via post-frame attach"
```

---

### Task 7: Settings screen demo section

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/settings_screen.dart`

- [ ] **Step 1: Add the demo section**

Open `packages/screen_recorder/lib/ui/screens/settings_screen.dart`. Add imports near the existing imports:

```dart
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
import 'package:screen_recorder/ui/app_alerts/app_alert_types.dart';
```

Inside the `Scaffold`'s body, find a good insertion point near the end of the existing settings list (before any "Done" / close button if present). Read the file's `build` method (around line 75–end) for context.

Add the section as a Column of `ListTile`s grouped under a header (matches the existing settings style — read 30 lines of surrounding settings to confirm the visual idiom):

```dart
const Divider(),
const Padding(
  padding: EdgeInsets.fromLTRB(16, 16, 16, 8),
  child: Text(
    'Alert demo',
    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
  ),
),
ListTile(
  leading: Icon(AlertType.success.icon, color: AlertType.success.accent),
  title: const Text('Show success'),
  onTap: () => AppAlerts.success('Saved to ~/Movies/clip.mp4'),
),
ListTile(
  leading: Icon(AlertType.error.icon, color: AlertType.error.accent),
  title: const Text('Show error'),
  onTap: () => AppAlerts.error("Couldn't pick a save location: permission denied"),
),
ListTile(
  leading: Icon(AlertType.warning.icon, color: AlertType.warning.accent),
  title: const Text('Show warning'),
  onTap: () => AppAlerts.warning('System audio not available on macOS 12'),
),
ListTile(
  leading: Icon(AlertType.info.icon, color: AlertType.info.accent),
  title: const Text('Show info'),
  onTap: () => AppAlerts.info('Recording paused'),
),
ListTile(
  leading: const Icon(Icons.layers_rounded),
  title: const Text('Fire 3 in a row (stack test)'),
  onTap: () {
    AppAlerts.success('First');
    AppAlerts.warning('Second');
    AppAlerts.error('Third');
  },
),
ListTile(
  leading: const Icon(Icons.push_pin_rounded),
  title: const Text('Sticky info (no auto-dismiss)'),
  onTap: () => AppAlerts.info(
    'Hover me, click to dismiss. Stays until you do.',
    duration: Duration.zero,
  ),
),
ListTile(
  leading: const Icon(Icons.touch_app_rounded),
  title: const Text('Success with action button'),
  onTap: () => AppAlerts.success(
    'Exported clip.mp4',
    action: AppAlertAction(
      label: 'Show in Finder',
      onPressed: () {},
    ),
  ),
),
```

If the existing settings layout uses `ListView`, drop these into its children list. If it uses `Column`, append directly. The exact wrap depends on the file's current shape — read the build method first.

- [ ] **Step 2: Verify it compiles**

Run: `~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder/lib/ui/screens/settings_screen.dart`
Expected: No errors.

- [ ] **Step 3: Manual verification**

Hot-restart the app. Open Settings. Scroll to the bottom. Tap each demo entry; verify:
- **Success / Error / Warning / Info** each render the right icon + accent color in the top-center.
- **Fire 3 in a row** stacks 3 pills with 8px gaps; the bottom pill auto-dismisses first.
- **Sticky info** stays until you click it. Mouse-over does nothing visual (timer pause is invisible because there's no timer).
- **Success with action** shows a "Show in Finder" link in the alert's right side; clicking it dismisses the alert.

If anything looks off (positioning, animation jank, color), pause and re-read the visual spec section.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/settings_screen.dart
git commit -m "feat(app): Settings 'Alert demo' section exercises all alert variants"
```

---

### Task 8: Migrate 14 existing `ScaffoldMessenger.showSnackBar` callsites

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (6 callsites)
- Modify: `packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart` (1 callsite)
- Modify: `packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart` (1 callsite)

(The 14 number in earlier notes counted line pairs — `ScaffoldMessenger` + `SnackBar(` — for a total of ~8 actual call SITES. Confirm via `grep -c "ScaffoldMessenger.of" packages/screen_recorder/lib/ui/screens/`.)

Mapping rule:
- `backgroundColor: Colors.red` → `AppAlerts.error(messageText)`.
- `backgroundColor: Colors.orange` → `AppAlerts.warning(messageText)`.
- `backgroundColor: const Color(0xFF4CAF50)` → `AppAlerts.success(messageText)`.
- No background color → `AppAlerts.info(messageText)`.

- [ ] **Step 1: Migrate `playback_screen.dart`**

Open `packages/screen_recorder/lib/ui/screens/playback_screen.dart`. Add the import:
```dart
import 'package:screen_recorder/ui/app_alerts/app_alerts.dart';
```

Then visit each `ScaffoldMessenger.of(context).showSnackBar(...)` at lines ~526, 539, 575, 694, 713 (line numbers may have shifted). For each, rewrite from the form:

```dart
ScaffoldMessenger.of(context).showSnackBar(
  SnackBar(
    content: Text('Some message'),
    backgroundColor: Colors.red,
  ),
);
```

to:
```dart
AppAlerts.error('Some message');
```

Pick the right type by the `backgroundColor`. Preserve the `Text` widget's runtime string (do `final msg = '...'; AppAlerts.error(msg);` if it's an interpolated expression).

For the call at line ~526 (currently uses `Text('Couldn\'t prepare export: $e')` + red): use `AppAlerts.error("Couldn't prepare export: $e")`.

For the call at line ~539 (uses orange + a multi-line / hardcoded warning): use `AppAlerts.warning(...)` with the same text.

For the call at line ~575 (currently uses red for save-location failure): `AppAlerts.error("Couldn't pick a save location: $e")`.

For the call at line ~694 (uses green `0xFF4CAF50` for export success + `result.message`): `AppAlerts.success(result.message)`. If `result` carries the output path and you want a "Show in Finder" action, add:
```dart
AppAlerts.success(
  result.message,
  action: outPath != null
      ? AppAlertAction(
          label: 'Show in Finder',
          onPressed: () => Process.run('open', ['-R', outPath]),
        )
      : null,
);
```
(Only do this if `outPath` and `Process` are already in scope at the callsite. Otherwise leave the migration plain — actions are a future enhancement, not part of this migration's scope.)

For the call at line ~713 (red, "Export failed: $error"): `AppAlerts.error('Export failed: $error')`.

- [ ] **Step 2: Migrate `motion_blur_playground_screen.dart`**

Open the file and replace the single snackbar (around line 246, neutral background — `Saved ${out.path}`) with:
```dart
AppAlerts.info('Saved ${out.path}');
```

Add the import at the top.

- [ ] **Step 3: Migrate `onboarding_screen.dart`**

Open the file. The snackbar around line 48 currently uses the default Material style (no `backgroundColor` field) for an onboarding error path. Replace with `AppAlerts.info(...)` or `AppAlerts.error(...)` depending on the message — read the surrounding code to judge.

Add the import at the top.

- [ ] **Step 4: Verify nothing else uses snackbars**

Run: `grep -rn "ScaffoldMessenger\|SnackBar(" --include="*.dart" packages/ | grep -v test`
Expected: 0 results. If any remain, repeat the migration for them.

- [ ] **Step 5: Verify analyzer + tests pass**

Run:
```bash
~/fvm/versions/3.41.5/bin/flutter analyze packages/screen_recorder
cd packages/screen_recorder && ~/fvm/versions/3.41.5/bin/flutter test
```
Expected: 0 analyzer errors. App tests: green (the same pre-existing `debug_probe_test` LOCAL-ONLY-induced failure is acceptable; nothing new should fail).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/lib/ui/screens/motion_blur_playground_screen.dart \
        packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart
git commit -m "refactor(app): migrate ScaffoldMessenger snackbars to AppAlerts"
```

---

### Task 9: Manual end-to-end verification

**Files:** none (verification only).

- [ ] **Step 1: Hot-restart**

If the app is running, hot-restart. Otherwise launch via `~/fvm/versions/3.41.5/bin/flutter run -d macos` from the repo root.

- [ ] **Step 2: Run through the migrated paths**

For each migrated callsite, exercise the path:
- **Export success** — open a recording, export an MP4. Green success alert with the output message.
- **Export error** — pick a destination you don't have write access to (or cancel the save dialog mid-flow). Red error alert.
- **Motion blur playground "Saved"** — fire the playground's save action. Blue info alert.
- **Onboarding info path** — restart with onboarding state cleared (delete the onboarding-store JSON or use the dev menu). The onboarding-error alert appears as a blue info pill (or red error, depending on what you chose in Task 8 Step 3).

For each, confirm:
- Alert anchors top-center, slides down from above, fades in.
- Auto-dismisses at the right time (4s for success/info, 6s for error/warning).
- Hover pauses the timer.
- Click dismisses.

- [ ] **Step 3: Run through the Settings demo**

Open Settings, tap every demo entry, confirm stacking, sticky behavior, and the action-button flow.

- [ ] **Step 4: No commit**

If anything fails, fix it (likely in Task 4 or Task 5) and re-run from Step 1. If all passes, the feature is shipped.

---

## Done

After Task 9 passes, hand off to `superpowers:finishing-a-development-branch` for merge.
