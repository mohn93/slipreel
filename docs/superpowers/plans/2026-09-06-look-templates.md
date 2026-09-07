# Look Templates Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user pick a named "look template" before recording (and apply one in the editor) so recordings open already styled, while mic/system-audio/camera toggles persist across launches.

**Architecture:** A new pure `EditorLook` value in the engine holds exactly the look fields of `EditorProjectState`; `withLook` swaps them without touching timeline content. Templates (`LookTemplate` = id/name/builtIn/look) are persisted app-side by a `LookTemplateStore` modelled on `FileCurveLibrary`, exposed through a Riverpod `LookTemplateController`. The recording bar seeds fresh recordings from the selected template; the inspector applies templates to open recordings via `EditorProjectController.applyLook`. Capture toggles gain last-used persistence in the existing `RecordingSettings` store.

**Tech Stack:** Dart, Flutter, Riverpod (`flutter_riverpod` `StateNotifier`), melos monorepo. Engine package `packages/slipreel_engine`, app package `packages/screen_recorder`.

**Spec:** `docs/superpowers/specs/2026-09-06-look-templates-design.md`

## Global Constraints

- Never run `dart format` on existing files; match surrounding style by hand.
- Stage only files you touched (`git add <path>`), never `git add -A`/`.`; other agents share this checkout.
- Branch is `feat/look-templates`; PRs target `main` (this repo has no `dev`).
- Dark-theme colors via `context.palette.<role>`; panel notifications via `AppAlerts`.
- Tests run via `melos test` (macOS host). Per-package: `flutter test` from the package dir.
- No external packages added; generate ids with `Random.secure()` hex like `FileCurveLibrary._newId`.
- Look JSON keys MUST match `EditorProjectState.toJson` key names exactly (e.g. `cursorDelayMicros`, `outputAspect`) so a look round-trips through the same readers.

---

## File Structure

**Engine (`packages/slipreel_engine`)**
- Create `lib/state/editor_look.dart` — `EditorLook` value class (look fields + JSON + fromProject).
- Modify `lib/state/editor_project_state.dart` — add `withLook(EditorLook)`; expose the private field-decode helpers needed by `EditorLook.fromJson` (or duplicate minimal readers — see Task 1).
- Modify `lib/state/editor_project_controller.dart` — add `applyLook(EditorLook, {Size videoSize})`.
- Modify `lib/state/editor_project_store.dart` — add optional `seed` to `load`.
- Tests under `test/state/`.

**App (`packages/screen_recorder`)**
- Create `lib/state/look_template.dart` — `LookTemplate` model + built-ins.
- Create `lib/state/look_template_store.dart` — file persistence.
- Create `lib/state/look_template_controller.dart` — Riverpod controller + providers.
- Modify `lib/state/recording_settings_store.dart` — add mic/systemAudio/camera fields.
- Modify `lib/state/microphone_controller.dart`, `system_audio_controller.dart`, `camera_controller.dart` — initial value + write-through.
- Modify `lib/main.dart` — wire template store/controller and capture-toggle initial values.
- Create `lib/ui/widgets/inspector/template_row.dart` — inspector template row.
- Modify `lib/ui/widgets/inspector/inspector_panel.dart` — mount `TemplateRow`.
- Modify `lib/ui/screens/playback_screen.dart` — apply/save wiring + seed fresh recordings.
- Create `lib/ui/bar/template_control.dart` — bar chip + menu.
- Modify `lib/ui/bar/recording_bar.dart`, `recording_bar_screen.dart` — mount the chip.
- Tests under `test/state/` and `test/ui/`.

---

## Task 1: `EditorLook` value + `withLook`

**Files:**
- Create: `packages/slipreel_engine/lib/state/editor_look.dart`
- Modify: `packages/slipreel_engine/lib/state/editor_project_state.dart`
- Test: `packages/slipreel_engine/test/state/editor_look_test.dart`

**Interfaces:**
- Consumes: `EditorProjectState` (existing fields + `toJson`/`fromJson` field encoders).
- Produces:
  - `class EditorLook` with named fields: `windowFrame` (WindowFrame), `cursorSize` (double), `cursorStyle` (CursorStyle), `cursorClickEffect` (CursorClickEffect), `cursorShadow` (double), `clickSpring` (ClickSpring), `cursorPostProcess` (CursorPostProcess), `hideCursorOverlay` (bool), `cursorDelay` (Duration), `screenAnimationConfig` (ScreenAnimationConfig), `cursorAnimationConfig` (CursorAnimationConfig), `motionBlur` (double), `cursorMovementBlur` (double), `screenMovementBlur` (double), `screenZoomBlur` (double), `outputAspect` (OutputAspect), `keystrokeOverlay` (KeystrokeOverlaySettings), `cameraSettings` (CameraSettings), `captionStyle` (CaptionStyle), `defaultZoomLook` (ZoomLook).
  - `factory EditorLook.fromProject(EditorProjectState s)`
  - `factory EditorLook.defaults()`
  - `EditorLook copyWith({...all fields...})`
  - `Map<String,dynamic> toJson()` and `factory EditorLook.fromJson(Map<String,dynamic>)`
  - `operator ==` / `hashCode`
  - `EditorProjectState.withLook(EditorLook look) -> EditorProjectState`

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/state/editor_look_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/state/editor_look.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  test('fromProject then withLook is identity for look fields', () {
    final base = EditorProjectState.defaults().copyWith(
      cursorSize: 4.0,
      cursorStyle: CursorStyle.dot,
      motionBlur: 0.3,
      outputAspect: OutputAspect.square,
      windowFrame: WindowFrame.modern(),
      defaultZoomLook: ZoomLook.showcase,
    );
    final look = EditorLook.fromProject(base);
    final applied = EditorProjectState.defaults().withLook(look);

    expect(applied.cursorSize, 4.0);
    expect(applied.cursorStyle, CursorStyle.dot);
    expect(applied.motionBlur, 0.3);
    expect(applied.outputAspect, OutputAspect.square);
    expect(applied.windowFrame, WindowFrame.modern());
    expect(applied.defaultZoomLook, ZoomLook.showcase);
    // Timeline is content, not look — untouched.
    expect(applied.timeline, EditorProjectState.defaults().timeline);
  });

  test('EditorLook JSON round-trips', () {
    final look = EditorLook.fromProject(
      EditorProjectState.defaults().copyWith(cursorSize: 3.3, motionBlur: 0.25),
    );
    final restored = EditorLook.fromJson(look.toJson());
    expect(restored, look);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_look_test.dart`
Expected: FAIL — `editor_look.dart` does not exist / `withLook` undefined.

- [ ] **Step 3: Add the `EditorLook` class**

Create `packages/slipreel_engine/lib/state/editor_look.dart`. Reuse the same imports `editor_project_state.dart` uses. `toJson`/`fromJson` MUST use identical keys to `EditorProjectState.toJson` for each field. Reuse the field encoders/decoders by delegating: for `fromJson`, build via `EditorProjectState.defaults().copyWith(...)`-style reads is not available for a standalone look, so decode each field with the same expressions the state uses. To avoid duplicating the private helpers, add three `static` decoders on `EditorProjectState` and reuse them, OR keep local copies. Simplest: reuse `WindowFrame.fromJson`, `ScreenAnimationConfig.fromJson`, etc. directly, and for scalars/enums write small inline reads mirroring `EditorProjectState.fromJson` (clamp motion-blur values the same way).

```dart
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

/// The look half of an [EditorProjectState] — everything a template
/// carries. Excludes timeline content and transient UI (timelineScale,
/// pendingScaleAnchor). See the look-templates design doc.
class EditorLook {
  const EditorLook({
    required this.windowFrame,
    required this.cursorSize,
    required this.cursorStyle,
    required this.cursorClickEffect,
    required this.cursorShadow,
    required this.clickSpring,
    required this.cursorPostProcess,
    required this.hideCursorOverlay,
    required this.cursorDelay,
    required this.screenAnimationConfig,
    required this.cursorAnimationConfig,
    required this.motionBlur,
    required this.cursorMovementBlur,
    required this.screenMovementBlur,
    required this.screenZoomBlur,
    required this.outputAspect,
    required this.keystrokeOverlay,
    required this.cameraSettings,
    required this.captionStyle,
    required this.defaultZoomLook,
  });

  final WindowFrame windowFrame;
  final double cursorSize;
  final CursorStyle cursorStyle;
  final CursorClickEffect cursorClickEffect;
  final double cursorShadow;
  final ClickSpring clickSpring;
  final CursorPostProcess cursorPostProcess;
  final bool hideCursorOverlay;
  final Duration cursorDelay;
  final ScreenAnimationConfig screenAnimationConfig;
  final CursorAnimationConfig cursorAnimationConfig;
  final double motionBlur;
  final double cursorMovementBlur;
  final double screenMovementBlur;
  final double screenZoomBlur;
  final OutputAspect outputAspect;
  final KeystrokeOverlaySettings keystrokeOverlay;
  final CameraSettings cameraSettings;
  final CaptionStyle captionStyle;
  final ZoomLook defaultZoomLook;

  factory EditorLook.fromProject(EditorProjectState s) => EditorLook(
        windowFrame: s.windowFrame,
        cursorSize: s.cursorSize,
        cursorStyle: s.cursorStyle,
        cursorClickEffect: s.cursorClickEffect,
        cursorShadow: s.cursorShadow,
        clickSpring: s.clickSpring,
        cursorPostProcess: s.cursorPostProcess,
        hideCursorOverlay: s.hideCursorOverlay,
        cursorDelay: s.cursorDelay,
        screenAnimationConfig: s.screenAnimationConfig,
        cursorAnimationConfig: s.cursorAnimationConfig,
        motionBlur: s.motionBlur,
        cursorMovementBlur: s.cursorMovementBlur,
        screenMovementBlur: s.screenMovementBlur,
        screenZoomBlur: s.screenZoomBlur,
        outputAspect: s.outputAspect,
        keystrokeOverlay: s.keystrokeOverlay,
        cameraSettings: s.cameraSettings,
        captionStyle: s.captionStyle,
        defaultZoomLook: s.defaultZoomLook,
      );

  factory EditorLook.defaults() =>
      EditorLook.fromProject(EditorProjectState.defaults());

  EditorLook copyWith({
    WindowFrame? windowFrame,
    double? cursorSize,
    CursorStyle? cursorStyle,
    CursorClickEffect? cursorClickEffect,
    double? cursorShadow,
    ClickSpring? clickSpring,
    CursorPostProcess? cursorPostProcess,
    bool? hideCursorOverlay,
    Duration? cursorDelay,
    ScreenAnimationConfig? screenAnimationConfig,
    CursorAnimationConfig? cursorAnimationConfig,
    double? motionBlur,
    double? cursorMovementBlur,
    double? screenMovementBlur,
    double? screenZoomBlur,
    OutputAspect? outputAspect,
    KeystrokeOverlaySettings? keystrokeOverlay,
    CameraSettings? cameraSettings,
    CaptionStyle? captionStyle,
    ZoomLook? defaultZoomLook,
  }) =>
      EditorLook(
        windowFrame: windowFrame ?? this.windowFrame,
        cursorSize: cursorSize ?? this.cursorSize,
        cursorStyle: cursorStyle ?? this.cursorStyle,
        cursorClickEffect: cursorClickEffect ?? this.cursorClickEffect,
        cursorShadow: cursorShadow ?? this.cursorShadow,
        clickSpring: clickSpring ?? this.clickSpring,
        cursorPostProcess: cursorPostProcess ?? this.cursorPostProcess,
        hideCursorOverlay: hideCursorOverlay ?? this.hideCursorOverlay,
        cursorDelay: cursorDelay ?? this.cursorDelay,
        screenAnimationConfig:
            screenAnimationConfig ?? this.screenAnimationConfig,
        cursorAnimationConfig:
            cursorAnimationConfig ?? this.cursorAnimationConfig,
        motionBlur: motionBlur ?? this.motionBlur,
        cursorMovementBlur: cursorMovementBlur ?? this.cursorMovementBlur,
        screenMovementBlur: screenMovementBlur ?? this.screenMovementBlur,
        screenZoomBlur: screenZoomBlur ?? this.screenZoomBlur,
        outputAspect: outputAspect ?? this.outputAspect,
        keystrokeOverlay: keystrokeOverlay ?? this.keystrokeOverlay,
        cameraSettings: cameraSettings ?? this.cameraSettings,
        captionStyle: captionStyle ?? this.captionStyle,
        defaultZoomLook: defaultZoomLook ?? this.defaultZoomLook,
      );

  Map<String, dynamic> toJson() => {
        'windowFrame': windowFrame.toJson(),
        'cursorSize': cursorSize,
        'cursorStyle': cursorStyle.name,
        'cursorClickEffect': cursorClickEffect.name,
        'cursorShadow': cursorShadow,
        'clickSpring': clickSpring.toJson(),
        'cursorPostProcess': cursorPostProcess.toJson(),
        'hideCursorOverlay': hideCursorOverlay,
        'cursorDelayMicros': cursorDelay.inMicroseconds,
        'screenAnimationConfig': screenAnimationConfig.toJson(),
        'cursorAnimationConfig': cursorAnimationConfig.toJson(),
        'motionBlur': motionBlur,
        'cursorMovementBlur': cursorMovementBlur,
        'screenMovementBlur': screenMovementBlur,
        'screenZoomBlur': screenZoomBlur,
        'outputAspect': outputAspect.name,
        'keystrokeOverlay': keystrokeOverlay.toJson(),
        'cameraSettings': cameraSettings.toJson(),
        'captionStyle': captionStyle.toJson(),
        'defaultZoomLook': defaultZoomLook.toJson(),
      };

  /// Decodes a look by layering the JSON onto a default project's JSON and
  /// reusing [EditorProjectState.fromJson]'s battle-tested per-field readers,
  /// then projecting back out. This guarantees identical decode semantics
  /// (clamps, enum fallbacks, section defaults) without duplicating them.
  factory EditorLook.fromJson(Map<String, dynamic> json) {
    final base = EditorProjectState.defaults().toJson();
    final merged = {...base, ...json};
    // fromJson requires a videoDuration for timeline seeding; the look
    // ignores timeline, so any non-zero duration is fine.
    final state = EditorProjectState.fromJson(
      merged,
      videoDuration: const Duration(seconds: 1),
    );
    return EditorLook.fromProject(state);
  }

  @override
  bool operator ==(Object other) =>
      other is EditorLook &&
      other.windowFrame == windowFrame &&
      other.cursorSize == cursorSize &&
      other.cursorStyle == cursorStyle &&
      other.cursorClickEffect == cursorClickEffect &&
      other.cursorShadow == cursorShadow &&
      other.clickSpring == clickSpring &&
      other.cursorPostProcess == cursorPostProcess &&
      other.hideCursorOverlay == hideCursorOverlay &&
      other.cursorDelay == cursorDelay &&
      other.screenAnimationConfig == screenAnimationConfig &&
      other.cursorAnimationConfig == cursorAnimationConfig &&
      other.motionBlur == motionBlur &&
      other.cursorMovementBlur == cursorMovementBlur &&
      other.screenMovementBlur == screenMovementBlur &&
      other.screenZoomBlur == screenZoomBlur &&
      other.outputAspect == outputAspect &&
      other.keystrokeOverlay == keystrokeOverlay &&
      other.cameraSettings == cameraSettings &&
      other.captionStyle == captionStyle &&
      other.defaultZoomLook == defaultZoomLook;

  @override
  int get hashCode => Object.hashAll([
        windowFrame,
        cursorSize,
        cursorStyle,
        cursorClickEffect,
        cursorShadow,
        clickSpring,
        cursorPostProcess,
        hideCursorOverlay,
        cursorDelay,
        screenAnimationConfig,
        cursorAnimationConfig,
        motionBlur,
        cursorMovementBlur,
        screenMovementBlur,
        screenZoomBlur,
        outputAspect,
        keystrokeOverlay,
        cameraSettings,
        captionStyle,
        defaultZoomLook,
      ]);
}
```

> Note: `EditorLook.fromJson` deliberately routes through `EditorProjectState.fromJson` so the look inherits every field's clamp/fallback rule. This also means `toJson` keys MUST equal the state's keys — verified by the round-trip test.

- [ ] **Step 4: Add `withLook` to `EditorProjectState`**

In `packages/slipreel_engine/lib/state/editor_project_state.dart`, add an import for `editor_look.dart` and a method (place it right after `copyWith`):

```dart
  /// Returns a copy with every look field replaced from [look]. Timeline
  /// content and transient UI (timelineScale, pendingScaleAnchor) are
  /// untouched. Used by templates (see look-templates design).
  EditorProjectState withLook(EditorLook look) => copyWith(
        windowFrame: look.windowFrame,
        cursorSize: look.cursorSize,
        cursorStyle: look.cursorStyle,
        cursorClickEffect: look.cursorClickEffect,
        cursorShadow: look.cursorShadow,
        clickSpring: look.clickSpring,
        cursorPostProcess: look.cursorPostProcess,
        hideCursorOverlay: look.hideCursorOverlay,
        cursorDelay: look.cursorDelay,
        screenAnimationConfig: look.screenAnimationConfig,
        cursorAnimationConfig: look.cursorAnimationConfig,
        motionBlur: look.motionBlur,
        cursorMovementBlur: look.cursorMovementBlur,
        screenMovementBlur: look.screenMovementBlur,
        screenZoomBlur: look.screenZoomBlur,
        outputAspect: look.outputAspect,
        keystrokeOverlay: look.keystrokeOverlay,
        cameraSettings: look.cameraSettings,
        captionStyle: look.captionStyle,
        defaultZoomLook: look.defaultZoomLook,
      );
```

Watch: `editor_look.dart` imports `editor_project_state.dart` and vice-versa. Dart handles this cyclic import fine within a package; keep both as normal `package:` imports.

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_look_test.dart`
Expected: PASS (both tests).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_look.dart \
        packages/slipreel_engine/lib/state/editor_project_state.dart \
        packages/slipreel_engine/test/state/editor_look_test.dart
git commit -m "Add EditorLook value and EditorProjectState.withLook"
```

---

## Task 2: Coverage guard test (look completeness)

**Files:**
- Test: `packages/slipreel_engine/test/state/editor_look_coverage_test.dart`

**Interfaces:**
- Consumes: `EditorLook.fromProject`, `EditorProjectState.withLook`, `EditorProjectState.defaults`.
- Produces: nothing (guard only).

This test fails if someone adds a look-ish field to `EditorProjectState` without adding it to `EditorLook`. It builds a state with every look field set to a non-default value, projects to a look, applies onto defaults, and asserts equality of every look field.

- [ ] **Step 1: Write the failing-safe test**

Create `packages/slipreel_engine/test/state/editor_look_coverage_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/models/camera_settings.dart';
import 'package:slipreel_engine/models/keystroke_overlay_settings.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/cursor_click_effect.dart';
import 'package:slipreel_engine/rendering/cursor_glyph.dart';
import 'package:slipreel_engine/rendering/spring_config.dart';
import 'package:slipreel_engine/state/cursor_post_process.dart';
import 'package:slipreel_engine/state/editor_look.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  test('withLook carries every look field (coverage guard)', () {
    // Every field here differs from EditorProjectState.defaults(). If you add
    // a new look field to EditorProjectState, set it non-default here AND add
    // it to EditorLook; otherwise this test fails.
    final fancy = EditorProjectState.defaults().copyWith(
      windowFrame: WindowFrame.modern(),
      cursorSize: 4.2,
      cursorStyle: CursorStyle.dot,
      cursorClickEffect: CursorClickEffect.none,
      cursorShadow: 0.9,
      clickSpring: ClickSpring.gentle,
      cursorPostProcess: const CursorPostProcess(freezeAtEnd: true),
      hideCursorOverlay: true,
      cursorDelay: const Duration(milliseconds: 120),
      screenAnimationConfig:
          const ScreenAnimationConfig.preset(ScreenAnimationStyle.instant),
      cursorAnimationConfig:
          const CursorAnimationConfig.preset(CursorAnimationStyle.linear),
      motionBlur: 0.4,
      cursorMovementBlur: 0.7,
      screenMovementBlur: 0.6,
      screenZoomBlur: 0.5,
      outputAspect: OutputAspect.portrait,
      keystrokeOverlay: const KeystrokeOverlaySettings(enabled: true),
      cameraSettings: const CameraSettings(enabled: true),
      captionStyle: const CaptionStyle(fontSize: 40),
      defaultZoomLook: ZoomLook.cinematic,
    );

    final applied = EditorProjectState.defaults()
        .withLook(EditorLook.fromProject(fancy));

    expect(applied.windowFrame, fancy.windowFrame);
    expect(applied.cursorSize, fancy.cursorSize);
    expect(applied.cursorStyle, fancy.cursorStyle);
    expect(applied.cursorClickEffect, fancy.cursorClickEffect);
    expect(applied.cursorShadow, fancy.cursorShadow);
    expect(applied.clickSpring, fancy.clickSpring);
    expect(applied.cursorPostProcess, fancy.cursorPostProcess);
    expect(applied.hideCursorOverlay, fancy.hideCursorOverlay);
    expect(applied.cursorDelay, fancy.cursorDelay);
    expect(applied.screenAnimationConfig, fancy.screenAnimationConfig);
    expect(applied.cursorAnimationConfig, fancy.cursorAnimationConfig);
    expect(applied.motionBlur, fancy.motionBlur);
    expect(applied.cursorMovementBlur, fancy.cursorMovementBlur);
    expect(applied.screenMovementBlur, fancy.screenMovementBlur);
    expect(applied.screenZoomBlur, fancy.screenZoomBlur);
    expect(applied.outputAspect, fancy.outputAspect);
    expect(applied.keystrokeOverlay, fancy.keystrokeOverlay);
    expect(applied.cameraSettings, fancy.cameraSettings);
    expect(applied.captionStyle, fancy.captionStyle);
    expect(applied.defaultZoomLook, fancy.defaultZoomLook);
  });
}
```

- [ ] **Step 2: Adjust the constructors to real APIs**

The exact enum values / named params above (`ScreenAnimationStyle.instant`, `CursorPostProcess(freezeAtEnd:)`, `KeystrokeOverlaySettings(enabled:)`, `CameraSettings(enabled:)`, `CaptionStyle(fontSize:)`, `ClickSpring.gentle`, `CursorClickEffect.none`, `OutputAspect.portrait`) are placeholders keyed to likely names. Before running, grep each type for its real constructor/enum members and fix any mismatch:

Run: `cd packages/slipreel_engine && grep -rn "enum ScreenAnimationStyle\|enum CursorAnimationStyle\|enum CursorClickEffect\|enum CursorStyle\|enum OutputAspect" lib` and open `cursor_post_process.dart`, `keystroke_overlay_settings.dart`, `camera_settings.dart`, `caption_style.dart`, `spring_config.dart` to confirm a non-default value for each. Every value must differ from `EditorProjectState.defaults()`.

- [ ] **Step 3: Run the test**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_look_coverage_test.dart`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add packages/slipreel_engine/test/state/editor_look_coverage_test.dart
git commit -m "Add look-completeness coverage guard test"
```

---

## Task 3: `applyLook` on the controller

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_controller.dart`
- Test: `packages/slipreel_engine/test/state/apply_look_test.dart`

**Interfaces:**
- Consumes: `EditorLook`, `EditorProjectState.withLook`, existing `applyLookToAllZooms(ZoomLook, {Size videoSize})`, `WindowFrame.copyWith`.
- Produces: `void EditorProjectController.applyLook(EditorLook look, {Size videoSize = Size.zero})`.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/state/apply_look_test.dart`:

```dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/models/zoom_region.dart';
import 'package:slipreel_engine/state/editor_look.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  test('applyLook replaces look fields and restyles all zooms', () {
    // Seed a project with two zooms and a device frame set on the recording.
    final withDeviceFrame = EditorProjectState.defaults().copyWith(
      windowFrame: EditorProjectState.defaults()
          .windowFrame
          .copyWith(deviceFrameId: 'iphone-16-pro', deviceFrameColor: 'black'),
      zoomRegions: [
        ZoomRegion.manual(
          start: const Duration(seconds: 1),
          end: const Duration(seconds: 2),
        ),
      ],
    );
    final controller = EditorProjectController(initial: withDeviceFrame);

    // A look saved from a NON-device recording: modern frame, showcase zoom.
    final look = EditorLook.fromProject(
      EditorProjectState.defaults().copyWith(
        windowFrame: WindowFrame.modern(),
        defaultZoomLook: ZoomLook.showcase,
      ),
    );

    controller.applyLook(look, videoSize: const Size(1920, 1080));

    // Look applied.
    expect(controller.current.defaultZoomLook, ZoomLook.showcase);
    // Frame name came from the template...
    expect(controller.current.windowFrame.name, WindowFrame.modern().name);
    // ...but the recording's device frame was PRESERVED, not wiped.
    expect(controller.current.windowFrame.deviceFrameId, 'iphone-16-pro');
    // Existing zoom restyled to the template's zoom look.
    expect(
      ZoomLook.of(controller.current.zoomRegions.first),
      ZoomLook.showcase,
    );
  });

  test('applyLook does not carry a template device frame onto a plain recording',
      () {
    final plain = EditorProjectController(
      initial: EditorProjectState.defaults(),
    );
    final look = EditorLook.fromProject(
      EditorProjectState.defaults().copyWith(
        windowFrame: EditorProjectState.defaults()
            .windowFrame
            .copyWith(deviceFrameId: 'iphone-16-pro'),
      ),
    );
    plain.applyLook(look, videoSize: const Size(1920, 1080));
    expect(plain.current.windowFrame.deviceFrameId, isNull);
  });
}
```

Confirm `ZoomRegion.manual(...)` and `ZoomLook.of(...)` signatures by grep before running; adjust if the manual-zoom factory differs.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/state/apply_look_test.dart`
Expected: FAIL — `applyLook` undefined.

- [ ] **Step 3: Implement `applyLook`**

In `editor_project_controller.dart`, add an import for `editor_look.dart`, then add the method next to `applyLookToAllZooms`:

```dart
  /// Applies a template look to this recording as one undoable change:
  /// swaps every look field, preserves the recording's own device-frame
  /// fields (a template never transfers a device bezel), and restyles every
  /// zoom to the look's [ZoomLook]. See look-templates design.
  void applyLook(EditorLook look, {Size videoSize = Size.zero}) {
    final cur = state.windowFrame;
    final resolvedFrame = look.windowFrame.copyWith(
      deviceFrameId: cur.deviceFrameId,
      deviceFrameColor: cur.deviceFrameColor,
      deviceFrameAdjustSize: cur.deviceFrameAdjustSize,
      clearDeviceFrame: cur.deviceFrameId == null,
    );
    state = state.withLook(look.copyWith(windowFrame: resolvedFrame));
    // Restyle existing zooms + set default; reuses the padding-floor logic.
    applyLookToAllZooms(look.defaultZoomLook, videoSize: videoSize);
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/state/apply_look_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_controller.dart \
        packages/slipreel_engine/test/state/apply_look_test.dart
git commit -m "Add EditorProjectController.applyLook"
```

---

## Task 4: `EditorProjectStore.load(seed:)`

**Files:**
- Modify: `packages/slipreel_engine/lib/state/editor_project_store.dart`
- Test: `packages/slipreel_engine/test/state/editor_project_store_seed_test.dart`

**Interfaces:**
- Consumes: existing `EditorProjectStore.load({required Duration videoDuration})`, `_seedSingleSlice`.
- Produces: `Future<EditorProjectState> load({required Duration videoDuration, EditorProjectState? seed})` — uses `seed ?? EditorProjectState.defaults()` in every no-sidecar/empty/corrupt branch; a parseable sidecar ignores `seed`.

- [ ] **Step 1: Write the failing test**

Create `packages/slipreel_engine/test/state/editor_project_store_seed_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:slipreel_engine/state/editor_project_store.dart';

void main() {
  test('load uses seed when no sidecar exists', () async {
    final dir = await Directory.systemTemp.createTemp('seed_test');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/clip.mov';
    final store = EditorProjectStore(videoPath: videoPath);

    final seed = EditorProjectState.defaults().copyWith(
      outputAspect: OutputAspect.square,
    );
    final loaded = await store.load(
      videoDuration: const Duration(seconds: 5),
      seed: seed,
    );

    expect(loaded.outputAspect, OutputAspect.square);
    // Single slice still seeded over the video duration.
    expect(loaded.timeline.clips, isNotEmpty);
  });

  test('load ignores seed when a valid sidecar exists', () async {
    final dir = await Directory.systemTemp.createTemp('seed_test2');
    addTearDown(() => dir.delete(recursive: true));
    final videoPath = '${dir.path}/clip.mov';
    final store = EditorProjectStore(videoPath: videoPath);

    // Save a project with default (auto) aspect first.
    await store.save(EditorProjectState.defaults());

    final seed = EditorProjectState.defaults().copyWith(
      outputAspect: OutputAspect.square,
    );
    final loaded = await store.load(
      videoDuration: const Duration(seconds: 5),
      seed: seed,
    );
    expect(loaded.outputAspect, OutputAspect.auto);
  });
}
```

Confirm `store.save(...)` exists and its signature by grep; if save requires other args, adjust. `OutputAspect.auto`/`.square` names are from the model — confirm.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_store_seed_test.dart`
Expected: FAIL — `load` has no `seed` parameter.

- [ ] **Step 3: Add the `seed` parameter**

In `editor_project_store.dart`, change the signature and every `EditorProjectState.defaults()` fallback to `(seed ?? EditorProjectState.defaults())`:

```dart
  Future<EditorProjectState> load({
    required Duration videoDuration,
    EditorProjectState? seed,
  }) async {
    final base = seed ?? EditorProjectState.defaults();
    final f = File(sidecarPath);
    if (!await f.exists()) {
      return _seedSingleSlice(base, videoDuration);
    }
    try {
      final text = await f.readAsString();
      if (text.trim().isEmpty) {
        return _seedSingleSlice(base, videoDuration);
      }
      final json = jsonDecode(text) as Map<String, dynamic>;
      return EditorProjectState.fromJson(json, videoDuration: videoDuration);
    } catch (e, stack) {
      AppLogger.ui.w(
        'EditorProjectStore: failed to load $sidecarPath, using defaults',
        error: e,
        stackTrace: stack,
      );
      return _seedSingleSlice(base, videoDuration);
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/state/editor_project_store_seed_test.dart`
Expected: PASS.

- [ ] **Step 5: Run the engine suite to confirm no regressions**

Run: `cd packages/slipreel_engine && flutter test`
Expected: PASS (all).

- [ ] **Step 6: Commit**

```bash
git add packages/slipreel_engine/lib/state/editor_project_store.dart \
        packages/slipreel_engine/test/state/editor_project_store_seed_test.dart
git commit -m "Add seed parameter to EditorProjectStore.load"
```

---

## Task 5: `LookTemplate` model + built-ins

**Files:**
- Create: `packages/screen_recorder/lib/state/look_template.dart`
- Test: `packages/screen_recorder/test/state/look_template_test.dart`

**Interfaces:**
- Consumes: `EditorLook` (engine), `WindowFrame`, `ZoomLook`.
- Produces:
  - `class LookTemplate { String id; String name; bool builtIn; EditorLook look; DateTime updatedAt; }` with `copyWith`, `toJson`/`fromJson` (user templates only — built-ins are not serialized), `==`/`hashCode`.
  - `const kBuiltinCleanId = 'builtin.clean'`, `kBuiltinShowcaseId = 'builtin.showcase'`, `kBuiltinMinimalId = 'builtin.minimal'`.
  - `List<LookTemplate> builtinLookTemplates()` returning Clean, Showcase, Minimal in that order.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/state/look_template_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/state/editor_look.dart';

void main() {
  test('built-ins are Clean/Showcase/Minimal in order', () {
    final b = builtinLookTemplates();
    expect(b.map((t) => t.id).toList(),
        [kBuiltinCleanId, kBuiltinShowcaseId, kBuiltinMinimalId]);
    expect(b.every((t) => t.builtIn), isTrue);
    expect(b[0].look.windowFrame.name, WindowFrame.rounded().name);
    expect(b[0].look.defaultZoomLook, ZoomLook.classic);
    expect(b[1].look.defaultZoomLook, ZoomLook.showcase);
    expect(b[2].look.defaultZoomLook, ZoomLook.flat);
  });

  test('user template JSON round-trips', () {
    final t = LookTemplate(
      id: 'abc',
      name: 'My Look',
      builtIn: false,
      look: EditorLook.defaults(),
      updatedAt: DateTime.utc(2026, 9, 6),
    );
    final restored = LookTemplate.fromJson(t.toJson());
    expect(restored, t);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/look_template_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement the model**

Create `packages/screen_recorder/lib/state/look_template.dart`:

```dart
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/models/zoom_look.dart';
import 'package:slipreel_engine/state/editor_look.dart';

const String kBuiltinCleanId = 'builtin.clean';
const String kBuiltinShowcaseId = 'builtin.showcase';
const String kBuiltinMinimalId = 'builtin.minimal';

/// A named, reusable editor look. Built-ins are code-defined and never
/// written to disk; user templates persist via LookTemplateStore.
class LookTemplate {
  const LookTemplate({
    required this.id,
    required this.name,
    required this.builtIn,
    required this.look,
    required this.updatedAt,
  });

  final String id;
  final String name;
  final bool builtIn;
  final EditorLook look;
  final DateTime updatedAt;

  LookTemplate copyWith({String? name, EditorLook? look, DateTime? updatedAt}) =>
      LookTemplate(
        id: id,
        name: name ?? this.name,
        builtIn: builtIn,
        look: look ?? this.look,
        updatedAt: updatedAt ?? this.updatedAt,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'updatedAt': updatedAt.toUtc().toIso8601String(),
        'look': look.toJson(),
      };

  /// Parses a user template. Throws if required keys are missing/malformed;
  /// the store catches per-entry so one bad row does not sink the file.
  factory LookTemplate.fromJson(Map<String, dynamic> json) => LookTemplate(
        id: json['id'] as String,
        name: json['name'] as String,
        builtIn: false,
        look: EditorLook.fromJson(
          (json['look'] as Map).cast<String, dynamic>(),
        ),
        updatedAt:
            DateTime.tryParse(json['updatedAt'] as String? ?? '')?.toUtc() ??
                DateTime.now().toUtc(),
      );

  @override
  bool operator ==(Object other) =>
      other is LookTemplate &&
      other.id == id &&
      other.name == name &&
      other.builtIn == builtIn &&
      other.look == look &&
      other.updatedAt == updatedAt;

  @override
  int get hashCode => Object.hash(id, name, builtIn, look, updatedAt);
}

/// The three read-only starter templates, in display order.
List<LookTemplate> builtinLookTemplates() {
  final epoch = DateTime.utc(2026, 1, 1);
  LookTemplate b(String id, String name, WindowFrame frame, ZoomLook zoom) =>
      LookTemplate(
        id: id,
        name: name,
        builtIn: true,
        look: EditorLook.defaults()
            .copyWith(windowFrame: frame, defaultZoomLook: zoom),
        updatedAt: epoch,
      );
  return [
    b(kBuiltinCleanId, 'Clean', WindowFrame.rounded(), ZoomLook.classic),
    b(kBuiltinShowcaseId, 'Showcase', WindowFrame.modern(), ZoomLook.showcase),
    b(kBuiltinMinimalId, 'Minimal', WindowFrame.minimal(), ZoomLook.flat),
  ];
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/state/look_template_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/look_template.dart \
        packages/screen_recorder/test/state/look_template_test.dart
git commit -m "Add LookTemplate model and built-in templates"
```

---

## Task 6: `LookTemplateStore` (file persistence)

**Files:**
- Create: `packages/screen_recorder/lib/state/look_template_store.dart`
- Test: `packages/screen_recorder/test/state/look_template_store_test.dart`

**Interfaces:**
- Consumes: `LookTemplate`.
- Produces (all async, serialized through an internal queue like `FileCurveLibrary`):
  - `class LookTemplateStore { LookTemplateStore({String? filePath}); }`
  - `Future<LookTemplateData> load()` where `class LookTemplateData { List<LookTemplate> templates; String selectedId; }` (selectedId defaults to `kBuiltinCleanId`).
  - `Future<void> saveAll(List<LookTemplate> userTemplates, String selectedId)` — atomic tmp+rename; refuses to write if the last load saw a future schema.
  - Constant `static const int schemaVersion = 1`.

- [ ] **Step 1: Write the failing tests**

Create `packages/screen_recorder/test/state/look_template_store_test.dart`:

```dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:screen_recorder/state/look_template_store.dart';
import 'package:slipreel_engine/state/editor_look.dart';

LookTemplate _user(String id, String name) => LookTemplate(
      id: id,
      name: name,
      builtIn: false,
      look: EditorLook.defaults(),
      updatedAt: DateTime.utc(2026, 9, 6),
    );

void main() {
  test('empty file yields no templates and Clean selection', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final store = LookTemplateStore(filePath: '${dir.path}/look_templates.json');
    final data = await store.load();
    expect(data.templates, isEmpty);
    expect(data.selectedId, kBuiltinCleanId);
  });

  test('round-trips user templates and selection', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    final store = LookTemplateStore(filePath: path);
    await store.saveAll([_user('a', 'A'), _user('b', 'B')], 'b');
    final data = await LookTemplateStore(filePath: path).load();
    expect(data.templates.map((t) => t.id), ['a', 'b']);
    expect(data.selectedId, 'b');
    // No leftover tmp file.
    expect(File('$path.tmp').existsSync(), isFalse);
  });

  test('corrupt file is backed up and yields empty', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    await File(path).writeAsString('{ not json');
    final data = await LookTemplateStore(filePath: path).load();
    expect(data.templates, isEmpty);
    expect(
      dir.listSync().whereType<File>().any(
          (f) => f.path.contains('look_templates.json.corrupt-')),
      isTrue,
    );
  });

  test('one bad entry is skipped, others survive', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    final good = _user('a', 'A').toJson();
    await File(path).writeAsString(jsonEncode({
      'schemaVersion': 1,
      'selectedTemplateId': 'a',
      'templates': [good, {'garbage': true}],
    }));
    final data = await LookTemplateStore(filePath: path).load();
    expect(data.templates.map((t) => t.id), ['a']);
  });

  test('future schema refuses to load or write', () async {
    final dir = await Directory.systemTemp.createTemp('lt');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/look_templates.json';
    await File(path).writeAsString(jsonEncode({
      'schemaVersion': 999,
      'selectedTemplateId': 'a',
      'templates': [_user('a', 'A').toJson()],
    }));
    final store = LookTemplateStore(filePath: path);
    final data = await store.load();
    expect(data.templates, isEmpty); // refused
    // Write is refused for this session — file content unchanged.
    await store.saveAll([_user('z', 'Z')], 'z');
    final raw = jsonDecode(await File(path).readAsString());
    expect(raw['schemaVersion'], 999);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && flutter test test/state/look_template_store_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement the store**

Create `packages/screen_recorder/lib/state/look_template_store.dart`, mirroring `FileCurveLibrary` (secure-random not needed here; ids come from the controller). Key behaviors: atomic write (`.tmp` then `rename`), serialized queue, corrupt backup, per-entry skip, future-schema refusal latched for the session.

```dart
import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:slipreel_engine/utils/app_logger.dart';

import 'look_template.dart';

class LookTemplateData {
  const LookTemplateData({required this.templates, required this.selectedId});
  final List<LookTemplate> templates; // user templates only
  final String selectedId;
}

class LookTemplateStore {
  LookTemplateStore({String? filePath}) : _explicitPath = filePath;

  static const int schemaVersion = 1;

  final String? _explicitPath;
  String? _resolvedPath;
  bool _writesBlocked = false; // latched when a future-schema file is seen
  Future<void> _writeQueue = Future.value();

  Future<T> _enqueue<T>(Future<T> Function() op) {
    final next = _writeQueue.then((_) => op());
    _writeQueue = next.then<void>((_) {}, onError: (_) {});
    return next;
  }

  Future<String> _path() async {
    if (_explicitPath != null) return _explicitPath!;
    if (_resolvedPath != null) return _resolvedPath!;
    final dir = await getApplicationSupportDirectory();
    final d = Directory(p.join(dir.path, 'slipreel'));
    if (!await d.exists()) await d.create(recursive: true);
    return _resolvedPath = p.join(d.path, 'look_templates.json');
  }

  Future<LookTemplateData> load() => _enqueue(_load);

  Future<LookTemplateData> _load() async {
    final path = await _path();
    final file = File(path);
    if (!await file.exists()) {
      return const LookTemplateData(templates: [], selectedId: kBuiltinCleanId);
    }
    Map<String, dynamic> json;
    try {
      final raw = await file.readAsString();
      if (raw.trim().isEmpty) {
        return const LookTemplateData(
            templates: [], selectedId: kBuiltinCleanId);
      }
      json = jsonDecode(raw) as Map<String, dynamic>;
    } catch (e, st) {
      AppLogger.ui.w('look_templates.json corrupt; backing up', error: e, stackTrace: st);
      await _backupCorrupt(file);
      return const LookTemplateData(templates: [], selectedId: kBuiltinCleanId);
    }

    final v = json['schemaVersion'];
    if (v is int && v > schemaVersion) {
      AppLogger.ui.w('look_templates.json schema $v > $schemaVersion; refusing');
      _writesBlocked = true;
      return const LookTemplateData(templates: [], selectedId: kBuiltinCleanId);
    }

    final rawList = json['templates'];
    final templates = <LookTemplate>[];
    if (rawList is List) {
      for (final e in rawList) {
        try {
          templates.add(
              LookTemplate.fromJson((e as Map).cast<String, dynamic>()));
        } catch (err) {
          AppLogger.ui.w('Skipping unparseable look template entry: $err');
        }
      }
    }
    final selected = json['selectedTemplateId'];
    return LookTemplateData(
      templates: templates,
      selectedId: selected is String ? selected : kBuiltinCleanId,
    );
  }

  Future<void> saveAll(List<LookTemplate> userTemplates, String selectedId) =>
      _enqueue(() async {
        if (_writesBlocked) {
          AppLogger.ui.w('look_templates write blocked (future schema)');
          return;
        }
        final path = await _path();
        final tmp = File('$path.tmp');
        final payload = jsonEncode({
          'schemaVersion': schemaVersion,
          'selectedTemplateId': selectedId,
          'templates': [for (final t in userTemplates) t.toJson()],
        });
        await tmp.writeAsString(payload, flush: true);
        await tmp.rename(path);
      });

  Future<void> _backupCorrupt(File file) async {
    try {
      final backup = '${file.path}.corrupt-'
          '${DateTime.now().millisecondsSinceEpoch}';
      await file.rename(backup);
    } catch (e, st) {
      AppLogger.ui.w('Failed to back up corrupt look_templates.json',
          error: e, stackTrace: st);
    }
  }
}
```

Confirm `path` package is a dep of `screen_recorder` (it is — used in `main.dart` as `p`). If `AppLogger.ui` is not the right channel, match whatever `recording_settings_store.dart` uses.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/state/look_template_store_test.dart`
Expected: PASS (all five).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/look_template_store.dart \
        packages/screen_recorder/test/state/look_template_store_test.dart
git commit -m "Add LookTemplateStore file persistence"
```

---

## Task 7: `LookTemplateController` + providers

**Files:**
- Create: `packages/screen_recorder/lib/state/look_template_controller.dart`
- Test: `packages/screen_recorder/test/state/look_template_controller_test.dart`

**Interfaces:**
- Consumes: `LookTemplate`, `builtinLookTemplates()`, `LookTemplateStore`, `LookTemplateData`, `EditorLook`.
- Produces:
  - `class LookTemplatesState { List<LookTemplate> all; String selectedId; }` where `all` = built-ins (fixed order) then user templates sorted by name (case-insensitive). Add `LookTemplate get selected` (fallback to Clean if unknown).
  - `class LookTemplateController extends StateNotifier<LookTemplatesState>` with:
    - `LookTemplateController({required LookTemplateStore store, required LookTemplateData initial})`
    - `void select(String id)`
    - `Future<LookTemplate> saveNew(String name, EditorLook look)`
    - `Future<void> update(String id, EditorLook look)` (no-op on built-ins)
    - `Future<void> rename(String id, String name)` (no-op on built-ins)
    - `Future<LookTemplate> duplicate(String id)` (name = "<name> copy")
    - `Future<void> delete(String id)` (no-op on built-ins; selection → Clean if deleted)
  - `lookTemplateStoreProvider` (Provider, throws UnimplementedError, overridden in main).
  - `lookTemplateControllerProvider` (StateNotifierProvider, throws UnimplementedError, overridden in main).

- [ ] **Step 1: Write the failing tests**

Create `packages/screen_recorder/test/state/look_template_controller_test.dart`:

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:screen_recorder/state/look_template_controller.dart';
import 'package:screen_recorder/state/look_template_store.dart';
import 'package:slipreel_engine/state/editor_look.dart';

Future<LookTemplateController> _fresh() async {
  final dir = await Directory.systemTemp.createTemp('ltc');
  addTearDown(() => dir.delete(recursive: true));
  final store = LookTemplateStore(filePath: '${dir.path}/look_templates.json');
  final initial = await store.load();
  return LookTemplateController(store: store, initial: initial);
}

void main() {
  test('built-ins listed first, users sorted by name', () async {
    final c = await _fresh();
    await c.saveNew('Zulu', EditorLook.defaults());
    await c.saveNew('alpha', EditorLook.defaults());
    final ids = c.state.all.map((t) => t.id).toList();
    // First three are built-ins.
    expect(ids.take(3), [kBuiltinCleanId, kBuiltinShowcaseId, kBuiltinMinimalId]);
    // Users sorted case-insensitively: alpha before Zulu.
    final names = c.state.all.skip(3).map((t) => t.name).toList();
    expect(names, ['alpha', 'Zulu']);
  });

  test('update and rename ignore built-ins', () async {
    final c = await _fresh();
    await c.update(kBuiltinCleanId, EditorLook.defaults()); // no throw, no-op
    await c.rename(kBuiltinCleanId, 'Hacked');
    expect(
      c.state.all.firstWhere((t) => t.id == kBuiltinCleanId).name,
      'Clean',
    );
  });

  test('delete selected falls back to Clean', () async {
    final c = await _fresh();
    final t = await c.saveNew('Temp', EditorLook.defaults());
    c.select(t.id);
    expect(c.state.selectedId, t.id);
    await c.delete(t.id);
    expect(c.state.selectedId, kBuiltinCleanId);
    expect(c.state.all.any((x) => x.id == t.id), isFalse);
  });

  test('duplicate copies a built-in as a user template', () async {
    final c = await _fresh();
    final dup = await c.duplicate(kBuiltinShowcaseId);
    expect(dup.builtIn, isFalse);
    expect(dup.name, 'Showcase copy');
    expect(dup.look.defaultZoomLook, c.state.all[1].look.defaultZoomLook);
  });
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd packages/screen_recorder && flutter test test/state/look_template_controller_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement the controller**

Create `packages/screen_recorder/lib/state/look_template_controller.dart`:

```dart
import 'dart:math';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/state/editor_look.dart';

import 'look_template.dart';
import 'look_template_store.dart';

class LookTemplatesState {
  const LookTemplatesState({required this.all, required this.selectedId});
  final List<LookTemplate> all; // built-ins first, then users by name
  final String selectedId;

  LookTemplate get selected => all.firstWhere(
        (t) => t.id == selectedId,
        orElse: () => all.firstWhere((t) => t.id == kBuiltinCleanId),
      );
}

class LookTemplateController extends StateNotifier<LookTemplatesState> {
  LookTemplateController({required this.store, required LookTemplateData initial})
      : _users = List.of(initial.templates),
        super(_compose(initial.templates, initial.selectedId));

  final LookTemplateStore store;
  final List<LookTemplate> _users;
  final Random _rng = Random.secure();

  static LookTemplatesState _compose(List<LookTemplate> users, String selected) {
    final sorted = List.of(users)
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final all = [...builtinLookTemplates(), ...sorted];
    final valid = all.any((t) => t.id == selected) ? selected : kBuiltinCleanId;
    return LookTemplatesState(all: all, selectedId: valid);
  }

  void _publish() => state = _compose(_users, state.selectedId);

  Future<void> _persist() =>
      store.saveAll(_users, state.selectedId);

  String _newId() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  void select(String id) {
    if (state.selectedId == id) return;
    state = LookTemplatesState(all: state.all, selectedId: id);
    _persist();
  }

  Future<LookTemplate> saveNew(String name, EditorLook look) async {
    final t = LookTemplate(
      id: _newId(),
      name: name,
      builtIn: false,
      look: look,
      updatedAt: DateTime.now().toUtc(),
    );
    _users.add(t);
    state = LookTemplatesState(
      all: _compose(_users, t.id).all,
      selectedId: t.id,
    );
    await _persist();
    return t;
  }

  Future<void> update(String id, EditorLook look) async {
    final i = _users.indexWhere((t) => t.id == id);
    if (i < 0) return; // built-in or unknown
    _users[i] = _users[i].copyWith(look: look, updatedAt: DateTime.now().toUtc());
    _publish();
    await _persist();
  }

  Future<void> rename(String id, String name) async {
    final i = _users.indexWhere((t) => t.id == id);
    if (i < 0) return;
    _users[i] = _users[i].copyWith(name: name);
    _publish();
    await _persist();
  }

  Future<LookTemplate> duplicate(String id) async {
    final src = state.all.firstWhere((t) => t.id == id);
    return saveNew('${src.name} copy', src.look);
  }

  Future<void> delete(String id) async {
    final before = _users.length;
    _users.removeWhere((t) => t.id == id);
    if (_users.length == before) return; // built-in or unknown
    final nextSelected =
        state.selectedId == id ? kBuiltinCleanId : state.selectedId;
    state = LookTemplatesState(
      all: _compose(_users, nextSelected).all,
      selectedId: nextSelected,
    );
    await _persist();
  }
}

final lookTemplateStoreProvider = Provider<LookTemplateStore>(
  (ref) => throw UnimplementedError('Override lookTemplateStoreProvider in main()'),
);

final lookTemplateControllerProvider =
    StateNotifierProvider<LookTemplateController, LookTemplatesState>(
  (ref) => throw UnimplementedError(
      'Override lookTemplateControllerProvider in main()'),
);
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd packages/screen_recorder && flutter test test/state/look_template_controller_test.dart`
Expected: PASS (all four).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/look_template_controller.dart \
        packages/screen_recorder/test/state/look_template_controller_test.dart
git commit -m "Add LookTemplateController and providers"
```

---

## Task 8: Capture-toggle last-used persistence

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_settings_store.dart`
- Modify: `packages/screen_recorder/lib/state/microphone_controller.dart`
- Modify: `packages/screen_recorder/lib/state/system_audio_controller.dart`
- Modify: `packages/screen_recorder/lib/state/camera_controller.dart`
- Test: `packages/screen_recorder/test/state/recording_settings_capture_test.dart`

**Interfaces:**
- Consumes: `MicrophoneConfig`, `SystemAudioConfig`, `CameraConfig` (each has `toJson`/`fromJson`).
- Produces:
  - `RecordingSettings` gains `MicrophoneConfig? microphone`, `SystemAudioConfig? systemAudio`, `CameraConfig? camera` (nullable, default null), threaded through `copyWith`/`toJson`/`fromJson`.
  - `MicrophoneController({MicrophoneConfig? initial, void Function(MicrophoneConfig?)? onChanged})`; `set` calls `onChanged`. Same shape for the other two controllers.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/state/recording_settings_capture_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_settings_store.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('RecordingSettings round-trips capture configs', () {
    const mic = MicrophoneConfig(
      deviceUid: 'uid-1',
      deviceLabel: 'Mic',
      reduceNoise: false,
      disableAgc: false,
    );
    const settings = RecordingSettings(countdownSeconds: 5, microphone: mic);
    final restored = RecordingSettings.fromJson(settings.toJson());
    expect(restored.countdownSeconds, 5);
    expect(restored.microphone?.deviceUid, 'uid-1');
    expect(restored.systemAudio, isNull);
    expect(restored.camera, isNull);
  });

  test('old JSON without capture keys loads as null', () {
    final restored = RecordingSettings.fromJson({'countdownSeconds': 3});
    expect(restored.microphone, isNull);
    expect(restored.systemAudio, isNull);
    expect(restored.camera, isNull);
  });
}
```

Confirm `MicrophoneConfig`'s real constructor params via `grep -n "MicrophoneConfig(" packages/screen_recorder_platform_interface/lib/src/models/microphone_config.dart` and adjust the test literal.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/state/recording_settings_capture_test.dart`
Expected: FAIL — `microphone` param undefined.

- [ ] **Step 3: Extend `RecordingSettings`**

In `recording_settings_store.dart`, import the platform interface, add the three fields to the constructor, `copyWith` (with `_unset` sentinels for nullable clearing OR simple `?? this.`), `toJson` (omit null keys), and `fromJson` (decode when present):

```dart
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class RecordingSettings {
  const RecordingSettings({
    this.countdownSeconds = 3,
    this.microphone,
    this.systemAudio,
    this.camera,
  });
  final int countdownSeconds;
  final MicrophoneConfig? microphone;
  final SystemAudioConfig? systemAudio;
  final CameraConfig? camera;

  static const Object _unset = Object();

  RecordingSettings copyWith({
    int? countdownSeconds,
    Object? microphone = _unset,
    Object? systemAudio = _unset,
    Object? camera = _unset,
  }) =>
      RecordingSettings(
        countdownSeconds: countdownSeconds ?? this.countdownSeconds,
        microphone: identical(microphone, _unset)
            ? this.microphone
            : microphone as MicrophoneConfig?,
        systemAudio: identical(systemAudio, _unset)
            ? this.systemAudio
            : systemAudio as SystemAudioConfig?,
        camera:
            identical(camera, _unset) ? this.camera : camera as CameraConfig?,
      );

  Map<String, dynamic> toJson() => {
        'countdownSeconds': countdownSeconds,
        if (microphone != null) 'microphone': microphone!.toJson(),
        if (systemAudio != null) 'systemAudio': systemAudio!.toJson(),
        if (camera != null) 'camera': camera!.toJson(),
      };

  static const defaults = RecordingSettings();
  static const _validCountdowns = {0, 3, 5};

  static RecordingSettings fromJson(Map<String, dynamic> json) {
    final raw = json['countdownSeconds'];
    final countdown = (raw is int && _validCountdowns.contains(raw))
        ? raw
        : defaults.countdownSeconds;
    MicrophoneConfig? mic;
    SystemAudioConfig? sys;
    CameraConfig? cam;
    try {
      final m = json['microphone'];
      if (m is Map) mic = MicrophoneConfig.fromJson(m.cast<String, dynamic>());
      final s = json['systemAudio'];
      if (s is Map) sys = SystemAudioConfig.fromJson(s.cast<String, dynamic>());
      final c = json['camera'];
      if (c is Map) cam = CameraConfig.fromJson(c.cast<String, dynamic>());
    } catch (_) {
      // Malformed capture config → treat as off; countdown still honored.
    }
    return RecordingSettings(
      countdownSeconds: countdown,
      microphone: mic,
      systemAudio: sys,
      camera: cam,
    );
  }
}
```

- [ ] **Step 4: Thread initial + write-through into the three controllers**

`microphone_controller.dart`:

```dart
class MicrophoneController extends StateNotifier<MicrophoneConfig?> {
  MicrophoneController({MicrophoneConfig? initial, this.onChanged})
      : super(initial);

  final void Function(MicrophoneConfig?)? onChanged;

  void set(MicrophoneConfig? config) {
    if (config != state) {
      state = config;
      onChanged?.call(config);
    }
  }
}
```

Update the doc comment (drop "resets to off each launch"). Apply the identical shape to `SystemAudioController` (`SystemAudioConfig?`) and `CameraController` (`CameraConfig?`). The default providers in those files stay (`(ref) => XController()`), overridden in main (Task 9).

- [ ] **Step 5: Run test + affected controller tests**

Run: `cd packages/screen_recorder && flutter test test/state/recording_settings_capture_test.dart`
Expected: PASS.
Run any existing controller tests: `flutter test test/state/` — fix any constructor-call breakages in existing tests (they call `MicrophoneController()` with no args, which still works since params are optional).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_settings_store.dart \
        packages/screen_recorder/lib/state/microphone_controller.dart \
        packages/screen_recorder/lib/state/system_audio_controller.dart \
        packages/screen_recorder/lib/state/camera_controller.dart \
        packages/screen_recorder/test/state/recording_settings_capture_test.dart
git commit -m "Persist mic/system-audio/camera selections across launches"
```

---

## Task 9: Wire providers in `main.dart`

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`
- Test: (manual build; no unit test — wiring only)

**Interfaces:**
- Consumes: `LookTemplateStore`, `LookTemplateController`, `RecordingSettingsStore` (already loaded), the three capture controllers.
- Produces: overrides for `lookTemplateStoreProvider`, `lookTemplateControllerProvider`, `microphoneControllerProvider`, `systemAudioControllerProvider`, `cameraControllerProvider`.

- [ ] **Step 1: Load the template store before `runApp`**

Near the other store loads (after `recordingSettingsStore`), add:

```dart
  final lookTemplateStore = LookTemplateStore();
  final initialLookTemplates = await lookTemplateStore.load();
```

Add the import: `import 'state/look_template_controller.dart';` and `import 'state/look_template_store.dart';`.

- [ ] **Step 2: Add provider overrides**

In the `overrides: [...]` list:

```dart
      lookTemplateStoreProvider.overrideWithValue(lookTemplateStore),
      lookTemplateControllerProvider.overrideWith((ref) => LookTemplateController(
            store: lookTemplateStore,
            initial: initialLookTemplates,
          )),
      microphoneControllerProvider.overrideWith((ref) => MicrophoneController(
            initial: initialRecordingSettings.microphone,
            onChanged: (c) => ref
                .read(recordingSettingsControllerProvider.notifier)
                .setMicrophone(c),
          )),
      systemAudioControllerProvider.overrideWith((ref) => SystemAudioController(
            initial: initialRecordingSettings.systemAudio,
            onChanged: (c) => ref
                .read(recordingSettingsControllerProvider.notifier)
                .setSystemAudio(c),
          )),
      cameraControllerProvider.overrideWith((ref) => CameraController(
            initial: initialRecordingSettings.camera,
            onChanged: (c) => ref
                .read(recordingSettingsControllerProvider.notifier)
                .setCamera(c),
          )),
```

Add imports for the three capture controllers if not already imported.

- [ ] **Step 3: Add the write-through setters on `RecordingSettingsController`**

In `recording_settings_controller.dart`, add:

```dart
  Future<void> setMicrophone(MicrophoneConfig? config) async {
    state = state.copyWith(microphone: config);
    await store.save(state);
  }

  Future<void> setSystemAudio(SystemAudioConfig? config) async {
    state = state.copyWith(systemAudio: config);
    await store.save(state);
  }

  Future<void> setCamera(CameraConfig? config) async {
    state = state.copyWith(camera: config);
    await store.save(state);
  }
```

Import the platform interface in that file.

- [ ] **Step 4: Build to verify wiring compiles**

Run: `cd packages/screen_recorder && flutter build macos --debug` (per macOS build-verify memory; long — see waiting-on-long-commands).
Expected: build succeeds.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/main.dart \
        packages/screen_recorder/lib/state/recording_settings_controller.dart
git commit -m "Wire look-template and capture-persistence providers in main"
```

---

## Task 10: Mic sentinel clears a restored selection

**Files:**
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Test: `packages/screen_recorder/test/state/recording_settings_capture_test.dart` (extend) or a focused widget test.

**Interfaces:**
- Consumes: existing mic-level problem sentinel (mic_status uses `v < 0`), `MicrophoneController.set`.
- Produces: a one-shot rule — if the restored mic selection reports the problem sentinel before the user has opened the mic menu this session, clear it to off (which persists null via write-through).

Per §7.3 of the spec. The mic monitor already emits a negative level for an unavailable device. The bar screen listens to the level stream; add: track `_userTouchedMic` (set true in `_onMicTap`), and when the level stream yields a sentinel while `!_userTouchedMic` and a mic is selected, call `ref.read(microphoneControllerProvider.notifier).set(null)` once.

- [ ] **Step 1: Write a focused test**

Because this is stream-timing UI logic, test the decision function in isolation. Extract the rule into a pure helper and test it:

Create the helper in `recording_bar_screen.dart` (top-level):

```dart
/// Whether a restored mic selection should be auto-cleared: the device is
/// reporting the unavailable sentinel and the user hasn't touched the mic
/// control yet this session.
bool shouldClearRestoredMic({
  required bool hasSelection,
  required bool userTouchedMic,
  required double level,
}) =>
    hasSelection && !userTouchedMic && level < 0;
```

Add to `packages/screen_recorder/test/ui/should_clear_restored_mic_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/recording_bar_screen.dart';

void main() {
  test('clears restored mic on sentinel before user interaction', () {
    expect(
      shouldClearRestoredMic(hasSelection: true, userTouchedMic: false, level: -1),
      isTrue,
    );
  });
  test('does not clear once user touched the control', () {
    expect(
      shouldClearRestoredMic(hasSelection: true, userTouchedMic: true, level: -1),
      isFalse,
    );
  });
  test('does not clear on a normal level', () {
    expect(
      shouldClearRestoredMic(hasSelection: true, userTouchedMic: false, level: 0.3),
      isFalse,
    );
  });
  test('does nothing without a selection', () {
    expect(
      shouldClearRestoredMic(hasSelection: false, userTouchedMic: false, level: -1),
      isFalse,
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/should_clear_restored_mic_test.dart`
Expected: FAIL — helper/undefined export.

- [ ] **Step 3: Implement the helper + wire it**

Add the helper (Step 1). In the bar screen state: add `bool _userTouchedMic = false;`, set it `true` at the top of `_onMicTap`. In the mic-level subscription (find where `_syncMicMonitor`/level stream is consumed; if the level isn't already surfaced to the screen, subscribe to `ScreenRecorderPlatform.instance.micLevelStream` once in `initState`), on each level event call:

```dart
if (shouldClearRestoredMic(
  hasSelection: ref.read(microphoneControllerProvider) != null,
  userTouchedMic: _userTouchedMic,
  level: level,
)) {
  ref.read(microphoneControllerProvider.notifier).set(null);
}
```

Guard so it fires at most once (e.g. set `_userTouchedMic = true` after clearing, or a dedicated `_restoredMicChecked` flag) to avoid repeatedly calling set(null).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/should_clear_restored_mic_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/test/ui/should_clear_restored_mic_test.dart
git commit -m "Clear a restored mic selection when its device is unavailable"
```

---

## Task 11: Inspector `TemplateRow` (apply, save, manage)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/inspector/template_row.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: `packages/screen_recorder/test/ui/template_row_test.dart`

**Interfaces:**
- Consumes: `lookTemplateControllerProvider`, `editorProjectControllerProvider`, `EditorLook.fromProject`, `AppAlerts`, `AppAlertAction`, `context.palette`.
- Produces: `class TemplateRow extends ConsumerWidget` with callbacks:
  - `final void Function(EditorLook look) onApply;` — playback screen calls `_projectController.applyLook(...)` and shows undo toast.
  - `final EditorLook Function() currentLook;` — returns `EditorLook.fromProject(_projectController.current)` for save/update.
  - It renders a dropdown of `state.all` (checked = selected) + an overflow menu (Save as new / Update "Name" [user only] / Duplicate / Rename [user only] / Delete [user only]).

Design note: `TemplateRow` reads templates via `ref.watch(lookTemplateControllerProvider)` and calls the controller for select/save/etc. Applying and reading the current look need the project controller, which lives in the playback screen's provider scope — pass those in as callbacks so `TemplateRow` stays decoupled from the playback screen internals.

- [ ] **Step 1: Write a widget test (menu visibility)**

Create `packages/screen_recorder/test/ui/template_row_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/look_template.dart';
import 'package:screen_recorder/state/look_template_controller.dart';
import 'package:screen_recorder/state/look_template_store.dart';
import 'package:screen_recorder/ui/widgets/inspector/template_row.dart';
import 'package:slipreel_engine/state/editor_look.dart';

void main() {
  testWidgets('overflow menu hides Update/Rename/Delete for built-ins',
      (tester) async {
    final store = LookTemplateStore(filePath: null); // won't be written in test
    final controller = LookTemplateController(
      store: store,
      initial: const LookTemplateData(templates: [], selectedId: kBuiltinCleanId),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        lookTemplateControllerProvider.overrideWith((_) => controller),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: TemplateRow(
            onApply: (_) {},
            currentLook: EditorLook.defaults,
          ),
        ),
      ),
    ));
    // Open the overflow menu.
    await tester.tap(find.byKey(const Key('template-overflow')));
    await tester.pumpAndSettle();
    expect(find.text('Save as new template…'), findsOneWidget);
    expect(find.textContaining('Update'), findsNothing); // Clean is built-in
    expect(find.text('Rename…'), findsNothing);
    expect(find.text('Delete…'), findsNothing);
  });
}
```

Note: `LookTemplateStore(filePath: null)` resolves the real app-support path if a save fires. This test never saves (only reads the menu), so it's safe; if the widget eagerly persists, pass a temp path instead.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/template_row_test.dart`
Expected: FAIL — `template_row.dart` missing.

- [ ] **Step 3: Implement `TemplateRow`**

Create `template_row.dart`. Use `context.palette` tokens, a `DropdownButton`/custom menu for selection, and a `PopupMenuButton` (key `template-overflow`) for actions. On select: `controller.select(id)` then `onApply(controller.state.selected.look)`. On "Save as new": show a name dialog, then `controller.saveNew(name, currentLook())`. On "Update": `controller.update(selectedId, currentLook())` + `AppAlerts.success('Template updated')`. On "Rename"/"Delete": dialogs then controller calls. Keep the widget under ~200 lines; extract the name dialog into a small private function.

Follow the existing inspector widget style (see `inspector_widgets.dart` for shared controls). Match dark tokens.

- [ ] **Step 4: Mount it in `InspectorPanel`**

`TemplateRow` should sit above the tab strip, visible on every tab. In `inspector_panel.dart`'s `build`, wrap the current child in a `Column` with `TemplateRow` on top:

```dart
child: Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: [
    TemplateRow(onApply: widget.onApplyTemplate, currentLook: widget.currentLook),
    const Divider(height: 1),
    Expanded(
      child: selection == null ? _formatMode() : _contextMode(selection),
    ),
  ],
),
```

Add two fields to `InspectorPanel`: `final void Function(EditorLook look) onApplyTemplate;` and `final EditorLook Function() currentLook;` (both required). This means `InspectorPanel` must import `editor_look.dart`.

- [ ] **Step 5: Wire callbacks from the playback screen**

In `playback_screen.dart` where `InspectorPanel(...)` is constructed, add:

```dart
      currentLook: () => EditorLook.fromProject(_projectController.current),
      onApplyTemplate: (look) {
        final vs = _videoSize();
        _projectController.applyLook(look, videoSize: vs);
        AppAlerts.success(
          'Applied ${ref.read(lookTemplateControllerProvider).selected.name}.',
          action: AppAlertAction(label: 'Undo', onPressed: () => _history?.undo()),
        );
        ref.captureAnalytics(AnalyticsEvents.templateApplied,
            properties: {'source': 'editor',
              'builtIn': ref.read(lookTemplateControllerProvider).selected.builtIn});
      },
```

Add imports for `editor_look.dart` and `look_template_controller.dart`. (The `AnalyticsEvents.templateApplied` constant is added in Task 13; if executing strictly in order, temporarily inline the string `'template_applied'` and replace in Task 13, or do Task 13's constant first.)

- [ ] **Step 6: Run tests + build**

Run: `cd packages/screen_recorder && flutter test test/ui/template_row_test.dart`
Expected: PASS.
Run: `flutter build macos --debug` to confirm the panel wiring compiles.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/template_row.dart \
        packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/template_row_test.dart
git commit -m "Add inspector TemplateRow for applying and managing templates"
```

---

## Task 12: Recording-bar template chip + fresh-recording seeding

**Files:**
- Create: `packages/screen_recorder/lib/ui/bar/template_control.dart`
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar.dart`
- Modify: `packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Test: `packages/screen_recorder/test/ui/template_control_test.dart`

**Interfaces:**
- Consumes: `lookTemplateControllerProvider`.
- Produces:
  - `class TemplateControl extends StatelessWidget` (presentational): `final String selectedName; final VoidCallback onTap;` — renders the chip.
  - Bar screen passes the selected name and an `onTemplateTap` that opens a menu (built via `showMenu` or the existing popover pattern) listing `state.all` and calling `controller.select`.
  - Playback screen seeds fresh recordings from the selected template.

- [ ] **Step 1: Write the chip test**

Create `packages/screen_recorder/test/ui/template_control_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/bar/template_control.dart';

void main() {
  testWidgets('renders the selected template name and fires onTap',
      (tester) async {
    var tapped = false;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TemplateControl(
          selectedName: 'Showcase',
          onTap: () => tapped = true,
        ),
      ),
    ));
    expect(find.text('Showcase'), findsOneWidget);
    await tester.tap(find.byType(TemplateControl));
    expect(tapped, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/template_control_test.dart`
Expected: FAIL — file missing.

- [ ] **Step 3: Implement `TemplateControl` + mount in the bar**

Create `template_control.dart` (a compact chip: layout icon + truncated name, styled like `_Mode`/`_GearButton` in `recording_bar.dart`). In `recording_bar.dart`, add `final String templateName;` and `final VoidCallback onTemplateTap;` to `RecordingBar`, and insert `TemplateControl(selectedName: templateName, onTap: onTemplateTap)` after the mode buttons and a `_Divider`, before the camera/mic/audio group.

In `recording_bar_screen.dart`, supply `templateName: ref.watch(lookTemplateControllerProvider).selected.name` and `onTemplateTap: _onTemplateTap`, where `_onTemplateTap` opens a menu of `ref.read(lookTemplateControllerProvider).all` and calls `.notifier.select(id)` on pick. Reuse the native/popup menu approach used by `_onMicTap` for consistency, or a Flutter `showMenu` anchored to the chip.

- [ ] **Step 4: Seed fresh recordings from the selected template**

In `playback_screen.dart`, find the `EditorProjectStore.load(...)` call in `_initializeVideo`/project-load path. Pass the seed:

```dart
final selectedLook = ref.read(lookTemplateControllerProvider).selected.look;
final loaded = await _projectStore.load(
  videoDuration: duration,
  seed: EditorProjectState.defaults().withLook(selectedLook),
);
```

This only takes effect when no sidecar exists (Task 4 guarantees a saved project is untouched). Confirm the exact call site and the `duration` variable name; adjust. Add the import for `look_template_controller.dart` if absent.

- [ ] **Step 5: Run tests + build**

Run: `cd packages/screen_recorder && flutter test test/ui/template_control_test.dart`
Expected: PASS.
Run: `flutter build macos --debug`.
Expected: success.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/bar/template_control.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar.dart \
        packages/screen_recorder/lib/ui/bar/recording_bar_screen.dart \
        packages/screen_recorder/lib/ui/screens/playback_screen.dart \
        packages/screen_recorder/test/ui/template_control_test.dart
git commit -m "Add recording-bar template chip and seed fresh recordings"
```

---

## Task 13: Analytics events

**Files:**
- Modify: analytics events constants file (find via `grep -rn "class AnalyticsEvents" packages/screen_recorder/lib`).
- Modify: `template_row.dart`, `recording_bar_screen.dart`, `playback_screen.dart` (emit events).
- Test: none (constants + call sites).

**Interfaces:**
- Consumes: existing `ref.captureAnalytics(event, properties:)` extension.
- Produces: `AnalyticsEvents.templateApplied = 'template_applied'`, `templateSaved = 'template_saved'`, `templateDeleted = 'template_deleted'`.

- [ ] **Step 1: Add the constants**

Add the three string constants next to existing analytics event constants (match the file's existing style — likely `static const String screenViewed = 'screen_viewed';`).

- [ ] **Step 2: Emit `template_applied`**

Ensure the editor apply path (Task 11 Step 5) and bar select path emit `templateApplied` with `{source: 'editor'|'bar', builtIn: bool}`. Replace any temporary inline string from Task 11 with the constant.

- [ ] **Step 3: Emit `template_saved` / `template_deleted`**

In `TemplateRow`'s save/update handlers: `ref.captureAnalytics(AnalyticsEvents.templateSaved, properties: {'kind': 'new'|'update'})`. In delete handler: `templateDeleted`. No names/looks in properties.

- [ ] **Step 4: Build to confirm**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: success.

- [ ] **Step 5: Commit**

```bash
git add -u packages/screen_recorder/lib
git commit -m "Emit template applied/saved/deleted analytics events"
```

> Note: `git add -u packages/screen_recorder/lib` stages only already-tracked modifications under that path. Confirm with `git status` before committing that no unrelated files are staged.

---

## Task 14: Full-suite verification + live check

**Files:** none (verification only).

- [ ] **Step 1: Run both package suites**

Run: `cd packages/slipreel_engine && flutter test` then `cd packages/screen_recorder && flutter test`
Expected: all green. Fix any regressions before proceeding.

- [ ] **Step 2: Live-verify in the running app**

Use the agent-wires setup (see memory: `driving-flutter-via-agent-wires`). Boot the app, then verify:
1. Record a clip → editor opens styled per the selected template (default Clean).
2. Change a wallpaper/padding, "Save as new template" → new entry appears in the bar and inspector.
3. Open another recording → pick the new template in the inspector → look applies, zooms restyle, one Undo reverts.
4. Change the bar template → record → new recording opens with that look.
5. Pick a mic, quit, relaunch → mic selection restored in the bar.

Capture a screenshot of the inspector `TemplateRow` and the bar chip; send to the user.

- [ ] **Step 3: Final commit (if any verification fixes)**

Commit any fixes with a clear message; otherwise nothing to do.

---

## Self-Review (completed by plan author)

**Spec coverage:**
- §4.1 EditorLook → Task 1. §4.2 LookTemplate + §4.3 built-ins → Task 5. §5.1 store → Task 6. §5.2 controller → Task 7. §6.1 applyLook → Task 3. §6.2 seeding → Task 4 + Task 12 Step 4. §6.3 snapshot (save/update) → Task 11. §6.4 selection persistence → Tasks 7/9/12. §7 capture persistence → Tasks 8/9/10. §8.1 bar chip → Task 12. §8.2 inspector row → Task 11. §8.4 analytics → Task 13. §9 error handling → Tasks 6 (store) + 8 (config parse). §10 testing → distributed across tasks. All covered.

**Placeholder scan:** No TBD/TODO. Two flagged confirmations (enum/constructor names in Tasks 2/3/8, analytics constant ordering in Task 13) are explicit "grep and adjust" steps, not placeholders — the code is complete and the grep is the verification.

**Type consistency:** `applyLook(EditorLook, {Size videoSize})` consistent across Tasks 3/11/12. `withLook` consistent Tasks 1/3/4/12. `LookTemplateData` consistent Tasks 6/7. `saveNew/update/rename/duplicate/delete/select` consistent Tasks 7/11. `EditorLook.fromProject`/`fromJson`/`toJson` consistent throughout. JSON keys match `EditorProjectState.toJson` (verified against the source).
