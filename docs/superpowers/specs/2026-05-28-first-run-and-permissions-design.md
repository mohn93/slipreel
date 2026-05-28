# First-run and permissions (sub-project B)

**Date:** 2026-05-28
**Status:** Approved (design)
**Scope:** Add first-launch onboarding, a Dart-side permission status surface that lights up the existing native probes, an on-demand "permission denied → open System Settings" sheet, and a 5-tip contextual coachmark system for first-time editor surfaces.

## Background

Slipreel today boots straight to `RecordingBarScreen` with no permission checks, no first-run flag, and no UI consequence when a permission is denied. The macOS native side already implements all three relevant probes — Screen Recording (`SCShareableContent`), Microphone (`AVCaptureDevice.requestAccess(for:.audio)`), Accessibility (`AXIsProcessTrustedWithOptions`) — but errors from the native layer are only logged. `url_launcher` and `shared_preferences` are already declared in `pubspec.yaml`; `url_launcher` is unused.

This sub-project is one of five that came out of the 2026-05-28 backlog brainstorm; the others (A: in-recording UX, C: crash recovery, D: click auto-zoom, E: distribution) are out of scope here.

## Decisions (from brainstorming)

- **Three sub-features in scope:** onboarding, permission-denied deep link, contextual tips.
- **Permissions covered:** Screen Recording, Microphone, Accessibility (all three).
- **Onboarding length:** 3 screens (Welcome → Permissions → Ready). No quick-tour pager; tour lives in contextual tips.
- **Deny handling in onboarding:** Screen Recording is a hard gate (Continue disabled until granted). Microphone and Accessibility are skippable.
- **Post-onboarding deny surface:** on-demand only — sheet appears where the user tries to do the thing. No persistent banner.
- **Tip format:** anchored coachmark with arrow + dim backdrop + Got-it button. One tip per surface (not bundled tour, not recording-count-driven).
- **Tip triggers:** first time the relevant surface is encountered; persisted per tip id.

## Components

### 1. `PermissionsController` (Dart side of the bus)
`packages/screen_recorder/lib/state/permissions_controller.dart`

```dart
enum PermissionKind { screenRecording, microphone, accessibility }
enum PermissionStatus { granted, denied, notDetermined, restricted, unsupported }

class PermissionsSnapshot {
  final Map<PermissionKind, PermissionStatus> byKind;
  PermissionStatus get screenRec     => byKind[PermissionKind.screenRecording]!;
  PermissionStatus get microphone    => byKind[PermissionKind.microphone]!;
  PermissionStatus get accessibility => byKind[PermissionKind.accessibility]!;
}

class PermissionsController extends StateNotifier<PermissionsSnapshot> {
  PermissionsController(this._platform);
  final ScreenRecorderPlatform _platform;

  Future<void> refreshAll();
  Future<PermissionStatus> request(PermissionKind);
}
```

Behavior:
- Single source of truth for permission state across onboarding, the deny sheet, and any future feature.
- `refreshAll()` runs once during app init (before `runApp`) so initial routing has a real snapshot.
- A `WidgetsBindingObserver` registered in `MyApp.initState` calls `refreshAll()` on `AppLifecycleState.resumed` — covers System Settings round-trips.
- On non-macOS, all kinds resolve to `unsupported`. The controller is a no-op; tests can still drive it.

### 2. Platform interface additions
`packages/screen_recorder_platform_interface/lib/`

Add three methods (and matching method-channel constants in `ScreenRecorderMethods`):
- `checkScreenRecordingPermission() → PermissionStatus`
- `checkMicrophonePermission() → PermissionStatus`
- `checkAccessibilityPermission() → PermissionStatus`

The macOS plugin already has the Swift implementations for all three; this exposes them through the federated interface. Win/Linux implementations return `unsupported`.

Also expose three `requestXxxPermission()` counterparts that wrap the existing native request methods. (Screen Rec and Mic already have native request methods; Accessibility's "request" is just a System Settings deep link plus a re-check on resume.)

### 3. `OnboardingStore`
`packages/screen_recorder/lib/onboarding/onboarding_store.dart`

Thin wrapper around `SharedPreferences`. Single key `'slipreel.onboarding_complete' : bool`. Methods: `load()`, `markComplete()`, `reset()` (used by the VM-service reset extension).

### 4. `OnboardingScreen`
`packages/screen_recorder/lib/ui/screens/onboarding/onboarding_screen.dart`
`packages/screen_recorder/lib/ui/screens/onboarding/pages/{welcome,permissions,ready}_page.dart`

Three-page `PageView` with a header dot indicator. No swipe gesture — the only way forward is a button on each page.

**Page 1 — Welcome:** hero, brand, single CTA `[Get started]` → page 2.

**Page 2 — Permissions:** three rows. Each row shows current status + a single action button driven by the status:

| Status | Screen Rec row | Mic row | Accessibility row |
|---|---|---|---|
| `notDetermined` | `[Grant]` → `request()` | `[Grant]` → `request()` | `[Grant]` → `request()` |
| `denied` | `[Open System Settings]` deep link | `[Open System Settings]` or `[Skip]` | `[Open System Settings]` or `[Skip]` |
| `granted` | ✓ check | ✓ check | ✓ check |
| `restricted` | same as `denied` | same as `denied` | same as `denied` |

The page subscribes to `PermissionsController`; rows re-render automatically on resume.

`[Continue]` button at the bottom enabled iff `screenRec == granted`. There is no persisted "skipped" flag for Mic/Accessibility — checks at action time always re-probe live OS state.

**Page 3 — Ready:** `[Record my first video]` → flips `onboarding_complete = true` → `Navigator.pushReplacement` to `RecordingBarScreen`.

### 5. Routing
`packages/screen_recorder/lib/main.dart`

In `main()`, after loading `OnboardingStore` (same place we already load `MotionTuningStore`):
```dart
final onboardingDone = await onboardingStore.load();
runApp(ProviderScope(
  overrides: [
    onboardingStoreProvider.overrideWithValue(onboardingStore),
    // ... existing overrides ...
  ],
  child: MyApp(onboardingDone: onboardingDone),
));
```

`MyApp` picks home:
```dart
home: onboardingDone ? const RecordingBarScreen() : const OnboardingScreen(),
```

Quitting mid-onboarding leaves the flag false; cold launch returns to Welcome. We do not persist partial progress.

### 6. `PermissionDeniedSheet`
`packages/screen_recorder/lib/ui/widgets/permission_denied_sheet.dart`

Reusable `showModalBottomSheet`-based widget with copy + System Settings URL parameterized by `PermissionKind`:

```dart
static const _urls = {
  PermissionKind.screenRecording:
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
  PermissionKind.microphone:
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone',
  PermissionKind.accessibility:
    'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility',
};

static Future<void> show(BuildContext, PermissionKind);
```

Layout: title + 2-3 line "why we need this" body + two buttons:
- Primary `[Open System Settings]` → `url_launcher.launchUrl(_urls[kind])` then dismiss.
- Secondary `[Not now]` → dismiss.

Call sites (the only behavior change to existing code):

| Trigger | Existing file | Condition | Kind |
|---|---|---|---|
| User presses Display/Window/Area/Device to start capture | `lib/state/recording_controller.dart` (top of `startRecording`) | `screenRec != granted` | `screenRecording` |
| User toggles Mic on in the source picker | `lib/ui/bar/_AvPlaceholder` (and the mic source picker) | `microphone != granted` | `microphone` |
| Future: accessibility-needing feature | (none today; declared for sub-project D) | `accessibility != granted` | `accessibility` |

The `recording_controller.dart` change is a single guard at the top of `startRecording()`: read `PermissionsController` snapshot, short-circuit to the sheet if denied. Everything else is new code.

### 7. Contextual tips system

**Files:**
- `packages/screen_recorder/lib/onboarding/tips_store.dart` — `SharedPreferences` wrapper holding `Set<String>` under key `'slipreel.tips_seen'`. Tip ids are persisted as `TipId.name` strings so renaming the enum value is a migration, not a silent data drop.
- `packages/screen_recorder/lib/onboarding/tips_controller.dart` — Riverpod controller exposing `shouldShow(tipId)` and `markSeen(tipId)`, plus a single-slot "currently visible" field for queuing.
- `packages/screen_recorder/lib/onboarding/tip_anchor.dart` — widget wrapper with a `GlobalKey`.
- `packages/screen_recorder/lib/onboarding/tip_overlay.dart` — coachmark renderer.

Anchor usage:
```dart
TipAnchor(
  tipId: TipId.editorTrimHandles,
  message: 'Drag these to trim the start and end of your clip.',
  child: TrimHandle(...),
)
```

`TipAnchor` on first frame after layout:
1. Early-exits if its `RenderObject` is not attached or has zero size (e.g. anchor is inside an off-screen tab).
2. Asks `TipsController.shouldShow(tipId)` — early-exits if already seen.
3. If shows and no other tip is currently visible, inserts an `OverlayEntry` into the root `Overlay` rendering `TipOverlay(anchorRect, message)`.

`TipOverlay` paints: full-screen dim backdrop (60% black) with a rectangular cutout around `anchorRect`, then a callout bubble with an arrow pointing at the cutout, then a single `[Got it]` button → marks tip seen → removes the overlay.

**Single-tip queue:** `TipsController` tracks the currently visible tip id. Anchors that try to fire while another tip is on-screen are no-ops on that frame; on the next time the user enters that screen, they re-fire (and by then the seen flag may have flipped).

**The 5 registered tips:**

| Tip id | Surface | Anchor target | Copy |
|---|---|---|---|
| `TipId.barModePicker` | Recording bar | Display button | "Pick a capture mode: Display, Window, Area, or a connected Device." |
| `TipId.editorTrimHandles` | Editor timeline | A trim handle | "Drag these to trim the start and end of your clip." |
| `TipId.editorZoomKeyframe` | Editor timeline | Zoom track | "Tap the timeline to add a smooth zoom keyframe." |
| `TipId.editorInspector` | Editor right pane | Inspector tab strip | "Customize cursor, background, frame, and motion here." |
| `TipId.editorExport` | Editor toolbar | Export button | "Cmd+E to export with smart presets." |

Tip ids live in an `enum TipId`; copy lives in one `Map<TipId, String>` in `tips_controller.dart`. Adding/removing a tip is one enum entry + one map entry + one `TipAnchor` placement.

### 8. QA reset hook
A dev-only VM-service extension `ext.slipreel.resetOnboarding` (registered alongside the existing `ext.slipreel.*` family in `main.dart`) calls `OnboardingStore.reset()` and `TipsStore.clearAll()`. Lets us drive the full first-run flow via flutter-qa without uninstalling the app.

## Data flow

```
Cold launch
   │
   ▼
main():
  onboardingStore.load() ──► onboardingDone:bool
  permissionsController.refreshAll() ──► PermissionsSnapshot
   │
   ▼
MyApp.home = onboardingDone ? RecordingBarScreen : OnboardingScreen

App resumed (from System Settings round-trip):
   │
   ▼
WidgetsBindingObserver → permissionsController.refreshAll()
   │
   ▼
Onboarding rows / deny-sheet status re-render.

User clicks Record (after onboarding) with Screen Rec denied:
   │
   ▼
RecordingController.startRecording() reads permissionsController →
   denied → PermissionDeniedSheet.show(context, screenRecording)
   → user taps [Open System Settings] → url_launcher → System Settings opens
   → user grants → System Settings remains open → user switches back to Slipreel
   → resumed → refreshAll → status flips to granted
   → user clicks Record again → startRecording proceeds.

User opens editor for the first time:
   │
   ▼
TipAnchor(editorTrimHandles) mounts → shouldShow=true → TipOverlay inserted
   → user dismisses → markSeen → next mount is a no-op.
```

## Error handling / edge cases

| Scenario | Behavior |
|---|---|
| `url_launcher` fails to open System Settings | Sheet stays open with inline error: "Couldn't open System Settings. Open Privacy & Security manually." No retry loop. |
| TCC quirk where granted but capture still fails (stale grant) | Permissions row shows ✓ when OS reports `granted`. If capture still fails at the action site, deny sheet re-surfaces there. We don't try to detect stale grants. |
| `PermissionsController.refreshAll()` throws | Treat as `notDetermined` for all kinds; log via `AppLogger.platform.e(...)`. Onboarding still renders. |
| Tip's anchor lives inside a sub-route or tab the user hasn't opened yet | Flutter doesn't `build` un-mounted subtrees, so the `TipAnchor` simply doesn't run until the user opens that surface. For anchors that are mounted-but-clipped (scrolled out of view), we additionally gate on `RenderBox.attached && hasSize` — the anchor fires the first frame both are true. |
| Two `TipAnchor`s with the same id mounted at once | `TipsController` is single source of truth; first fire wins, others early-exit. |
| `OnboardingStore.markComplete()` write fails | `SnackBar`: "Couldn't save onboarding state — you may see this screen again next launch." User can still proceed; nothing destructive. |
| App killed while deny sheet is open | Sheet is ephemeral UI state. Next launch only re-shows the sheet if the user retries the action. |
| `Platform.isMacOS == false` (tests, future Win/Linux) | All statuses `unsupported`. Routing treats `unsupported` as "don't gate" so onboarding Continue is enabled. Deny-sheet call sites short-circuit when `unsupported`. |

## Testing

**Unit / state:**
- `permissions_controller_test.dart` — fake `ScreenRecorderPlatform`; status transitions and `AppLifecycleState.resumed` triggers `refreshAll()`.
- `onboarding_store_test.dart` — round-trip via `SharedPreferences.setMockInitialValues`.
- `tips_store_test.dart` — same for the seen set.
- `tips_controller_test.dart` — `shouldShow` returns true once; false after `markSeen`; second anchor while one is visible is queued, not concurrent.

**Widget:**
- `onboarding_screen_test.dart` — Continue disabled when `screenRec != granted`; enabled when granted; Skip on Mic/Accessibility advances the page state without granting; completing flow flips the flag.
- `permission_denied_sheet_test.dart` — renders correct copy per `PermissionKind`; `[Open System Settings]` invokes `url_launcher` with the correct URL (mock `UrlLauncherPlatform`).
- `tip_overlay_test.dart` — anchor inserts overlay on first appearance; `[Got it]` dismisses + marks seen; anchor with already-seen id never inserts; off-screen anchor does not insert until visible.

**Manual checks (on a real Mac, post-merge):**
1. Reset via `ext.slipreel.resetOnboarding`: full onboarding renders; granting each permission flips its row to ✓.
2. Revoke Screen Rec in System Settings after onboarding; try to start a recording → deny sheet appears with the correct URL.
3. Open editor for the first time → trim/zoom/inspector/export tips surface one at a time as user touches each surface; reload app → tips do not return.

## Out of scope

- Win/Linux permission handling — the architecture supports it via `unsupported`, but no implementation here.
- Re-onboarding on app upgrade — flag is sticky; no "new feature tour" mechanism in v1.
- Granular per-capability tour — only the 5 registered tips; no tip-authoring DSL.
- Telemetry on tip dismissal / onboarding drop-off — no analytics layer in this sub-project.
- Animated "permission needed" arrow pointing at the menu bar.
- Custom System Settings panes for older macOS — we ship with macOS 13+ `x-apple.systempreferences:` URLs only.

## Success criteria

- Cold launch with no prior state shows the 3-screen onboarding; granting all three permissions and clicking [Record my first video] lands on `RecordingBarScreen` with `onboarding_complete=true`.
- Cold launch with `onboarding_complete=true` skips onboarding and lands directly on `RecordingBarScreen`.
- Revoking Screen Rec in System Settings and clicking Record from the bar pops `PermissionDeniedSheet(screenRecording)` with a working "Open System Settings" deep link.
- First time each of the 5 registered tip surfaces is entered, its coachmark fires; second time, it does not.
- App runs cleanly on macOS, all permissions-related code paths exercise `unsupported` on non-macOS (covered by tests), no regression to existing recording or editor flows.
- `melos run analyze --no-select` clean; full suite green.
