# Manual Zoom Screen Preview — Implementation Plan

> **For agentic workers:** Execute task-by-task, TDD, commit per task. Design rationale lives in `docs/superpowers/specs/2026-06-21-manual-zoom-screen-preview-design.md`.

**Goal:** Render the actual screen (a video frame at the zoom's start time) behind the manual-zoom placement box, with the selected region spotlighted, so the user can see what they're framing.

**Architecture:** A new `frameExtractorProvider` (`FutureProvider.autoDispose.family`) shells out to ffmpeg for one frame → `ui.Image`; `ZoomContextInspector` watches it (keyed on `zoom.startTime`) and hands the image to `ZoomPlacementPicker`, which paints it + a spotlight under the existing draggable rect.

**Tech Stack:** Flutter, Riverpod, `dart:ui`, ffmpeg via `Ffmpeg.resolve()` (`slipreel_engine/lib/export/ffmpeg_resolver.dart`). Tests: `cd packages/screen_recorder && flutter test …`; full suite `melos run test`.

---

### Task B1: `frame_extractor_provider` (new)

**Files:**
- Create: `packages/screen_recorder/lib/state/frame_extractor_provider.dart`
- Test: `packages/screen_recorder/test/state/frame_extractor_provider_test.dart` (new)

**Shape:**
```dart
@immutable
class FrameKey {
  const FrameKey(this.videoPath, this.atMicros, this.width, this.height);
  final String videoPath; final int atMicros; final int width; final int height;
  @override bool operator ==(Object o) => o is FrameKey && o.videoPath == videoPath
      && o.atMicros == atMicros && o.width == width && o.height == height;
  @override int get hashCode => Object.hash(videoPath, atMicros, width, height);
}

final frameExtractorProvider =
    FutureProvider.autoDispose.family<ui.Image?, FrameKey>((ref, key) async {
  final bytes = await _extractFrameRgba(key);     // ffmpeg → RGBA, null on any failure
  if (bytes == null) return null;
  return decodeRgbaToImage(bytes, key.width, key.height);
});
```
- `_extractFrameRgba`: `Process.run(Ffmpeg.resolve(), ['-loglevel','error','-ss',(atMicros/1e6).toStringAsFixed(3),'-i',videoPath,'-frames:v','1','-vf','scale=$w:$h','-f','rawvideo','-pix_fmt','rgba','-'], stdoutEncoding: null)`; return null on non-zero/short output; wrap in try/catch → null.
- `decodeRgbaToImage`: `ui.decodeImageFromPixels(bytes, w, h, ui.PixelFormat.rgba8888, completer.complete)`. **Use rgba + rgba8888** (do NOT copy the thumbnail extractor's bgra→rgba8888 channel swap).

- [ ] **Step 1: Failing tests** (deterministic — no ffmpeg/video needed):

```dart
test('FrameKey value-equality', () {
  expect(const FrameKey('/v.mp4', 1000, 280, 600),
         const FrameKey('/v.mp4', 1000, 280, 600));
  expect(const FrameKey('/v.mp4', 1000, 280, 600).hashCode,
         const FrameKey('/v.mp4', 1000, 280, 600).hashCode);
  expect(const FrameKey('/v.mp4', 1000, 280, 600) ==
         const FrameKey('/v.mp4', 2000, 280, 600), isFalse);
});

test('decodeRgbaToImage builds a ui.Image of the right size', () async {
  final bytes = Uint8List(2 * 2 * 4); // 2x2 transparent
  final img = await decodeRgbaToImage(bytes, 2, 2);
  expect(img.width, 2);
  expect(img.height, 2);
});
```

- [ ] **Step 2: Run → fail.** `cd packages/screen_recorder && flutter test test/state/frame_extractor_provider_test.dart`
- [ ] **Step 3: Implement** the provider, `FrameKey`, `_extractFrameRgba`, and a top-level `decodeRgbaToImage` (exported for the test). End-to-end extraction is runtime-verified (Task B-verify), not unit-tested (needs ffmpeg + a fixture).
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit.** `feat(editor): frame_extractor_provider (ffmpeg single-frame → ui.Image)`

---

### Task B2: `ZoomPlacementPicker` background frame + spotlight

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/zoom_placement_picker.dart`
- Test: `packages/screen_recorder/test/ui/zoom_placement_picker_test.dart` (new)

- [ ] **Step 1: Failing widget test** — pump `ZoomPlacementPicker(..., backgroundImage: img)` (img = synthetic 4×4 `ui.Image`); expect `find.byKey(const Key('zoom-placement-frame'))` and `find.byKey(const Key('zoom-placement-spotlight'))` present. With `backgroundImage: null` → frame key absent (dark fallback only).
- [ ] **Step 2: Run → fail.**
- [ ] **Step 3: Implement.** Add `final ui.Image? backgroundImage;` (default null). Inside the `Stack` (currently `zoom_placement_picker.dart:114`), **before** the existing `Positioned` inner rect, insert two `Positioned.fill` layers:
  1. `CustomPaint(key: Key('zoom-placement-frame'), painter: _FramePainter(backgroundImage, widget.videoSize))` — `drawImageRect(image, src=full image, dst=size, Paint()..filterQuality = FilterQuality.medium)`. Only build when `backgroundImage != null` (dark `DecoratedBox` fill remains the fallback).
  2. `CustomPaint(key: Key('zoom-placement-spotlight'), painter: _SpotlightPainter(selectionRectInMini))` where the selection rect = `Rect.fromLTWH(innerLeft, innerTop, innerW, innerH)` (already computed). Paint: `saveLayer(full)`, `drawRect(full, Paint()..color=Colors.black54)`, `drawRect(selection, Paint()..blendMode=BlendMode.clear)`, `restore()`.
  The existing purple `Positioned` rect stays on top (border/handle, gestures unchanged).
- [ ] **Step 4: Run → pass.**
- [ ] **Step 5: Commit.** `feat(editor): frame + spotlight behind manual-zoom placement box`

---

### Task B3: thread `videoPath` + watch provider → picker

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart` (pass `widget.videoPath` to `InspectorPanel` `:2193`)
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart` (add `final String videoPath;`, forward to `ZoomContextInspector`)
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart` (watch provider, pass image)

- [ ] **Step 1:** In `ZoomContextInspector.build`, when rendering `ZoomPlacementPicker` (`:76-100`), compute the mini-frame target px (e.g. `w = min(280, videoSize.width).round()`-derived, aspect-preserved, ≤640 longest side) and:
  `final img = ref.watch(frameExtractorProvider(FrameKey(videoPath, zoom.startTime.inMicroseconds, w, h))).valueOrNull;`
  then pass `backgroundImage: img`.
- [ ] **Step 2:** Thread `videoPath` down: `PlaybackScreen` (`widget.videoPath`) → `InspectorPanel` → `ZoomContextInspector`. Make `ZoomContextInspector` a `ConsumerWidget` (or wrap in `Consumer`) if not already, to `ref.watch`.
- [ ] **Step 3:** Widget test (optional) — override `frameExtractorProvider` to return a synthetic image and assert `ZoomPlacementPicker` receives a non-null `backgroundImage`.
- [ ] **Step 4: Run** `cd packages/screen_recorder && flutter test` (package) → green.
- [ ] **Step 5: Commit.** `feat(editor): wire video frame into manual-zoom placement preview`

---

**Done-when:** `melos run test` green; runtime: open any recording, add/select a manual zoom → the placement box shows the screen frame with the selected region spotlighted, dragging the box updates the spotlight correctly.
