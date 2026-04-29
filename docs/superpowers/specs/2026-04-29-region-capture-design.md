# Region Capture — Design Spec

**Date:** 2026-04-29
**Status:** Approved (pending implementation plan)

## Goal

Add a third tab to the source picker — **Region** — that lets the user draw a rectangle anywhere on the desktop with a full-screen overlay, fine-tune it with resize handles + a floating toolbar, and record only that sub-region of the display via `SCStreamConfiguration.sourceRect`.

## Background

The source picker redesign (2026-04-28) shipped Windows and Screens tabs and explicitly deferred Region. `RecordingSource.area` already exists in the Dart enum; `SCStream` supports sub-rectangle capture via `SCStreamConfiguration.sourceRect`. What's missing is the selection UI (overlay + toolbar) and the wiring through the existing live-recording pipeline.

## Non-goals

- Cross-display rectangles (a region must live entirely on one display).
- Aspect-ratio snap (freeform only in v1; shift-key snap is a follow-up).
- Cross-launch persistence of the last region (selection lives in screen state, gone on relaunch).
- Preset regions ("16:9 1080p", etc.).
- Windows / Linux platforms (those plugins remain stubs).

## Architecture

```
+-------------------------------------+
|  Flutter UI                         |
|  - RecordingScreen (Region tab)     |
|  - RegionTabContent (empty / recap) |
+-------------------+-----------------+
                    | platform interface
                    | (selectRegion, startLiveRecording {region})
                    v
+-------------------------------------+
|  ScreenRecorderMacosPlugin          |
|  - RegionSelector  (NSWindow x N)   |
|  - RegionToolbar   (NSWindow)       |
|  - ScreenCaptureManager.startCapture|
+-------------------------------------+
```

- **Picker UI** → invokes `selectRegion()`, awaits the result, stores it as the current selection.
- **Native overlay** is owned entirely by Swift — no Flutter rendering during selection.
- **Recording** is the existing live pipeline plus `config.sourceRect` and the chosen display's filter.

## Native side (Swift)

### `RegionSelector.swift`

New module. Owns one transparent `NSWindow` per `NSScreen` at `level: .screenSaver`. Each window hosts a `RegionSelectorView` (custom `NSView`) responsible for drawing and mouse handling.

Public API:

```swift
struct RegionSelection {
  let displayId: CGDirectDisplayID
  let x: Int
  let y: Int           // top-left in display-pixel coordinates
  let widthPx: Int
  let heightPx: Int
}

actor RegionSelector {
  static let shared = RegionSelector()
  func selectRegion() async -> RegionSelection?  // nil on cancel
}
```

`selectRegion()` is idempotent — concurrent calls return the same in-flight Future. Internally:
1. Mini-aturizes the picker app window so it doesn't occlude the desktop.
2. Creates one overlay `NSWindow` per `NSScreen` and one mini toolbar window.
3. Becomes first responder for keyboard (Esc → cancel).
4. Awaits the user's Start (returns selection) or Cancel/Esc (returns nil).
5. Tears down all windows and restores the picker app.

### `RegionSelectorView` (NSView subclass)

Owns a state machine:

```swift
enum RegionSelectionState {
  case idle                    // dimmed, no rect
  case drawing(start: NSPoint, current: NSPoint)
  case selected(rect: NSRect)  // 8 handles + toolbar visible
  case resizing(handle: ResizeHandle, originalRect: NSRect, anchor: NSPoint)
  case moving(originalRect: NSRect, dragStart: NSPoint)
  case cancelled
  case confirmed(rect: NSRect)
}

enum ResizeHandle { case nw, n, ne, e, se, s, sw, w }
```

Mouse handling:
- `mouseDown` on a handle → `resizing`.
- `mouseDown` inside `selected` rect (no handle) → `moving`.
- `mouseDown` elsewhere → `drawing` (replaces any prior selection).
- `mouseDragged` updates the rect (with min-size 50×50, clipped to display bounds).
- `mouseUp` from `drawing` → `selected` (if rect ≥ 50×50, else back to `idle`).
- Esc key → `cancelled`.

Drawing:
- Dim layer: 40% black overlay covering the whole view *minus* the selected rect (clear hole).
- Rect outline: 1pt purple (`#6C63FF`) stroke.
- Resize handles: 12pt purple squares centered on each corner + edge midpoint.
- Live readout: `"\(width) × \(height)"` in monospace, drawn near the cursor while `drawing` or `resizing`.

Cursor:
- Hover over a handle → resize cursor (`NSCursor.resizeLeftRight`, `resizeUpDown`, etc.).
- Hover inside the rect → `NSCursor.openHand`.
- Drag → `NSCursor.closedHand`.
- Otherwise → `NSCursor.crosshair`.

### `RegionToolbar.swift`

Small floating `NSWindow` (~140 × 36pt) hosting two buttons: **Start** (filled, purple) and **Cancel** (outlined). Anchors to the bottom-right corner of the selected rect with an 8pt gap. Clamps to the host display's bounds (if rect is at a corner, toolbar moves inside the rect).

Visible only in the `selected` / `resizing` / `moving` states. Hidden during `drawing` so it doesn't cover the live readout.

### `ScreenCaptureManager` extension

`startCapture` gains a region path. New parameter `region: RegionSelection?`. When `region != nil`:

```swift
let display = content.displays.first { $0.displayID == region.displayId }!
contentFilter = SCContentFilter(display: display, excludingWindows: [])
config.sourceRect = CGRect(x: region.x, y: region.y, width: region.widthPx, height: region.heightPx)
config.width = region.widthPx
config.height = region.heightPx
```

Encoder dimensions = the region's pixel size. No need to query `captureDimensions` for the region path — the rect is already authoritative.

### Plugin dispatch

`ScreenRecorderMacosPlugin.handle` adds two hooks:
- New method `selectRegion` → calls `RegionSelector.shared.selectRegion()`, returns either a `[String: Any]` (`displayId`, `x`, `y`, `width`, `height`) or `nil`.
- `startLiveRecording` accepts an optional `region: [String: Any]?` argument. When `source == "area"` and `region` is present, plumbs it through to `ScreenCaptureManager.startCapture(region:)`.

## Dart side

### Platform interface

New value type:

```dart
class RegionSelection {
  final String displayId;
  final int x;
  final int y;
  final int widthPx;
  final int heightPx;
  // toMap, fromMap
}
```

New abstract method on `ScreenRecorderPlatform`:

```dart
Future<RegionSelection?> selectRegion() {
  throw UnimplementedError('selectRegion() has not been implemented.');
}
```

`startLiveRecording` gains an optional `RegionSelection? region` parameter (only sent when `settings.source == RecordingSource.area`).

### Method-channel adapter

`MethodChannelScreenRecorderMacos.selectRegion` calls `_recordingChannel.invokeMapMethod` and returns `null` if the result is null, else `RegionSelection.fromMap(raw)`.

`startLiveRecording` serializes the optional region into the args map under key `'region'` when present.

### State

`RecordingState` gains `final RegionSelection? selectedRegion`. `RecordingController.selectSource` is extended:

```dart
void selectSource({
  required RecordingSource? kind,
  required String? id,
  RegionSelection? region,  // only used when kind == area
});
```

Tab switch (clearSelection in `copyWith`) also nulls `selectedRegion`.

`startRecording` reads `state.selectedRegion` and forwards it to `startLiveRecording`.

### UI

**File structure:**
- `lib/ui/widgets/source_picker/region_tab_content.dart` — empty state + recap card + "Draw a region" / "Redraw" button.
- `lib/ui/screens/recording_screen.dart` — adds the third segment to `SegmentedButton<_Tab>`, routes `_Tab.region` to `RegionTabContent`.

**Region tab visual states:**
- **Empty** (no `selectedRegion`):
  - Centered icon (`Icons.crop`) + headline "Draw a region of your screen" + subline "Click anywhere to begin".
  - Primary button: "Draw a region".
  - Bottom bar shows "Draw a region first" placeholder; Record disabled.
- **Selected** (`selectedRegion != null`):
  - Recap card: `1280 × 720` headline, `on Built-in Display` subline, `Redraw` text button.
  - Bottom bar shows the same string; Record enabled.

**Triggering the overlay:**
1. User taps "Draw a region" / "Redraw".
2. UI calls `ScreenRecorderPlatform.instance.selectRegion()`.
3. While the future is pending, the button shows a spinner.
4. On result:
   - `null` → state unchanged.
   - `RegionSelection` → `selectSource(kind: RecordingSource.area, id: region.displayId, region: region)`.

## Recording-pipeline integration

The only change to the live recording pipeline is the new `region` parameter and the sub-rect filter inside `ScreenCaptureManager.startCapture`. `LiveRecordingWriter`, `VideoToolboxEncoder`, audio capture, cursor tracking, perf instrumentation, sidecar metadata — all unchanged.

For a region source, the recorded video's `widthPx × heightPx` come from the region itself, which the native side already knows authoritatively. `RecordingResult.width/height` carry the same values back to Dart, and the metadata sidecar gets the cropped dimensions correctly.

## Edge cases

- **Tiny rect** (< 50 × 50 in display points): rejected at `mouseUp`; state stays in `drawing`. Same minimum as the strict window filter.
- **Rect equals the whole display**: allowed; functionally same as a screen capture but routed through the region path. No special-case.
- **Permission revoked between selection and Record**: `LIVE_START_FAILED` propagates as today.
- **Display disconnected between selection and Record**: `startCapture` fails to find the display ID → returns `INVALID_SOURCE_ID`; UI shows "Display no longer available, please redraw."
- **Concurrent `selectRegion` calls**: native side returns the in-flight Future to all callers. UI also disables the "Draw a region" button while the overlay is active.
- **Multi-display drag attempt**: rect bounds clipped to the display the user started dragging on; the rect cannot extend onto another display in v1.

## Testing plan

### Native (XCTest, in `RunnerTests`)

- `RegionSelectorStateTests` — drives `RegionSelectionState` transitions:
  - `idle` + `mouseDown` + `mouseDragged` → `drawing` with current rect.
  - `drawing` + `mouseUp` ≥ 50×50 → `selected`.
  - `drawing` + `mouseUp` < 50×50 → `idle`.
  - `selected` + `mouseDown` on each `ResizeHandle` → `resizing`.
  - `resizing` + `mouseDragged` past the anchor → rect inverts but `width/height ≥ 0`.
  - `selected` + `mouseDown` inside rect (no handle) → `moving`.
  - any state + Esc → `cancelled`.
- `RegionToolbarPositionTests` — given a rect and display bounds, computes the toolbar anchor: bottom-right + 8pt gap when there's room, falls back to inside-the-rect when the rect is at a corner.
- `PluginDispatchTests` — `selectRegion` method-channel handler returns a well-formed map on confirm and `nil` on cancel; `startLiveRecording` with `source == "area"` and a `region` arg dispatches to `ScreenCaptureManager.startCapture(region:)`.

The window-and-event layer (`NSWindow`, `NSEvent` synthesis) is thin glue around the state machine; we test the state machine, not the window plumbing.

### Dart (flutter_test)

- `region_selection_test.dart` — `RegionSelection.fromMap` / `toMap` round-trip, missing-field defaults.
- `recording_state_region_test.dart`:
  - `selectSource(kind: area, id:, region:)` updates `selectedSourceKind`, `selectedSourceId`, `selectedRegion`.
  - `selectSource(kind: null, id: null)` clears all three.
  - `startRecording` with a region builds `RecordingSettings(source: area, sourceId: displayId)` and forwards `region` to the platform.
- `region_tab_content_test.dart` (widget):
  - Empty state shows "Draw a region" button.
  - Selected state shows recap card with the right size and display name + "Redraw" button.
- `recording_screen_region_test.dart` (widget):
  - Tapping "Draw a region" calls `selectRegion`.
  - `selectRegion` returns a region → tab shows recap; bottom bar shows correct text; Record enabled.
  - `selectRegion` returns null → tab stays in empty state.
  - Switching to Windows tab clears `selectedRegion`.

### Manual (`MANUAL_TESTING_CHECKLIST.md` addendum)

- Click Region tab → "Draw a region" button visible.
- Click button → app minimizes, overlay appears across all connected displays with the desktop dimmed.
- Click-drag → rect outlined in purple, live `W × H` readout follows cursor.
- Release → 8 resize handles appear; mini toolbar shows at the bottom-right corner of the rect.
- Drag a corner handle → rect resizes proportionally; toolbar follows.
- Drag an edge handle → resizes one axis only.
- Drag inside the rect → rect moves; toolbar follows.
- Press Esc → overlay closes everywhere, app restores, region tab still empty.
- Click Cancel in toolbar → same as Esc.
- Click Start → overlay closes, app restores, recap card visible with correct dimensions and display; Record enabled.
- Click Record → recording captures only the chosen region at the rect's pixel size.
- Stop → playback shows exactly the region you drew (no scaling, correct aspect ratio).
- Multi-display: confirm a rect drawn on a secondary display records that display's pixels (not the primary).

## Acceptance criteria

- All new tests pass; existing 163 tests still green.
- Region recording produces a video at the rect's exact pixel dimensions; metadata sidecar matches.
- Window and screen recording paths unchanged from regression baseline.
- Selection overlay appears on every connected display.
- Esc and Cancel both cleanly tear down the overlay; the picker app window restores.

## Deferred

- Cross-display rectangles.
- Aspect-ratio snap (e.g. shift-key for 16:9).
- Cross-launch persistence of the last region.
- Preset regions ("16:9 1080p", etc.).
- Windows / Linux platforms.
