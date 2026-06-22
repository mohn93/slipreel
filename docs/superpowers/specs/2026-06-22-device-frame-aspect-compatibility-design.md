# Device-Frame Aspect Compatibility Filter (#9 follow-up) — Design

- **Date:** 2026-06-22
- **Issue:** #9 — Device frames (follow-up enhancement)
- **Status:** Approved (design); implementation pending
- **Builds on:** device-frames feature merged to main (`defd79da`); spec `2026-06-21-device-frames-design.md`

## 1. Goal

Stop the device-frame picker from offering frames whose form factor doesn't match the
recording. Concretely: when you record a tall iPhone, **don't list iPad frames** (a 4:3
iPad bezel wrapped around tall phone video looks wrong); when you record a 4:3 iPad,
**don't list iPhone frames**. Compatibility is judged purely against the **original
recording's native aspect ratio** — the output/export aspect ratio plays no part.

This finalises the standing `TODO(device-frames)` in `device_frame_matcher.dart` to
"filter by kind (phone/tablet)".

## 2. Decisions (from brainstorming)

| Question | Decision |
| --- | --- |
| What aspect drives the rule? | The **original recording's native aspect ratio**. The output/canvas/export aspect is irrelevant. |
| Scope | **General compatibility** — filter both directions (hide tablets for phone recordings *and* phones for tablet recordings), not iPad-only. |
| Classification primitive | Reuse the existing `DeviceFrameEntry.kind` (`'phone' \| 'tablet'`). No new asset/manifest data. |
| Recording classification | By aspect normalised to landscape `max(w,h)/min(w,h)`, split at **1.6**: `≤ 1.6` ⇒ tablet, `> 1.6` ⇒ phone. |
| Picker behaviour | "Flexible" mode lists **same-kind** devices (was: all). "Perfect" mode stays exact-resolution match. |
| Already-applied incompatible frame | **Non-destructive render guard**: if a persisted/legacy frame's kind doesn't match the recording, don't render the bezel (treat as off). The stored selection is left untouched. |

### Why 1.6

| Device | Landscape aspect | Classified |
| --- | --- | --- |
| iPhone 15/16 (19.5:9) | 2.16 | phone |
| iPhone SE / 8 (16:9) | 1.78 | phone |
| iPad mini | 1.52 | tablet |
| iPad Pro 11" / Air | 1.43–1.45 | tablet |
| iPad 12.9" / classic 4:3 | 1.33 | tablet |

Every Apple phone is ≥ 1.78 and every iPad is ≤ 1.52, so a 1.6 split separates them with
comfortable margin on both sides.

## 3. The rule (engine, pure)

New code in `packages/slipreel_engine/lib/rendering/device_frame_matcher.dart`:

```dart
/// Device form factor inferred from a recording's pixel size, by aspect
/// ratio normalised to landscape (orientation-independent). Returns null
/// when the size is empty/degenerate (caller should not filter).
enum RecordingFormFactor { phone, tablet }

const double kPhoneTabletAspectSplit = 1.6;

RecordingFormFactor? recordingFormFactor(Size recording) {
  final w = recording.width, h = recording.height;
  if (w <= 0 || h <= 0) return null;
  final landscapeAspect = (w >= h ? w / h : h / w);
  return landscapeAspect <= kPhoneTabletAspectSplit
      ? RecordingFormFactor.tablet
      : RecordingFormFactor.phone;
}

/// True when [entry]'s kind matches the recording's inferred form factor.
/// Unknown form factor (degenerate size) ⇒ compatible (don't over-filter).
bool deviceFrameCompatible(DeviceFrameEntry entry, Size recording) {
  final ff = recordingFormFactor(recording);
  if (ff == null) return true;
  final wantTablet = ff == RecordingFormFactor.tablet;
  return (entry.kind == 'tablet') == wantTablet;
}
```

`flexibleMatches` changes from "return everything" to "return same-kind devices":

```dart
List<DeviceFrameEntry> flexibleMatches(DeviceFrameCatalog c, Size recording) =>
    [for (final e in c.entries) if (deviceFrameCompatible(e, recording)) e];
```

`perfectMatches` is **unchanged** — an exact-resolution match is inherently same-kind.
`autoSelectDeviceFrame` / `windowFrameWithAutoDeviceFrame` are **unchanged** — they only
ever pick perfect matches, so they can never auto-enable an incompatible frame.

## 4. Changes by file

| File | Change |
| --- | --- |
| `slipreel_engine/.../rendering/device_frame_matcher.dart` | Add `RecordingFormFactor`, `kPhoneTabletAspectSplit`, `recordingFormFactor`, `deviceFrameCompatible`; rewrite `flexibleMatches` to filter by kind; delete the now-resolved `TODO(device-frames)`. |
| `screen_recorder/.../inspector/tabs/device_tab.dart` | No logic change needed — it already calls `flexibleMatches`/`perfectMatches`. Update the "Flexible/Perfect" helper copy if useful (e.g. Flexible = "all compatible devices"). The "Use device mockup" enable path already falls back to `flexibleMatches`, which is now safe. |
| `screen_recorder/.../zoom/playback_canvas.dart` (preview, ~L710) | Render guard: after resolving `entry`, bail out of the device-frame branch when `!deviceFrameCompatible(entry, videoSize)`. |
| `slipreel_engine/.../export/frame_compositor.dart` (`_resolveDeviceFramePlan`, ~L109) | Same render guard: return `null` when `!deviceFrameCompatible(entry, videoSize)`. Keeps preview == export. |

## 5. Edge cases

- **Degenerate recording size** (`Size.zero`, size not yet known): `recordingFormFactor`
  returns null ⇒ `deviceFrameCompatible` returns true ⇒ no filtering. The picker shows
  everything rather than hiding all frames before the size is known.
- **Empty filtered list** (catalog has no same-kind device): the picker shows the existing
  "No matching device frames." message; the enable toggle's `flexibleMatches` fallback is
  also empty, so toggling on is a no-op (no crash).
- **Catalog absent** (ship-gated/inert build): unchanged — empty catalog, no Device tab.
- **Square-ish future device** exactly at 1.6: classified as tablet (`≤ 1.6` is inclusive).
  No current Apple device sits there; documented for determinism.

## 6. Testing

Pure unit tests in `slipreel_engine` (matcher is dependency-free):

- `recordingFormFactor`: phone resolutions (iPhone 16 portrait & landscape, 16:9 iPhone),
  iPad resolutions (12.9", 11", mini — portrait & landscape) classify correctly; the 1.6
  boundary is exercised from both sides; `Size.zero` ⇒ null.
- `deviceFrameCompatible`: phone-entry × phone-recording = true, phone-entry ×
  iPad-recording = false, and the two tablet symmetric cases; degenerate size ⇒ true.
- `flexibleMatches`: with a mixed catalog (phones + tablets), a phone recording yields only
  phone entries and an iPad recording only tablet entries; degenerate size yields all.
- `perfectMatches` regression: still exact-resolution, unaffected.

No new widget tests required (the tab already renders whatever the matcher returns); a light
optional widget test can assert the picker list count shrinks for a cross-kind recording.

## 7. Non-goals / out of scope

- Output/export aspect ratio gating (explicitly excluded — recording aspect only).
- Any change to bezel rendering, layout, corner-radius, or asset extraction.
- A user-facing "show everything anyway" override (deliberate cross-kind mockups). If ever
  wanted, it's a later additive toggle; YAGNI for v1.
- Per-model (within-kind) aspect refinement — kind granularity is sufficient.
