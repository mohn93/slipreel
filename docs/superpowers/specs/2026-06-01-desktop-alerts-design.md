# Desktop Alerts — Design Spec

**Date:** 2026-06-01
**Status:** Approved, ready for implementation plan.

## Goal

Replace Flutter's bottom-anchored Material `SnackBar` with a desktop-native floating alert. A single dark-themed pill drops in from the top-center of the window, sized to its content, with a type-coded icon and an optional action button. Up to three alerts stack vertically.

## Non-Goals

- **No queue.** Alerts stack live (max 3). The 4th evicts the oldest.
- **No custom theming per call.** Type → preset visuals (icon, accent color, default duration). Callers only choose the type.
- **No multi-window alerts.** Alerts only fire from screens that live in panel mode (editor, settings, onboarding). The bar/pill windows have their own coachmark/tip system and don't call `AppAlerts`.
- **No close (X) button.** Auto-dismiss + click-to-dismiss is enough.
- **No golden-image tests.** Codebase convention.

## Architecture Summary

One singleton controller, one OverlayEntry, one ValueNotifier-backed stack widget. Caller-side API is BuildContext-free static methods.

```
AppAlerts.success(msg)
        │
        ▼
AppAlertsController._instance        (singleton)
        │
        ├── OverlayState  (captured at first call from MaterialApp's navigatorKey)
        ├── ValueNotifier<List<_Alert>>  (max 3; eviction on overflow)
        ├── Timer per _Alert  (auto-dismiss; paused on hover)
        └── OverlayEntry  (single, shared, builder reads the ValueNotifier)
                 │
                 ▼
        _AlertStackOverlay  (Align.topCenter → Column of _AlertPill widgets)
```

## Types

Four variants, each with a fixed icon, accent color, and default duration:

| Type | Icon | Accent | Default duration |
|---|---|---|---|
| `success` | `Icons.check_circle_rounded` | `#34C759` | 4 s |
| `error` | `Icons.error_rounded` | `#FF453A` | 6 s |
| `warning` | `Icons.warning_amber_rounded` | `#FF9F0A` | 6 s |
| `info` | `Icons.info_rounded` | `#0A84FF` | 4 s |

Accent color is applied to the icon only. Everything else (background, text) stays dark across all types.

## Visual Spec

**Position:** top-center of the window, `SafeArea`-aware, 16px below the top safe-area edge.

**Pill chrome:**
- Fill: `Color(0xFF000000)` with `Color.alpha = 0.92`.
- Border: `Border.all(color: Color(0xFFFFFFFF).withValues(alpha: 0.08), width: 1)`.
- Radius: `BorderRadius.circular(12)`.
- Shadow: single `BoxShadow(color: Color.fromRGBO(0, 0, 0, 0.45), blurRadius: 28, offset: Offset(0, 12))`.
- Padding: `EdgeInsets.symmetric(horizontal: 14, vertical: 12)`.
- Min width: 240 px. Max width: 560 px (long messages wrap).

**Content row (left → right):**
- Type icon, 20 px, tinted with the accent color.
- 8 px gap.
- Message text — `bodyMedium.copyWith(color: Colors.white, fontWeight: FontWeight.w500)`. Max 2 lines, ellipsis on overflow.
- (If action present) 12 px gap + `TextButton` with `foregroundColor: <accent>`, text-only, no border/fill. Label uppercased like macOS HIG action buttons.

**Stack layout:** vertical `Column` with 8 px gaps between pills, newest on top.

## Animation

**Entry (per pill):**
- Slide from `Offset(0, -1.2)` (just above its row) to `Offset.zero`, combined with opacity 0 → 1.
- Duration: 260 ms.
- Curve: `Curves.easeOutCubic`.
- The slight negative overshoot (`-1.2` instead of `-1.0`) gives a subtle "drop in" feel.

**Exit (auto-timer or click):**
- Opacity 1 → 0 and slide to `Offset(0, -0.6)`.
- Duration: 200 ms.
- Curve: `Curves.easeInCubic`.

**Stack reflow:** when a pill in the middle/bottom of the stack exits, neighbors `AnimatedSlide` into their new positions (200 ms, `Curves.easeOutCubic`). Implemented via `AnimatedSwitcher` + `AnimatedSize` on the parent `Column`; the per-pill `AnimatedBuilder` is just for opacity/translate.

**Hover-pause:** wrap each pill in `MouseRegion`. `onEnter` cancels the timer; `onExit` restarts it from the remaining-time tracked when paused. So a long error stays on screen as long as the user's cursor is over it.

**Click-to-dismiss:** the pill's background is wrapped in `GestureDetector` (or `InkWell` for visual feedback) — taps anywhere except the action button trigger immediate exit. Clicking the action button fires its callback **then** dismisses.

## Public API

`AppAlerts` (static facade, lives in `packages/screen_recorder/lib/ui/app_alerts/app_alerts.dart`):

```dart
class AppAlerts {
  AppAlerts._();

  static void success(String message, {AppAlertAction? action, Duration? duration});
  static void error(String message, {AppAlertAction? action, Duration? duration});
  static void warning(String message, {AppAlertAction? action, Duration? duration});
  static void info(String message, {AppAlertAction? action, Duration? duration});

  /// Hook the controller into the app's `Overlay` once at startup. Idempotent.
  /// Called from `MyApp.build` via `navigatorKey`'s `currentState!.overlay`.
  static void attach(OverlayState overlay);
}

class AppAlertAction {
  const AppAlertAction({required this.label, required this.onPressed});
  final String label;
  final VoidCallback onPressed;
}
```

`duration: Duration.zero` makes the alert sticky (no auto-dismiss; user must click to dismiss).

## OverlayEntry Mechanics

**`AppAlertsController`** (private to the `app_alerts` directory, singleton via `static final _instance`):

- `OverlayState? _overlay` — captured by `AppAlerts.attach(overlay)`. Until set, calls enqueue.
- `final ValueNotifier<List<_AlertEntry>> _stack = ValueNotifier([])` — max length 3.
- `final List<_AlertEntry> _pendingPreAttach = []` — flushed onto `_stack` when `_overlay` becomes non-null.
- `OverlayEntry? _entry` — a SINGLE shared overlay entry whose builder is `_AlertStackOverlay(_stack)`. Mounted lazily on first non-empty `_stack`.
- `_Timer? Map<_AlertEntry, Timer> _timers` — one per active alert.

**Show flow:**
1. Build `_AlertEntry{type, message, action, duration, key: UniqueKey()}`.
2. If `_overlay == null`, push onto `_pendingPreAttach` and return.
3. Append to `_stack.value`. If length > 3, remove the oldest (index 0).
4. If `_entry == null`, create + insert into the `_overlay`.
5. Start a `Timer(duration)` that calls `_dismiss(entry)`. If `duration == Duration.zero`, skip the timer.

**Dismiss flow:**
1. Cancel the entry's timer.
2. Trigger the exit animation (the pill widget listens for its own removal from `_stack` and animates out before the parent removes it).
3. Once the exit animation completes, remove from `_stack`.
4. If `_stack.value.isEmpty`, remove `_entry` from the overlay (frees the layer).

**Window guard:** in practice no code in `RecordingBarScreen` or the bar-mode pill paths calls `AppAlerts` — all current snackbar callsites originate from editor/settings/onboarding screens that only exist in panel mode. So no explicit guard is needed at the controller level. If we ever add a bar-context callsite, the controller will still mount the OverlayEntry on the (small) bar window; we'll add a per-call check at that point. YAGNI for now.

## Public Wiring

In `packages/screen_recorder/lib/main.dart` (the app root):

1. `MaterialApp` already has a `navigatorKey`. After `runApp`, in a post-frame callback:
   ```dart
   WidgetsBinding.instance.addPostFrameCallback((_) {
     final overlay = navigatorKey.currentState?.overlay;
     if (overlay != null) AppAlerts.attach(overlay);
   });
   ```
2. Re-attach on hot restart (the `addPostFrameCallback` runs on every `main()`).

## Demo (Settings entry)

Add a new section to `packages/screen_recorder/lib/ui/screens/settings_screen.dart` titled "Alert demo":
- 4 buttons — **Success / Error / Warning / Info** — each fires a sample alert with representative copy.
- 1 button — **Fire 3 in a row** — calls all four types in quick succession to exercise stacking + eviction.
- 1 button — **Sticky info (no auto-dismiss)** — fires an `info` with `duration: Duration.zero` to verify hover behavior + click-to-dismiss.
- The section is shipped (not gated behind a build flag) — it's small, useful as a manual smoke test after any alert-system change, and gives a place to see all variants without recording first.

## Migration

After the demo lands and we're happy with the visuals, migrate the 14 existing `ScaffoldMessenger.showSnackBar` callsites. Mapping rules:

- `backgroundColor: Colors.red` → `AppAlerts.error(...)`.
- `backgroundColor: Colors.orange` → `AppAlerts.warning(...)`.
- `backgroundColor: const Color(0xFF4CAF50)` (green) → `AppAlerts.success(...)`.
- Default (no color) → `AppAlerts.info(...)`.

The 14 callsites live in `playback_screen.dart` (10), `motion_blur_playground_screen.dart` (1), `onboarding_screen.dart` (1) — plus any other we discover via grep. Migration is mechanical; no logic changes.

## Files Created / Modified

**Create:**
- `packages/screen_recorder/lib/ui/app_alerts/app_alerts.dart` — public `AppAlerts` facade + `AppAlertAction`.
- `packages/screen_recorder/lib/ui/app_alerts/app_alerts_controller.dart` — singleton controller.
- `packages/screen_recorder/lib/ui/app_alerts/alert_stack_overlay.dart` — the stack widget that reads `_stack` and renders pills.
- `packages/screen_recorder/lib/ui/app_alerts/alert_pill.dart` — one pill widget (chrome, animation, hover-pause, click-to-dismiss).
- `packages/screen_recorder/test/ui/app_alerts/app_alerts_controller_test.dart` — unit tests for show, eviction, pending-pre-attach, timer, hover.
- `packages/screen_recorder/test/ui/app_alerts/alert_pill_test.dart` — widget tests for 4 types, hover-pause, action callback, click-to-dismiss.

**Modify:**
- `packages/screen_recorder/lib/main.dart` — attach the controller after first frame.
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart` — add the "Alert demo" section.
- The 14 callsite files (post-migration) — replace `ScaffoldMessenger.of(context).showSnackBar(...)` with `AppAlerts.<type>(...)`.

## Testing

**Unit (`app_alerts_controller_test.dart`):**
- `success/error/warning/info` each push the right `_AlertEntry.type`.
- Pushing a 4th entry evicts the oldest (`_stack.value.length` stays at 3).
- Calls before `attach()` enqueue and flush when `attach()` runs.
- Sticky (`duration: Duration.zero`) doesn't schedule a timer.
- Action callback fires when invoked.
- Sequential calls before `attach()` enqueue in order; after `attach()`, all flush onto `_stack` (subject to max-3 eviction).

**Widget (`alert_pill_test.dart`):**
- Each type renders its expected icon + accent color (`find.byIcon` + tinted-color inspection).
- Long text wraps to 2 lines and ellipses on overflow.
- Tap on the pill body fires dismissal; tap on the action button fires the action callback first.
- Hover (`MouseRegion` simulated) pauses the timer; un-hover resumes it.

**No integration tests** for the overlay-insertion mechanics — those are exercised by the demo section and the post-migration smoke tests.

## Open Risks

- **Hot-restart re-attach.** The first `main()` runs once at app launch. Hot-restart re-runs `main()`, which calls `AppAlerts.attach` again with a fresh `OverlayState`. The controller's `attach` must be idempotent — replace `_overlay`, clear `_stack`, cancel timers, dispose the old `OverlayEntry`. Implemented in `attach` itself.
- **OverlayEntry lifecycle.** The single shared entry stays mounted while the stack is non-empty. When the last alert dismisses and `_stack` becomes empty, we remove the entry. Memory is fine.
- **Multi-display.** `MediaQuery.size` reads from the current window. Alerts always anchor to the window that hosts the `MaterialApp` — they don't follow the mouse to another display. Acceptable.
