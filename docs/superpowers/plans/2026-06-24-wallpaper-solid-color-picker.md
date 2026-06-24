# Solid → Color Picker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the Solid tab's 16 random procedural solids with a real color picker (SV square + hue slider + hex + curated presets), persist the chosen color per project, and make custom colors favoritable.

**Architecture:** A new `WindowFrame.solidColor` field carries the exact color; `wallpaperDecoration`/`wallpaperRepresentativeColor` gain a `solidColor` param and the preview canvas + export pass it (one render path, no preview≠export). A reusable `ColorPickerField` widget drives the Solid tab via `_gridRegion`. `WallpaperRef` gains a `color:RRGGBB` variant so favorites hold custom colors.

**Tech Stack:** Flutter, `flutter_riverpod`, `flutter_test`, Flutter's built-in `HSVColor`.

## Global Constraints

- **Branch:** `feat/wallpaper-solid-color-picker` (already created off `main` @ a3fc6f8f, which has the merged favorites).
- **This sub-project DOES modify `slipreel_engine`** (the wallpaper model + render) — that's expected here.
- **Do NOT run `dart format`** — the pinned formatter reflows unrelated lines. Match style by hand; verify with `fvm flutter analyze` + `fvm flutter test`.
- **Run with `fvm`** from each package dir (FVM 3.41.5): `cd packages/<pkg> && fvm flutter test <path>` / `fvm flutter analyze <paths>`.
- **`WallpaperRef` stays one class** with an added `WallpaperRef.color(Color)` constructor; color refs carry `category == 'Solid'`, `index == 0`, `color != null` (the `isColor` getter is the discriminator). Keep the existing `.photo` constructor and all merged favorites tests green.
- **Color hex is opaque `RRGGBB`** (6 uppercase hex digits), alpha always `FF`. Mirror the existing `backgroundColor` JSON pattern (`?.toARGB32()` / `Color(json[..] as int)`).
- **Reuse inspector color constants** (`kInspectorPanel`, `kInspectorBorder`, `kInspectorAccent`, `kInspectorMuted`) — no `context.palette` in these files.
- Backward compatible: `solidColor == null` keeps rendering today's procedural `_solid(index)`; the picker only ever writes `solidColor`.

## File Structure

**Modify (engine):**
- `packages/slipreel_engine/lib/models/window_frame.dart` — `solidColor` field.
- `packages/slipreel_engine/lib/rendering/wallpaper.dart` — `solidColor` param on `wallpaperDecoration` + `wallpaperRepresentativeColor`.
- `packages/slipreel_engine/lib/export/frame_compositor.dart` — pass `solidColor`.

**Modify (app):**
- `packages/screen_recorder/lib/state/wallpaper_ref.dart` — `color:` variant.
- `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` — pass `solidColor`.
- `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart` — Solid → picker; color-ref favorites.

**Create (app):**
- `packages/screen_recorder/lib/ui/widgets/inspector/color_picker_field.dart` — reusable picker + hex helpers.

---

### Task 1: `WindowFrame.solidColor`

**Files:**
- Modify: `packages/slipreel_engine/lib/models/window_frame.dart`
- Test: `packages/slipreel_engine/test/models/window_frame_solid_color_test.dart`

**Interfaces:**
- Produces: `WindowFrame` gains `final Color? solidColor;`, a `solidColor` named arg on the constructor and `copyWith`, JSON key `solidColor`, and inclusion in `==`/`hashCode`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/window_frame_solid_color_test.dart
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';

void main() {
  test('copyWith sets solidColor; absent leaves it unchanged', () {
    final base = WindowFrame.rounded();
    final withColor = base.copyWith(solidColor: const Color(0xFF112233));
    expect(withColor.solidColor, const Color(0xFF112233));
    expect(withColor.copyWith(name: 'x').solidColor, const Color(0xFF112233));
  });

  test('toJson/fromJson round-trips solidColor', () {
    final f = WindowFrame.rounded().copyWith(solidColor: const Color(0xFFAABBCC));
    final back = WindowFrame.fromJson(f.toJson());
    expect(back.solidColor, const Color(0xFFAABBCC));
  });

  test('fromJson defaults solidColor to null when absent', () {
    final json = WindowFrame.rounded().toJson()..remove('solidColor');
    expect(WindowFrame.fromJson(json).solidColor, isNull);
  });

  test('solidColor participates in equality', () {
    final a = WindowFrame.rounded().copyWith(solidColor: const Color(0xFF010203));
    final b = WindowFrame.rounded().copyWith(solidColor: const Color(0xFF010203));
    final c = WindowFrame.rounded().copyWith(solidColor: const Color(0xFF040506));
    expect(a, b);
    expect(a == c, isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && fvm flutter test test/models/window_frame_solid_color_test.dart`
Expected: FAIL — `No named parameter with the name 'solidColor'`.

- [ ] **Step 3: Add the field, constructor arg, copyWith, JSON, ==/hashCode**

In `window_frame.dart`:

Add the field next to `borderColor` (after the `final Color? borderColor;` declaration near line 33):
```dart
  /// Exact background color when [wallpaperCategory] == 'Solid'. Null falls
  /// back to the procedural index-based solid (legacy projects).
  final Color? solidColor;
```

Add to the constructor (after `this.borderColor,`):
```dart
    this.solidColor,
```

Add to `copyWith` params (after `Color? borderColor,`):
```dart
    Color? solidColor,
```
and to the `copyWith` body's `WindowFrame(...)` (after `borderColor: borderColor ?? this.borderColor,`):
```dart
      solidColor: solidColor ?? this.solidColor,
```

In `toJson()` (after the `'borderColor': borderColor?.toARGB32(),` line):
```dart
      'solidColor': solidColor?.toARGB32(),
```

In `fromJson` (after the `borderColor: ... : null,` block, before `wallpaperCategory:`):
```dart
      solidColor: json['solidColor'] != null
          ? Color(json['solidColor'] as int)
          : null,
```

In `operator ==` (add a clause, e.g. after `other.borderColor == borderColor &&`):
```dart
        other.solidColor == solidColor &&
```

In `hashCode`'s `Object.hash(...)` add `solidColor,` (after `borderColor,`).

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && fvm flutter test test/models/window_frame_solid_color_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Confirm nothing else broke + commit**

Run: `cd packages/slipreel_engine && fvm flutter analyze lib/models/window_frame.dart && fvm flutter test test/models/`
Expected: `No issues found!` + existing model tests green.

```bash
git add packages/slipreel_engine/lib/models/window_frame.dart \
        packages/slipreel_engine/test/models/window_frame_solid_color_test.dart
git commit -m "feat(wallpaper): add WindowFrame.solidColor"
```

---

### Task 2: `solidColor` in the engine render functions

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/wallpaper.dart`
- Test: `packages/slipreel_engine/test/rendering/wallpaper_test.dart` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `wallpaperDecoration(category, index, {int? thumbCacheWidth, Color? solidColor})` and `wallpaperRepresentativeColor(category, index, {Color? solidColor})`.

- [ ] **Step 1: Write the failing test (append to wallpaper_test.dart's `main`)**

```dart
  group('Solid color override', () {
    test('Solid + solidColor renders that exact color', () {
      final dec = wallpaperDecoration('Solid', 0,
          solidColor: const Color(0xFF123456));
      expect(dec.color, const Color(0xFF123456));
      expect(dec.gradient, isNull);
    });

    test('Solid without solidColor keeps the legacy procedural fill', () {
      final dec = wallpaperDecoration('Solid', 0);
      expect(dec.color, isNotNull);
      expect(dec.color, isNot(const Color(0xFF123456)));
    });

    test('representative color returns the custom solidColor', () {
      expect(
        wallpaperRepresentativeColor('Solid', 0,
            solidColor: const Color(0xFF777777)),
        const Color(0xFF777777),
      );
    });

    test('non-Solid categories ignore solidColor', () {
      final dec = wallpaperDecoration('macOS', 0,
          solidColor: const Color(0xFF123456));
      expect(dec.image, isNotNull); // still a photo
      expect(dec.color, isNull);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/wallpaper_test.dart`
Expected: FAIL — `No named parameter with the name 'solidColor'`.

- [ ] **Step 3: Add the `solidColor` param**

In `wallpaper.dart`, change the `wallpaperDecoration` signature to add `Color? solidColor` and short-circuit Solid:

```dart
BoxDecoration wallpaperDecoration(
  String category,
  int index, {
  int? thumbCacheWidth,
  Color? solidColor,
}) {
  if (category == 'Solid' && solidColor != null) {
    return BoxDecoration(color: solidColor);
  }
  final r = Random('$category.$index'.hashCode);
  if (isPhotoWallpaperCategory(category)) {
    return _photoDecoration(category, index, thumbCacheWidth);
  }
  switch (category) {
    case 'Sunset':
      return _sunsetGradient(r);
    case 'Radial':
      return _radialGradient(r);
    case 'Solid':
      return _solid(r);
    default:
      return _photoDecoration('macOS', index, thumbCacheWidth);
  }
}
```

Change `wallpaperRepresentativeColor`'s signature and add an early return:

```dart
Color wallpaperRepresentativeColor(String category, int index,
    {Color? solidColor}) {
  if (category == 'Solid' && solidColor != null) return solidColor;
  if (isPhotoWallpaperCategory(category)) {
```
(the rest of the body is unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && fvm flutter test test/rendering/wallpaper_test.dart`
Expected: PASS (all groups, incl. the new 4).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/wallpaper.dart \
        packages/slipreel_engine/test/rendering/wallpaper_test.dart
git commit -m "feat(wallpaper): solidColor override in wallpaperDecoration"
```

---

### Task 3: Thread `solidColor` through the render call sites

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` (the `_wallpaperLayer` helper + its single call site)
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart` (the `drawProcedural` closure, ~line 961)

**Interfaces:**
- Consumes: `WindowFrame.solidColor` (Task 1), `wallpaperDecoration(..., solidColor:)` (Task 2).

> No new unit test — this is wiring that makes preview and export read the same `frame.solidColor` (preserving preview==export). The gate is `analyze` clean + the existing compositor/canvas suites unchanged.

- [ ] **Step 1: Pass `solidColor` in the export compositor**

In `frame_compositor.dart`, in `drawProcedural()` change:
```dart
      final decoration = wallpaperDecoration(category, _frame.wallpaperIndex);
```
to:
```dart
      final decoration = wallpaperDecoration(category, _frame.wallpaperIndex,
          solidColor: _frame.solidColor);
```

- [ ] **Step 2: Pass `solidColor` in the preview canvas**

In `playback_canvas.dart`, add a `Color? solidColor` param to `_wallpaperLayer`:
```dart
  Widget _wallpaperLayer({
    required String category,
    required int index,
    required double blur,
    Color? solidColor,
  }) {
    final fill = Container(
        decoration: wallpaperDecoration(category, index, solidColor: solidColor));
```
Then find the single `_wallpaperLayer(` call site (grep it) and add `solidColor: <frame>.solidColor,` to the arguments, where `<frame>` is the `WindowFrame` already in scope there (the same object whose `wallpaperCategory`/`wallpaperIndex` are passed as `category`/`index`).

- [ ] **Step 3: Analyze + run the touched suites**

Run: `cd packages/slipreel_engine && fvm flutter analyze lib/export/frame_compositor.dart && fvm flutter test test/export/`
Expected: `No issues found!` + export suite green.

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/zoom/playback_canvas.dart`
Expected: `No issues found!`

- [ ] **Step 4: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "feat(wallpaper): thread solidColor into preview + export render"
```

---

### Task 4: `WallpaperRef.color` variant

**Files:**
- Modify: `packages/screen_recorder/lib/state/wallpaper_ref.dart`
- Test: `packages/screen_recorder/test/state/wallpaper_ref_test.dart` (extend + fix one existing case)

**Interfaces:**
- Produces: `WallpaperRef.color(Color)`, `bool get isColor`, `Color? get color`; `encode()` → `color:RRGGBB`; `decode` learns the `color:` scheme.

- [ ] **Step 1: Update tests (the `color:` scheme is now VALID, not unknown)**

In `wallpaper_ref_test.dart`, REPLACE the existing test:
```dart
  test('decode returns null for unknown scheme (forward-compat)', () {
    expect(WallpaperRef.decode('color:FF8800'), isNull);
  });
```
with:
```dart
  test('decode returns null for a genuinely unknown scheme', () {
    expect(WallpaperRef.decode('gradient:1'), isNull);
  });

  group('color variant', () {
    test('encode/decode round-trips a color ref', () {
      const ref = WallpaperRef.color(Color(0xFFFF8800));
      expect(ref.encode(), 'color:FF8800');
      expect(WallpaperRef.decode('color:FF8800'), ref);
      expect(ref.isColor, isTrue);
      expect(ref.color, const Color(0xFFFF8800));
    });

    test('decode rejects malformed color tokens', () {
      expect(WallpaperRef.decode('color:FFF'), isNull); // wrong length
      expect(WallpaperRef.decode('color:GGGGGG'), isNull); // not hex
    });

    test('a color ref never equals a photo ref', () {
      expect(const WallpaperRef.color(Color(0xFF000000)) ==
          const WallpaperRef.photo('Solid', 0), isFalse);
    });

    test('photo refs are not color refs', () {
      expect(const WallpaperRef.photo('macOS', 0).isColor, isFalse);
      expect(const WallpaperRef.photo('macOS', 0).color, isNull);
    });
  });
```
Add `import 'package:flutter/painting.dart';` (for `Color`) at the top of the test if not present.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/state/wallpaper_ref_test.dart`
Expected: FAIL — `WallpaperRef.color` undefined / `isColor` undefined.

- [ ] **Step 3: Rewrite `wallpaper_ref.dart` with the color variant**

```dart
import 'package:flutter/painting.dart';

/// A serializable reference to a single wallpaper in the picker.
///
/// Encoded as an extensible string token:
///   - `photo:<category>:<index>` — a bundled or procedural wallpaper.
///   - `color:<RRGGBB>` — a custom solid color (opaque).
///
/// Color refs carry `category == 'Solid'`, `index == 0`, and a non-null
/// [color]; use [isColor] to discriminate.
class WallpaperRef {
  const WallpaperRef.photo(this.category, this.index) : color = null;

  const WallpaperRef.color(Color value)
      : color = value,
        category = 'Solid',
        index = 0;

  final String category;
  final int index;
  final Color? color;

  bool get isColor => color != null;

  /// Encode to a persistence token.
  String encode() => color != null
      ? 'color:${_hex6(color!)}'
      : 'photo:$category:$index';

  /// Decode a token. Returns null for malformed or unknown-scheme tokens,
  /// so an older build silently ignores a token a newer build wrote.
  static WallpaperRef? decode(String token) {
    final sep = token.indexOf(':');
    if (sep < 0) return null;
    final scheme = token.substring(0, sep);
    final rest = token.substring(sep + 1);
    switch (scheme) {
      case 'photo':
        final parts = rest.split(':');
        if (parts.length != 2 || parts[0].isEmpty) return null;
        final index = int.tryParse(parts[1]);
        if (index == null) return null;
        return WallpaperRef.photo(parts[0], index);
      case 'color':
        if (rest.length != 6) return null;
        final v = int.tryParse(rest, radix: 16);
        if (v == null) return null;
        return WallpaperRef.color(Color(0xFF000000 | v));
      default:
        return null;
    }
  }

  static String _hex6(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  @override
  bool operator ==(Object other) =>
      other is WallpaperRef &&
      other.category == category &&
      other.index == index &&
      other.color == color;

  @override
  int get hashCode => Object.hash(category, index, color);

  @override
  String toString() => 'WallpaperRef(${encode()})';
}
```

- [ ] **Step 4: Run test to verify it passes (and the favorites suite stays green)**

Run: `cd packages/screen_recorder && fvm flutter test test/state/`
Expected: PASS — `wallpaper_ref_test.dart` (updated) plus the existing favorites store/controller tests (`color:FFF` still drops as malformed; `photo:` round-trips unchanged).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/wallpaper_ref.dart \
        packages/screen_recorder/test/state/wallpaper_ref_test.dart
git commit -m "feat(wallpaper): add color: variant to WallpaperRef"
```

---

### Task 5: `ColorPickerField` widget + hex helpers

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/inspector/color_picker_field.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/color_picker_field_test.dart`

**Interfaces:**
- Produces: `Color? parseHexColor(String)`, `String formatHexColor(Color)`, `const List<Color> kSolidPresetColors`, and `class ColorPickerField extends StatefulWidget` with `const ColorPickerField({Key?, required Color color, required ValueChanged<Color> onChanged})`. The SV square has `key: const Key('sv-square')`, the hue strip `key: const Key('hue-slider')`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/widgets/inspector/color_picker_field_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/inspector/color_picker_field.dart';

void main() {
  test('parseHexColor parses #RRGGBB and RRGGBB; rejects bad input', () {
    expect(parseHexColor('#FF8800'), const Color(0xFFFF8800));
    expect(parseHexColor('ff8800'), const Color(0xFFFF8800));
    expect(parseHexColor('  #00FF00 '), const Color(0xFF00FF00));
    expect(parseHexColor('FFF'), isNull);
    expect(parseHexColor('GGGGGG'), isNull);
  });

  test('formatHexColor returns uppercase #RRGGBB', () {
    expect(formatHexColor(const Color(0xFF12ab34)), '#12AB34');
  });

  Widget host(Color color, ValueChanged<Color> onChanged) => MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 240, child: ColorPickerField(
            color: color, onChanged: onChanged)),
        ),
      );

  testWidgets('tapping a preset emits that color', (tester) async {
    Color? out;
    await tester.pumpWidget(host(const Color(0xFF000000), (c) => out = c));
    await tester.tap(find.byKey(ValueKey('preset-${kSolidPresetColors.last.toARGB32()}')));
    await tester.pump();
    expect(out, kSolidPresetColors.last);
  });

  testWidgets('submitting a hex value emits the parsed color', (tester) async {
    Color? out;
    await tester.pumpWidget(host(const Color(0xFF000000), (c) => out = c));
    await tester.enterText(find.byType(TextField), '#3366CC');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(out, const Color(0xFF3366CC));
  });

  testWidgets('dragging the SV square emits a new color', (tester) async {
    Color? out;
    await tester.pumpWidget(host(const Color(0xFFFF0000), (c) => out = c));
    await tester.drag(find.byKey(const Key('sv-square')), const Offset(-30, 10));
    await tester.pump();
    expect(out, isNotNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/color_picker_field_test.dart`
Expected: FAIL — `color_picker_field.dart` / `ColorPickerField` not found.

- [ ] **Step 3: Implement the widget**

```dart
// packages/screen_recorder/lib/ui/widgets/inspector/color_picker_field.dart
import 'package:flutter/material.dart';

import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Curated preset solids for the picker (neutrals + saturated tones).
const List<Color> kSolidPresetColors = [
  Color(0xFF1A1A26), Color(0xFF2E2E3A), Color(0xFF5B6470), Color(0xFF9AA3B2),
  Color(0xFFE7E9EE), Color(0xFFFFFFFF), Color(0xFF6C63FF), Color(0xFF4FC3F7),
  Color(0xFF34C759), Color(0xFFFFD60A), Color(0xFFFF9F0A), Color(0xFFFF375F),
];

/// Parse `#RRGGBB` / `RRGGBB` to an opaque [Color], or null if invalid.
Color? parseHexColor(String input) {
  var s = input.trim();
  if (s.startsWith('#')) s = s.substring(1);
  if (s.length != 6) return null;
  final v = int.tryParse(s, radix: 16);
  if (v == null) return null;
  return Color(0xFF000000 | v);
}

/// Format an opaque [Color] as an uppercase `#RRGGBB` string.
String formatHexColor(Color c) =>
    '#${c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase()}';

/// Reusable HSV color picker: saturation/brightness square + hue slider +
/// hex field + curated preset swatches. Emits [onChanged] continuously
/// during drag.
class ColorPickerField extends StatefulWidget {
  const ColorPickerField({
    super.key,
    required this.color,
    required this.onChanged,
  });

  final Color color;
  final ValueChanged<Color> onChanged;

  @override
  State<ColorPickerField> createState() => _ColorPickerFieldState();
}

class _ColorPickerFieldState extends State<ColorPickerField> {
  late HSVColor _hsv;
  late TextEditingController _hex;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.color);
    _hex = TextEditingController(text: formatHexColor(widget.color));
  }

  @override
  void didUpdateWidget(ColorPickerField old) {
    super.didUpdateWidget(old);
    if (widget.color.toARGB32() != _hsv.toColor().toARGB32()) {
      _hsv = HSVColor.fromColor(widget.color);
      _hex.text = formatHexColor(widget.color);
    }
  }

  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  void _emit(HSVColor hsv) {
    setState(() => _hsv = hsv);
    final c = hsv.toColor();
    _hex.text = formatHexColor(c);
    widget.onChanged(c);
  }

  void _applyHex(String text) {
    final c = parseHexColor(text);
    if (c != null) _emit(HSVColor.fromColor(c));
  }

  Widget _thumb() => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white, width: 2),
          boxShadow: const [BoxShadow(color: Colors.black45, blurRadius: 2)],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final pure = HSVColor.fromAHSV(1, _hsv.hue, 1, 1).toColor();
    final current = _hsv.toColor();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        AspectRatio(
          aspectRatio: 1.7,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              final h = c.maxHeight;
              void handle(Offset p) => _emit(HSVColor.fromAHSV(
                    1,
                    _hsv.hue,
                    (p.dx / w).clamp(0.0, 1.0),
                    (1 - p.dy / h).clamp(0.0, 1.0),
                  ));
              return GestureDetector(
                key: const Key('sv-square'),
                onPanDown: (d) => handle(d.localPosition),
                onPanUpdate: (d) => handle(d.localPosition),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Stack(children: [
                    Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.centerLeft,
                            end: Alignment.centerRight,
                            colors: [Colors.white, pure],
                          ),
                        ),
                      ),
                    ),
                    const Positioned.fill(
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Colors.transparent, Colors.black],
                          ),
                        ),
                      ),
                    ),
                    Positioned(
                      left: _hsv.saturation * w - 7,
                      top: (1 - _hsv.value) * h - 7,
                      child: _thumb(),
                    ),
                  ]),
                ),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 14,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth;
              void handle(Offset p) => _emit(HSVColor.fromAHSV(
                    1,
                    (p.dx / w).clamp(0.0, 1.0) * 360,
                    _hsv.saturation,
                    _hsv.value,
                  ));
              return GestureDetector(
                key: const Key('hue-slider'),
                onPanDown: (d) => handle(d.localPosition),
                onPanUpdate: (d) => handle(d.localPosition),
                child: Stack(clipBehavior: Clip.none, children: [
                  Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(7),
                        gradient: const LinearGradient(colors: [
                          Color(0xFFFF0000), Color(0xFFFFFF00),
                          Color(0xFF00FF00), Color(0xFF00FFFF),
                          Color(0xFF0000FF), Color(0xFFFF00FF),
                          Color(0xFFFF0000),
                        ]),
                      ),
                    ),
                  ),
                  Positioned(left: (_hsv.hue / 360) * w - 7, top: 0, child: _thumb()),
                ]),
              );
            },
          ),
        ),
        const SizedBox(height: 12),
        Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: current,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kInspectorBorder),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: _hex,
              onSubmitted: _applyHex,
              onEditingComplete: () => _applyHex(_hex.text),
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                isDense: true,
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                filled: true,
                fillColor: kInspectorPanel,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kInspectorBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: kInspectorAccent),
                ),
              ),
            ),
          ),
        ]),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final c in kSolidPresetColors)
            GestureDetector(
              key: ValueKey('preset-${c.toARGB32()}'),
              onTap: () => _emit(HSVColor.fromColor(c)),
              child: Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: c,
                  borderRadius: BorderRadius.circular(7),
                  border: Border.all(
                    color: current.toARGB32() == c.toARGB32()
                        ? kInspectorAccent
                        : kInspectorBorder,
                    width: current.toARGB32() == c.toARGB32() ? 2 : 1,
                  ),
                ),
              ),
            ),
        ]),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/color_picker_field_test.dart`
Expected: PASS (2 unit + 3 widget tests).

- [ ] **Step 5: Analyze + commit**

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/color_picker_field.dart`
Expected: `No issues found!`

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/color_picker_field.dart \
        packages/screen_recorder/test/ui/widgets/inspector/color_picker_field_test.dart
git commit -m "feat(wallpaper): reusable ColorPickerField widget"
```

---

### Task 6: Solid tab uses the color picker

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart` (append)

**Interfaces:**
- Consumes: `ColorPickerField` (Task 5), `WindowFrame.solidColor` (Task 1), `wallpaperRepresentativeColor(..., solidColor:)` (Task 2).
- Produces: a `_updateSolidColor(Color)` method; `_gridRegion` returns the picker for `'Solid'`.

- [ ] **Step 1: Write the failing test (append to the existing test file's `main`)**

```dart
  testWidgets('Solid tab shows the color picker and writes solidColor',
      (tester) async {
    final editor = EditorProjectController();
    SharedPreferences.setMockInitialValues({});
    final store = await WallpaperFavoritesStore.resolveDefault();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => editor),
        wallpaperFavoritesProvider.overrideWith(
          (ref) => WallpaperFavoritesController(store: store, initial: const [])),
      ],
      child: const MaterialApp(home: Scaffold(body: BackgroundTab())),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Solid'));
    await tester.pumpAndSettle();
    expect(find.byType(ColorPickerField), findsOneWidget);

    await tester.enterText(find.byType(TextField), '#224466');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    expect(editor.current.windowFrame.wallpaperCategory, 'Solid');
    expect(editor.current.windowFrame.solidColor, const Color(0xFF224466));
  });
```
Add imports to the test file if missing: `import 'package:screen_recorder/ui/widgets/inspector/color_picker_field.dart';` and `import 'dart:ui';` (for `Color`, usually already transitively available via material).

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: FAIL — Solid still renders the procedural tile grid; no `ColorPickerField`.

- [ ] **Step 3: Add the import + `_updateSolidColor` + the Solid branch**

In `background_tab.dart`, add the import (after the inspector_widgets import):
```dart
import 'package:screen_recorder/ui/widgets/inspector/color_picker_field.dart';
```

Add a method next to `_updateWallpaper`:
```dart
  void _updateSolidColor(Color color) => _mutateFrame(
        (f) => f.copyWith(
          wallpaperCategory: 'Solid',
          solidColor: color,
          name: 'Custom',
        ),
      );
```

In `_gridRegion`, add a `'Solid'` branch BEFORE the `'Favorite'`/else logic so the picker shows instead of tiles:
```dart
    final Widget content;
    if (category == 'Solid') {
      final seed = frame.solidColor ??
          (frame.wallpaperCategory != null
              ? wallpaperRepresentativeColor(
                  frame.wallpaperCategory!, frame.wallpaperIndex)
              : const Color(0xFF5B6470));
      content = ColorPickerField(color: seed, onChanged: _updateSolidColor);
    } else if (category == 'Favorite') {
      content = favorites.isEmpty
          ? _favoritesEmptyState()
          : _favoritesGrid(frame, favorites);
    } else {
      final selectedIndex =
          frame.wallpaperCategory == category ? frame.wallpaperIndex : -1;
      content = _wallpaperGrid(category, selectedIndex, favorites);
    }
```
(the `AnimatedSize` wrapper that follows stays unchanged.)

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: PASS (existing favorites tests + the new Solid test).

- [ ] **Step 5: Analyze + commit**

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/tabs/background_tab.dart`
Expected: `No issues found!`

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart \
        packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart
git commit -m "feat(wallpaper): Solid tab color picker wired to solidColor"
```

---

### Task 7: Favorite custom colors

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`
- Test: `packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart` (append)

**Interfaces:**
- Consumes: `WallpaperRef.color` / `isColor` (Task 4), `_updateSolidColor` (Task 6).

- [ ] **Step 1: Write the failing tests (append)**

```dart
  testWidgets('Favorite tab renders a color favorite and applies it', (tester) async {
    final editor = EditorProjectController();
    SharedPreferences.setMockInitialValues({});
    final store = await WallpaperFavoritesStore.resolveDefault();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => editor),
        wallpaperFavoritesProvider.overrideWith(
          (ref) => WallpaperFavoritesController(
            store: store,
            initial: const [WallpaperRef.color(Color(0xFF224466))])),
      ],
      child: const MaterialApp(home: Scaffold(body: BackgroundTab())),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Favorite'));
    await tester.pumpAndSettle();
    final tile = find.byKey(const ValueKey('color:224466'));
    expect(tile, findsOneWidget);

    await tester.tap(tile);
    await tester.pumpAndSettle();
    expect(editor.current.windowFrame.wallpaperCategory, 'Solid');
    expect(editor.current.windowFrame.solidColor, const Color(0xFF224466));
  });

  testWidgets('the Solid picker can favorite the current color', (tester) async {
    final editor = EditorProjectController();
    SharedPreferences.setMockInitialValues({});
    final store = await WallpaperFavoritesStore.resolveDefault();
    final favs = WallpaperFavoritesController(store: store, initial: const []);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => editor),
        wallpaperFavoritesProvider.overrideWith((ref) => favs),
      ],
      child: const MaterialApp(home: Scaffold(body: BackgroundTab())),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Solid'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '#224466');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('favorite-current-color')));
    await tester.pump();
    expect(favs.state, contains(const WallpaperRef.color(Color(0xFF224466))));
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: FAIL — no `color:224466` tile (favorites grid assumes photo refs); no `favorite-current-color` button.

- [ ] **Step 3: Handle color refs in `_favoritesGrid` (render + ring + apply)**

Replace `_favoritesGrid` with a version that branches on `wref.isColor`:
```dart
  Widget _favoritesGrid(WindowFrame frame, List<WallpaperRef> favorites) {
    final notifier = ref.read(wallpaperFavoritesProvider.notifier);
    final WallpaperRef? current;
    if (frame.wallpaperCategory == 'Solid' && frame.solidColor != null) {
      current = WallpaperRef.color(frame.solidColor!);
    } else if (frame.wallpaperCategory != null) {
      current = WallpaperRef.photo(frame.wallpaperCategory!, frame.wallpaperIndex);
    } else {
      current = null;
    }
    return GridView.count(
      crossAxisCount: 7,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: EdgeInsets.zero,
      mainAxisSpacing: 8,
      crossAxisSpacing: 8,
      childAspectRatio: 1,
      children: [
        for (final wref in favorites)
          _WallpaperThumb(
            key: ValueKey(wref.encode()),
            decoration: wref.isColor
                ? BoxDecoration(color: wref.color)
                : wallpaperDecoration(wref.category, wref.index,
                    thumbCacheWidth: _kWallpaperThumbCacheWidth),
            isSelected: wref == current,
            isFavorite: true,
            onTap: () => wref.isColor
                ? _updateSolidColor(wref.color!)
                : _updateWallpaper(category: wref.category, index: wref.index),
            onToggleFavorite: () => notifier.toggle(wref),
          ),
      ],
    );
  }
```

- [ ] **Step 4: Add a "favorite the current color" star to the Solid picker region**

In `_gridRegion`'s `'Solid'` branch, wrap the picker with a star toggle that favorites the current `solidColor`. Replace the `'Solid'` branch body from Task 6 with:
```dart
    if (category == 'Solid') {
      final seed = frame.solidColor ??
          (frame.wallpaperCategory != null
              ? wallpaperRepresentativeColor(
                  frame.wallpaperCategory!, frame.wallpaperIndex)
              : const Color(0xFF5B6470));
      final notifier = ref.read(wallpaperFavoritesProvider.notifier);
      final isFav = frame.solidColor != null &&
          favorites.contains(WallpaperRef.color(frame.solidColor!));
      content = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ColorPickerField(color: seed, onChanged: _updateSolidColor),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              key: const Key('favorite-current-color'),
              onPressed: () => notifier.toggle(
                  WallpaperRef.color(frame.solidColor ?? seed)),
              icon: Icon(isFav ? Icons.star : Icons.star_border,
                  size: 16, color: Colors.white),
              label: Text(isFav ? 'Favorited' : 'Add to Favorites',
                  style: const TextStyle(color: Colors.white, fontSize: 13)),
            ),
          ),
        ],
      );
    } else if (category == 'Favorite') {
```
(the rest of `_gridRegion` — the `'Favorite'`/else branches and the `AnimatedSize` — is unchanged.)

- [ ] **Step 5: Run tests to verify they pass**

Run: `cd packages/screen_recorder && fvm flutter test test/ui/widgets/inspector/background_tab_favorites_test.dart`
Expected: PASS (all favorites + Solid + the 2 new color-favorite tests).

- [ ] **Step 6: Analyze + full regression gate**

Run: `cd packages/screen_recorder && fvm flutter analyze lib/ui/widgets/inspector/tabs/background_tab.dart`
Expected: `No issues found!`

Run: `cd packages/screen_recorder && fvm flutter test test/state/ test/ui/widgets/inspector/` and `cd packages/slipreel_engine && fvm flutter test test/models/ test/rendering/ test/export/`
Expected: all green.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart \
        packages/screen_recorder/test/ui/widgets/inspector/background_tab_favorites_test.dart
git commit -m "feat(wallpaper): favorite custom solid colors"
```

---

## Manual verification (after all tasks)

Build + launch the macOS app (build via `xcodebuild` x86_64 destination, then `open` the bundle — `flutter run -d macos` fails the arm64 destination in this setup). Open a recording → editor → inspector → Background tab → **Solid**: drag the square/hue, type a hex, tap presets — the canvas updates live. Star the current color, switch to **Favorite** — the color tile shows; click it to re-apply. Confirm switching between Solid and a photo tab still animates (AnimatedSize) and old projects with index-based solids still render.

## Follow-up (separate spec)

3. **Real photo sets for Sunset/Radial** — Unsplash-licensed assets like macOS/Spring; decide what "Radial" becomes; reuse the picker's `thumbCacheWidth` path.
