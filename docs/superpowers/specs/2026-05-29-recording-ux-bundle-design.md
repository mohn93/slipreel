# Recording UX bundle (sub-project A)

**Date:** 2026-05-29
**Status:** Approved (design)
**Scope:** Five recording-lifecycle features bundled because they all touch `RecordingController` + the recording pill: 3-2-1 countdown overlay before recording, Pause/Resume during recording (paused time excluded from the output), system-wide global hotkeys, system-sleep auto-pause with on-wake modal, and long-recording warnings (30 / 60 min toasts, 90 min prompt, 2 hr hard stop).

This is sub-project A of the five-part backlog from the 2026-05-28 brainstorm; B (first-run & permissions) has shipped; C (crash recovery), D (click auto-zoom), E (distribution) follow.

## Background

`RecordingController` (in `packages/screen_recorder/lib/state/recording_state.dart`) today exposes `selectSource()`, `startRecording()`, `stopRecording()`, and a wall-clock `Timer.periodic` that ticks `RecordingState.duration` once per second. There is no pause/resume, no countdown, no hotkeys, no sleep handling. The recording pill (`packages/screen_recorder/lib/ui/bar/recording_pill.dart`) shows a red dot + elapsed time + a single Stop button.

A few useful facts from recon:
- `ScreenRecorderMethods` already declares `pauseRecording` and `resumeRecording` constants (Workstream D), but the Swift plugin has no matching cases — they're stubs.
- The macOS plugin already uses `NSEvent.addGlobalMonitorForEvents` (for cursor tracking), so the global-event pattern is proven.
- The settings screen exists but is thin — only WindowFrame controls. A new "Recording" section is welcome.
- No in-recording toast infrastructure exists; the pill renders inline with no overlay surface today.

## Decisions (from brainstorming)

- **All 5 features ship in v1.**
- **Pause semantics:** paused time is **excluded** from the output MP4. PTS is rebased on resume so the output reads as a single continuous clip.
- **Countdown duration:** user-configurable (0 / 3 / 5 seconds), default 3.
- **Global hotkeys:** fixed defaults — `Cmd+Shift+1` start, `Cmd+Shift+2` stop, `Cmd+Shift+P` pause-toggle. No remap UI, no disable toggle.
- **Hotkey scope:** system-wide. Carbon `RegisterEventHotKey` — no Accessibility permission needed for modified-key combos.
- **Sleep:** auto-pause on `willSleep`; on `didWake` show a modal asking Resume or Stop & Save with a 10 s default-to-Stop timeout.
- **Long-recording warnings:** in-app toasts at 30 and 60 min; modal at 90 min with 30 s default-to-Stop; hard auto-stop at 120 min with a final toast.

## System overview

```
                       ┌─────────────────────────┐
   Global hotkey ──────┤  RecordingActionRouter  │
   Pill button ────────┤  (start / stop / pause) │
   Sleep observer ─────┤                         │
                       └────────────┬────────────┘
                                    │
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
      CountdownController    RecordingController    LongRecordingWatcher
       (3 / 0 / 5 sec)       (start/pause/resume)   (30/60/90/120 min)
              │                     │                     │
              └─────── triggers ────▶─── observes ────────┘
                                    │
                                    ▼
                           Native pause/resume
                           (PTS rebase in writer)
```

A single `RecordingActionRouter` is the entry point for every "start / stop / pause" trigger — UI button, hotkey, sleep observer, long-recording watcher. It owns the countdown-before-start decision, the deny-sheet gate, and the status-dispatch logic for pause-vs-resume.

## Components

### 1. Native: pause/resume in `LiveRecordingWriter`
`packages/screen_recorder_macos/macos/Classes/`

Implement the existing stubs:
```swift
case "pauseRecording":
  liveRecordingWriter.pause()
  result(nil)
case "resumeRecording":
  liveRecordingWriter.resume()
  result(nil)
```

`LiveRecordingWriter.pause()` flips `isPaused = true` and stamps `pauseStart = CMClockGetTime(hostClock)`. While paused, the append path drops every incoming `CMSampleBuffer` (video, mic, system audio — all three tracks treat the same paused window).

`LiveRecordingWriter.resume()` adds `(now - pauseStart)` to a running `pausedOffset: CMTime`. Every sample's PTS is rebased on append: `sample.pts -= pausedOffset`. `AVAssetWriter` sees a continuous monotonic timeline with no gap → the output MP4 has the paused interval excluded.

Stop while paused: the writer's `finalize()` path first calls `resume()` (idempotent if already running) so the writer drains cleanly.

Dart-side additions on `ScreenRecorderPlatform`:
```dart
Future<void> pauseRecording() async {}
Future<void> resumeRecording() async {}
```
Both no-op on non-macOS.

### 2. Native: global hotkeys via Carbon
`packages/screen_recorder_macos/macos/Classes/HotkeyManager.swift` (new)

New method-channel methods on the plugin:
- `registerRecordingHotkeys` — installs three Carbon hotkeys with fixed IDs:
  | ID | Key | Modifiers |
  |---|---|---|
  | 1 | `kVK_ANSI_1` | cmd + shift |
  | 2 | `kVK_ANSI_2` | cmd + shift |
  | 3 | `kVK_ANSI_P` | cmd + shift |
- `unregisterRecordingHotkeys` — `UnregisterEventHotKey` on each ID.

A single `InstallEventHandler` on `kEventHotKeyPressed` dispatches by hotkey ID. Each press posts `{"action": "start" | "stop" | "pauseToggle"}` on the new EventChannel `com.slipreel.screen_recorder/hotkeys`.

If `RegisterEventHotKey` returns an error (combo conflicted), the native side logs and posts `{"event": "conflict", "id": N}` on the same channel. No user-facing surface in v1.

### 3. Native: sleep observer
`packages/screen_recorder_macos/macos/Classes/SleepObserver.swift` (new)

New method `startSleepObserver` (idempotent — second call is a no-op). The native side registers:
```swift
NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.willSleepNotification, ...)
NSWorkspace.shared.notificationCenter.addObserver(
  forName: NSWorkspace.didWakeNotification, ...)
```
Both fire on the EventChannel `com.slipreel.screen_recorder/sleep` carrying `{"event": "willSleep" | "didWake"}`.

Method-channel constants added: `registerRecordingHotkeys`, `unregisterRecordingHotkeys`, `startSleepObserver`. EventChannel constants added on `ScreenRecorderChannels`: `hotkeys`, `sleep`.

### 4. `RecordingController` extension
`packages/screen_recorder/lib/state/recording_state.dart`

```dart
enum RecordingStatus { idle, recording, paused, processing, completed, error }
```

New methods:
```dart
Future<void> pauseRecording() async {
  if (state.status != RecordingStatus.recording) return;
  _durationTimer?.cancel();
  await _platform.pauseRecording();
  state = state.copyWith(status: RecordingStatus.paused);
}

Future<void> resumeRecording() async {
  if (state.status != RecordingStatus.paused) return;
  await _platform.resumeRecording();
  _startDurationTimer();
  state = state.copyWith(status: RecordingStatus.recording);
}
```

The wall-clock `_durationTimer` is cancelled on pause and restarted on resume so `RecordingState.duration` does not advance during pause. `stopRecording` accepts both `recording` and `paused` as starting states.

### 5. `CountdownController` + `CountdownOverlay`
`packages/screen_recorder/lib/state/countdown_controller.dart` (new)
`packages/screen_recorder/lib/ui/widgets/countdown_overlay.dart` (new)

```dart
class CountdownState {
  final int remaining;   // seconds left; 0 means done
  final bool active;
}

class CountdownController extends StateNotifier<CountdownState> {
  Timer? _timer;
  VoidCallback? _onComplete;

  Future<void> run({required int seconds, required VoidCallback onComplete});
  void cancel();
}
```

`CountdownOverlay` renders inside the existing Slipreel bar/pill window (the bar window keeps its current size). For the countdown duration, the bar's existing source-picker contents are hidden and a centered "Recording in N…" display is shown with a `TweenAnimationBuilder` scale pulse on each second tick. The final "GO!" tick triggers `onComplete` and the overlay self-removes.

Two cancel paths: a `[Cancel]` button shown next to the number is always available; a `FocusableActionDetector` catches `Escape` when the Slipreel window has focus. The hotkey-initiated case (`Cmd+Shift+1` from another app) does not have focus by default, so the Cancel button is the documented escape hatch — `Cmd+Shift+2` (stop hotkey) also cancels by routing through `RecordingActionRouter.stop()` which knows the countdown is the active state.

The overlay is implemented as an `OverlayEntry` inserted into the bar window's `Overlay` (same pattern as `TipOverlay`). It subscribes to `countdownControllerProvider`; when `active == false` the entry is removed.

### 6. `RecordingSettingsStore` + Settings UI
`packages/screen_recorder/lib/state/recording_settings_store.dart` (new)
`packages/screen_recorder/lib/ui/screens/settings_screen.dart` (extend)

JSON sidecar at `getApplicationSupportDirectory()/recording_settings.json`:
```json
{ "countdownSeconds": 3 }
```
Default `3`. Same sidecar pattern as `motion_tuning.json` — deliberately not SharedPreferences because we'll be growing this object as more recording prefs land.

Settings screen gets a new "Recording" section above the existing WindowFrame block:

```
Recording
  Countdown       How long before recording starts.     [Off][3s][5s]
  Keyboard shortcuts
    ⌘⇧1 Start recording
    ⌘⇧2 Stop recording
    ⌘⇧P Pause / resume
```

The countdown segmented control writes through `recordingSettingsProvider` immediately on tap. Shortcuts are read-only documentation.

### 7. `RecordingActionRouter`
`packages/screen_recorder/lib/state/recording_action_router.dart` (new)

The single funnel every trigger goes through:
```dart
class RecordingActionRouter {
  Future<void> start(BuildContext ctx);   // honors countdown
  Future<void> stop();
  Future<void> pauseOrResume();           // dispatches by current status
}
```

`start()`:
1. If `countdownSeconds > 0`, run `CountdownController` then call `RecordingController.startRecording(…)`.
2. Otherwise call `RecordingController.startRecording(…)` directly.
3. The deny-sheet gate from sub-project B remains where it is (inside `RecordingController.startRecording`); the router just calls through it.

The `BuildContext` the router needs for the deny sheet is obtained from a `GlobalKey<NavigatorState>` registered in `MyApp` (`navigatorKey.currentContext`). The hotkey path (which has no natural context) uses this key. The bar-button path passes its own `BuildContext` directly.

`stop()` calls `RecordingController.stopRecording()`.

`pauseOrResume()` reads `RecordingState.status` and calls either `pauseRecording()` or `resumeRecording()`.

### 8. `HotkeyController`
`packages/screen_recorder/lib/state/hotkey_controller.dart` (new)

Riverpod controller. On construction (after onboarding completes — see Section "Lifecycle integration" below) it calls `_platform.registerRecordingHotkeys()` and subscribes to the `hotkeys` EventChannel. On each event:
- `start` → `routerProvider.start(rootContext)`
- `stop` → `routerProvider.stop()`
- `pauseToggle` → `routerProvider.pauseOrResume()`
- `conflict` → log via `AppLogger.platform`; do not surface

On dispose, `_platform.unregisterRecordingHotkeys()`.

### 9. `SleepObserver`
`packages/screen_recorder/lib/state/sleep_observer.dart` (new)

Riverpod consumer of the `sleep` EventChannel. Tracks `bool _pausedBySleep`.

- On `willSleep`: if `recording`, call `routerProvider.pauseOrResume()` and set `_pausedBySleep = true`.
- On `didWake`: if `paused && _pausedBySleep`, show `WakeModal` via the pill screen's `Overlay` and clear the flag.
- `_pausedBySleep` is also cleared on manual resume, stop, or modal dismissal.

### 10. `WakeModal`
`packages/screen_recorder/lib/ui/bar/wake_modal.dart` (new)

Parameterised modal reused for both the on-wake prompt and the 90-min prompt:
```dart
class WakeModal extends StatelessWidget {
  final String title;
  final String body;
  final String primaryLabel;
  final String secondaryLabel;
  final Duration autoStopAfter;
  final VoidCallback onPrimary;
  final VoidCallback onSecondary;
}
```

The header shows a small "Stopping in N s" countdown. Hover/touch on the modal cancels the auto-action. Default after timeout: invoke `onSecondary`.

| Caller | Title | Primary / Secondary | Auto-stop |
|---|---|---|---|
| Sleep observer (on wake) | "Welcome back" | Resume / Stop & save | 10 s |
| Long-recording watcher (90 min) | "Still recording?" | Continue recording / Stop & save | 30 s |

### 11. `LongRecordingWatcher` + `RecordingToast`
`packages/screen_recorder/lib/state/long_recording_watcher.dart` (new)
`packages/screen_recorder/lib/ui/bar/recording_toast.dart` (new)

```dart
static const _thresholds = [
  (Duration(minutes: 30), _ThresholdAction.toast30),
  (Duration(minutes: 60), _ThresholdAction.toast60),
  (Duration(minutes: 90), _ThresholdAction.modal90),
  (Duration(minutes: 120), _ThresholdAction.hardStop),
];
```

A root-scope `Provider` listens to `recordingControllerProvider` and tracks fired thresholds in an in-memory `Set`. On each duration tick, crosses → marks fired → dispatches:

- `toast30` / `toast60` → `RecordingToast.show(message)`
- `modal90` → push a `WakeModal` ("Still recording?" / "Continue recording" / "Stop & save", 30 s auto-stop)
- `hardStop` → `routerProvider.stop()` + a final toast "Recording capped at 2 hours and saved"

Fired set resets on `RecordingStatus.idle`.

`RecordingToast` is an `OverlayEntry` shown below the pill — same overlay infrastructure pattern as the tip system. Fade in 200 ms, hold 6 s, fade out 200 ms. Tap to dismiss early. No queue management: a second toast immediately replaces the first.

### 12. Onboarding `ReadyPage` extension
`packages/screen_recorder/lib/ui/screens/onboarding/pages/ready_page.dart` (edit)

Add a small read-only shortcuts card immediately above the existing CTA:
```
⌘⇧1   Start recording from anywhere
⌘⇧2   Stop
⌘⇧P   Pause / resume
```

Decoration only. No new file.

## Lifecycle integration

In `main()`:

1. After `tipsController.load()` (sub-project B's last init step), construct `RecordingSettingsStore`, load it, then construct `recordingSettingsController` and override its provider.
2. After all stores are ready, construct `HotkeyController` and `SleepObserver` — both register their native channels eagerly so hotkeys work even before the user opens the recording bar.
3. Both controllers are disposed in `MyApp.dispose()` (unregister hotkeys, cancel observer subs).

The hotkey + sleep observer wiring happens regardless of onboarding state — hotkeys must work even during onboarding (e.g. `Cmd+Shift+1` after onboarding finishes should Just Work without a relaunch).

## Data flow

```
User presses ⌘⇧1 in another app
       │
       ▼
Carbon InstallEventHandler → hotkeys EventChannel → HotkeyController
       │
       ▼
routerProvider.start(context)
       │
       ▼
countdownSeconds > 0 ? → CountdownController.run(3, onComplete: ...)
       │                       │
       │                       ▼
       │              CountdownOverlay shows 3 → 2 → 1
       │                       │
       │                       ▼
       └──────────▶ RecordingController.startRecording(...)
                              │
                              ▼ (sub-project B's gate stays here)
                       Permissions check / deny sheet
                              │
                              ▼
                       Native start → status = recording

User presses ⌘⇧P
       │
       ▼
hotkeys channel → HotkeyController → routerProvider.pauseOrResume()
       │
       ▼
RecordingController.pauseRecording() → native pause → status = paused
       │
       ▼
Pill renders Resume button; elapsed counter stops ticking

macOS sleeps
       │
       ▼
sleep channel → SleepObserver → routerProvider.pauseOrResume()
       │
       ▼
status was recording → pauseRecording; _pausedBySleep = true

macOS wakes
       │
       ▼
sleep channel → SleepObserver → status == paused && _pausedBySleep
       │
       ▼
WakeModal shown; 10 s auto-stop default

Recording crosses 30 min
       │
       ▼
LongRecordingWatcher → RecordingToast.show("Recording for 30 minutes")
```

## Error handling / edge cases

| Scenario | Behavior |
|---|---|
| `RegisterEventHotKey` conflict | Native logs + posts `{"event": "conflict", "id": N}`; Dart logs via `AppLogger.platform`. No user-facing surface in v1. |
| Pause called when status != recording | No-op (early-return guard). |
| Resume called when status != paused | No-op. |
| Stop called while paused | Native resumes briefly (idempotent) then finalizes; output is a single MP4 with paused-time excluded. |
| Countdown active when hotkey fires Stop | `CountdownController.cancel()` aborts before native start; status stays `idle`. |
| Countdown active when hotkey fires Pause | No-op (status is `idle`). |
| Sleep observer fires `willSleep` when not recording | No-op. |
| Sleep observer fires `didWake` while we never paused for sleep | `_pausedBySleep` false → no modal. |
| User manually resumes before wake modal could show | `_pausedBySleep` cleared; modal never shown. |
| 90-min modal showing while user backgrounds Slipreel | Modal stays; auto-stop timer keeps running. Safe default. |
| 2-hour hard-stop while a toast is visible | Toast immediately replaced by the 2-hour "capped" toast; stop proceeds. |
| App killed during pause | Sub-project C territory — partial file on disk + recovery on next launch. |
| User changes countdown setting mid-countdown | The running countdown uses the value captured at start; the new value applies to the next start. |

## Testing

**Unit / state:**
- `countdown_controller_test.dart` — runs to completion fires `onComplete`; `cancel()` mid-flight does not; running while already active is a no-op.
- `recording_controller_pause_test.dart` — `pauseRecording` flips status to `paused` only when currently `recording`; `resumeRecording` flips back; `stopRecording` from `paused` works; `_durationTimer` is cancelled on pause and restarted on resume.
- `recording_action_router_test.dart` — `start()` skips countdown when `countdownSeconds == 0`; honors it otherwise; routes to deny sheet via the existing permissions gate; `pauseOrResume()` dispatches correctly.
- `long_recording_watcher_test.dart` — pump duration through each threshold; assert correct action per threshold; assert reset on stop.
- `sleep_observer_test.dart` — fake the sleep channel; assert pause-on-sleep only when recording; assert `_pausedBySleep` flag flow.
- `hotkey_controller_test.dart` — fake the hotkeys channel; assert each action routes to the right router method; assert conflict events are logged not surfaced.
- `recording_settings_store_test.dart` — fresh load returns default 3; round-trip persists `countdownSeconds`; corrupt JSON falls back to default.

**Widget:**
- `countdown_overlay_test.dart` — renders the current value; Esc dismisses; tap on Cancel dismisses; auto-hides when `active == false`.
- `recording_pill_test.dart` — Pause button visible when `recording`; Resume visible when `paused`; elapsed counter does not tick during pause; status icon swaps (pulsing red ↔ static grey).
- `wake_modal_test.dart` — auto-stop fires after the configured timeout; hover cancels auto-stop; primary/secondary buttons call their callbacks.
- `recording_toast_test.dart` — 6-second auto-dismiss; replacement when a second toast is shown.

**Manual / on-device:**
1. Cmd+Shift+1 from another app → countdown overlays → recording starts.
2. Cmd+Shift+P toggles pause/resume on the pill; elapsed counter pauses too.
3. macOS Settings → Energy → "Put display to sleep" 1 min, start recording, wait → wake → modal appears with the auto-stop countdown.
4. Long-form recording: jump duration via the Flutter dev menu (or wait); confirm toasts + 90-min modal + 2-hour hard stop fire correctly.
5. Settings → Recording → toggle countdown between Off / 3s / 5s; verify each next recording honors the new value.

## Out of scope

- **Hotkey remap UI** — fixed defaults only in v1.
- **Hotkey conflict surface** — native logs only; no UI banner.
- **Per-source countdown** — same countdown for Display/Window/Area/Device.
- **Configurable warning thresholds** — 30/60/90/120 are baked in.
- **Resume-after-crash from paused state** — sub-project C.
- **Cross-platform** — macOS only; Win/Linux remain no-op.
- **Pause/resume telemetry** — none.

## Success criteria

- Cmd+Shift+1 starts a recording from any focused app; with the default 3 s countdown the user sees the overlay and the captured clip starts after "GO!".
- Cmd+Shift+P during recording pauses; pressing again resumes. The output MP4 has the paused interval excluded — playback is seamless.
- Cmd+Shift+2 stops both from `recording` and from `paused` and produces a finalized MP4.
- macOS sleep mid-recording auto-pauses; on wake a modal asks Resume vs Stop & Save and defaults to Stop after 10 s.
- 30 min and 60 min toasts appear inline below the pill; 90 min shows a modal with a 30 s default-to-Stop; 120 min auto-stops with a final toast.
- Settings → Recording → Countdown control writes through and takes effect next start.
- `melos run analyze --no-select` clean (no new findings); `melos run test --no-select` green; manual checks above pass on a real Mac.
