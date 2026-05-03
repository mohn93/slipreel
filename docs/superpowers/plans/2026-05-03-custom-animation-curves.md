# Custom Animation Curves Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a graph-based custom animation curve editor that coexists with existing presets, applies to screen + cursor + per-zoom-region contexts, and persists user-named curves to a global library.

**Architecture:** New `AnimationCurve` value type (sealed: preset | cubic bezier) with config wrappers per context. `CursorMotionController` is rewritten from per-frame IIR lerp to stateless FIR convolution over the recorded path so curves have meaning for cursor motion. A new inline editor in the inspector exposes the bezier graph + handles + numeric inputs + duration slider + library chips; library is file-backed in app support dir with atomic writes.

**Tech Stack:** Dart 3, Flutter, `flutter_riverpod` (already in deps), `path_provider` (already in deps), `flutter_test`. No new packages.

**Spec:** `docs/superpowers/specs/2026-05-03-custom-animation-curves-design.md`

**Working directory for all paths below:** `packages/screen_recorder/`. Run tests via `flutter test` from that directory unless noted otherwise.

---

## File Structure

**New files:**
- `lib/rendering/animation_curve.dart` — `AnimationCurve` sealed type, `CubicBezierCurve`, `PresetCurve`, JSON roundtrip.
- `lib/rendering/animation_config.dart` — `ScreenAnimationConfig`, `CursorAnimationConfig` value types and accessors that resolve to `(Duration, Curve)`.
- `lib/services/curve_library.dart` — `CurveLibrary` interface + `FileCurveLibrary` impl + `BuiltInCurves` static list + `NamedCurve` value type.
- `lib/ui/widgets/inspector/curve_graph_painter.dart` — `CustomPainter` for the bezier graph, handles, tangent guides, and animated demo dot.
- `lib/ui/widgets/inspector/curve_editor.dart` — Inline editor stateful widget composing graph + handles + numeric inputs + duration slider + chip row + save UI.
- `test/rendering/animation_curve_test.dart`
- `test/rendering/animation_config_test.dart`
- `test/services/curve_library_test.dart`
- `test/ui/widgets/inspector/curve_editor_test.dart`

**Modified files:**
- `lib/rendering/animation_style.dart` — keep enums; add `(Duration, Curve)` tuple accessors used by configs.
- `lib/ui/widgets/zoom/cursor_motion_controller.dart` — replace IIR lerp with FIR convolution; new constructor signature.
- `lib/models/zoom_region.dart` — add `rampCurveOverride` field; backward-compatible JSON via existing `copyWith` plus new `toJson`/`fromJson` (none currently — see Task 5 for whether we add or piggyback on caller serialization).
- `lib/ui/widgets/inspector/tabs/animation_tab.dart` — props become configs; add Custom tile + inline editor.
- `lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart` — add override toggle + editor section.
- `lib/ui/widgets/inspector/inspector_panel.dart` — pipe configs and library through to the tabs and zoom context inspector.
- `lib/ui/screens/playback_screen.dart` — replace enum state with config state; pass per-region or global ramp curve into `ZoomTransformer`; pass cursor config into `CursorMotionController`.
- `test/ui/widgets/zoom/cursor_motion_controller_test.dart` — rewrite for FIR semantics.
- `test/ui/widgets/cursor_overlay_painter_test.dart` — no signature changes expected; keep as-is.

---

## Task 1: AnimationCurve value type

**Files:**
- Create: `lib/rendering/animation_curve.dart`
- Test: `test/rendering/animation_curve_test.dart`

- [ ] **Step 1.1: Write failing test for `CubicBezierCurve` JSON roundtrip and Flutter curve conversion**

```dart
// test/rendering/animation_curve_test.dart
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';

void main() {
  group('CubicBezierCurve', () {
    test('toJson/fromJson roundtrips x1/y1/x2/y2', () {
      const c = CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4);
      final json = c.toJson();
      final back = AnimationCurve.fromJson(json);
      expect(back, isA<CubicBezierCurve>());
      final cb = back as CubicBezierCurve;
      expect(cb.x1, 0.42);
      expect(cb.y1, 0.0);
      expect(cb.x2, 0.58);
      expect(cb.y2, 1.4);
    });

    test('toFlutterCurve produces a Cubic with matching params', () {
      const c = CubicBezierCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0);
      final flutter = c.toFlutterCurve();
      expect(flutter, isA<Cubic>());
      // Sample at endpoints — every cubic bezier with locked (0,0)/(1,1)
      // must hit those corners regardless of control points.
      expect(flutter.transform(0.0), closeTo(0.0, 1e-6));
      expect(flutter.transform(1.0), closeTo(1.0, 1e-6));
    });

    test('equality is value-based', () {
      const a = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      const b = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      const c = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.5);
      expect(a, equals(b));
      expect(a, isNot(equals(c)));
      expect(a.hashCode, equals(b.hashCode));
    });
  });

  group('PresetCurve', () {
    test('toJson/fromJson roundtrips presetId', () {
      const c = PresetCurve(presetId: 'screen.focused');
      final back = AnimationCurve.fromJson(c.toJson());
      expect(back, isA<PresetCurve>());
      expect((back as PresetCurve).presetId, 'screen.focused');
    });
  });
}
```

- [ ] **Step 1.2: Run test, verify it fails**

```
flutter test test/rendering/animation_curve_test.dart
```
Expected: FAIL — `animation_curve.dart` does not exist.

- [ ] **Step 1.3: Create `lib/rendering/animation_curve.dart` with the sealed type**

```dart
import 'package:flutter/animation.dart';

/// Either a named preset (resolved against the active style enums or
/// the saved-curve library) or a user-authored cubic bezier.
sealed class AnimationCurve {
  const AnimationCurve();

  Curve toFlutterCurve();
  Map<String, dynamic> toJson();

  static AnimationCurve fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String?;
    switch (type) {
      case 'preset':
        return PresetCurve(presetId: json['presetId'] as String);
      case 'bezier':
        return CubicBezierCurve(
          x1: (json['x1'] as num).toDouble(),
          y1: (json['y1'] as num).toDouble(),
          x2: (json['x2'] as num).toDouble(),
          y2: (json['y2'] as num).toDouble(),
        );
      default:
        throw FormatException('Unknown AnimationCurve type: $type');
    }
  }
}

class PresetCurve extends AnimationCurve {
  const PresetCurve({required this.presetId});
  final String presetId;

  @override
  Curve toFlutterCurve() {
    // Preset resolution lives in the ScreenAnimationConfig /
    // CursorAnimationConfig wrappers — they know which enum the id
    // belongs to. PresetCurve.toFlutterCurve is only called as a last
    // resort and falls back to linear so we never crash a render pass.
    return Curves.linear;
  }

  @override
  Map<String, dynamic> toJson() => {'type': 'preset', 'presetId': presetId};

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PresetCurve && presetId == other.presetId;

  @override
  int get hashCode => presetId.hashCode;
}

class CubicBezierCurve extends AnimationCurve {
  const CubicBezierCurve({
    required this.x1,
    required this.y1,
    required this.x2,
    required this.y2,
  });

  final double x1;
  final double y1;
  final double x2;
  final double y2;

  @override
  Curve toFlutterCurve() => Cubic(x1, y1, x2, y2);

  @override
  Map<String, dynamic> toJson() => {
        'type': 'bezier',
        'x1': x1,
        'y1': y1,
        'x2': x2,
        'y2': y2,
      };

  CubicBezierCurve copyWith({double? x1, double? y1, double? x2, double? y2}) {
    return CubicBezierCurve(
      x1: x1 ?? this.x1,
      y1: y1 ?? this.y1,
      x2: x2 ?? this.x2,
      y2: y2 ?? this.y2,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CubicBezierCurve &&
          x1 == other.x1 &&
          y1 == other.y1 &&
          x2 == other.x2 &&
          y2 == other.y2;

  @override
  int get hashCode => Object.hash(x1, y1, x2, y2);
}
```

- [ ] **Step 1.4: Run test, verify it passes**

```
flutter test test/rendering/animation_curve_test.dart
```
Expected: PASS, 4 tests.

- [ ] **Step 1.5: Commit**

```bash
git add lib/rendering/animation_curve.dart test/rendering/animation_curve_test.dart
git commit -m "feat(curves): add AnimationCurve value type (preset + cubic bezier)"
```

---

## Task 2: BuiltInCurves catalogue

**Files:**
- Modify: `lib/services/curve_library.dart` (created here, expanded in Task 3)
- Test: `test/services/curve_library_test.dart`

This task is just the standard easings list — separate so future plan steps that reach for "linear / ease / ease-in / ..." find a stable, tested source.

- [ ] **Step 2.1: Write failing test for built-in curves**

```dart
// test/services/curve_library_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';

void main() {
  group('BuiltInCurves', () {
    test('exposes the five CSS standard easings in a stable order', () {
      final ids = BuiltInCurves.all.map((e) => e.id).toList();
      expect(ids, [
        'linear',
        'ease',
        'ease-in',
        'ease-out',
        'ease-in-out',
      ]);
    });

    test('each built-in resolves to a CubicBezierCurve with known params', () {
      final ease = BuiltInCurves.byId('ease')!;
      expect(ease.curve, isA<CubicBezierCurve>());
      final cb = ease.curve as CubicBezierCurve;
      // CSS "ease" = cubic-bezier(0.25, 0.1, 0.25, 1.0)
      expect(cb.x1, closeTo(0.25, 1e-9));
      expect(cb.y1, closeTo(0.10, 1e-9));
      expect(cb.x2, closeTo(0.25, 1e-9));
      expect(cb.y2, closeTo(1.00, 1e-9));
    });

    test('byId returns null for unknown id', () {
      expect(BuiltInCurves.byId('nope'), isNull);
    });
  });
}
```

- [ ] **Step 2.2: Run test, verify it fails**

```
flutter test test/services/curve_library_test.dart
```
Expected: FAIL — file/symbols missing.

- [ ] **Step 2.3: Create `lib/services/curve_library.dart` with built-ins only (library service comes in Task 3)**

```dart
import 'package:screen_recorder/rendering/animation_curve.dart';

/// Identifies a curve in chip rows and editor state. The same record
/// shape is used for built-ins and for user-saved entries.
class NamedCurve {
  const NamedCurve({
    required this.id,
    required this.name,
    required this.curve,
  });
  final String id;
  final String name;
  final CubicBezierCurve curve;
}

/// CSS-standard easings rendered first in the editor's chip row.
/// They never appear in the on-disk library file.
class BuiltInCurves {
  static const List<NamedCurve> all = [
    NamedCurve(
      id: 'linear',
      name: 'Linear',
      curve: CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease',
      name: 'Ease',
      curve: CubicBezierCurve(x1: 0.25, y1: 0.10, x2: 0.25, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-in',
      name: 'Ease in',
      curve: CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 1.0, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-out',
      name: 'Ease out',
      curve: CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0),
    ),
    NamedCurve(
      id: 'ease-in-out',
      name: 'Ease in-out',
      curve: CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
    ),
  ];

  static NamedCurve? byId(String id) {
    for (final c in all) {
      if (c.id == id) return c;
    }
    return null;
  }
}
```

- [ ] **Step 2.4: Run test, verify it passes**

```
flutter test test/services/curve_library_test.dart
```
Expected: PASS, 3 tests.

- [ ] **Step 2.5: Commit**

```bash
git add lib/services/curve_library.dart test/services/curve_library_test.dart
git commit -m "feat(curves): add BuiltInCurves catalogue for editor chips"
```

---

## Task 3: FileCurveLibrary service

**Files:**
- Modify: `lib/services/curve_library.dart`
- Modify: `test/services/curve_library_test.dart`

- [ ] **Step 3.1: Add failing tests for save/list/rename/delete + atomic write + corrupt JSON**

Append a new `group('FileCurveLibrary', ...)` block inside the existing `void main()` of `test/services/curve_library_test.dart` (alongside the existing `BuiltInCurves` group). Add these imports at the top of the file alongside the existing ones:

```dart
import 'dart:convert';
import 'dart:io';
```

Append the group:

```dart
  group('FileCurveLibrary', () {
    late Directory tempDir;
    late FileCurveLibrary lib;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('curve_lib_test_');
      lib = FileCurveLibrary(filePath: '${tempDir.path}/curves.json');
    });

    tearDown(() async {
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('save then list returns the saved curve', () async {
      const c = CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4);
      final saved = await lib.save(name: 'snap-back', curve: c);
      expect(saved.name, 'snap-back');
      expect(saved.curve, c);

      final list = await lib.list();
      expect(list, hasLength(1));
      expect(list.first.id, saved.id);
      expect(list.first.curve, c);
    });

    test('save assigns unique ids', () async {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      final a = await lib.save(name: 'a', curve: c);
      final b = await lib.save(name: 'b', curve: c);
      expect(a.id, isNot(b.id));
    });

    test('rename updates only the name', () async {
      const c = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      final saved = await lib.save(name: 'old', curve: c);
      await lib.rename(saved.id, 'new');
      final list = await lib.list();
      expect(list.first.name, 'new');
      expect(list.first.curve, c);
      expect(list.first.id, saved.id);
    });

    test('delete removes the entry', () async {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      final saved = await lib.save(name: 'x', curve: c);
      await lib.delete(saved.id);
      expect(await lib.list(), isEmpty);
    });

    test('atomic write leaves no .tmp on success', () async {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      await lib.save(name: 'x', curve: c);
      final tmp = File('${tempDir.path}/curves.json.tmp');
      expect(await tmp.exists(), isFalse);
    });

    test('corrupt JSON yields empty list, not a throw', () async {
      final f = File('${tempDir.path}/curves.json');
      await f.writeAsString('not json{{');
      expect(await lib.list(), isEmpty);
    });

    test('schema version 1 is written on save', () async {
      const c = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      await lib.save(name: 'v1', curve: c);
      final raw = await File('${tempDir.path}/curves.json').readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      expect(json['version'], 1);
    });
  });
```

(Closing `});` of the file's existing `main()` stays as it is — the new group sits alongside the `BuiltInCurves` group.)

- [ ] **Step 3.2: Run, verify failures**

```
flutter test test/services/curve_library_test.dart
```
Expected: FAIL — `FileCurveLibrary` not defined.

- [ ] **Step 3.3: Implement `FileCurveLibrary` in `lib/services/curve_library.dart`**

Add to the existing file (above `BuiltInCurves`):

```dart
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:path_provider/path_provider.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/utils/app_logger.dart';

abstract class CurveLibrary {
  Future<List<NamedCurve>> list();
  Future<NamedCurve> save({required String name, required CubicBezierCurve curve});
  Future<void> rename(String id, String newName);
  Future<void> delete(String id);
}

class FileCurveLibrary implements CurveLibrary {
  FileCurveLibrary({String? filePath}) : _explicitPath = filePath;

  final String? _explicitPath;
  String? _resolvedPath;
  final Random _rng = Random.secure();

  Future<String> _path() async {
    if (_explicitPath != null) return _explicitPath!;
    if (_resolvedPath != null) return _resolvedPath!;
    final dir = await getApplicationSupportDirectory();
    final sub = Directory('${dir.path}/screenflow');
    if (!await sub.exists()) {
      await sub.create(recursive: true);
    }
    _resolvedPath = '${sub.path}/curves.json';
    return _resolvedPath!;
  }

  @override
  Future<List<NamedCurve>> list() async {
    final f = File(await _path());
    if (!await f.exists()) return const [];
    try {
      final raw = await f.readAsString();
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final entries = (json['curves'] as List<dynamic>? ?? const []);
      return entries
          .whereType<Map<String, dynamic>>()
          .map((e) => NamedCurve(
                id: e['id'] as String,
                name: e['name'] as String,
                curve: CubicBezierCurve(
                  x1: (e['x1'] as num).toDouble(),
                  y1: (e['y1'] as num).toDouble(),
                  x2: (e['x2'] as num).toDouble(),
                  y2: (e['y2'] as num).toDouble(),
                ),
              ))
          .toList(growable: false);
    } catch (e, st) {
      AppLogger.ui.w('curves.json corrupt — returning empty list',
          error: e, stackTrace: st);
      return const [];
    }
  }

  @override
  Future<NamedCurve> save({
    required String name,
    required CubicBezierCurve curve,
  }) async {
    final entries = [...await list()];
    final id = _newId();
    final entry = NamedCurve(id: id, name: name, curve: curve);
    entries.add(entry);
    await _write(entries);
    return entry;
  }

  @override
  Future<void> rename(String id, String newName) async {
    final entries = await list();
    final next = entries
        .map((e) => e.id == id
            ? NamedCurve(id: e.id, name: newName, curve: e.curve)
            : e)
        .toList(growable: false);
    await _write(next);
  }

  @override
  Future<void> delete(String id) async {
    final entries = await list();
    final next = entries.where((e) => e.id != id).toList(growable: false);
    await _write(next);
  }

  Future<void> _write(List<NamedCurve> entries) async {
    final path = await _path();
    final tmp = File('$path.tmp');
    final json = {
      'version': 1,
      'curves': entries
          .map((e) => {
                'id': e.id,
                'name': e.name,
                'x1': e.curve.x1,
                'y1': e.curve.y1,
                'x2': e.curve.x2,
                'y2': e.curve.y2,
              })
          .toList(),
    };
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename(path);
  }

  String _newId() {
    final bytes = List<int>.generate(8, (_) => _rng.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
```

The codebase's logger uses zone-keyed getters defined in `lib/utils/app_logger.dart`. Existing zones: `platform`, `videoEncoder`, `audioEncoder`, `cursorRenderer`, `recording`, `ui`, `isolate`, `ffmpeg`, `permissions`. For curve library messages we reuse `AppLogger.ui` — no new zone needed. Replace the import line above with:

```dart
import 'package:screen_recorder/utils/app_logger.dart';
```

…and the warning line in `list()` becomes:

```dart
AppLogger.ui.w('curves.json corrupt — returning empty list', error: e, stackTrace: st);
```

- [ ] **Step 3.4: Run, verify pass**

```
flutter test test/services/curve_library_test.dart
```
Expected: PASS, all tests.

- [ ] **Step 3.5: Commit**

```bash
git add lib/services/curve_library.dart test/services/curve_library_test.dart
git commit -m "feat(curves): file-backed CurveLibrary with atomic writes"
```

---

## Task 4: Animation configs

**Files:**
- Create: `lib/rendering/animation_config.dart`
- Test: `test/rendering/animation_config_test.dart`
- Modify: `lib/rendering/animation_style.dart` (add accessors used by configs)

- [ ] **Step 4.1: Write failing tests for `ScreenAnimationConfig` and `CursorAnimationConfig`**

```dart
// test/rendering/animation_config_test.dart
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/rendering/animation_style.dart';

void main() {
  group('ScreenAnimationConfig', () {
    test('preset config resolves badge curve and duration from the enum', () {
      const cfg = ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
      expect(cfg.badgeCurve, ScreenAnimationStyle.smooth.badgeCurve);
      expect(cfg.badgeDuration, ScreenAnimationStyle.smooth.badgeDuration);
      expect(cfg.rampCurve, ScreenAnimationStyle.smooth.rampCurve);
    });

    test('custom config resolves curve to the supplied bezier', () {
      const c = CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4);
      const cfg = ScreenAnimationConfig.custom(
        curve: c,
        badgeDuration: Duration(milliseconds: 500),
      );
      expect(cfg.badgeCurve, isA<Cubic>());
      expect(cfg.rampCurve, isA<Cubic>());
      expect(cfg.badgeDuration, const Duration(milliseconds: 500));
    });

    test('custom without explicit duration falls back to Smooth preset', () {
      const c = CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0);
      const cfg = ScreenAnimationConfig.custom(curve: c);
      expect(cfg.badgeDuration, ScreenAnimationStyle.smooth.badgeDuration);
    });
  });

  group('CursorAnimationConfig', () {
    test('preset config exposes window from re-tuning table', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
      expect(cfg.window, CursorAnimationStyle.smooth.fir.window);
      expect(cfg.firCurve, CursorAnimationStyle.smooth.fir.curve);
    });

    test('custom config carries user window + curve', () {
      const c = CubicBezierCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0);
      const cfg = CursorAnimationConfig.custom(
        curve: c,
        window: Duration(milliseconds: 500),
      );
      expect(cfg.window, const Duration(milliseconds: 500));
      expect(cfg.firCurve, isA<Cubic>());
    });

    test('window=0 preset is "None"', () {
      const cfg = CursorAnimationConfig.preset(CursorAnimationStyle.none);
      expect(cfg.window, Duration.zero);
    });
  });
}
```

- [ ] **Step 4.2: Run, verify failures**

```
flutter test test/rendering/animation_config_test.dart
```
Expected: FAIL — symbols missing.

- [ ] **Step 4.3: Add `(Duration, Curve)` FIR accessors to `lib/rendering/animation_style.dart`**

Append to `extension CursorAnimationStyleData`:

```dart
  /// Re-tuning table: maps each preset to its FIR (window, curve) pair
  /// so cursor smoothing has a single unified mental model with screen
  /// curves. Smooth/Medium/Rapid use easeOutCubic with windows chosen
  /// to match the legacy IIR per-frame lerp's 90% rise time. None
  /// has a zero window (snap).
  ({Duration window, Curve curve}) get fir => switch (this) {
        CursorAnimationStyle.smooth =>
          (window: const Duration(milliseconds: 450), curve: Curves.easeOutCubic),
        CursorAnimationStyle.medium =>
          (window: const Duration(milliseconds: 180), curve: Curves.easeOutCubic),
        CursorAnimationStyle.rapid =>
          (window: const Duration(milliseconds: 65), curve: Curves.easeOutCubic),
        CursorAnimationStyle.none =>
          (window: Duration.zero, curve: Curves.linear),
      };
```

- [ ] **Step 4.4: Create `lib/rendering/animation_config.dart`**

```dart
import 'package:flutter/animation.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/rendering/animation_style.dart';

/// Either a preset pick (one of [ScreenAnimationStyle]) or a custom
/// cubic bezier with an optional badge-tween-duration override. The
/// inspector picker writes one of these into the playback screen's
/// state on every change.
class ScreenAnimationConfig {
  const ScreenAnimationConfig.preset(ScreenAnimationStyle preset)
      : _preset = preset,
        _customCurve = null,
        _customBadgeDuration = null;

  const ScreenAnimationConfig.custom({
    required CubicBezierCurve curve,
    Duration? badgeDuration,
  })  : _preset = null,
        _customCurve = curve,
        _customBadgeDuration = badgeDuration;

  final ScreenAnimationStyle? _preset;
  final CubicBezierCurve? _customCurve;
  final Duration? _customBadgeDuration;

  bool get isCustom => _customCurve != null;
  ScreenAnimationStyle? get preset => _preset;
  CubicBezierCurve? get customCurve => _customCurve;

  Curve get badgeCurve =>
      _customCurve?.toFlutterCurve() ?? _preset!.badgeCurve;

  Curve get rampCurve =>
      _customCurve?.toFlutterCurve() ?? _preset!.rampCurve;

  Duration get badgeDuration =>
      _customBadgeDuration ??
      _preset?.badgeDuration ??
      ScreenAnimationStyle.smooth.badgeDuration;

  Map<String, dynamic> toJson() {
    if (_preset != null) {
      return {'preset': _preset.name};
    }
    return {
      'curve': _customCurve!.toJson(),
      if (_customBadgeDuration != null)
        'badgeDurationMicros': _customBadgeDuration!.inMicroseconds,
    };
  }

  factory ScreenAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      final preset = ScreenAnimationStyle.values.firstWhere(
        (e) => e.name == presetName,
        orElse: () => ScreenAnimationStyle.smooth,
      );
      return ScreenAnimationConfig.preset(preset);
    }
    final curve = AnimationCurve.fromJson(
        json['curve'] as Map<String, dynamic>) as CubicBezierCurve;
    final micros = json['badgeDurationMicros'] as int?;
    return ScreenAnimationConfig.custom(
      curve: curve,
      badgeDuration: micros != null ? Duration(microseconds: micros) : null,
    );
  }
}

class CursorAnimationConfig {
  const CursorAnimationConfig.preset(CursorAnimationStyle preset)
      : _preset = preset,
        _customCurve = null,
        _customWindow = null;

  const CursorAnimationConfig.custom({
    required CubicBezierCurve curve,
    required Duration window,
  })  : _preset = null,
        _customCurve = curve,
        _customWindow = window;

  final CursorAnimationStyle? _preset;
  final CubicBezierCurve? _customCurve;
  final Duration? _customWindow;

  bool get isCustom => _customCurve != null;
  CursorAnimationStyle? get preset => _preset;
  CubicBezierCurve? get customCurve => _customCurve;

  Duration get window => _customWindow ?? _preset!.fir.window;
  Curve get firCurve => _customCurve?.toFlutterCurve() ?? _preset!.fir.curve;

  Map<String, dynamic> toJson() {
    if (_preset != null) {
      return {'preset': _preset.name};
    }
    return {
      'curve': _customCurve!.toJson(),
      'windowMicros': _customWindow!.inMicroseconds,
    };
  }

  factory CursorAnimationConfig.fromJson(Map<String, dynamic> json) {
    final presetName = json['preset'] as String?;
    if (presetName != null) {
      final preset = CursorAnimationStyle.values.firstWhere(
        (e) => e.name == presetName,
        orElse: () => CursorAnimationStyle.smooth,
      );
      return CursorAnimationConfig.preset(preset);
    }
    final curve = AnimationCurve.fromJson(
        json['curve'] as Map<String, dynamic>) as CubicBezierCurve;
    return CursorAnimationConfig.custom(
      curve: curve,
      window: Duration(microseconds: json['windowMicros'] as int),
    );
  }
}
```

- [ ] **Step 4.5: Run, verify pass**

```
flutter test test/rendering/animation_config_test.dart
```
Expected: PASS, all tests.

- [ ] **Step 4.6: Commit**

```bash
git add lib/rendering/animation_config.dart lib/rendering/animation_style.dart \
        test/rendering/animation_config_test.dart
git commit -m "feat(curves): ScreenAnimationConfig + CursorAnimationConfig"
```

---

## Task 5: Cursor FIR rewrite

**Files:**
- Modify: `lib/ui/widgets/zoom/cursor_motion_controller.dart`
- Modify: `test/ui/widgets/zoom/cursor_motion_controller_test.dart`
- Modify: `lib/ui/screens/playback_screen.dart` (call site update)

- [ ] **Step 5.1: Rewrite the cursor controller test for FIR semantics**

Replace the entire content of `test/ui/widgets/zoom/cursor_motion_controller_test.dart`:

```dart
import 'package:flutter/animation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/ui/widgets/zoom/cursor_motion_controller.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

CursorRecording _record(
    List<({int micros, double x, double y, bool clicked})> samples) {
  final r = CursorRecording();
  for (final s in samples) {
    r.addPosition(CursorPosition(
      x: s.x, y: s.y, timestampMicros: s.micros, isClicked: s.clicked,
    ));
  }
  return r;
}

void main() {
  group('CursorMotionController (FIR)', () {
    test('returns null when there is no cursor data', () {
      final ctrl = CursorMotionController();
      final out = ctrl.update(
        position: const Duration(milliseconds: 50),
        cursorRecording: _record([]),
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out, isNull);
    });

    test('window=0 (None preset) bypasses FIR and returns raw sample', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 16000, x: 100, y: 0, clicked: false),
      ]);

      final out = ctrl.update(
        position: const Duration(milliseconds: 16),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.none),
        fps: 60,
      );
      expect(out!.screenPos.dx, closeTo(100, 1e-6));
    });

    test('FIR weights sum to 1 (rendered position lies on the path)', () {
      final ctrl = CursorMotionController();
      // Stationary target. FIR average must equal the constant value.
      final rec = _record(List.generate(60, (i) => (
            micros: i * 16667, x: 42.0, y: 7.0, clicked: false,
          )));
      final out = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out!.screenPos.dx, closeTo(42.0, 1e-3));
      expect(out.screenPos.dy, closeTo(7.0, 1e-3));
    });

    test('idempotent at the same position', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 200, y: 0, clicked: false),
      ]);
      final cfg = const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth);

      final a = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      final b = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      expect(b!.screenPos, a!.screenPos);
    });

    test('near start of recording, taps before t=0 clamp to first sample', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 50, y: 50, clicked: false),
        (micros: 1000000, x: 50, y: 50, clicked: false),
      ]);
      // Position at t=0 with a 450 ms window — most taps would land
      // before t=0; they must clamp to the first sample (50,50), not
      // throw.
      final out = ctrl.update(
        position: Duration.zero,
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      expect(out, isNotNull);
      expect(out!.screenPos.dx, closeTo(50, 1e-3));
      expect(out.screenPos.dy, closeTo(50, 1e-3));
    });

    test('changing config invalidates the kernel cache', () {
      final ctrl = CursorMotionController();
      // Step from 0 to 100 at t=500ms.
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 499000, x: 0, y: 0, clicked: false),
        (micros: 500000, x: 100, y: 0, clicked: false),
        (micros: 1000000, x: 100, y: 0, clicked: false),
      ]);

      final smooth = ctrl.update(
        position: const Duration(milliseconds: 750),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.smooth),
        fps: 60,
      );
      final rapid = ctrl.update(
        position: const Duration(milliseconds: 750),
        cursorRecording: rec,
        config: const CursorAnimationConfig.preset(CursorAnimationStyle.rapid),
        fps: 60,
      );
      // Rapid has a much shorter window, so by 250 ms past the step it
      // should be much closer to the new value (100) than smooth.
      expect(rapid!.screenPos.dx, greaterThan(smooth!.screenPos.dx));
    });

    test('reset() clears the cache so the next update recomputes', () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 100000, x: 100, y: 0, clicked: false),
      ]);
      final cfg = const CursorAnimationConfig.preset(
          CursorAnimationStyle.smooth);

      final a = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      ctrl.reset();
      final b = ctrl.update(
        position: const Duration(milliseconds: 100),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      // Same inputs → same output, but importantly no exception.
      expect(b!.screenPos, a!.screenPos);
    });

    test('custom curve evaluates without throwing and returns finite Offset',
        () {
      final ctrl = CursorMotionController();
      final rec = _record([
        (micros: 0, x: 0, y: 0, clicked: false),
        (micros: 1000000, x: 200, y: 100, clicked: false),
      ]);
      const cfg = CursorAnimationConfig.custom(
        curve: CubicBezierCurveDummy.testCurve,
        window: Duration(milliseconds: 300),
      );
      final out = ctrl.update(
        position: const Duration(milliseconds: 500),
        cursorRecording: rec, config: cfg, fps: 60,
      );
      expect(out!.screenPos.dx.isFinite, isTrue);
      expect(out.screenPos.dy.isFinite, isTrue);
    });
  });
}

// Compile-time-constant bezier for the custom test above.
abstract class CubicBezierCurveDummy {
  static const testCurve =
      CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0);
}
```

(The `CubicBezierCurveDummy` indirection is just to keep the const expression literal — `CursorAnimationConfig.custom` requires a const curve.)

- [ ] **Step 5.2: Run, verify failures**

```
flutter test test/ui/widgets/zoom/cursor_motion_controller_test.dart
```
Expected: FAIL — `CursorMotionController.update` signature mismatch.

- [ ] **Step 5.3: Rewrite `lib/ui/widgets/zoom/cursor_motion_controller.dart`**

Replace entire file content:

```dart
import 'dart:math' as math;

import 'package:flutter/animation.dart';
import 'package:flutter/painting.dart' show Offset;
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/cursor_geometry.dart';

/// Stateless FIR convolution over the recorded cursor path.
///
/// Each `update` builds (or reuses) a kernel from the active config's
/// `(window, curve)` pair, then samples the recorded cursor at past
/// times relative to `position` weighted by the kernel. There's no
/// running smoothed-state — every frame is computed from scratch —
/// so scrubbing the playhead can never strand a stale value.
///
/// Two caches:
///   - kernel cache, keyed by (window, curve) — invalidated when the
///     config changes,
///   - result cache, keyed by `position` — fixes the parent-setState
///     double-builder problem (same as ZoomFocalController).
class CursorMotionController {
  // Kernel cache.
  Duration? _kernelWindow;
  Curve? _kernelCurve;
  int? _kernelFps;
  List<double>? _kernelWeights;

  // Result cache (idempotency for same-frame rebuilds).
  Duration? _cachedPosition;
  CursorMotionUpdate? _cachedResult;
  Object? _cachedConfigKey;

  CursorMotionUpdate? update({
    required Duration position,
    required CursorRecording cursorRecording,
    required CursorAnimationConfig config,
    required int fps,
  }) {
    final configKey = _configKey(config, fps);
    if (_cachedPosition == position && _cachedConfigKey == configKey) {
      return _cachedResult;
    }
    _cachedPosition = position;
    _cachedConfigKey = configKey;

    if (config.window == Duration.zero) {
      // Snap path — no FIR, no kernel.
      final raw = cursorAt(cursorRecording, position);
      if (raw == null) {
        _cachedResult = null;
        return null;
      }
      _cachedResult = CursorMotionUpdate(
        screenPos: Offset(raw.x, raw.y),
        isClicked: raw.isClicked,
      );
      return _cachedResult;
    }

    final weights = _ensureKernel(window: config.window, curve: config.firCurve, fps: fps);
    final framePeriodMicros = (1000000 / fps).round();

    double accX = 0;
    double accY = 0;
    double accW = 0;
    bool anyClicked = false;
    for (var i = 0; i < weights.length; i++) {
      final tapMicros = position.inMicroseconds - i * framePeriodMicros;
      final tapTime = Duration(
        microseconds: tapMicros < 0 ? 0 : tapMicros,
      );
      final s = cursorAt(cursorRecording, tapTime);
      if (s == null) continue;
      accX += s.x * weights[i];
      accY += s.y * weights[i];
      accW += weights[i];
      if (i == 0 && s.isClicked) anyClicked = true;
    }
    if (accW == 0) {
      _cachedResult = null;
      return null;
    }
    final inv = 1.0 / accW;
    _cachedResult = CursorMotionUpdate(
      screenPos: Offset(accX * inv, accY * inv),
      isClicked: anyClicked,
    );
    return _cachedResult;
  }

  void reset() {
    _cachedPosition = null;
    _cachedResult = null;
    _cachedConfigKey = null;
  }

  // --- internals --------------------------------------------------------

  Object _configKey(CursorAnimationConfig c, int fps) =>
      Object.hash(c.window.inMicroseconds, c.firCurve.runtimeType,
          identityHashCode(c.firCurve), fps);

  List<double> _ensureKernel({
    required Duration window,
    required Curve curve,
    required int fps,
  }) {
    if (_kernelWindow == window &&
        identical(_kernelCurve, curve) &&
        _kernelFps == fps &&
        _kernelWeights != null) {
      return _kernelWeights!;
    }

    final n = math.max(1, (window.inMicroseconds * fps / 1000000).round());
    final weights = List<double>.filled(n, 0);
    double sum = 0;
    for (var i = 0; i < n; i++) {
      final hi = curve.transform(((n - i) / n).clamp(0.0, 1.0));
      final lo = curve.transform(((n - i - 1) / n).clamp(0.0, 1.0));
      final w = (hi - lo).abs();
      weights[i] = w;
      sum += w;
    }
    if (sum > 0) {
      for (var i = 0; i < n; i++) {
        weights[i] /= sum;
      }
    } else {
      // Degenerate curve — fall back to "snap to most recent tap".
      weights[0] = 1.0;
    }

    _kernelWindow = window;
    _kernelCurve = curve;
    _kernelFps = fps;
    _kernelWeights = weights;
    return weights;
  }
}

class CursorMotionUpdate {
  const CursorMotionUpdate({
    required this.screenPos,
    required this.isClicked,
  });
  final Offset screenPos;
  final bool isClicked;
}
```

- [ ] **Step 5.4: Update the call site in `lib/ui/screens/playback_screen.dart`**

Find the existing call (around line 576):

```dart
? _cursorMotionController.update(
    position: ...,
    cursorRecording: _cursorRecording,
    smoothing: _cursorAnimationStyle.smoothing,
  )
```

Replace with:

```dart
? _cursorMotionController.update(
    position: position,                      // existing local
    cursorRecording: _cursorRecording,
    config: CursorAnimationConfig.preset(_cursorAnimationStyle),
    fps: _metadata?.fps ?? 60,
  )
```

(Wiring the `CursorAnimationConfig` field directly — instead of building it from the enum each frame — is Task 10.)

- [ ] **Step 5.5: Run cursor controller tests, verify pass**

```
flutter test test/ui/widgets/zoom/cursor_motion_controller_test.dart
```
Expected: PASS, all tests.

- [ ] **Step 5.6: Run full test suite to confirm no regressions**

```
flutter test
```
Expected: PASS.

- [ ] **Step 5.7: Commit**

```bash
git add lib/ui/widgets/zoom/cursor_motion_controller.dart \
        test/ui/widgets/zoom/cursor_motion_controller_test.dart \
        lib/ui/screens/playback_screen.dart
git commit -m "refactor(cursor): replace IIR lerp with FIR convolution + curve config"
```

---

## Task 6: ZoomRegion ramp curve override

**Files:**
- Modify: `lib/models/zoom_region.dart`
- Test: `test/models/zoom_region_test.dart` (create if missing)

- [ ] **Step 6.1: Inspect existing zoom_region tests**

```bash
ls test/models/
```

If `zoom_region_test.dart` does not exist, create it. If it does, append the new tests there.

- [ ] **Step 6.2: Write failing test for `rampCurveOverride` field + copyWith**

```dart
// test/models/zoom_region_test.dart  — append or create
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';

void main() {
  group('ZoomRegion.rampCurveOverride', () {
    test('defaults to null', () {
      final z = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );
      expect(z.rampCurveOverride, isNull);
    });

    test('copyWith sets and clears override', () {
      final z = ZoomRegion(
        rect: const Rect.fromLTWH(0, 0, 10, 10),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );
      const override = CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4);
      final z2 = z.copyWith(rampCurveOverride: override);
      expect(z2.rampCurveOverride, override);

      // copyWith with explicit null: use the sentinel-style overload to
      // distinguish "leave as-is" from "clear".
      final z3 = z2.copyWith(clearRampCurveOverride: true);
      expect(z3.rampCurveOverride, isNull);
    });
  });
}
```

- [ ] **Step 6.3: Run, verify fail**

```
flutter test test/models/zoom_region_test.dart
```
Expected: FAIL.

- [ ] **Step 6.4: Add field + copyWith parameter to `lib/models/zoom_region.dart`**

Add import:

```dart
import 'package:screen_recorder/rendering/animation_curve.dart';
```

In the field block (alongside `enterDuration`, `exitDuration`):

```dart
final AnimationCurve? rampCurveOverride;
```

Update constructor:

```dart
ZoomRegion({
  required Rect rect,
  required this.startTime,
  required this.duration,
  required double zoomLevel,
  Duration? enterDuration,
  Duration? exitDuration,
  Size? videoBounds,
  this.rampCurveOverride,
})  : assert(duration > Duration.zero, 'Duration must be positive'),
      ...
```

Update `copyWith` to support clearing the override:

```dart
ZoomRegion copyWith({
  Rect? rect,
  Duration? startTime,
  Duration? duration,
  double? zoomLevel,
  Duration? enterDuration,
  Duration? exitDuration,
  Size? videoBounds,
  AnimationCurve? rampCurveOverride,
  bool clearRampCurveOverride = false,
}) {
  return ZoomRegion(
    rect: rect ?? this.rect,
    startTime: startTime ?? this.startTime,
    duration: duration ?? this.duration,
    zoomLevel: zoomLevel ?? this.zoomLevel,
    enterDuration: enterDuration ?? this.enterDuration,
    exitDuration: exitDuration ?? this.exitDuration,
    videoBounds: videoBounds,
    rampCurveOverride: clearRampCurveOverride
        ? null
        : (rampCurveOverride ?? this.rampCurveOverride),
  );
}
```

Update `==` and `hashCode` to include `rampCurveOverride`.

- [ ] **Step 6.5: Run, verify pass**

```
flutter test test/models/zoom_region_test.dart
```
Expected: PASS.

- [ ] **Step 6.6: Run full suite**

```
flutter test
```
Expected: PASS — pre-existing tests for `ZoomRegion` still pass because the new field is optional.

- [ ] **Step 6.7: Commit**

```bash
git add lib/models/zoom_region.dart test/models/zoom_region_test.dart
git commit -m "feat(zoom): rampCurveOverride field on ZoomRegion"
```

---

## Task 7: Curve graph painter

**Files:**
- Create: `lib/ui/widgets/inspector/curve_graph_painter.dart`
- Test: defer to widget test in Task 8 (the painter is render-only — its correctness is best validated through the editor widget).

- [ ] **Step 7.1: Create `lib/ui/widgets/inspector/curve_graph_painter.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart'
    show kInspectorAccent, kInspectorBorder;

/// Renders the bezier graph: axes box, the curve sampled at ~64 points,
/// tangent guide lines from (0,0)→handle1 and (1,1)→handle2, the two
/// draggable handles, and (optionally) an animated demo dot whose
/// horizontal position is `progress` (0–1).
class CurveGraphPainter extends CustomPainter {
  CurveGraphPainter({
    required this.curve,
    required this.demoProgress,
    required this.draggingHandle,
  });

  final CubicBezierCurve curve;
  /// 0–1 — current x-coord of the demo dot. The dot's y is the curve
  /// evaluated at this x.
  final double demoProgress;
  /// 0 = none, 1 = handle 1, 2 = handle 2. Drives a glow on the active
  /// handle so users see what they're dragging.
  final int draggingHandle;

  @override
  void paint(Canvas canvas, Size size) {
    // Axes box.
    final box = Rect.fromLTWH(0, 0, size.width, size.height);
    final axesPaint = Paint()
      ..color = kInspectorBorder
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawRect(box, axesPaint);

    // Light grid (quartiles).
    for (var i = 1; i < 4; i++) {
      final dx = size.width * i / 4;
      final dy = size.height * i / 4;
      canvas.drawLine(Offset(dx, 0), Offset(dx, size.height),
          Paint()..color = kInspectorBorder.withValues(alpha: 0.3));
      canvas.drawLine(Offset(0, dy), Offset(size.width, dy),
          Paint()..color = kInspectorBorder.withValues(alpha: 0.3));
    }

    Offset toScreen(double x, double y) {
      return Offset(x * size.width, (1 - y) * size.height);
    }

    // Tangent guide lines.
    final guidePaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.35)
      ..strokeWidth = 1;
    canvas.drawLine(toScreen(0, 0), toScreen(curve.x1, curve.y1), guidePaint);
    canvas.drawLine(toScreen(1, 1), toScreen(curve.x2, curve.y2), guidePaint);

    // Curve path — sample 64 points using the Flutter Cubic.
    final cubic = Cubic(curve.x1, curve.y1, curve.x2, curve.y2);
    final path = Path()..moveTo(0, size.height);
    const samples = 64;
    for (var i = 1; i <= samples; i++) {
      final tx = i / samples;
      final ty = cubic.transform(tx);
      path.lineTo(tx * size.width, (1 - ty) * size.height);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = kInspectorAccent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    // Handles.
    void handle(int idx, double x, double y) {
      final p = toScreen(x, y);
      final glowing = draggingHandle == idx;
      if (glowing) {
        canvas.drawCircle(
          p, 12,
          Paint()..color = kInspectorAccent.withValues(alpha: 0.25),
        );
      }
      canvas.drawCircle(p, 6, Paint()..color = kInspectorAccent);
      canvas.drawCircle(
        p, 6,
        Paint()
          ..style = PaintingStyle.stroke
          ..color = Colors.white.withValues(alpha: 0.85)
          ..strokeWidth = 1.4,
      );
    }
    handle(1, curve.x1, curve.y1);
    handle(2, curve.x2, curve.y2);

    // Demo dot.
    final dx = demoProgress.clamp(0.0, 1.0);
    final dy = cubic.transform(dx);
    final dot = toScreen(dx, dy);
    canvas.drawCircle(dot, 4.5, Paint()..color = Colors.white);
  }

  @override
  bool shouldRepaint(covariant CurveGraphPainter old) =>
      old.curve != curve ||
      old.demoProgress != demoProgress ||
      old.draggingHandle != draggingHandle;
}
```

- [ ] **Step 7.2: Run analyzer to confirm no warnings**

```
dart analyze lib/ui/widgets/inspector/curve_graph_painter.dart
```
Expected: clean.

- [ ] **Step 7.3: Commit**

```bash
git add lib/ui/widgets/inspector/curve_graph_painter.dart
git commit -m "feat(curves): CurveGraphPainter for inline editor"
```

---

## Task 8: Inline curve editor widget

**Files:**
- Create: `lib/ui/widgets/inspector/curve_editor.dart`
- Test: `test/ui/widgets/inspector/curve_editor_test.dart`

This widget composes graph + handles drag + numeric inputs + duration slider + chip row + save UI. It accepts a `CurveLibrary` (interface from Task 3) so widget tests can pass a fake.

- [ ] **Step 8.1: Write failing widget tests**

```dart
// test/ui/widgets/inspector/curve_editor_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';

class _FakeLibrary implements CurveLibrary {
  final List<NamedCurve> _entries = [];
  @override
  Future<List<NamedCurve>> list() async => List.of(_entries);
  @override
  Future<NamedCurve> save({required String name, required CubicBezierCurve curve}) async {
    final n = NamedCurve(id: '${_entries.length}', name: name, curve: curve);
    _entries.add(n);
    return n;
  }
  @override
  Future<void> rename(String id, String newName) async {
    for (var i = 0; i < _entries.length; i++) {
      if (_entries[i].id == id) {
        _entries[i] = NamedCurve(id: id, name: newName, curve: _entries[i].curve);
      }
    }
  }
  @override
  Future<void> delete(String id) async {
    _entries.removeWhere((e) => e.id == id);
  }
}

void main() {
  testWidgets('numeric input edits flow back to onChanged on submit',
      (tester) async {
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => captured = c,
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: true,
        ),
      ),
    ));

    final field = find.byKey(const ValueKey('curveEditor.x1Field'));
    await tester.enterText(field, '0.42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(captured?.x1, closeTo(0.42, 1e-9));
  });

  testWidgets('numeric input clamps x1 to [0, 1]', (tester) async {
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => captured = c,
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: true,
        ),
      ),
    ));

    final field = find.byKey(const ValueKey('curveEditor.x1Field'));
    await tester.enterText(field, '1.5');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();

    expect(captured?.x1, 1.0);
  });

  testWidgets('clicking a built-in chip overwrites the curve', (tester) async {
    CubicBezierCurve? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.0, y1: 0.0, x2: 1.0, y2: 1.0),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => captured = c,
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('curveEditor.chip.ease')));
    await tester.pump();

    expect(captured, BuiltInCurves.byId('ease')!.curve);
  });

  testWidgets('Save to library persists then shows the new chip',
      (tester) async {
    final lib = _FakeLibrary();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (_) {},
          onDurationChanged: (_) {},
          library: lib,
          showDurationSlider: true,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('curveEditor.saveButton')));
    await tester.pumpAndSettle();
    await tester.enterText(
        find.byKey(const ValueKey('curveEditor.saveNameField')), 'snap-back');
    await tester.tap(find.byKey(const ValueKey('curveEditor.saveConfirm')));
    await tester.pumpAndSettle();

    expect(lib.list().then((l) => l.first.name), completion('snap-back'));
    expect(find.byKey(const ValueKey('curveEditor.chip.0')), findsOneWidget);
  });

  testWidgets('hides duration slider when showDurationSlider=false',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CurveEditor(
          curve: const CubicBezierCurve(x1: 0.1, y1: 0.2, x2: 0.3, y2: 0.4),
          duration: const Duration(milliseconds: 320),
          durationLabel: 'Duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (_) {},
          onDurationChanged: (_) {},
          library: _FakeLibrary(),
          showDurationSlider: false,
        ),
      ),
    ));

    expect(find.byKey(const ValueKey('curveEditor.durationSlider')),
        findsNothing);
  });
}
```

- [ ] **Step 8.2: Run, verify failures**

```
flutter test test/ui/widgets/inspector/curve_editor_test.dart
```
Expected: FAIL — `CurveEditor` does not exist.

- [ ] **Step 8.3: Implement `lib/ui/widgets/inspector/curve_editor.dart`**

```dart
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_graph_painter.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Inline graph editor used by the Animation tab and the per-region
/// override section. Live: every drag / chip / numeric edit calls back
/// immediately so the canvas reflects the curve in real time.
class CurveEditor extends StatefulWidget {
  const CurveEditor({
    super.key,
    required this.curve,
    required this.duration,
    required this.durationLabel,
    required this.durationMin,
    required this.durationMax,
    required this.onCurveChanged,
    required this.onDurationChanged,
    required this.library,
    required this.showDurationSlider,
  });

  final CubicBezierCurve curve;
  final Duration duration;
  final String durationLabel;
  final Duration durationMin;
  final Duration durationMax;
  final ValueChanged<CubicBezierCurve> onCurveChanged;
  final ValueChanged<Duration> onDurationChanged;
  final CurveLibrary library;
  final bool showDurationSlider;

  @override
  State<CurveEditor> createState() => _CurveEditorState();
}

class _CurveEditorState extends State<CurveEditor>
    with SingleTickerProviderStateMixin {
  late final AnimationController _demoCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  )..repeat(reverse: true);
  int _draggingHandle = 0;
  List<NamedCurve> _saved = const [];
  bool _showSaveField = false;
  final TextEditingController _saveName = TextEditingController();

  late TextEditingController _x1, _y1, _x2, _y2;

  @override
  void initState() {
    super.initState();
    _x1 = TextEditingController(text: widget.curve.x1.toStringAsFixed(2));
    _y1 = TextEditingController(text: widget.curve.y1.toStringAsFixed(2));
    _x2 = TextEditingController(text: widget.curve.x2.toStringAsFixed(2));
    _y2 = TextEditingController(text: widget.curve.y2.toStringAsFixed(2));
    _refreshLibrary();
  }

  @override
  void didUpdateWidget(covariant CurveEditor old) {
    super.didUpdateWidget(old);
    if (old.curve != widget.curve) {
      _x1.text = widget.curve.x1.toStringAsFixed(2);
      _y1.text = widget.curve.y1.toStringAsFixed(2);
      _x2.text = widget.curve.x2.toStringAsFixed(2);
      _y2.text = widget.curve.y2.toStringAsFixed(2);
    }
  }

  @override
  void dispose() {
    _demoCtrl.dispose();
    _saveName.dispose();
    _x1.dispose();
    _y1.dispose();
    _x2.dispose();
    _y2.dispose();
    super.dispose();
  }

  Future<void> _refreshLibrary() async {
    final l = await widget.library.list();
    if (!mounted) return;
    setState(() => _saved = l);
  }

  void _commitNumeric(int idx, String raw) {
    final v = double.tryParse(raw);
    if (v == null) return;
    var x1 = widget.curve.x1;
    var y1 = widget.curve.y1;
    var x2 = widget.curve.x2;
    var y2 = widget.curve.y2;
    switch (idx) {
      case 0: x1 = v.clamp(0.0, 1.0); break;
      case 1: y1 = v.clamp(-0.5, 1.5); break;
      case 2: x2 = v.clamp(0.0, 1.0); break;
      case 3: y2 = v.clamp(-0.5, 1.5); break;
    }
    widget.onCurveChanged(CubicBezierCurve(x1: x1, y1: y1, x2: x2, y2: y2));
  }

  void _onDragHandle(int idx, Offset local, Size size) {
    final nx = (local.dx / size.width).clamp(0.0, 1.0);
    final ny = (1 - (local.dy / size.height)).clamp(-0.5, 1.5);
    var x1 = widget.curve.x1;
    var y1 = widget.curve.y1;
    var x2 = widget.curve.x2;
    var y2 = widget.curve.y2;
    if (idx == 1) { x1 = nx; y1 = ny; }
    if (idx == 2) { x2 = nx; y2 = ny; }
    widget.onCurveChanged(CubicBezierCurve(x1: x1, y1: y1, x2: x2, y2: y2));
  }

  int _hitTestHandle(Offset local, Size size) {
    Offset toScreen(double x, double y) =>
        Offset(x * size.width, (1 - y) * size.height);
    final h1 = toScreen(widget.curve.x1, widget.curve.y1);
    final h2 = toScreen(widget.curve.x2, widget.curve.y2);
    if ((local - h1).distance < 16) return 1;
    if ((local - h2).distance < 16) return 2;
    return 0;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 12),
        AspectRatio(
          aspectRatio: 1,
          child: LayoutBuilder(builder: (context, c) {
            final size = Size(c.maxWidth, c.maxHeight);
            return GestureDetector(
              onPanDown: (d) {
                final h = _hitTestHandle(d.localPosition, size);
                if (h != 0) setState(() => _draggingHandle = h);
              },
              onPanUpdate: (d) {
                if (_draggingHandle != 0) {
                  _onDragHandle(_draggingHandle, d.localPosition, size);
                }
              },
              onPanEnd: (_) => setState(() => _draggingHandle = 0),
              child: AnimatedBuilder(
                animation: _demoCtrl,
                builder: (_, __) => CustomPaint(
                  painter: CurveGraphPainter(
                    curve: widget.curve,
                    demoProgress: _demoCtrl.value,
                    draggingHandle: _draggingHandle,
                  ),
                  size: size,
                ),
              ),
            );
          }),
        ),
        const SizedBox(height: 10),
        Row(children: [
          Expanded(child: _numField(0, 'x1', _x1)),
          const SizedBox(width: 6),
          Expanded(child: _numField(1, 'y1', _y1)),
          const SizedBox(width: 6),
          Expanded(child: _numField(2, 'x2', _x2)),
          const SizedBox(width: 6),
          Expanded(child: _numField(3, 'y2', _y2)),
        ]),
        if (widget.showDurationSlider) ...[
          const SizedBox(height: 12),
          _DurationSlider(
            key: const ValueKey('curveEditor.durationSlider'),
            label: widget.durationLabel,
            value: widget.duration,
            min: widget.durationMin,
            max: widget.durationMax,
            onChanged: widget.onDurationChanged,
          ),
        ],
        const SizedBox(height: 12),
        const Text('Library',
            style: TextStyle(color: Colors.white, fontSize: 13)),
        const SizedBox(height: 6),
        Wrap(spacing: 6, runSpacing: 6, children: [
          for (final b in BuiltInCurves.all)
            _Chip(
              key: ValueKey('curveEditor.chip.${b.id}'),
              label: b.name,
              onTap: () => widget.onCurveChanged(b.curve),
            ),
          for (final s in _saved)
            _Chip(
              key: ValueKey('curveEditor.chip.${s.id}'),
              label: s.name,
              onTap: () => widget.onCurveChanged(s.curve),
              onLongPress: () async {
                await widget.library.delete(s.id);
                _refreshLibrary();
              },
            ),
        ]),
        const SizedBox(height: 10),
        if (!_showSaveField)
          OutlinedButton(
            key: const ValueKey('curveEditor.saveButton'),
            onPressed: () => setState(() => _showSaveField = true),
            child: const Text('Save to library…'),
          )
        else
          Row(children: [
            Expanded(
              child: TextField(
                key: const ValueKey('curveEditor.saveNameField'),
                controller: _saveName,
                decoration:
                    const InputDecoration(hintText: 'Curve name'),
              ),
            ),
            const SizedBox(width: 6),
            ElevatedButton(
              key: const ValueKey('curveEditor.saveConfirm'),
              onPressed: () async {
                final name = _saveName.text.trim();
                if (name.isEmpty) return;
                await widget.library.save(name: name, curve: widget.curve);
                _saveName.clear();
                setState(() => _showSaveField = false);
                _refreshLibrary();
              },
              child: const Text('Save'),
            ),
          ]),
      ],
    );
  }

  Widget _numField(int idx, String label, TextEditingController c) {
    final keyPrefix = ['x1', 'y1', 'x2', 'y2'][idx];
    return TextField(
      key: ValueKey('curveEditor.${keyPrefix}Field'),
      controller: c,
      keyboardType: const TextInputType.numberWithOptions(
          signed: true, decimal: true),
      textInputAction: TextInputAction.done,
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[-0-9.]')),
      ],
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
            horizontal: 6, vertical: 6),
      ),
      onSubmitted: (raw) => _commitNumeric(idx, raw),
      onEditingComplete: () => _commitNumeric(idx, c.text),
    );
  }
}

class _Chip extends StatelessWidget {
  const _Chip({
    super.key,
    required this.label,
    required this.onTap,
    this.onLongPress,
  });
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      onLongPress: onLongPress,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: kInspectorBorder),
        ),
        child: Text(label,
            style: const TextStyle(color: Colors.white, fontSize: 12)),
      ),
    );
  }
}

class _DurationSlider extends StatelessWidget {
  const _DurationSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });
  final String label;
  final Duration value, min, max;
  final ValueChanged<Duration> onChanged;
  @override
  Widget build(BuildContext context) {
    final t = (value.inMicroseconds - min.inMicroseconds) /
        (max.inMicroseconds - min.inMicroseconds).clamp(1, 1 << 31);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 13)),
      Slider(
        value: t.clamp(0.0, 1.0).toDouble(),
        onChanged: (v) {
          final micros = min.inMicroseconds +
              ((max.inMicroseconds - min.inMicroseconds) * v).round();
          onChanged(Duration(microseconds: micros));
        },
      ),
      Text('${value.inMilliseconds} ms',
          style: const TextStyle(color: kInspectorMuted, fontSize: 11)),
    ]);
  }
}
```

- [ ] **Step 8.4: Run editor tests**

```
flutter test test/ui/widgets/inspector/curve_editor_test.dart
```
Expected: PASS, 5 tests.

- [ ] **Step 8.5: Run analyzer**

```
dart analyze lib/ui/widgets/inspector/curve_editor.dart \
             lib/ui/widgets/inspector/curve_graph_painter.dart
```
Expected: clean.

- [ ] **Step 8.6: Commit**

```bash
git add lib/ui/widgets/inspector/curve_editor.dart \
        test/ui/widgets/inspector/curve_editor_test.dart
git commit -m "feat(curves): inline CurveEditor widget"
```

---

## Task 9: Animation tab — wire Custom tile + editor

**Files:**
- Modify: `lib/ui/widgets/inspector/tabs/animation_tab.dart`
- Modify: `lib/ui/widgets/inspector/inspector_panel.dart`

The tab still ships the existing English-named preset tiles. We append a **Custom** tile that, when selected, expands the inline editor below.

- [ ] **Step 9.1: Update `AnimationTab`'s public props**

Replace the prop signature in `lib/ui/widgets/inspector/tabs/animation_tab.dart`:

```dart
class AnimationTab extends StatefulWidget {
  const AnimationTab({
    super.key,
    required this.screenConfig,
    required this.onScreenConfigChanged,
    required this.cursorConfig,
    required this.onCursorConfigChanged,
    required this.motionBlur,
    required this.onMotionBlurChanged,
    required this.library,
  });

  final ScreenAnimationConfig screenConfig;
  final ValueChanged<ScreenAnimationConfig> onScreenConfigChanged;
  final CursorAnimationConfig cursorConfig;
  final ValueChanged<CursorAnimationConfig> onCursorConfigChanged;
  final double motionBlur;
  final ValueChanged<double> onMotionBlurChanged;
  final CurveLibrary library;
  // ...
}
```

Add imports:
```dart
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';
```

Drop the import of `'package:screen_recorder/rendering/animation_style.dart'` only if it's no longer used after changes (it's still needed for the enum tiles, so keep it).

- [ ] **Step 9.2: Replace `build` method body to render preset tiles + Custom tile + inline editor**

```dart
@override
Widget build(BuildContext context) {
  return ListView(
    padding: EdgeInsets.zero,
    children: [
      const Text('Screen animation style',
          style: TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final s in ScreenAnimationStyle.values)
          _AnimationOptionTile<ScreenAnimationStyle>(
            value: s,
            selected: widget.screenConfig.preset,
            label: s.label,
            icon: _screenIcon(s),
            previewCurve: s.previewCurve,
            previewDuration: s.previewDuration,
            onSelected: (s) =>
                widget.onScreenConfigChanged(ScreenAnimationConfig.preset(s)),
            size: 84,
          ),
        _CustomTile(
          selected: widget.screenConfig.isCustom,
          curve: widget.screenConfig.customCurve ??
              const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
          onTap: () => widget.onScreenConfigChanged(
            ScreenAnimationConfig.custom(
              curve: widget.screenConfig.customCurve ??
                  const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
              badgeDuration: widget.screenConfig.badgeDuration,
            ),
          ),
          size: 84,
        ),
      ]),
      if (widget.screenConfig.isCustom)
        CurveEditor(
          curve: widget.screenConfig.customCurve!,
          duration: widget.screenConfig.badgeDuration,
          durationLabel: 'Badge duration',
          durationMin: const Duration(milliseconds: 100),
          durationMax: const Duration(milliseconds: 1000),
          onCurveChanged: (c) => widget.onScreenConfigChanged(
            ScreenAnimationConfig.custom(
              curve: c,
              badgeDuration: widget.screenConfig.badgeDuration,
            ),
          ),
          onDurationChanged: (d) => widget.onScreenConfigChanged(
            ScreenAnimationConfig.custom(
              curve: widget.screenConfig.customCurve!,
              badgeDuration: d,
            ),
          ),
          library: widget.library,
          showDurationSlider: true,
        ),
      const SizedBox(height: 12),
      const InspectorSectionDivider(),
      const Text('Cursor animation style',
          style: TextStyle(
              color: Colors.white, fontSize: 15, fontWeight: FontWeight.w600)),
      const SizedBox(height: 12),
      Wrap(spacing: 10, runSpacing: 10, children: [
        for (final s in CursorAnimationStyle.values)
          _AnimationOptionTile<CursorAnimationStyle>(
            value: s,
            selected: widget.cursorConfig.preset,
            label: s.label,
            icon: _cursorIcon(s),
            previewCurve: s.previewCurve,
            previewDuration: s.previewDuration,
            onSelected: (s) =>
                widget.onCursorConfigChanged(CursorAnimationConfig.preset(s)),
            size: 76,
          ),
        _CustomTile(
          selected: widget.cursorConfig.isCustom,
          curve: widget.cursorConfig.customCurve ??
              const CubicBezierCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0),
          onTap: () => widget.onCursorConfigChanged(
            CursorAnimationConfig.custom(
              curve: widget.cursorConfig.customCurve ??
                  const CubicBezierCurve(x1: 0.25, y1: 0.1, x2: 0.25, y2: 1.0),
              window: widget.cursorConfig.window == Duration.zero
                  ? const Duration(milliseconds: 300)
                  : widget.cursorConfig.window,
            ),
          ),
          size: 76,
        ),
      ]),
      if (widget.cursorConfig.isCustom)
        CurveEditor(
          curve: widget.cursorConfig.customCurve!,
          duration: widget.cursorConfig.window,
          durationLabel: 'Catch-up window',
          durationMin: Duration.zero,
          durationMax: const Duration(milliseconds: 1500),
          onCurveChanged: (c) => widget.onCursorConfigChanged(
            CursorAnimationConfig.custom(
              curve: c, window: widget.cursorConfig.window,
            ),
          ),
          onDurationChanged: (d) => widget.onCursorConfigChanged(
            CursorAnimationConfig.custom(
              curve: widget.cursorConfig.customCurve!, window: d,
            ),
          ),
          library: widget.library,
          showDurationSlider: true,
        ),
      const InspectorSectionDivider(),
      InspectorSlider(
        label: 'Motion blur',
        subtitle:
            'While mouse cursor or screen is moving, cinematic motion '
            'blur effect will be applied. (Coming soon — value is '
            'captured but not yet rendered.)',
        value: widget.motionBlur,
        min: 0, max: 1,
        onChanged: widget.onMotionBlurChanged,
        onReset: () => widget.onMotionBlurChanged(0),
        canReset: widget.motionBlur != 0,
      ),
      const SizedBox(height: 24),
      const InspectorCollapsible(
        title: 'Advanced motion blur settings',
        child: Text(
          'Per-component blur tuning. Coming soon.',
          style: TextStyle(
              color: Colors.white60, fontSize: 13, height: 1.4),
        ),
      ),
      const SizedBox(height: 24),
    ],
  );
}
```

- [ ] **Step 9.3: Update `_AnimationOptionTile` to accept nullable selected (since `preset` is null when custom)**

```dart
class _AnimationOptionTile<T> extends StatefulWidget {
  const _AnimationOptionTile({
    super.key,
    required this.value,
    required this.selected,    // now T?
    required this.label,
    required this.icon,
    required this.previewCurve,
    required this.previewDuration,
    required this.onSelected,
    required this.size,
  });
  final T value;
  final T? selected;
  // ...
}
```

In the build of the tile, change `widget.value == widget.selected` to `widget.value == widget.selected` (still works because `==` against null returns false).

- [ ] **Step 9.4: Add `_CustomTile`**

```dart
class _CustomTile extends StatefulWidget {
  const _CustomTile({
    required this.selected,
    required this.curve,
    required this.onTap,
    required this.size,
  });
  final bool selected;
  final CubicBezierCurve curve;
  final VoidCallback onTap;
  final double size;
  @override
  State<_CustomTile> createState() => _CustomTileState();
}

class _CustomTileState extends State<_CustomTile> {
  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        width: widget.size,
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(
            height: widget.size,
            decoration: BoxDecoration(
              color: kInspectorPanel,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: widget.selected
                    ? kInspectorAccent
                    : kInspectorBorder,
                width: 1,
              ),
            ),
            child: CustomPaint(
              painter: CurveGraphPainter(
                curve: widget.curve,
                demoProgress: 0.5,
                draggingHandle: 0,
              ),
            ),
          ),
          const SizedBox(height: 6),
          const Text('Custom',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500)),
        ]),
      ),
    );
  }
}
```

Add the import for `CurveGraphPainter`.

- [ ] **Step 9.5: Update `inspector_panel.dart` to thread the new props**

In `lib/ui/widgets/inspector/inspector_panel.dart`, replace these prop fields:

```dart
final ScreenAnimationStyle screenAnimationStyle;
final CursorAnimationStyle cursorAnimationStyle;
final ValueChanged<ScreenAnimationStyle>? onScreenAnimationStyleChanged;
final ValueChanged<CursorAnimationStyle>? onCursorAnimationStyleChanged;
```

with:

```dart
final ScreenAnimationConfig screenAnimationConfig;
final CursorAnimationConfig cursorAnimationConfig;
final ValueChanged<ScreenAnimationConfig>? onScreenAnimationConfigChanged;
final ValueChanged<CursorAnimationConfig>? onCursorAnimationConfigChanged;
final CurveLibrary curveLibrary;
```

Update the constructor accordingly (defaults: `ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth)` etc., and require `curveLibrary`).

Update the `AnimationTab(...)` instantiation to:

```dart
AnimationTab(
  screenConfig: widget.screenAnimationConfig,
  onScreenConfigChanged: (c) =>
      widget.onScreenAnimationConfigChanged?.call(c),
  cursorConfig: widget.cursorAnimationConfig,
  onCursorConfigChanged: (c) =>
      widget.onCursorAnimationConfigChanged?.call(c),
  motionBlur: widget.motionBlur,
  onMotionBlurChanged: (v) =>
      widget.onMotionBlurChanged?.call(v),
  library: widget.curveLibrary,
)
```

Add the necessary imports.

- [ ] **Step 9.6: Run analyzer to find call-site failures (we expect at least one in `playback_screen.dart`)**

```
dart analyze lib/
```
Expected: errors at the `InspectorPanel(...)` call site in `playback_screen.dart` because the props changed. We fix those in Task 11.

- [ ] **Step 9.7: Commit**

```bash
git add lib/ui/widgets/inspector/tabs/animation_tab.dart \
        lib/ui/widgets/inspector/inspector_panel.dart
git commit -m "feat(curves): Custom tile + inline editor in animation tab"
```

---

## Task 10: Per-zoom-region override section

**Files:**
- Modify: `lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart`

- [ ] **Step 10.1: Extend `ZoomContextInspector` props**

At the top of the file, add imports:

```dart
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';
import 'package:screen_recorder/ui/widgets/inspector/curve_editor.dart';
```

Add to the constructor:

```dart
required this.curveLibrary,
required this.onCurveOverrideChanged,
```

And the field:

```dart
final CurveLibrary curveLibrary;
final ValueChanged<AnimationCurve?> onCurveOverrideChanged;
```

- [ ] **Step 10.2: Add a collapsible override section to the build**

Inside the `ListView` children, after the existing zoom controls, add:

```dart
const InspectorSectionDivider(),
InspectorToggle(
  label: 'Animation override',
  subtitle: 'Use a custom curve for this region\'s ramp.',
  value: zoom.rampCurveOverride != null,
  onChanged: (v) {
    if (v) {
      onCurveOverrideChanged(
        const CubicBezierCurve(x1: 0.42, y1: 0.0, x2: 0.58, y2: 1.0),
      );
    } else {
      onCurveOverrideChanged(null);
    }
  },
),
if (zoom.rampCurveOverride is CubicBezierCurve)
  CurveEditor(
    curve: zoom.rampCurveOverride as CubicBezierCurve,
    duration: Duration.zero,        // unused — slider hidden
    durationLabel: '',
    durationMin: Duration.zero,
    durationMax: Duration.zero,
    onCurveChanged: onCurveOverrideChanged,
    onDurationChanged: (_) {},
    library: curveLibrary,
    showDurationSlider: false,
  ),
```

- [ ] **Step 10.3: Run analyzer**

```
dart analyze lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart
```
Expected: errors at the call sites passing this widget — fixed in Task 11.

- [ ] **Step 10.4: Commit**

```bash
git add lib/ui/widgets/inspector/contexts/zoom_context_inspector.dart
git commit -m "feat(curves): per-zoom-region rampCurveOverride section"
```

---

## Task 11: Wire playback screen + apply per-region override at render

**Files:**
- Modify: `lib/ui/screens/playback_screen.dart`
- Modify: `lib/ui/widgets/inspector/inspector_panel.dart` (callsite for ZoomContextInspector)

- [ ] **Step 11.1: Replace enum state fields with config state in `playback_screen.dart`**

Find the existing fields (around line 69) and replace:

```dart
ScreenAnimationStyle _screenAnimationStyle = ScreenAnimationStyle.smooth;
CursorAnimationStyle _cursorAnimationStyle = CursorAnimationStyle.smooth;
```

with:

```dart
ScreenAnimationConfig _screenAnimationConfig =
    const ScreenAnimationConfig.preset(ScreenAnimationStyle.smooth);
CursorAnimationConfig _cursorAnimationConfig =
    const CursorAnimationConfig.preset(CursorAnimationStyle.smooth);
late final FileCurveLibrary _curveLibrary = FileCurveLibrary();
```

Add imports:

```dart
import 'package:screen_recorder/rendering/animation_config.dart';
import 'package:screen_recorder/rendering/animation_curve.dart';
import 'package:screen_recorder/services/curve_library.dart';
```

- [ ] **Step 11.2: Update `InspectorPanel(...)` call site to pass new props**

Find the existing args:

```dart
screenAnimationStyle: _screenAnimationStyle,
cursorAnimationStyle: _cursorAnimationStyle,
onScreenAnimationStyleChanged: (s) =>
    setState(() => _screenAnimationStyle = s),
onCursorAnimationStyleChanged: (s) =>
    setState(() => _cursorAnimationStyle = s),
```

Replace with:

```dart
screenAnimationConfig: _screenAnimationConfig,
cursorAnimationConfig: _cursorAnimationConfig,
onScreenAnimationConfigChanged: (c) =>
    setState(() => _screenAnimationConfig = c),
onCursorAnimationConfigChanged: (c) =>
    setState(() => _cursorAnimationConfig = c),
curveLibrary: _curveLibrary,
```

- [ ] **Step 11.3: Update the cursor controller call to use the config**

Find the call (was updated in Task 5.4):

```dart
config: CursorAnimationConfig.preset(_cursorAnimationStyle),
```

Replace with:

```dart
config: _cursorAnimationConfig,
```

- [ ] **Step 11.4: Update `ZoomTransformer.getTransform` call to use per-region override or global**

Find (around line 681):

```dart
rampCurve: _screenAnimationStyle.rampCurve,
```

Replace with:

```dart
rampCurve: (zoom.rampCurveOverride is CubicBezierCurve)
    ? (zoom.rampCurveOverride as CubicBezierCurve).toFlutterCurve()
    : _screenAnimationConfig.rampCurve,
```

(`zoom` is the `ZoomRegion` already in scope at that call site.)

- [ ] **Step 11.5: Update the `TweenAnimationBuilder` to use config**

Find (around line 670–671):

```dart
duration: _screenAnimationStyle.badgeDuration,
curve: _screenAnimationStyle.badgeCurve,
```

Replace with:

```dart
duration: _screenAnimationConfig.badgeDuration,
curve: _screenAnimationConfig.badgeCurve,
```

- [ ] **Step 11.6: Update the `ZoomFocalController.update` smoothing argument**

Find (around line 658):

```dart
smoothing: _cursorAnimationStyle.smoothing,
```

Replace with: derive an effective smoothing from the cursor config's window so the focal still chases the cursor (the focal controller is independent of the FIR cursor smoothing). Map window→smoothing using the same scheme as the current presets:

```dart
smoothing: _focalSmoothingFor(_cursorAnimationConfig),
```

Add a private helper near the bottom of the class:

```dart
double _focalSmoothingFor(CursorAnimationConfig cfg) {
  // Map FIR window size to the legacy lerp factor used by
  // ZoomFocalController. Same perceptual feel as the old presets.
  final ms = cfg.window.inMilliseconds;
  if (ms <= 0)   return 1.00;   // none → snap
  if (ms <= 90)  return 0.40;   // rapid
  if (ms <= 250) return 0.18;   // medium
  return 0.08;                  // smooth or longer custom windows
}
```

- [ ] **Step 11.7: Wire `ZoomContextInspector` callbacks at `inspector_panel.dart`**

Find the `ZoomContextInspector(...)` call and add:

```dart
curveLibrary: widget.curveLibrary,
onCurveOverrideChanged: (curve) {
  final idx = (widget.selection as ZoomSelected).index;
  final region = widget.zoomRegions[idx];
  final next = curve == null
      ? region.copyWith(clearRampCurveOverride: true)
      : region.copyWith(rampCurveOverride: curve);
  widget.onZoomChanged?.call(idx, next);
},
```

- [ ] **Step 11.8: Run full analyzer**

```
dart analyze lib/
```
Expected: clean (or only the pre-existing 11 issues noted earlier).

- [ ] **Step 11.9: Run full test suite**

```
flutter test
```
Expected: PASS — including the cursor controller tests, animation curve tests, library tests, editor widget tests, and the existing 158 tests.

- [ ] **Step 11.10: Commit**

```bash
git add lib/ui/screens/playback_screen.dart \
        lib/ui/widgets/inspector/inspector_panel.dart
git commit -m "feat(curves): wire configs + per-region override into playback render"
```

---

## Task 12: Manual smoke + perceptual parity

This is a manual checklist, not automated tests, because the FIR re-tuning's success criterion is "feels the same as the old IIR".

- [ ] **Step 12.1: Run the app**

```
flutter run -d macos
```

- [ ] **Step 12.2: Load any existing recording. With the Animation tab open, click each preset for both Screen and Cursor; confirm:**

- The Screen preset tiles still snap zooms quickly (Focused) or push smoothly (Smooth).
- Cursor presets' visible smoothing rates match the previous build (compare to a recording made before this branch if possible).

- [ ] **Step 12.3: Click the Custom tile under Screen. Drag a handle in the editor:**

- The recording's zoom transitions update in real time as you drag.
- Save the curve as "test-screen". Confirm a chip with that name appears.
- Clicking another preset tile reverts to that preset; clicking Custom again restores your authored curve.

- [ ] **Step 12.4: Click Custom under Cursor; drag the catch-up window slider from short to long while the recording plays. Cursor smoothing should visibly tighten / loosen.**

- [ ] **Step 12.5: Select a zoom region in the timeline. Toggle on "Animation override" → editor appears, with default ease-in-out-ish curve. Drag a handle. Confirm only this region's ramp shape changes (others still use the global config).**

- [ ] **Step 12.6: Toggle off "Animation override" → ramp returns to the global curve.**

- [ ] **Step 12.7: Quit and re-open the app. Confirm "test-screen" chip is still in the Library row (persisted to disk).**

- [ ] **Step 12.8: Long-press the "test-screen" chip → it disappears (deletion).**

- [ ] **Step 12.9: Note any perceptual mismatch between FIR-driven cursor presets and the old IIR feel. If any preset feels wrong, adjust its `(window, curve)` in the table on `CursorAnimationStyleData.fir` (Task 4) and re-run smoke.**

(No commit for this task.)

---

## Self-Review Notes

**Coverage check vs spec:**

- ✅ AnimationCurve sealed type, JSON roundtrip — Task 1.
- ✅ BuiltInCurves catalogue — Task 2.
- ✅ FileCurveLibrary with atomic write + corrupt JSON tolerance — Task 3.
- ✅ ScreenAnimationConfig + CursorAnimationConfig — Task 4.
- ✅ Cursor FIR rewrite + preset re-tuning — Task 5.
- ✅ ZoomRegion.rampCurveOverride — Task 6.
- ✅ Curve graph painter — Task 7.
- ✅ Inline curve editor — Task 8.
- ✅ Custom tile + editor in animation tab — Task 9.
- ✅ Per-region override section — Task 10.
- ✅ Playback screen wiring + render-time override — Task 11.
- ✅ Manual perceptual parity check — Task 12.

**Type consistency:**

- `CursorMotionController.update` signature defined in Task 5 (`config: CursorAnimationConfig`, `fps: int`) is consistent with the call site in Task 11.
- `ZoomRegion.copyWith` adds `rampCurveOverride` and `clearRampCurveOverride` (Task 6); both are used by Task 11.7.
- `CurveEditor` constructor (Task 8) is invoked identically in Tasks 9 and 10 with `showDurationSlider: false` for the per-region case.
- `CurveLibrary` interface (Task 3) is implemented by `FileCurveLibrary` (Task 3) and consumed by Tasks 8/9/10/11 as a constructor param.

**Out of scope (per spec):**
- Multi-keyframe spline editing.
- Curve sharing/import/export between users.
- Custom badge curve overrides per zoom region.
- Motion-blur curve customization.
