# Padding-preserving Zoom (Hybrid) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** During a zoom the framed card pushes in (scales up toward a clamp), the wallpaper padding shrinks only to a floor and never to zero, and the focal region is magnified by the full zoom level inside the rounded window — in both preview and export.

**Architecture:** A shared pure helper (`ZoomTransformer.resolveCardPushIn`) turns the effective zoom factor + padding floor into a clamped **card scale** `zCard` and a centered **card rect**. The chrome (frame/shadow) is scaled by `zCard` (centered); the content (video+cursor) keeps the FULL zoom transform (`getTransform`, unchanged) but is clipped to the centered card rect (rounded, radius `cornerRadius·zCard`). This extends the current branch (which already clips content to a fixed rect): chrome now grows by `zCard` and the clip rect follows it.

**Tech Stack:** Dart / Flutter; `flutter_test`; `dart:ui` Canvas; `Transform`/`ClipPath`.

**Spec:** `docs/superpowers/specs/2026-06-15-padding-preserving-zoom-design.md` (hybrid).

**Branch state:** `feat/padding-preserving-zoom` currently implements the *fixed-frame* model (chrome un-zoomed, content clipped to fixed `_videoRect`). This plan revises that to the hybrid. The effective zoom factor `z` at a frame is the scale of the zoom matrix: `zoomTransform.storage[0]` (export) / `transform.storage[0]` (preview).

---

## File Structure

- **Modify** `packages/slipreel_engine/lib/effects/zoom_transformer.dart` — add `resolveCardPushIn` pure helper. (Task A)
- **Modify** `packages/slipreel_engine/lib/export/frame_compositor.dart` — scale chrome by `zCard`; clip content to the grown card rect. (Task B)
- **Modify** `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — scale `framePainterLayer` by `zCard`; clipper uses the grown card rect. (Task C)
- **Test** `packages/slipreel_engine/test/effects/zoom_transformer_test.dart` (or the existing zoom_transformer test file) — clamp unit tests. (Task A)
- **Test** `packages/slipreel_engine/test/export/frame_compositor_test.dart` — revise the padding test to assert the floor (padding shrinks but survives). (Task B)
- Manual runtime verification. (Task D)

---

### Task A: Shared `resolveCardPushIn` helper

**Files:**
- Modify: `packages/slipreel_engine/lib/effects/zoom_transformer.dart`
- Test: create `packages/slipreel_engine/test/effects/zoom_transformer_card_pushin_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/effects/zoom_transformer_card_pushin_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/effects/zoom_transformer.dart';

void main() {
  // Canvas 400×320, video 320×240 centered → padding 40 each side.
  const canvas = Size(400, 320);
  const videoRect = Rect.fromLTWH(40, 40, 320, 240);
  const cornerRadius = 12.0;

  group('resolveCardPushIn', () {
    test('floorFraction 1.0 ⇒ card never grows (fixed-frame degenerate)', () {
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 4.0,
        paddingFloorFraction: 1.0,
      );
      expect(r.zCard, closeTo(1.0, 1e-9));
      expect(r.cardRect, videoRect);
      expect(r.cornerRadius, closeTo(cornerRadius, 1e-9));
    });

    test('low zoom below zCardMax ⇒ card scales by the full zoom', () {
      // zCardMax (x) = (400 - 0.4*(400-320)) / 320 = (400-32)/320 = 1.15.
      // zCardMax (y) = (320 - 0.4*(320-240)) / 240 = (320-32)/240 = 1.20.
      // zCardMax = min = 1.15. So zoom 1.10 < 1.15 ⇒ zCard == 1.10.
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 1.10,
        paddingFloorFraction: 0.4,
      );
      expect(r.zCard, closeTo(1.10, 1e-9));
      // Centered: card grows about the canvas center.
      expect(r.cardRect.center, const Offset(200, 160));
      expect(r.cardRect.width, closeTo(320 * 1.10, 1e-6));
      expect(r.cornerRadius, closeTo(cornerRadius * 1.10, 1e-6));
      // Padding still ≥ floor (16): (400 - 352)/2 = 24 ≥ 16. ✓
    });

    test('high zoom clamps card scale to zCardMax; padding holds at floor', () {
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 4.0,
        paddingFloorFraction: 0.4,
      );
      expect(r.zCard, closeTo(1.15, 1e-6)); // = min axis zCardMax
      // Padding on the binding (x) axis == floor 16: (400 - 320*1.15)/2 = 16.
      final padX = (canvas.width - r.cardRect.width) / 2;
      expect(padX, closeTo(0.4 * 40, 1e-6)); // 16
      // Card never exceeds canvas-inset-by-floor.
      expect(r.cardRect.width, lessThanOrEqualTo(canvas.width - 2 * 16 + 1e-6));
    });

    test('zoom 1.0 ⇒ zCard 1.0, cardRect == videoRect', () {
      final r = ZoomTransformer.resolveCardPushIn(
        videoRect: videoRect,
        canvasSize: canvas,
        cornerRadius: cornerRadius,
        zoom: 1.0,
        paddingFloorFraction: 0.4,
      );
      expect(r.zCard, closeTo(1.0, 1e-9));
      expect(r.cardRect, videoRect);
    });
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/effects/zoom_transformer_card_pushin_test.dart`
Expected: FAIL — `resolveCardPushIn` does not exist (compile error).

- [ ] **Step 3: Implement the helper**

In `zoom_transformer.dart`, add a result record typedef and a static method on `ZoomTransformer` (place after `clampFocalToBounds`):

```dart
  /// Result of [resolveCardPushIn]: the clamped card scale, the centered
  /// on-canvas card rect at that scale, and the effective (scaled) corner
  /// radius.
  static ({double zCard, Rect cardRect, double cornerRadius}) resolveCardPushIn({
    required Rect videoRect,
    required Size canvasSize,
    required double cornerRadius,
    required double zoom,
    double paddingFloorFraction = 0.4,
  }) {
    // Padding (per axis) is the inset of the centered 1× video rect.
    final padX = (canvasSize.width - videoRect.width) / 2;
    final padY = (canvasSize.height - videoRect.height) / 2;
    final floorX = paddingFloorFraction * padX;
    final floorY = paddingFloorFraction * padY;
    // Largest card scale that keeps each axis inset ≥ its floor:
    //   zCardMax_axis = (canvas_axis - 2·floor_axis) / videoRect_axis.
    final zCardMaxX = videoRect.width <= 0
        ? 1.0
        : (canvasSize.width - 2 * floorX) / videoRect.width;
    final zCardMaxY = videoRect.height <= 0
        ? 1.0
        : (canvasSize.height - 2 * floorY) / videoRect.height;
    final zCardMax = zCardMaxX < zCardMaxY ? zCardMaxX : zCardMaxY;
    final cappedMax = zCardMax < 1.0 ? 1.0 : zCardMax;
    var zCard = zoom < 1.0 ? 1.0 : zoom;
    if (zCard > cappedMax) zCard = cappedMax;
    final center = Offset(canvasSize.width / 2, canvasSize.height / 2);
    final cardRect = Rect.fromCenter(
      center: center,
      width: videoRect.width * zCard,
      height: videoRect.height * zCard,
    );
    return (
      zCard: zCard,
      cardRect: cardRect,
      cornerRadius: cornerRadius * zCard,
    );
  }
```

(Confirm `Rect`/`Size`/`Offset` are imported — `zoom_transformer.dart` imports `dart:ui` `Offset, Size`; add `Rect` to that show-list if needed.)

- [ ] **Step 4: Run to verify pass**

Run: `cd packages/slipreel_engine && flutter test test/effects/zoom_transformer_card_pushin_test.dart`
Expected: PASS (all 4).

- [ ] **Step 5: Run the existing zoom_transformer tests (no regressions)**

Run: `cd packages/slipreel_engine && flutter test test/effects/`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/effects/zoom_transformer.dart \
        packages/slipreel_engine/test/effects/zoom_transformer_card_pushin_test.dart
git commit -m "feat(zoom): add resolveCardPushIn clamp helper (card scale + grown rect) (#zoom-padding)"
```

---

### Task B: Export — clamped card push-in + grown content clip

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Test: `packages/slipreel_engine/test/export/frame_compositor_test.dart`

- [ ] **Step 1: Revise the failing test**

Replace the existing test named `active zoom does not grow the video into the padding (padding band stays clear)` in `frame_compositor_test.dart` with the hybrid version below (the old fixed-frame assertion — whole 0–40 band clear — is now wrong; the card pushes in so the band between the floor and the 1× padding is covered):

```dart
    test('active zoom pushes the card in to the padding floor (padding '
        'shrinks but does not vanish)', () async {
      // 320×240 video, 40px padding → totalSize 400×320, videoRect
      // (40,40,320,240). floorFraction 0.4 → floor 16px. zCardMax (x) =
      // (400-32)/320 = 1.15 → at 2× the card clamps to 1.15× and the left
      // padding becomes (400-368)/2 = 16px. So: a pixel inside the floor
      // (x<16) stays clear; a pixel between the floor and the old padding
      // (16<x<40) is now covered by the pushed-in card; the center is video.
      final compositor = FrameCompositor(
        projectState: EditorProjectState.defaults().copyWith(
          windowFrame: const WindowFrame(
            name: 'Custom',
            padding: EdgeInsets.all(40),
            cornerRadius: 0,
            shadowBlur: 0,
            shadowOffset: Offset.zero,
            shadowColor: Color(0x00000000),
            borderWidth: 0,
          ),
          zoomRegions: [
            ZoomRegion(
              rect: const Rect.fromLTWH(0, 0, 320, 240),
              startTime: Duration.zero,
              duration: const Duration(seconds: 1),
              zoomLevel: 2.0,
              followCursor: false,
              enterDuration: Duration.zero,
              exitDuration: Duration.zero,
            ),
          ],
        ),
        cursorRecording: CursorRecording(),
        metadata: _meta(),
        videoSize: const Size(320, 240),
        fps: 30,
      );

      final magenta = _solidBgra(320, 240, 0xFF, 0x00, 0xFF);
      final rgba = await compositor.compose(
        videoFrameBgra: magenta,
        position: const Duration(milliseconds: 500),
      );

      const w = 400;
      bool isMagenta(int x, int y) {
        final i = (y * w + x) * 4;
        return rgba[i + 0] == 0xFF && rgba[i + 2] == 0xFF && rgba[i + 3] == 0xFF;
      }

      // Inside the floor: still clear (padding survives).
      expect(isMagenta(8, 160), isFalse,
          reason: 'padding inside the floor must survive the zoom');
      // Between floor (16) and old padding (40): card pushed in here.
      expect(isMagenta(28, 160), isTrue,
          reason: 'the card pushes in to the floor (padding shrinks 40→~16)');
      // Center is the magnified video.
      expect(isMagenta(200, 160), isTrue,
          reason: 'window center shows the magnified video');
    });
```

(Keep the rounded-corner test from the earlier commit — it still holds; the card at z=2 clamps to 1.15× and the corner is still rounded. If that test's exact sample pixel now lands inside the grown card, adjust its sample to a still-outside-the-arc point and note it; do not weaken it.)

- [ ] **Step 2: Run to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_test.dart --plain-name "pushes the card in to the padding floor"`
Expected: FAIL — with the current fixed-frame code the card does NOT push in, so `isMagenta(28,160)` is `false` (assertion `isTrue` fails).

- [ ] **Step 3: Compute the card push-in and apply it**

In `compose()`, after `zoomActive` is determined and before building the foreground clip, compute the push-in when active:

```dart
      final zoomActive = !zoomTransform.isIdentity();
      // Hybrid push-in: the chrome scales up to a clamped card rect (padding
      // shrinks only to the floor), while the content keeps the full zoom and
      // is clipped to that grown card. zCard==1 / cardRect==_videoRect when
      // not zooming.
      final pushIn = zoomActive
          ? ZoomTransformer.resolveCardPushIn(
              videoRect: _videoRect,
              canvasSize: totalSize,
              cornerRadius: _frame.cornerRadius,
              zoom: zoomTransform.storage[0], // effective ramped zoom = scaleX
            )
          : null;
```

Then change the foreground clip to use the grown card rect:

```dart
      if (zoomActive) {
        fgCanvas.save();
        fgCanvas.clipRRect(
          RRect.fromRectAndRadius(
            pushIn!.cardRect,
            Radius.circular(pushIn.cornerRadius),
          ),
        );
      }
      applyZoom(fgCanvas);
      // ... _paintVideoFrame + _paintCursor unchanged ...
      if (zoomActive) {
        fgCanvas.restore();
      }
```

- [ ] **Step 4: Scale the chrome by `zCard` (centered)**

Replace the chrome build so it scales by `zCard` about the canvas center when zooming (was: painted un-zoomed). Update the stale "chrome stays at the fixed padded rect" comment too:

```dart
      ui.Picture? chromePicture;
      if (_frame.name != 'None') {
        final chromeRecorder = ui.PictureRecorder();
        final chromeCanvas = ui.Canvas(chromeRecorder, layerRect);
        // Hybrid push-in: the chrome (shadow/ring/border + rounded window)
        // scales by zCard, centered, so the card visibly pushes in but only
        // until the padding reaches its floor. Never smeared (composited crisp
        // below). zCard==1 when not zooming ⇒ unchanged.
        if (pushIn != null && pushIn.zCard != 1.0) {
          chromeCanvas.translate(totalSize.width / 2, totalSize.height / 2);
          chromeCanvas.scale(pushIn.zCard, pushIn.zCard);
          chromeCanvas.translate(-totalSize.width / 2, -totalSize.height / 2);
        }
        _framePainter.paint(chromeCanvas, totalSize);
        chromePicture = chromeRecorder.endRecording();
      }
```

Also fix the now-inaccurate comment at the foreground block (lines ~218–224, "The chrome still scales/pans with the zoom") to describe the hybrid: chrome scales by `zCard` (centered, crisp), content gets the full zoom clipped to the grown card.

- [ ] **Step 5: Run to verify pass**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_test.dart --plain-name "pushes the card in to the padding floor"`
Expected: PASS.

- [ ] **Step 6: Full compositor file**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_test.dart`
Expected: PASS (all — including the rounded-corner test and the existing shadowed/zoom-pan smoke tests). Fix the rounded-corner sample point if needed (per Step 1 note).

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/slipreel_engine/test/export/frame_compositor_test.dart
git commit -m "feat(zoom): export hybrid push-in — chrome scales to padding floor, content clipped to grown card (#zoom-padding)"
```

---

### Task C: Preview — clamped card push-in + grown content clip

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`

- [ ] **Step 1: Compute the push-in in the active-zoom builder**

In the `TweenAnimationBuilder` builder, after `transform` is computed and after the `transform.isIdentity()` short-circuit, add:

```dart
                // Hybrid push-in: chrome scales by zCard (centered, clamped to
                // the padding floor); the content keeps the full zoom and is
                // clipped to the grown card rect.
                final pushIn = ZoomTransformer.resolveCardPushIn(
                  videoRect: Rect.fromLTWH(
                    videoOriginX,
                    videoOriginY,
                    videoSize.width,
                    videoSize.height,
                  ),
                  canvasSize: totalSize,
                  cornerRadius: currentFrame.cornerRadius,
                  zoom: transform.storage[0], // effective ramped zoom = scaleX
                );
```

(`ZoomTransformer` is already imported in this file — it's used for `_zoomTransformer.getTransform`. If `ZoomTransformer` is only referenced via the instance, add the static call via the type name; the import already covers it.)

- [ ] **Step 2: Scale the chrome by `zCard`; clip to the grown card**

Update the `transformed` Stack and the `windowClipper` in the builder. The chrome layer gets a centered `Transform(scale zCard)`; the clipper uses `pushIn.cardRect` + `pushIn.cornerRadius`:

```dart
                final windowClipper = _VideoWindowClipper(
                  pushIn.cardRect,
                  pushIn.cornerRadius,
                );

                final scaledChrome = pushIn.zCard == 1.0
                    ? framePainterLayer
                    : Transform(
                        transform: Matrix4.identity()
                          ..scaleByDouble(pushIn.zCard, pushIn.zCard, 1.0, 1.0),
                        alignment: Alignment.center,
                        child: framePainterLayer,
                      );

                final transformed = Stack(
                  fit: StackFit.expand,
                  children: [
                    scaledChrome,
                    ClipPath(
                      clipper: windowClipper,
                      child: Transform(
                        transform: transform,
                        alignment: Alignment.center,
                        child: videoLayer,
                      ),
                    ),
                    ...debugLayers,
                  ],
                );

                final transformedCursor = cursorOverlay == null
                    ? null
                    : ClipPath(
                        clipper: windowClipper,
                        child: Transform(
                          transform: transform,
                          alignment: Alignment.center,
                          child: cursorOverlay,
                        ),
                      );
```

(`framePainterLayer` / `videoLayer` / `debugLayers` are the existing named layers; `_buildSceneMotionBlurPass(...)` call below stays unchanged. `Matrix4`/`Transform`/`Alignment` are already imported.)

- [ ] **Step 3: Analyze**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/zoom/playback_canvas.dart`
Expected: No issues. (If `framePainterLayer` is now only used to build `scaledChrome` and the analyzer complains about anything, resolve it; it's still used in the no-zoom `composition`.)

- [ ] **Step 4: Widget tests (no regressions)**

Run the playback_canvas + scene_blur widget test files under `packages/screen_recorder/test/` (e.g. `test/ui/widgets/zoom/playback_canvas_camera_test.dart`, `test/widgets/scene_blur_*_test.dart`).
Run: `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/playback_canvas_camera_test.dart test/widgets/scene_blur_tree_stable_test.dart test/widgets/scene_blur_focal_track_test.dart test/widgets/scene_blur_no_remount_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "feat(zoom): preview hybrid push-in — chrome scales to padding floor, content clipped to grown card (#zoom-padding)"
```

---

### Task D: Manual runtime verification

**Files:** none (verification only). Use the flutter-qa probe; the branch must be built (`stop_app` then `boot_app` to pick up the branch code).

- [ ] **Step 1:** Launch the app, open a recording, ensure a zoom region exists (or add one).
- [ ] **Step 2 — the repro:** Set a zoom to ~4× with the focal in a corner (top-right). Expected: the **card is visibly larger than at 1×** (pushed in), there is a **clear padding margin (~the floor) that does NOT vanish**, and the content shows the top-right region magnified. Contrast with the previously-built fixed-frame build (card didn't grow) and the original (padding vanished).
- [ ] **Step 3 — 1× unchanged:** a no-zoom section renders exactly as before (cursor can bleed onto the padding near an edge).
- [ ] **Step 4 — preview ↔ export:** export and scrub the MP4 across the zoom; the push-in amount and padding floor match the preview.
- [ ] **Step 5 — scene-blur check:** with screen motion blur on, play a zoom ramp; watch whether the scaling chrome smears objectionably in preview (flagged follow-up, not a blocker).
- [ ] **Step 6:** Record the outcome. If the push-in feels too subtle or too strong, the `paddingFloorFraction` default (0.4) is the dial — note a preferred value.

---

## Self-Review

**Spec coverage:**
- Clamped card scale + centered grown rect + floor → Task A (`resolveCardPushIn`) + unit tests. ✓
- Chrome scales by `zCard` (centered) → Task B Step 4 (export), Task C Step 2 (preview `scaledChrome`). ✓
- Content keeps full zoom, clipped to grown card (radius·zCard) → Task B Step 3 (export clip `pushIn.cardRect`), Task C Step 2 (preview `windowClipper` from `pushIn`). ✓
- Effective zoom read from matrix scale → Task B Step 3 / Task C Step 1 (`storage[0]`). ✓
- Padding floor holds, padding shrinks-but-survives → Task B revised pixel test (clear inside floor, covered between floor and old padding). ✓
- Degenerate cases (floorFraction 1 ⇒ fixed-frame; zoom 1 ⇒ unchanged) → Task A tests + `zoomActive`/`zCard==1` gates. ✓
- 1× unchanged + identity short-circuit retained → Task C keeps the `transform.isIdentity()` early return; export `zoomActive` gate. ✓
- Scene-blur verify-not-fix → Task D Step 5. ✓

**Placeholder scan:** No TBD/TODO; every code step has full code; commands have expected output. ✓

**Type consistency:** `resolveCardPushIn(...)` returns `({double zCard, Rect cardRect, double cornerRadius})`, consumed as `pushIn.zCard` / `pushIn.cardRect` / `pushIn.cornerRadius` in Tasks B and C. `_VideoWindowClipper(rect, radius)` (existing) constructed with `pushIn.cardRect, pushIn.cornerRadius`. Effective zoom `transform.storage[0]` / `zoomTransform.storage[0]` (the `scaleByDouble(z,z,..)` x-scale). ✓
