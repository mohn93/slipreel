# Region Capture Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a third tab to the source picker — Region — that lets the user draw a rectangle anywhere on the desktop with a full-screen overlay, fine-tune it with resize handles + a floating Start/Cancel toolbar, and record only that sub-region of the display via `SCStreamConfiguration.sourceRect`.

**Architecture:** Two-layer split. Native (Swift) owns the entire selection UI: one transparent `NSWindow` per `NSScreen` hosting a custom view backed by a pure-Swift state machine, plus a small floating toolbar window. Flutter calls `selectRegion()` and waits for a `RegionSelection` (or null on cancel). Recording reuses the existing live pipeline with `SCContentFilter(display:excludingWindows:)` plus `config.sourceRect`.

**Tech Stack:** Swift 5 / AppKit / ScreenCaptureKit / Flutter 3 / Riverpod / XCTest / flutter_test.

---

## Spec reference

Spec: `docs/superpowers/specs/2026-04-29-region-capture-design.md`. Read it first if you need rationale; this plan tells you exactly what to type.

## Background you need to know before starting

- **Federated plugin layout** (same as all prior tasks):
  - Platform interface: `packages/screen_recorder_platform_interface/`
  - macOS implementation: `packages/screen_recorder_macos/`
  - App + UI: `packages/screen_recorder/`
- **Reuse existing types**:
  - `RecordingSource.area` already exists in `recording_settings.dart`. Use it for region recordings.
  - `MockPlatformInterfaceMixin` is the test seam for fake `ScreenRecorderPlatform` instances.
- **Existing test target**: `packages/screen_recorder_macos/example/macos/RunnerTests/`. New native tests live alongside `SourceCatalogTests.swift` and `ThumbnailCaptureTests.swift`.
- **Run native tests** from `packages/screen_recorder_macos/example` with:
  ```bash
  xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
  ```
- **Run Dart tests** from each package's root with `flutter test`.
- When new Swift sources are added under `packages/screen_recorder_macos/macos/Classes/`, run `pod install` in `packages/screen_recorder_macos/example/macos/` if the build complains about "cannot find type X in scope".
- **No path-header comments** at the top of source files. Plan code blocks may include such markers for the controller; do NOT transcribe them into source.
- **Min macOS version:** 12.3. Do not bump.

## File structure (created or modified by this plan)

### Native (Swift)

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_macos/macos/Classes/RegionSelectorState.swift` | **create** | Pure-Swift state machine: `RegionSelectionState`, `RegionEvent`, `ResizeHandle`, `RegionSelectorMachine`. Zero AppKit/SCKit imports. All testable without an `NSWindow`. |
| `packages/screen_recorder_macos/macos/Classes/RegionToolbarPosition.swift` | **create** | Pure function `positionFor(rect:displayBounds:toolbarSize:gap:) -> CGPoint`. |
| `packages/screen_recorder_macos/macos/Classes/RegionSelectorView.swift` | **create** | `NSView` subclass that draws the dim layer, rect outline, handles, and live readout, and translates `NSEvent`s into `RegionEvent`s. |
| `packages/screen_recorder_macos/macos/Classes/RegionToolbar.swift` | **create** | Tiny `NSWindow` + `NSView` hosting two buttons (Start / Cancel). Repositions itself based on `RegionToolbarPosition`. |
| `packages/screen_recorder_macos/macos/Classes/RegionSelector.swift` | **create** | Public `actor`-style entry point: `selectRegion()` async → `RegionSelection?`. Owns one overlay window per `NSScreen` plus the toolbar window. |
| `packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift` | **modify** | Extend `startCapture` with an optional `region: RegionInfo?` parameter; when set, use `SCContentFilter(display:excludingWindows:)` + `config.sourceRect`. |
| `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift` | **modify** | Add `selectRegion` method-channel handler; plumb `region` argument through `startLiveRecording`. |
| `packages/screen_recorder_macos/example/macos/RunnerTests/RegionSelectorStateTests.swift` | **create** | XCTest covering every transition of `RegionSelectorMachine`. |
| `packages/screen_recorder_macos/example/macos/RunnerTests/RegionToolbarPositionTests.swift` | **create** | XCTest for the toolbar-position function. |
| `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift` | **modify** | Add dispatch tests for `selectRegion` and the `region` arg in `startLiveRecording`. |

### Platform interface (Dart)

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_platform_interface/lib/src/models/region_selection.dart` | **create** | Immutable value type: `displayId, x, y, widthPx, heightPx`. |
| `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart` | **modify** | Export `region_selection.dart`. |
| `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart` | **modify** | Add abstract `selectRegion()` and add optional `region` parameter to `startLiveRecording`. |
| `packages/screen_recorder_platform_interface/lib/src/constants.dart` | **modify** | Add `selectRegion` method name. |

### macOS Dart adapter

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart` | **modify** | Override `selectRegion`; serialize `region` into `startLiveRecording` args. |

### App / UI

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder/lib/state/recording_state.dart` | **modify** | Add `selectedRegion: RegionSelection?`; extend `selectSource` to accept `region`; forward to `startLiveRecording`. |
| `packages/screen_recorder/lib/ui/widgets/source_picker/region_tab_content.dart` | **create** | Stateless widget showing empty state ("Draw a region" button) or recap card ("1280 × 720 on Built-in Display · Redraw"). |
| `packages/screen_recorder/lib/ui/screens/recording_screen.dart` | **modify** | Add `_Tab.region` segment, route to `RegionTabContent`, drive `selectRegion` flow. |

### Tests (Dart)

| File | Status | Responsibility |
|---|---|---|
| `packages/screen_recorder_platform_interface/test/models/region_selection_test.dart` | **create** | Round-trip + missing-field defaults. |
| `packages/screen_recorder/test/state/recording_state_region_test.dart` | **create** | `selectSource` with region, region clearing on tab switch. |
| `packages/screen_recorder/test/widgets/source_picker/region_tab_content_test.dart` | **create** | Empty-state and recap-state widget tests. |
| `packages/screen_recorder/test/screens/recording_screen_region_test.dart` | **create** | End-to-end region tab + Record button enable. |

### Docs

| File | Status | Responsibility |
|---|---|---|
| `MANUAL_TESTING_CHECKLIST.md` | **modify** | Append a "Region capture" section. |

---

## Task list

Follow tasks in order. Each task ends with a commit. Run `flutter test` after every Dart task, run the Xcode test scheme after every Swift task.

---

### Task 1: RegionSelectorState — pure state machine (TDD)

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/RegionSelectorState.swift`
- Create: `packages/screen_recorder_macos/example/macos/RunnerTests/RegionSelectorStateTests.swift`

The state machine has zero AppKit imports — it operates on `CGPoint`/`CGRect` only — so we can test every transition without windowing.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder_macos/example/macos/RunnerTests/RegionSelectorStateTests.swift`:

```swift
import XCTest
@testable import screen_recorder_macos

final class RegionSelectorStateTests: XCTestCase {
  private let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)

  private func makeMachine() -> RegionSelectorMachine {
    return RegionSelectorMachine(displayBounds: displayBounds)
  }

  func testInitialStateIsIdle() {
    let m = makeMachine()
    if case .idle = m.state {} else { XCTFail("expected idle, got \(m.state)") }
  }

  func testIdleMouseDownStartsDrawing() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    guard case let .drawing(start, current) = m.state else {
      return XCTFail("expected drawing, got \(m.state)")
    }
    XCTAssertEqual(start, CGPoint(x: 100, y: 100))
    XCTAssertEqual(current, CGPoint(x: 100, y: 100))
  }

  func testDrawingMouseDraggedUpdatesCurrent() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.mouseDragged(to: CGPoint(x: 300, y: 250)))
    guard case let .drawing(_, current) = m.state else {
      return XCTFail("expected drawing")
    }
    XCTAssertEqual(current, CGPoint(x: 300, y: 250))
  }

  func testDrawingMouseUpAboveMinSizeBecomesSelected() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.mouseDragged(to: CGPoint(x: 300, y: 250)))
    m.handle(.mouseUp(at: CGPoint(x: 300, y: 250)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 200, height: 150))
  }

  func testDrawingMouseUpBelowMinSizeReturnsToIdle() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.mouseDragged(to: CGPoint(x: 130, y: 130)))
    m.handle(.mouseUp(at: CGPoint(x: 130, y: 130)))
    if case .idle = m.state {} else { XCTFail("expected idle, got \(m.state)") }
  }

  func testDrawingClipsToDisplayBounds() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 1800, y: 1000)))
    m.handle(.mouseDragged(to: CGPoint(x: 2500, y: 1500)))
    m.handle(.mouseUp(at: CGPoint(x: 2500, y: 1500)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect.maxX, 1920)
    XCTAssertEqual(rect.maxY, 1080)
  }

  func testDrawingInvertsForBackwardsDrag() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 500, y: 500)))
    m.handle(.mouseDragged(to: CGPoint(x: 200, y: 200)))
    m.handle(.mouseUp(at: CGPoint(x: 200, y: 200)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect, CGRect(x: 200, y: 200, width: 300, height: 300))
  }

  func testSelectedMouseDownOnHandleStartsResizing() {
    var m = makeMachine()
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.mouseDown(at: CGPoint(x: 300, y: 250)))
    guard case let .resizing(handle, originalRect, _) = m.state else {
      return XCTFail("expected resizing, got \(m.state)")
    }
    XCTAssertEqual(handle, .se)
    XCTAssertEqual(originalRect, rect)
  }

  func testSelectedMouseDownInsideRectStartsMoving() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 200, y: 175)))
    if case .moving = m.state {} else { XCTFail("expected moving, got \(m.state)") }
  }

  func testSelectedMouseDownOutsideRectStartsNewDrawing() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 800, y: 800)))
    if case .drawing = m.state {} else { XCTFail("expected drawing, got \(m.state)") }
  }

  func testResizingSEHandleGrowsRect() {
    var m = makeMachine()
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.mouseDown(at: CGPoint(x: 300, y: 250)))
    m.handle(.mouseDragged(to: CGPoint(x: 400, y: 300)))
    guard case let .resizing(_, _, _) = m.state else {
      return XCTFail("expected resizing")
    }
    XCTAssertEqual(m.currentRect, CGRect(x: 100, y: 100, width: 300, height: 200))
  }

  func testResizingMouseUpReturnsToSelected() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 300, y: 250)))
    m.handle(.mouseDragged(to: CGPoint(x: 400, y: 300)))
    m.handle(.mouseUp(at: CGPoint(x: 400, y: 300)))
    guard case let .selected(rect) = m.state else {
      return XCTFail("expected selected")
    }
    XCTAssertEqual(rect, CGRect(x: 100, y: 100, width: 300, height: 200))
  }

  func testMovingTranslatesRect() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 200, y: 175)))
    m.handle(.mouseDragged(to: CGPoint(x: 250, y: 200)))
    XCTAssertEqual(m.currentRect, CGRect(x: 150, y: 125, width: 200, height: 150))
  }

  func testMovingClipsToDisplayBounds() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.mouseDown(at: CGPoint(x: 200, y: 175)))
    m.handle(.mouseDragged(to: CGPoint(x: 5000, y: 5000)))
    let r = m.currentRect
    XCTAssertEqual(r.maxX, 1920)
    XCTAssertEqual(r.maxY, 1080)
    XCTAssertEqual(r.width, 200)
    XCTAssertEqual(r.height, 150)
  }

  func testEscapeCancelsFromAnyState() {
    var m = makeMachine()
    m.handle(.mouseDown(at: CGPoint(x: 100, y: 100)))
    m.handle(.escapePressed)
    if case .cancelled = m.state {} else { XCTFail("expected cancelled, got \(m.state)") }
  }

  func testStartFromSelectedConfirms() {
    var m = makeMachine()
    let rect = CGRect(x: 100, y: 100, width: 200, height: 150)
    m.setSelectedForTest(rect)
    m.handle(.startPressed)
    guard case let .confirmed(confirmedRect) = m.state else {
      return XCTFail("expected confirmed")
    }
    XCTAssertEqual(confirmedRect, rect)
  }

  func testCancelButtonFromSelectedCancels() {
    var m = makeMachine()
    m.setSelectedForTest(CGRect(x: 100, y: 100, width: 200, height: 150))
    m.handle(.cancelPressed)
    if case .cancelled = m.state {} else { XCTFail("expected cancelled") }
  }

  func testStartFromIdleIsIgnored() {
    var m = makeMachine()
    m.handle(.startPressed)
    if case .idle = m.state {} else { XCTFail("expected idle, got \(m.state)") }
  }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: build fails — `RegionSelectorMachine`, `RegionSelectionState`, etc. undefined.

- [ ] **Step 3: Implement the state machine**

Create `packages/screen_recorder_macos/macos/Classes/RegionSelectorState.swift`:

```swift
import Foundation
import CoreGraphics

enum ResizeHandle: CaseIterable {
  case nw, n, ne, e, se, s, sw, w

  func position(in rect: CGRect) -> CGPoint {
    switch self {
    case .nw: return CGPoint(x: rect.minX, y: rect.minY)
    case .n:  return CGPoint(x: rect.midX, y: rect.minY)
    case .ne: return CGPoint(x: rect.maxX, y: rect.minY)
    case .e:  return CGPoint(x: rect.maxX, y: rect.midY)
    case .se: return CGPoint(x: rect.maxX, y: rect.maxY)
    case .s:  return CGPoint(x: rect.midX, y: rect.maxY)
    case .sw: return CGPoint(x: rect.minX, y: rect.maxY)
    case .w:  return CGPoint(x: rect.minX, y: rect.midY)
    }
  }

  static func hit(at point: CGPoint, in rect: CGRect, tolerance: CGFloat = 12) -> ResizeHandle? {
    func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
      return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
    // Order corners before edges so a click at a corner gets the corner handle.
    for h in [ResizeHandle.se, .ne, .sw, .nw, .n, .s, .e, .w] {
      if near(point, h.position(in: rect)) { return h }
    }
    return nil
  }

  func apply(originalRect: CGRect, current: CGPoint) -> CGRect {
    let anchor = position(in: originalRect)
    let dx = current.x - anchor.x
    let dy = current.y - anchor.y
    var minX = originalRect.minX
    var minY = originalRect.minY
    var maxX = originalRect.maxX
    var maxY = originalRect.maxY
    switch self {
    case .nw: minX += dx; minY += dy
    case .n:               minY += dy
    case .ne: maxX += dx; minY += dy
    case .e:  maxX += dx
    case .se: maxX += dx; maxY += dy
    case .s:               maxY += dy
    case .sw: minX += dx; maxY += dy
    case .w:  minX += dx
    }
    return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                  width: abs(maxX - minX), height: abs(maxY - minY))
  }
}

enum RegionSelectionState {
  case idle
  case drawing(start: CGPoint, current: CGPoint)
  case selected(rect: CGRect)
  case resizing(handle: ResizeHandle, originalRect: CGRect, current: CGPoint)
  case moving(originalRect: CGRect, dragStart: CGPoint, current: CGPoint)
  case cancelled
  case confirmed(rect: CGRect)
}

enum RegionEvent {
  case mouseDown(at: CGPoint)
  case mouseDragged(to: CGPoint)
  case mouseUp(at: CGPoint)
  case escapePressed
  case startPressed
  case cancelPressed
}

struct RegionSelectorMachine {
  static let minSize: CGFloat = 50

  private(set) var state: RegionSelectionState = .idle
  let displayBounds: CGRect

  init(displayBounds: CGRect) {
    self.displayBounds = displayBounds
  }

  /// The rect currently visible to the user (regardless of which dynamic state we're in).
  var currentRect: CGRect {
    switch state {
    case .idle, .cancelled:
      return .zero
    case .drawing(let start, let current):
      return CGRect(
        x: min(start.x, current.x),
        y: min(start.y, current.y),
        width: abs(current.x - start.x),
        height: abs(current.y - start.y)
      ).intersection(displayBounds)
    case .selected(let r):
      return r
    case .confirmed(let r):
      return r
    case .resizing(let handle, let originalRect, let current):
      return handle.apply(originalRect: originalRect, current: current)
        .intersection(displayBounds)
    case .moving(let originalRect, let dragStart, let current):
      let dx = current.x - dragStart.x
      let dy = current.y - dragStart.y
      let translated = originalRect.offsetBy(dx: dx, dy: dy)
      return clampToDisplay(translated)
    }
  }

  private func clampToDisplay(_ r: CGRect) -> CGRect {
    var clamped = r
    if clamped.maxX > displayBounds.maxX {
      clamped.origin.x = displayBounds.maxX - clamped.width
    }
    if clamped.maxY > displayBounds.maxY {
      clamped.origin.y = displayBounds.maxY - clamped.height
    }
    if clamped.minX < displayBounds.minX { clamped.origin.x = displayBounds.minX }
    if clamped.minY < displayBounds.minY { clamped.origin.y = displayBounds.minY }
    return clamped
  }

  mutating func handle(_ event: RegionEvent) {
    switch event {
    case .escapePressed:
      state = .cancelled
      return
    default:
      break
    }
    switch state {
    case .idle:
      handleFromIdle(event)
    case .drawing(let start, _):
      handleFromDrawing(event, start: start)
    case .selected(let rect):
      handleFromSelected(event, rect: rect)
    case .resizing(let handle, let originalRect, _):
      handleFromResizing(event, handle: handle, originalRect: originalRect)
    case .moving(let originalRect, let dragStart, _):
      handleFromMoving(event, originalRect: originalRect, dragStart: dragStart)
    case .cancelled, .confirmed:
      break
    }
  }

  private mutating func handleFromIdle(_ event: RegionEvent) {
    if case let .mouseDown(p) = event {
      state = .drawing(start: p, current: p)
    }
  }

  private mutating func handleFromDrawing(_ event: RegionEvent, start: CGPoint) {
    switch event {
    case .mouseDragged(let to):
      state = .drawing(start: start, current: to)
    case .mouseUp(let at):
      let raw = CGRect(
        x: min(start.x, at.x),
        y: min(start.y, at.y),
        width: abs(at.x - start.x),
        height: abs(at.y - start.y)
      )
      let clipped = raw.intersection(displayBounds)
      if clipped.width >= Self.minSize && clipped.height >= Self.minSize {
        state = .selected(rect: clipped)
      } else {
        state = .idle
      }
    default:
      break
    }
  }

  private mutating func handleFromSelected(_ event: RegionEvent, rect: CGRect) {
    switch event {
    case .mouseDown(let p):
      if let h = ResizeHandle.hit(at: p, in: rect) {
        state = .resizing(handle: h, originalRect: rect, current: p)
      } else if rect.contains(p) {
        state = .moving(originalRect: rect, dragStart: p, current: p)
      } else {
        state = .drawing(start: p, current: p)
      }
    case .startPressed:
      state = .confirmed(rect: rect)
    case .cancelPressed:
      state = .cancelled
    default:
      break
    }
  }

  private mutating func handleFromResizing(_ event: RegionEvent, handle: ResizeHandle,
                                            originalRect: CGRect) {
    switch event {
    case .mouseDragged(let to):
      state = .resizing(handle: handle, originalRect: originalRect, current: to)
    case .mouseUp(let to):
      let raw = handle.apply(originalRect: originalRect, current: to)
      let clipped = raw.intersection(displayBounds)
      if clipped.width >= Self.minSize && clipped.height >= Self.minSize {
        state = .selected(rect: clipped)
      } else {
        state = .selected(rect: originalRect)
      }
    default:
      break
    }
  }

  private mutating func handleFromMoving(_ event: RegionEvent, originalRect: CGRect, dragStart: CGPoint) {
    switch event {
    case .mouseDragged(let to):
      state = .moving(originalRect: originalRect, dragStart: dragStart, current: to)
    case .mouseUp(let to):
      let dx = to.x - dragStart.x
      let dy = to.y - dragStart.y
      let translated = originalRect.offsetBy(dx: dx, dy: dy)
      state = .selected(rect: clampToDisplay(translated))
    default:
      break
    }
  }
}

#if DEBUG
extension RegionSelectorMachine {
  /// Test-only seam to seed a selected rect without going through the drawing flow.
  mutating func setSelectedForTest(_ rect: CGRect) {
    state = .selected(rect: rect)
  }
}
#endif
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all 18 RegionSelectorStateTests pass; pre-existing 22 native tests still pass.

If `pod install` is needed, run from `packages/screen_recorder_macos/example/macos/`.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/RegionSelectorState.swift \
  packages/screen_recorder_macos/example/macos/RunnerTests/RegionSelectorStateTests.swift \
  packages/screen_recorder_macos/example/macos/Runner.xcodeproj/project.pbxproj
git commit -m "feat(macos): add RegionSelectorMachine pure-Swift state machine

State machine for the region-selection overlay: idle / drawing /
selected / resizing / moving / cancelled / confirmed. Handles
drag-clipping, min-size 50x50, all 8 resize handles, move-clamping
to display bounds. Zero AppKit imports."
```

---

### Task 2: RegionToolbarPosition — pure positioning math (TDD)

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/RegionToolbarPosition.swift`
- Create: `packages/screen_recorder_macos/example/macos/RunnerTests/RegionToolbarPositionTests.swift`

The toolbar floats relative to the rect. The position function takes `(rect, displayBounds, toolbarSize, gap)` and returns the toolbar's top-left origin.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder_macos/example/macos/RunnerTests/RegionToolbarPositionTests.swift`:

```swift
import XCTest
@testable import screen_recorder_macos

final class RegionToolbarPositionTests: XCTestCase {
  private let displayBounds = CGRect(x: 0, y: 0, width: 1920, height: 1080)
  private let toolbarSize = CGSize(width: 140, height: 36)
  private let gap: CGFloat = 8

  func testPlacesAtBottomRightOfRectWithGap() {
    let rect = CGRect(x: 200, y: 200, width: 400, height: 300)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    // Bottom-right corner is (600, 500); toolbar's top-left = corner - (width, 0) shifted by gap
    // i.e. toolbar sits with right edge aligned to rect.maxX, top edge at rect.maxY + gap.
    XCTAssertEqual(p.x, 600 - 140)
    XCTAssertEqual(p.y, 500 + 8)
  }

  func testFlipsAboveWhenNotEnoughSpaceBelow() {
    let rect = CGRect(x: 200, y: 1000, width: 400, height: 70)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    // Below rect: 1070 + 8 + 36 = 1114, exceeds 1080. Flip above.
    XCTAssertEqual(p.x, 600 - 140)
    XCTAssertEqual(p.y, 1000 - 36 - 8)
  }

  func testFallsInsideWhenRectFillsDisplay() {
    let rect = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    // No room outside; clamp inside the rect (bottom-right inset by gap).
    XCTAssertEqual(p.x, 1920 - 140 - 8)
    XCTAssertEqual(p.y, 1080 - 36 - 8)
  }

  func testClampsLeftEdgeToDisplay() {
    let rect = CGRect(x: 0, y: 200, width: 80, height: 70)
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: toolbarSize, gap: gap)
    // Right edge of rect = 80, toolbar wants top-left at -60. Clamp to 0.
    XCTAssertEqual(p.x, 0)
  }
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: build fails — `RegionToolbarPosition` undefined.

- [ ] **Step 3: Implement**

Create `packages/screen_recorder_macos/macos/Classes/RegionToolbarPosition.swift`:

```swift
import Foundation
import CoreGraphics

/// Positions the floating Start/Cancel toolbar relative to the selected rect.
/// Tries bottom-right with a gap; flips above if there's no room below; falls
/// inside the rect if the rect fills the display. Clamps to display bounds.
enum RegionToolbarPosition {
  static func positionFor(
    rect: CGRect,
    displayBounds: CGRect,
    toolbarSize: CGSize,
    gap: CGFloat
  ) -> CGPoint {
    var x = rect.maxX - toolbarSize.width
    var y = rect.maxY + gap

    if y + toolbarSize.height > displayBounds.maxY {
      // Not enough room below — flip above.
      y = rect.minY - gap - toolbarSize.height
    }
    if y < displayBounds.minY || y + toolbarSize.height > displayBounds.maxY {
      // No room outside the rect — fall inside, bottom-right inset by gap.
      x = displayBounds.maxX - toolbarSize.width - gap
      y = displayBounds.maxY - toolbarSize.height - gap
    }
    if x < displayBounds.minX { x = displayBounds.minX }
    if x + toolbarSize.width > displayBounds.maxX {
      x = displayBounds.maxX - toolbarSize.width
    }
    return CGPoint(x: x, y: y)
  }
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all 4 RegionToolbarPositionTests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/RegionToolbarPosition.swift \
  packages/screen_recorder_macos/example/macos/RunnerTests/RegionToolbarPositionTests.swift \
  packages/screen_recorder_macos/example/macos/Runner.xcodeproj/project.pbxproj
git commit -m "feat(macos): add RegionToolbarPosition pure positioning math"
```

---

### Task 3: RegionSelectorView — NSView with drawing + event translation

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/RegionSelectorView.swift`

This is the AppKit glue between `NSEvent`s and the state machine. We don't unit-test it directly (would require a real `NSWindow`) — its correctness comes from the state machine being tested.

- [ ] **Step 1: Implement**

Create `packages/screen_recorder_macos/macos/Classes/RegionSelectorView.swift`:

```swift
import AppKit

final class RegionSelectorView: NSView {
  var machine: RegionSelectorMachine
  var onStateChange: ((RegionSelectionState) -> Void)?

  init(displayBounds: CGRect) {
    self.machine = RegionSelectorMachine(displayBounds: displayBounds)
    super.init(frame: NSRect(origin: .zero, size: displayBounds.size))
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { return true }
  override var acceptsFirstResponder: Bool { return true }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    machine.handle(.mouseDown(at: p))
    needsDisplay = true
    onStateChange?(machine.state)
  }

  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    machine.handle(.mouseDragged(to: p))
    needsDisplay = true
    onStateChange?(machine.state)
  }

  override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    machine.handle(.mouseUp(at: p))
    needsDisplay = true
    onStateChange?(machine.state)
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { // Esc
      machine.handle(.escapePressed)
      onStateChange?(machine.state)
      return
    }
    super.keyDown(with: event)
  }

  override func draw(_ dirty: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = machine.currentRect

    // Dim everything outside the rect.
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
    if rect.isEmpty {
      ctx.fill(bounds)
    } else {
      // Fill bounds, then clear the rect.
      ctx.fill(bounds)
      ctx.clear(rect)
    }

    if rect.isEmpty { return }

    // Rect outline.
    ctx.setStrokeColor(NSColor(srgbRed: 0x6c/255.0, green: 0x63/255.0, blue: 0xff/255.0, alpha: 1).cgColor)
    ctx.setLineWidth(1)
    ctx.stroke(rect)

    // Draw resize handles only in selected/resizing/moving.
    switch machine.state {
    case .selected, .resizing, .moving:
      drawHandles(in: rect, context: ctx)
    default:
      break
    }

    // Live size readout while drawing or resizing.
    switch machine.state {
    case .drawing, .resizing:
      drawSizeReadout(at: rect, context: ctx)
    default:
      break
    }
  }

  private func drawHandles(in rect: CGRect, context ctx: CGContext) {
    let purple = NSColor(srgbRed: 0x6c/255.0, green: 0x63/255.0, blue: 0xff/255.0, alpha: 1).cgColor
    ctx.setFillColor(purple)
    let s: CGFloat = 12
    let half = s / 2
    let points = [
      CGPoint(x: rect.minX, y: rect.minY),
      CGPoint(x: rect.midX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.minY),
      CGPoint(x: rect.maxX, y: rect.midY),
      CGPoint(x: rect.maxX, y: rect.maxY),
      CGPoint(x: rect.midX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.maxY),
      CGPoint(x: rect.minX, y: rect.midY),
    ]
    for p in points {
      ctx.fill(CGRect(x: p.x - half, y: p.y - half, width: s, height: s))
    }
  }

  private func drawSizeReadout(at rect: CGRect, context ctx: CGContext) {
    let text = "\(Int(rect.width)) × \(Int(rect.height))"
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: text, attributes: attrs)
    let pad: CGFloat = 6
    let textSize = str.size()
    let bgRect = CGRect(
      x: rect.minX, y: rect.minY - textSize.height - pad * 2,
      width: textSize.width + pad * 2, height: textSize.height + pad
    )
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
    ctx.fill(bgRect)
    str.draw(at: CGPoint(x: bgRect.minX + pad, y: bgRect.minY + pad / 2))
  }
}
```

- [ ] **Step 2: Run tests to verify nothing regressed**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all existing tests still pass; the new file compiles.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/RegionSelectorView.swift
git commit -m "feat(macos): add RegionSelectorView with drag + draw glue"
```

---

### Task 4: RegionToolbar — floating Start/Cancel window

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/RegionToolbar.swift`

A small panel with two buttons; positioned via `RegionToolbarPosition`. No unit tests — it's thin AppKit glue.

- [ ] **Step 1: Implement**

Create `packages/screen_recorder_macos/macos/Classes/RegionToolbar.swift`:

```swift
import AppKit

final class RegionToolbar {
  let window: NSPanel
  var onStart: (() -> Void)?
  var onCancel: (() -> Void)?

  static let toolbarSize = CGSize(width: 140, height: 36)

  init() {
    let rect = NSRect(origin: .zero, size: Self.toolbarSize)
    window = NSPanel(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isFloatingPanel = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]

    let host = NSView(frame: rect)
    host.wantsLayer = true
    host.layer?.cornerRadius = 8
    host.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.95).cgColor

    let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
    cancelBtn.bezelStyle = .rounded
    cancelBtn.frame = NSRect(x: 8, y: 6, width: 60, height: 24)
    cancelBtn.target = self
    cancelBtn.action = #selector(cancelTapped)
    host.addSubview(cancelBtn)

    let startBtn = NSButton(title: "Start", target: nil, action: nil)
    startBtn.bezelStyle = .rounded
    startBtn.frame = NSRect(x: 72, y: 6, width: 60, height: 24)
    startBtn.target = self
    startBtn.action = #selector(startTapped)
    startBtn.keyEquivalent = "\r"
    host.addSubview(startBtn)

    window.contentView = host
  }

  func show(in displayBounds: CGRect, anchoredTo rect: CGRect) {
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: Self.toolbarSize, gap: 8)
    // Convert from top-left-origin (our state-machine convention) to AppKit's
    // bottom-left-origin display coords for window.setFrameOrigin.
    let flippedY = displayBounds.maxY - p.y - Self.toolbarSize.height
    window.setFrameOrigin(NSPoint(x: p.x + displayBounds.minX, y: flippedY + displayBounds.minY))
    window.orderFrontRegardless()
  }

  func hide() {
    window.orderOut(nil)
  }

  @objc private func startTapped() { onStart?() }
  @objc private func cancelTapped() { onCancel?() }
}
```

- [ ] **Step 2: Run tests to verify compilation**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/RegionToolbar.swift
git commit -m "feat(macos): add RegionToolbar floating panel with Start/Cancel"
```

---

### Task 5: RegionSelector — public entry point

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/RegionSelector.swift`

Owns one overlay window per `NSScreen` plus the toolbar. Returns a `RegionSelection` (or nil) via async/await.

- [ ] **Step 1: Implement**

Create `packages/screen_recorder_macos/macos/Classes/RegionSelector.swift`:

```swift
import AppKit
import CoreGraphics

struct RegionSelection {
  let displayId: CGDirectDisplayID
  let x: Int
  let y: Int
  let widthPx: Int
  let heightPx: Int
}

final class RegionSelector {
  static let shared = RegionSelector()
  private init() {}

  private var inFlight: Task<RegionSelection?, Never>?
  private var overlayWindows: [NSWindow] = []
  private var views: [NSScreen: RegionSelectorView] = [:]
  private var toolbar: RegionToolbar?
  private var continuation: CheckedContinuation<RegionSelection?, Never>?
  private var activeScreen: NSScreen?

  func selectRegion() async -> RegionSelection? {
    if let inFlight = inFlight { return await inFlight.value }
    let task = Task<RegionSelection?, Never> { [weak self] in
      guard let self = self else { return nil }
      return await self.runSelection()
    }
    inFlight = task
    defer { inFlight = nil }
    return await task.value
  }

  @MainActor
  private func runSelection() async -> RegionSelection? {
    NSApp.miniaturizeAll(nil)
    overlayWindows.removeAll()
    views.removeAll()
    toolbar = RegionToolbar()

    for screen in NSScreen.screens {
      let win = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false,
        screen: screen)
      win.level = .screenSaver
      win.isOpaque = false
      win.backgroundColor = NSColor.black.withAlphaComponent(0.0)
      win.ignoresMouseEvents = false
      win.collectionBehavior = [.canJoinAllSpaces, .stationary]

      let view = RegionSelectorView(displayBounds: CGRect(origin: .zero, size: screen.frame.size))
      view.onStateChange = { [weak self] state in
        self?.handleStateChange(state, on: screen)
      }
      win.contentView = view
      win.makeKeyAndOrderFront(nil)
      win.makeFirstResponder(view)
      overlayWindows.append(win)
      views[screen] = view
    }

    toolbar?.onStart = { [weak self] in
      guard let self = self, let screen = self.activeScreen,
            let view = self.views[screen] else { return }
      view.machine.handle(.startPressed)
      self.handleStateChange(view.machine.state, on: screen)
    }
    toolbar?.onCancel = { [weak self] in
      self?.cancelAll()
    }

    return await withCheckedContinuation { cont in
      self.continuation = cont
    }
  }

  private func handleStateChange(_ state: RegionSelectionState, on screen: NSScreen) {
    // Only one screen is "active" at a time — whichever last received a mouse-down.
    let isActiveDuringSelection: Bool
    switch state {
    case .drawing, .selected, .resizing, .moving:
      isActiveDuringSelection = true
    default:
      isActiveDuringSelection = false
    }
    if isActiveDuringSelection {
      activeScreen = screen
      // Reset machines on all OTHER screens so only one rect is visible at a time.
      for (s, v) in views where s != screen {
        v.machine = RegionSelectorMachine(displayBounds: CGRect(origin: .zero, size: s.frame.size))
        v.needsDisplay = true
      }
    }

    let displayBounds = CGRect(origin: .zero, size: screen.frame.size)
    let currentRect = views[screen]?.machine.currentRect ?? .zero

    switch state {
    case .idle:
      toolbar?.hide()
    case .drawing:
      // Hide toolbar while actively drawing so it doesn't cover the readout.
      toolbar?.hide()
    case .selected:
      toolbar?.show(in: displayBounds, anchoredTo: currentRect)
    case .resizing, .moving:
      // Keep toolbar visible during resize/move so user can confirm.
      toolbar?.show(in: displayBounds, anchoredTo: currentRect)
    case .confirmed(let rect):
      finish(with: rect, on: screen)
    case .cancelled:
      cancelAll()
    }
  }

  private func finish(with rect: CGRect, on screen: NSScreen) {
    let scale = screen.backingScaleFactor
    let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    let selection = RegionSelection(
      displayId: displayId,
      x: Int(rect.minX * scale),
      y: Int(rect.minY * scale),
      widthPx: Int(rect.width * scale),
      heightPx: Int(rect.height * scale)
    )
    teardown()
    continuation?.resume(returning: selection)
    continuation = nil
  }

  private func cancelAll() {
    teardown()
    continuation?.resume(returning: nil)
    continuation = nil
  }

  private func teardown() {
    toolbar?.hide()
    toolbar = nil
    for win in overlayWindows { win.orderOut(nil) }
    overlayWindows.removeAll()
    views.removeAll()
    activeScreen = nil
    NSApp.unhide(nil)
  }
}

```

The state-handling logic is verified by Task 1's tests; this file is the AppKit glue between those state transitions and real `NSWindow`s.

- [ ] **Step 2: Run tests to verify compilation**

```bash
cd packages/screen_recorder_macos/example/macos && pod install
cd /Users/mohn93/Desktop/side_projects/screenflow_studio/packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/RegionSelector.swift
git commit -m "feat(macos): add RegionSelector public entry point

Owns one transparent NSWindow per NSScreen plus a floating
toolbar; awaits user Start/Cancel and returns RegionSelection
in display-pixel coordinates."
```

---

### Task 6: Extend ScreenCaptureManager with the region path

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift`

`startCapture` gains an optional `region: RegionSelection?` parameter; when set, it overrides the filter and config.

- [ ] **Step 1: Add the new parameter and branch**

In `packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift`, change the signature of `startCapture` from:

```swift
func startCapture(sourceId: String, fps: Int, isWindow: Bool, showCursor: Bool = true) async throws {
```

to:

```swift
func startCapture(
  sourceId: String,
  fps: Int,
  isWindow: Bool,
  region: RegionSelection? = nil,
  showCursor: Bool = true
) async throws {
```

Inside the method, replace the existing filter-construction block (the `if isWindow { ... } else { ... }` plus the resolution-setting block) with:

```swift
    // Get shareable content
    let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

    // Configure stream
    let config = SCStreamConfiguration()
    config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
    config.pixelFormat = kCVPixelFormatType_32BGRA
    config.scalesToFit = false
    config.showsCursor = showCursor
    config.queueDepth = 5

    if let region = region {
      // Region path: full-display filter + sourceRect crop.
      guard let display = content.displays.first(where: { $0.displayID == region.displayId }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      contentFilter = SCContentFilter(display: display, excludingWindows: [])
      config.sourceRect = CGRect(x: region.x, y: region.y,
                                 width: region.widthPx, height: region.heightPx)
      config.width = region.widthPx
      config.height = region.heightPx
    } else if isWindow {
      guard let windowID = UInt32(sourceId),
            let window = content.windows.first(where: { $0.windowID == windowID }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      contentFilter = SCContentFilter(desktopIndependentWindow: window)
      let scale = NSScreen.main?.backingScaleFactor ?? 1.0
      config.width = Int(window.frame.width * scale)
      config.height = Int(window.frame.height * scale)
    } else {
      guard let displayID = UInt32(sourceId),
            let display = content.displays.first(where: { $0.displayID == displayID }) else {
        throw ScreenCaptureError.invalidSourceId
      }
      let excludedApps = content.applications.filter { app in
        app.bundleIdentifier == "com.apple.finder" ||
        app.bundleIdentifier == "com.apple.dock"
      }
      contentFilter = SCContentFilter(
        display: display,
        excludingApplications: excludedApps,
        exceptingWindows: []
      )
      config.width = display.width
      config.height = display.height
    }

    streamConfiguration = config
```

Remove the old free-standing resolution block that sets `config.width`/`config.height` (it's been folded into the three branches above).

Also extend `captureDimensions(sourceId:isWindow:)` to handle the region case (used by the plugin's `startLiveRecording` to set encoder dims). Add an overload right after the existing method:

```swift
  /// Compute the actual pixel dimensions for a region capture.
  func captureDimensions(region: RegionSelection) -> (width: Int, height: Int) {
    return (region.widthPx, region.heightPx)
  }
```

- [ ] **Step 2: Run tests, verify nothing regressed**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all existing tests pass.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift
git commit -m "feat(macos): add region path to ScreenCaptureManager.startCapture"
```

---

### Task 7: Plugin handlers — selectRegion + startLiveRecording region arg (TDD)

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`
- Modify: `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift`

- [ ] **Step 1: Add the failing tests**

Append to `packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift` inside the existing class:

```swift
  func testSelectRegionMethodIsDispatched() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(methodName: "selectRegion", arguments: nil)
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      // We can't actually open windows in CI, but the dispatch should at least
      // not return FlutterMethodNotImplemented. Result will be nil (canceled
      // because no UI is showing) — that's the expected null-on-cancel value.
      XCTAssertFalse(result is FlutterMethodNotImplemented)
      exp.fulfill()
    }
    waitForExpectations(timeout: 2)
  }

  func testStartLiveRecordingRejectsBadRegionShape() {
    let plugin = ScreenRecorderMacosPlugin()
    let call = FlutterMethodCall(
      methodName: "startLiveRecording",
      arguments: [
        "source": "area",
        "frameRate": 30,
        "outputPath": "/tmp/test.mp4",
        "region": "not a map",
      ]
    )
    let exp = expectation(description: "result")
    plugin.handle(call) { result in
      let err = result as? FlutterError
      XCTAssertEqual(err?.code, "INVALID_ARGUMENTS")
      exp.fulfill()
    }
    waitForExpectations(timeout: 2)
  }
```

The first test isn't a perfect dispatch test (we can't easily simulate a full overlay flow in CI), but it does verify the handler exists and doesn't return `FlutterMethodNotImplemented`. The second verifies the region-arg shape validation.

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: build succeeds; the two new tests fail (handler returns `FlutterMethodNotImplemented`).

- [ ] **Step 3: Add dispatch case + handler**

In `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`, find the `handle` switch and add a new case after `captureThumbnail`:

```swift
    case "selectRegion":
      selectRegion(call: call, result: result)
```

Add a private handler method in the `// MARK: - Source picker` section:

```swift
  private func selectRegion(call: FlutterMethodCall, result: @escaping FlutterResult) {
    Task { @MainActor in
      let selection = await RegionSelector.shared.selectRegion()
      if let s = selection {
        result([
          "displayId": String(s.displayId),
          "x": s.x,
          "y": s.y,
          "width": s.widthPx,
          "height": s.heightPx,
        ])
      } else {
        result(nil)
      }
    }
  }
```

Now extend `startLiveRecording` to honor a `region` argument. Find the `startLiveRecording` handler (around line 343 of the file). After the existing arg parsing block (`source`, `fps`, `outputPath`, etc.), and before the `Task { ... }`, add:

```swift
    // Optional region for area capture.
    var regionSelection: RegionSelection? = nil
    if let raw = args["region"] {
      guard let map = raw as? [String: Any],
            let didStr = map["displayId"] as? String,
            let displayId = CGDirectDisplayID(didStr),
            let x = map["x"] as? Int,
            let y = map["y"] as? Int,
            let w = map["width"] as? Int,
            let h = map["height"] as? Int else {
        result(FlutterError(code: "INVALID_ARGUMENTS",
                            message: "region argument must be a map with displayId/x/y/width/height",
                            details: nil))
        return
      }
      regionSelection = RegionSelection(
        displayId: displayId, x: x, y: y, widthPx: w, heightPx: h)
    }
```

Then in the `Task { ... }` block, find the existing dimension query:

```swift
        let dims = try await captureManager!.captureDimensions(sourceId: finalSourceId, isWindow: isWindow)
        let captureWidth = dims.width
        let captureHeight = dims.height
```

Replace with:

```swift
        let captureWidth: Int
        let captureHeight: Int
        if let region = regionSelection {
          captureWidth = region.widthPx
          captureHeight = region.heightPx
        } else {
          let dims = try await captureManager!.captureDimensions(sourceId: finalSourceId, isWindow: isWindow)
          captureWidth = dims.width
          captureHeight = dims.height
        }
```

Find the existing `try await captureManager?.startCapture(sourceId: finalSourceId, fps: fps, isWindow: isWindow)` and replace with:

```swift
        try await captureManager?.startCapture(
          sourceId: finalSourceId, fps: fps, isWindow: isWindow,
          region: regionSelection)
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_macos/example
xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS'
```
Expected: all native tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift \
  packages/screen_recorder_macos/example/macos/RunnerTests/RunnerTests.swift
git commit -m "feat(macos): wire selectRegion and region arg in startLiveRecording"
```

---

### Task 8: Add RegionSelection model + method constant in platform interface (TDD)

**Files:**
- Create: `packages/screen_recorder_platform_interface/lib/src/models/region_selection.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_platform_interface/lib/src/constants.dart`
- Create: `packages/screen_recorder_platform_interface/test/models/region_selection_test.dart`

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder_platform_interface/test/models/region_selection_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('RegionSelection.fromMap', () {
    test('parses all fields', () {
      final r = RegionSelection.fromMap({
        'displayId': '69734662',
        'x': 100, 'y': 200,
        'width': 1280, 'height': 720,
      });
      expect(r.displayId, '69734662');
      expect(r.x, 100);
      expect(r.y, 200);
      expect(r.widthPx, 1280);
      expect(r.heightPx, 720);
    });

    test('round-trips through toMap', () {
      const original = RegionSelection(
          displayId: '1', x: 10, y: 20, widthPx: 100, heightPx: 200);
      final round = RegionSelection.fromMap(original.toMap());
      expect(round.displayId, '1');
      expect(round.x, 10);
      expect(round.y, 20);
      expect(round.widthPx, 100);
      expect(round.heightPx, 200);
    });
  });

  group('ScreenRecorderMethods constants', () {
    test('selectRegion constant exists', () {
      expect(ScreenRecorderMethods.selectRegion, 'selectRegion');
    });
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_platform_interface && flutter test test/models/region_selection_test.dart
```
Expected: FAIL — `RegionSelection` undefined.

- [ ] **Step 3: Create the model**

Create `packages/screen_recorder_platform_interface/lib/src/models/region_selection.dart`:

```dart
/// A user-drawn region of a specific display, in display-pixel coordinates.
class RegionSelection {
  final String displayId;
  final int x;
  final int y;
  final int widthPx;
  final int heightPx;

  const RegionSelection({
    required this.displayId,
    required this.x,
    required this.y,
    required this.widthPx,
    required this.heightPx,
  });

  Map<String, dynamic> toMap() => {
        'displayId': displayId,
        'x': x,
        'y': y,
        'width': widthPx,
        'height': heightPx,
      };

  factory RegionSelection.fromMap(Map<String, dynamic> map) {
    return RegionSelection(
      displayId: map['displayId'] as String,
      x: (map['x'] as num).toInt(),
      y: (map['y'] as num).toInt(),
      widthPx: (map['width'] as num).toInt(),
      heightPx: (map['height'] as num).toInt(),
    );
  }
}
```

- [ ] **Step 4: Add the constant and export**

In `packages/screen_recorder_platform_interface/lib/src/constants.dart`, add inside `ScreenRecorderMethods`:

```dart
  static const String selectRegion = 'selectRegion';
```

In `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`, add the export alongside the others:

```dart
export 'src/models/region_selection.dart';
```

- [ ] **Step 5: Run tests, verify they pass**

```bash
cd packages/screen_recorder_platform_interface && flutter test
```
Expected: all platform-interface tests pass.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder_platform_interface/
git commit -m "feat(platform-interface): add RegionSelection model and selectRegion method name"
```

---

### Task 9: Abstract selectRegion + region in startLiveRecording (TDD)

**Files:**
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`
- Modify: `packages/screen_recorder_platform_interface/test/screen_recorder_platform_interface_test.dart`

- [ ] **Step 1: Add the failing tests**

In `packages/screen_recorder_platform_interface/test/screen_recorder_platform_interface_test.dart`, append inside the existing `group`:

```dart
    test('selectRegion throws UnimplementedError', () {
      expect(() => p.selectRegion(), throwsA(isA<UnsupportedError>()));
    });
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder_platform_interface && flutter test
```
Expected: FAIL — `selectRegion` not on `ScreenRecorderPlatform`.

- [ ] **Step 3: Add abstract methods**

In `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`, add `import 'models/region_selection.dart';` near the other model imports.

Add this method inside the abstract class, after `captureThumbnail`:

```dart
  /// Show a full-screen overlay for region selection. Returns the chosen
  /// region in display-pixel coordinates, or null if the user cancelled.
  Future<RegionSelection?> selectRegion() {
    throw UnsupportedError('selectRegion() is not supported on this platform.');
  }
```

Update `startLiveRecording`'s signature to accept an optional region:

```dart
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) {
    throw UnsupportedError(
      'startLiveRecording() is not supported on this platform; '
      'use startRecording() with the spool-based path instead.',
    );
  }
```

(The existing default implementation throws `UnsupportedError`. Adding `region` as optional doesn't break callers.)

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder_platform_interface && flutter test
```
Expected: all tests green.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder_platform_interface/
git commit -m "feat(platform-interface): add abstract selectRegion + optional region in startLiveRecording"
```

---

### Task 10: macOS Dart adapter — selectRegion + region in startLiveRecording

**Files:**
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`

- [ ] **Step 1: Add the overrides**

In `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`, add this override at the end of the class (after `stopLiveRecording`):

```dart
  @override
  Future<RegionSelection?> selectRegion() async {
    final raw = await _recordingChannel.invokeMapMethod<String, dynamic>(
      ScreenRecorderMethods.selectRegion,
    );
    if (raw == null) return null;
    return RegionSelection.fromMap(raw);
  }
```

Update the existing `startLiveRecording` override to accept and forward `region`:

```dart
  @override
  Future<void> startLiveRecording({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    final args = <String, dynamic>{
      ...settings.toJson(),
      'outputPath': outputPath,
      'width': width,
      'height': height,
    };
    if (region != null) {
      args['region'] = region.toMap();
    }
    await _recordingChannel.invokeMethod<void>(
      ScreenRecorderMethods.startLiveRecording,
      args,
    );
  }
```

- [ ] **Step 2: Run analyze**

```bash
cd packages/screen_recorder_macos && flutter analyze
```
Expected: no errors.

- [ ] **Step 3: Commit**

```bash
git add packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart
git commit -m "feat(macos): implement selectRegion adapter; forward region in startLiveRecording"
```

---

### Task 11: RecordingState + RecordingController accept regions (TDD)

**Files:**
- Modify: `packages/screen_recorder/lib/state/recording_state.dart`
- Create: `packages/screen_recorder/test/state/recording_state_region_test.dart`

The state gains `selectedRegion: RegionSelection?`. `selectSource` accepts an optional `region`. Tab switch / null-clear nulls it. `startRecording` forwards region to `startLiveRecording`.

- [ ] **Step 1: Write the failing test**

Create `packages/screen_recorder/test/state/recording_state_region_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/recording_state.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  test('initial selectedRegion is null', () {
    final c = RecordingController();
    expect(c.state.selectedRegion, isNull);
  });

  test('selectSource with region populates selectedRegion', () {
    final c = RecordingController();
    const region = RegionSelection(
        displayId: '1', x: 0, y: 0, widthPx: 800, heightPx: 600);
    c.selectSource(
        kind: RecordingSource.area, id: '1', region: region);
    expect(c.state.selectedSourceKind, RecordingSource.area);
    expect(c.state.selectedSourceId, '1');
    expect(c.state.selectedRegion, isNotNull);
    expect(c.state.selectedRegion!.widthPx, 800);
  });

  test('selectSource(null, null) clears region too', () {
    final c = RecordingController();
    c.selectSource(
      kind: RecordingSource.area,
      id: '1',
      region: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 100, heightPx: 100),
    );
    c.selectSource(kind: null, id: null);
    expect(c.state.selectedRegion, isNull);
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder && flutter test test/state/recording_state_region_test.dart
```
Expected: FAIL — `region` parameter and `selectedRegion` field undefined.

- [ ] **Step 3: Update RecordingState + RecordingController**

In `packages/screen_recorder/lib/state/recording_state.dart`:

Add `final RegionSelection? selectedRegion;` to `RecordingState`. Add it to the constructor with a default of `null`. Add it to `copyWith` with the same `clearSelection` semantics:

```dart
class RecordingState {
  final RecordingStatus status;
  final int frameCount;
  final Duration duration;
  final String? videoPath;
  final String? error;
  final String? selectedSourceId;
  final RecordingSource? selectedSourceKind;
  final RegionSelection? selectedRegion;

  const RecordingState({
    this.status = RecordingStatus.idle,
    this.frameCount = 0,
    this.duration = Duration.zero,
    this.videoPath,
    this.error,
    this.selectedSourceId,
    this.selectedSourceKind,
    this.selectedRegion,
  });

  RecordingState copyWith({
    RecordingStatus? status,
    int? frameCount,
    Duration? duration,
    String? videoPath,
    String? error,
    String? selectedSourceId,
    RecordingSource? selectedSourceKind,
    RegionSelection? selectedRegion,
    bool clearSelection = false,
  }) {
    return RecordingState(
      status: status ?? this.status,
      frameCount: frameCount ?? this.frameCount,
      duration: duration ?? this.duration,
      videoPath: videoPath ?? this.videoPath,
      error: error,
      selectedSourceId:
          clearSelection ? null : (selectedSourceId ?? this.selectedSourceId),
      selectedSourceKind:
          clearSelection ? null : (selectedSourceKind ?? this.selectedSourceKind),
      selectedRegion:
          clearSelection ? null : (selectedRegion ?? this.selectedRegion),
    );
  }
  ...
}
```

Update `selectSource` to accept and store the region:

```dart
  void selectSource({
    required RecordingSource? kind,
    required String? id,
    RegionSelection? region,
  }) {
    if (kind == null && id == null) {
      state = state.copyWith(clearSelection: true);
      return;
    }
    state = state.copyWith(
      selectedSourceId: id,
      selectedSourceKind: kind,
      selectedRegion: region,
    );
  }
```

Update `startRecording` to forward `region`. Find the existing `_videoEncoder.start(...)` call (around line 95) and add the `region` parameter:

```dart
      await _videoEncoder.start(
        settings: settings,
        outputPath: outputPath,
        width: _defaultWidth,
        height: _defaultHeight,
        region: state.selectedRegion,
      );
```

Now update `VideoEncoder.start` in `packages/screen_recorder/lib/video_encoder.dart` to accept and forward the parameter. Replace the existing `start` method:

```dart
  Future<void> start({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
  }) async {
    _outputPath = outputPath;
    _width = width;
    _height = height;
    _fps = settings.frameRate;
    await ScreenRecorderPlatform.instance.startLiveRecording(
      settings: settings,
      outputPath: outputPath,
      width: width,
      height: height,
    );
    _isActive = true;
    AppLogger.videoEncoder.i('Live recording started: ${_width}x$_height @ ${_fps}fps -> $_outputPath');
  }
```

with:

```dart
  Future<void> start({
    required RecordingSettings settings,
    required String outputPath,
    required int width,
    required int height,
    RegionSelection? region,
  }) async {
    _outputPath = outputPath;
    _width = width;
    _height = height;
    _fps = settings.frameRate;
    await ScreenRecorderPlatform.instance.startLiveRecording(
      settings: settings,
      outputPath: outputPath,
      width: width,
      height: height,
      region: region,
    );
    _isActive = true;
    AppLogger.videoEncoder.i('Live recording started: ${_width}x$_height @ ${_fps}fps -> $_outputPath');
  }
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder && flutter test test/state/recording_state_region_test.dart
```
Expected: 3 tests pass.

Then run the full suite:

```bash
cd packages/screen_recorder && flutter test
```
Expected: all 125 + 3 = 128 tests green.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/state/recording_state.dart \
  packages/screen_recorder/lib/video_encoder.dart \
  packages/screen_recorder/test/state/recording_state_region_test.dart
git commit -m "feat(picker): RecordingController accepts regions, forwards to encoder"
```

---

### Task 12: RegionTabContent widget (TDD)

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/source_picker/region_tab_content.dart`
- Create: `packages/screen_recorder/test/widgets/source_picker/region_tab_content_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `packages/screen_recorder/test/widgets/source_picker/region_tab_content_test.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/source_picker/region_tab_content.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  Widget wrap(Widget child) => MaterialApp(
        home: Scaffold(body: child),
      );

  testWidgets('empty state shows Draw a region button', (tester) async {
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: null,
      displayName: null,
      onDraw: () {},
      isDrawing: false,
    )));
    expect(find.text('Draw a region'), findsOneWidget);
    expect(find.textContaining('Draw a region of your screen'), findsOneWidget);
  });

  testWidgets('selected state shows recap with size and display', (tester) async {
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 1280, heightPx: 720),
      displayName: 'Built-in Display',
      onDraw: () {},
      isDrawing: false,
    )));
    expect(find.textContaining('1280 × 720'), findsOneWidget);
    expect(find.textContaining('Built-in Display'), findsOneWidget);
    expect(find.text('Redraw'), findsOneWidget);
  });

  testWidgets('button tap calls onDraw', (tester) async {
    var taps = 0;
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: null,
      displayName: null,
      onDraw: () => taps++,
      isDrawing: false,
    )));
    await tester.tap(find.text('Draw a region'));
    await tester.pump();
    expect(taps, 1);
  });

  testWidgets('isDrawing disables button and shows spinner', (tester) async {
    await tester.pumpWidget(wrap(RegionTabContent(
      selection: null,
      displayName: null,
      onDraw: () {},
      isDrawing: true,
    )));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder && flutter test test/widgets/source_picker/region_tab_content_test.dart
```
Expected: FAIL — `RegionTabContent` undefined.

- [ ] **Step 3: Implement**

Create `packages/screen_recorder/lib/ui/widgets/source_picker/region_tab_content.dart`:

```dart
import 'package:flutter/material.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class RegionTabContent extends StatelessWidget {
  const RegionTabContent({
    super.key,
    required this.selection,
    required this.displayName,
    required this.onDraw,
    required this.isDrawing,
  });

  final RegionSelection? selection;
  final String? displayName;
  final VoidCallback onDraw;
  final bool isDrawing;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (selection == null)
              _buildEmpty(context)
            else
              _buildRecap(context),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.crop, size: 56, color: Colors.white38),
        const SizedBox(height: 16),
        const Text(
          'Draw a region of your screen',
          style: TextStyle(
              color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        const Text(
          'Click and drag anywhere on your desktop to capture a sub-region.',
          style: TextStyle(color: Colors.white60, fontSize: 13),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton.icon(
          onPressed: isDrawing ? null : onDraw,
          icon: isDrawing
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.crop),
          label: const Text('Draw a region'),
        ),
      ],
    );
  }

  Widget _buildRecap(BuildContext context) {
    final s = selection!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: Colors.white10,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFF6C63FF), width: 2),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${s.widthPx} × ${s.heightPx}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w600,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 6),
              Text(
                'on ${displayName ?? 'Display ${s.displayId}'}',
                style: const TextStyle(color: Colors.white60, fontSize: 13),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        TextButton.icon(
          onPressed: isDrawing ? null : onDraw,
          icon: const Icon(Icons.refresh, size: 18),
          label: const Text('Redraw'),
        ),
      ],
    );
  }
}
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder && flutter test test/widgets/source_picker/region_tab_content_test.dart
```
Expected: 4 tests pass.

- [ ] **Step 5: Commit**

```bash
git add packages/screen_recorder/lib/ui/widgets/source_picker/region_tab_content.dart \
  packages/screen_recorder/test/widgets/source_picker/region_tab_content_test.dart
git commit -m "feat(picker): add RegionTabContent widget with empty/recap states"
```

---

### Task 13: Add Region tab to RecordingScreen (TDD)

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/recording_screen.dart`
- Create: `packages/screen_recorder/test/screens/recording_screen_region_test.dart`

- [ ] **Step 1: Write the failing tests**

Create `packages/screen_recorder/test/screens/recording_screen_region_test.dart`:

```dart
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:screen_recorder/ui/screens/recording_screen.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

class _FakePlatform extends ScreenRecorderPlatform with MockPlatformInterfaceMixin {
  _FakePlatform({this.regionResult, this.screens = const []});
  final RegionSelection? regionResult;
  final List<ScreenInfo> screens;

  @override
  Future<SourceList> listSources({bool strictFilter = true}) async =>
      SourceList(screens: screens);

  @override
  Future<Uint8List?> captureThumbnail(String id, RecordingSource kind,
          {int maxDimension = 480}) async =>
      null;

  @override
  Future<RegionSelection?> selectRegion() async => regionResult;
}

void main() {
  Widget wrap(_FakePlatform p) {
    ScreenRecorderPlatform.instance = p;
    return const ProviderScope(child: MaterialApp(home: RecordingScreen()));
  }

  testWidgets('shows Region segment', (tester) async {
    await tester.pumpWidget(wrap(_FakePlatform()));
    await tester.pumpAndSettle();
    expect(find.text('Region'), findsOneWidget);
  });

  testWidgets('Region tab empty state shows Draw a region button', (tester) async {
    await tester.pumpWidget(wrap(_FakePlatform()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    expect(find.text('Draw a region'), findsOneWidget);
  });

  testWidgets('selectRegion success shows recap and enables Record', (tester) async {
    final p = _FakePlatform(
      regionResult: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 1280, heightPx: 720),
      screens: [
        const ScreenInfo(id: '1', name: 'Built-in', width: 2560, height: 1600),
      ],
    );
    await tester.pumpWidget(wrap(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw a region'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1280 × 720'), findsOneWidget);
    expect(find.text('Redraw'), findsOneWidget);
  });

  testWidgets('selectRegion null leaves empty state', (tester) async {
    final p = _FakePlatform(regionResult: null);
    await tester.pumpWidget(wrap(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw a region'));
    await tester.pumpAndSettle();
    expect(find.text('Draw a region'), findsOneWidget);
    expect(find.textContaining('×'), findsNothing);
  });

  testWidgets('switching tabs clears selectedRegion', (tester) async {
    final p = _FakePlatform(
      regionResult: const RegionSelection(
          displayId: '1', x: 0, y: 0, widthPx: 1280, heightPx: 720),
    );
    await tester.pumpWidget(wrap(p));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Draw a region'));
    await tester.pumpAndSettle();
    expect(find.textContaining('1280 × 720'), findsOneWidget);
    await tester.tap(find.text('Windows'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Region'));
    await tester.pumpAndSettle();
    expect(find.text('Draw a region'), findsOneWidget);
    expect(find.textContaining('1280 × 720'), findsNothing);
  });
}
```

- [ ] **Step 2: Run tests, verify they fail**

```bash
cd packages/screen_recorder && flutter test test/screens/recording_screen_region_test.dart
```
Expected: FAIL — Region tab doesn't exist.

- [ ] **Step 3: Update RecordingScreen**

In `packages/screen_recorder/lib/ui/screens/recording_screen.dart`:

Update the `_Tab` enum to include `region`:

```dart
enum _Tab { windows, screens, region }
```

Add a state field for the in-progress drawing:

```dart
  bool _drawingRegion = false;
```

Add an import for the new widget:

```dart
import '../widgets/source_picker/region_tab_content.dart';
```

In `_buildSegmentedControl`, add a third segment:

```dart
        segments: const [
          ButtonSegment(
              value: _Tab.windows,
              label: Text('Windows'),
              icon: Icon(Icons.window)),
          ButtonSegment(
              value: _Tab.screens,
              label: Text('Screens'),
              icon: Icon(Icons.desktop_windows)),
          ButtonSegment(
              value: _Tab.region,
              label: Text('Region'),
              icon: Icon(Icons.crop)),
        ],
```

In `_buildBody`, add a region branch BEFORE the `final items = ...` line:

```dart
    if (_tab == _Tab.region) {
      final state = ref.watch(recordingControllerProvider);
      String? displayName;
      if (state.selectedRegion != null) {
        for (final s in _sources.screens) {
          if (s.id == state.selectedRegion!.displayId) {
            displayName = s.name;
            break;
          }
        }
      }
      return RegionTabContent(
        selection: state.selectedRegion,
        displayName: displayName,
        isDrawing: _drawingRegion,
        onDraw: _drawRegion,
      );
    }
```

Add the `_drawRegion` async method to the state class:

```dart
  Future<void> _drawRegion() async {
    setState(() => _drawingRegion = true);
    try {
      final region = await ScreenRecorderPlatform.instance.selectRegion();
      if (!mounted) return;
      if (region != null) {
        ref.read(recordingControllerProvider.notifier).selectSource(
              kind: RecordingSource.area,
              id: region.displayId,
              region: region,
            );
      }
    } finally {
      if (mounted) setState(() => _drawingRegion = false);
    }
  }
```

Update `_selectedTitle` to handle the area kind:

```dart
  String? _selectedTitle(RecordingState s) {
    final id = s.selectedSourceId;
    if (id == null) return null;
    if (s.selectedSourceKind == RecordingSource.window) {
      for (final w in _sources.windows) {
        if (w.id == id) return w.title;
      }
      return null;
    }
    if (s.selectedSourceKind == RecordingSource.screen) {
      for (final scr in _sources.screens) {
        if (scr.id == id) return scr.name;
      }
      return null;
    }
    if (s.selectedSourceKind == RecordingSource.area && s.selectedRegion != null) {
      final r = s.selectedRegion!;
      String? screenName;
      for (final scr in _sources.screens) {
        if (scr.id == r.displayId) { screenName = scr.name; break; }
      }
      return '${r.widthPx} × ${r.heightPx} on ${screenName ?? 'Display ${r.displayId}'}';
    }
    return null;
  }
```

- [ ] **Step 4: Run tests, verify they pass**

```bash
cd packages/screen_recorder && flutter test
```
Expected: full suite green (existing 125 + Task 11's 3 + Task 12's 4 + Task 13's 5 = 137 tests).

- [ ] **Step 5: Run analyze and native suite**

```bash
cd packages/screen_recorder && flutter analyze lib/
cd packages/screen_recorder_macos/example && xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' 2>&1 | grep -E "(TEST SUCCEEDED|TEST FAILED)"
```
Expected: clean analyze; native tests still pass.

- [ ] **Step 6: Commit**

```bash
git add packages/screen_recorder/lib/ui/screens/recording_screen.dart \
  packages/screen_recorder/test/screens/recording_screen_region_test.dart
git commit -m "feat(picker): add Region tab with selectRegion flow"
```

---

### Task 14: Manual checklist + final verification

**Files:**
- Modify: `MANUAL_TESTING_CHECKLIST.md`

- [ ] **Step 1: Append the manual checklist**

Append to `MANUAL_TESTING_CHECKLIST.md`:

```markdown

## Region Capture (2026-04-29)

- [ ] Region tab visible in segmented control with crop icon.
- [ ] Click Region tab on first launch → empty state with "Draw a region" button.
- [ ] Click "Draw a region" → app minimizes; transparent overlay appears across every connected display with the desktop dimmed.
- [ ] Click-drag → live `W × H` readout follows cursor; rect outlined in purple.
- [ ] Release → 8 resize handles appear at corners + edge midpoints; floating Start/Cancel toolbar appears at bottom-right of the rect.
- [ ] Drag a corner handle → rect resizes; toolbar follows.
- [ ] Drag an edge midpoint handle → resizes that axis only.
- [ ] Drag inside the rect → rect translates; toolbar follows.
- [ ] Drag past display edge → rect clips at the display boundary.
- [ ] Press Esc → overlay closes everywhere; app restores; Region tab still in empty state.
- [ ] Click Cancel → same as Esc.
- [ ] Click Start → overlay closes; app restores; Region tab now shows recap card with the chosen size and display name; Record button enabled.
- [ ] Click Record → recording captures only the chosen region at the rect's pixel size.
- [ ] Stop → playback shows exactly the region you drew (no scaling, correct aspect ratio).
- [ ] Switch to Windows tab → Region selection clears; switching back to Region tab shows empty state.
- [ ] Multi-display: drag rect on a secondary display, record, verify the secondary display's pixels are captured.
```

- [ ] **Step 2: Run the full verification gate**

```bash
cd packages/screen_recorder && flutter test
cd packages/screen_recorder_platform_interface && flutter test
cd packages/screen_recorder_macos/example && xcodebuild test -workspace macos/Runner.xcworkspace -scheme Runner -destination 'platform=macOS' 2>&1 | grep -E "(TEST SUCCEEDED|TEST FAILED)"
cd packages/screen_recorder && flutter analyze
cd packages/screen_recorder_platform_interface && flutter analyze
cd packages/screen_recorder_macos && flutter analyze
```
Expected: all green; pre-existing info-level warnings about `avoid_print` in examples are acceptable.

- [ ] **Step 3: Commit**

```bash
git add MANUAL_TESTING_CHECKLIST.md
git commit -m "docs: add region capture manual checklist"
```

---

## Final acceptance

- All new tests pass (Dart + native).
- Existing 163 tests still green.
- Region recording produces a video at the rect's pixel dimensions; metadata sidecar matches.
- Window and screen recording paths unchanged from regression baseline.
- Selection overlay appears on every connected display; Esc / Cancel cleanly tear it down.
