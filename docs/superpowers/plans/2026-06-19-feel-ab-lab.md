# Feel A/B Lab Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an in-app, debug-gated A/B toggle that flips bundled cursor+screen "feels" live during preview so we can pick the Screen-Studio-like one, then bake the winner.

**Architecture:** Candidate feels are hidden "experimental" enum presets on `ScreenAnimationStyle`/`CursorAnimationStyle`, filtered out of the user picker. A `FeelLabController` applies a bundle (`{screen, cursor, motionTuning}`) via the *existing* editor + motion-tuning setters, so preview↔export stay in lockstep. A debug row in the Animation tab cycles variants; an `ext.slipreel.setFeel` hook drives it programmatically.

**Tech Stack:** Flutter, flutter_riverpod (StateNotifier), melos monorepo (`slipreel_engine` + `screen_recorder`).

**Spec:** `docs/superpowers/specs/2026-06-19-feel-ab-lab-design.md`

---

## Task 1: Experimental presets + `experimental` flag

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/animation_style.dart`
- Test: `packages/slipreel_engine/test/rendering/animation_style_experimental_test.dart`

Add two experimental values to each enum and an `experimental` getter; keep every
existing `switch` exhaustive (Dart enforces this at compile time).

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/rendering/animation_style_experimental_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';

void main() {
  test('experimental screen styles are excluded from the selectable set', () {
    final selectable =
        ScreenAnimationStyle.values.where((s) => !s.experimental).toList();
    expect(selectable, [ScreenAnimationStyle.focused, ScreenAnimationStyle.smooth]);
    expect(ScreenAnimationStyle.studioSoft.experimental, isTrue);
    expect(ScreenAnimationStyle.studioSnappy.experimental, isTrue);
  });

  test('experimental cursor styles are excluded from the selectable set', () {
    final selectable =
        CursorAnimationStyle.values.where((s) => !s.experimental).toList();
    expect(selectable, [
      CursorAnimationStyle.smooth,
      CursorAnimationStyle.medium,
      CursorAnimationStyle.rapid,
      CursorAnimationStyle.none,
    ]);
    expect(CursorAnimationStyle.studioSoft.experimental, isTrue);
    expect(CursorAnimationStyle.studioSnappy.experimental, isTrue);
  });

  test('every value resolves its curves/spring/label (switch totality)', () {
    for (final s in ScreenAnimationStyle.values) {
      expect(s.label, isNotEmpty);
      expect(s.rampCurve, isNotNull);
      expect(s.badgeCurve, isNotNull);
      expect(s.previewCurve, isNotNull);
    }
    for (final s in CursorAnimationStyle.values) {
      expect(s.label, isNotEmpty);
      expect(s.motionSpring, isNotNull);
      expect(s.previewCurve, isNotNull);
      expect(s.fir, isNotNull);
    }
  });
}
```

- [ ] **Step 2: Run the test, confirm it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/animation_style_experimental_test.dart`
Expected: FAIL — `studioSoft`/`studioSnappy` don't exist yet.

- [ ] **Step 3: Add the enum values + flag**

In `animation_style.dart`:
- Add `studioSoft, studioSnappy` to the end of `enum ScreenAnimationStyle` and to
  `enum CursorAnimationStyle` (append last so existing index-based JSON is unaffected).
- Extend every `switch` in `ScreenAnimationStyleData` and `CursorAnimationStyleData`
  with cases for the new values. Starting-point values (we'll refine while tuning):

```dart
// ScreenAnimationStyleData
String get label => switch (this) {
  ScreenAnimationStyle.focused => 'Focused',
  ScreenAnimationStyle.smooth => 'Smooth',
  ScreenAnimationStyle.studioSoft => 'Studio Soft',
  ScreenAnimationStyle.studioSnappy => 'Studio Snappy',
};

bool get experimental => switch (this) {
  ScreenAnimationStyle.focused || ScreenAnimationStyle.smooth => false,
  ScreenAnimationStyle.studioSoft || ScreenAnimationStyle.studioSnappy => true,
};

Duration get badgeDuration => switch (this) {
  ScreenAnimationStyle.focused => const Duration(milliseconds: 150),
  ScreenAnimationStyle.smooth => const Duration(milliseconds: 350),
  ScreenAnimationStyle.studioSoft => const Duration(milliseconds: 420),
  ScreenAnimationStyle.studioSnappy => const Duration(milliseconds: 260),
};

Curve get badgeCurve => switch (this) {
  ScreenAnimationStyle.focused => Curves.easeOutCubic,
  ScreenAnimationStyle.smooth => Curves.easeInOutCubic,
  ScreenAnimationStyle.studioSoft => Curves.easeInOutCubic,
  ScreenAnimationStyle.studioSnappy => Curves.easeOutCubic,
};

// Screen Studio's signature push-in: slow-in, slow-out, weighted toward a
// settled landing. Starting points — refined during A/B tuning.
Curve get rampCurve => switch (this) {
  ScreenAnimationStyle.focused => Curves.easeOutCubic,
  ScreenAnimationStyle.smooth => Curves.easeInOutCubic,
  ScreenAnimationStyle.studioSoft => const Cubic(0.33, 0.0, 0.15, 1.0),
  ScreenAnimationStyle.studioSnappy => const Cubic(0.4, 0.0, 0.2, 1.0),
};

Curve get previewCurve => switch (this) {
  ScreenAnimationStyle.focused => Curves.easeOutCubic,
  ScreenAnimationStyle.smooth => Curves.easeInOutSine,
  ScreenAnimationStyle.studioSoft => Curves.easeInOutCubic,
  ScreenAnimationStyle.studioSnappy => Curves.easeOutCubic,
};

Duration get previewDuration => switch (this) {
  ScreenAnimationStyle.focused => const Duration(milliseconds: 700),
  ScreenAnimationStyle.smooth => const Duration(milliseconds: 1300),
  ScreenAnimationStyle.studioSoft => const Duration(milliseconds: 1100),
  ScreenAnimationStyle.studioSnappy => const Duration(milliseconds: 800),
};
```

```dart
// CursorAnimationStyleData
String get label => switch (this) {
  CursorAnimationStyle.smooth => 'Smooth',
  CursorAnimationStyle.medium => 'Medium',
  CursorAnimationStyle.rapid => 'Rapid',
  CursorAnimationStyle.none => 'None',
  CursorAnimationStyle.studioSoft => 'Studio Soft',
  CursorAnimationStyle.studioSnappy => 'Studio Snappy',
};

bool get experimental => switch (this) {
  CursorAnimationStyle.smooth ||
  CursorAnimationStyle.medium ||
  CursorAnimationStyle.rapid ||
  CursorAnimationStyle.none => false,
  CursorAnimationStyle.studioSoft ||
  CursorAnimationStyle.studioSnappy => true,
};

double get smoothing => switch (this) {
  CursorAnimationStyle.smooth => 0.08,
  CursorAnimationStyle.medium => 0.18,
  CursorAnimationStyle.rapid => 0.40,
  CursorAnimationStyle.none => 1.0,
  CursorAnimationStyle.studioSoft => 0.12,
  CursorAnimationStyle.studioSnappy => 0.22,
};

Curve get previewCurve => switch (this) {
  CursorAnimationStyle.smooth => Curves.easeOutSine,
  CursorAnimationStyle.medium => Curves.easeOutCubic,
  CursorAnimationStyle.rapid => Curves.easeOutQuint,
  CursorAnimationStyle.none => Curves.linear,
  CursorAnimationStyle.studioSoft => Curves.easeOutCubic,
  CursorAnimationStyle.studioSnappy => Curves.easeOutQuint,
};

Duration get previewDuration => switch (this) {
  CursorAnimationStyle.smooth => const Duration(milliseconds: 1400),
  CursorAnimationStyle.medium => const Duration(milliseconds: 800),
  CursorAnimationStyle.rapid => const Duration(milliseconds: 350),
  CursorAnimationStyle.none => const Duration(milliseconds: 80),
  CursorAnimationStyle.studioSoft => const Duration(milliseconds: 1000),
  CursorAnimationStyle.studioSnappy => const Duration(milliseconds: 600),
};

// FIR retained only for legacy JSON round-trip; experimental values reuse a
// reasonable window/curve so the record stays total.
({Duration window, Curve curve}) get fir => switch (this) {
  CursorAnimationStyle.smooth =>
    (window: const Duration(milliseconds: 450), curve: Curves.easeOutCubic),
  CursorAnimationStyle.medium =>
    (window: const Duration(milliseconds: 180), curve: Curves.easeOutCubic),
  CursorAnimationStyle.rapid =>
    (window: const Duration(milliseconds: 65), curve: Curves.easeOutCubic),
  CursorAnimationStyle.none =>
    (window: Duration.zero, curve: Curves.linear),
  CursorAnimationStyle.studioSoft =>
    (window: const Duration(milliseconds: 300), curve: Curves.easeOutCubic),
  CursorAnimationStyle.studioSnappy =>
    (window: const Duration(milliseconds: 140), curve: Curves.easeOutCubic),
};

// Softer chase for Soft, firmer for Snappy; both critically damped (no ring).
MotionSpring get motionSpring => switch (this) {
  CursorAnimationStyle.smooth => const MotionSpring(stiffness: 180, damping: 1.0),
  CursorAnimationStyle.medium => const MotionSpring(stiffness: 380, damping: 1.0),
  CursorAnimationStyle.rapid => const MotionSpring(stiffness: 900, damping: 1.0),
  CursorAnimationStyle.none => MotionSpring.snap,
  CursorAnimationStyle.studioSoft =>
    const MotionSpring(stiffness: 240, damping: 1.0),
  CursorAnimationStyle.studioSnappy =>
    const MotionSpring(stiffness: 520, damping: 1.0),
};
```

`_screenIcon`/`_cursorIcon` in `animation_tab.dart` are `switch` over the enums too —
Task 4 filters the picker to non-experimental, but the icon switches must still be
total. Add icon cases there in Task 4 (noted again below).

- [ ] **Step 4: Run the test, confirm it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/animation_style_experimental_test.dart`
Expected: PASS.

- [ ] **Step 5: Analyze + commit**

```bash
cd packages/slipreel_engine && flutter analyze lib/rendering/animation_style.dart
git add packages/slipreel_engine/lib/rendering/animation_style.dart \
  packages/slipreel_engine/test/rendering/animation_style_experimental_test.dart
git commit -m "feat(feel-lab): add experimental Studio screen/cursor presets + flag (#7)"
```

---

## Task 2: `FeelVariant` bundles

**Files:**
- Create: `packages/slipreel_engine/lib/rendering/feel_variant.dart`
- Test: `packages/slipreel_engine/test/rendering/feel_variant_test.dart`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/rendering/feel_variant_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/feel_variant.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';

void main() {
  test('candidate 0 is the non-experimental Default', () {
    final d = FeelVariant.candidates.first;
    expect(d.label, 'Default');
    expect(d.screen.experimental, isFalse);
    expect(d.cursor.experimental, isFalse);
    expect(d.tuning, MotionTuningPreset.defaults);
  });

  test('there are at least 3 candidates and the Studio ones are experimental', () {
    expect(FeelVariant.candidates.length, greaterThanOrEqualTo(3));
    final studio = FeelVariant.candidates.skip(1);
    for (final v in studio) {
      expect(v.screen.experimental, isTrue, reason: v.label);
      expect(v.cursor.experimental, isTrue, reason: v.label);
    }
  });
}
```

- [ ] **Step 2: Run, confirm fail** — `flutter test test/rendering/feel_variant_test.dart` → FAIL (no file).

- [ ] **Step 3: Implement**

```dart
// packages/slipreel_engine/lib/rendering/feel_variant.dart
import 'package:flutter/foundation.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';

/// A named bundle of screen + cursor + motion-tuning settings, used by the
/// debug Feel A/B Lab to flip a whole "feel" with one control. Candidate 0
/// is the shipping Default; the rest are Screen-Studio-aimed experiments.
@immutable
class FeelVariant {
  const FeelVariant({
    required this.label,
    required this.screen,
    required this.cursor,
    required this.tuning,
  });

  final String label;
  final ScreenAnimationStyle screen;
  final CursorAnimationStyle cursor;
  final MotionTuningPreset tuning;

  static const List<FeelVariant> candidates = [
    FeelVariant(
      label: 'Default',
      screen: ScreenAnimationStyle.smooth,
      cursor: CursorAnimationStyle.smooth,
      tuning: MotionTuningPreset.defaults,
    ),
    FeelVariant(
      label: 'Studio Soft',
      screen: ScreenAnimationStyle.studioSoft,
      cursor: CursorAnimationStyle.studioSoft,
      tuning: MotionTuningPreset.cinematic,
    ),
    FeelVariant(
      label: 'Studio Snappy',
      screen: ScreenAnimationStyle.studioSnappy,
      cursor: CursorAnimationStyle.studioSnappy,
      tuning: MotionTuningPreset.snappy,
    ),
  ];
}
```

- [ ] **Step 4: Run, confirm pass.**

- [ ] **Step 5: Analyze + commit**

```bash
git add packages/slipreel_engine/lib/rendering/feel_variant.dart \
  packages/slipreel_engine/test/rendering/feel_variant_test.dart
git commit -m "feat(feel-lab): FeelVariant bundles (Default + Studio Soft/Snappy) (#7)"
```

---

## Task 3: `FeelLabController`

**Files:**
- Create: `packages/screen_recorder/lib/state/feel_lab_controller.dart`
- Test: `packages/screen_recorder/test/state/feel_lab_controller_test.dart`

The controller holds the active index and applies bundles through the existing
editor + motion-tuning setters. It snapshots the entry config on first apply so
flipping is non-destructive.

**Context for the implementer:** `editorProjectControllerProvider` (from
`slipreel_engine/lib/state/editor_project_controller.dart`) exposes
`setScreenAnimationConfig(ScreenAnimationConfig)` and
`setCursorAnimationConfig(CursorAnimationConfig)`. Its state
(`editorProjectControllerProvider` value) has `.screenAnimationConfig` and
`.cursorAnimationConfig`. `motionTuningProvider` (from
`slipreel_engine/lib/state/motion_tuning_controller.dart`) exposes
`usePreset(MotionTuningPreset)` and `replace(MotionTuning)`; its value is the
current `MotionTuning`. Look at an existing `screen_recorder/test/state/*_test.dart`
for the ProviderContainer + override pattern, and at how `main.dart` builds an
`EditorProjectController` to construct one for the test (constructor is
`EditorProjectController({EditorProjectState? initial})`; `EditorProjectState.defaults()`
is a factory — call with parens).

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/state/feel_lab_controller_test.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/rendering/feel_variant.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';
import 'package:screen_recorder/state/feel_lab_controller.dart';

void main() {
  late ProviderContainer container;

  setUp(() {
    container = ProviderContainer(overrides: [
      // Seed a real editor controller from defaults so the setters work.
      editorProjectControllerProvider.overrideWith(
        (ref) => EditorProjectController(initial: EditorProjectState.defaults()),
      ),
    ]);
    addTearDown(container.dispose);
  });

  EditorProjectState editor() =>
      container.read(editorProjectControllerProvider);

  test('apply(i) writes the i-th variant through the existing setters', () {
    final lab = container.read(feelLabControllerProvider.notifier);
    lab.apply(2); // Studio Snappy
    final v = FeelVariant.candidates[2];
    expect(editor().screenAnimationConfig.preset, v.screen);
    expect(editor().cursorAnimationConfig.preset, v.cursor);
    expect(container.read(feelLabControllerProvider), 2);
  });

  test('cycle wraps around the candidate list', () {
    final lab = container.read(feelLabControllerProvider.notifier);
    for (var i = 0; i < FeelVariant.candidates.length; i++) {
      lab.cycle();
    }
    expect(container.read(feelLabControllerProvider), 0); // wrapped back
  });

  test('restore re-applies the entry snapshot taken on first apply', () {
    final lab = container.read(feelLabControllerProvider.notifier);
    final entryScreen = editor().screenAnimationConfig.preset;
    lab.apply(1);
    expect(editor().screenAnimationConfig.preset,
        isNot(entryScreen)); // changed
    lab.restore();
    expect(editor().screenAnimationConfig.preset, entryScreen); // back
    expect(container.read(feelLabControllerProvider), 0);
  });
}
```

> If `EditorProjectController`'s constructor or `EditorProjectState.defaults` differs,
> adapt the setUp to match — the assertions are the contract.

- [ ] **Step 2: Run, confirm fail.**

- [ ] **Step 3: Implement**

```dart
// packages/screen_recorder/lib/state/feel_lab_controller.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/feel_variant.dart';
import 'package:slipreel_engine/rendering/motion_tuning.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/motion_tuning_controller.dart';

/// Debug-only A/B harness: applies a [FeelVariant] bundle through the
/// existing editor + motion-tuning setters so preview and export stay in
/// lockstep (no parallel override path). State is the active candidate index.
class FeelLabController extends StateNotifier<int> {
  FeelLabController(this._ref) : super(0);

  final Ref _ref;

  // Entry config captured on first non-trivial apply so restore() is exact.
  ScreenAnimationConfig? _entryScreen;
  CursorAnimationConfig? _entryCursor;
  MotionTuning? _entryTuning;

  void _snapshotIfNeeded() {
    if (_entryScreen != null) return;
    final project = _ref.read(editorProjectControllerProvider);
    _entryScreen = project.screenAnimationConfig;
    _entryCursor = project.cursorAnimationConfig;
    _entryTuning = _ref.read(motionTuningProvider);
  }

  void apply(int index) {
    _snapshotIfNeeded();
    final v = FeelVariant.candidates[index % FeelVariant.candidates.length];
    final editor = _ref.read(editorProjectControllerProvider.notifier);
    editor.setScreenAnimationConfig(ScreenAnimationConfig.preset(v.screen));
    editor.setCursorAnimationConfig(CursorAnimationConfig.preset(v.cursor));
    _ref.read(motionTuningProvider.notifier).usePreset(v.tuning);
    state = index % FeelVariant.candidates.length;
  }

  void cycle() => apply(state + 1);
  void cyclePrev() =>
      apply((state - 1 + FeelVariant.candidates.length) %
          FeelVariant.candidates.length);

  /// Re-apply the entry snapshot and reset to Default index. No-op if nothing
  /// was applied yet.
  void restore() {
    if (_entryScreen == null) return;
    final editor = _ref.read(editorProjectControllerProvider.notifier);
    editor.setScreenAnimationConfig(_entryScreen!);
    editor.setCursorAnimationConfig(_entryCursor!);
    _ref.read(motionTuningProvider.notifier).replace(_entryTuning!);
    _entryScreen = null;
    _entryCursor = null;
    _entryTuning = null;
    state = 0;
  }

  /// Keep the current config as the new baseline ("I like this one").
  void commit() {
    _entryScreen = null;
    _entryCursor = null;
    _entryTuning = null;
  }

  String get activeLabel => FeelVariant.candidates[state].label;
}

final feelLabControllerProvider =
    StateNotifierProvider<FeelLabController, int>(
  (ref) => FeelLabController(ref),
);
```

- [ ] **Step 4: Run, confirm pass.**

- [ ] **Step 5: Analyze + commit**

```bash
git add packages/screen_recorder/lib/state/feel_lab_controller.dart \
  packages/screen_recorder/test/state/feel_lab_controller_test.dart
git commit -m "feat(feel-lab): FeelLabController applies bundles via existing setters (#7)"
```

---

## Task 4: Animation-tab filter + debug Feel A/B row

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/animation_tab_feel_row_test.dart`

Two changes: (a) filter the picker loops to non-experimental values so the Studio
tiles never appear; (b) add a `kDebugMode`-gated Feel A/B row.

- [ ] **Step 1: Filter the picker loops**

In `build`, change both loops:
```dart
for (final s in ScreenAnimationStyle.values.where((s) => !s.experimental))
// ...
for (final s in CursorAnimationStyle.values.where((s) => !s.experimental))
```
The `_screenIcon`/`_cursorIcon` switches must stay total — add icon cases for the
experimental values (any sensible icon, they're never shown as tiles but the switch
must compile):
```dart
ScreenAnimationStyle.studioSoft => Icons.movie_filter_outlined,
ScreenAnimationStyle.studioSnappy => Icons.movie_filter,
// ...
CursorAnimationStyle.studioSoft => Icons.auto_awesome_outlined,
CursorAnimationStyle.studioSnappy => Icons.auto_awesome,
```

- [ ] **Step 2: Add the debug row at the top of the ListView children**

```dart
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:screen_recorder/state/feel_lab_controller.dart';
// ...
children: [
  if (kDebugMode) ...[
    _FeelAbRow(),
    const SizedBox(height: 12),
    const InspectorSectionDivider(),
  ],
  const Text('Screen animation style', /* ... unchanged ... */),
  // ...
],
```

```dart
/// Debug-only A/B control: cycles bundled feels via FeelLabController.
class _FeelAbRow extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final index = ref.watch(feelLabControllerProvider);
    final lab = ref.read(feelLabControllerProvider.notifier);
    final label = FeelVariant.candidates[index].label;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: kInspectorPanel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: kInspectorBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.science_outlined, color: Colors.white70, size: 18),
          const SizedBox(width: 8),
          const Text('Feel A/B (dev)',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.chevron_left, color: Colors.white),
            onPressed: lab.cyclePrev,
            tooltip: 'Previous feel',
          ),
          SizedBox(
            width: 96,
            child: Text(label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white)),
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right, color: Colors.white),
            onPressed: lab.cycle,
            tooltip: 'Next feel',
          ),
          IconButton(
            icon: const Icon(Icons.restart_alt, color: Colors.white70),
            onPressed: lab.restore,
            tooltip: 'Restore original',
          ),
        ],
      ),
    );
  }
}
```
(Requires `import 'package:slipreel_engine/rendering/feel_variant.dart';`.)

- [ ] **Step 3: Write the widget test**

```dart
// packages/screen_recorder/test/ui/widgets/inspector/animation_tab_feel_row_test.dart
// Pump AnimationTab inside a ProviderScope with the editor + motionTuning +
// feelLab providers overridden (follow the existing inspector tab test, if any,
// or settings_screen_test.dart for the ProviderScope+MaterialApp shell).
// Assert:
//  - No 'Studio Soft' / 'Studio Snappy' TILE captions render (experimental
//    excluded from the picker). NB the Feel A/B row's label Text DOES show the
//    active candidate label, so assert specifically on the absence of the
//    experimental *tiles* — e.g. there is exactly one 'Smooth' screen tile and
//    the studio labels only ever appear inside the dev row, never as tiles.
//  - In a kDebugMode test run, find.text('Feel A/B (dev)') findsOneWidget.
```
> Keep this test pragmatic — if wiring a full `AnimationTab` pump is heavy
> (it needs a `CurveLibrary` + editor providers), a thinner test that pumps
> just `_FeelAbRow` (make it package-visible via `@visibleForTesting`) plus a
> unit assertion that the picker list excludes experimentals is acceptable.

- [ ] **Step 4: Run the test + analyze, confirm pass/clean.**

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/animation_tab.dart \
  packages/screen_recorder/test/ui/widgets/inspector/animation_tab_feel_row_test.dart
git commit -m "feat(feel-lab): debug Feel A/B row in Animation tab; hide experimental tiles (#7)"
```

---

## Task 5: `ext.slipreel.setFeel` runtime hook

**Files:**
- Modify: `packages/screen_recorder/lib/main.dart`

Register a VM-service extension that applies a feel by index so the lab can be
driven during runtime verification (the editor canvas isn't tappable via the probe).

- [ ] **Step 1: Add the registration**

Near the other `developer.registerExtension('ext.slipreel.*', ...)` calls, add one
that reads `feelLabControllerProvider.notifier` from the app's `ProviderContainer`
(use the same container/ref the existing hooks use — match the pattern of
`ext.slipreel.play` etc.) and calls `apply(int.parse(params['index'] ?? '0'))`,
returning the active label:

```dart
developer.registerExtension('ext.slipreel.setFeel', (method, params) async {
  final i = int.tryParse(params['index'] ?? '') ?? 0;
  container.read(feelLabControllerProvider.notifier).apply(i);
  final label = container.read(feelLabControllerProvider.notifier).activeLabel;
  return developer.ServiceExtensionResponse.result(
    jsonEncode({'index': i, 'label': label}),
  );
});
```
> Match the exact container/ref access and `jsonEncode` import style of the
> surrounding `ext.slipreel.*` handlers in `main.dart`.

- [ ] **Step 2: Analyze**

Run: `cd packages/screen_recorder && flutter analyze lib/main.dart`
Expected: No issues.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/main.dart
git commit -m "feat(feel-lab): ext.slipreel.setFeel hook to drive the lab for verification (#7)"
```

---

## Task 6: Full-suite gate + runtime verify

- [ ] **Step 1: Run both package suites**

```bash
cd packages/slipreel_engine && flutter test
cd packages/screen_recorder && flutter test
```
Expected: all pass (lesson from #2 — always run the WHOLE package suite, not just
the task's targeted tests).

- [ ] **Step 2: Runtime verify** — boot the app, open a recording in the editor,
  open the inspector Animation tab, confirm the **Feel A/B (dev)** row appears and
  `‹ ›` flips the label; drive `ext.slipreel.setFeel` with index 0/1/2 and confirm
  the preview feel changes (zoom push-in + cursor settle). Capture a screenshot of
  the row. Use the verify skill.

- [ ] **Step 3: Tuning session (with the user)** — play the same slice across
  Default / Studio Soft / Studio Snappy, refine the curve constants in Task 1 until
  the Screen-Studio feel lands. This is interactive and not a code-complete gate.

- [ ] **Step 4: Final review** — dispatch a holistic code review over the branch
  diff, then use `superpowers:finishing-a-development-branch`. The **bake step**
  (promote the winning feel to the default + retire experimentals) is a follow-up
  once the user picks, per the spec.
