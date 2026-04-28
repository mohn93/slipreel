# Source Picker Redesign — Design Spec

**Date:** 2026-04-28
**Status:** Approved (pending implementation plan)

## Goal

Replace the current windows-only source picker with a tabbed picker that lists Windows and Screens, each tile previewed by a real thumbnail of the source. Make the Windows list useful by filtering out system noise (menu bar, dock, sub-windows) by default. Wire screens through to the existing live-recording pipeline so users can record a whole display, not just a single window.

A third tab — "Region" (user-drawn rect) — is **out of scope** for this spec and will be designed and shipped separately.

## Background

Today's `RecordingScreen` lists windows from `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`, with no filtering and no thumbnails — just an icon, title, and owner name per tile. The list contains menu-bar items, dock helpers, transparent UIElement windows, and notification tooltips, which makes it hard to find the window you actually want. `getAvailableScreens` is wired on the native side but unused by the UI, so users can't record a whole display.

## Non-goals

- Region selection (deferred to a separate spec).
- Live thumbnail refresh (one-shot at picker open + manual refresh only).
- Any change to the editor, export pipeline, or recording perf instrumentation.
- Any change to recording config (fps, output path, audio settings remain untouched).
- Bumping minimum macOS version.

## Architecture

Two layers with a clean boundary:

```
+---------------------------+
|  Flutter UI               |
|  - RecordingScreen (tabs) |
|  - SourceGrid             |
|  - SourceTile             |
|  - ThumbnailCache         |
+-------------+-------------+
              | platform interface
              | (listSources, captureThumbnail, startLiveRecording {kind})
              v
+---------------------------+
|  ScreenRecorderMacosPlugin|
|  - SourceCatalog          |
|  - ThumbnailCapture       |
|  - ScreenCaptureManager   |
+---------------------------+
```

The picker UI talks to a thin Dart facade. Thumbnail capture details (which native API, downsampling, format) live entirely on the native side. Each side is independently testable.

## Native side (Swift)

### SourceCatalog

New module `screen_recorder_macos/macos/Classes/SourceCatalog.swift`.

```swift
struct SourceList {
  let windows: [WindowInfo]
  let screens: [ScreenInfo]
}

struct ScreenInfo {
  let id: String           // "display-<displayID>"
  let displayName: String  // "Built-in Retina Display" / "External LG"
  let widthPx: Int
  let heightPx: Int
  let isMain: Bool
}

enum SourceCatalog {
  static func listSources(strictFilter: Bool) async throws -> SourceList
  static func applyStrictFilter(_ raw: [RawWindow]) -> [WindowInfo]
}
```

`listSources`:
- Calls `SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)`.
- Maps `SCWindow` → `RawWindow` (id, title, ownerName, ownerBundleId, frame).
- If `strictFilter`, applies `applyStrictFilter`. Otherwise passes through.
- Maps `SCDisplay` → `ScreenInfo` (resolution, name from `NSScreen.localizedName` if matched, `isMain` from `CGMainDisplayID()`).

`applyStrictFilter` rules (pure, unit-testable):
- Drop windows with empty/whitespace title.
- Drop windows whose `ownerBundleId` is in `{ "com.apple.dock", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager" }`.
- Drop windows with `frame.width < 50 || frame.height < 50`.
- Keep everything else.

### ThumbnailCapture

New module `screen_recorder_macos/macos/Classes/ThumbnailCapture.swift`.

```swift
enum ThumbnailCapture {
  static func capture(
    sourceId: String,
    kind: SourceKind,            // .window | .screen
    maxDimension: Int,           // long-edge in pixels, e.g. 480
    osVersion: OSVersionProbe = .live
  ) async throws -> Data         // JPEG bytes (quality ~0.8)
}

protocol OSVersionProbe {
  var isMacOS14OrLater: Bool { get }
}
```

Capture path is selected at runtime:
- `osVersion.isMacOS14OrLater == true` → `SCScreenshotManager.captureImage(contentFilter:configuration:)`. Build the filter from a fresh `SCShareableContent` lookup of the source by id. Configuration: `width/height` set to a downsampled box matching `maxDimension` while preserving aspect ratio; `showsCursor = false`.
- Otherwise → `CGWindowListCreateImage(rect: .null, listOption: .optionIncludingWindow, windowID: id, imageOption: .boundsIgnoreFraming)` for windows, or `CGDisplayCreateImage(displayID)` for screens. Downsample the resulting `CGImage` via `CGContext` to `maxDimension` long edge.

Both paths return JPEG `Data` (quality 0.8) to keep the FlutterStandardTypedData payload small.

`OSVersionProbe` is an injectable protocol so tests can flip the version without running on a different OS.

### Plugin wiring

Extend `ScreenRecorderMacosPlugin.swift` method-channel handler:

| Method | Args | Returns |
|---|---|---|
| `listSources` | `{ strictFilter: Bool }` | `{ windows: [...], screens: [...] }` |
| `captureThumbnail` | `{ id: String, kind: "window"\|"screen", maxDimension: Int }` | `Uint8List` (JPEG) or `null` on error |
| `startLiveRecording` | (existing args) + `{ kind: "window"\|"screen" }` | (existing) |

`startLiveRecording` plumbs `kind` into `ScreenCaptureManager.startCapture` so the right `SCContentFilter` is built:
- `kind == "window"` → existing path: `SCContentFilter(desktopIndependentWindow: scWindow)`.
- `kind == "screen"` → new path: `SCContentFilter(display: scDisplay, excludingWindows: [])`. Capture dimensions: `display.width * backingScaleFactor × display.height * backingScaleFactor`, identical Retina handling to the window path.

The `captureDimensions(sourceId:isWindow:)` helper added in Phase 9 generalizes to `captureDimensions(sourceId:kind:)` so the plugin can override Dart's hint correctly for both kinds.

## Dart side

### Platform interface

Extend `ScreenRecorderPlatform`:

```dart
abstract class ScreenRecorderPlatform {
  // existing methods...

  Future<SourceList> listSources({bool strictFilter = true});
  Future<Uint8List?> captureThumbnail(
    String id,
    SourceKind kind, {
    int maxDimension = 480,
  });
}

enum SourceKind { window, screen }

class SourceList {
  final List<WindowInfo> windows;
  final List<ScreenInfo> screens;
  // fromMap, toMap
}

class ScreenInfo {
  final String id;
  final String displayName;
  final int widthPx;
  final int heightPx;
  final bool isMain;
  // fromMap, toMap
}
```

`startLiveRecording` gains a required `SourceKind kind` parameter; the existing window-only call sites switch to passing `SourceKind.window`.

### UI

**File structure:**
- `lib/ui/screens/recording_screen.dart` — restructured into a tab host with a segmented control.
- `lib/ui/widgets/source_picker/source_grid.dart` — grid layout + concurrency-capped thumbnail loader.
- `lib/ui/widgets/source_picker/source_tile.dart` — shared tile widget (windows + screens).
- `lib/ui/widgets/source_picker/thumbnail_cache.dart` — in-memory `Map<String, Uint8List>` keyed by `(kind, id)`, scoped to the picker route.
- `lib/ui/widgets/source_picker/permission_cta.dart` — "Grant screen recording permission" empty state.

**Layout (top to bottom):**
- AppBar: "ScreenFlow Studio" + refresh icon + (Windows tab only) "Show all" toggle.
- Segmented control: `[ Windows | Screens ]`. Default tab = Windows.
- Body: `GridView` of `SourceTile`s. ~3 columns at ≥800pt wide, 2 columns under 600pt. Tile size ~240×180pt.
- Bottom bar: unchanged from today (selected title + Record button + recording indicator).

**Tile design:**
- 16:9 thumbnail area on top, rounded corners, subtle border.
- Below: title (1 line, ellipsis), subtitle.
  - Windows: subtitle = app name (`ownerName`).
  - Screens: subtitle = `"${widthPx} × ${heightPx}"` + " · Main" suffix if `isMain`.
- Selected state: 2pt purple ring (`#6C63FF`) + slightly brighter background.

**Tile lifecycle:**
- `listSources` returns instantly with metadata → grid renders with skeleton (gray + shimmer).
- Each tile, on first build, requests its thumbnail through a shared loader with a global concurrency cap of 4 in-flight captures.
- Thumbnail arrives → fade in. Capture error → fall back to `Icons.window` (windows) or `Icons.desktop_windows` (screens).
- Refresh button: clears the cache, re-runs `listSources`, kicks off all thumbnail captures fresh.

### Selection model

- One selection at a time, stored as `({SourceKind kind, String id})?` in `_RecordingScreenState`.
- Switching tabs **clears** the selection — windows and screens are independent pools.
- Bottom bar reads the selection. Record button disabled when null; helper text "Pick a window or screen above".
- On tap of Record, the screen calls `recordingControllerProvider.notifier.startRecording(kind: kind, id: id)` and the rest of the existing flow runs unchanged.

### Empty / error states (per tab)

- Windows, strict filter, zero matches → "No app windows detected. Open a window you want to record, then tap refresh." + an inline hint to enable "Show all".
- Windows, "Show all", zero matches → "No windows available. Tap refresh."
- Screens → always ≥1 in practice; if listing fails entirely, show a generic error with retry.
- Permission error from `listSources` → full-tab CTA: "ScreenFlow needs Screen Recording permission" + "Open System Settings" button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture`. Refresh retries.
- Per-tile thumbnail error → silent fallback to icon placeholder; never blocks the rest of the grid.

## Recording-pipeline integration

The only change to the recording pipeline is the addition of the `kind` parameter and the screen path inside `ScreenCaptureManager.startCapture`. Everything else — `LiveRecordingWriter`, `VideoToolboxEncoder`, `AudioCaptureManager`, the `RecordingResult` shape, perf instrumentation, sidecar metadata — is unchanged.

For a screen source, the recorded video's `widthPx` × `heightPx` come from the actual capture dimensions returned by `captureDimensions(sourceId:kind:)`, just like the window path. This keeps the metadata sidecar fix from Phase 9 working for both kinds.

## Testing plan

### Native (XCTest)

Add a new test target `screen_recorder_macosTests` (we don't have one yet) — a follow-on of the Phase 9 commitment to test the Swift side.

- `SourceCatalogTests` — pure tests of `applyStrictFilter`. Cases:
  - Drops `com.apple.dock` owner.
  - Drops `com.apple.systemuiserver` owner.
  - Drops empty-title window.
  - Drops `40 × 200` window (sub-50 width).
  - Keeps a regular `1200 × 800` window owned by `com.example.app` with title "Document".
- `ThumbnailCaptureTests` — version-gate behavior with a fake `OSVersionProbe`:
  - `isMacOS14OrLater = true` → `SCScreenshotManager` path is invoked (assert via injected closure).
  - `isMacOS14OrLater = false`, `kind == .window` → `CGWindowListCreateImage` path.
  - `isMacOS14OrLater = false`, `kind == .screen` → `CGDisplayCreateImage` path.
  We don't capture real images; we assert which capture closure is invoked.
- `PluginDispatchTests` — feed canned method-channel calls into the handler, assert correct delegation and arg parsing for `listSources`, `captureThumbnail`, and `startLiveRecording { kind }`.

### Dart (flutter_test)

- `source_list_test.dart` — `SourceList`, `WindowInfo`, `ScreenInfo` round-trip from/to map, including missing-field defaults.
- `thumbnail_cache_test.dart` — populate/lookup/clear; refresh resets cache.
- `concurrent_loader_test.dart` — given 10 fake sources and a concurrency cap of 4, verify never more than 4 in-flight at once and all eventually resolve.
- `recording_screen_test.dart` (widget):
  - Tab switch clears the selection.
  - Empty-windows tab shows the empty-state CTA with "Show all" hint.
  - Permission error shows the "Open System Settings" CTA.
  - Tile thumbnail error renders the icon fallback without breaking the grid.
  - "Show all" toggle re-runs `listSources` with `strictFilter: false`.
- `start_recording_test.dart` — selecting a window then tapping Record sends `kind: "window"`; selecting a screen sends `kind: "screen"`. Uses a mock `ScreenRecorderPlatform`.

### Manual (`MANUAL_TESTING_CHECKLIST.md` addendum)

- Open picker, Windows tab populates with thumbnails within ~1.5s.
- Switch to Screens, see all physical displays with correct resolutions, "Main" badge on primary.
- Refresh re-captures (visually verify a stale thumb updates after scrolling content in the source).
- Select window → record → stop → playback shows what you recorded.
- Select screen → record → stop → playback covers full display.
- Toggle "Show all" — utility windows appear.
- First-launch permission flow: revoke Screen Recording in System Settings, re-launch, see CTA, grant, refresh works.

## Acceptance criteria

- All new unit tests pass; existing 111 tests still pass.
- Picker open → first thumbnails visible within ~1.5s on a typical Mac with ~20 windows.
- Recording from a screen produces a video at the display's actual capture resolution; metadata sidecar matches.
- Recording from a window unchanged from Phase 9 behavior (regression check).
- No change to existing recording perf targets (`cpuPctAvg ≤ 10`, `memPeakMB ≤ 500`).

## Deferred / future work

- **Region tab** — interactive overlay-window region selector + sub-rect SCStream config. Separate spec.
- **Per-tab last-used persistence** — remember the user's last tab across launches.
- **Live thumbnail refresh** — auto re-capture every N seconds while picker is visible.
- **Audio device picker** — currently hidden in settings; unrelated to this spec.
- **Windows / Linux platforms** — these plugins remain stubs.
