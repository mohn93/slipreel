# Live Microphone Level Meter — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show a live level meter under the mic control on the recording bar that visualizes the real-time intensity of the selected microphone, driven by genuine native mic monitoring.

**Architecture:** A native `MicLevelMonitor` taps the selected mic, computes a smoothed 0–1 RMS level, and streams it (~20 Hz) over a new `micLevel` event channel. `RecordingBarScreen` starts/stops the monitor whenever the window is in bar mode with a mic selected, and feeds the stream to a `MicLevelMeter` widget rendered under the mic chip. The bar's existing width auto-size is generalized to width **and** height so the bar grows for the meter and shrinks when the mic is off.

**Tech Stack:** Flutter/Dart, Riverpod, method + event channels; Swift / AVFoundation (AVAudioEngine tap, RMS), AppKit (window resize).

**Spec:** `docs/superpowers/specs/2026-05-26-mic-level-meter-design.md`
**Branch:** `feat/mic-level-meter` (already created).

---

## Conventions
- Dart tasks are **TDD** (red → green → commit). Swift tasks aren't unit-tested here; gate is `flutter build macos` then commit. Build native with: `cd packages/screen_recorder_macos/example && flutter build macos --debug` (run `pod install` in that `macos/` dir first if it complains about a new source file).
- Stage only the files each task lists. **Never** `git add -A` (untracked `DerivedData/` churn).
- Run Dart tests from the package dir.

---

## File Structure

**Created**
- `packages/screen_recorder/lib/ui/bar/mic_level_meter.dart` — the meter widget.
- `packages/screen_recorder_macos/macos/Classes/MicLevelMonitor.swift` — native level monitor.
- Tests for each + the changes below.

**Modified**
- `screen_recorder_platform_interface`: `constants.dart`, `screen_recorder_platform_interface.dart`, method-channel impl.
- `screen_recorder_macos`: `ScreenRecorderMacosPlugin.swift`, `MainFlutterWindow.swift` is in the **app**, not here.
- `screen_recorder` (app): `recording_bar.dart`, `recording_bar_screen.dart`, `state/window_mode.dart`, `platform/window_chrome_channel.dart`, `macos/Runner/MainFlutterWindow.swift`, and the `WindowChrome` test fakes.

---

## Task 1: Platform interface — `micLevel` channel + monitor methods + stream

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`
- Modify: `packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart`. In the `setUp` mock handler `switch`, add before `default`:
```dart
          case 'startMicMonitor':
            return null;
          case 'stopMicMonitor':
            return null;
```
Add these tests (the file already imports the platform interface from Task work earlier; if not, add `import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';`):
```dart
  test('startMicMonitor sends the microphone config', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return null;
    });
    await platform.startMicMonitor(
        const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic', reduceNoise: true));
    expect(calls.single.method, 'startMicMonitor');
    expect((calls.single.arguments as Map)['deviceUid'], 'u');
    expect((calls.single.arguments as Map)['reduceNoise'], true);
  });

  test('stopMicMonitor invokes the stop method', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (c) async {
      calls.add(c);
      return null;
    });
    await platform.stopMicMonitor();
    expect(calls.single.method, 'stopMicMonitor');
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder_macos && flutter test test/screen_recorder_macos_method_channel_test.dart`
Expected: FAIL — `startMicMonitor`/`stopMicMonitor` not defined.

- [ ] **Step 3: Implement**

In `packages/screen_recorder_platform_interface/lib/src/constants.dart`:
- Add to `ScreenRecorderChannels`:
```dart
  /// Event channel for the live microphone level (0..1) stream.
  static const String micLevel = 'com.slipreel.screen_recorder/micLevel';
```
- Add to `ScreenRecorderMethods`:
```dart
  static const String startMicMonitor = 'startMicMonitor';
  static const String stopMicMonitor = 'stopMicMonitor';
```

In `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`, add (after the `showMicrophoneMenu` method; `MicrophoneConfig` is already imported):
```dart
  /// Live microphone level (0..1), emitted ~20 Hz while a monitor is running.
  Stream<double> get micLevelStream {
    throw UnimplementedError('micLevelStream has not been implemented.');
  }

  /// Start live monitoring of [config]'s device so [micLevelStream] emits.
  Future<void> startMicMonitor(MicrophoneConfig config) {
    throw UnsupportedError('startMicMonitor() is not supported on this platform.');
  }

  /// Stop live mic monitoring.
  Future<void> stopMicMonitor() {
    throw UnsupportedError('stopMicMonitor() is not supported on this platform.');
  }
```

In `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`:
- Add a field next to the other event channels:
```dart
  final _micLevelChannel = const EventChannel(ScreenRecorderChannels.micLevel);
```
- Add the implementations (after `showMicrophoneMenu`):
```dart
  @override
  Stream<double> get micLevelStream => _micLevelChannel
      .receiveBroadcastStream()
      .map((event) => (event as num).toDouble());

  @override
  Future<void> startMicMonitor(MicrophoneConfig config) async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.startMicMonitor,
      config.toJson(),
    );
  }

  @override
  Future<void> stopMicMonitor() async {
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.stopMicMonitor,
    );
  }
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder_macos && flutter test test/screen_recorder_macos_method_channel_test.dart`
Then: `cd ../screen_recorder_platform_interface && flutter test`
Expected: PASS (both).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/lib/src/constants.dart \
        packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart \
        packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart \
        packages/screen_recorder_macos/test/screen_recorder_macos_method_channel_test.dart
git commit -m "feat(meter): micLevel channel + startMicMonitor/stopMicMonitor on the platform interface"
```

---

## Task 2: `WindowChrome.setBarWidth` → `setBarSize(width, height)` (Dart)

Generalize the existing width-only auto-size to width + height. The bar's height is content-driven by a simple rule: taller when the meter is shown (a mic is selected), base otherwise.

**Files:**
- Modify: `packages/screen_recorder/lib/state/window_mode.dart`
- Modify: `packages/screen_recorder/lib/platform/window_chrome_channel.dart`
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Modify: `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`
- Modify: `packages/screen_recorder/test/state/window_mode_controller_test.dart`

- [ ] **Step 1: Write the failing test**

In `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`, update the `_FakeChrome` to record sizes instead of widths:
```dart
  final List<({double w, double h})> barSizes = [];
  @override
  Future<void> setBarSize(double width, double height) async =>
      barSizes.add((w: width, h: height));
```
(Remove the old `barWidths` list + `setBarWidth` override.)
Replace the existing auto-size test body's assertions to use `barSizes`:
```dart
  testWidgets('bar auto-sizes its window to the (variable) content size',
      (tester) async {
    _wide(tester);
    ScreenRecorderPlatform.instance = _FakePlatform();
    final chrome = _FakeChrome();

    await tester.pumpWidget(ProviderScope(
      overrides: [windowChromeProvider.overrideWithValue(chrome)],
      child: const MaterialApp(home: RecordingBarScreen()),
    ));
    await tester.pumpAndSettle();

    expect(chrome.barSizes, isNotEmpty);
    final off = chrome.barSizes.last;
    expect(off.w, greaterThan(320));
    expect(off.h, 68); // base height, no meter when mic is off

    final container = ProviderScope.containerOf(
        tester.element(find.byType(RecordingBar)));
    container
        .read(microphoneControllerProvider.notifier)
        .set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'X'));
    await tester.pumpAndSettle();

    final on = chrome.barSizes.last;
    expect(on.w, lessThan(off.w)); // 'X' is narrower than 'No microphone'
    expect(on.h, 80); // taller — meter row present
  });
```
In `packages/screen_recorder/test/state/window_mode_controller_test.dart`, update its `_FakeChrome`:
```dart
  @override
  Future<void> setBarSize(double width, double height) async {}
```
(replace the `setBarWidth` override.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_screen_test.dart`
Expected: FAIL — `setBarSize` not defined on `WindowChrome`; the screen still calls `setBarWidth`/measures only width.

- [ ] **Step 3: Implement**

`window_mode.dart` — replace the `setBarWidth` declaration:
```dart
  /// Resizes the floating bar window to [width]×[height] points, keeping its
  /// top-left corner fixed (grows/shrinks on the right & bottom). Native no-ops
  /// unless in bar mode. Hugs the bar's variable content (mic label, meter row).
  Future<void> setBarSize(double width, double height);
```

`window_chrome_channel.dart` — replace the `setBarWidth` impl:
```dart
  @override
  Future<void> setBarSize(double width, double height) async {
    await _channel
        .invokeMethod<void>('setBarSize', {'width': width, 'height': height});
  }
```

`recording_bar_screen.dart`:
- Add height constants near the existing `_lastBarWidth` field area:
```dart
  static const double _kBarHeight = 68;
  static const double _kBarHeightWithMeter = 80;
```
- Replace `double? _lastBarWidth;` with `({double w, double h})? _lastBarSize;`.
- Replace the `_syncBarWidth` method with `_syncBarSize`:
```dart
  /// Measures the bar content's intrinsic width and pairs it with a height that
  /// depends on whether the meter row is shown (a mic is selected). Intrinsic
  /// width keeps native resizes from feeding back into the measurement.
  void _syncBarSize() {
    final box = _barContentKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final content = box.getMaxIntrinsicWidth(double.infinity);
    if (!content.isFinite || content <= 0) return;
    final width = (content + 12).ceilToDouble(); // h-padding 6+6
    final micOn = ref.read(microphoneControllerProvider) != null;
    final height = micOn ? _kBarHeightWithMeter : _kBarHeight;
    final size = (w: width, h: height);
    if (_lastBarSize != null &&
        (_lastBarSize!.w - size.w).abs() < 0.5 &&
        _lastBarSize!.h == size.h) {
      return;
    }
    _lastBarSize = size;
    ref.read(windowChromeProvider).setBarSize(size.w, size.h);
  }
```
- In the mode-change reset block, rename `_lastBarWidth = null` → `_lastBarSize = null`, and in the post-frame callback call `_syncBarSize()` instead of `_syncBarWidth()`. (Find the `if (mode != _lastMode)` block and the `addPostFrameCallback` block added by the prior feature and update the names.)

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_screen_test.dart test/state/window_mode_controller_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/window_mode.dart \
        packages/screen_recorder/lib/platform/window_chrome_channel.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart \
        packages/screen_recorder/test/state/window_mode_controller_test.dart
git commit -m "feat(meter): generalize bar auto-size from setBarWidth to setBarSize (width+height)"
```

---

## Task 3: Native — `MainFlutterWindow` `setBarWidth` → `setBarSize`

Swift task: implement → build → commit.

**Files:**
- Modify: `packages/screen_recorder/macos/Runner/MainFlutterWindow.swift`

- [ ] **Step 1: Implement**

(a) In the channel handler `switch`, replace the `case "setBarWidth"` block with:
```swift
      case "setBarSize":
        guard let args = call.arguments as? [String: Any],
              let width = args["width"] as? Double,
              let height = args["height"] as? Double else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.setBarSize(width: CGFloat(width), height: CGFloat(height))
        result(nil)
```

(b) Replace the `setBarWidth` method with:
```swift
  /// Resize the bar in place to width×height, anchoring the TOP-LEFT corner
  /// (in Cocoa bottom-left coords: keep origin.x; set origin.y so the top edge
  /// stays put). Grows/shrinks on the right & bottom; never re-centers / snaps
  /// to the top of the screen. Bar mode only.
  private func setBarSize(width: CGFloat, height: CGFloat) {
    guard currentMode == "bar" else { return }
    let w = max(320, min(width, 1400))
    let h = max(48, min(height, 200))
    var f = frame
    let top = f.maxY          // current top edge (screen coords)
    f.size.width = w
    f.size.height = h
    f.origin.y = top - h      // keep the top edge fixed
    setFrame(f, display: true)
  }
```

(c) `applyMode("bar")` default stays `configureFloating(width: 736, height: 68, cornerRadius: 18)` (the measured size corrects it). No change needed there.

- [ ] **Step 2: Build**

Run: `cd packages/screen_recorder/macos && pod install >/dev/null 2>&1; cd .. && flutter build macos --debug`
Expected: `Built ... Slipreel.app`. (Runner Swift change — no plugin pod change; `pod install` is harmless.)

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/macos/Runner/MainFlutterWindow.swift
git commit -m "feat(meter): native setBarSize (width+height, top-left anchored)"
```

---

## Task 4: `MicLevelMeter` widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/mic_level_meter.dart`
- Create: `packages/screen_recorder/test/ui/bar/mic_level_meter_test.dart`

- [ ] **Step 1: Write the failing test**

`packages/screen_recorder/test/ui/bar/mic_level_meter_test.dart`:
```dart
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/mic_level_meter.dart';

void main() {
  Widget host(Stream<double> s) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(width: 100, child: MicLevelMeter(levelStream: s)),
          ),
        ),
      );

  testWidgets('fill width tracks the level', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    await tester.pump();

    c.add(0.0);
    await tester.pump();
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 0.0);

    c.add(1.0);
    await tester.pump();
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 1.0);

    c.add(0.5);
    await tester.pump();
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 0.5);

    await c.close();
  });

  testWidgets('fill color shifts to amber then red near clip', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));

    Color fillColor() => (tester
            .widget<Container>(find.byKey(const Key('mic-meter-fill')))
            .decoration as BoxDecoration)
        .color!;

    c.add(0.5);
    await tester.pump();
    final normal = fillColor();

    c.add(0.90);
    await tester.pump();
    expect(fillColor(), isNot(normal)); // amber zone

    c.add(0.99);
    await tester.pump();
    final red = fillColor();
    expect(red.red, greaterThan(red.green)); // reddish near clip

    await c.close();
  });

  testWidgets('clamps out-of-range levels', (tester) async {
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(host(c.stream));
    c.add(2.0);
    await tester.pump();
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 1.0);
    c.add(-1.0);
    await tester.pump();
    expect(tester.widget<FractionallySizedBox>(find.byType(FractionallySizedBox)).widthFactor, 0.0);
    await c.close();
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/mic_level_meter_test.dart`
Expected: FAIL — `MicLevelMeter` undefined.

- [ ] **Step 3: Implement**

`packages/screen_recorder/lib/ui/bar/mic_level_meter.dart`:
```dart
import 'dart:async';
import 'package:flutter/material.dart';

/// A thin horizontal level meter that fills left→right with the latest value
/// from [levelStream] (0..1). Fills the width given by its parent. The fill is
/// the bar's light accent, shifting to amber and then red near clip.
class MicLevelMeter extends StatefulWidget {
  const MicLevelMeter({super.key, required this.levelStream, this.height = 6});

  final Stream<double> levelStream;
  final double height;

  @override
  State<MicLevelMeter> createState() => _MicLevelMeterState();
}

class _MicLevelMeterState extends State<MicLevelMeter> {
  double _level = 0;
  StreamSubscription<double>? _sub;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(MicLevelMeter old) {
    super.didUpdateWidget(old);
    if (old.levelStream != widget.levelStream) {
      _sub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.levelStream.listen((l) {
      if (!mounted) return;
      setState(() => _level = l.isFinite ? l.clamp(0.0, 1.0) : 0.0);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Color get _fillColor {
    if (_level >= 0.97) return const Color(0xFFE5484D); // red near clip
    if (_level >= 0.85) return const Color(0xFFF5A623); // amber
    return const Color(0xFFE9E9EC); // normal accent
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(widget.height / 2),
        child: Stack(
          children: [
            const Positioned.fill(
              child: ColoredBox(color: Color(0x1FFFFFFF)), // track
            ),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: _level,
              child: Container(
                key: const Key('mic-meter-fill'),
                decoration: BoxDecoration(color: _fillColor),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/mic_level_meter_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/mic_level_meter.dart \
        packages/screen_recorder/test/ui/bar/mic_level_meter_test.dart
git commit -m "feat(meter): MicLevelMeter widget (level fill + clip colors)"
```

---

## Task 5: Bar layout — meter row under the mic control

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Modify: `packages/screen_recorder/test/ui/bar/recording_bar_mic_test.dart`

- [ ] **Step 1: Write the failing test**

Add to `packages/screen_recorder/test/ui/bar/recording_bar_mic_test.dart`. Extend the `_bar` helper with an optional stream:
```dart
import 'dart:async';
// ...
RecordingBar _bar({MicrophoneConfig? mic, VoidCallback? onMicTap, Stream<double>? level}) =>
    RecordingBar(
      onPickMode: (_) {},
      onClose: () {},
      onGearTap: () {},
      onDragStart: () {},
      microphone: mic,
      onMicTap: onMicTap ?? () {},
      micLevelStream: level,
    );
```
Add tests:
```dart
import 'package:screen_recorder/ui/bar/mic_level_meter.dart';
// ...
  testWidgets('shows the meter under the mic when a stream is provided',
      (tester) async {
    _wide(tester);
    final c = StreamController<double>.broadcast();
    await tester.pumpWidget(_wrap(_bar(
      mic: const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic'),
      level: c.stream,
    )));
    expect(find.byType(MicLevelMeter), findsOneWidget);
    await c.close();
  });

  testWidgets('no meter when no level stream (off)', (tester) async {
    _wide(tester);
    await tester.pumpWidget(_wrap(_bar(mic: null)));
    expect(find.byType(MicLevelMeter), findsNothing);
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_mic_test.dart`
Expected: FAIL — `RecordingBar` has no `micLevelStream`; no `MicLevelMeter`.

- [ ] **Step 3: Implement**

In `recording_bar.dart`:
- Add import: `import 'mic_level_meter.dart';`
- Add the param + field to `RecordingBar` (after `onMicTap`):
```dart
    this.micLevelStream,
```
```dart
  /// Live mic level (0..1) stream; when non-null a meter is shown under the mic
  /// control. Null when not monitoring.
  final Stream<double>? micLevelStream;
```
- Pass it into `_MicControl`: change the instantiation to
```dart
            _MicControl(
                microphone: microphone,
                onTap: onMicTap,
                levelStream: micLevelStream),
```
- In `_MicControl`, add the field + param:
```dart
  const _MicControl({required this.microphone, required this.onTap, this.levelStream});
  final MicrophoneConfig? microphone;
  final VoidCallback onTap;
  final Stream<double>? levelStream;
```
- Restructure `_MicControl.build` so it returns a `Column` whose first child is the **existing** `SpringHoverButton(...)` (keep its full body exactly as it is today — `key: Key('bar-mic')`, `onTap`, the `SizedBox`/`Row` with icon+label+chevron) and whose optional second child is the meter. Concretely, keep the current `SpringHoverButton(...)` expression and wrap it like this — assign the existing button to a local, then return the Column:
```dart
  @override
  Widget build(BuildContext context) {
    final on = microphone != null;
    final label = on ? microphone!.deviceLabel : 'No microphone';
    final iconColor = on ? const Color(0xFFE9E9EC) : const Color(0xFF6E6E76);
    final textColor = on ? const Color(0xFFE9E9EC) : const Color(0xFF6E6E76);

    final chip = SpringHoverButton(
      key: const Key('bar-mic'),
      onTap: onTap,
      child: SizedBox(
        height: _kBarButtonHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(on ? LucideIcons.mic : LucideIcons.micOff,
                    size: 22, color: iconColor),
                const SizedBox(width: 6),
                // 120pt cap bounds long names; the bar's auto-size measures the
                // same capped width, so the window hugs what renders.
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 120),
                  child: Text(label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      softWrap: false,
                      style: TextStyle(fontSize: 10, color: textColor)),
                ),
                const SizedBox(width: 2),
                const Icon(LucideIcons.chevronDown,
                    size: 13, color: Color(0xFF7E7E86)),
              ],
            ),
          ),
        ),
      ),
    );

    if (levelStream == null) return chip;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        chip,
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: MicLevelMeter(levelStream: levelStream!),
        ),
      ],
    );
  }
```
(When off / not monitoring, `_MicControl` returns just the chip exactly as before — no Column, no height change. `crossAxisAlignment.stretch` makes the meter span the chip's width. **Confirm against the current `_MicControl.build` in `recording_bar.dart` and preserve any detail that differs — copy the real chip body, don't paraphrase.**)

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_mic_test.dart test/ui/bar/recording_bar_test.dart`
Expected: PASS (both — the existing bar tests still pass; the `_bar`/`bar` helpers gained an optional param with a default).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_mic_test.dart
git commit -m "feat(meter): render MicLevelMeter under the mic control"
```

---

## Task 6: Monitor lifecycle in `RecordingBarScreen`

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Modify: `packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart`

- [ ] **Step 1: Write the failing test**

Add `startMicMonitor`/`stopMicMonitor` to the screen test's `_FakePlatform`:
```dart
  final List<MicrophoneConfig> monitorStarts = [];
  int monitorStops = 0;
  @override
  Future<void> startMicMonitor(MicrophoneConfig config) async => monitorStarts.add(config);
  @override
  Future<void> stopMicMonitor() async => monitorStops++;
  @override
  Stream<double> get micLevelStream => const Stream<double>.empty();
```
Add a test:
```dart
  testWidgets('monitor starts when a mic is selected, stops when off',
      (tester) async {
    _wide(tester);
    final fakePlatform = _FakePlatform();
    ScreenRecorderPlatform.instance = fakePlatform;

    late WidgetRef ref;
    await tester.pumpWidget(ProviderScope(
      overrides: [windowChromeProvider.overrideWithValue(_FakeChrome())],
      child: MaterialApp(
        home: Consumer(builder: (c, r, _) {
          ref = r;
          return const RecordingBarScreen();
        }),
      ),
    ));
    await tester.pumpAndSettle();

    expect(fakePlatform.monitorStarts, isEmpty); // off by default

    ref.read(microphoneControllerProvider.notifier)
        .set(const MicrophoneConfig(deviceUid: 'u', deviceLabel: 'Mic'));
    await tester.pumpAndSettle();
    expect(fakePlatform.monitorStarts, hasLength(1));

    ref.read(microphoneControllerProvider.notifier).set(null);
    await tester.pumpAndSettle();
    expect(fakePlatform.monitorStops, greaterThanOrEqualTo(1));
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_screen_test.dart`
Expected: FAIL — monitor never started (no lifecycle wiring).

- [ ] **Step 3: Implement**

In `recording_bar_screen.dart`:
- Add state to track the active monitor config: `MicrophoneConfig? _monitoredConfig;`
- Cache the level stream ONCE so the meter doesn't resubscribe every build (the
  `micLevelStream` getter returns a fresh `receiveBroadcastStream()` each call):
```dart
  late final Stream<double> _micLevelStream =
      ScreenRecorderPlatform.instance.micLevelStream;
```
- Add a sync method:
```dart
  /// Starts/stops the native mic monitor so the level meter only runs while the
  /// bar is showing with a mic selected. Restarts when the device changes.
  void _syncMicMonitor(WindowMode mode, MicrophoneConfig? mic) {
    final shouldMonitor = mode == WindowMode.bar && mic != null;
    final platform = ScreenRecorderPlatform.instance;
    if (shouldMonitor) {
      if (_monitoredConfig != mic) {
        _monitoredConfig = mic;
        platform.startMicMonitor(mic!);
      }
    } else if (_monitoredConfig != null) {
      _monitoredConfig = null;
      platform.stopMicMonitor();
    }
  }
```
- In `build`, after `final mode = ref.watch(...)` and after reading the mic, call it. Add near the top of `build` (after `final mode = ref.watch(windowModeControllerProvider);`):
```dart
    final mic = ref.watch(microphoneControllerProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncMicMonitor(mode, mic);
    });
```
- Pass the cached level stream to the bar only while a mic is selected. In `_buildBar()`, add:
```dart
        micLevelStream: ref.watch(microphoneControllerProvider) != null
            ? _micLevelStream
            : null,
```
- In `dispose()`, stop the monitor: add `if (_monitoredConfig != null) ScreenRecorderPlatform.instance.stopMicMonitor();` before `super.dispose();`.

> Note: `micLevelStream` is a broadcast stream from an `EventChannel`, safe to hand to the widget each build. The `_buildBar` runs in `build`, so `ref.watch` rebuilds when the selection changes.

- [ ] **Step 4: Run to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/bar/recording_bar_screen_test.dart`
Expected: PASS (new test + all existing screen tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/bar/recording_bar_screen_test.dart
git commit -m "feat(meter): start/stop the mic monitor on (bar + mic selected)"
```

---

## Task 7: Native — `MicLevelMonitor`

Swift task: implement → build → commit.

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/MicLevelMonitor.swift`

- [ ] **Step 1: Implement**

`packages/screen_recorder_macos/macos/Classes/MicLevelMonitor.swift`:
```swift
import Foundation
import AVFoundation

/// Lightweight live mic monitor: taps the selected input device, computes a
/// smoothed 0..1 RMS level, and reports it (~20 Hz) via `onLevel`. Separate
/// from AudioCaptureManager so the recording lifecycle stays untangled.
final class MicLevelMonitor {
  var onLevel: ((Double) -> Void)?

  private var engine: AVAudioEngine?
  private var smoothed: Double = 0
  private var lastEmit: CFTimeInterval = 0
  private(set) var isRunning = false

  /// Start monitoring [deviceUid] (nil → default input). [reduceNoise] mirrors
  /// the recorder so the meter reflects the processed signal.
  func start(deviceUid: String?, reduceNoise: Bool, disableAgc: Bool) {
    stop()
    let engine = AVAudioEngine()
    let input = engine.inputNode
    do {
      if let uid = deviceUid, let devID = AudioDeviceCatalog.deviceID(forUID: uid) {
        do { try input.auAudioUnit.setDeviceID(devID) } catch { /* fall back to default */ }
      }
      if reduceNoise {
        try input.setVoiceProcessingEnabled(true)
        if #available(macOS 14.0, *) { input.isVoiceProcessingAGCEnabled = !disableAgc }
      }
      let format = input.outputFormat(forBus: 0)
      input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
        self?.process(buffer)
      }
      try engine.start()
      self.engine = engine
      self.isRunning = true
    } catch {
      input.removeTap(onBus: 0)
      engine.stop()
    }
  }

  func stop() {
    guard isRunning, let engine = engine else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    self.engine = nil
    self.smoothed = 0
    self.isRunning = false
  }

  private func process(_ buffer: AVAudioPCMBuffer) {
    guard let ch = buffer.floatChannelData else { return }
    let frames = Int(buffer.frameLength)
    let channels = Int(buffer.format.channelCount)
    guard frames > 0, channels > 0 else { return }

    // RMS across all channels.
    var sumSquares: Double = 0
    for c in 0..<channels {
      let data = ch[c]
      for i in 0..<frames { let s = Double(data[i]); sumSquares += s * s }
    }
    let rms = (sumSquares / Double(frames * channels)).squareRoot()

    // RMS → dBFS → 0..1 over a -60..0 dB window.
    let db = rms > 0 ? 20 * log10(rms) : -160
    let level = max(0, min(1, (db + 60) / 60))

    // Attack/decay smoothing: rise fast, fall slower.
    let coeff = level > smoothed ? 0.5 : 0.15
    smoothed += (level - smoothed) * coeff

    // Throttle to ~20 Hz.
    let now = CACurrentMediaTime()
    guard now - lastEmit >= 0.05 else { return }
    lastEmit = now
    let out = smoothed
    DispatchQueue.main.async { [weak self] in self?.onLevel?(out) }
  }
}
```
> `CACurrentMediaTime()` needs `import QuartzCore` — `AVFoundation` transitively exposes it on macOS, but if it doesn't resolve, add `import QuartzCore`.

- [ ] **Step 2: Build**

Run: `cd packages/screen_recorder_macos/example && (cd macos && pod install >/dev/null 2>&1); flutter build macos --debug`
Expected: BUILD SUCCEEDED (`pod install` registers the new file).

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/MicLevelMonitor.swift
git commit -m "feat(meter): native MicLevelMonitor (RMS → smoothed 0..1, ~20 Hz)"
```

---

## Task 8: Native — plugin wiring (channel, handler, start/stop, stop-on-record)

Swift task: implement → build → commit.

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

- [ ] **Step 1: Implement**

(a) Add properties to the plugin class (near the other stream handlers, ~line 15):
```swift
  private var micLevelStreamHandler: MicLevelStreamHandler?
  private let micLevelMonitor = MicLevelMonitor()
```

(b) In `register(with:)` (after the cursor channel block, ~line 76), register the channel + wire the monitor:
```swift
    let micLevelChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/micLevel",
      binaryMessenger: registrar.messenger
    )
    instance.micLevelStreamHandler = MicLevelStreamHandler()
    micLevelChannel.setStreamHandler(instance.micLevelStreamHandler)
    instance.micLevelMonitor.onLevel = { [weak instance] level in
      instance?.micLevelStreamHandler?.send(level)
    }
```

(c) In the `handle(_:result:)` switch (next to `showMicrophoneMenu`), add:
```swift
    case "startMicMonitor":
      if let args = call.arguments as? [String: Any] {
        micLevelMonitor.start(
          deviceUid: args["deviceUid"] as? String,
          reduceNoise: args["reduceNoise"] as? Bool ?? false,
          disableAgc: args["disableAgc"] as? Bool ?? false)
      }
      result(nil)
    case "stopMicMonitor":
      micLevelMonitor.stop()
      result(nil)
```

(d) Defensively stop the monitor when a recording starts. At the very top of the `startLiveRecording(call:result:)` method body, add:
```swift
    micLevelMonitor.stop()
```

(e) Add the stream handler class at file scope (near `CursorStreamHandler`, bottom of file):
```swift
// MARK: - Mic Level Stream Handler

class MicLevelStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  /// Called on the main thread by MicLevelMonitor.
  func send(_ level: Double) {
    guard let sink = eventSink, level.isFinite else { return }
    sink(level)
  }
}
```

- [ ] **Step 2: Build**

Run: `cd packages/screen_recorder_macos/example && flutter build macos --debug`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "feat(meter): wire micLevel channel + monitor start/stop, stop on record"
```

---

## Task 9: End-to-end verification

**Files:** none expected (fix-forward only).

- [ ] **Step 1: Full Dart gate**

```bash
cd packages/screen_recorder_platform_interface && flutter test
cd ../screen_recorder_macos && flutter test
cd ../screen_recorder && flutter test
cd ../slipreel_engine && flutter test
```
All green.

- [ ] **Step 2: Full app build**

```bash
cd packages/screen_recorder/macos && pod install >/dev/null 2>&1
cd .. && flutter build macos --debug
```
Expected: `Built ... Slipreel.app`.

- [ ] **Step 3: Boot + manual checks** (flutter-qa harness, real mic)
- Select a mic → a meter appears under the chip and the bar grows taller (stays where dragged, extends down — not re-centered). Speak → the meter moves; silence → near zero; loud → fill approaches full with amber/red near clip.
- Drag the bar down, change the mic device → bar stays put, only resizes; meter restarts for the new device.
- Start a recording → meter disappears (pill), recording still captures audio; stop → bar returns, meter resumes.
- "Don't record microphone" → meter gone, bar shrinks to base height, macOS mic-in-use indicator clears.

- [ ] **Step 4: Commit any fixups**

```bash
git add -p
git commit -m "fix(meter): address issues found in E2E verification"
```

---

## After all tasks
Dispatch a final whole-implementation review, then use **superpowers:finishing-a-development-branch** (merge locally; never push without an explicit request).
