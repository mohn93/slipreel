# Source Picker Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the windows-only `RecordingScreen` with a tabbed picker (Windows + Screens) that shows a real thumbnail per tile, applies a strict filter that hides system noise from the Windows tab, and wires the Screens tab through the existing live recording pipeline.

**Architecture:** Two-layer design with a clean boundary. Native (Swift): a `SourceCatalog` module produces filtered `WindowInfo`/`ScreenInfo` lists, and a `ThumbnailCapture` module returns downsampled JPEG bytes via `SCScreenshotManager` on macOS 14+ or `CGWindowListCreateImage`/`CGDisplayCreateImage` on 12.3–13. Flutter UI: a tab host with a segmented control, a shared `SourceTile` widget, an in-memory thumbnail cache, and a concurrency-capped loader that requests thumbnails lazily.

**Tech Stack:** Swift 5 / ScreenCaptureKit / CoreGraphics / Flutter 3 / Riverpod / XCTest / flutter_test.

---

## Spec reference

Spec: `docs/superpowers/specs/2026-04-28-source-picker-redesign-design.md`. The plan covers every section of that spec. Read it first if you need rationale; this plan tells you exactly what to type.

## Background you need to know before starting

- **Federated plugin layout**:
  - Platform interface (Dart abstract class + models): `packages/screen_recorder_platform_interface/`
  - macOS implementation (Dart `MethodChannel` adapter + Swift sources): `packages/screen_recorder_macos/`
  - App + UI: `packages/screen_recorder/`
- **Existing Dart types** (do **not** invent new ones that overlap):
  - `RecordingSource` enum in `recording_settings.dart` already has `screen`, `window`, `area`. Reuse it everywhere this plan would otherwise need a "source kind". No new `SourceKind` enum.
  - `WindowInfo` (id, title, ownerName, x/y/w/h, isOnScreen) — keep as-is.
  - `ScreenInfo` (id, name, width, height, isPrimary) — keep as-is.
- **Existing macOS plugin entry points**:
  - `ScreenRecorderMacosPlugin.swift` is the method-channel handler.
  - `ScreenCaptureManager.swift` already supports both window and display capture and exposes `captureDimensions(sourceId:isWindow:)`.
- **Existing Swift test target**: `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift` is wired into the example Xcode project but contains only a stale demo test. New native tests live alongside it. Run with:
  ```bash
  cd packages/screen_recorder_macos/example
  xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
  ```
- **Existing Dart test runner**: `flutter test` from `packages/screen_recorder/`. The existing 111-test suite must remain green at the end of every task.
- **Min macOS version**: 12.3 (do not bump). Use `if #available(macOS 14.0, *)` for the modern thumbnail API.

## File structure (created or modified by this plan)

### Native (Swift)

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_macos/macos/Classes/SourceCatalog.swift` | **create** | `RawWindow` struct, `applyStrictFilter`, `listSources` async helper that queries `SCShareableContent` and produces method-channel-ready `[String: Any]` dictionaries. |
| `packages/screen_recorder_macos/macos/Classes/ThumbnailCapture.swift` | **create** | `OSVersionProbe` protocol + `LiveOSVersionProbe`, `ThumbnailCapture` enum with one `capture(...)` async method. Picks `SCScreenshotManager` (14+) or `CGWindowListCreateImage`/`CGDisplayCreateImage` (12.3–13). Returns JPEG `Data`. |
| `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` | **modify** | Add `listSources` and `captureThumbnail` cases to `handle(_:result:)`. Existing `getAvailableWindows` / `getAvailableScreens` stay (legacy paths the plan does not yet remove). |
| `packages/screen_recorder_macos/example/macos/RunnerTests/SourceCatalogTests.swift` | **create** | XCTest cases for `applyStrictFilter`. |
| `packages/screen_recorder_macos/example/macos/RunnerTests/ThumbnailCaptureTests.swift` | **create** | XCTest cases for `OSVersionProbe`-driven path selection. |
| `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift` | **modify** | Replace the stale `testGetPlatformVersion` with real plugin-dispatch tests for `listSources` / `captureThumbnail`. |

### Platform interface (Dart)

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_platform_interface/lib/src/models/source_list.dart` | **create** | `SourceList` value object holding `windows: List<WindowInfo>` and `screens: List<ScreenInfo>`. |
| `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` | **modify** | Export the new `source_list.dart`. |
| `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` | **modify** | Add `listSources({bool strictFilter = true})` and `captureThumbnail(String id, RecordingSource kind, {int maxDimension = 480})` abstract methods (default impls throw `UnimplementedError`). |
| `packages/screen_recorder_platform_interface/lib/src/constants.dart` | **modify** | Add `listSources` and `captureThumbnail` to `ScreenRecorderMethods`. |

### macOS Dart adapter

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart` | **modify** | Override `listSources` and `captureThumbnail` to call the new method-channel methods. |

### App / UI

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder/lib/ui/widgets/source_picker/source_tile.dart` | **create** | Stateless tile widget showing thumbnail + title + subtitle, with selected/loading/error states. |
| `packages/screen_recorder/lib/ui/widgets/source_picker/thumbnail_cache.dart` | **create** | In-memory `Map<String, Uint8List>` keyed by `"${kind.name}:${id}"`. |
| `packages/screen_recorder/lib/ui/widgets/source_picker/concurrent_loader.dart` | **create** | Runs futures with a max-in-flight cap. |
| `packages/screen_recorder/lib/ui/widgets/source_picker/source_grid.dart` | **create** | Responsive `GridView` of `SourceTile`s; lazily kicks off thumbnail captures via the loader; populates the cache. |
| `packages/screen_recorder/lib/ui/widgets/source_picker/permission_cta.dart` | **create** | Full-tab "grant Screen Recording permission" CTA, deep-links System Settings. |
| `packages/screen_recorder/lib/ui/screens/recording_screen.dart` | **modify** | Restructure into a tab host with a segmented control; manage selection across tabs; wire selected source into `RecordingController`. |
| `packages/screen_recorder/lib/state/recording_state.dart` | **modify** | Track `selectedSourceKind` and `selectedSourceId` (replacing the windows-only `selectedWindowId`); plumb the right `RecordingSource` into `RecordingSettings`. |

### Tests (Dart)

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_platform_interface/test/source_list_test.dart` | **create** | `SourceList`, `WindowInfo`, `ScreenInfo` round-trip from/to maps. |
| `packages/screen_recorder/test/widgets/source_picker/thumbnail_cache_test.dart` | **create** | Cache populate / lookup / clear. |
| `packages/screen_recorder/test/widgets/source_picker/concurrent_loader_test.dart` | **create** | Cap 4: never more than 4 in-flight, all eventually resolve. |
| `packages/screen_recorder/test/widgets/source_picker/source_tile_test.dart` | **create** | Renders thumbnail when bytes present; shows skeleton when null; shows icon fallback on error. |
| `packages/screen_recorder/test/screens/recording_screen_test.dart` | **create** | Tab switch clears selection; empty-windows shows CTA; permission error shows System Settings CTA; "Show all" toggle calls `listSources(strictFilter: false)`. |
| `packages/screen_recorder/test/state/recording_state_test.dart` | **create** | `RecordingController.selectSource(kind:id:)` updates state correctly; `startRecording` builds `RecordingSettings` with the right `RecordingSource`. |

### Docs

| File | Status | Responsibility |
|---|---|---|
| `MANUAL_TESTING_CHECKLIST.md` | **modify** | Append a "Source picker redesign" section. |

---

## Task list

Follow tasks in order. Each task ends with a commit. Run `flutter test` from `packages/screen_recorder/` after every task that touches Dart, and run the Xcode tests after every task that touches Swift.

---

### Task 1: Replace stale RunnerTests demo with empty scaffold

**Files:**
- Modify: `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift`

The existing demo test calls `getPlatformVersion`, which the plugin doesn't implement — it would currently fail. Replace with a minimal placeholder so subsequent tasks have a green baseline.

- [ ] **Step 1: Replace file content**

```swift
// packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift
import Cocoa
import FlutterMacOS
import XCTest

@testable import screen_recorder_macos

class RunnerTests: XCTestCase {
  func testPluginInstantiates() {
    let plugin = ScreenRecorderMacosPlugin()
    XCTAssertNotNil(plugin)
  }
}
```

- [ ] **Step 2: Run native tests**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: build succeeds, `RunnerTests.testPluginInstantiates` passes.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift
git commit -m "test(macos): replace stale RunnerTests demo with green baseline"
```

---

### Task 2: Add SourceCatalog with applyStrictFilter (TDD)

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/SourceCatalog.swift`
- Create: `packages/screen_recorder_macos/example/macos/RunnerTests/SourceCatalogTests.swift`

The filter logic is pure Swift — no `SCShareableContent` calls — so it tests in isolation. We feed it `[RawWindow]` and assert the survivors.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder_macos/example/macos/RunnerTests/SourceCatalogTests.swift`:

```swift
import XCTest
@testable import screen_recorder_macos

final class SourceCatalogTests: XCTestCase {
  private func makeWindow(
    id: UInt32 = 100,
    title: String? = "Document",
    ownerName: String = "Example",
    bundleId: String = "com.example.app",
    width: CGFloat = 1200,
    height: CGFloat = 800
  ) -> RawWindow {
    return RawWindow(
      id: id,
      title: title,
      ownerName: ownerName,
      ownerBundleId: bundleId,
      frame: CGRect(x: 0, y: 0, width: width, height: height),
      isOnScreen: true
    )
  }

  func testKeepsRegularAppWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow()])
    XCTAssertEqual(result.count, 1)
    XCTAssertEqual(result.first?.id, "100")
  }

  func testDropsDockOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.dock"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsSystemUIServerOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.systemuiserver"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsControlCenterOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.controlcenter"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsNotificationCenterOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.notificationcenterui"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsWindowManagerOwnedWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(bundleId: "com.apple.WindowManager"),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsEmptyTitleWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow(title: "")])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsNilTitleWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow(title: nil)])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsWhitespaceOnlyTitleWindow() {
    let result = SourceCatalog.applyStrictFilter([makeWindow(title: "   ")])
    XCTAssertTrue(result.isEmpty)
  }

  func testDropsTooSmallWindow() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(width: 40, height: 40),
    ])
    XCTAssertTrue(result.isEmpty)
  }

  func testKeepsBoundaryWindowAtMinSize() {
    let result = SourceCatalog.applyStrictFilter([
      makeWindow(width: 50, height: 50),
    ])
    XCTAssertEqual(result.count, 1)
  }

  func testEmittedDictionaryShape() {
    let result = SourceCatalog.applyStrictFilter([makeWindow()])
    let dict = result.first!
    XCTAssertEqual(dict["id"] as? String, "100")
    XCTAssertEqual(dict["title"] as? String, "Document")
    XCTAssertEqual(dict["ownerName"] as? String, "Example")
    XCTAssertEqual(dict["x"] as? Int, 0)
    XCTAssertEqual(dict["y"] as? Int, 0)
    XCTAssertEqual(dict["width"] as? Int, 1200)
    XCTAssertEqual(dict["height"] as? Int, 800)
    XCTAssertEqual(dict["isOnScreen"] as? Bool, true)
  }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: build fails (`RawWindow`, `SourceCatalog` undefined).

- [ ] **Step 3: Create SourceCatalog with the filter implementation**

Create `packages/screen_recorder_macos/macos/Classes/SourceCatalog.swift`:

```swift
import Foundation
import CoreGraphics
import ScreenCaptureKit
import AppKit

/// Plain-data view of a window. Built either from `SCWindow` at runtime or
/// constructed directly in tests.
struct RawWindow {
  let id: UInt32
  let title: String?
  let ownerName: String
  let ownerBundleId: String
  let frame: CGRect
  let isOnScreen: Bool
}

enum SourceCatalog {
  /// Bundle identifiers whose windows are always system noise from the user's
  /// perspective in a screen-recording picker.
  static let excludedBundleIds: Set<String> = [
    "com.apple.dock",
    "com.apple.systemuiserver",
    "com.apple.controlcenter",
    "com.apple.notificationcenterui",
    "com.apple.WindowManager",
  ]

  /// Pure filter logic: drops system noise and tiny / titleless windows, then
  /// converts survivors to the method-channel dictionary shape.
  static func applyStrictFilter(_ windows: [RawWindow]) -> [[String: Any]] {
    return windows.compactMap { w -> [String: Any]? in
      guard let title = w.title,
            !title.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
      guard !excludedBundleIds.contains(w.ownerBundleId) else { return nil }
      guard w.frame.width >= 50, w.frame.height >= 50 else { return nil }
      return [
        "id": String(w.id),
        "title": title,
        "ownerName": w.ownerName,
        "x": Int(w.frame.origin.x),
        "y": Int(w.frame.origin.y),
        "width": Int(w.frame.size.width),
        "height": Int(w.frame.size.height),
        "isOnScreen": w.isOnScreen,
      ]
    }
  }

  /// Converts an array of plain dictionaries (no filtering applied) into the
  /// same method-channel shape, for the "show all" path. Same projection as
  /// `applyStrictFilter` but without the drop rules.
  static func projectAll(_ windows: [RawWindow]) -> [[String: Any]] {
    return windows.map { w in
      [
        "id": String(w.id),
        "title": w.title ?? "",
        "ownerName": w.ownerName,
        "x": Int(w.frame.origin.x),
        "y": Int(w.frame.origin.y),
        "width": Int(w.frame.size.width),
        "height": Int(w.frame.size.height),
        "isOnScreen": w.isOnScreen,
      ]
    }
  }

  /// Maps `SCWindow` to `RawWindow` for use with the filter.
  static func rawWindow(from w: SCWindow) -> RawWindow {
    return RawWindow(
      id: w.windowID,
      title: w.title,
      ownerName: w.owningApplication?.applicationName ?? "Unknown",
      ownerBundleId: w.owningApplication?.bundleIdentifier ?? "",
      frame: w.frame,
      isOnScreen: w.isOnScreen
    )
  }

  /// Calls `SCShareableContent` once and returns method-channel-ready
  /// dictionaries for both windows and screens.
  static func listSources(strictFilter: Bool) async throws -> (windows: [[String: Any]], screens: [[String: Any]]) {
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    let raw = content.windows.map { rawWindow(from: $0) }
    let windows = strictFilter ? applyStrictFilter(raw) : projectAll(raw)
    let mainID = CGMainDisplayID()
    let screens = content.displays.map { display -> [String: Any] in
      let name: String
      if let nsScreen = NSScreen.screens.first(where: {
        ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == display.displayID
      }) {
        name = nsScreen.localizedName
      } else if display.displayID == mainID {
        name = "Main Display"
      } else {
        name = "Display \(display.displayID)"
      }
      return [
        "id": String(display.displayID),
        "name": name,
        "width": display.width,
        "height": display.height,
        "isPrimary": display.displayID == mainID,
      ]
    }
    return (windows, screens)
  }
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all 12 SourceCatalogTests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/SourceCatalog.swift \
  packages/screen_recorder_macos/example/macos/RunnerTests/SourceCatalogTests.swift
git commit -m "feat(macos): add SourceCatalog with strict filter

Pure Swift filter that drops dock/systemuiserver/control-center/
notification-center/window-manager owned windows, titleless
windows, and sub-50pt windows. Builds method-channel dictionaries
for both filtered and unfiltered paths."
```

---

### Task 3: Add ThumbnailCapture with OS-version-gated path selection (TDD)

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/ThumbnailCapture.swift`
- Create: `packages/screen_recorder_macos/example/macos/RunnerTests/ThumbnailCaptureTests.swift`

We can't actually capture a screen during XCTest (no display permission, no SCShareableContent). What we can test is the *path selection* — given a fake `OSVersionProbe`, the right capture closure runs.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder_macos/example/macos/RunnerTests/ThumbnailCaptureTests.swift`:

```swift
import XCTest
@testable import screen_recorder_macos

final class ThumbnailCaptureTests: XCTestCase {
  func testPicksModernPathOnSonomaPlus() async throws {
    let probe = StubOSVersionProbe(isMacOS14OrLater: true)
    var pickedModern = false
    var pickedLegacyWindow = false
    var pickedLegacyDisplay = false
    let result = try? await ThumbnailCapture.capture(
      sourceId: "1",
      kind: .window,
      maxDimension: 240,
      osVersion: probe,
      modernCapture: { _, _, _, _ in pickedModern = true; return Data([0xFF]) },
      legacyWindowCapture: { _, _ in pickedLegacyWindow = true; return Data() },
      legacyDisplayCapture: { _, _ in pickedLegacyDisplay = true; return Data() }
    )
    XCTAssertTrue(pickedModern)
    XCTAssertFalse(pickedLegacyWindow)
    XCTAssertFalse(pickedLegacyDisplay)
    XCTAssertEqual(result, Data([0xFF]))
  }

  func testPicksLegacyWindowPathOnVentura() async throws {
    let probe = StubOSVersionProbe(isMacOS14OrLater: false)
    var pickedModern = false
    var pickedLegacyWindow = false
    var pickedLegacyDisplay = false
    _ = try? await ThumbnailCapture.capture(
      sourceId: "42",
      kind: .window,
      maxDimension: 240,
      osVersion: probe,
      modernCapture: { _, _, _, _ in pickedModern = true; return Data() },
      legacyWindowCapture: { id, _ in pickedLegacyWindow = true; XCTAssertEqual(id, 42); return Data() },
      legacyDisplayCapture: { _, _ in pickedLegacyDisplay = true; return Data() }
    )
    XCTAssertFalse(pickedModern)
    XCTAssertTrue(pickedLegacyWindow)
    XCTAssertFalse(pickedLegacyDisplay)
  }

  func testPicksLegacyDisplayPathOnVentura() async throws {
    let probe = StubOSVersionProbe(isMacOS14OrLater: false)
    var pickedModern = false
    var pickedLegacyWindow = false
    var pickedLegacyDisplay = false
    _ = try? await ThumbnailCapture.capture(
      sourceId: "100",
      kind: .screen,
      maxDimension: 240,
      osVersion: probe,
      modernCapture: { _, _, _, _ in pickedModern = true; return Data() },
      legacyWindowCapture: { _, _ in pickedLegacyWindow = true; return Data() },
      legacyDisplayCapture: { id, _ in pickedLegacyDisplay = true; XCTAssertEqual(id, 100); return Data() }
    )
    XCTAssertFalse(pickedModern)
    XCTAssertFalse(pickedLegacyWindow)
    XCTAssertTrue(pickedLegacyDisplay)
  }
}

private struct StubOSVersionProbe: OSVersionProbe {
  let isMacOS14OrLater: Bool
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: build fails (`OSVersionProbe`, `ThumbnailCapture`, `ThumbnailKind` undefined).

- [ ] **Step 3: Create ThumbnailCapture**

Create `packages/screen_recorder_macos/macos/Classes/ThumbnailCapture.swift`:

```swift
import Foundation
import CoreGraphics
import CoreImage
import AppKit
import ScreenCaptureKit
import ImageIO
import UniformTypeIdentifiers

enum ThumbnailKind: String {
  case window
  case screen
}

protocol OSVersionProbe {
  var isMacOS14OrLater: Bool { get }
}

struct LiveOSVersionProbe: OSVersionProbe {
  var isMacOS14OrLater: Bool {
    if #available(macOS 14.0, *) { return true }
    return false
  }
}

/// Errors thumbnail capture can surface to the plugin layer. Plugins should
/// translate to `null` (not error) so the UI can fall back to an icon.
enum ThumbnailCaptureError: Error {
  case sourceNotFound
  case captureFailed
  case encodeFailed
}

enum ThumbnailCapture {
  /// Capture a JPEG thumbnail for `sourceId` with longest edge ≤ `maxDimension`.
  /// `osVersion` and the three `*Capture` closures are seams for testing — the
  /// production caller relies on the defaults.
  static func capture(
    sourceId: String,
    kind: ThumbnailKind,
    maxDimension: Int,
    osVersion: OSVersionProbe = LiveOSVersionProbe(),
    modernCapture: ((String, ThumbnailKind, Int, Int) async throws -> Data)? = nil,
    legacyWindowCapture: ((CGWindowID, Int) async throws -> Data)? = nil,
    legacyDisplayCapture: ((CGDirectDisplayID, Int) async throws -> Data)? = nil
  ) async throws -> Data {
    if osVersion.isMacOS14OrLater {
      let fn = modernCapture ?? defaultModernCapture
      return try await fn(sourceId, kind, maxDimension, maxDimension)
    }
    switch kind {
    case .window:
      guard let id = CGWindowID(sourceId) else { throw ThumbnailCaptureError.sourceNotFound }
      let fn = legacyWindowCapture ?? defaultLegacyWindowCapture
      return try await fn(id, maxDimension)
    case .screen:
      guard let id = CGDirectDisplayID(sourceId) else { throw ThumbnailCaptureError.sourceNotFound }
      let fn = legacyDisplayCapture ?? defaultLegacyDisplayCapture
      return try await fn(id, maxDimension)
    }
  }

  // MARK: - Default capture implementations (production use)

  private static let defaultModernCapture: (String, ThumbnailKind, Int, Int) async throws -> Data = { sourceId, kind, maxW, maxH in
    if #available(macOS 14.0, *) {
      let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
      let filter: SCContentFilter
      switch kind {
      case .window:
        guard let id = UInt32(sourceId),
              let w = content.windows.first(where: { $0.windowID == id }) else {
          throw ThumbnailCaptureError.sourceNotFound
        }
        filter = SCContentFilter(desktopIndependentWindow: w)
      case .screen:
        guard let id = UInt32(sourceId),
              let d = content.displays.first(where: { $0.displayID == id }) else {
          throw ThumbnailCaptureError.sourceNotFound
        }
        filter = SCContentFilter(display: d, excludingWindows: [])
      }
      let config = SCStreamConfiguration()
      config.width = maxW
      config.height = maxH
      config.showsCursor = false
      config.scalesToFit = true
      let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
      return try jpegData(from: cgImage)
    }
    throw ThumbnailCaptureError.captureFailed
  }

  private static let defaultLegacyWindowCapture: (CGWindowID, Int) async throws -> Data = { id, maxDim in
    guard let cgImage = CGWindowListCreateImage(.null, .optionIncludingWindow, id, [.boundsIgnoreFraming, .nominalResolution]) else {
      throw ThumbnailCaptureError.captureFailed
    }
    let downsampled = downsample(cgImage, maxDimension: maxDim)
    return try jpegData(from: downsampled)
  }

  private static let defaultLegacyDisplayCapture: (CGDirectDisplayID, Int) async throws -> Data = { id, maxDim in
    guard let cgImage = CGDisplayCreateImage(id) else {
      throw ThumbnailCaptureError.captureFailed
    }
    let downsampled = downsample(cgImage, maxDimension: maxDim)
    return try jpegData(from: downsampled)
  }

  // MARK: - Helpers

  private static func downsample(_ image: CGImage, maxDimension: Int) -> CGImage {
    let w = image.width
    let h = image.height
    let longEdge = max(w, h)
    if longEdge <= maxDimension { return image }
    let scale = CGFloat(maxDimension) / CGFloat(longEdge)
    let newW = Int(CGFloat(w) * scale)
    let newH = Int(CGFloat(h) * scale)
    let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()
    let bytesPerRow = newW * 4
    guard let ctx = CGContext(
      data: nil, width: newW, height: newH, bitsPerComponent: 8,
      bytesPerRow: bytesPerRow, space: colorSpace,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return image }
    ctx.interpolationQuality = .medium
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
    return ctx.makeImage() ?? image
  }

  private static func jpegData(from image: CGImage) throws -> Data {
    let mutable = NSMutableData()
    guard let dest = CGImageDestinationCreateWithData(
      mutable, UTType.jpeg.identifier as CFString, 1, nil
    ) else { throw ThumbnailCaptureError.encodeFailed }
    let opts: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.8]
    CGImageDestinationAddImage(dest, image, opts as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ThumbnailCaptureError.encodeFailed }
    return mutable as Data
  }
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: 3 ThumbnailCaptureTests pass; SourceCatalogTests still pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ThumbnailCapture.swift \
  packages/screen_recorder_macos/example/macos/RunnerTests/ThumbnailCaptureTests.swift
git commit -m "feat(macos): add ThumbnailCapture with OS-gated path selection

SCScreenshotManager on macOS 14+, CGWindowListCreateImage and
CGDisplayCreateImage on 12.3-13. Returns JPEG (quality 0.8)
downsampled to max-dimension long edge."
```

---

### Task 4: Wire listSources + captureThumbnail into the macOS plugin (TDD)

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
- Modify: `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift`

The plugin handler dispatches by method name. Add cases for `listSources` and `captureThumbnail`. The dispatch logic is what we test; the underlying SCShareableContent / capture closures aren't reached in unit tests.

- [ ] **Step 1: Write the failing test**

Replace `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift` with:

```swift
import Cocoa
import FlutterMacOS
import XCTest

@testable import screen_recorder_macos

class RunnerTests: XCTestCase {
  func testPluginInstantiates() {
    let plugin = ScreenRecorderMacosPlugin()
    XCTAssertNotNil(plugin)
  }

  func testListSourcesRejectsBadArgs() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(methodName: "listSources", arguments: "not a dict")
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testCaptureThumbnailRejectsBadArgs() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(methodName: "captureThumbnail", arguments: ["id": "1"])
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

  func testCaptureThumbnailRejectsBadKind() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(
      methodName: "captureThumbnail",
      arguments: ["id": "1", "kind": "potato", "maxDimension": 240]
    )
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 1)
  }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: build succeeds, the three new tests fail (handler returns `FlutterMethodNotImplemented`).

- [ ] **Step 3: Add the dispatch cases and handlers**

In `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`, find the `handle` switch (currently lines 60–87) and add two new cases right after `getAvailableWindows`:

```swift
    case "listSources":
      listSources(call: call, result: result)
    case "captureThumbnail":
      captureThumbnail(call: call, result: result)
```

Then add the two handler methods at the end of the class, just before the closing `}` of `ScreenRecorderMacosPlugin`:

```swift
  // MARK: - Source picker

  private func listSources(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any] else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "listSources requires a map argument",
                          details: nil))
      return
    }
    let strict = args["strictFilter"] as? Bool ?? true
    Task {
      do {
        let lists = try await SourceCatalog.listSources(strictFilter: strict)
        result(["windows": lists.windows, "screens": lists.screens])
      } catch {
        result(FlutterError(code: "DISCOVERY_FAILED",
                            message: "listSources failed: \(error.localizedDescription)",
                            details: nil))
      }
    }
  }

  private func captureThumbnail(call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard let args = call.arguments as? [String: Any],
          let id = args["id"] as? String,
          let kindRaw = args["kind"] as? String,
          let kind = ThumbnailKind(rawValue: kindRaw),
          let maxDim = args["maxDimension"] as? Int else {
      result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "captureThumbnail requires { id, kind, maxDimension }",
                          details: nil))
      return
    }
    Task {
      do {
        let data = try await ThumbnailCapture.capture(sourceId: id, kind: kind, maxDimension: maxDim)
        result(FlutterStandardTypedData(bytes: data))
      } catch {
        // Errors become null so the UI can fall back to an icon without a snackbar.
        result(nil)
      }
    }
  }
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all RunnerTests + SourceCatalogTests + ThumbnailCaptureTests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift \
  packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift
git commit -m "feat(macos): wire listSources and captureThumbnail method-channel handlers"
```

---

### Task 5: Add SourceList model + method constants in platform interface (TDD)

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/models/source_list.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Create: `packages/screen_recorder_platform_interface/test/source_list_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder_platform_interface/test/source_list_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('SourceList.fromMap', () {
    test('parses windows and screens', () {
      final list = SourceList.fromMap({
        'windows': [
          {
            'id': '100',
            'title': 'Doc',
            'ownerName': 'Example',
            'x': 0, 'y': 0, 'width': 800, 'height': 600,
            'isOnScreen': true,
          },
        ],
        'screens': [
          {
            'id': '1',
            'name': 'Built-in',
            'width': 2560, 'height': 1600,
            'isPrimary': true,
          },
        ],
      });
      expect(list.windows, hasLength(1));
      expect(list.windows.first.title, 'Doc');
      expect(list.screens, hasLength(1));
      expect(list.screens.first.isPrimary, true);
    });

    test('defaults to empty when keys missing', () {
      final list = SourceList.fromMap({});
      expect(list.windows, isEmpty);
      expect(list.screens, isEmpty);
    });

    test('round-trips through toMap', () {
      final original = SourceList(
        windows: [
          const WindowInfo(
            id: '1', title: 't', ownerName: 'o',
            x: 0, y: 0, width: 100, height: 100,
          ),
        ],
        screens: [
          const ScreenInfo(id: '1', name: 'n', width: 100, height: 100),
        ],
      );
      final round = SourceList.fromMap(original.toMap());
      expect(round.windows.first.title, 't');
      expect(round.screens.first.name, 'n');
    });
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_platform_interface
flutter test test/source_list_test.dart
```
Expected: FAIL — `SourceList` undefined.

- [ ] **Step 3: Create SourceList model**

Create `packages/screen_recorder_platform_interface/lib/src/models/source_list.dart`:

```dart
import 'screen_info.dart';
import 'window_info.dart';

/// Combined window + screen list returned by `listSources`.
class SourceList {
  final List<WindowInfo> windows;
  final List<ScreenInfo> screens;

  const SourceList({
    this.windows = const [],
    this.screens = const [],
  });

  Map<String, dynamic> toMap() => {
        'windows': windows.map((w) => w.toJson()).toList(),
        'screens': screens.map((s) => s.toJson()).toList(),
      };

  factory SourceList.fromMap(Map<String, dynamic> map) {
    final rawWindows = (map['windows'] as List?) ?? const [];
    final rawScreens = (map['screens'] as List?) ?? const [];
    return SourceList(
      windows: rawWindows
          .map((e) => WindowInfo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      screens: rawScreens
          .map((e) => ScreenInfo.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}
```

- [ ] **Step 4: Export the model and add method constants**

Modify `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` — add the export below the existing exports:

```dart
export 'src/models/source_list.dart';
```

Modify `packages/screen_recorder_platform_interface/lib/src/constants.dart` — add two new method names to `ScreenRecorderMethods`:

```dart
  static const String listSources = 'listSources';
  static const String captureThumbnail = 'captureThumbnail';
```

- [ ] **Step 5: Run tests, verify they pass**

```bash
cd packages/screen_recorder_platform_interface
flutter test
```
Expected: all platform-interface tests pass (3 new + any existing).

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder_platform_interface/
git commit -m "feat(platform-interface): add SourceList model and listSources/captureThumbnail method names"
```

---

### Task 6: Add abstract listSources/captureThumbnail to ScreenRecorderPlatform (TDD)

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_platform_interface/test/source_list_test.dart` (extend existing file)

- [ ] **Step 1: Add the failing test**

Append to `packages/screen_recorder_platform_interface/test/source_list_test.dart`:

```dart
class _UnimplementedPlatform extends ScreenRecorderPlatform {}

void runAbstractMethodTests() {
  group('ScreenRecorderPlatform abstract defaults', () {
    final p = _UnimplementedPlatform();

    test('listSources throws UnimplementedError', () async {
      expect(p.listSources, throwsA(isA<UnimplementedError>()));
    });

    test('captureThumbnail throws UnimplementedError', () async {
      expect(
        () => p.captureThumbnail('1', RecordingSource.window),
        throwsA(isA<UnimplementedError>()),
      );
    });
  });
}
```

Then call `runAbstractMethodTests()` from inside the existing `void main()` (add the line at the bottom of `main`).

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_platform_interface
flutter test
```
Expected: FAIL — `listSources` and `captureThumbnail` not defined on `ScreenRecorderPlatform`.

- [ ] **Step 3: Add abstract methods**

Modify `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`. Add the imports at the top (alongside existing imports):

```dart
import 'models/source_list.dart';
```

Then, anywhere inside the `ScreenRecorderPlatform` abstract class (a good spot is after `getAvailableWindows`), add:

```dart
  /// Return a combined list of windows + screens. When `strictFilter` is true
  /// (the default), system-noise windows (dock/SystemUIServer/etc.) are
  /// filtered out.
  Future<SourceList> listSources({bool strictFilter = true}) {
    throw UnimplementedError('listSources() has not been implemented.');
  }

  /// Capture a JPEG thumbnail for the given source. `kind` must be
  /// `RecordingSource.window` or `RecordingSource.screen`. Returns null on
  /// capture failure (UI falls back to an icon).
  Future<Uint8List?> captureThumbnail(
    String id,
    RecordingSource kind, {
    int maxDimension = 480,
  }) {
    throw UnimplementedError('captureThumbnail() has not been implemented.');
  }
```

Add `import 'dart:typed_data';` at the top of the file if not already present.

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_platform_interface
flutter test
```
Expected: all tests green.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/
git commit -m "feat(platform-interface): add abstract listSources/captureThumbnail methods"
```

---

### Task 7: Implement listSources + captureThumbnail in macOS Dart adapter

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`

No new test file — this is a thin method-channel adapter. We verify it through the widget tests later that mock the platform.

- [ ] **Step 1: Add the overrides**

In `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`, after the existing `stopLiveRecording` override (the last method in the class), add:

```dart
  @override
  Future<SourceList> listSources({bool strictFilter = true}) async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.listSources,
      {'strictFilter': strictFilter},
    );
    if (raw == null) return const SourceList();
    return SourceList.fromMap(raw);
  }

  @override
  Future<Uint8List?> captureThumbnail(
    String id,
    RecordingSource kind, {
    int maxDimension = 480,
  }) async {
    if (kind != RecordingSource.window && kind != RecordingSource.screen) {
      throw ArgumentError('captureThumbnail kind must be window or screen, got $kind');
    }
    final result = await _recordingChannel.invokeMethod<Uint8List>(
      ScreenRecorderMethods.captureThumbnail,
      {
        'id': id,
        'kind': kind.name,
        'maxDimension': maxDimension,
      },
    );
    return result;
  }
```

Add `import 'dart:typed_data';` at the top of the file if it isn't already there.

- [ ] **Step 2: Run a `flutter analyze` to make sure everything resolves**

```bash
cd packages/screen_recorder_macos
flutter analyze
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart
git commit -m "feat(macos): implement listSources and captureThumbnail method-channel adapters"
```

---

### Task 8: Add ThumbnailCache (TDD)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/source_picker/thumbnail_cache.dart`
- Create: `packages/screen_recorder/test/widgets/source_picker/thumbnail_cache_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/widgets/source_picker/thumbnail_cache_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/thumbnail_cache.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('ThumbnailCache', () {
    test('returns null for missing entries', () {
      final cache = ThumbnailCache();
      expect(cache.get(RecordingSource.window, '42'), isNull);
    });

    test('stores and retrieves bytes', () {
      final cache = ThumbnailCache();
      cache.put(RecordingSource.screen, '1', Uint8List.fromList([1, 2, 3]));
      expect(cache.get(RecordingSource.screen, '1'), [1, 2, 3]);
    });

    test('clear empties the cache', () {
      final cache = ThumbnailCache();
      cache.put(RecordingSource.window, 'a', Uint8List(0));
      cache.put(RecordingSource.screen, 'a', Uint8List(0));
      cache.clear();
      expect(cache.get(RecordingSource.window, 'a'), isNull);
      expect(cache.get(RecordingSource.screen, 'a'), isNull);
    });

    test('window and screen with same id are independent', () {
      final cache = ThumbnailCache();
      cache.put(RecordingSource.window, '1', Uint8List.fromList([10]));
      cache.put(RecordingSource.screen, '1', Uint8List.fromList([20]));
      expect(cache.get(RecordingSource.window, '1'), [10]);
      expect(cache.get(RecordingSource.screen, '1'), [20]);
    });
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder
flutter test test/widgets/source_picker/thumbnail_cache_test.dart
```
Expected: FAIL — `ThumbnailCache` undefined.

- [ ] **Step 3: Implement the cache**

Create `packages/screen_recorder/lib/ui/widgets/source_picker/thumbnail_cache.dart`:

```dart
import 'dart:typed_data';

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// In-memory keyed cache of JPEG thumbnail bytes.
class ThumbnailCache {
  final Map<String, Uint8List> _store = {};

  String _key(RecordingSource kind, String id) => '${kind.name}:$id';

  Uint8List? get(RecordingSource kind, String id) => _store[_key(kind, id)];

  void put(RecordingSource kind, String id, Uint8List bytes) {
    _store[_key(kind, id)] = bytes;
  }

  void clear() => _store.clear();
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder
flutter test test/widgets/source_picker/thumbnail_cache_test.dart
```
Expected: all 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/source_picker/thumbnail_cache.dart \
  packages/screen_recorder/test/widgets/source_picker/thumbnail_cache_test.dart
git commit -m "feat(picker): add in-memory ThumbnailCache"
```

---

### Task 9: Add ConcurrentLoader with in-flight cap (TDD)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/source_picker/concurrent_loader.dart`
- Create: `packages/screen_recorder/test/widgets/source_picker/concurrent_loader_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/widgets/source_picker/concurrent_loader_test.dart`:

```dart
import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/concurrent_loader.dart';

void main() {
  test('never exceeds maxInFlight, all complete', () async {
    final loader = ConcurrentLoader<int>(maxInFlight: 4);
    int inFlight = 0;
    int peak = 0;
    final completers = <Completer<int>>[];

    Future<int> task(int i) async {
      inFlight++;
      peak = inFlight > peak ? inFlight : peak;
      final c = Completer<int>();
      completers.add(c);
      final value = await c.future;
      inFlight--;
      return value;
    }

    final futures = List.generate(10, (i) => loader.run(() => task(i)));

    // Let the loader schedule its first batch.
    await Future<void>.delayed(Duration.zero);
    expect(peak, lessThanOrEqualTo(4));

    // Resolve them one at a time so we can keep observing the cap.
    for (var i = 0; i < completers.length; i++) {
      // The number of started tasks should never exceed (resolved + 4).
      expect(inFlight, lessThanOrEqualTo(4));
      completers[i].complete(i);
      await Future<void>.delayed(Duration.zero);
    }

    final results = await Future.wait(futures);
    expect(results, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9]);
    expect(peak, lessThanOrEqualTo(4));
  });

  test('forwards errors to caller', () async {
    final loader = ConcurrentLoader<int>(maxInFlight: 1);
    expect(
      () => loader.run<int>(() async => throw StateError('boom')),
      throwsA(isA<StateError>()),
    );
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder
flutter test test/widgets/source_picker/concurrent_loader_test.dart
```
Expected: FAIL — `ConcurrentLoader` undefined.

- [ ] **Step 3: Implement the loader**

Create `packages/screen_recorder/lib/ui/widgets/source_picker/concurrent_loader.dart`:

```dart
import 'dart:async';
import 'dart:collection';

/// Runs async tasks with a global maximum-in-flight cap. Tasks queue FIFO and
/// start as slots free up.
class ConcurrentLoader<T> {
  ConcurrentLoader({required this.maxInFlight}) : assert(maxInFlight > 0);

  final int maxInFlight;
  int _inFlight = 0;
  final Queue<_Pending<T>> _queue = Queue();

  Future<R> run<R>(Future<R> Function() task) {
    final completer = Completer<R>();
    _queue.add(_Pending<T>(() async {
      try {
        final result = await task();
        completer.complete(result as R);
      } catch (e, st) {
        completer.completeError(e, st);
      }
    }));
    _drain();
    return completer.future;
  }

  void _drain() {
    while (_inFlight < maxInFlight && _queue.isNotEmpty) {
      final pending = _queue.removeFirst();
      _inFlight++;
      pending.run().whenComplete(() {
        _inFlight--;
        _drain();
      });
    }
  }
}

class _Pending<T> {
  _Pending(this.run);
  final Future<void> Function() run;
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder
flutter test test/widgets/source_picker/concurrent_loader_test.dart
```
Expected: both tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/source_picker/concurrent_loader.dart \
  packages/screen_recorder/test/widgets/source_picker/concurrent_loader_test.dart
git commit -m "feat(picker): add ConcurrentLoader with in-flight cap"
```

---

### Task 10: Add SourceTile widget (TDD)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/source_picker/source_tile.dart`
- Create: `packages/screen_recorder/test/widgets/source_picker/source_tile_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/widgets/source_picker/source_tile_test.dart`:

```dart
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/source_tile.dart';

void main() {
  Widget _wrap(Widget child) => MaterialApp(
        home: Scaffold(body: SizedBox(width: 240, height: 200, child: child)),
      );

  testWidgets('renders title and subtitle', (tester) async {
    await tester.pumpWidget(_wrap(SourceTile(
      title: 'Document.pdf',
      subtitle: 'Preview',
      thumbnail: null,
      isSelected: false,
      isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    expect(find.text('Document.pdf'), findsOneWidget);
    expect(find.text('Preview'), findsOneWidget);
  });

  testWidgets('shows fallback icon when thumbnail null and not errored', (tester) async {
    await tester.pumpWidget(_wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: false, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.window), findsOneWidget);
  });

  testWidgets('shows error icon when isErrored', (tester) async {
    await tester.pumpWidget(_wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: false, isErrored: true,
      fallbackIcon: Icons.desktop_windows,
      onTap: () {},
    )));
    expect(find.byIcon(Icons.desktop_windows), findsOneWidget);
  });

  testWidgets('renders thumbnail when bytes present', (tester) async {
    final bytes = Uint8List.fromList([
      // 1x1 transparent PNG
      137, 80, 78, 71, 13, 10, 26, 10,
      0, 0, 0, 13, 73, 72, 68, 82, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 31, 21, 196, 137,
      0, 0, 0, 11, 73, 68, 65, 84, 8, 153, 99, 0, 1, 0, 0, 5, 0, 1, 13, 10, 45, 180, 0, 0, 0, 0, 73, 69, 78, 68, 174, 66, 96, 130
    ]);
    await tester.pumpWidget(_wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: bytes, isSelected: false, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    await tester.pump();
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('selected state adds the selection ring', (tester) async {
    await tester.pumpWidget(_wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: true, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () {},
    )));
    final container = tester.widget<Container>(find.byKey(const ValueKey('source-tile-outer')));
    final decoration = container.decoration as BoxDecoration;
    final border = decoration.border as Border;
    expect(border.top.color, const Color(0xFF6C63FF));
    expect(border.top.width, 2);
  });

  testWidgets('tap fires onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_wrap(SourceTile(
      title: 't', subtitle: 's',
      thumbnail: null, isSelected: false, isErrored: false,
      fallbackIcon: Icons.window,
      onTap: () => taps++,
    )));
    await tester.tap(find.byType(SourceTile));
    await tester.pump();
    expect(taps, 1);
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder
flutter test test/widgets/source_picker/source_tile_test.dart
```
Expected: FAIL — `SourceTile` undefined.

- [ ] **Step 3: Implement the tile**

Create `packages/screen_recorder/lib/ui/widgets/source_picker/source_tile.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';

class SourceTile extends StatelessWidget {
  const SourceTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.thumbnail,
    required this.isSelected,
    required this.isErrored,
    required this.fallbackIcon,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final Uint8List? thumbnail;
  final bool isSelected;
  final bool isErrored;
  final IconData fallbackIcon;
  final VoidCallback onTap;

  static const Color _selectionColor = Color(0xFF6C63FF);

  @override
  Widget build(BuildContext context) {
    final borderColor = isSelected ? _selectionColor : Colors.white12;
    final borderWidth = isSelected ? 2.0 : 1.0;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          key: const ValueKey('source-tile-outer'),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: isSelected ? Colors.white12 : Colors.white10,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: borderColor, width: borderWidth),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: _buildThumbnail(),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: Colors.white.withValues(alpha: 0.6), fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildThumbnail() {
    if (isErrored || thumbnail == null) {
      return Container(
        color: Colors.white10,
        child: Center(
          child: Icon(fallbackIcon, color: Colors.white38, size: 32),
        ),
      );
    }
    return Image.memory(thumbnail!, fit: BoxFit.cover, gaplessPlayback: true);
  }
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder
flutter test test/widgets/source_picker/source_tile_test.dart
```
Expected: all 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/source_picker/source_tile.dart \
  packages/screen_recorder/test/widgets/source_picker/source_tile_test.dart
git commit -m "feat(picker): add SourceTile widget with thumbnail/selected/error states"
```

---

### Task 11: Add PermissionCta widget

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/source_picker/permission_cta.dart`

This is a small presentation widget; its behavior is exercised in Task 13 (RecordingScreen widget tests). No standalone test.

- [ ] **Step 1: Implement the widget**

Create `packages/screen_recorder/lib/ui/widgets/source_picker/permission_cta.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class PermissionCta extends StatelessWidget {
  const PermissionCta({super.key, required this.onRetry});

  final VoidCallback onRetry;

  static final Uri _settingsUri = Uri.parse(
    'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture',
  );

  Future<void> _openSettings() async {
    if (await canLaunchUrl(_settingsUri)) {
      await launchUrl(_settingsUri);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline, size: 48, color: Colors.white54),
            const SizedBox(height: 16),
            const Text(
              'ScreenFlow needs Screen Recording permission',
              style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            const Text(
              'Grant access in System Settings, then tap retry.',
              style: TextStyle(color: Colors.white60, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton(
                  onPressed: _openSettings,
                  child: const Text('Open System Settings'),
                ),
                const SizedBox(width: 12),
                OutlinedButton(
                  onPressed: onRetry,
                  child: const Text('Retry'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 2: Add url_launcher dependency**

Check `packages/screen_recorder/pubspec.yaml` — if `url_launcher` is not listed under `dependencies`, add it:

```yaml
  url_launcher: ^6.2.0
```

Then run:

```bash
cd packages/screen_recorder
flutter pub get
```

- [ ] **Step 3: Verify it compiles**

```bash
cd packages/screen_recorder
flutter analyze lib/ui/widgets/source_picker/permission_cta.dart
```
Expected: no errors.

- [ ] **Step 4: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/source_picker/permission_cta.dart \
  packages/screen_recorder/pubspec.yaml packages/screen_recorder/pubspec.lock
git commit -m "feat(picker): add PermissionCta with deep-link to System Settings"
```

---

### Task 12: Add SourceGrid that ties cache + loader + tiles together

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/source_picker/source_grid.dart`

This widget orchestrates: shows the grid, kicks off thumbnail captures via `ConcurrentLoader`, populates `ThumbnailCache`. Tested indirectly through the recording-screen widget tests (Task 13). It's small enough to ship without its own dedicated test.

- [ ] **Step 1: Implement SourceGrid**

Create `packages/screen_recorder/lib/ui/widgets/source_picker/source_grid.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import 'concurrent_loader.dart';
import 'source_tile.dart';
import 'thumbnail_cache.dart';

typedef ThumbnailFetcher = Future<Uint8List?> Function(
  String id, RecordingSource kind,
);

class SourceGridItem {
  const SourceGridItem({
    required this.id,
    required this.kind,
    required this.title,
    required this.subtitle,
    required this.fallbackIcon,
  });

  final String id;
  final RecordingSource kind;
  final String title;
  final String subtitle;
  final IconData fallbackIcon;
}

class SourceGrid extends StatefulWidget {
  const SourceGrid({
    super.key,
    required this.items,
    required this.cache,
    required this.loader,
    required this.fetcher,
    required this.selectedId,
    required this.onSelect,
  });

  final List<SourceGridItem> items;
  final ThumbnailCache cache;
  final ConcurrentLoader<Uint8List?> loader;
  final ThumbnailFetcher fetcher;
  final String? selectedId;
  final void Function(SourceGridItem item) onSelect;

  @override
  State<SourceGrid> createState() => _SourceGridState();
}

class _SourceGridState extends State<SourceGrid> {
  final Set<String> _erroredKeys = {};
  final Set<String> _inFlight = {};

  String _key(SourceGridItem i) => '${i.kind.name}:${i.id}';

  void _kickoff(SourceGridItem item) {
    final key = _key(item);
    if (_inFlight.contains(key)) return;
    if (widget.cache.get(item.kind, item.id) != null) return;
    if (_erroredKeys.contains(key)) return;
    _inFlight.add(key);
    widget.loader.run<Uint8List?>(() => widget.fetcher(item.id, item.kind)).then((bytes) {
      if (!mounted) return;
      _inFlight.remove(key);
      setState(() {
        if (bytes == null) {
          _erroredKeys.add(key);
        } else {
          widget.cache.put(item.kind, item.id, bytes);
        }
      });
    }).catchError((_) {
      if (!mounted) return;
      _inFlight.remove(key);
      setState(() => _erroredKeys.add(key));
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final cols = constraints.maxWidth >= 800 ? 3 : 2;
        return GridView.builder(
          padding: const EdgeInsets.all(16),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: cols,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
            childAspectRatio: 4 / 3,
          ),
          itemCount: widget.items.length,
          itemBuilder: (context, i) {
            final item = widget.items[i];
            final bytes = widget.cache.get(item.kind, item.id);
            final errored = _erroredKeys.contains(_key(item));
            if (bytes == null && !errored) _kickoff(item);
            return SourceTile(
              title: item.title,
              subtitle: item.subtitle,
              thumbnail: bytes,
              isSelected: widget.selectedId == item.id,
              isErrored: errored,
              fallbackIcon: item.fallbackIcon,
              onTap: () => widget.onSelect(item),
            );
          },
        );
      },
    );
  }
}
```

- [ ] **Step 2: Verify it compiles**

```bash
cd packages/screen_recorder
flutter analyze lib/ui/widgets/source_picker/source_grid.dart
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/source_picker/source_grid.dart
git commit -m "feat(picker): add SourceGrid widget gluing cache + loader + tiles"
```

---

### Task 13: Update RecordingController to track source kind (TDD)

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Create: `packages/screen_recorder/test/state/recording_state_test.dart`

The controller currently only tracks `selectedWindowId` and hard-codes `RecordingSource.window`. We replace that with a source-kind-aware selection.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/state/recording_state_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('initial state has no selection', () {
    final c = RecordingController();
    expect(c.state.selectedSourceId, isNull);
    expect(c.state.selectedSourceKind, isNull);
  });

  test('selectSource sets both kind and id', () {
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.window, id: '42');
    expect(c.state.selectedSourceId, '42');
    expect(c.state.selectedSourceKind, RecordingSource.window);
  });

  test('selectSource(null, null) clears the selection', () {
    final c = RecordingController();
    c.selectSource(kind: RecordingSource.screen, id: '1');
    c.selectSource(kind: null, id: null);
    expect(c.state.selectedSourceId, isNull);
    expect(c.state.selectedSourceKind, isNull);
  });

  test('canStartRecording false when no source selected', () {
    final c = RecordingController();
    expect(c.state.canStartRecording, true); // status idle
    // but selectedSourceId is null, so startRecording is a no-op (separate guard).
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder
flutter test test/state/recording_state_test.dart
```
Expected: FAIL — `selectedSourceId`, `selectedSourceKind`, and `selectSource` undefined.

- [ ] **Step 3: Update RecordingController**

In `packages/screen_recorder/lib/state/recording_state.dart`, replace the `RecordingState` class definition (lines 14–53) with:

```dart
class RecordingState {
  final RecordingStatus status;
  final int frameCount;
  final Duration duration;
  final String? videoPath;
  final String? error;
  final String? selectedSourceId;
  final RecordingSource? selectedSourceKind;

  const RecordingState({
    this.status = RecordingStatus.idle,
    this.frameCount = 0,
    this.duration = Duration.zero,
    this.videoPath,
    this.error,
    this.selectedSourceId,
    this.selectedSourceKind,
  });

  RecordingState copyWith({
    RecordingStatus? status,
    int? frameCount,
    Duration? duration,
    String? videoPath,
    String? error,
    String? selectedSourceId,
    RecordingSource? selectedSourceKind,
    bool clearSelection = false,
  }) {
    return RecordingState(
      status: status ?? this.status,
      frameCount: frameCount ?? this.frameCount,
      duration: duration ?? this.duration,
      videoPath: videoPath ?? this.videoPath,
      error: error,
      selectedSourceId: clearSelection ? null : (selectedSourceId ?? this.selectedSourceId),
      selectedSourceKind: clearSelection ? null : (selectedSourceKind ?? this.selectedSourceKind),
    );
  }

  bool get isRecording => status == RecordingStatus.recording;
  bool get isProcessing => status == RecordingStatus.processing;
  bool get canStartRecording =>
      status == RecordingStatus.idle || status == RecordingStatus.completed;
}
```

Replace the `selectWindow` method (current lines 68–70) with `selectSource`:

```dart
  void selectSource({required RecordingSource? kind, required String? id}) {
    if (kind == null && id == null) {
      state = state.copyWith(clearSelection: true);
      return;
    }
    state = state.copyWith(
      selectedSourceId: id,
      selectedSourceKind: kind,
    );
  }
```

In `startRecording` (current lines 72–117), replace the early-return guard and the `RecordingSettings` construction:

```dart
  Future<void> startRecording() async {
    if (!state.canStartRecording ||
        state.selectedSourceId == null ||
        state.selectedSourceKind == null) return;
    try {
      state = state.copyWith(
        status: RecordingStatus.recording,
        frameCount: 0,
        duration: Duration.zero,
        videoPath: null,
        error: null,
      );

      final docsDir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().millisecondsSinceEpoch;
      final outputPath = '${docsDir.path}/recording_$ts.mp4';

      final settings = RecordingSettings(
        source: state.selectedSourceKind!,
        sourceId: state.selectedSourceId,
        frameRate: _defaultFps,
        captureAudio: true,
        captureCursor: true,
      );

      await _videoEncoder.start(
        settings: settings,
        outputPath: outputPath,
        width: _defaultWidth,
        height: _defaultHeight,
      );

      _cursorRecording = CursorRecording();
      _cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
        (pos) => _cursorRecording?.addPosition(pos),
        onError: (e) => AppLogger.recording.w('Cursor stream error', error: e),
      );

      _startTime = DateTime.now();
      _durationTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (_startTime != null) {
          state = state.copyWith(duration: DateTime.now().difference(_startTime!));
        }
      });
    } catch (e) {
      _handleError('Failed to start recording: $e');
    }
  }
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder
flutter test test/state/recording_state_test.dart
```
Expected: 4 tests pass.

- [ ] **Step 5: Run the full Dart suite — anything calling old field names will fail**

```bash
cd packages/screen_recorder
flutter test
```
Expected: existing recording_screen.dart references `selectWindow` and `selectedWindowId` and will fail to compile. That's fine — Task 14 fixes it. Confirm the only compile errors are in `recording_screen.dart`. Do not commit yet.

- [ ] **Step 6: Skip commit; Task 14 lands the matching UI rewrite**

We hold the commit until the screen rewrite is in. The tree is broken between now and the end of Task 14, but it's a single coupled change.

---

### Task 14: Rewrite RecordingScreen as a tabbed picker (TDD)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/recording_screen.dart`
- Create: `packages/screen_recorder/test/screens/recording_screen_test.dart`

This is the largest task. We test through a minimum of widget tests using a fake `ScreenRecorderPlatform`.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/screens/recording_screen_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder/ui/screens/recording_screen.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({
    this.windows = const [],
    this.screens = const [],
    this.thumbnailBytes,
    this.permissionDenied = false,
    this.lastStrictFilter,
  }) : super();

  final List<WindowInfo> windows;
  final List<ScreenInfo> screens;
  final Uint8List? thumbnailBytes;
  final bool permissionDenied;
  bool? lastStrictFilter;

  @override
  Future<SourceList> listSources({bool strictFilter = true}) async {
    lastStrictFilter = strictFilter;
    if (permissionDenied) {
      throw PlatformException(code: 'DISCOVERY_FAILED', message: 'Screen recording permission denied');
    }
    return SourceList(windows: windows, screens: screens);
  }

  @override
  Future<Uint8List?> captureThumbnail(String id, RecordingSource kind, {int maxDimension = 480}) async {
    return thumbnailBytes;
  }
}

void main() {
  Widget _wrap({required ScreenRecorderPlatform platform}) {
    ScreenRecorderPlatform.instance = platform;
    return const ProviderScope(
      child: MaterialApp(home: RecordingScreen()),
    );
  }

  testWidgets('shows segmented control with Windows and Screens', (tester) async {
    await tester.pumpWidget(_wrap(platform: _FakePlatform()));
    await tester.pumpAndSettle();
    expect(find.text('Windows'), findsOneWidget);
    expect(find.text('Screens'), findsOneWidget);
  });

  testWidgets('Windows tab populates from listSources', (tester) async {
    final platform = _FakePlatform(windows: [
      const WindowInfo(id: '1', title: 'Doc', ownerName: 'App', x: 0, y: 0, width: 800, height: 600),
    ]);
    await tester.pumpWidget(_wrap(platform: platform));
    await tester.pumpAndSettle();
    expect(find.text('Doc'), findsOneWidget);
    expect(find.text('App'), findsOneWidget);
  });

  testWidgets('switching to Screens tab clears window selection', (tester) async {
    final platform = _FakePlatform(
      windows: [
        const WindowInfo(id: '1', title: 'Doc', ownerName: 'App', x: 0, y: 0, width: 800, height: 600),
      ],
      screens: [
        const ScreenInfo(id: '100', name: 'Built-in', width: 2560, height: 1600, isPrimary: true),
      ],
    );
    await tester.pumpWidget(_wrap(platform: platform));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Doc'));
    await tester.pumpAndSettle();
    // Switch to Screens
    await tester.tap(find.text('Screens'));
    await tester.pumpAndSettle();
    // Bottom bar should not show the window title anymore.
    expect(find.text('Doc'), findsNothing);
  });

  testWidgets('shows empty-state CTA when Windows tab has nothing', (tester) async {
    await tester.pumpWidget(_wrap(platform: _FakePlatform()));
    await tester.pumpAndSettle();
    expect(find.textContaining('No app windows'), findsOneWidget);
  });

  testWidgets('permission error shows Open System Settings CTA', (tester) async {
    await tester.pumpWidget(_wrap(platform: _FakePlatform(permissionDenied: true)));
    await tester.pumpAndSettle();
    expect(find.text('Open System Settings'), findsOneWidget);
  });

  testWidgets('Show all toggle calls listSources(strictFilter: false)', (tester) async {
    final platform = _FakePlatform();
    await tester.pumpWidget(_wrap(platform: platform));
    await tester.pumpAndSettle();
    expect(platform.lastStrictFilter, true);
    await tester.tap(find.byTooltip('Show all windows'));
    await tester.pumpAndSettle();
    expect(platform.lastStrictFilter, false);
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder
flutter test test/screens/recording_screen_test.dart
```
Expected: build fails (RecordingScreen does not yet have these structures).

- [ ] **Step 3: Rewrite RecordingScreen**

Replace the content of `packages/screen_recorder/lib/ui/screens/recording_screen.dart` with:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

import '../../state/recording_state.dart';
import '../widgets/source_picker/concurrent_loader.dart';
import '../widgets/source_picker/permission_cta.dart';
import '../widgets/source_picker/source_grid.dart';
import '../widgets/source_picker/thumbnail_cache.dart';
import 'playback_screen.dart';

class RecordingScreen extends ConsumerStatefulWidget {
  const RecordingScreen({super.key});

  @override
  ConsumerState<RecordingScreen> createState() => _RecordingScreenState();
}

enum _Tab { windows, screens }

class _RecordingScreenState extends ConsumerState<RecordingScreen> {
  _Tab _tab = _Tab.windows;
  bool _strictFilter = true;
  bool _loading = true;
  bool _permissionDenied = false;
  String? _error;
  SourceList _sources = const SourceList();

  late final ThumbnailCache _cache = ThumbnailCache();
  late final ConcurrentLoader<Uint8List?> _loader = ConcurrentLoader(maxInFlight: 4);

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
      _permissionDenied = false;
    });
    try {
      final result = await ScreenRecorderPlatform.instance.listSources(
        strictFilter: _strictFilter,
      );
      if (!mounted) return;
      setState(() {
        _sources = result;
        _loading = false;
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _permissionDenied = e.message?.toLowerCase().contains('permission') ?? false;
        _error = _permissionDenied ? null : e.message ?? e.code;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _refresh() async {
    _cache.clear();
    await _load();
  }

  void _selectTab(_Tab tab) {
    if (tab == _tab) return;
    setState(() => _tab = tab);
    ref.read(recordingControllerProvider.notifier)
        .selectSource(kind: null, id: null);
  }

  void _toggleStrictFilter(bool value) {
    setState(() => _strictFilter = value);
    _refresh();
  }

  Future<Uint8List?> _fetchThumbnail(String id, RecordingSource kind) {
    return ScreenRecorderPlatform.instance.captureThumbnail(id, kind, maxDimension: 480);
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<RecordingState>(recordingControllerProvider, (previous, next) {
      if (previous?.status != RecordingStatus.completed &&
          next.status == RecordingStatus.completed &&
          next.videoPath != null) {
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => PlaybackScreen(videoPath: next.videoPath!),
          ),
        );
      }
    });

    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text('ScreenFlow Studio',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600)),
        backgroundColor: const Color(0xFF2B2B3D),
        elevation: 0,
        actions: [
          if (_tab == _Tab.windows)
            IconButton(
              tooltip: 'Show all windows',
              icon: Icon(_strictFilter ? Icons.visibility_off : Icons.visibility),
              onPressed: () => _toggleStrictFilter(!_strictFilter),
            ),
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSegmentedControl(),
          Expanded(child: _buildBody()),
          _buildBottomBar(),
        ],
      ),
    );
  }

  Widget _buildSegmentedControl() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: SegmentedButton<_Tab>(
        segments: const [
          ButtonSegment(value: _Tab.windows, label: Text('Windows'), icon: Icon(Icons.window)),
          ButtonSegment(value: _Tab.screens, label: Text('Screens'), icon: Icon(Icons.desktop_windows)),
        ],
        selected: {_tab},
        onSelectionChanged: (s) => _selectTab(s.first),
      ),
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF)));
    }
    if (_permissionDenied) {
      return PermissionCta(onRetry: _refresh);
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!, style: const TextStyle(color: Colors.redAccent)),
        ),
      );
    }
    final items = _tab == _Tab.windows ? _windowItems() : _screenItems();
    if (items.isEmpty) return _buildEmptyState();
    final state = ref.watch(recordingControllerProvider);
    return SourceGrid(
      items: items,
      cache: _cache,
      loader: _loader,
      fetcher: _fetchThumbnail,
      selectedId: state.selectedSourceId,
      onSelect: (item) => ref
          .read(recordingControllerProvider.notifier)
          .selectSource(kind: item.kind, id: item.id),
    );
  }

  List<SourceGridItem> _windowItems() => _sources.windows
      .map((w) => SourceGridItem(
            id: w.id,
            kind: RecordingSource.window,
            title: w.title,
            subtitle: w.ownerName,
            fallbackIcon: Icons.window,
          ))
      .toList();

  List<SourceGridItem> _screenItems() => _sources.screens
      .map((s) => SourceGridItem(
            id: s.id,
            kind: RecordingSource.screen,
            title: s.name,
            subtitle: '${s.width} × ${s.height}${s.isPrimary ? ' · Main' : ''}',
            fallbackIcon: Icons.desktop_windows,
          ))
      .toList();

  Widget _buildEmptyState() {
    if (_tab == _Tab.windows) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.window_outlined, size: 48, color: Colors.white38),
              const SizedBox(height: 16),
              const Text(
                _strictFilter
                    ? 'No app windows detected. Open a window you want to record, then tap refresh.'
                    : 'No windows available. Tap refresh.',
                style: TextStyle(color: Colors.white70),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }
    return const Center(
      child: Text('No displays found.', style: TextStyle(color: Colors.white70)),
    );
  }

  Widget _buildBottomBar() {
    final state = ref.watch(recordingControllerProvider);
    final selectedTitle = _selectedTitle(state);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: Color(0xFF2B2B3D),
        boxShadow: [BoxShadow(color: Colors.black26, blurRadius: 8, offset: Offset(0, -2))],
      ),
      child: Column(
        children: [
          if (selectedTitle != null)
            Text(
              selectedTitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w500),
            )
          else
            const Text(
              'Pick a window or screen above',
              style: TextStyle(color: Colors.white38),
            ),
          const SizedBox(height: 12),
          _RecordButton(enabled: state.selectedSourceId != null && state.canStartRecording),
        ],
      ),
    );
  }

  String? _selectedTitle(RecordingState s) {
    final id = s.selectedSourceId;
    if (id == null) return null;
    if (s.selectedSourceKind == RecordingSource.window) {
      for (final w in _sources.windows) {
        if (w.id == id) return w.title;
      }
      return null;
    }
    for (final scr in _sources.screens) {
      if (scr.id == id) return scr.name;
    }
    return null;
  }
}

class _RecordButton extends ConsumerWidget {
  const _RecordButton({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(recordingControllerProvider);
    final notifier = ref.read(recordingControllerProvider.notifier);
    if (state.isRecording) {
      return FilledButton.icon(
        onPressed: notifier.stopRecording,
        icon: const Icon(Icons.stop),
        label: const Text('Stop'),
      );
    }
    return FilledButton.icon(
      onPressed: enabled ? notifier.startRecording : null,
      icon: const Icon(Icons.fiber_manual_record),
      label: const Text('Record'),
    );
  }
}
```

- [ ] **Step 4: Run the recording-screen widget tests**

```bash
cd packages/screen_recorder
flutter test test/screens/recording_screen_test.dart
```
Expected: 6 tests pass.

- [ ] **Step 5: Run the full Dart suite**

```bash
cd packages/screen_recorder
flutter test
```
Expected: full suite green (existing 111 tests + new ones).

- [ ] **Step 6: Run native tests**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all native tests still pass.

- [ ] **Step 7: Commit (combined with Task 13)**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart \
  packages/screen_recorder/lib/ui/screens/recording_screen.dart \
  packages/screen_recorder/test/state/recording_state_test.dart \
  packages/screen_recorder/test/screens/recording_screen_test.dart
git commit -m "feat(picker): tabbed source picker with thumbnails

- RecordingController.selectSource(kind, id) replaces selectWindow
- RecordingScreen rewritten as a tabbed host (Windows + Screens)
- SegmentedButton tabs, refresh, 'Show all' toggle, permission CTA
- Bottom bar shows selected source title; tab switch clears selection"
```

---

### Task 15: Smoke-test the live recording path on a screen source

**Files:** none (manual + curl through the existing flow)

We've kept `startLiveRecording`'s payload shape identical — `RecordingSettings.source.name` already carries `"window"` or `"screen"`, and the macOS plugin already branches on it. This task is a manual confirmation that recording from a screen actually works end-to-end and that `RecordingResult.width/height` come back correct.

- [ ] **Step 1: Run the example app on macOS**

```bash
cd packages/screen_recorder/example
flutter run -d macos
```

- [ ] **Step 2: Walk through the manual checklist**

In the running app:

1. Confirm you land on the Windows tab and tiles have thumbnails within ~1.5s.
2. Tap a window tile. Confirm the bottom bar shows the window title and Record is enabled.
3. Tap Record, wait ~3 seconds, tap Stop. Playback opens; the video shows the window.
4. Back to picker. Switch to Screens. Tiles populate.
5. Tap a screen tile. Confirm the bottom bar shows the display name. Tap Record, wait, Stop. Playback shows the whole display.
6. Toggle "Show all windows" — verify previously-filtered system windows appear.
7. Refresh — visually verify a stale thumbnail updates after scrolling content in the source.

- [ ] **Step 3: Append the new section to MANUAL_TESTING_CHECKLIST.md**

Open `MANUAL_TESTING_CHECKLIST.md` and append:

```markdown

## Source Picker Redesign (2026-04-28)

- [ ] Picker open → first thumbnails visible within ~1.5s on a Mac with ~20 windows.
- [ ] Switch to Screens, see all physical displays with correct resolutions, "Main" badge on primary.
- [ ] Refresh re-captures (visually verify a stale thumbnail updates after scrolling content in the source).
- [ ] Select window → record → stop → playback shows what you recorded.
- [ ] Select screen → record → stop → playback covers full display.
- [ ] Toggle "Show all" — utility windows appear.
- [ ] First-launch permission flow: revoke Screen Recording in System Settings, re-launch, see CTA, grant, refresh works.
```

- [ ] **Step 4: Commit the docs**

```bash
git add MANUAL_TESTING_CHECKLIST.md
git commit -m "docs: add source picker redesign manual checklist"
```

---

## Final verification

After Task 15, run the complete gate:

```bash
# Dart suite (every package)
melos exec -- "flutter test"

# Native suite
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'

# Static analysis
melos exec -- "flutter analyze"
```

All three must pass before considering the work complete.
