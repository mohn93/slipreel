# Device Frames Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Render a realistic Apple device bezel around iPhone/iPad recordings in both the editor preview and the export, controlled by a Screen-Studio-style inspector.

**Architecture:** A data-driven `DeviceFrameCatalog` (parsed from a generated `manifest.json`) feeds a pure layout/matcher in `slipreel_engine`. Both compositors (`PlaybackCanvas` preview, `FrameCompositor` export) draw the source video into the bezel's transparent screen cutout, then the bezel PNG on top, inside the existing zoom transform. The bezel art is extracted from Apple Design Resources by an offline Python script.

**Tech Stack:** Dart / Flutter (`flutter_test`), Riverpod (`StateNotifier`), `dart:ui` canvas compositing, Python 3 + Pillow (offline asset extraction), macOS `hdiutil`.

## Global Constraints

- Spec: [docs/superpowers/specs/2026-06-21-device-frames-design.md](../specs/2026-06-21-device-frames-design.md).
- **Device-frame settings live on `WindowFrame`** (package `slipreel_engine`), persisted in the per-project `.editor.json` — never a new top-level state field.
- **Preview must equal export:** the same `DeviceFrameCatalog` + layout math (`resolveDeviceFrameLayout`) feed both `PlaybackCanvas` and `FrameCompositor`.
- **`deviceFrameId == null` means the frame is OFF.** "Use device mockup" toggling off clears it (via `copyWith(clearDeviceFrame: true)`).
- **Inspector controls are gated to `isDevice` recordings** for v1.
- **Auto-enable**: on project open, if `isDeviceCapture` and `deviceFrameId == null` and a Perfect match exists, select it.
- **Manifest asset paths are full bundle paths** (`assets/device_frames/<id>/<color>-<orientation>.png`), matching the wallpaper convention.
- **License gate:** the real Apple PNGs are extracted by Task 11 and are **release-gated on Apple sign-off** (see spec §9). Tasks 1–10 use synthetic fixtures only and must not depend on the real assets existing.
- Run package tests from the package dir, e.g. `cd packages/slipreel_engine && flutter test test/...`.
- Follow existing patterns: immutable models with `copyWith`/`toJson`/`fromJson`/`==`/`hashCode`; inspector controls route through `_mutateFrame`.

## File Structure

**Create (engine — `packages/slipreel_engine/`):**
- `lib/models/device_frame.dart` — `DeviceFrameCatalog`, `DeviceFrameEntry`, `DeviceFrameColorVariant`, `DeviceFrameOrientationAsset`, `DeviceScreenRect`; manifest parse + asset loader.
- `lib/rendering/device_frame_layout.dart` — `DeviceFrameLayout` + `resolveDeviceFrameLayout(...)` (pure geometry).
- `lib/rendering/device_frame_matcher.dart` — Perfect/Flexible matching + `autoSelectDeviceFrame(...)` + `windowFrameWithAutoDeviceFrame(...)`.

**Create (UI — `packages/screen_recorder/`):**
- `lib/state/device_frame_catalog_provider.dart` — `FutureProvider<DeviceFrameCatalog>`.
- `lib/ui/widgets/zoom/device_frame_composition.dart` — pure widget that positions video + bezel per a `DeviceFrameLayout`.

**Create (tooling):**
- `tool/device_frames/extract.py` — download/mount/extract → assets + manifest.
- `tool/device_frames/test_extract.py` — unit test for the screen-rect extractor.
- `tool/device_frames/README.md` — usage + license note.

**Modify (engine):**
- `lib/models/window_frame.dart` — add `deviceFrameId` / `deviceFrameColor` / `deviceFrameAdjustSize`.
- `lib/export/frame_compositor.dart` — device-frame compositing branch.

**Modify (UI):**
- `lib/ui/widgets/zoom/playback_canvas.dart` — device-frame composition branch.
- `lib/ui/widgets/inspector/inspector_panel.dart` — pass `isDevice` + `videoSize` to `BackgroundTab`.
- `lib/ui/widgets/inspector/tabs/background_tab.dart` — device-frame section.
- `lib/ui/screens/playback_screen.dart` — load catalog, auto-enable, thread catalog to canvas + compositor.
- `pubspec.yaml` — declare `assets/device_frames/`.

---

### Task 1: Device frame catalog model + manifest parsing

**Files:**
- Create: `packages/slipreel_engine/lib/models/device_frame.dart`
- Test: `packages/slipreel_engine/test/models/device_frame_test.dart`

**Interfaces:**
- Produces:
  - `class DeviceScreenRect { final double l, t, r, b; const DeviceScreenRect({...}); }`
  - `class DeviceFrameOrientationAsset { final String asset; final int bezelWidth, bezelHeight; final DeviceScreenRect screenRect; }`
  - `class DeviceFrameColorVariant { final String id, name; final Color swatch; final DeviceFrameOrientationAsset portrait, landscape; }`
  - `class DeviceFrameEntry { final String id, family, kind; final int screenWidth, screenHeight; final List<DeviceFrameColorVariant> colors; DeviceFrameColorVariant? colorById(String id); }`
  - `class DeviceFrameCatalog { final List<DeviceFrameEntry> entries; const DeviceFrameCatalog(this.entries); factory DeviceFrameCatalog.parse(String jsonStr); DeviceFrameEntry? entryById(String id); }`

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/device_frame_test.dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';

const _manifest = '''
{ "entries": [
  { "id": "iphone-16-pro", "family": "iPhone 16 Pro", "kind": "phone",
    "screen": { "w": 1206, "h": 2622 },
    "colors": [
      { "id": "black-titanium", "name": "Black Titanium", "swatch": "#3a3a3c",
        "portrait":  { "asset": "assets/device_frames/iphone-16-pro/black-titanium-portrait.png",
                       "bezel": { "w": 1350, "h": 2760 },
                       "screenRect": { "l": 0.0533, "t": 0.0250, "r": 0.9467, "b": 0.9750 } },
        "landscape": { "asset": "assets/device_frames/iphone-16-pro/black-titanium-landscape.png",
                       "bezel": { "w": 2760, "h": 1350 },
                       "screenRect": { "l": 0.0250, "t": 0.0533, "r": 0.9750, "b": 0.9467 } } }
    ] }
] }
''';

void main() {
  test('parses a manifest into a catalog', () {
    final catalog = DeviceFrameCatalog.parse(_manifest);
    expect(catalog.entries, hasLength(1));
    final entry = catalog.entryById('iphone-16-pro')!;
    expect(entry.family, 'iPhone 16 Pro');
    expect(entry.kind, 'phone');
    expect(entry.screenWidth, 1206);
    expect(entry.screenHeight, 2622);

    final color = entry.colorById('black-titanium')!;
    expect(color.name, 'Black Titanium');
    expect(color.swatch, const Color(0xFF3A3A3C));
    expect(color.portrait.asset, endsWith('black-titanium-portrait.png'));
    expect(color.portrait.bezelWidth, 1350);
    expect(color.portrait.bezelHeight, 2760);
    expect(color.portrait.screenRect.l, closeTo(0.0533, 1e-9));
    expect(color.landscape.bezelWidth, 2760);
  });

  test('unknown ids return null', () {
    final catalog = DeviceFrameCatalog.parse(_manifest);
    expect(catalog.entryById('nope'), isNull);
    expect(catalog.entryById('iphone-16-pro')!.colorById('gold'), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/device_frame_test.dart`
Expected: FAIL — `Error: Couldn't resolve the package 'slipreel_engine/models/device_frame.dart'` / `DeviceFrameCatalog` undefined.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/slipreel_engine/lib/models/device_frame.dart
import 'dart:convert';
import 'package:flutter/painting.dart' show Color;

/// Normalized screen-cutout rect within a bezel image (0..1 of bezel
/// width/height). The video is drawn into this sub-rect.
class DeviceScreenRect {
  final double l, t, r, b;
  const DeviceScreenRect({required this.l, required this.t, required this.r, required this.b});

  double get width => r - l;
  double get height => b - t;

  factory DeviceScreenRect.fromJson(Map<String, dynamic> j) => DeviceScreenRect(
        l: (j['l'] as num).toDouble(),
        t: (j['t'] as num).toDouble(),
        r: (j['r'] as num).toDouble(),
        b: (j['b'] as num).toDouble(),
      );
}

/// One orientation (portrait or landscape) of a colored device bezel.
class DeviceFrameOrientationAsset {
  final String asset;
  final int bezelWidth, bezelHeight;
  final DeviceScreenRect screenRect;
  const DeviceFrameOrientationAsset({
    required this.asset,
    required this.bezelWidth,
    required this.bezelHeight,
    required this.screenRect,
  });

  factory DeviceFrameOrientationAsset.fromJson(Map<String, dynamic> j) {
    final bezel = j['bezel'] as Map<String, dynamic>;
    return DeviceFrameOrientationAsset(
      asset: j['asset'] as String,
      bezelWidth: (bezel['w'] as num).toInt(),
      bezelHeight: (bezel['h'] as num).toInt(),
      screenRect: DeviceScreenRect.fromJson(j['screenRect'] as Map<String, dynamic>),
    );
  }
}

/// A color variant of a device (e.g. "Black Titanium").
class DeviceFrameColorVariant {
  final String id, name;
  final Color swatch;
  final DeviceFrameOrientationAsset portrait, landscape;
  const DeviceFrameColorVariant({
    required this.id,
    required this.name,
    required this.swatch,
    required this.portrait,
    required this.landscape,
  });

  factory DeviceFrameColorVariant.fromJson(Map<String, dynamic> j) => DeviceFrameColorVariant(
        id: j['id'] as String,
        name: j['name'] as String,
        swatch: _parseHexColor(j['swatch'] as String),
        portrait: DeviceFrameOrientationAsset.fromJson(j['portrait'] as Map<String, dynamic>),
        landscape: DeviceFrameOrientationAsset.fromJson(j['landscape'] as Map<String, dynamic>),
      );
}

/// A device model with its native (portrait) screen resolution and
/// available color variants.
class DeviceFrameEntry {
  final String id, family, kind; // kind: 'phone' | 'tablet'
  final int screenWidth, screenHeight; // native portrait px
  final List<DeviceFrameColorVariant> colors;
  const DeviceFrameEntry({
    required this.id,
    required this.family,
    required this.kind,
    required this.screenWidth,
    required this.screenHeight,
    required this.colors,
  });

  DeviceFrameColorVariant? colorById(String id) {
    for (final c in colors) {
      if (c.id == id) return c;
    }
    return null;
  }

  factory DeviceFrameEntry.fromJson(Map<String, dynamic> j) {
    final screen = j['screen'] as Map<String, dynamic>;
    return DeviceFrameEntry(
      id: j['id'] as String,
      family: j['family'] as String,
      kind: j['kind'] as String,
      screenWidth: (screen['w'] as num).toInt(),
      screenHeight: (screen['h'] as num).toInt(),
      colors: (j['colors'] as List)
          .map((e) => DeviceFrameColorVariant.fromJson(e as Map<String, dynamic>))
          .toList(growable: false),
    );
  }
}

/// In-memory device-frame catalog parsed from `manifest.json`.
class DeviceFrameCatalog {
  final List<DeviceFrameEntry> entries;
  const DeviceFrameCatalog(this.entries);

  factory DeviceFrameCatalog.parse(String jsonStr) {
    final root = jsonDecode(jsonStr) as Map<String, dynamic>;
    final entries = (root['entries'] as List)
        .map((e) => DeviceFrameEntry.fromJson(e as Map<String, dynamic>))
        .toList(growable: false);
    return DeviceFrameCatalog(entries);
  }

  DeviceFrameEntry? entryById(String id) {
    for (final e in entries) {
      if (e.id == id) return e;
    }
    return null;
  }
}

Color _parseHexColor(String hex) {
  var h = hex.replaceFirst('#', '').trim();
  if (h.length == 6) h = 'FF$h';
  return Color(int.parse(h, radix: 16));
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/device_frame_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/device_frame.dart packages/slipreel_engine/test/models/device_frame_test.dart
git commit -m "feat(device-frames): catalog model + manifest parsing"
```

---

### Task 2: Catalog asset loader + Riverpod provider

**Files:**
- Modify: `packages/slipreel_engine/lib/models/device_frame.dart` (add loader)
- Create: `packages/screen_recorder/lib/state/device_frame_catalog_provider.dart`
- Test: `packages/slipreel_engine/test/models/device_frame_loader_test.dart`

**Interfaces:**
- Consumes: `DeviceFrameCatalog.parse` (Task 1).
- Produces:
  - `const String kDeviceFrameManifestAsset = 'assets/device_frames/manifest.json';`
  - `Future<DeviceFrameCatalog> loadDeviceFrameCatalog()` — caches a singleton; reads the manifest asset via `rootBundle`; returns an empty catalog if the asset is missing (so the app runs before Task 11 populates art).
  - `@visibleForTesting void debugSetDeviceFrameCatalog(DeviceFrameCatalog? c)` — sets/clears the cache for tests + preview.
  - `final deviceFrameCatalogProvider = FutureProvider<DeviceFrameCatalog>(...)`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/device_frame_loader_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';

void main() {
  test('debug-set catalog is returned by the cached loader', () async {
    debugSetDeviceFrameCatalog(const DeviceFrameCatalog([
      DeviceFrameEntry(
        id: 'x', family: 'X', kind: 'phone',
        screenWidth: 100, screenHeight: 200, colors: [],
      ),
    ]));
    final catalog = await loadDeviceFrameCatalog();
    expect(catalog.entryById('x'), isNotNull);
    debugSetDeviceFrameCatalog(null);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/device_frame_loader_test.dart`
Expected: FAIL — `debugSetDeviceFrameCatalog` / `loadDeviceFrameCatalog` undefined.

- [ ] **Step 3: Write minimal implementation**

Append to `packages/slipreel_engine/lib/models/device_frame.dart`:

```dart
// --- asset loading (appended) ---------------------------------------------
// (add to the imports at the top of the file:)
//   import 'package:flutter/foundation.dart' show visibleForTesting;
//   import 'package:flutter/services.dart' show rootBundle;

const String kDeviceFrameManifestAsset = 'assets/device_frames/manifest.json';

DeviceFrameCatalog? _cachedCatalog;

@visibleForTesting
void debugSetDeviceFrameCatalog(DeviceFrameCatalog? c) => _cachedCatalog = c;

/// Loads + caches the device-frame catalog from the bundled manifest.
/// Returns an empty catalog when the manifest asset is absent (the app
/// ships functional before the real Apple art is populated).
Future<DeviceFrameCatalog> loadDeviceFrameCatalog() async {
  final cached = _cachedCatalog;
  if (cached != null) return cached;
  try {
    final jsonStr = await rootBundle.loadString(kDeviceFrameManifestAsset);
    return _cachedCatalog = DeviceFrameCatalog.parse(jsonStr);
  } catch (_) {
    return _cachedCatalog = const DeviceFrameCatalog([]);
  }
}
```

Create `packages/screen_recorder/lib/state/device_frame_catalog_provider.dart`:

```dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/models/device_frame.dart';

/// Async-loaded device-frame catalog (bundled manifest). Inspector
/// widgets watch this; it resolves once and stays cached for the session.
final deviceFrameCatalogProvider = FutureProvider<DeviceFrameCatalog>(
  (ref) => loadDeviceFrameCatalog(),
);
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/device_frame_loader_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/device_frame.dart \
        packages/slipreel_engine/test/models/device_frame_loader_test.dart \
        packages/screen_recorder/lib/state/device_frame_catalog_provider.dart
git commit -m "feat(device-frames): catalog asset loader + provider"
```

---

### Task 3: Device-frame layout math

**Files:**
- Create: `packages/slipreel_engine/lib/rendering/device_frame_layout.dart`
- Test: `packages/slipreel_engine/test/rendering/device_frame_layout_test.dart`

**Interfaces:**
- Consumes: `DeviceFrameOrientationAsset`, `DeviceScreenRect` (Task 1); `OutputCanvasResolver`, `OutputAspect`.
- Produces:
  - `class DeviceFrameLayout { final Size canvasSize; final Rect bezelRect; final Rect screenRect; final Rect videoRect; }`
  - `DeviceFrameLayout resolveDeviceFrameLayout({ required DeviceFrameOrientationAsset asset, required Size recordingSize, required EdgeInsets padding, required OutputAspect aspect, required bool adjustSize })`

Geometry: the bezel is the content fit into the canvas (via `OutputCanvasResolver`). `adjustSize == true` stretches the bezel height so the screen cutout matches the recording's aspect (video fills the cutout exactly). `adjustSize == false` keeps the bezel's true proportions and letterbox-fits the video inside the cutout.

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/rendering/device_frame_layout_test.dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';

// iPhone 16 Pro portrait: bezel 1350x2760, screen 1206x2622 inset.
const _asset = DeviceFrameOrientationAsset(
  asset: 'x.png',
  bezelWidth: 1350,
  bezelHeight: 2760,
  screenRect: DeviceScreenRect(l: 0.0533, t: 0.0250, r: 0.9467, b: 0.9750),
);

void main() {
  test('perfect match: no padding -> canvas == bezel, video fills screen rect', () {
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1206, 2622),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: true,
    );
    expect(layout.canvasSize.width, closeTo(1350, 1e-6));
    expect(layout.canvasSize.height, closeTo(2760, 1e-6));
    expect(layout.bezelRect, const Rect.fromLTWH(0, 0, 1350, 2760));
    // screen rect = normalized * bezel
    expect(layout.screenRect.left, closeTo(0.0533 * 1350, 1e-3));
    expect(layout.screenRect.width, closeTo((0.9467 - 0.0533) * 1350, 1e-3));
    // adjustSize: video fills the screen rect exactly
    expect(layout.videoRect, layout.screenRect);
  });

  test('padding grows the canvas; bezel is centered inside', () {
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1206, 2622),
      padding: const EdgeInsets.all(50),
      aspect: OutputAspect.auto,
      adjustSize: true,
    );
    expect(layout.canvasSize.width, closeTo(1450, 1e-6)); // 1350 + 100
    expect(layout.bezelRect.left, closeTo(50, 1e-6));
    expect(layout.bezelRect.top, closeTo(50, 1e-6));
  });

  test('adjustSize=false letterboxes a wider recording inside the screen', () {
    // A 1:1 recording inside a portrait screen -> contained, centered.
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1000, 1000),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: false,
    );
    // bezel keeps native proportions
    expect(layout.canvasSize.height / layout.canvasSize.width, closeTo(2760 / 1350, 1e-6));
    // video is square, fit within the (taller) screen rect -> width-limited
    expect(layout.videoRect.width, closeTo(layout.screenRect.width, 1e-3));
    expect(layout.videoRect.height, closeTo(layout.screenRect.width, 1e-3));
    // centered vertically within the screen rect
    final screenCenterY = layout.screenRect.top + layout.screenRect.height / 2;
    final videoCenterY = layout.videoRect.top + layout.videoRect.height / 2;
    expect(videoCenterY, closeTo(screenCenterY, 1e-3));
  });

  test('adjustSize=true stretches bezel so the screen matches recording aspect', () {
    // Square recording -> screen sub-rect should become square.
    final layout = resolveDeviceFrameLayout(
      asset: _asset,
      recordingSize: const Size(1000, 1000),
      padding: EdgeInsets.zero,
      aspect: OutputAspect.auto,
      adjustSize: true,
    );
    expect(layout.screenRect.width, closeTo(layout.screenRect.height, 1e-2));
    expect(layout.videoRect, layout.screenRect);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_layout_test.dart`
Expected: FAIL — `resolveDeviceFrameLayout` undefined.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/slipreel_engine/lib/rendering/device_frame_layout.dart
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/output_aspect.dart';
import 'package:slipreel_engine/rendering/output_canvas_resolver.dart';

/// Resolved geometry for drawing a device frame: the output canvas, the
/// rect where the bezel PNG is drawn, the screen cutout sub-rect, and
/// the rect where the source video is drawn.
class DeviceFrameLayout {
  const DeviceFrameLayout({
    required this.canvasSize,
    required this.bezelRect,
    required this.screenRect,
    required this.videoRect,
  });

  final Size canvasSize;
  final Rect bezelRect;
  final Rect screenRect;
  final Rect videoRect;
}

/// Computes the device-frame layout. See [DeviceFrameLayout].
DeviceFrameLayout resolveDeviceFrameLayout({
  required DeviceFrameOrientationAsset asset,
  required Size recordingSize,
  required EdgeInsets padding,
  required OutputAspect aspect,
  required bool adjustSize,
}) {
  final bw = asset.bezelWidth.toDouble();
  final bh = asset.bezelHeight.toDouble();
  final sr = asset.screenRect;

  // Native screen cutout px and its aspect.
  final nativeScreenW = sr.width * bw;
  final nativeScreenH = sr.height * bh;
  final recAspect = recordingSize.height <= 0
      ? 1.0
      : recordingSize.width / recordingSize.height;

  // Content (bezel) size, stretched vertically when adjustSize so the
  // screen cutout takes on the recording's aspect.
  Size contentSize = Size(bw, bh);
  if (adjustSize && nativeScreenW > 0 && recAspect > 0) {
    final desiredScreenH = nativeScreenW / recAspect;
    final scaleY = desiredScreenH / nativeScreenH;
    contentSize = Size(bw, bh * scaleY);
  }

  final resolved = OutputCanvasResolver.resolve(
    videoSize: contentSize,
    padding: padding,
    aspect: aspect,
  );
  final canvasSize = resolved.canvasSize;
  final bezelRect = resolved.videoRect;

  final screenRect = Rect.fromLTRB(
    bezelRect.left + sr.l * bezelRect.width,
    bezelRect.top + sr.t * bezelRect.height,
    bezelRect.left + sr.r * bezelRect.width,
    bezelRect.top + sr.b * bezelRect.height,
  );

  final Rect videoRect;
  if (adjustSize) {
    videoRect = screenRect; // aspect already matches by construction
  } else {
    final scale = recordingSize.width <= 0 || recordingSize.height <= 0
        ? 1.0
        : (screenRect.width / recordingSize.width)
            .clamp(0.0, double.infinity)
            .toDouble();
    final scaleH = recordingSize.height <= 0
        ? scale
        : screenRect.height / recordingSize.height;
    final s = scale < scaleH ? scale : scaleH;
    final w = recordingSize.width * s;
    final h = recordingSize.height * s;
    videoRect = Rect.fromLTWH(
      screenRect.left + (screenRect.width - w) / 2,
      screenRect.top + (screenRect.height - h) / 2,
      w,
      h,
    );
  }

  return DeviceFrameLayout(
    canvasSize: canvasSize,
    bezelRect: bezelRect,
    screenRect: screenRect,
    videoRect: videoRect,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_layout_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/device_frame_layout.dart \
        packages/slipreel_engine/test/rendering/device_frame_layout_test.dart
git commit -m "feat(device-frames): pure layout geometry (bezel + screen + video rects)"
```

---

### Task 4: Device matcher + auto-enable logic

**Files:**
- Create: `packages/slipreel_engine/lib/rendering/device_frame_matcher.dart`
- Test: `packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart`

**Interfaces:**
- Consumes: `DeviceFrameCatalog`, `DeviceFrameEntry` (Task 1); `WindowFrame` (Task 5 adds the fields — this task only *reads* `deviceFrameId` and calls `copyWith`, so do Task 5 first or in the same branch).
- Produces:
  - `bool deviceMatchesRecording(DeviceFrameEntry entry, Size recording)` — exact (orientation-aware).
  - `List<DeviceFrameEntry> perfectMatches(DeviceFrameCatalog c, Size recording)`
  - `List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording)` — same kind + orientation as the recording.
  - `bool recordingIsPortrait(Size recording)`
  - `DeviceFrameEntry? autoSelectDeviceFrame(DeviceFrameCatalog c, Size recording)` — first perfect match or null.
  - `WindowFrame windowFrameWithAutoDeviceFrame({ required WindowFrame current, required DeviceFrameCatalog catalog, required Size recording })` — returns `current` unchanged unless `deviceFrameId == null` AND a perfect match exists, in which case it sets id + first color.

> **Note:** This task depends on Task 5's `WindowFrame` fields (`deviceFrameId`, `deviceFrameColor`, `copyWith`). Implement Task 5 before Step 3 here.

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';

DeviceFrameColorVariant _color(String id) => DeviceFrameColorVariant(
      id: id, name: id, swatch: const Color(0xFF000000),
      portrait: const DeviceFrameOrientationAsset(
        asset: 'p.png', bezelWidth: 1350, bezelHeight: 2760,
        screenRect: DeviceScreenRect(l: 0.05, t: 0.02, r: 0.95, b: 0.98)),
      landscape: const DeviceFrameOrientationAsset(
        asset: 'l.png', bezelWidth: 2760, bezelHeight: 1350,
        screenRect: DeviceScreenRect(l: 0.02, t: 0.05, r: 0.98, b: 0.95)),
    );

final _catalog = DeviceFrameCatalog([
  DeviceFrameEntry(
    id: 'iphone-16-pro', family: 'iPhone 16 Pro', kind: 'phone',
    screenWidth: 1206, screenHeight: 2622, colors: [_color('black'), _color('white')]),
  DeviceFrameEntry(
    id: 'ipad-pro-11', family: 'iPad Pro 11', kind: 'tablet',
    screenWidth: 1668, screenHeight: 2420, colors: [_color('silver')]),
]);

void main() {
  test('exact portrait match', () {
    expect(deviceMatchesRecording(_catalog.entryById('iphone-16-pro')!,
        const Size(1206, 2622)), isTrue);
  });

  test('exact landscape match (axes swapped)', () {
    expect(deviceMatchesRecording(_catalog.entryById('iphone-16-pro')!,
        const Size(2622, 1206)), isTrue);
  });

  test('non-matching resolution is not perfect', () {
    expect(perfectMatches(_catalog, const Size(1179, 2556)), isEmpty);
    expect(perfectMatches(_catalog, const Size(1206, 2622)).single.id, 'iphone-16-pro');
  });

  test('autoSelect returns the perfect match or null', () {
    expect(autoSelectDeviceFrame(_catalog, const Size(1206, 2622))!.id, 'iphone-16-pro');
    expect(autoSelectDeviceFrame(_catalog, const Size(800, 600)), isNull);
  });

  test('windowFrameWithAutoDeviceFrame sets id+color only when off and matched', () {
    final off = WindowFrame.none();
    final enabled = windowFrameWithAutoDeviceFrame(
        current: off, catalog: _catalog, recording: const Size(1206, 2622));
    expect(enabled.deviceFrameId, 'iphone-16-pro');
    expect(enabled.deviceFrameColor, 'black');

    // Already set -> unchanged.
    final preset = off.copyWith(deviceFrameId: 'ipad-pro-11', deviceFrameColor: 'silver');
    expect(identical(
        windowFrameWithAutoDeviceFrame(
            current: preset, catalog: _catalog, recording: const Size(1206, 2622)),
        preset), isTrue);

    // No match -> unchanged.
    expect(identical(
        windowFrameWithAutoDeviceFrame(
            current: off, catalog: _catalog, recording: const Size(800, 600)),
        off), isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_matcher_test.dart`
Expected: FAIL — matcher functions undefined.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/slipreel_engine/lib/rendering/device_frame_matcher.dart
import 'package:flutter/painting.dart';

import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';

bool recordingIsPortrait(Size recording) => recording.height >= recording.width;

/// Exact, orientation-aware match between a device's native screen
/// resolution and the recording's pixel size.
bool deviceMatchesRecording(DeviceFrameEntry entry, Size recording) {
  final w = recording.width.round();
  final h = recording.height.round();
  if (recordingIsPortrait(recording)) {
    return entry.screenWidth == w && entry.screenHeight == h;
  }
  return entry.screenWidth == h && entry.screenHeight == w;
}

List<DeviceFrameEntry> perfectMatches(DeviceFrameCatalog c, Size recording) =>
    [for (final e in c.entries) if (deviceMatchesRecording(e, recording)) e];

/// All entries whose *kind* fits a portrait/landscape recording — used
/// for the "Flexible" picker (scaled to fit, not exact).
List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording) =>
    List<DeviceFrameEntry>.from(c.entries);

DeviceFrameEntry? autoSelectDeviceFrame(DeviceFrameCatalog c, Size recording) {
  final matches = perfectMatches(c, recording);
  return matches.isEmpty ? null : matches.first;
}

/// Returns [current] unchanged unless the device frame is OFF
/// (`deviceFrameId == null`) and a perfect match exists, in which case
/// it enables that device with its first color.
WindowFrame windowFrameWithAutoDeviceFrame({
  required WindowFrame current,
  required DeviceFrameCatalog catalog,
  required Size recording,
}) {
  if (current.deviceFrameId != null) return current;
  final match = autoSelectDeviceFrame(catalog, recording);
  if (match == null || match.colors.isEmpty) return current;
  return current.copyWith(
    deviceFrameId: match.id,
    deviceFrameColor: match.colors.first.id,
  );
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_matcher_test.dart`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/rendering/device_frame_matcher.dart \
        packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart
git commit -m "feat(device-frames): Perfect/Flexible matcher + auto-enable logic"
```

---

### Task 5: WindowFrame device-frame fields

**Files:**
- Modify: `packages/slipreel_engine/lib/models/window_frame.dart`
- Test: `packages/slipreel_engine/test/models/window_frame_device_test.dart`

**Interfaces:**
- Produces (on `WindowFrame`): `final String? deviceFrameId; final String? deviceFrameColor; final bool deviceFrameAdjustSize;` plus `copyWith({String? deviceFrameId, String? deviceFrameColor, bool? deviceFrameAdjustSize, bool clearDeviceFrame = false})`, serialized in `toJson`/`fromJson`, included in `==`/`hashCode`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/models/window_frame_device_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';

void main() {
  test('defaults: no device frame, adjustSize true', () {
    final f = WindowFrame.none();
    expect(f.deviceFrameId, isNull);
    expect(f.deviceFrameColor, isNull);
    expect(f.deviceFrameAdjustSize, isTrue);
  });

  test('copyWith sets and clears device frame', () {
    final set = WindowFrame.none()
        .copyWith(deviceFrameId: 'iphone-16-pro', deviceFrameColor: 'black');
    expect(set.deviceFrameId, 'iphone-16-pro');
    final cleared = set.copyWith(clearDeviceFrame: true);
    expect(cleared.deviceFrameId, isNull);
    expect(cleared.deviceFrameColor, isNull);
  });

  test('json round-trips device-frame fields', () {
    final f = WindowFrame.none().copyWith(
      deviceFrameId: 'iphone-16-pro',
      deviceFrameColor: 'white',
      deviceFrameAdjustSize: false,
    );
    final back = WindowFrame.fromJson(f.toJson());
    expect(back.deviceFrameId, 'iphone-16-pro');
    expect(back.deviceFrameColor, 'white');
    expect(back.deviceFrameAdjustSize, isFalse);
    expect(back, f);
  });

  test('legacy json (no device fields) loads with defaults', () {
    final json = WindowFrame.none().toJson()..remove('deviceFrameId')
      ..remove('deviceFrameColor')..remove('deviceFrameAdjustSize');
    final back = WindowFrame.fromJson(json);
    expect(back.deviceFrameId, isNull);
    expect(back.deviceFrameAdjustSize, isTrue);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/models/window_frame_device_test.dart`
Expected: FAIL — `deviceFrameId` getter undefined.

- [ ] **Step 3: Write minimal implementation**

In `window_frame.dart`:

1. Add fields after `inset` (line ~56):
```dart
  /// Catalog id of the selected device frame, e.g. "iphone-16-pro".
  /// Null means no device frame is drawn.
  final String? deviceFrameId;

  /// Selected color variant id within [deviceFrameId], e.g.
  /// "black-titanium". Ignored when [deviceFrameId] is null.
  final String? deviceFrameColor;

  /// When true, the device mockup stretches so its screen cutout
  /// matches the recording's aspect (video fills edge-to-edge). When
  /// false, the device keeps true proportions and the video is
  /// letterbox-fit inside the screen. Defaults to true.
  final bool deviceFrameAdjustSize;
```

2. Add to the constructor params (after `this.inset = 0,`):
```dart
    this.deviceFrameId,
    this.deviceFrameColor,
    this.deviceFrameAdjustSize = true,
```

3. In `copyWith`, add params (after `double? inset,`) and a clear flag (after `bool clearWallpaper = false,`):
```dart
    String? deviceFrameId,
    String? deviceFrameColor,
    bool? deviceFrameAdjustSize,
    bool clearDeviceFrame = false,
```
and in the returned `WindowFrame(...)` (after `inset: inset ?? this.inset,`):
```dart
      deviceFrameId:
          clearDeviceFrame ? null : (deviceFrameId ?? this.deviceFrameId),
      deviceFrameColor:
          clearDeviceFrame ? null : (deviceFrameColor ?? this.deviceFrameColor),
      deviceFrameAdjustSize:
          deviceFrameAdjustSize ?? this.deviceFrameAdjustSize,
```

4. In `toJson()` (after `'inset': inset,`):
```dart
      'deviceFrameId': deviceFrameId,
      'deviceFrameColor': deviceFrameColor,
      'deviceFrameAdjustSize': deviceFrameAdjustSize,
```

5. In `fromJson` (after `inset: (json['inset'] as num?)?.toDouble() ?? 0,`):
```dart
      deviceFrameId: json['deviceFrameId'] as String?,
      deviceFrameColor: json['deviceFrameColor'] as String?,
      deviceFrameAdjustSize: json['deviceFrameAdjustSize'] as bool? ?? true,
```

6. In `operator ==` (after `other.inset == inset;` — change the `;` to `&&` and append):
```dart
        other.inset == inset &&
        other.deviceFrameId == deviceFrameId &&
        other.deviceFrameColor == deviceFrameColor &&
        other.deviceFrameAdjustSize == deviceFrameAdjustSize;
```

7. In `hashCode` `Object.hash(...)` add the three fields before the closing `);` (note: `Object.hash` takes up to 20 positional args — current list has 13, adding 3 is fine):
```dart
      inset,
      deviceFrameId,
      deviceFrameColor,
      deviceFrameAdjustSize,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/models/window_frame_device_test.dart`
Then the existing frame test for regressions: `flutter test test/models/`
Expected: PASS (4 new tests + existing pass).

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/models/window_frame.dart \
        packages/slipreel_engine/test/models/window_frame_device_test.dart
git commit -m "feat(device-frames): WindowFrame device-frame fields + serialization"
```

---

### Task 6: Asset extraction script (offline, Python)

**Files:**
- Create: `tool/device_frames/extract.py`
- Create: `tool/device_frames/test_extract.py`
- Create: `tool/device_frames/README.md`

**Interfaces:**
- Produces: `screen_rect(png_path) -> dict` returning `{bezel_w, bezel_h, screen: {w,h,x,y}, screenRect: {l,t,r,b}}`; a `main()` that downloads/mounts DMGs and writes assets + `manifest.json`.

> The download/mount path needs macOS + network + accepting the Apple SLA; it is **not** unit-tested. Only the pure `screen_rect` extractor is tested, against a synthesized fixture PNG.

- [ ] **Step 1: Write the failing test**

```python
# tool/device_frames/test_extract.py
import os, sys, unittest
from PIL import Image, ImageDraw
sys.path.insert(0, os.path.dirname(__file__))
from extract import screen_rect  # noqa: E402

class ScreenRectTest(unittest.TestCase):
    def _fixture(self, path):
        # Opaque device body (200x400) with a transparent interior screen
        # rect at (20,30)-(180,370), plus transparent outer margin.
        img = Image.new("RGBA", (240, 440), (0, 0, 0, 0))
        d = ImageDraw.Draw(img)
        d.rectangle([20, 20, 220, 420], fill=(20, 20, 20, 255))   # body (opaque)
        d.rectangle([40, 50, 200, 390], fill=(0, 0, 0, 0))        # screen (cut-out)
        img.save(path)

    def test_finds_interior_screen_rect(self):
        p = "/tmp/_df_fixture.png"
        self._fixture(p)
        r = screen_rect(p)
        self.assertEqual(r["bezel_w"], 240)
        self.assertEqual(r["bezel_h"], 440)
        self.assertEqual(r["screen"]["w"], 161)   # 200-40+1
        self.assertEqual(r["screen"]["h"], 341)   # 390-50+1
        self.assertEqual(r["screen"]["x"], 40)
        self.assertEqual(r["screen"]["y"], 50)
        self.assertAlmostEqual(r["screenRect"]["l"], 40 / 240, places=4)

if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 tool/device_frames/test_extract.py`
Expected: FAIL — `ModuleNotFoundError: No module named 'extract'` (file doesn't exist yet).

- [ ] **Step 3: Write minimal implementation**

```python
# tool/device_frames/extract.py
"""Extract Apple Design Resources device bezels into Slipreel assets.

Pure extractor (`screen_rect`) is unit-tested. The download/mount/main
path requires macOS + network + accepting Apple's SLA and is run by a
developer (see README). Output: assets/device_frames/<id>/<color>-<orient>.png
plus assets/device_frames/manifest.json.

LICENSE: Apple Design Resources may not be embedded/redistributed in a
product without Apple's permission. Running this and shipping the output
is gated on Apple sign-off. See docs/superpowers/specs/2026-06-21-device-frames-design.md.
"""
import json
import os
import re
import subprocess
import sys
from PIL import Image, ImageDraw

# Apple bezel DMGs (public CDN). Extend as the catalog grows.
DMG_URLS = [
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-16.dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPhone-17.dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-Pro-(M5).dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-Air-(M4).dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-mini-(A17-Pro).dmg",
    "https://devimages-cdn.apple.com/design/resources/download/Bezel-iPad-(A16).dmg",
]


def screen_rect(png_path):
    """Find the interior transparent screen cutout in a bezel PNG.

    Returns bezel size, screen bbox (px), and normalized screenRect.
    Algorithm: flood-fill transparent pixels from the border to mark the
    OUTSIDE; the remaining transparent region is the screen cutout.
    """
    im = Image.open(png_path).convert("RGBA")
    w, h = im.size
    alpha = im.split()[3]               # 0 = transparent, 255 = opaque
    work = alpha.copy()
    px = alpha.load()
    seeds = [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1),
             (w // 2, 0), (w // 2, h - 1), (0, h // 2), (w - 1, h // 2)]
    for sx, sy in seeds:
        if px[sx, sy] == 0:
            ImageDraw.floodfill(work, (sx, sy), 200, thresh=0)
    wpx = work.load()
    xs0, ys0, xs1, ys1 = w, h, -1, -1
    for y in range(h):
        for x in range(w):
            if wpx[x, y] == 0:          # transparent and not reached -> screen
                if x < xs0:
                    xs0 = x
                if y < ys0:
                    ys0 = y
                if x > xs1:
                    xs1 = x
                if y > ys1:
                    ys1 = y
    if xs1 < 0:
        raise ValueError(f"no interior screen cutout in {png_path}")
    sw, sh = xs1 - xs0 + 1, ys1 - ys0 + 1
    return {
        "bezel_w": w, "bezel_h": h,
        "screen": {"w": sw, "h": sh, "x": xs0, "y": ys0},
        "screenRect": {
            "l": xs0 / w, "t": ys0 / h, "r": (xs1 + 1) / w, "b": (ys1 + 1) / h,
        },
    }


def slugify(s):
    return re.sub(r"[^a-z0-9]+", "-", s.lower()).strip("-")


def parse_filename(name):
    """`<Device> - <Color> - <Orientation>.png` -> (device, color, orient)."""
    base = name[:-4] if name.lower().endswith(".png") else name
    parts = [p.strip() for p in base.split(" - ")]
    if len(parts) != 3:
        return None
    device, color, orient = parts
    return device, color, orient.lower()


def mount(dmg_path):
    mnt = "/tmp/df_mnt_" + slugify(os.path.basename(dmg_path))
    subprocess.run(
        ["hdiutil", "attach", dmg_path, "-nobrowse", "-readonly", "-mountpoint", mnt],
        input=b"Y\n" * 50, check=True,
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    return mnt


def main():
    out_root = os.path.join("packages", "screen_recorder", "assets", "device_frames")
    os.makedirs(out_root, exist_ok=True)
    cache = "/tmp/df_dmgs"
    os.makedirs(cache, exist_ok=True)

    entries = {}  # id -> entry dict
    for url in DMG_URLS:
        dmg = os.path.join(cache, os.path.basename(url))
        if not os.path.exists(dmg):
            print(f"downloading {url}")
            subprocess.run(["curl", "-sL", "-o", dmg, url], check=True)
        mnt = mount(dmg)
        try:
            png_dir = os.path.join(mnt, "PNG")
            for dirpath, _dirs, files in os.walk(png_dir):
                for fn in files:
                    if not fn.lower().endswith(".png"):
                        continue
                    parsed = parse_filename(fn)
                    if parsed is None:
                        continue
                    device, color, orient = parsed
                    if orient not in ("portrait", "landscape"):
                        continue
                    src = os.path.join(dirpath, fn)
                    geom = screen_rect(src)
                    dev_id = slugify(device)
                    color_id = slugify(color)
                    dst_dir = os.path.join(out_root, dev_id)
                    os.makedirs(dst_dir, exist_ok=True)
                    dst_name = f"{color_id}-{orient}.png"
                    # Recompress (optional pngquant if present).
                    Image.open(src).convert("RGBA").save(os.path.join(dst_dir, dst_name))
                    asset = f"assets/device_frames/{dev_id}/{dst_name}"

                    entry = entries.setdefault(dev_id, {
                        "id": dev_id, "family": device,
                        "kind": "tablet" if "ipad" in dev_id else "phone",
                        "screen": None, "colors": {},
                    })
                    cv = entry["colors"].setdefault(
                        color_id, {"id": color_id, "name": color, "swatch": "#1d1d1f"})
                    cv[orient] = {
                        "asset": asset,
                        "bezel": {"w": geom["bezel_w"], "h": geom["bezel_h"]},
                        "screenRect": geom["screenRect"],
                    }
                    # Native portrait screen res defines the entry screen size.
                    if orient == "portrait":
                        entry["screen"] = {"w": geom["screen"]["w"], "h": geom["screen"]["h"]}
        finally:
            subprocess.run(["hdiutil", "detach", mnt, "-quiet"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    # Flatten colors dict -> list; drop incomplete variants/entries.
    manifest = {"entries": []}
    for entry in entries.values():
        if entry["screen"] is None:
            continue
        colors = [c for c in entry["colors"].values()
                  if "portrait" in c and "landscape" in c]
        if not colors:
            continue
        entry["colors"] = colors
        manifest["entries"].append(entry)

    with open(os.path.join(out_root, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print(f"wrote {len(manifest['entries'])} device entries to {out_root}/manifest.json")


if __name__ == "__main__":
    sys.exit(main())
```

Create `tool/device_frames/README.md`:

```markdown
# Device frame extraction

Generates `packages/screen_recorder/assets/device_frames/**` + `manifest.json`
from Apple Design Resources bezel DMGs.

## ⚠️ License gate
Apple Design Resources may **not** be embedded/redistributed in a product
without Apple's written permission (see the spec, §9). Do not ship the
generated assets until that sign-off is obtained.

## Run (macOS)
    python3 tool/device_frames/extract.py

Downloads the DMGs listed in `DMG_URLS`, mounts them (auto-accepting the
SLA), extracts each `<Device> - <Color> - <Orientation>.png`, computes the
screen cutout, and writes the assets + manifest.

## Test the extractor
    python3 tool/device_frames/test_extract.py
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 tool/device_frames/test_extract.py`
Expected: PASS (`Ran 1 test ... OK`).

- [ ] **Step 5: Commit**

```bash
git add tool/device_frames/
git commit -m "feat(device-frames): offline Apple-bezel extraction script + extractor test"
```

---

### Task 7: Export compositor device-frame path

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart`
- Test: `packages/slipreel_engine/test/export/frame_compositor_device_test.dart`

**Interfaces:**
- Consumes: `DeviceFrameCatalog` (Task 2), `resolveDeviceFrameLayout` (Task 3), `WindowFrame.deviceFrameId/Color/AdjustSize` (Task 5), `recordingIsPortrait` (Task 4).
- Produces (on `FrameCompositor`):
  - New ctor param `DeviceFrameCatalog? deviceFrameCatalog`.
  - `@visibleForTesting Future<ui.Image> Function(String asset)? bezelImageLoaderOverride` (defaults to `rootBundle`).
  - `DeviceFrameRenderPlan? deviceFramePlan` getter: `{ DeviceFrameOrientationAsset asset, DeviceFrameLayout layout }` or null.
  - `compose` draws the device frame when `deviceFramePlan != null`: wallpaper → (blurred) video at `layout.videoRect` → crisp bezel at `layout.bezelRect` (through `applyZoom`) → camera. No chrome.

> **Key compositing facts** (verified): the bezel PNG is opaque except the transparent screen cutout. Draw the video into `layout.videoRect` first, then the bezel into `layout.bezelRect` on top — the bezel masks the corners + overlays the island automatically. The video is the motion-blurred layer; the bezel is crisp (like chrome).

- [ ] **Step 1: Write the failing test**

```dart
// packages/slipreel_engine/test/export/frame_compositor_device_test.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/export/frame_compositor.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/recording_metadata.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/cursor_recording.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

// 1206x2622 native screen; small bezel for a fast test (scaled-down,
// proportions preserved): bezel 120x240, screen inset 10px each side.
DeviceFrameCatalog _catalog() => const DeviceFrameCatalog([
      DeviceFrameEntry(
        id: 'test-phone', family: 'Test Phone', kind: 'phone',
        screenWidth: 100, screenHeight: 220,
        colors: [
          DeviceFrameColorVariant(
            id: 'black', name: 'Black', swatch: Color(0xFF000000),
            portrait: DeviceFrameOrientationAsset(
              asset: 'test://bezel-p', bezelWidth: 120, bezelHeight: 240,
              screenRect: DeviceScreenRect(
                l: 10 / 120, t: 10 / 240, r: 110 / 120, b: 230 / 240)),
            landscape: DeviceFrameOrientationAsset(
              asset: 'test://bezel-l', bezelWidth: 240, bezelHeight: 120,
              screenRect: DeviceScreenRect(
                l: 10 / 240, t: 10 / 120, r: 230 / 240, b: 110 / 120)),
          ),
        ],
      ),
    ]);

// A bezel image: fully red, with a transparent rect where the screen is.
Future<ui.Image> _bezelImage(int w, int h, Rect hole) async {
  final rec = ui.PictureRecorder();
  final c = ui.Canvas(rec);
  c.drawRect(Rect.fromLTWH(0, 0, w.toDouble(), h.toDouble()),
      Paint()..color = const Color(0xFFFF0000));
  c.drawRect(hole, Paint()..blendMode = BlendMode.clear);
  final pic = rec.endRecording();
  return pic.toImage(w, h);
}

Uint8List _solidBgra(int w, int h, int b, int g, int r) {
  final bytes = Uint8List(w * h * 4);
  for (var i = 0; i < w * h; i++) {
    bytes[i * 4] = b; bytes[i * 4 + 1] = g; bytes[i * 4 + 2] = r; bytes[i * 4 + 3] = 255;
  }
  return bytes;
}

void main() {
  test('device-frame compose: video in cutout, bezel around it', () async {
    final state = EditorProjectState.defaults().copyWith(
      windowFrame: WindowFrame.none()
          .copyWith(deviceFrameId: 'test-phone', deviceFrameColor: 'black'),
    );
    final comp = FrameCompositor(
      projectState: state,
      cursorRecording: CursorRecording(),
      metadata: const RecordingMetadata(
        isPureSource: true, recordedAt: null, widthPx: 100, heightPx: 220,
        fps: 60, isDeviceCapture: true),
      videoSize: const Size(100, 220),
      fps: 60,
      deviceFrameCatalog: _catalog(),
    )..bezelImageLoaderOverride = (asset) =>
        _bezelImage(120, 240, const Rect.fromLTWH(10, 10, 100, 220));

    expect(comp.deviceFramePlan, isNotNull);
    expect(comp.totalSize.width.round(), 120);
    expect(comp.totalSize.height.round(), 240);

    final rgba = await comp.compose(
      videoFrameBgra: _solidBgra(100, 220, 0, 255, 0), // green video
      position: Duration.zero,
    );
    final w = comp.totalSize.width.round();
    int at(int x, int y) {
      final i = (y * w + x) * 4;
      return (rgba[i] << 16) | (rgba[i + 1] << 8) | rgba[i + 2]; // RGB
    }
    // Screen center -> green video.
    expect(at(60, 120), 0x00FF00);
    // Bezel ring (5px in from edge) -> red.
    expect(at(5, 120), 0xFF0000);
  });
}
```

> If `RecordingMetadata`'s `recordedAt` is non-nullable in your tree, pass `DateTime.fromMillisecondsSinceEpoch(0)` instead of `null`.

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_device_test.dart`
Expected: FAIL — `deviceFrameCatalog` param / `bezelImageLoaderOverride` / `deviceFramePlan` undefined.

- [ ] **Step 3: Write minimal implementation**

In `frame_compositor.dart`:

1. Add imports:
```dart
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
```

2. Add a ctor param `this.deviceFrameCatalog` and field:
```dart
  final DeviceFrameCatalog? deviceFrameCatalog;
```
Add to the constructor parameter list (e.g. after `this.cameraSrcHeight = 0,`): `this.deviceFrameCatalog,`.

3. Replace the `totalSize` / `_videoRect` initializers so they honor the device plan. Simplest: compute a static plan helper and use it. Add after the field declarations:
```dart
  /// Resolved device-frame plan (null when no device frame is active).
  late final DeviceFrameRenderPlan? deviceFramePlan = _resolveDeviceFramePlan();

  DeviceFrameRenderPlan? _resolveDeviceFramePlan() {
    final id = projectState.windowFrame.deviceFrameId;
    final catalog = deviceFrameCatalog;
    if (id == null || catalog == null) return null;
    final entry = catalog.entryById(id);
    if (entry == null) return null;
    final color = entry.colorById(projectState.windowFrame.deviceFrameColor ?? '')
        ?? (entry.colors.isEmpty ? null : entry.colors.first);
    if (color == null) return null;
    final asset = recordingIsPortrait(videoSize) ? color.portrait : color.landscape;
    final layout = resolveDeviceFrameLayout(
      asset: asset,
      recordingSize: videoSize,
      padding: projectState.windowFrame.padding,
      aspect: projectState.outputAspect,
      adjustSize: projectState.windowFrame.deviceFrameAdjustSize,
    );
    return DeviceFrameRenderPlan(asset: asset, layout: layout);
  }

  @visibleForTesting
  Future<ui.Image> Function(String asset)? bezelImageLoaderOverride;
  ui.Image? _cachedBezelImage;
```

   Then change `totalSize` and `_videoRect` to be `late final` computed from the plan when present. Replace their initializer-list forms with field declarations + an initializer that branches. Concretely, remove `totalSize` / `_videoRect` from the initializer list and declare:
```dart
  late final Size totalSize = deviceFramePlan != null
      ? _evenSize(deviceFramePlan!.layout.canvasSize)
      : _evenSize(OutputCanvasResolver.resolve(
          videoSize: videoSize,
          padding: projectState.windowFrame.padding,
          aspect: projectState.outputAspect,
        ).canvasSize);

  late final Rect _videoRect = deviceFramePlan != null
      ? _shiftRect(deviceFramePlan!.layout.videoRect,
          _evenCenteringDelta(deviceFramePlan!.layout.canvasSize))
      : _centeredVideoRect(
          _evenSize(OutputCanvasResolver.resolve(
            videoSize: videoSize,
            padding: projectState.windowFrame.padding,
            aspect: projectState.outputAspect,
          ).canvasSize),
          videoSize);

  late final Rect _bezelRect = deviceFramePlan == null
      ? Rect.zero
      : _shiftRect(deviceFramePlan!.layout.bezelRect,
          _evenCenteringDelta(deviceFramePlan!.layout.canvasSize));
```
   (`_framePainter` stays as-is; it is simply unused on the device path.)

   Add helpers near `_centeredVideoRect`:
```dart
  static Offset _evenCenteringDelta(Size raw) {
    final even = _evenSize(raw);
    return Offset((even.width - raw.width) / 2, (even.height - raw.height) / 2);
  }

  static Rect _shiftRect(Rect r, Offset d) => r.shift(d);
```

4. Add the bezel image loader + cache (near `_ensureWallpaperImage`):
```dart
  Future<ui.Image?> _ensureBezelImage() async {
    final plan = deviceFramePlan;
    if (plan == null) return null;
    final cached = _cachedBezelImage;
    if (cached != null) return cached;
    final loader = bezelImageLoaderOverride ?? _loadBezelFromBundle;
    return _cachedBezelImage = await loader(plan.asset.asset);
  }

  Future<ui.Image> _loadBezelFromBundle(String assetPath) async {
    final data = await rootBundle.load(assetPath);
    final codec = await ui.instantiateImageCodec(data.buffer.asUint8List());
    final frame = await codec.getNextFrame();
    return frame.image;
  }
```

5. In `compose`, branch at the top of the `try` (after computing `scenePass`/`zoomTransform`/`applyZoom`/`layerRect`, i.e. after the existing `applyZoom` closure and `layerRect` definition) — when `deviceFramePlan != null`, take a device path that skips the chrome and draws video-into-cutout + bezel:
```dart
      if (deviceFramePlan != null) {
        return await _composeDeviceFrame(
          videoImage: videoImage,
          position: position,
          sceneSignal: sceneSignal,
          applyZoom: applyZoom,
          layerRect: layerRect,
        );
      }
```
   Add the method (device captures have no cursor data, so the fg layer is just the video; bezel is crisp; camera kept for parity):
```dart
  Future<Uint8List> _composeDeviceFrame({
    required ui.Image videoImage,
    required Duration position,
    required _SceneMotionSignal sceneSignal, // use the actual return type of _computeSceneMotionSignal
    required void Function(ui.Canvas) applyZoom,
    required Rect layerRect,
  }) async {
    // Foreground = video drawn into the screen cutout, motion-blurred.
    final fgRecorder = ui.PictureRecorder();
    final fgCanvas = ui.Canvas(fgRecorder, layerRect);
    applyZoom(fgCanvas);
    paintImageRectToRect(fgCanvas, videoImage, _videoRect);
    final fgPicture = fgRecorder.endRecording();

    // Bezel = crisp PNG on top, through the same zoom transform.
    final bezel = await _ensureBezelImage();
    ui.Picture? bezelPicture;
    if (bezel != null) {
      final r = ui.PictureRecorder();
      final c = ui.Canvas(r, layerRect);
      applyZoom(c);
      paintImageRectToRect(c, bezel, _bezelRect);
      bezelPicture = r.endRecording();
    }

    try {
      final fgImage = await fgPicture.toImage(
          totalSize.width.toInt(), totalSize.height.toInt());
      final ui.Image? bezelImg = bezelPicture == null
          ? null
          : await bezelPicture.toImage(
              totalSize.width.toInt(), totalSize.height.toInt());
      try {
        final blurredFg = await _applySceneMotionBlur(fgImage, sceneSignal);
        final fgToComposite = blurredFg ?? fgImage;
        try {
          final wallpaperImage = await _ensureWallpaperImage();
          final composeRecorder = ui.PictureRecorder();
          final composeCanvas = ui.Canvas(composeRecorder,
              Rect.fromLTWH(0, 0, totalSize.width, totalSize.height));
          if (wallpaperImage != null) {
            composeCanvas.drawImage(wallpaperImage, Offset.zero, Paint());
          }
          composeCanvas.drawImage(fgToComposite, Offset.zero, Paint());
          if (bezelImg != null) {
            composeCanvas.drawImage(bezelImg, Offset.zero, Paint());
          }
          final composePicture = composeRecorder.endRecording();
          try {
            final finalImage = await composePicture.toImage(
                totalSize.width.toInt(), totalSize.height.toInt());
            try {
              final byteData =
                  await finalImage.toByteData(format: ui.ImageByteFormat.rawRgba);
              if (byteData == null) {
                throw StateError('toByteData returned null at $position');
              }
              return Uint8List.fromList(byteData.buffer.asUint8List());
            } finally {
              finalImage.dispose();
            }
          } finally {
            composePicture.dispose();
          }
        } finally {
          if (blurredFg != null) blurredFg.dispose();
        }
      } finally {
        fgImage.dispose();
        bezelImg?.dispose();
      }
    } finally {
      fgPicture.dispose();
      bezelPicture?.dispose();
    }
  }

  /// Draws [image] (its full bounds) into [dst], scaling to fit.
  static void paintImageRectToRect(ui.Canvas c, ui.Image image, Rect dst) {
    final src = Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble());
    c.drawImageRect(image, src, dst,
        Paint()..filterQuality = FilterQuality.high);
  }
```

> Replace `_SceneMotionSignal` with the actual type returned by `_computeSceneMotionSignal` (read it in the file — it is defined lower down). If it's a private named type, the new method can stay in the same file so the type is in scope.

6. Dispose `_cachedBezelImage` wherever the compositor disposes `_cachedWallpaperImage` (find the dispose path / add one if the class has a `dispose()`); if there's no `dispose()` on the class, add bezel cleanup alongside the existing wallpaper cleanup in `_ensureWallpaperImage`'s null branch is not appropriate — instead, if the class lacks a dispose, leave the single cached image to be GC'd at end of export (matches wallpaper's lifetime). Document with a comment.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_device_test.dart`
Expected: PASS. Then run the full export suite for regressions: `flutter test test/export/`.

- [ ] **Step 5: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/slipreel_engine/test/export/frame_compositor_device_test.dart
git commit -m "feat(device-frames): export compositor draws video-in-cutout + bezel"
```

---

### Task 8: Preview composition widget + PlaybackCanvas branch

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/zoom/device_frame_composition.dart`
- Test: `packages/screen_recorder/test/ui/device_frame_composition_test.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`

**Interfaces:**
- Consumes: `DeviceFrameLayout` (Task 3).
- Produces:
  - `class DeviceFrameComposition extends StatelessWidget { final DeviceFrameLayout layout; final Widget video; final ImageProvider bezel; }` — a `Stack` with the video `Positioned` at `layout.videoRect` and the bezel `Image` `Positioned` at `layout.bezelRect` on top.
- PlaybackCanvas: new `DeviceFrameCatalog? deviceFrameCatalog` field; when a device frame is active, swap the `FramePainter` + video `Positioned` (lines ~1082–1103) for a `DeviceFrameComposition`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/device_frame_composition_test.dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';
import 'package:screen_recorder/ui/widgets/zoom/device_frame_composition.dart';

Future<ui.Image> _img() async {
  final r = ui.PictureRecorder();
  ui.Canvas(r).drawRect(const Rect.fromLTWH(0, 0, 2, 2),
      Paint()..color = const Color(0xFFFF0000));
  return r.endRecording().toImage(2, 2);
}

void main() {
  testWidgets('positions video and bezel per layout', (tester) async {
    const layout = DeviceFrameLayout(
      canvasSize: Size(120, 240),
      bezelRect: Rect.fromLTWH(0, 0, 120, 240),
      screenRect: Rect.fromLTWH(10, 10, 100, 220),
      videoRect: Rect.fromLTWH(10, 10, 100, 220),
    );
    final image = await _img();
    await tester.pumpWidget(MaterialApp(
      home: DeviceFrameComposition(
        layout: layout,
        video: const ColoredBox(color: Color(0xFF00FF00), key: Key('video')),
        bezel: _TestImageProvider(image),
      ),
    ));
    final videoRect = tester.getRect(find.byKey(const Key('video')));
    expect(videoRect.width, closeTo(100, 0.5));
    expect(videoRect.height, closeTo(220, 0.5));
    expect(find.byType(Image), findsOneWidget);
  });
}

class _TestImageProvider extends ImageProvider<_TestImageProvider> {
  _TestImageProvider(this.image);
  final ui.Image image;
  @override
  Future<_TestImageProvider> obtainKey(ImageConfiguration c) async => this;
  @override
  ImageStreamCompleter loadImage(_TestImageProvider key, ImageDecoderCallback d) =>
      OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image)),
      );
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/device_frame_composition_test.dart`
Expected: FAIL — `DeviceFrameComposition` undefined.

- [ ] **Step 3: Write minimal implementation**

```dart
// packages/screen_recorder/lib/ui/widgets/zoom/device_frame_composition.dart
import 'package:flutter/widgets.dart';
import 'package:slipreel_engine/rendering/device_frame_layout.dart';

/// Lays out a device frame: the source [video] in the screen cutout,
/// the [bezel] PNG on top. Both positioned per [layout]. Used inside
/// PlaybackCanvas's zoom Transform so they scale/pan together.
class DeviceFrameComposition extends StatelessWidget {
  const DeviceFrameComposition({
    super.key,
    required this.layout,
    required this.video,
    required this.bezel,
  });

  final DeviceFrameLayout layout;
  final Widget video;
  final ImageProvider bezel;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fromRect(
          rect: layout.videoRect,
          child: video,
        ),
        Positioned.fromRect(
          rect: layout.bezelRect,
          child: Image(
            image: bezel,
            fit: BoxFit.fill,
            filterQuality: FilterQuality.high,
          ),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/device_frame_composition_test.dart`
Expected: PASS.

- [ ] **Step 5: Wire into PlaybackCanvas**

In `playback_canvas.dart`:
1. Add a field + constructor param: `final DeviceFrameCatalog? deviceFrameCatalog;` (default null), import `device_frame.dart`, `device_frame_layout.dart`, `device_frame_matcher.dart`, and the new `device_frame_composition.dart`.
2. After computing `resolved` (line ~681), compute an optional plan:
```dart
    DeviceFrameLayout? deviceLayout;
    DeviceFrameOrientationAsset? deviceAsset;
    final dfId = currentFrame.deviceFrameId;
    final dfCatalog = widget.deviceFrameCatalog;
    if (dfId != null && dfCatalog != null) {
      final entry = dfCatalog.entryById(dfId);
      final color = entry?.colorById(currentFrame.deviceFrameColor ?? '')
          ?? (entry != null && entry.colors.isNotEmpty ? entry.colors.first : null);
      if (color != null) {
        deviceAsset = recordingIsPortrait(videoSize) ? color.portrait : color.landscape;
        deviceLayout = resolveDeviceFrameLayout(
          asset: deviceAsset,
          recordingSize: videoSize,
          padding: currentFrame.padding,
          aspect: widget.outputAspect,
          adjustSize: currentFrame.deviceFrameAdjustSize,
        );
      }
    }
```
3. Override `totalSize` / `videoOriginX/Y` when `deviceLayout != null`:
```dart
    final Size effTotalSize = deviceLayout?.canvasSize ?? totalSize;
    final double effVideoOriginX = deviceLayout?.videoRect.left ?? videoOriginX;
    final double effVideoOriginY = deviceLayout?.videoRect.top ?? videoOriginY;
```
   Use `effTotalSize` for the outer `SizedBox(width/height)` at line ~705 and the cursor-overlay `SizedBox`es, and `effVideoOriginX/Y` where the video/cursor are positioned. (Device captures have no cursor data, so cursor overlays are inert — but keep the substitution consistent.)
4. Replace the `composition` `Stack` children (the `FramePainter` `CustomPaint` at ~1082 and the video `Positioned` at ~1090) with a device branch:
```dart
            final composition = Stack(
              children: [
                if (deviceLayout != null && deviceAsset != null)
                  SizedBox(
                    width: effTotalSize.width,
                    height: effTotalSize.height,
                    child: DeviceFrameComposition(
                      layout: deviceLayout,
                      video: videoPlayer!,
                      bezel: AssetImage(deviceAsset.asset),
                    ),
                  )
                else ...[
                  CustomPaint(
                    size: totalSize,
                    painter: FramePainter(
                      frame: currentFrame,
                      videoSize: videoSize,
                      aspect: widget.outputAspect,
                    ),
                  ),
                  Positioned(
                    left: videoOriginX,
                    top: videoOriginY,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(currentFrame.cornerRadius),
                      child: SizedBox(
                        width: videoSize.width,
                        height: videoSize.height,
                        child: videoPlayer!,
                      ),
                    ),
                  ),
                ],
                // ... keep the existing showZoomDebug + debugSnapshot children unchanged ...
              ],
            );
```
   Leave the `if (widget.showZoomDebug)` and debug-snapshot `Builder` children exactly as they are, appended after the branch above.

- [ ] **Step 6: Run preview test + a smoke analyze**

Run: `cd packages/screen_recorder && flutter test test/ui/device_frame_composition_test.dart && flutter analyze lib/ui/widgets/zoom/playback_canvas.dart`
Expected: test PASS; analyze: no new errors.

- [ ] **Step 7: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/device_frame_composition.dart \
        packages/screen_recorder/test/ui/device_frame_composition_test.dart \
        packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "feat(device-frames): preview composition widget + PlaybackCanvas branch"
```

---

### Task 9: Inspector device-frame controls

**Files:**
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart`
- Test: `packages/screen_recorder/test/ui/background_tab_device_test.dart`

**Interfaces:**
- Consumes: `deviceFrameCatalogProvider` (Task 2), `perfectMatches`/`flexibleMatches` (Task 4), `WindowFrame` device fields (Task 5), `InspectorToggle`/`InspectorChipGroup`/`InspectorSectionLabel`/`InspectorSectionDivider`.
- Produces: `BackgroundTab({bool isDevice = false, Size recordingSize = Size.zero})`; a device-frame section rendered only when `isDevice`.

- [ ] **Step 1: Write the failing test**

```dart
// packages/screen_recorder/test/ui/background_tab_device_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/models/window_frame.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';
import 'package:screen_recorder/state/device_frame_catalog_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/tabs/background_tab.dart';

void main() {
  testWidgets('device section shows "Use device mockup" and toggles it on',
      (tester) async {
    debugSetDeviceFrameCatalog(const DeviceFrameCatalog([
      DeviceFrameEntry(
        id: 'iphone-16-pro', family: 'iPhone 16 Pro', kind: 'phone',
        screenWidth: 1206, screenHeight: 2622,
        colors: [
          DeviceFrameColorVariant(
            id: 'black', name: 'Black', swatch: Color(0xFF000000),
            portrait: DeviceFrameOrientationAsset(
              asset: 'a', bezelWidth: 1350, bezelHeight: 2760,
              screenRect: DeviceScreenRect(l: .05, t: .02, r: .95, b: .98)),
            landscape: DeviceFrameOrientationAsset(
              asset: 'b', bezelWidth: 2760, bezelHeight: 1350,
              screenRect: DeviceScreenRect(l: .02, t: .05, r: .98, b: .95))),
        ]),
    ]));
    addTearDown(() => debugSetDeviceFrameCatalog(null));

    final controller = EditorProjectController(
      initial: EditorProjectState.defaults()
          .copyWith(windowFrame: WindowFrame.none()),
    );
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => controller),
        deviceFrameCatalogProvider.overrideWith(
            (ref) async => (await loadDeviceFrameCatalog())),
      ],
      child: const MaterialApp(
        home: Scaffold(
          body: BackgroundTab(isDevice: true, recordingSize: Size(1206, 2622)),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Use device mockup'), findsOneWidget);
    // Toggle it on via the matched device's color chip.
    await tester.tap(find.text('Black').first);
    await tester.pump();
    expect(controller.current.windowFrame.deviceFrameId, 'iphone-16-pro');
  });

  testWidgets('no device section for non-device recordings', (tester) async {
    final controller = EditorProjectController(
      initial: EditorProjectState.defaults());
    await tester.pumpWidget(ProviderScope(
      overrides: [
        editorProjectControllerProvider.overrideWith((ref) => controller),
      ],
      child: const MaterialApp(
        home: Scaffold(body: BackgroundTab(isDevice: false)),
      ),
    ));
    await tester.pump();
    expect(find.text('Use device mockup'), findsNothing);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder && flutter test test/ui/background_tab_device_test.dart`
Expected: FAIL — `BackgroundTab` has no `isDevice`/`recordingSize` params.

- [ ] **Step 3: Write minimal implementation**

In `inspector_panel.dart`, change the `BackgroundTab` construction (line ~183):
```dart
        InspectorTab.background => BackgroundTab(
            isDevice: widget.isDevice,
            recordingSize: widget.videoSize,
          ),
```

In `background_tab.dart`:
1. Add imports:
```dart
import 'package:slipreel_engine/models/device_frame.dart';
import 'package:slipreel_engine/rendering/device_frame_matcher.dart';
import 'package:screen_recorder/state/device_frame_catalog_provider.dart';
```
2. Add fields + constructor params:
```dart
  const BackgroundTab({super.key, this.isDevice = false, this.recordingSize = Size.zero});
  final bool isDevice;
  final Size recordingSize;
```
3. Add device mutators in `_BackgroundTabState`:
```dart
  void _setDeviceColor(String deviceId, String colorId) => _mutateFrame(
        (f) => f.copyWith(deviceFrameId: deviceId, deviceFrameColor: colorId),
      );

  void _disableDeviceFrame() =>
      _mutateFrame((f) => f.copyWith(clearDeviceFrame: true));

  void _setAdjustSize(bool v) =>
      _mutateFrame((f) => f.copyWith(deviceFrameAdjustSize: v));
```
4. At the TOP of the `ListView` children in `build` (before `_wallpaperHeader()`), insert the device section when `widget.isDevice`:
```dart
        if (widget.isDevice) ...[
          _deviceFrameSection(frame),
          const InspectorSectionDivider(),
        ],
```
5. Add a `bool _flexible = false;` field and the section builder method:
```dart
  Widget _deviceFrameSection(WindowFrame frame) {
    final catalogAsync = ref.watch(deviceFrameCatalogProvider);
    return catalogAsync.maybeWhen(
      orElse: () => const SizedBox.shrink(),
      data: (catalog) {
        final enabled = frame.deviceFrameId != null;
        final entries = _flexible
            ? flexibleMatches(catalog, widget.recordingSize)
            : perfectMatches(catalog, widget.recordingSize);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const InspectorSectionLabel(label: 'Device frame'),
            const SizedBox(height: 8),
            InspectorToggle(
              label: 'Use device mockup',
              subtitle: 'Wrap the recording in a device mockup.',
              value: enabled,
              onChanged: (v) {
                if (!v) {
                  _disableDeviceFrame();
                } else {
                  // Turn on by selecting the first available match.
                  final list = entries.isNotEmpty
                      ? entries
                      : flexibleMatches(catalog, widget.recordingSize);
                  if (list.isNotEmpty && list.first.colors.isNotEmpty) {
                    _setDeviceColor(list.first.id, list.first.colors.first.id);
                  }
                }
              },
            ),
            if (enabled) ...[
              const SizedBox(height: 12),
              InspectorToggle(
                label: 'Adjust device size',
                subtitle: 'Stretch or shrink the mockup to match the recording.',
                value: frame.deviceFrameAdjustSize,
                onChanged: _setAdjustSize,
              ),
              const SizedBox(height: 12),
              InspectorChipGroup<bool>(
                items: const [false, true],
                labelOf: (b) => b ? 'Flexible' : 'Perfect',
                selected: _flexible,
                onSelected: (b) => setState(() => _flexible = b),
              ),
              const SizedBox(height: 12),
              for (final entry in entries) _deviceColorRow(frame, entry),
              if (entries.isEmpty)
                const Text('No matching device frames.',
                    style: TextStyle(color: kInspectorMuted, fontSize: 12)),
            ],
          ],
        );
      },
    );
  }

  Widget _deviceColorRow(WindowFrame frame, DeviceFrameEntry entry) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(entry.family,
              style: const TextStyle(color: kInspectorMuted, fontSize: 12)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final c in entry.colors)
                InspectorChip(
                  label: c.name,
                  selected: frame.deviceFrameId == entry.id &&
                      frame.deviceFrameColor == c.id,
                  onTap: () => _setDeviceColor(entry.id, c.id),
                ),
            ],
          ),
        ],
      ),
    );
  }
```

> Verify `InspectorToggle`'s exact named params (`label`, `subtitle`, `value`, `onChanged`) and `InspectorChip`'s (`label`, `selected`, `onTap`) by reading `inspector_widgets.dart`; adjust the call sites to match the real signatures.

- [ ] **Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder && flutter test test/ui/background_tab_device_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/inspector/inspector_panel.dart \
        packages/screen_recorder/lib/ui/widgets/inspector/tabs/background_tab.dart \
        packages/screen_recorder/test/ui/background_tab_device_test.dart
git commit -m "feat(device-frames): inspector device-frame controls (toggle, Perfect/Flexible, colors)"
```

---

### Task 10: Wire catalog + auto-enable in playback_screen

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

**Interfaces:**
- Consumes: `loadDeviceFrameCatalog` (Task 2), `windowFrameWithAutoDeviceFrame` (Task 4), PlaybackCanvas `deviceFrameCatalog` (Task 8), FrameCompositor `deviceFrameCatalog` (Task 7).

This task is wiring; its logic is already unit-tested in Task 4. No new test (verified via `flutter analyze` + the app smoke check in Task 11).

- [ ] **Step 1: Load the catalog during init**

In `_initializeVideo` (near where `_metadata` is loaded, ~line 632), add a field `DeviceFrameCatalog? _deviceFrameCatalog;` to the State class and load it:
```dart
      _deviceFrameCatalog = await loadDeviceFrameCatalog();
```
Add the import: `import 'package:slipreel_engine/models/device_frame.dart';` and `import 'package:slipreel_engine/rendering/device_frame_matcher.dart';`.

- [ ] **Step 2: Auto-enable before `replace(restored)`**

Just before `_projectController.replace(restored);` (~line 738), add:
```dart
      // Auto-select a device frame for device captures with no frame set
      // yet, when a Perfect (exact-resolution) match exists. Persist so a
      // later "off" sticks across opens (mirrors auto-zoom seeding).
      final catalog = _deviceFrameCatalog;
      if (catalog != null &&
          _metadata != null &&
          _metadata!.isDeviceCapture &&
          restored.windowFrame.deviceFrameId == null) {
        final recording = Size(
          _metadata!.widthPx.toDouble(),
          _metadata!.heightPx.toDouble(),
        );
        final nextFrame = windowFrameWithAutoDeviceFrame(
          current: restored.windowFrame,
          catalog: catalog,
          recording: recording,
        );
        if (nextFrame.deviceFrameId != restored.windowFrame.deviceFrameId) {
          restored = restored.copyWith(windowFrame: nextFrame);
          await _projectStore.save(restored);
        }
      }
```

- [ ] **Step 3: Pass the catalog to PlaybackCanvas**

At the `PlaybackCanvas(...)` construction (search for `PlaybackCanvas(`), add:
```dart
      deviceFrameCatalog: _deviceFrameCatalog,
```

- [ ] **Step 4: Pass the catalog to FrameCompositor (export)**

At the `FrameCompositor(...)` construction (near line ~1730, the export path), add:
```dart
        deviceFrameCatalog: _deviceFrameCatalog,
```

- [ ] **Step 5: Verify it analyzes + existing tests pass**

Run: `cd packages/screen_recorder && flutter analyze lib/ui/screens/playback_screen.dart && flutter test`
Expected: no new analyze errors; tests pass.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat(device-frames): load catalog, auto-enable on open, thread to canvas+export"
```

---

### Task 11: Declare assets, populate Apple art, end-to-end verify (release-gated)

**Files:**
- Modify: `packages/screen_recorder/pubspec.yaml`
- Create (generated): `packages/screen_recorder/assets/device_frames/**` + `manifest.json`

> ⚠️ **Release gate:** this task pulls Apple Design Resources into the repo. Per the spec, the resulting build must **not** be released to users until Apple sign-off is obtained. The code from Tasks 1–10 is fully functional without it (empty catalog → no device section, no auto-enable).

- [ ] **Step 1: Declare the asset directory**

In `packages/screen_recorder/pubspec.yaml`, under `flutter: assets:` (after the wallpaper lines ~115), add:
```yaml
    - assets/device_frames/
    - assets/device_frames/manifest.json
```
(Subdirectories per device are added by the generator; Flutter needs each leaf dir listed OR the generator can append them. For v1, after running Step 2, list each generated `assets/device_frames/<id>/` directory, or use a glob tool. Simplest: after Step 2, run `ls -d packages/screen_recorder/assets/device_frames/*/` and add each as its own `- assets/device_frames/<id>/` line.)

- [ ] **Step 2: Run the extractor**

Run: `python3 tool/device_frames/extract.py`
Expected: downloads the DMGs, writes `packages/screen_recorder/assets/device_frames/<id>/*.png` and `manifest.json`, prints `wrote N device entries`.

- [ ] **Step 3: Add each generated device dir to pubspec**

Run: `ls -d packages/screen_recorder/assets/device_frames/*/`
Add each printed directory as an asset line in `pubspec.yaml` (see Step 1).

- [ ] **Step 4: Build + smoke-verify in the app**

Run: `cd packages/screen_recorder && flutter run -d macos` (or the project's run skill).
Verify manually:
1. Open an iPhone/iPad device recording → device frame auto-appears (Perfect match), inspector Background tab shows the device section with the matched model + colors.
2. Toggle "Use device mockup" off/on; switch colors; toggle "Adjust device size"; switch Perfect/Flexible — preview updates live.
3. Open a normal (non-device) recording → no device section; behavior unchanged.
4. Export the device recording → the MP4 shows the same bezel as the preview (preview == export).

- [ ] **Step 5: Commit (assets + pubspec)**

```bash
git add packages/screen_recorder/pubspec.yaml packages/screen_recorder/assets/device_frames/
git commit -m "feat(device-frames): bundle Apple bezel assets + manifest (release-gated on Apple sign-off)"
```

---

## Self-Review

**Spec coverage:**
- §3 feasibility / extraction → Task 6 (script) + Task 11 (run). ✓
- §4 architecture (catalog in engine, shared by both compositors) → Tasks 1–4, 7, 8. ✓
- §5 compositing model (video-in-cutout + bezel on top, suppress chrome, inside zoom) → Task 7 (export), Task 8 (preview). ✓
- §6 data model (WindowFrame fields + manifest) → Task 5, Task 1. ✓
- §7 asset pipeline → Task 6 + Task 11. ✓
- §8 sizing/matching (Perfect/Flexible, adjust size, auto-enable) → Task 3 (layout), Task 4 (match/auto), Task 9 (UI), Task 10 (wire). ✓
- §9 risks (license gate) → called out in Task 6, Task 11. ✓
- §10 testing (unit + golden/pixel) → Tasks 1–9 each ship tests; Task 7 pixel-checks compose; Task 8 widget-checks placement. ✓
- §11 out-of-scope → not implemented (correct). ✓

**Placeholder scan:** No TBD/TODO. Two explicit "verify the real signature in the file" notes (Task 7 `_SceneMotionSignal` type; Task 9 `InspectorToggle`/`InspectorChip` params) — these are real local-symbol confirmations, with the surrounding code complete.

**Type consistency:** `DeviceFrameLayout` fields (`canvasSize`/`bezelRect`/`screenRect`/`videoRect`) are consistent across Tasks 3, 7, 8. `windowFrameWithAutoDeviceFrame`/`autoSelectDeviceFrame` names consistent (Task 4 → Task 10). `deviceFrameId`/`deviceFrameColor`/`deviceFrameAdjustSize` + `clearDeviceFrame` consistent (Task 5 → 4, 7, 8, 9). `deviceFrameCatalog` param consistent (Tasks 7, 8, 10). `bezelImageLoaderOverride` only in Task 7.

**Note on Task ordering:** Task 4 depends on Task 5's `WindowFrame` fields — implement Task 5 before Task 4 (or together). All other tasks are in dependency order.
