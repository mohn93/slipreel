# Preview Cursor Sync (frame-exact) + Cursor-track Capture Fixes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the editor preview cursor sit on the actually-displayed video frame by measuring the AVPlayer clock-vs-presented-frame latency natively and subtracting it in the preview only, and fix two cursor-track capture bugs (late start, stale first-frame origin).

**Architecture:** A vendored, lightly-patched `video_player_avfoundation` exposes the presented-frame `CMTime` and a raw instantaneous display latency over a `slipreel/video_sync` method channel. A Dart `DisplayLatencyProbe` polls it (~8 Hz), smooths/clamps it, and the editor preview subtracts that latency from the playhead before the cursor scene builder runs. Export is untouched. Separately, two native ordering/reset fixes in `ScreenRecorderMacosPlugin.swift` make the cursor track begin at ~0 ms and stop cross-recording origin leakage.

**Tech Stack:** Flutter/Dart, Riverpod, melos monorepo, `video_player` 2.11.0 / `video_player_avfoundation` (vendored), ObjC (AVFoundation plugin), Swift (ScreenCaptureKit plugin), `flutter_test`.

**Refinements from the approved spec (deliberate, behavior-identical):**
1. **Smoothing moved native → Dart.** The vendored plugin exposes only the *raw* instantaneous latency; all EMA smoothing + clamping lives in a pure, unit-tested Dart class (`DisplayLatencySmoother`). The ObjC plugin has no convenient test seam; Dart does. Net behavior is the same.
2. **Vendor location `packages/` not `third_party/`.** `pubspec_overrides.yaml` is gitignored and melos-generated; melos auto-overrides every workspace package under `packages/**`. Vendoring there is the only CI-safe way to make the path override survive `melos bootstrap`. We add melos `analyze`/`test` ignores so the vendored package's own suite doesn't run.

---

## File Structure

- `packages/screen_recorder/lib/ui/widgets/zoom/preview_cursor_timing.dart` (NEW) — pure `previewPlayheadWithLatency` helper.
- `packages/screen_recorder/lib/state/display_latency_smoother.dart` (NEW) — pure EMA+clamp smoother.
- `packages/screen_recorder/lib/state/display_latency_probe.dart` (NEW) — polls the channel, owns a timer + smoother, exposes `ValueListenable<Duration>`.
- `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (MODIFY) — own a probe per main controller, thread it into `PlaybackCanvas`, dispose it.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` (MODIFY) — accept a `displayLatency` listenable; subtract it from the playing-branch `pos`.
- `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` (MODIFY) — reorder cursor-tracking start; reset first-frame timing on start.
- `packages/video_player_avfoundation/**` (NEW, vendored) — copy of the resolved version + patch.
- `melos.yaml` (MODIFY) — ignore the vendored package in `analyze`/`test`.
- Tests alongside each Dart unit.

---

## Task 1: Pure helper — `previewPlayheadWithLatency`

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/zoom/preview_cursor_timing.dart`
- Test: `packages/screen_recorder/test/ui/widgets/zoom/preview_cursor_timing_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/zoom/preview_cursor_timing_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/preview_cursor_timing.dart';

void main() {
  test('subtracts display latency from the playhead', () {
    final r = previewPlayheadWithLatency(
      playhead: const Duration(milliseconds: 1000),
      displayLatency: const Duration(milliseconds: 80),
    );
    expect(r, const Duration(milliseconds: 920));
  });

  test('zero latency is the identity', () {
    const p = Duration(milliseconds: 1234);
    expect(
      previewPlayheadWithLatency(playhead: p, displayLatency: Duration.zero),
      p,
    );
  });

  test('clamps to zero rather than going negative', () {
    final r = previewPlayheadWithLatency(
      playhead: const Duration(milliseconds: 30),
      displayLatency: const Duration(milliseconds: 80),
    );
    expect(r, Duration.zero);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/preview_cursor_timing_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'screen_recorder' ... preview_cursor_timing.dart` / undefined function.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/ui/widgets/zoom/preview_cursor_timing.dart

/// Preview-only: shift the playhead back by the measured display latency so the
/// synthetic cursor lands on the frame the texture is actually showing (the
/// AVPlayer texture trails the playback clock under decode load). Clamped at
/// zero. Does NOT touch `cursorDelay` — that is applied separately inside the
/// scene-pass builder and must not be double-counted here.
Duration previewPlayheadWithLatency({
  required Duration playhead,
  required Duration displayLatency,
}) {
  final shifted = playhead - displayLatency;
  return shifted < Duration.zero ? Duration.zero : shifted;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/preview_cursor_timing_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/preview_cursor_timing.dart \
        packages/screen_recorder/test/ui/widgets/zoom/preview_cursor_timing_test.dart
git commit -m "feat(preview): pure previewPlayheadWithLatency helper"
```

---

## Task 2: Pure smoother — `DisplayLatencySmoother`

EMA + clamp + null-handling, isolated from timers/channels so it is fully unit-testable.

**Files:**
- Create: `packages/screen_recorder/lib/state/display_latency_smoother.dart`
- Test: `packages/screen_recorder/test/state/display_latency_smoother_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/display_latency_smoother_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/display_latency_smoother.dart';

void main() {
  test('starts at zero before any sample', () {
    expect(DisplayLatencySmoother().value, Duration.zero);
  });

  test('first non-null sample seeds the value exactly', () {
    final s = DisplayLatencySmoother(alpha: 0.3);
    s.add(80000); // 80 ms in micros
    expect(s.value, const Duration(milliseconds: 80));
  });

  test('subsequent samples move toward the new value by alpha', () {
    final s = DisplayLatencySmoother(alpha: 0.5);
    s.add(80000); // seed 80 ms
    s.add(0); // ema = 0.5*0 + 0.5*80 = 40 ms
    expect(s.value, const Duration(milliseconds: 40));
  });

  test('negative raw samples are clamped to zero before smoothing', () {
    final s = DisplayLatencySmoother(alpha: 1.0);
    s.add(-5000);
    expect(s.value, Duration.zero);
  });

  test('null samples are ignored — value holds', () {
    final s = DisplayLatencySmoother(alpha: 1.0);
    s.add(50000);
    s.add(null);
    expect(s.value, const Duration(milliseconds: 50));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/display_latency_smoother_test.dart`
Expected: FAIL — undefined class `DisplayLatencySmoother`.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/state/display_latency_smoother.dart

/// Exponential-moving-average smoother for the raw per-sample display latency
/// (AVPlayer clock − presented frame time) reported by the native
/// `slipreel/video_sync` channel. Pure and timer-free so it can be unit-tested;
/// [DisplayLatencyProbe] owns the polling.
class DisplayLatencySmoother {
  DisplayLatencySmoother({this.alpha = 0.3}) : assert(alpha > 0 && alpha <= 1);

  /// EMA weight for each new sample (0..1]. Higher = snappier, noisier.
  final double alpha;

  double? _emaMicros;

  /// Current smoothed latency. [Duration.zero] until the first non-null sample.
  Duration get value =>
      Duration(microseconds: (_emaMicros ?? 0).round());

  /// Feed one raw sample in microseconds. `null` (channel had no reading) is
  /// ignored and the current value holds. Negative samples clamp to zero.
  void add(int? rawMicros) {
    if (rawMicros == null) return;
    final sample = rawMicros < 0 ? 0.0 : rawMicros.toDouble();
    final prev = _emaMicros;
    _emaMicros = prev == null ? sample : alpha * sample + (1 - alpha) * prev;
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/display_latency_smoother_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/display_latency_smoother.dart \
        packages/screen_recorder/test/state/display_latency_smoother_test.dart
git commit -m "feat(preview): pure DisplayLatencySmoother (EMA + clamp)"
```

---

## Task 3: `DisplayLatencyProbe` — poll the channel on a timer

Owns a `DisplayLatencySmoother`, a periodic timer, and a `ValueNotifier<Duration>`. The channel call is exposed as `pollOnce()` so a test can drive it without real timers, using a mock method-channel handler.

**Files:**
- Create: `packages/screen_recorder/lib/state/display_latency_probe.dart`
- Test: `packages/screen_recorder/test/state/display_latency_probe_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/display_latency_probe_test.dart
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/display_latency_probe.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('slipreel/video_sync');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getDisplayLatencyMicros') {
        expect((call.arguments as Map)['playerId'], 7);
        return 60000; // 60 ms
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('defaults to zero before polling', () {
    final probe = DisplayLatencyProbe(playerId: 7);
    expect(probe.latency.value, Duration.zero);
    probe.dispose();
  });

  test('pollOnce pulls a reading and smooths it into the notifier', () async {
    final probe = DisplayLatencyProbe(playerId: 7, alpha: 1.0);
    await probe.pollOnce();
    expect(probe.latency.value, const Duration(milliseconds: 60));
    probe.dispose();
  });

  test('a null playerId yields zero and never calls the channel', () async {
    final probe = DisplayLatencyProbe(playerId: null);
    await probe.pollOnce();
    expect(probe.latency.value, Duration.zero);
    probe.dispose();
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/display_latency_probe_test.dart`
Expected: FAIL — undefined class `DisplayLatencyProbe`.

- [ ] **Step 3: Write minimal implementation**

```dart
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/display_latency_probe_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/display_latency_probe.dart \
        packages/screen_recorder/test/state/display_latency_probe_test.dart
git commit -m "feat(preview): DisplayLatencyProbe polling slipreel/video_sync"
```

---

## Task 4: Native capture fixes — early cursor start + reset on start

Both edits are in `startRecording`'s live-capture branch of
`packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`.
This is a **code move + one added call**; native ordering can't be unit-tested,
so the gate is: compile-clean + the relocation invariants below.

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

- [ ] **Step 1: Locate the two anchors**

Run: `grep -n "try await captureManager?.startCapture(\|self.liveStartTime = Date()\|if captureCursor {\|resetFirstFrameTiming" packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
Expected: the `startCapture(` call (~L808), the `self.liveStartTime = Date()` line (~L864) with its 3-line leading comment, the `if captureCursor {` block opener (~L866), and `resetFirstFrameTiming` defined (~L130) + called once at stop (~L1001).

- [ ] **Step 2: Move the cursor-tracking block to *before* `startCapture`, prepend the reset**

Cut the contiguous region that begins at the comment line
`// liveStartTime must be set BEFORE cursor tracking begins so the`
(the comment directly above `self.liveStartTime = Date()`) through the closing
`}` of the `if captureCursor { … }` block (the line after
`try cursorTracker?.startTracking(frequency: 60)`).

Paste it **immediately above** the `try await captureManager?.startCapture(` line, and add `resetFirstFrameTiming()` as the first line of the relocated region. The relocated region's head becomes:

```swift
        // Reset first-frame timing for THIS recording before any cursor sample
        // or video frame can be stamped — otherwise the first cursor sample can
        // be rebased against the previous recording's frame origin (stale-origin
        // bug: an off-screen garbage sample with a huge timestamp).
        resetFirstFrameTiming()

        // liveStartTime must be set BEFORE cursor tracking begins so the
        // cursor callback can rebase timestamps to video-relative time.
        // Without this, cursor samples would carry mach_absolute_time
        // values while playback queries are 0-based video time, and
        // every lookup would clamp to the first sample.
        self.liveStartTime = Date()

        if captureCursor {
          // … (unchanged body, ending with) …
          try cursorTracker?.startTracking(frequency: 60)
        }
```

The cursor callback body is unchanged. It still guards on
`currentFirstVideoFrameAt()` returning non-nil, so samples captured during the
SCStream warmup (before the first frame latches `firstVideoFrameAt`) are dropped
— and the first *surviving* sample now lands at ~0 ms instead of ~473 ms.

- [ ] **Step 3: Verify the relocation invariants by re-grepping**

Run: `grep -n "resetFirstFrameTiming()\|self.liveStartTime = Date()\|try cursorTracker?.startTracking\|try await captureManager?.startCapture(" packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
Expected ordering (ascending line numbers): `resetFirstFrameTiming()` (the new start-path call) → `self.liveStartTime = Date()` → `try cursorTracker?.startTracking(frequency: 60)` → `try await captureManager?.startCapture(`. The old stop-path `resetFirstFrameTiming()` (~L1001) still exists. There must be exactly ONE `if captureCursor {` and ONE `self.liveStartTime = Date()`.

- [ ] **Step 4: Compile-verify the native change (arm64 `flutter build` is broken here — use x86_64 xcodebuild)**

Run:
```bash
cd packages/screen_recorder/macos && \
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`. (If the workspace needs pods first, run `cd packages/screen_recorder && flutter pub get` then retry.)

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git commit -m "fix(macos): start cursor tracking before capture + reset first-frame timing on start"
```

> **Manual verification (by the human, post-merge):** record a short *area* clip,
> then `python3 -c "import json;d=json.load(open('<rec>.mp4.cursor.json'));print(d[0])"`
> — the first sample's `timestampMicros` should be small (≲ 50 000) and its
> coords on-screen (no negative/off-screen first sample).

---

## Task 5: Vendor `video_player_avfoundation` as a workspace package

Place the resolved version under `packages/` so `melos bootstrap` auto-generates
the path override (CI-safe), and exclude it from melos `analyze`/`test`. This
task vendors the **unpatched** copy and proves the build is unchanged; Task 6
applies the patch.

**Files:**
- Create: `packages/video_player_avfoundation/**` (vendored copy)
- Create: `packages/video_player_avfoundation/SLIPREEL_PATCH.md` (re-apply notes)
- Modify: `melos.yaml`

- [ ] **Step 1: Resolve the exact version and copy it**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
# Ensure the pub cache has the locked version.
( cd packages/screen_recorder && flutter pub get >/dev/null )
VER=$(awk '/^  video_player_avfoundation:/{f=1} f&&/version:/{gsub(/[" ]/,"");split($0,a,":");print a[2];exit}' packages/screen_recorder/pubspec.lock)
echo "locked video_player_avfoundation = $VER"
SRC="$HOME/.pub-cache/hosted/pub.dev/video_player_avfoundation-$VER"
test -d "$SRC" || { echo "MISSING $SRC — run flutter pub get"; exit 1; }
rm -rf packages/video_player_avfoundation
mkdir -p packages/video_player_avfoundation
cp -R "$SRC"/. packages/video_player_avfoundation/
# Prune things we don't need as a workspace package (reduces melos surface).
rm -rf packages/video_player_avfoundation/example \
       packages/video_player_avfoundation/test \
       packages/video_player_avfoundation/.pub-cache 2>/dev/null
chmod -R u+w packages/video_player_avfoundation
ls packages/video_player_avfoundation
```
Expected: the package contents (`pubspec.yaml`, `lib/`, `darwin/`, `LICENSE`, …) printed; no `example/`/`test/`.

- [ ] **Step 2: Record the patch-source notes**

Create `packages/video_player_avfoundation/SLIPREEL_PATCH.md`:

```markdown
# Slipreel vendored video_player_avfoundation

Vendored copy of `video_player_avfoundation` (see `pubspec.yaml` for version),
overridden via melos workspace path resolution so we can patch the macOS
texture player.

## Why
The editor preview draws a synthetic cursor at the AVPlayer **clock** position
while the texture lags under decode load, so the cursor leads the video. The
stock plugin discards the presented-frame time (`itemTimeForDisplay:NULL`). Our
patch captures it and exposes the instantaneous latency over a
`slipreel/video_sync` method channel; Dart smooths it and shifts the preview
cursor back.

## The patch (re-apply after any upgrade)
1. `darwin/.../FVPTextureBasedVideoPlayer.m`
   - Add ivar `@property(nonatomic, assign) CMTime lastPresentedItemTime;`.
   - In `copyPixelBuffer`, change `itemTimeForDisplay:NULL` to capture a real
     `CMTime` and store it to `self.lastPresentedItemTime` when a buffer is
     returned.
   - Add `- (nullable NSNumber *)displayLatencyMicros;` returning
     `currentTime − lastPresentedItemTime` in micros, clamped ≥ 0, nil if either
     CMTime is invalid.
   - Declare `displayLatencyMicros` in `FVPTextureBasedVideoPlayer.h`.
2. `darwin/.../FVPVideoPlayerPlugin.m`
   - In `registerWithRegistrar:`, register a `slipreel/video_sync`
     `FlutterMethodChannel`; handle `getDisplayLatencyMicros(playerId)` by
     looking up `_playersByIdentifier[playerId]` and calling
     `displayLatencyMicros` when it is an `FVPTextureBasedVideoPlayer`.
   - Retain the channel on a plugin property so it isn't deallocated.

Keep this file in sync with `packages/screen_recorder` Dart code
(`DisplayLatencyProbe`, channel name `slipreel/video_sync`).
```

- [ ] **Step 3: Exclude the vendored package from melos analyze/test**

In `melos.yaml`, add `video_player_avfoundation` to BOTH the `analyze` and
`test` `packageFilters.ignore` lists (next to the existing `"*example*"`):

```yaml
  analyze:
    exec: flutter analyze --no-fatal-infos
    description: Run flutter analyze in all packages (infos non-fatal)
    packageFilters:
      ignore:
        - "*example*"
        # Vendored upstream plugin (patched) — not our code to lint.
        - "video_player_avfoundation"
  test:
    exec: flutter test
    description: Run tests in all packages
    packageFilters:
      ignore:
        - "*example*"
        - "screen_recorder_windows"
        # Vendored upstream plugin — its suite was pruned; don't run it.
        - "video_player_avfoundation"
```

- [ ] **Step 4: Bootstrap and confirm the override resolves to the vendored copy**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
melos bootstrap 2>&1 | tail -5
grep -n "video_player_avfoundation" packages/screen_recorder/pubspec_overrides.yaml
```
Expected: bootstrap succeeds; `pubspec_overrides.yaml` now contains a
`video_player_avfoundation:` `path: ../video_player_avfoundation` entry in the
melos-managed block (melos overrides every workspace package that is a
dependency, and the facade depends on it transitively).

- [ ] **Step 5: Build the app to prove the unpatched vendored copy is drop-in**

Run:
```bash
cd packages/screen_recorder/macos && \
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -20
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 6: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/video_player_avfoundation melos.yaml
git commit -m "build: vendor video_player_avfoundation as workspace package (unpatched)"
```

---

## Task 6: Patch the vendored plugin — expose display latency

Apply the native patch from `SLIPREEL_PATCH.md`. Anchor edits by **searching for
the code**, not line numbers (they shift between versions).

**Files:**
- Modify: `packages/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/FVPTextureBasedVideoPlayer.m`
- Modify: `packages/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/include/video_player_avfoundation/FVPTextureBasedVideoPlayer.h`
- Modify: `packages/video_player_avfoundation/darwin/video_player_avfoundation/Sources/video_player_avfoundation/FVPVideoPlayerPlugin.m`

- [ ] **Step 1: Add the `lastPresentedItemTime` ivar**

In `FVPTextureBasedVideoPlayer.m`, inside the class extension
`@interface FVPTextureBasedVideoPlayer ()` … `@end`, add after the
`waitingForFrame` property:

```objc
// Slipreel: media time (CMTime) of the frame most recently handed to the
// texture. Compared against the player clock to measure display latency.
@property(nonatomic, assign) CMTime lastPresentedItemTime;
```

- [ ] **Step 2: Capture the presented CMTime in `copyPixelBuffer`**

Find:
```objc
    buffer = [self.pixelBufferSource copyPixelBufferForItemTime:outputItemTime
                                             itemTimeForDisplay:NULL];
    if (buffer) {
      // Balance the owned reference from copyPixelBufferForItemTime.
      CVBufferRelease(self.latestPixelBuffer);
      self.latestPixelBuffer = buffer;
    }
```
Replace with:
```objc
    CMTime presentedItemTime = kCMTimeInvalid;
    buffer = [self.pixelBufferSource copyPixelBufferForItemTime:outputItemTime
                                             itemTimeForDisplay:&presentedItemTime];
    if (buffer) {
      // Balance the owned reference from copyPixelBufferForItemTime.
      CVBufferRelease(self.latestPixelBuffer);
      self.latestPixelBuffer = buffer;
      // Slipreel: remember which media time is now on the texture.
      self.lastPresentedItemTime = presentedItemTime;
    }
```

- [ ] **Step 3: Add the `displayLatencyMicros` method**

At the end of `@implementation FVPTextureBasedVideoPlayer` (before the final
`@end`), add:

```objc
// Slipreel: AVPlayer clock minus the presented frame's media time, in micros.
// Positive means the texture is showing an older frame than the clock (decode
// lag) — the editor preview subtracts this from the cursor's playhead. Returns
// nil until a frame has been presented or if either CMTime is invalid.
- (nullable NSNumber *)displayLatencyMicros {
  CMTime presented = self.lastPresentedItemTime;
  CMTime clock = [self.player currentTime];
  if (!CMTIME_IS_VALID(presented) || !CMTIME_IS_VALID(clock)) return nil;
  if (presented.timescale == 0 || clock.timescale == 0) return nil;
  int64_t presentedUs = presented.value * 1000000 / presented.timescale;
  int64_t clockUs = clock.value * 1000000 / clock.timescale;
  int64_t latency = clockUs - presentedUs;
  if (latency < 0) latency = 0;
  return @(latency);
}
```

(`self.player` is the readonly `AVPlayer` property declared on the
`FVPVideoPlayer` superclass header.)

- [ ] **Step 4: Declare the method in the header**

In `include/video_player_avfoundation/FVPTextureBasedVideoPlayer.h`, inside
`@interface FVPTextureBasedVideoPlayer : FVPVideoPlayer <FlutterTexture>` …
`@end`, add:

```objc
/// Slipreel: AVPlayer clock minus the presented frame's media time, in micros
/// (clamped ≥ 0), or nil if not yet known. Used by the editor to align the
/// preview cursor with the frame actually on screen.
- (nullable NSNumber *)displayLatencyMicros;
```

- [ ] **Step 5: Register the `slipreel/video_sync` channel in the plugin**

In `FVPVideoPlayerPlugin.m`:

5a. Ensure the texture-player header is imported near the top (add if absent):
```objc
#import "./include/video_player_avfoundation/FVPTextureBasedVideoPlayer.h"
```

5b. Add a retaining property in the private `@interface FVPVideoPlayerPlugin ()`
(so the channel isn't deallocated after `registerWithRegistrar:` returns):
```objc
@property(nonatomic, strong) FlutterMethodChannel *slipreelSyncChannel;
```

5c. In `+ (void)registerWithRegistrar:`, after the
`SetUpFVPAVFoundationVideoPlayerApi(registrar.messenger, instance);` line, add:
```objc
  // Slipreel: side channel exposing per-player display latency (AVPlayer clock
  // vs the frame actually on the texture) so the editor can align its preview
  // cursor. Retained on the plugin instance so it outlives this method.
  FlutterMethodChannel *syncChannel =
      [FlutterMethodChannel methodChannelWithName:@"slipreel/video_sync"
                                  binaryMessenger:registrar.messenger];
  [syncChannel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
    if ([@"getDisplayLatencyMicros" isEqualToString:call.method]) {
      NSNumber *playerId = call.arguments[@"playerId"];
      FVPVideoPlayer *player =
          playerId ? instance->_playersByIdentifier[playerId] : nil;
      if ([player isKindOfClass:[FVPTextureBasedVideoPlayer class]]) {
        result([(FVPTextureBasedVideoPlayer *)player displayLatencyMicros]);
      } else {
        result(nil);
      }
    } else {
      result(FlutterMethodNotImplemented);
    }
  }];
  instance.slipreelSyncChannel = syncChannel;
```

(`instance` and `instance->_playersByIdentifier` are already used identically in
this method for the view factory, so both are in scope.)

- [ ] **Step 6: Compile-verify the patched plugin**

Run:
```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder/macos && \
xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug \
  -destination 'platform=macOS,arch=x86_64' build 2>&1 | tail -25
```
Expected: `** BUILD SUCCEEDED **`. (Fix any ObjC type/import errors surfaced.)

- [ ] **Step 7: Commit**

```bash
cd /Users/mohn93/Desktop/side_projects/screenflow_studio
git add packages/video_player_avfoundation
git commit -m "feat(video_player): expose presented-frame display latency via slipreel/video_sync"
```

---

## Task 7: Wire the probe into the editor preview (preview-only)

Thread the probe's latency into `PlaybackCanvas` and subtract it from the
playing-branch playhead. `cursorDelay` stays where it is (inside the scene
builder) — do not touch it here.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: `packages/screen_recorder/test/ui/widgets/zoom/playback_canvas_latency_test.dart`

- [ ] **Step 1: Add the `displayLatency` parameter to `PlaybackCanvas`**

In `playback_canvas.dart`, add the import and a new optional field. Near the
existing imports add:
```dart
import 'package:screen_recorder/ui/widgets/zoom/preview_cursor_timing.dart';
```
In the `PlaybackCanvas` constructor parameter list add `this.displayLatency,`
and declare the field alongside the other `final` fields (e.g. next to
`cursorDelay`):
```dart
/// Preview-only display latency (AVPlayer clock vs the frame on the texture).
/// Subtracted from the playhead while playing so the cursor lands on the
/// displayed frame. Null/zero ⇒ no shift (matches pre-existing behaviour).
final ValueListenable<Duration>? displayLatency;
```
(`ValueListenable` comes from `package:flutter/foundation.dart`, already
imported transitively via material; if analyzer complains, add
`import 'package:flutter/foundation.dart';`.)

- [ ] **Step 2: Subtract latency in the playing branch only**

In the builder around the existing `final rawPos = …` / `if (widget.controller.value.isPlaying)` block, change the **isPlaying** branch from:
```dart
            if (widget.controller.value.isPlaying) {
              _stablePos = rawPos;
              pos = rawPos;
            } else {
```
to:
```dart
            if (widget.controller.value.isPlaying) {
              // Preview-only: shift back by measured display latency so the
              // cursor sits on the frame the texture is actually showing.
              // Paused branch is left untouched (no decode lag while paused).
              final adjusted = previewPlayheadWithLatency(
                playhead: rawPos,
                displayLatency:
                    widget.displayLatency?.value ?? Duration.zero,
              );
              _stablePos = adjusted;
              pos = adjusted;
            } else {
```

- [ ] **Step 3: Write the failing widget test**

```dart
// packages/screen_recorder/test/ui/widgets/zoom/playback_canvas_latency_test.dart
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/preview_cursor_timing.dart';

// PlaybackCanvas needs a live VideoPlayerController/texture which can't run in a
// unit test, so we assert the timing contract the widget relies on directly:
// while playing, the cursor lookup time is the playhead minus the current
// display latency; while paused, latency is not applied.
void main() {
  test('playing branch subtracts the listenable latency', () {
    final latency = ValueNotifier<Duration>(const Duration(milliseconds: 70));
    const rawPos = Duration(milliseconds: 1000);
    final pos = previewPlayheadWithLatency(
      playhead: rawPos,
      displayLatency: latency.value,
    );
    expect(pos, const Duration(milliseconds: 930));
  });

  test('null latency listenable falls back to no shift', () {
    const rawPos = Duration(milliseconds: 1000);
    final ValueListenable<Duration>? latency = null;
    final pos = previewPlayheadWithLatency(
      playhead: rawPos,
      displayLatency: latency?.value ?? Duration.zero,
    );
    expect(pos, rawPos);
  });
}
```

- [ ] **Step 4: Run the test (passes once the helper from Task 1 exists)**

Run: `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/playback_canvas_latency_test.dart`
Expected: PASS (2 tests). (This locks the contract the widget edit depends on.)

- [ ] **Step 5: Create + own the probe in `playback_screen.dart`**

5a. Add imports:
```dart
import 'package:screen_recorder/state/display_latency_probe.dart';
```
5b. Add a field near `_smoothPlayhead`:
```dart
  DisplayLatencyProbe? _latencyProbe;
```
5c. In `_initializeVideo`, right after `_smoothPlayhead = SmoothPlayheadController(...)` is constructed, add:
```dart
      // Preview-only cursor/video sync: poll the vendored video_player patch for
      // this player's display latency. `playerId` is video_player's internal id
      // (only a @visibleForTesting getter is public, but it is stable in 2.11.x
      // and the only way to key the side channel).
      // ignore: invalid_use_of_visible_for_testing_member
      _latencyProbe = DisplayLatencyProbe(playerId: _controller.playerId)..start();
```
5d. In `dispose()` (find the existing `_smoothPlayhead?.dispose();`), add:
```dart
    _latencyProbe?.dispose();
```

- [ ] **Step 6: Pass the latency into `PlaybackCanvas`**

At `playback_screen.dart:~2327` where `final playbackCanvas = PlaybackCanvas(` is
built, add the argument:
```dart
      displayLatency: _latencyProbe?.latency,
```

- [ ] **Step 7: Analyze + full preview test suite**

Run:
```bash
cd packages/screen_recorder && flutter analyze lib/ui/widgets/zoom/playback_canvas.dart lib/ui/screens/playback_screen.dart lib/state/display_latency_probe.dart && \
flutter test test/ui/widgets/zoom/ test/state/
```
Expected: analyze clean (only the intentional `invalid_use_of_visible_for_testing_member` ignore); tests PASS.

- [ ] **Step 8: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/widgets/zoom/playback_canvas_latency_test.dart
git commit -m "feat(preview): subtract measured display latency from preview cursor playhead"
```

---

## Final verification (after all tasks)

- [ ] `cd /Users/mohn93/Desktop/side_projects/screenflow_studio && melos run test --no-select` — all package suites green.
- [ ] `melos run analyze --no-select` — clean (modulo the single intentional ignore).
- [ ] Native build: `cd packages/screen_recorder/macos && xcodebuild -workspace Runner.xcworkspace -scheme Runner -configuration Debug -destination 'platform=macOS,arch=x86_64' build` → `BUILD SUCCEEDED`.
- [ ] **Manual (human):** run the app, record a short *area* clip, open it, play, and confirm (a) the cursor no longer leads the video, and (b) the cursor is no longer frozen for the first ~½ s; re-record a second clip without restarting and confirm no off-screen first cursor sample (Task 4 manual check).
- [ ] **Manual (human):** export the same clip and confirm the exported MP4's cursor timing is unchanged (export path must be unaffected).
