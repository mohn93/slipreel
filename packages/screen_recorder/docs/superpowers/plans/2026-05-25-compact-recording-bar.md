# Compact Recording Bar Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the full-window source-picker screen with a slim floating, always-on-top control bar that morphs (bar → pill → panel) and starts recording from a native click-to-select overlay painted on the real desktop windows/screens.

**Architecture:** A single Flutter window changes shape via an app-level `slipreel/window` method channel handled in the macOS Runner (`MainFlutterWindow.swift`). Flutter drives it through a `WindowModeController` (Riverpod `StateNotifier`) over a testable `WindowChrome` seam. The bar/pill are pure Flutter widgets; Recents/Settings/editor are existing screens shown by morphing the window to a normal panel via standard `Navigator.push`. Window/Display source selection is a **native** overlay (one borderless transparent `NSWindow` per `NSScreen`, modeled on the existing `RegionSelector`) that returns the chosen source over a new `pickSource` platform method; pure geometry (coordinate conversion + topmost hit-test) is extracted and unit-tested.

**Tech Stack:** Flutter 3.41.5 (FVM), Riverpod (`StateNotifier`), `flutter_test` + `MockPlatformInterfaceMixin` + `TestDefaultBinaryMessengerBinding`, Swift/AppKit/ScreenCaptureKit, XCTest.

---

## Conventions

- **Flutter binary:** `/Users/mohn93/fvm/default/bin/flutter` (referred to as `$FLUTTER` below).
- **Run one Flutter test file:** `$FLUTTER test <path>` (run from repo root `/Users/mohn93/Desktop/side_projects/screenflow_studio`).
- **Run a package suite:** `$FLUTTER test packages/screen_recorder/test`.
- **Run Swift tests:** from `packages/screen_recorder_macos/example`:
  `xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' 2>&1 | grep -E "(TEST SUCCEEDED|TEST FAILED|error:)"`
- **Branch:** all work on a feature branch (e.g. `feat/compact-recording-bar`), not `main`.
- The native overlay **NSView/NSWindow glue is not unit-tested** (consistent with the repo: only `RegionSelectorState`/`SourceCatalog` logic is tested, not `RegionSelectorView`). Its correctness is verified by running the app. All *pure* native logic IS unit-tested.

## File Structure

**Flutter — `packages/screen_recorder/lib`**
- `state/window_mode.dart` — `enum WindowMode { bar, pill, panel }` + `abstract class WindowChrome { Future<void> setMode(WindowMode) }`.
- `platform/window_chrome_channel.dart` — `MethodChannelWindowChrome implements WindowChrome` over `MethodChannel('slipreel/window')`.
- `state/window_mode_controller.dart` — `WindowModeController extends StateNotifier<WindowMode>` + `windowModeControllerProvider`.
- `ui/bar/elapsed_format.dart` — pure `String formatElapsed(Duration)`.
- `ui/bar/recording_pill.dart` — `RecordingPill` widget.
- `ui/bar/recording_bar.dart` — `RecordingBar` widget (✕, modes, disabled A/V, gear menu).
- `ui/bar/recording_bar_screen.dart` — `RecordingBarScreen` orchestrator (the new `home:`).
- `main.dart` — swap `home:` to `RecordingBarScreen`, provide the chrome.
- `ui/screens/settings_screen.dart` — add the "Show all windows" strict-filter setting.

**Platform interface — `packages/screen_recorder_platform_interface/lib`**
- `src/models/picked_source.dart` — `PickedSource { RecordingSource kind; String id }`.
- `src/constants.dart` — add `pickSource` method name.
- `src/screen_recorder_platform_interface.dart` — add `Future<PickedSource?> pickSource(RecordingSource)`.
- `lib/screen_recorder_platform_interface.dart` — export the new model.

**macOS plugin — `packages/screen_recorder_macos`**
- `lib/screen_recorder_macos_method_channel.dart` — implement `pickSource`.
- `macos/Classes/SourcePickerGeometry.swift` — pure helpers (tested).
- `macos/Classes/SourcePickerOverlay.swift` — overlay manager (modeled on `RegionSelector`).
- `macos/Classes/SourcePickerView.swift` — per-screen drawing/mouse view.
- `macos/Classes/ScreenRecorderMacosPlugin.swift` — dispatch `pickSource`.
- `example/macos/RunnerTests/SourcePickerGeometryTests.swift` — XCTest.

**App Runner — `packages/screen_recorder/macos/Runner`**
- `MainFlutterWindow.swift` — register `slipreel/window`, implement `setMode`, allow borderless key window.

---

## Task 1: WindowMode enum + WindowChrome seam

**Files:**
- Create: `packages/screen_recorder/lib/state/window_mode.dart`

- [ ] **Step 1: Create the enum + seam (no test — pure declarations)**

```dart
// packages/screen_recorder/lib/state/window_mode.dart

/// The three shapes the single app window can take.
enum WindowMode {
  /// Small, borderless, always-on-top, draggable bar (default / idle).
  bar,

  /// Tiny borderless pill shown while recording.
  pill,

  /// Normal resizable window for Recents / Settings / the editor.
  panel,
}

/// Seam over the native window-morphing channel so the controller is
/// unit-testable without a live method channel.
abstract class WindowChrome {
  Future<void> setMode(WindowMode mode);
}
```

- [ ] **Step 2: Commit**

```bash
git add packages/screen_recorder/lib/state/window_mode.dart
git commit -m "feat(bar): WindowMode enum + WindowChrome seam"
```

---

## Task 2: WindowModeController

**Files:**
- Create: `packages/screen_recorder/lib/state/window_mode_controller.dart`
- Test: `packages/screen_recorder/test/state/window_mode_controller_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/window_mode_controller_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';

class _FakeChrome implements WindowChrome {
  final List<WindowMode> calls = [];
  @override
  Future<void> setMode(WindowMode mode) async => calls.add(mode);
}

void main() {
  test('starts in bar mode without touching chrome', () {
    final chrome = _FakeChrome();
    final c = WindowModeController(chrome);
    expect(c.state, WindowMode.bar);
    expect(chrome.calls, isEmpty);
  });

  test('showPill / showPanel / showBar set state and call chrome once each',
      () async {
    final chrome = _FakeChrome();
    final c = WindowModeController(chrome);

    await c.showPill();
    expect(c.state, WindowMode.pill);

    await c.showPanel();
    expect(c.state, WindowMode.panel);

    await c.showBar();
    expect(c.state, WindowMode.bar);

    expect(chrome.calls,
        [WindowMode.pill, WindowMode.panel, WindowMode.bar]);
  });

  test('repeating the current mode is a no-op (no duplicate chrome call)',
      () async {
    final chrome = _FakeChrome();
    final c = WindowModeController(chrome);
    await c.showBar(); // already bar
    expect(chrome.calls, isEmpty);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder/test/state/window_mode_controller_test.dart`
Expected: FAIL — `window_mode_controller.dart` / `WindowModeController` not found.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/state/window_mode_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'window_mode.dart';

/// Single source of truth for the window's shape. Setting a mode updates
/// state and asks the native chrome to resize/restyle the window. Repeating
/// the current mode is a no-op so listeners and the native side aren't
/// churned needlessly.
class WindowModeController extends StateNotifier<WindowMode> {
  WindowModeController(this._chrome) : super(WindowMode.bar);

  final WindowChrome _chrome;

  Future<void> _set(WindowMode mode) async {
    if (state == mode) return;
    state = mode;
    await _chrome.setMode(mode);
  }

  Future<void> showBar() => _set(WindowMode.bar);
  Future<void> showPill() => _set(WindowMode.pill);
  Future<void> showPanel() => _set(WindowMode.panel);
}

/// Overridden in `main.dart` with a real [WindowChrome]. The default throws
/// so a missing override is caught immediately rather than silently no-op.
final windowChromeProvider = Provider<WindowChrome>((ref) {
  throw UnimplementedError('windowChromeProvider must be overridden in main()');
});

final windowModeControllerProvider =
    StateNotifierProvider<WindowModeController, WindowMode>(
  (ref) => WindowModeController(ref.watch(windowChromeProvider)),
);
```

- [ ] **Step 4: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder/test/state/window_mode_controller_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/window_mode_controller.dart packages/screen_recorder/test/state/window_mode_controller_test.dart
git commit -m "feat(bar): WindowModeController with chrome seam"
```

---

## Task 3: MethodChannelWindowChrome (Dart side of the window channel)

**Files:**
- Create: `packages/screen_recorder/lib/platform/window_chrome_channel.dart`
- Test: `packages/screen_recorder/test/platform/window_chrome_channel_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/platform/window_chrome_channel_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/platform/window_chrome_channel.dart';
import 'package:screen_recorder/state/window_mode.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('slipreel/window');
  final log = <MethodCall>[];

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return null;
    });
    log.clear();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('setMode sends setMode with the mode name', () async {
    final chrome = MethodChannelWindowChrome();
    await chrome.setMode(WindowMode.panel);
    expect(log, hasLength(1));
    expect(log.single.method, 'setMode');
    expect(log.single.arguments, {'mode': 'panel'});
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder/test/platform/window_chrome_channel_test.dart`
Expected: FAIL — `window_chrome_channel.dart` not found.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/platform/window_chrome_channel.dart
import 'package:flutter/services.dart';

import '../state/window_mode.dart';

/// Real [WindowChrome] backed by the app-level `slipreel/window` channel
/// handled in `macos/Runner/MainFlutterWindow.swift`.
class MethodChannelWindowChrome implements WindowChrome {
  static const _channel = MethodChannel('slipreel/window');

  @override
  Future<void> setMode(WindowMode mode) async {
    await _channel.invokeMethod<void>('setMode', {'mode': mode.name});
  }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder/test/platform/window_chrome_channel_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/platform/window_chrome_channel.dart packages/screen_recorder/test/platform/window_chrome_channel_test.dart
git commit -m "feat(bar): MethodChannelWindowChrome over slipreel/window"
```

---

## Task 4: Native window morphing (Runner)

**Files:**
- Modify: `packages/screen_recorder/macos/Runner/MainFlutterWindow.swift`

This native glue is verified by running the app (Task 13), not by a unit test.

- [ ] **Step 1: Replace `MainFlutterWindow.swift` with the morphing version**

```swift
// packages/screen_recorder/macos/Runner/MainFlutterWindow.swift
import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Bar/pill are borderless; borderless windows refuse key/main unless we
  // opt in, which the bar needs to receive clicks (gear menu, mode buttons).
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Transparent so the Flutter-drawn rounded bar shows without black
    // corners. Flutter paints its own background.
    flutterViewController.backgroundColor = .clear

    let channel = FlutterMethodChannel(
      name: "slipreel/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setMode",
            let args = call.arguments as? [String: Any],
            let mode = args["mode"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.applyMode(mode)
      result(nil)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Start as the bar.
    applyMode("bar")

    super.awakeFromNib()
  }

  private func applyMode(_ mode: String) {
    switch mode {
    case "bar":
      configureFloating(width: 760, height: 64)
    case "pill":
      configureFloating(width: 168, height: 48)
    case "panel":
      configurePanel(width: 1100, height: 720)
    default:
      break
    }
  }

  private func configureFloating(width: CGFloat, height: CGFloat) {
    styleMask = [.borderless]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    setContentSize(NSSize(width: width, height: height))
    positionTopCenter(width: width, height: height)
    makeKeyAndOrderFront(nil)
  }

  private func configurePanel(width: CGFloat, height: CGFloat) {
    styleMask = [.titled, .closable, .miniaturizable, .resizable]
    isOpaque = true
    backgroundColor = .windowBackgroundColor
    hasShadow = true
    level = .normal
    isMovableByWindowBackground = false
    collectionBehavior = [.fullScreenPrimary]
    setContentSize(NSSize(width: width, height: height))
    center()
    makeKeyAndOrderFront(nil)
  }

  private func positionTopCenter(width: CGFloat, height: CGFloat) {
    guard let screen = NSScreen.main else { return }
    let vf = screen.visibleFrame
    let x = vf.midX - width / 2
    let y = vf.maxY - height - 24 // 24px below the menu bar
    setFrameOrigin(NSPoint(x: x, y: y))
  }
}
```

- [ ] **Step 2: Build the macOS app to confirm it compiles**

Run: `$FLUTTER build macos --debug` (from `packages/screen_recorder`)
Expected: build succeeds (no Swift errors). Runtime behavior is verified in Task 13.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/macos/Runner/MainFlutterWindow.swift
git commit -m "feat(bar): native window morphing (bar/pill/panel) via slipreel/window"
```

---

## Task 5: Elapsed-time formatter

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/elapsed_format.dart`
- Test: `packages/screen_recorder/test/ui/bar/elapsed_format_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/bar/elapsed_format_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/elapsed_format.dart';

void main() {
  test('formats as m:ss with zero-padded seconds, uncapped minutes', () {
    expect(formatElapsed(Duration.zero), '0:00');
    expect(formatElapsed(const Duration(seconds: 5)), '0:05');
    expect(formatElapsed(const Duration(seconds: 14)), '0:14');
    expect(formatElapsed(const Duration(seconds: 65)), '1:05');
    expect(formatElapsed(const Duration(minutes: 10, seconds: 5)), '10:05');
    expect(formatElapsed(const Duration(minutes: 75)), '75:00');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/elapsed_format_test.dart`
Expected: FAIL — `elapsed_format.dart` not found.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/bar/elapsed_format.dart

/// Formats a recording duration as `m:ss` (minutes uncapped, seconds
/// zero-padded). Used by the recording pill timer.
String formatElapsed(Duration d) {
  final totalSeconds = d.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '$minutes:${seconds.toString().padLeft(2, '0')}';
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/elapsed_format_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/elapsed_format.dart packages/screen_recorder/test/ui/bar/elapsed_format_test.dart
git commit -m "feat(bar): elapsed-time m:ss formatter"
```

---

## Task 6: RecordingPill widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/recording_pill.dart`
- Test: `packages/screen_recorder/test/ui/bar/recording_pill_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/bar/recording_pill_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_pill.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('shows the elapsed time as m:ss', (tester) async {
    await tester.pumpWidget(wrap(
      const RecordingPill(elapsed: Duration(seconds: 65), onStop: _noop),
    ));
    expect(find.text('1:05'), findsOneWidget);
  });

  testWidgets('tapping stop fires onStop', (tester) async {
    var stopped = false;
    await tester.pumpWidget(wrap(
      RecordingPill(elapsed: Duration.zero, onStop: () => stopped = true),
    ));
    await tester.tap(find.byKey(const Key('pill-stop')));
    expect(stopped, isTrue);
  });
}

void _noop() {}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/recording_pill_test.dart`
Expected: FAIL — `recording_pill.dart` not found.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/bar/recording_pill.dart
import 'package:flutter/material.dart';

import 'elapsed_format.dart';

/// The window collapses to this while recording: a pulsing red dot, the
/// elapsed time, and a stop button. Pure presentation.
class RecordingPill extends StatelessWidget {
  const RecordingPill({super.key, required this.elapsed, required this.onStop});

  final Duration elapsed;
  final VoidCallback onStop;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF2C2C30),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: const [
          BoxShadow(color: Colors.black45, blurRadius: 18, offset: Offset(0, 6)),
        ],
      ),
      padding: const EdgeInsets.fromLTRB(14, 7, 8, 7),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: const BoxDecoration(
              color: Color(0xFFE5484D),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            formatElapsed(elapsed),
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.w600,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            key: const Key('pill-stop'),
            tooltip: 'Stop recording',
            onPressed: onStop,
            icon: const Icon(Icons.stop_rounded),
            color: Colors.white,
            style: IconButton.styleFrom(
              backgroundColor: const Color(0xFFE5484D),
              minimumSize: const Size(30, 30),
              padding: EdgeInsets.zero,
            ),
          ),
        ],
      ),
    );
  }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/recording_pill_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_pill.dart packages/screen_recorder/test/ui/bar/recording_pill_test.dart
git commit -m "feat(bar): RecordingPill widget"
```

---

## Task 7: RecordingBar widget

The bar exposes the ✕, the four source modes (Device disabled), the three disabled A/V placeholders, and a gear popup menu (Recents / Settings / Quit). It owns no IO — callbacks out.

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Test: `packages/screen_recorder/test/ui/bar/recording_bar_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/bar/recording_bar_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';

void main() {
  RecordingBar bar({
    void Function(BarSourceMode)? onPickMode,
    VoidCallback? onClose,
    VoidCallback? onOpenRecents,
    VoidCallback? onOpenSettings,
  }) =>
      RecordingBar(
        onPickMode: onPickMode ?? (_) {},
        onClose: onClose ?? () {},
        onOpenRecents: onOpenRecents ?? () {},
        onOpenSettings: onOpenSettings ?? () {},
      );

  Widget wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('renders the four source modes', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    expect(find.text('Display'), findsOneWidget);
    expect(find.text('Window'), findsOneWidget);
    expect(find.text('Area'), findsOneWidget);
    expect(find.text('Device'), findsOneWidget);
  });

  testWidgets('shows the three disabled A/V placeholders', (tester) async {
    await tester.pumpWidget(wrap(bar()));
    expect(find.text('No camera'), findsOneWidget);
    expect(find.text('No microphone'), findsOneWidget);
    expect(find.text('No system audio'), findsOneWidget);
  });

  testWidgets('tapping Window fires onPickMode(window)', (tester) async {
    BarSourceMode? picked;
    await tester.pumpWidget(wrap(bar(onPickMode: (m) => picked = m)));
    await tester.tap(find.text('Window'));
    expect(picked, BarSourceMode.window);
  });

  testWidgets('tapping Device does NOT fire onPickMode (disabled)',
      (tester) async {
    BarSourceMode? picked;
    await tester.pumpWidget(wrap(bar(onPickMode: (m) => picked = m)));
    await tester.tap(find.text('Device'), warnIfMissed: false);
    expect(picked, isNull);
  });

  testWidgets('close button fires onClose', (tester) async {
    var closed = false;
    await tester.pumpWidget(wrap(bar(onClose: () => closed = true)));
    await tester.tap(find.byKey(const Key('bar-close')));
    expect(closed, isTrue);
  });

  testWidgets('gear menu opens Recents and Settings', (tester) async {
    var recents = false;
    var settings = false;
    await tester.pumpWidget(wrap(bar(
      onOpenRecents: () => recents = true,
      onOpenSettings: () => settings = true,
    )));
    await tester.tap(find.byKey(const Key('bar-gear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recent recordings'));
    expect(recents, isTrue);

    await tester.tap(find.byKey(const Key('bar-gear')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Settings'));
    expect(settings, isTrue);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/recording_bar_test.dart`
Expected: FAIL — `recording_bar.dart` / `RecordingBar` / `BarSourceMode` not found.

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/ui/bar/recording_bar.dart
import 'package:flutter/material.dart';

/// The selectable source modes on the bar. `device` is shown but disabled.
enum BarSourceMode { display, window, area, device }

enum _GearAction { recents, settings, quit }

/// The compact floating control bar: close, source modes, disabled A/V
/// placeholders, and a gear menu. Pure presentation — all actions are
/// callbacks; no IO or navigation here.
class RecordingBar extends StatelessWidget {
  const RecordingBar({
    super.key,
    required this.onPickMode,
    required this.onClose,
    required this.onOpenRecents,
    required this.onOpenSettings,
  });

  final void Function(BarSourceMode mode) onPickMode;
  final VoidCallback onClose;
  final VoidCallback onOpenRecents;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF2C2C30),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          boxShadow: const [
            BoxShadow(color: Colors.black54, blurRadius: 24, offset: Offset(0, 10)),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _CircleButton(
              key: const Key('bar-close'),
              icon: Icons.close,
              tooltip: 'Quit Slipreel',
              onPressed: onClose,
            ),
            const _Divider(),
            _Mode(
              icon: Icons.desktop_windows_outlined,
              label: 'Display',
              onTap: () => onPickMode(BarSourceMode.display),
            ),
            _Mode(
              icon: Icons.web_asset,
              label: 'Window',
              onTap: () => onPickMode(BarSourceMode.window),
            ),
            _Mode(
              icon: Icons.crop_free,
              label: 'Area',
              onTap: () => onPickMode(BarSourceMode.area),
            ),
            const _Mode(
              icon: Icons.phone_iphone,
              label: 'Device',
              disabledTooltip: 'Device capture — coming soon',
            ),
            const _Divider(),
            const _AvPlaceholder(icon: Icons.videocam_off_outlined, label: 'No camera'),
            const _AvPlaceholder(icon: Icons.mic_off_outlined, label: 'No microphone'),
            const _AvPlaceholder(icon: Icons.volume_off_outlined, label: 'No system audio'),
            const _Divider(),
            PopupMenuButton<_GearAction>(
              key: const Key('bar-gear'),
              tooltip: 'More',
              icon: const Icon(Icons.settings_outlined, color: Color(0xFFD6D6DA), size: 20),
              onSelected: (a) {
                switch (a) {
                  case _GearAction.recents:
                    onOpenRecents();
                  case _GearAction.settings:
                    onOpenSettings();
                  case _GearAction.quit:
                    onClose();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: _GearAction.recents, child: Text('Recent recordings')),
                PopupMenuItem(value: _GearAction.settings, child: Text('Settings')),
                PopupMenuDivider(),
                PopupMenuItem(value: _GearAction.quit, child: Text('Quit Slipreel')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();
  @override
  Widget build(BuildContext context) => Container(
        width: 1,
        height: 34,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        color: Colors.white.withValues(alpha: 0.10),
      );
}

class _Mode extends StatelessWidget {
  const _Mode({
    required this.icon,
    required this.label,
    this.onTap,
    this.disabledTooltip,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final String? disabledTooltip;

  @override
  Widget build(BuildContext context) {
    final disabled = onTap == null;
    final color = disabled ? const Color(0xFF6E6E76) : const Color(0xFFE9E9EC);
    final body = InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(9),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 20, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11, color: color)),
          ],
        ),
      ),
    );
    if (disabled && disabledTooltip != null) {
      return Tooltip(message: disabledTooltip!, child: body);
    }
    return body;
  }
}

class _AvPlaceholder extends StatelessWidget {
  const _AvPlaceholder({required this.icon, required this.label});
  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: '$label — coming soon',
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 18, color: const Color(0xFF6E6E76)),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFF6E6E76))),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    super.key,
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        customBorder: const CircleBorder(),
        child: Container(
          width: 30,
          height: 30,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: const Icon(Icons.close, size: 16, color: Color(0xFFE9E9EC)),
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/recording_bar_test.dart`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart packages/screen_recorder/test/ui/bar/recording_bar_test.dart
git commit -m "feat(bar): RecordingBar widget (modes, disabled A/V, gear menu)"
```

---

## Task 8: PickedSource model + `pickSource` platform method

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/models/picked_source.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart` (add `pickSource`)
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` (add method)
- Modify: `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` (export model)
- Test: `packages/screen_recorder_platform_interface/test/picked_source_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_platform_interface/test/picked_source_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('fromMap parses window kind', () {
    final p = PickedSource.fromMap({'kind': 'window', 'id': '42'});
    expect(p.kind, RecordingSource.window);
    expect(p.id, '42');
  });

  test('fromMap parses screen kind', () {
    final p = PickedSource.fromMap({'kind': 'screen', 'id': '7'});
    expect(p.kind, RecordingSource.screen);
    expect(p.id, '7');
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder_platform_interface/test/picked_source_test.dart`
Expected: FAIL — `PickedSource` not found.

- [ ] **Step 3: Create the model**

```dart
// packages/screen_recorder_platform_interface/lib/src/models/picked_source.dart
import 'recording_settings.dart';

/// A source chosen via the native click-to-select overlay.
class PickedSource {
  final RecordingSource kind; // window or screen
  final String id;

  const PickedSource({required this.kind, required this.id});

  factory PickedSource.fromMap(Map<String, dynamic> map) {
    final kind = map['kind'] == 'window'
        ? RecordingSource.window
        : RecordingSource.screen;
    return PickedSource(kind: kind, id: map['id'] as String);
  }
}
```

- [ ] **Step 4: Export it**

In `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`, add next to the other model exports:

```dart
export 'src/models/picked_source.dart';
```

- [ ] **Step 5: Add the method-name constant**

In `packages/screen_recorder_platform_interface/lib/src/constants.dart`, add inside `class ScreenRecorderMethods`, after `selectRegion`:

```dart
  static const String pickSource = 'pickSource';
```

- [ ] **Step 6: Add the abstract method**

In `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`, after the `selectRegion` method, add:

```dart
  /// Shows a native click-to-select overlay over the desktop for the given
  /// [kind] (window or screen). Returns the chosen source, or null if the
  /// user cancelled (Esc / clicked empty space).
  Future<PickedSource?> pickSource(RecordingSource kind) {
    throw UnsupportedError('pickSource() is not supported on this platform.');
  }
```

Ensure the file imports the model (add near the top with the other model imports if the file imports them individually; if it relies on the barrel, no change needed — verify by running the test).

- [ ] **Step 7: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder_platform_interface/test/picked_source_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder_platform_interface
git commit -m "feat(platform): PickedSource model + pickSource method"
```

---

## Task 9: Dart method-channel impl of `pickSource`

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Test: `packages/screen_recorder_macos/test/pick_source_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder_macos/test/pick_source_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_macos/screen_recorder_macos_method_channel.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.slipreel.screen_recorder/recording');
  final log = <MethodCall>[];
  Object? response;

  setUp(() {
    response = null;
    log.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      log.add(call);
      return response;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('pickSource(window) invokes pickSource with kind and parses result',
      () async {
    response = {'kind': 'window', 'id': '99'};
    final platform = MethodChannelScreenRecorderMacos();
    final picked = await platform.pickSource(RecordingSource.window);
    expect(log.single.method, 'pickSource');
    expect(log.single.arguments, {'kind': 'window'});
    expect(picked, isNotNull);
    expect(picked!.kind, RecordingSource.window);
    expect(picked.id, '99');
  });

  test('pickSource returns null when native returns null (cancel)', () async {
    response = null;
    final platform = MethodChannelScreenRecorderMacos();
    final picked = await platform.pickSource(RecordingSource.screen);
    expect(log.single.arguments, {'kind': 'screen'});
    expect(picked, isNull);
  });
}
```

> Note: confirm the concrete class name (`MethodChannelScreenRecorderMacos`) by reading the top of `screen_recorder_macos_method_channel.dart`; use whatever the file declares.

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder_macos/test/pick_source_test.dart`
Expected: FAIL — `pickSource` not implemented (UnsupportedError) / method not invoked.

- [ ] **Step 3: Implement** (add after the `selectRegion` override, mirroring it)

```dart
  @override
  Future<PickedSource?> pickSource(RecordingSource kind) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.pickSource,
      {'kind': kind == RecordingSource.window ? 'window' : 'screen'},
    );
    if (raw == null) return null;
    return PickedSource.fromMap(raw);
  }
```

- [ ] **Step 4: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder_macos/test/pick_source_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart packages/screen_recorder_macos/test/pick_source_test.dart
git commit -m "feat(macos): Dart pickSource method-channel impl"
```

---

## Task 10: Native SourcePickerGeometry (pure, unit-tested)

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/SourcePickerGeometry.swift`
- Test: `packages/screen_recorder_macos/example/macos/RunnerTests/SourcePickerGeometryTests.swift`

- [ ] **Step 1: Write the failing XCTest**

```swift
// packages/screen_recorder_macos/example/macos/RunnerTests/SourcePickerGeometryTests.swift
import XCTest
import CoreGraphics
@testable import screen_recorder_macos

final class SourcePickerGeometryTests: XCTestCase {
  func testLocalFrameSubtractsDisplayOrigin() {
    // A window at global (1920+100, 50) on a secondary display whose CG
    // bounds start at (1920, 0). Local frame should be (100, 50).
    let display = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
    let window = CGRect(x: 2020, y: 50, width: 400, height: 300)
    let local = SourcePickerGeometry.localFrame(window: window, displayBounds: display)
    XCTAssertEqual(local, CGRect(x: 100, y: 50, width: 400, height: 300))
  }

  func testTopmostReturnsFirstContainingFrameFrontToBack() {
    // frames are ordered front -> back. Point is inside both 0 and 2;
    // the front-most (index 0) wins.
    let frames = [
      CGRect(x: 0, y: 0, width: 100, height: 100),   // front
      CGRect(x: 200, y: 0, width: 100, height: 100),
      CGRect(x: 50, y: 50, width: 100, height: 100),  // back, overlaps 0
    ]
    XCTAssertEqual(SourcePickerGeometry.topmost(at: CGPoint(x: 60, y: 60), frames: frames), 0)
  }

  func testTopmostReturnsNilOutsideAllFrames() {
    let frames = [CGRect(x: 0, y: 0, width: 10, height: 10)]
    XCTAssertNil(SourcePickerGeometry.topmost(at: CGPoint(x: 500, y: 500), frames: frames))
  }
}
```

- [ ] **Step 2: Add the test file to the RunnerTests target & run to verify it fails**

Run (from `packages/screen_recorder_macos/example`):
`xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' 2>&1 | grep -E "(TEST SUCCEEDED|TEST FAILED|error:)"`
Expected: FAIL/`error:` — `SourcePickerGeometry` is undefined.

> If the new file isn't picked up by the target, open `macos/Runner.xcworkspace` and confirm `SourcePickerGeometryTests.swift` is a member of the `RunnerTests` target (the existing `*Tests.swift` files show the membership pattern).

- [ ] **Step 3: Implement**

```swift
// packages/screen_recorder_macos/macos/Classes/SourcePickerGeometry.swift
import CoreGraphics

/// Pure geometry for the source-picker overlay. Kept separate from the
/// AppKit view so it can be unit-tested (the view itself is not).
enum SourcePickerGeometry {
  /// Converts a window's global CG frame (top-left origin) into coordinates
  /// local to a display whose CG bounds are `displayBounds` — a simple origin
  /// subtraction. The overlay view is flipped (top-left), so no Y inversion.
  static func localFrame(window: CGRect, displayBounds: CGRect) -> CGRect {
    return CGRect(
      x: window.origin.x - displayBounds.origin.x,
      y: window.origin.y - displayBounds.origin.y,
      width: window.size.width,
      height: window.size.height)
  }

  /// Given frames ordered front-to-back, returns the index of the first
  /// (front-most) frame containing `point`, or nil if none do.
  static func topmost(at point: CGPoint, frames: [CGRect]) -> Int? {
    for (i, f) in frames.enumerated() where f.contains(point) {
      return i
    }
    return nil
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run (from `packages/screen_recorder_macos/example`):
`xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' 2>&1 | grep -E "(TEST SUCCEEDED|TEST FAILED|error:)"`
Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/SourcePickerGeometry.swift packages/screen_recorder_macos/example/macos/RunnerTests/SourcePickerGeometryTests.swift
git commit -m "feat(macos): SourcePickerGeometry pure helpers + tests"
```

---

## Task 11: Native source-picker overlay + plugin wiring

This is the AppKit overlay, modeled directly on `RegionSelector`/`RegionSelectorView`. Not unit-tested (view glue); verified by running the app. The geometry it relies on is already tested (Task 10).

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/SourcePickerView.swift`
- Create: `packages/screen_recorder_macos/macos/Classes/SourcePickerOverlay.swift`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

- [ ] **Step 1: Create `SourcePickerView.swift`**

```swift
// packages/screen_recorder_macos/macos/Classes/SourcePickerView.swift
import AppKit
import CoreGraphics

/// One pickable target drawn on a screen overlay.
struct PickerTarget {
  let id: String            // window id or display id (as String)
  let title: String
  let icon: NSImage?        // app icon for windows; nil for displays
  let localFrame: CGRect    // in this view's flipped (top-left) coords
}

/// Draws target overlays on one screen and reports hover/click. Mirrors the
/// RegionSelectorView pattern: flipped coords, mouse events drive redraw and
/// fire callbacks to the owning overlay manager.
final class SourcePickerView: NSView {
  var targets: [PickerTarget] = [] { didSet { needsDisplay = true } }
  /// Called with the chosen target id when the user clicks a target.
  var onSelect: ((String) -> Void)?
  /// Called when the user clicks empty space (cancel).
  var onCancel: (() -> Void)?

  private var hoveredIndex: Int?
  private static let blue = NSColor(srgbRed: 0.16, green: 0.43, blue: 1.0, alpha: 0.34)
  private static let scrim = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.46)
  private static let blueBorder = NSColor(srgbRed: 0.29, green: 0.55, blue: 1.0, alpha: 0.9)

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self, userInfo: nil))
  }

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let idx = SourcePickerGeometry.topmost(at: p, frames: targets.map { $0.localFrame })
    if idx != hoveredIndex {
      hoveredIndex = idx
      needsDisplay = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    if hoveredIndex != nil { hoveredIndex = nil; needsDisplay = true }
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let idx = SourcePickerGeometry.topmost(at: p, frames: targets.map { $0.localFrame }) {
      onSelect?(targets[idx].id)
    } else {
      onCancel?()
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    for (i, t) in targets.enumerated() {
      let hovered = (i == hoveredIndex)
      let fill = hovered ? Self.blue : Self.scrim
      ctx.setFillColor(fill.cgColor)
      ctx.fill(t.localFrame)
      if hovered {
        ctx.setStrokeColor(Self.blueBorder.cgColor)
        ctx.setLineWidth(3)
        ctx.stroke(t.localFrame.insetBy(dx: 1.5, dy: 1.5))
      }
      drawCenteredControls(for: t, hovered: hovered)
    }
  }

  private func drawCenteredControls(for t: PickerTarget, hovered: Bool) {
    let cx = t.localFrame.midX
    var cy = t.localFrame.midY
    let alpha: CGFloat = hovered ? 1.0 : 0.85

    // App icon (windows only), above the label.
    if let icon = t.icon {
      let size: CGFloat = 40
      let rect = CGRect(x: cx - size / 2, y: cy - size - 36, width: size, height: size)
      icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    // Title label.
    let labelAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    let label = NSAttributedString(string: t.title, attributes: labelAttrs)
    let labelSize = label.size()
    label.draw(at: CGPoint(x: cx - labelSize.width / 2, y: cy - 24))

    // Record button.
    let btnW: CGFloat = 116, btnH: CGFloat = 32
    let btn = CGRect(x: cx - btnW / 2, y: cy + 6, width: btnW, height: btnH)
    let path = NSBezierPath(roundedRect: btn, xRadius: 9, yRadius: 9)
    NSColor(srgbRed: 0.90, green: 0.28, blue: 0.30, alpha: hovered ? 1.0 : 0.85).setFill()
    path.fill()
    let btnAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.white,
    ]
    let rec = NSAttributedString(string: "● Record", attributes: btnAttrs)
    let recSize = rec.size()
    rec.draw(at: CGPoint(x: btn.midX - recSize.width / 2, y: btn.midY - recSize.height / 2))
    _ = cy
    cy += 0
  }
}
```

- [ ] **Step 2: Create `SourcePickerOverlay.swift`**

```swift
// packages/screen_recorder_macos/macos/Classes/SourcePickerOverlay.swift
import AppKit
import CoreGraphics
import ScreenCaptureKit

/// What kind of targets to show.
enum PickerKind { case window, screen }

/// Result handed back to Flutter.
struct PickedSourceResult {
  let kind: PickerKind
  let id: String
}

/// Shows borderless transparent overlay windows (one per NSScreen) painting
/// the pickable targets, and returns the chosen source. Modeled on
/// `RegionSelector`.
@MainActor
final class SourcePickerOverlay {
  static let shared = SourcePickerOverlay()
  private init() {}

  private var overlayWindows: [NSWindow] = []
  private var continuation: CheckedContinuation<PickedSourceResult?, Never>?
  private var escMonitor: Any?
  private var kind: PickerKind = .window
  private var inFlight = false

  func pick(kind: PickerKind) async -> PickedSourceResult? {
    if inFlight { return nil }
    inFlight = true
    defer { inFlight = false }
    self.kind = kind

    // Gather targets per screen.
    let targetsByScreen = await buildTargets(kind: kind)

    return await withCheckedContinuation { cont in
      self.continuation = cont
      present(targetsByScreen: targetsByScreen)
    }
  }

  private func present(targetsByScreen: [NSScreen: [PickerTarget]]) {
    overlayWindows.removeAll()
    for screen in NSScreen.screens {
      let win = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
      win.level = .screenSaver
      win.isOpaque = false
      win.backgroundColor = .clear
      win.ignoresMouseEvents = false
      win.acceptsMouseMovedEvents = true
      win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

      let view = SourcePickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
      view.targets = targetsByScreen[screen] ?? []
      view.onSelect = { [weak self] id in self?.finish(id: id) }
      view.onCancel = { [weak self] in self?.cancel() }
      win.contentView = view
      win.orderFrontRegardless()
      overlayWindows.append(win)
    }
    NSApp.activate(ignoringOtherApps: true)
    overlayWindows.first?.makeKey()

    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      if e.keyCode == 53 { self?.cancel(); return nil } // Esc
      return e
    }
  }

  /// Builds per-screen targets. For windows, maps each on-screen window's CG
  /// frame to the display it sits on. For screens, one full-screen target.
  private func buildTargets(kind: PickerKind) async -> [NSScreen: [PickerTarget]] {
    var result: [NSScreen: [PickerTarget]] = [:]
    guard let content = try? await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true) else { return result }

    switch kind {
    case .screen:
      for screen in NSScreen.screens {
        guard let displayId = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
        let name = screen.localizedName
        let full = CGRect(origin: .zero, size: screen.frame.size)
        result[screen] = [PickerTarget(
          id: String(displayId), title: name, icon: nil, localFrame: full)]
      }
    case .window:
      // front-to-back: SCShareableContent returns windows front-most first.
      let raw = content.windows.map { SourceCatalog.rawWindow(from: $0) }
      let visible = SourceCatalog.applyStrictFilter(raw) // [[String:Any]] with x/y/w/h
      for screen in NSScreen.screens {
        guard let displayId = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
        let displayBounds = CGDisplayBounds(displayId) // global, top-left origin
        var targets: [PickerTarget] = []
        for w in visible {
          let cg = CGRect(
            x: CGFloat(w["x"] as! Int), y: CGFloat(w["y"] as! Int),
            width: CGFloat(w["width"] as! Int), height: CGFloat(w["height"] as! Int))
          guard cg.intersects(displayBounds) else { continue }
          let local = SourcePickerGeometry.localFrame(window: cg, displayBounds: displayBounds)
          let id = w["id"] as! String
          let title = (w["title"] as? String) ?? ""
          let owner = (w["ownerName"] as? String) ?? ""
          targets.append(PickerTarget(
            id: id,
            title: title.isEmpty ? owner : title,
            icon: appIcon(for: w),
            localFrame: local))
        }
        result[screen] = targets
      }
    }
    return result
  }

  private func appIcon(for window: [String: Any]) -> NSImage? {
    // ownerName isn't a bundle id; fall back to the running app whose
    // localizedName matches. Best-effort — nil is fine (drawn without icon).
    guard let owner = window["ownerName"] as? String else { return nil }
    let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == owner }
    return app?.icon
  }

  private func finish(id: String) {
    teardown()
    continuation?.resume(returning: PickedSourceResult(kind: kind, id: id))
    continuation = nil
  }

  private func cancel() {
    teardown()
    continuation?.resume(returning: nil)
    continuation = nil
  }

  private func teardown() {
    overlayWindows.forEach { $0.orderOut(nil) }
    overlayWindows.removeAll()
    if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
  }
}
```

> If `SourceCatalog.rawWindow(from:)` / `applyStrictFilter` are not accessible from this file, widen their access from the default to `static func` (they already are `static`; confirm they're not `private`). They live in `SourceCatalog.swift`.

- [ ] **Step 3: Wire the plugin dispatch**

In `ScreenRecorderMacosPlugin.swift`, add a case in the `handle(_:result:)` switch (next to `selectRegion`):

```swift
  case "pickSource":
    pickSource(call: call, result: result)
```

And add the handler method (mirroring `selectRegion`'s handler):

```swift
  private func pickSource(call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    let kindStr = (args?["kind"] as? String) ?? "window"
    let kind: PickerKind = (kindStr == "screen") ? .screen : .window
    Task { @MainActor in
      let picked = await SourcePickerOverlay.shared.pick(kind: kind)
      if let p = picked {
        result([
          "kind": p.kind == .window ? "window" : "screen",
          "id": p.id,
        ])
      } else {
        result(nil)
      }
    }
  }
```

- [ ] **Step 4: Build to confirm it compiles**

Run (from `packages/screen_recorder`): `$FLUTTER build macos --debug`
Expected: build succeeds. Behavior verified in Task 13.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/SourcePickerView.swift packages/screen_recorder_macos/macos/Classes/SourcePickerOverlay.swift packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(macos): native source-picker overlay + pickSource dispatch"
```

---

## Task 12: RecordingBarScreen orchestrator + main.dart wiring

The new `home:`. Renders bar/pill by window mode; drives bar↔pill from recording status; opens picker/region/recents/settings/editor as panels via `Navigator.push` (each push sets panel mode, each pop returns to bar).

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Modify: `packages/screen_recorder/lib/main.dart`
- Test: `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/window_mode.dart';
import 'package:screen_recorder/state/window_mode_controller.dart';
import 'package:screen_recorder/ui/bar/recording_bar.dart';
import 'package:screen_recorder/ui/bar/recording_pill.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';

class _FakeChrome implements WindowChrome {
  final List<WindowMode> calls = [];
  @override
  Future<void> setMode(WindowMode mode) async => calls.add(mode);
}

void main() {
  Widget wrap(_FakeChrome chrome) => ProviderScope(
        overrides: [windowChromeProvider.overrideWithValue(chrome)],
        child: const MaterialApp(home: RecordingBarScreen()),
      );

  testWidgets('bar mode renders the RecordingBar', (tester) async {
    await tester.pumpWidget(wrap(_FakeChrome()));
    await tester.pump();
    expect(find.byType(RecordingBar), findsOneWidget);
    expect(find.byType(RecordingPill), findsNothing);
  });

  testWidgets('pill mode renders the RecordingPill', (tester) async {
    final chrome = _FakeChrome();
    late WidgetRef capturedRef;
    await tester.pumpWidget(ProviderScope(
      overrides: [windowChromeProvider.overrideWithValue(chrome)],
      child: MaterialApp(
        home: Consumer(builder: (c, ref, _) {
          capturedRef = ref;
          return const RecordingBarScreen();
        }),
      ),
    ));
    await tester.pump();
    await capturedRef.read(windowModeControllerProvider.notifier).showPill();
    await tester.pump();
    expect(find.byType(RecordingPill), findsOneWidget);
    expect(find.byType(RecordingBar), findsNothing);
  });
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`
Expected: FAIL — `recording_bar_screen.dart` not found.

- [ ] **Step 3: Implement `RecordingBarScreen`**

```dart
// packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../state/recording_state.dart';
import '../../state/window_mode.dart';
import '../../state/window_mode_controller.dart';
import '../screens/playback_screen.dart';
import '../screens/recents_screen.dart';
import '../screens/settings_screen.dart';
import '../../state/frame_settings_provider.dart';
import 'recording_bar.dart';
import 'recording_pill.dart';

/// Root of the app. Hosts the bar/pill and routes Recents/Settings/editor as
/// panels by morphing the window. Single window, three shapes.
class RecordingBarScreen extends ConsumerStatefulWidget {
  const RecordingBarScreen({super.key});

  @override
  ConsumerState<RecordingBarScreen> createState() => _RecordingBarScreenState();
}

class _RecordingBarScreenState extends ConsumerState<RecordingBarScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(windowModeControllerProvider.notifier).showBar();
    });
  }

  WindowModeController get _window =>
      ref.read(windowModeControllerProvider.notifier);

  Future<void> _openPanel(Widget child) async {
    await _window.showPanel();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => child),
    );
    if (!mounted) return;
    await _window.showBar();
  }

  Future<void> _pickAndRecord(BarSourceMode mode) async {
    final controller = ref.read(recordingControllerProvider.notifier);
    switch (mode) {
      case BarSourceMode.display:
      case BarSourceMode.window:
        final kind = mode == BarSourceMode.window
            ? RecordingSource.window
            : RecordingSource.screen;
        final picked = await ScreenRecorderPlatform.instance.pickSource(kind);
        if (picked == null) return; // cancelled
        controller.selectSource(kind: picked.kind, id: picked.id);
        await controller.startRecording();
      case BarSourceMode.area:
        final region = await ScreenRecorderPlatform.instance.selectRegion();
        if (region == null) return;
        controller.selectSource(
          kind: RecordingSource.area,
          id: region.displayId,
          region: region,
        );
        await controller.startRecording();
      case BarSourceMode.device:
        break; // disabled
    }
  }

  @override
  Widget build(BuildContext context) {
    final mode = ref.watch(windowModeControllerProvider);

    // Drive bar<->pill from recording status, and push the editor on completion.
    ref.listen<RecordingState>(recordingControllerProvider, (prev, next) {
      if (next.status == RecordingStatus.recording ||
          next.status == RecordingStatus.processing) {
        _window.showPill();
      } else if (prev?.status != RecordingStatus.completed &&
          next.status == RecordingStatus.completed &&
          next.videoPath != null) {
        _openPanel(PlaybackScreen(videoPath: next.videoPath!));
      } else if (next.status == RecordingStatus.error) {
        _window.showBar();
      }
    });

    final Widget body;
    switch (mode) {
      case WindowMode.pill:
        final state = ref.watch(recordingControllerProvider);
        body = RecordingPill(
          elapsed: state.duration,
          onStop: ref.read(recordingControllerProvider.notifier).stopRecording,
        );
      case WindowMode.bar:
        body = RecordingBar(
          onPickMode: _pickAndRecord,
          onClose: () => SystemNavigator.pop(),
          onOpenRecents: () => _openPanel(const RecentsScreen()),
          onOpenSettings: () => _openPanel(
            SettingsScreen(settingsProvider: ref.read(frameSettingsProvider.notifier)),
          ),
        );
      case WindowMode.panel:
        // While a panel route is on top, this root is covered; render the bar
        // underneath so popping back reveals it instantly.
        body = RecordingBar(
          onPickMode: _pickAndRecord,
          onClose: () => SystemNavigator.pop(),
          onOpenRecents: () => _openPanel(const RecentsScreen()),
          onOpenSettings: () => _openPanel(
            SettingsScreen(settingsProvider: ref.read(frameSettingsProvider.notifier)),
          ),
        );
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: body,
    );
  }
}
```

> Verify the exact provider used by `SettingsScreen` (`FrameSettingsProvider`). The Explore notes show `SettingsScreen({required FrameSettingsProvider settingsProvider})` and a `frameSettingsProvider`. Read `lib/state/frame_settings_provider.dart` and pass the correct notifier reference. If the provider exposes the notifier differently, adapt the `ref.read(...)` accordingly.

- [ ] **Step 4: Run it to verify it passes**

Run: `$FLUTTER test packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`
Expected: PASS (2 tests). Fix the `frameSettingsProvider` reference if the test fails to compile.

- [ ] **Step 5: Wire `main.dart`**

In `packages/screen_recorder/lib/main.dart`:
- Add imports:

```dart
import 'platform/window_chrome_channel.dart';
import 'state/window_mode_controller.dart';
import 'ui/bar/recording_bar_screen.dart';
```

- Provide the chrome at the root `ProviderScope` (find where `ProviderScope` wraps the app and add the override):

```dart
ProviderScope(
  overrides: [
    windowChromeProvider.overrideWithValue(MethodChannelWindowChrome()),
  ],
  child: const MyApp(),
)
```

- Change `home:` in `MyApp.build` from `const RecordingScreen()` to `const RecordingBarScreen()`. Remove the now-unused `import 'ui/screens/recording_screen.dart';` if nothing else references it (Task 13 removes the screen).

- [ ] **Step 6: Run the whole screen_recorder suite**

Run: `$FLUTTER test packages/screen_recorder/test`
Expected: PASS (the old `recording_screen_test.dart` still passes for now — it tests `RecordingScreen` directly, which still exists).

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart packages/screen_recorder/lib/main.dart packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart
git commit -m "feat(bar): RecordingBarScreen orchestrator + main wiring"
```

---

## Task 13: Move strict-filter into Settings; retire RecordingScreen; run the app

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/settings_screen.dart` (add the toggle)
- Delete: `packages/screen_recorder/lib/ui/screens/recording_screen.dart`
- Delete: `packages/screen_recorder/test/screens/recording_screen_test.dart`, `packages/screen_recorder/test/screens/recording_screen_region_test.dart`
- Possibly delete: now-unused `lib/ui/widgets/source_picker/*` (only if nothing else imports them)

- [ ] **Step 1: Find remaining references to `RecordingScreen` and the source_picker grid**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
grep -rn "RecordingScreen\b" packages/screen_recorder/lib packages/screen_recorder/test
grep -rln "source_picker/source_grid\|source_picker/source_tile\|SourceGrid\b" packages/screen_recorder/lib
```
Expected: after Task 12, `lib` no longer references `RecordingScreen` (only the deleted screen + its tests). `RegionTabContent`, `PermissionCta`, `ThumbnailCache`, `ConcurrentLoader` may still be referenced — keep any that are.

- [ ] **Step 2: Add the "Show all windows" strict-filter setting**

The overlay always reflects current on-screen windows; the strict filter (drop tiny/system windows) becomes a user preference. Add a persisted bool. Read `lib/state/frame_settings_provider.dart` for the existing settings-persistence pattern and add a `strictWindowFilter` bool following the same shape. Then in `SettingsScreen.build`, add a `SwitchListTile`:

```dart
SwitchListTile(
  title: const Text('Show all windows'),
  subtitle: const Text(
    'Include tiny and system windows in the Window picker',
  ),
  value: !strictFilter, // "show all" == NOT strict
  onChanged: (showAll) => /* set strictWindowFilter = !showAll via provider */,
),
```

Then thread the value into the native picker: pass it to `pickSource` (extend the `pickSource` arg map with `{'strictFilter': bool}`, default true), and in `SourcePickerOverlay.buildTargets` choose `SourceCatalog.applyStrictFilter(raw)` vs `SourceCatalog.projectAll(raw)` accordingly.

> This step spans Dart (settings + platform method arg) and Swift (overlay). Implement as: (a) add `strictWindowFilter` setting + persistence with a unit test mirroring `frame_settings_provider_test.dart`; (b) extend `pickSource(RecordingSource, {bool strictFilter})` in the interface + method channel (update Task 9's test to assert the arg); (c) branch in `buildTargets`. Keep each as its own commit if it helps.

- [ ] **Step 3: Delete the old screen + its tests**

```bash
git rm packages/screen_recorder/lib/ui/screens/recording_screen.dart
git rm packages/screen_recorder/test/screens/recording_screen_test.dart
git rm packages/screen_recorder/test/screens/recording_screen_region_test.dart
```

Remove any now-dangling imports of `recording_screen.dart`. For `lib/ui/widgets/source_picker/*` files that Step 1 proved unused, `git rm` them and their tests; **keep** `region_tab_content.dart`, `permission_cta.dart`, and anything still imported.

- [ ] **Step 4: Run the full suites**

```bash
$FLUTTER test packages/screen_recorder/test
$FLUTTER test packages/slipreel_engine/test
```
Expected: all green (no references to the deleted screen remain).

- [ ] **Step 5: Manual / agent-driven app verification**

Build & launch the app (or use the `flutter-qa` MCP harness). Verify:
1. App opens as the **bar** (small, floating, top-center, draggable).
2. **Window** → native overlay paints over each window with icon+title+Record; hover turns the window blue; clicking Record starts recording; the window collapses to the **pill** with a ticking timer.
3. **Stop** → window grows to **panel** and shows the editor (`PlaybackScreen`).
4. Closing the editor returns to the **bar**.
5. **Display** → per-screen overlay; Record starts a display recording.
6. **Area** → region-draw overlay; confirming starts recording.
7. **Device** + the three A/V controls are visibly disabled.
8. Gear ▾ → **Recent recordings** and **Settings** open as panels; back returns to the bar. "Show all windows" toggle in Settings affects the Window overlay.
9. ✕ quits the app.

Fix any issues found, re-running the relevant tests.

- [ ] **Step 6: Commit**

```bash
git add -A
git commit -m "feat(bar): strict-filter setting; retire RecordingScreen; bar is the home UI"
```

---

## Self-Review Notes (for the executor)

- **Spec coverage:** bar layout (Tasks 7,12) · disabled A/V + Device (Task 7) · native Window/Display overlay with icon/label/Record + blue hover (Tasks 10,11) · Area region-draw reuse (Task 12) · pill (Tasks 5,6,12) · window morphing bar/pill/panel (Tasks 1-4,12) · Recents/Settings/editor as panels (Task 12) · strict-filter→Settings (Task 13) · permission/cancel handling (Task 12 cancel paths; permission CTA — see note below) · tests at every layer.
- **Permission-denied path:** `pickSource`/`selectRegion` returning null covers cancel; if screen-recording permission is denied the native call should surface it. The simplest v1: the overlay shows nothing and the user sees no targets. If you want the explicit `PermissionCta`, add a `checkPermissions` gate before `pickSource` in `_pickAndRecord` and `_openPanel(PermissionScreen(...))` on denial — wire it if the native `checkPermissions` is reliable; otherwise leave as a follow-up (flagged, not silently dropped).
- **Type consistency:** `WindowMode`, `WindowChrome`, `BarSourceMode`, `PickedSource`, `PickerKind`, `PickerTarget` names are used identically across tasks. `setMode` arg `{'mode': name}` matches between Task 3 (Dart) and Task 4 (Swift). `pickSource` arg `{'kind': 'window'|'screen'}` matches Task 9 (Dart) and Task 11 (Swift).
- **Frame settings provider:** Task 12 and Task 13 depend on the real name/shape of `frameSettingsProvider` / `FrameSettingsProvider`. Read that file first and adapt the two `ref.read(...)` sites + the new `strictWindowFilter` setting accordingly.
```
