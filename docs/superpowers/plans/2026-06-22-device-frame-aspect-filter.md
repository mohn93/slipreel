# Device-Frame Aspect Compatibility Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the device-frame picker offer only frames whose form factor (phone/tablet) matches the recording's native aspect ratio, so a tall iPhone recording never lists iPad frames (and vice-versa).

**Architecture:** A pure classification rule in the engine (`device_frame_matcher.dart`) buckets a recording as phone or tablet by its landscape-normalized aspect (split at 1.6), then filters catalog entries by their existing `kind` field. The picker's "Flexible" list consumes this filter; both render paths (preview + export) gain a non-destructive guard so a legacy/persisted incompatible frame simply doesn't render.

**Tech Stack:** Dart / Flutter; `slipreel_engine` pure engine package (painting-only); `flutter_test`.

## Global Constraints

- **Recording aspect only.** Compatibility is judged against the recording's native pixel size. The output/export aspect ratio is never an input to this rule.
- **Reuse the existing `kind` field** (`'phone' | 'tablet'`) on `DeviceFrameEntry`. No manifest/asset/data changes.
- **Classification split = `1.6`**, on aspect normalized to landscape (`max(w,h)/min(w,h)`); `≤ 1.6` ⇒ tablet, `> 1.6` ⇒ phone. Degenerate size (any dimension `≤ 0`) ⇒ unknown ⇒ treated as compatible (do not over-filter).
- **Preview must equal export.** Both render guards use the identical predicate.
- **Do NOT run `dart format`** on touched files (pinned formatter reflows unrelated lines — see project memory). Match surrounding style by hand; verify with `flutter analyze` + `flutter test`.

---

### Task 1: Engine — form-factor classification, compatibility predicate, and picker filter

**Files:**
- Modify: `packages/slipreel_engine/lib/rendering/device_frame_matcher.dart` (add classification + predicate; rewrite `flexibleMatches`; delete the resolved `TODO(device-frames)` block at lines 23–32)
- Test: `packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart` (add new tests; replace the obsolete "returns all" test at lines 48–57)

**Interfaces:**
- Consumes: existing `DeviceFrameEntry.kind`, `DeviceFrameCatalog.entries`, `recordingIsPortrait(Size)`.
- Produces (relied on by Task 2 and the existing `device_tab.dart`):
  - `enum RecordingFormFactor { phone, tablet }`
  - `const double kPhoneTabletAspectSplit = 1.6;`
  - `RecordingFormFactor? recordingFormFactor(Size recording)` — null on degenerate size.
  - `bool deviceFrameCompatible(DeviceFrameEntry entry, Size recording)` — true on degenerate size.
  - `List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording)` — now returns only same-kind entries.

- [ ] **Step 1: Replace the obsolete `flexibleMatches returns all` test and add new failing tests**

In `packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart`, **delete** the entire existing test block (lines 48–57):

```dart
  test('flexibleMatches returns all catalog entries (pass-through, no filter)', () {
    // Pin the v1 behavior: flexibleMatches must return every entry in the
    // catalog so the Flexible picker shows all device options. If a future
    // kind/orientation filter is added, this test catches a regression to
    // empty (e.g., filtering a phone recording against a tablet-only catalog).
    final allIds = _catalog.entries.map((e) => e.id).toSet();
    final result = flexibleMatches(_catalog, const Size(1206, 2622));
    expect(result.map((e) => e.id).toSet(), equals(allIds));
    expect(result.length, _catalog.entries.length);
  });
```

and in its place add (the `_catalog` already contains `iphone-16-pro` kind `phone` and `ipad-pro-11` kind `tablet`):

```dart
  group('recordingFormFactor', () {
    test('iPhone resolutions classify as phone (both orientations)', () {
      expect(recordingFormFactor(const Size(1206, 2622)),
          RecordingFormFactor.phone); // 2.17
      expect(recordingFormFactor(const Size(2622, 1206)),
          RecordingFormFactor.phone); // landscape, same
      expect(recordingFormFactor(const Size(1334, 750)),
          RecordingFormFactor.phone); // 16:9 = 1.78
    });

    test('iPad resolutions classify as tablet (both orientations)', () {
      expect(recordingFormFactor(const Size(1668, 2420)),
          RecordingFormFactor.tablet); // 1.45
      expect(recordingFormFactor(const Size(2048, 1536)),
          RecordingFormFactor.tablet); // 1.33
      expect(recordingFormFactor(const Size(1488, 2266)),
          RecordingFormFactor.tablet); // iPad mini 1.52
    });

    test('split boundary at 1.6 is inclusive for tablet', () {
      expect(recordingFormFactor(const Size(1600, 1000)),
          RecordingFormFactor.tablet); // exactly 1.6
      expect(recordingFormFactor(const Size(1601, 1000)),
          RecordingFormFactor.phone); // just over 1.6
    });

    test('degenerate size returns null', () {
      expect(recordingFormFactor(Size.zero), isNull);
      expect(recordingFormFactor(const Size(100, 0)), isNull);
    });
  });

  group('deviceFrameCompatible', () {
    final phone = _catalog.entryById('iphone-16-pro')!;
    final tablet = _catalog.entryById('ipad-pro-11')!;

    test('phone entry matches phone recording only', () {
      expect(deviceFrameCompatible(phone, const Size(1206, 2622)), isTrue);
      expect(deviceFrameCompatible(phone, const Size(1668, 2420)), isFalse);
    });

    test('tablet entry matches tablet recording only', () {
      expect(deviceFrameCompatible(tablet, const Size(1668, 2420)), isTrue);
      expect(deviceFrameCompatible(tablet, const Size(1206, 2622)), isFalse);
    });

    test('degenerate size is compatible with anything', () {
      expect(deviceFrameCompatible(phone, Size.zero), isTrue);
      expect(deviceFrameCompatible(tablet, Size.zero), isTrue);
    });
  });

  group('flexibleMatches (kind-filtered)', () {
    test('phone recording yields only phone entries', () {
      final r = flexibleMatches(_catalog, const Size(1206, 2622));
      expect(r.map((e) => e.id), ['iphone-16-pro']);
    });

    test('iPad recording yields only tablet entries', () {
      final r = flexibleMatches(_catalog, const Size(1668, 2420));
      expect(r.map((e) => e.id), ['ipad-pro-11']);
    });

    test('degenerate size yields all entries (no filtering)', () {
      final r = flexibleMatches(_catalog, Size.zero);
      expect(r.map((e) => e.id).toSet(),
          _catalog.entries.map((e) => e.id).toSet());
    });
  });
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_matcher_test.dart`
Expected: FAIL — compile errors (`recordingFormFactor`, `RecordingFormFactor`, `deviceFrameCompatible` undefined).

- [ ] **Step 3: Add the classification + predicate to the matcher**

In `packages/slipreel_engine/lib/rendering/device_frame_matcher.dart`, immediately after the `recordingIsPortrait` function (line 7), insert:

```dart
/// Device form factor inferred from a recording's pixel size, by aspect
/// ratio normalised to landscape (orientation-independent).
enum RecordingFormFactor { phone, tablet }

/// Landscape-aspect boundary separating tablet-like (≤) from phone-like (>)
/// recordings. Every Apple iPad is ≤ 1.52; every iPhone is ≥ 1.78.
const double kPhoneTabletAspectSplit = 1.6;

/// Classifies [recording] as a phone or tablet by its landscape-normalised
/// aspect ratio. Returns null for a degenerate (zero/negative) size so
/// callers can choose not to filter before the size is known.
RecordingFormFactor? recordingFormFactor(Size recording) {
  final w = recording.width;
  final h = recording.height;
  if (w <= 0 || h <= 0) return null;
  final landscapeAspect = w >= h ? w / h : h / w;
  return landscapeAspect <= kPhoneTabletAspectSplit
      ? RecordingFormFactor.tablet
      : RecordingFormFactor.phone;
}

/// Whether [entry]'s kind matches the recording's inferred form factor.
/// A degenerate [recording] size is treated as compatible (do not
/// over-filter before the size is known).
bool deviceFrameCompatible(DeviceFrameEntry entry, Size recording) {
  final ff = recordingFormFactor(recording);
  if (ff == null) return true;
  final wantTablet = ff == RecordingFormFactor.tablet;
  return (entry.kind == 'tablet') == wantTablet;
}
```

- [ ] **Step 4: Rewrite `flexibleMatches` to filter by kind**

In the same file, **replace** the doc comment + function at lines 23–34:

```dart
/// Returns ALL catalog entries, regardless of kind or orientation.
///
/// This is the v1 "Flexible" picker behavior: show every device and let
/// the renderer scale the bezel to fit the recording. No filtering is
/// applied intentionally — the [recording] parameter is accepted for API
/// symmetry with [perfectMatches] and may be used in a future revision.
///
/// TODO(device-frames): once the Flexible picker design is finalised,
/// consider filtering by kind (phone/tablet) and orientation to reduce
/// the list length; add a regression test if you do.
List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording) =>
    List<DeviceFrameEntry>.from(c.entries);
```

with:

```dart
/// Returns catalog entries whose form factor is compatible with the
/// recording (see [deviceFrameCompatible]): phones for a phone-shaped
/// recording, tablets for a tablet-shaped one. A degenerate [recording]
/// size yields every entry (no filtering).
///
/// This is the "Flexible" picker behavior: any same-kind device, scaled
/// by the renderer to fit — as opposed to [perfectMatches]' exact match.
List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording) =>
    [for (final e in c.entries) if (deviceFrameCompatible(e, recording)) e];
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `cd packages/slipreel_engine && flutter test test/rendering/device_frame_matcher_test.dart`
Expected: PASS (all groups green).

- [ ] **Step 6: Analyze and commit**

Run: `cd packages/slipreel_engine && flutter analyze lib/rendering/device_frame_matcher.dart`
Expected: No issues.

```bash
git add packages/slipreel_engine/lib/rendering/device_frame_matcher.dart \
        packages/slipreel_engine/test/rendering/device_frame_matcher_test.dart
git commit -m "feat(device-frames): filter picker by recording form factor (phone/tablet)"
```

---

### Task 2: Non-destructive render guard (export + preview)

**Files:**
- Modify: `packages/slipreel_engine/lib/export/frame_compositor.dart` (`_resolveDeviceFramePlan`, ~lines 105–123)
- Modify: `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart` (device-frame branch, ~lines 708–724)
- Test: `packages/slipreel_engine/test/export/frame_compositor_device_test.dart` (add one guard test)

**Interfaces:**
- Consumes: `deviceFrameCompatible(DeviceFrameEntry, Size)` from Task 1. Both files already import `device_frame_matcher.dart` (they use `recordingIsPortrait`), so no new import is required.
- Produces: no new public API — behavioral guard only.

- [ ] **Step 1: Write the failing export-guard test**

In `packages/slipreel_engine/test/export/frame_compositor_device_test.dart`, add this test inside `main()` after the existing `'device-frame compose: ...'` test (the file's `_catalog()` defines a single `kind: 'phone'` entry `test-phone`):

```dart
  test('device-frame plan is null when entry kind is incompatible '
      'with the recording form factor', () {
    // test-phone is a phone entry; a 200x150 (1.33 landscape) recording is
    // tablet-shaped, so the persisted phone frame must not render.
    final state = EditorProjectState.defaults().copyWith(
      windowFrame: WindowFrame.none()
          .copyWith(deviceFrameId: 'test-phone', deviceFrameColor: 'black'),
    );
    final comp = FrameCompositor(
      projectState: state,
      cursorRecording: CursorRecording(),
      metadata: RecordingMetadata(
        isPureSource: true,
        recordedAt: DateTime.fromMillisecondsSinceEpoch(0),
        widthPx: 200,
        heightPx: 150,
        fps: 60,
        isDeviceCapture: true,
      ),
      videoSize: const Size(200, 150),
      fps: 60,
      deviceFrameCatalog: _catalog(),
    );
    expect(comp.deviceFramePlan, isNull);
  });
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_device_test.dart`
Expected: FAIL — `deviceFramePlan` is non-null (guard not yet added).

- [ ] **Step 3: Add the export guard**

In `packages/slipreel_engine/lib/export/frame_compositor.dart`, in `_resolveDeviceFramePlan`, add the compatibility check right after the `entry == null` guard (currently line 110):

```dart
    final entry = catalog.entryById(id);
    if (entry == null) return null;
    if (!deviceFrameCompatible(entry, videoSize)) return null;
    final color = entry.colorById(projectState.windowFrame.deviceFrameColor ?? '')
        ?? (entry.colors.isEmpty ? null : entry.colors.first);
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd packages/slipreel_engine && flutter test test/export/frame_compositor_device_test.dart`
Expected: PASS (new guard test + existing compose test both green).

- [ ] **Step 5: Mirror the guard in the live preview**

In `packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart`, **replace** the device-frame resolution block (currently lines 708–724):

```dart
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

with (adds the `deviceFrameCompatible` guard so an incompatible persisted frame falls back to normal framing — keeping preview == export):

```dart
    final dfId = currentFrame.deviceFrameId;
    final dfCatalog = widget.deviceFrameCatalog;
    if (dfId != null && dfCatalog != null) {
      final entry = dfCatalog.entryById(dfId);
      if (entry != null && deviceFrameCompatible(entry, videoSize)) {
        final color = entry.colorById(currentFrame.deviceFrameColor ?? '')
            ?? (entry.colors.isNotEmpty ? entry.colors.first : null);
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
    }
```

- [ ] **Step 6: Analyze both packages and run the affected suites**

Run: `cd packages/slipreel_engine && flutter analyze lib/export/frame_compositor.dart && flutter test test/export/`
Expected: No analyzer issues; all export tests pass (including the device parity test).

Run: `cd packages/screen_recorder && flutter analyze lib/ui/widgets/zoom/playback_canvas.dart`
Expected: No issues.

- [ ] **Step 7: Commit**

```bash
git add packages/slipreel_engine/lib/export/frame_compositor.dart \
        packages/slipreel_engine/test/export/frame_compositor_device_test.dart \
        packages/screen_recorder/lib/ui/widgets/zoom/playback_canvas.dart
git commit -m "feat(device-frames): don't render a frame whose kind mismatches the recording"
```

---

### Task 3: Full-suite verification

**Files:** none (verification only).

- [ ] **Step 1: Run the full engine suite**

Run: `cd packages/slipreel_engine && flutter test`
Expected: All pass. (Note: a known gif `ffmpeg -9` flake can appear under parallel load — if a single gif test fails, re-run `flutter test test/export/` in isolation to confirm it's the pre-existing flake, not a regression.)

- [ ] **Step 2: Run the full recorder suite**

Run: `cd packages/screen_recorder && flutter test`
Expected: All pass.

- [ ] **Step 3: Manual runtime check (requires local Apple bezel assets)**

With the local device-frame assets present (`packages/screen_recorder/assets/device_frames/` + the pubspec declarations), run the app, open a **tall iPhone** recording, open the Device tab, switch the picker to **Flexible**: the list shows only iPhone families (no iPads). Open a **4:3 iPad** recording: Flexible shows only iPads. Confirm an iPhone recording that previously had an iPad frame forced on it now renders with normal framing (no stretched iPad bezel) in both preview and a short export.

> If assets are not present (inert/ship-gated build), this step is N/A — the catalog is empty and the Device tab is hidden; the unit tests fully cover the logic.

---

## Notes

- **`device_tab.dart` needs no change.** It already calls `flexibleMatches`/`perfectMatches`, so it inherits the filter. Its "Use device mockup" enable path falls back to `flexibleMatches`, which is now kind-filtered — an improvement (it can no longer enable a cross-kind frame), not a regression.
- **No new widget test.** The picker contents are fully determined by the matcher, which is unit-tested in Task 1; a widget test would only re-assert the same logic through more machinery (YAGNI). Manual runtime check in Task 3 covers the integrated UI.
