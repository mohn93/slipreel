import XCTest
@testable import screen_recorder_macos

final class CursorCoordinateMapperTests: XCTestCase {
  // MARK: - mapForScreen

  /// Cursor at the display's bottom-left global corner — which is the
  /// origin in AppKit's coord system — must land on the video's
  /// top-left (0, 0) because the video uses top-left origin.
  func testScreenBottomLeftMapsToVideoTopLeft() {
    let p = CursorCoordinateMapper.mapForScreen(
      cursorGlobalX: 0, cursorGlobalY: 0,
      displayMinX: 0, displayMaxY: 1117,
      displayWidthPts: 1728, displayHeightPts: 1117,
      videoWidthPx: 1728, videoHeightPx: 1117)
    XCTAssertEqual(p.x, 0, accuracy: 1e-6)
    XCTAssertEqual(p.y, 1117, accuracy: 1e-6)
  }

  /// Cursor at the display's top-left global corner (max-Y, min-X)
  /// must map to the video's (0, 0).
  func testScreenTopLeftMapsToVideoOrigin() {
    let p = CursorCoordinateMapper.mapForScreen(
      cursorGlobalX: 0, cursorGlobalY: 1117,
      displayMinX: 0, displayMaxY: 1117,
      displayWidthPts: 1728, displayHeightPts: 1117,
      videoWidthPx: 1728, videoHeightPx: 1117)
    XCTAssertEqual(p.x, 0, accuracy: 1e-6)
    XCTAssertEqual(p.y, 0, accuracy: 1e-6)
  }

  /// Cursor at the display's top-right corner must map to the video's
  /// far-right edge.
  func testScreenTopRightMapsToVideoTopRight() {
    let p = CursorCoordinateMapper.mapForScreen(
      cursorGlobalX: 1728, cursorGlobalY: 1117,
      displayMinX: 0, displayMaxY: 1117,
      displayWidthPts: 1728, displayHeightPts: 1117,
      videoWidthPx: 1728, videoHeightPx: 1117)
    XCTAssertEqual(p.x, 1728, accuracy: 1e-6)
    XCTAssertEqual(p.y, 0, accuracy: 1e-6)
  }

  /// Apple-Silicon "logical-resolution capture" case: display reports
  /// backingScaleFactor 2.0 but SCStream captures at 1728×1117 (point
  /// resolution, not 3456×2234 backing pixels). Effective scale is 1.0
  /// — derived from videoWidthPx/displayWidthPts, not from backing.
  func testScreenLogicalResolutionCapture() {
    // Cursor at display midpoint.
    let p = CursorCoordinateMapper.mapForScreen(
      cursorGlobalX: 864, cursorGlobalY: 558.5,
      displayMinX: 0, displayMaxY: 1117,
      displayWidthPts: 1728, displayHeightPts: 1117,
      videoWidthPx: 1728, videoHeightPx: 1117)
    XCTAssertEqual(p.x, 864, accuracy: 1e-6)
    XCTAssertEqual(p.y, 558.5, accuracy: 1e-6)
  }

  /// Backing-resolution capture: same display, but SCStream returns
  /// 3456×2234. Effective scale becomes 2.0.
  func testScreenBackingResolutionCapture() {
    let p = CursorCoordinateMapper.mapForScreen(
      cursorGlobalX: 864, cursorGlobalY: 558.5,
      displayMinX: 0, displayMaxY: 1117,
      displayWidthPts: 1728, displayHeightPts: 1117,
      videoWidthPx: 3456, videoHeightPx: 2234)
    XCTAssertEqual(p.x, 1728, accuracy: 1e-6)
    XCTAssertEqual(p.y, 1117, accuracy: 1e-6)
  }

  /// Multi-display: cursor on the secondary monitor (positioned to the
  /// right of the primary in global coords). The mapper must subtract
  /// the secondary's `minX` so the cursor lands inside the captured
  /// frame, not 1920+ pixels off-screen.
  func testScreenSecondaryDisplayOffsetIsSubtracted() {
    let p = CursorCoordinateMapper.mapForScreen(
      cursorGlobalX: 1920 + 500, cursorGlobalY: 600,
      displayMinX: 1920, displayMaxY: 1080,
      displayWidthPts: 1920, displayHeightPts: 1080,
      videoWidthPx: 1920, videoHeightPx: 1080)
    XCTAssertEqual(p.x, 500, accuracy: 1e-6)
    XCTAssertEqual(p.y, 480, accuracy: 1e-6)
  }

  /// Non-square pixel ratio: display 16:9 captured at the same aspect
  /// but a different resolution must scale x and y independently.
  func testScreenNonUniformScalePerAxis() {
    let p = CursorCoordinateMapper.mapForScreen(
      cursorGlobalX: 800, cursorGlobalY: 450,
      displayMinX: 0, displayMaxY: 900,
      displayWidthPts: 1600, displayHeightPts: 900,
      videoWidthPx: 800, videoHeightPx: 600)
    // x: 800 pts / 1600 pts * 800 px = 400
    // y_in_pts: 900 - 450 = 450; 450 pts / 900 pts * 600 px = 300
    XCTAssertEqual(p.x, 400, accuracy: 1e-6)
    XCTAssertEqual(p.y, 300, accuracy: 1e-6)
  }

  // MARK: - mapForArea

  /// Region anchored at the display's top-left; cursor at the
  /// region's top-left corner must map to video (0, 0).
  func testAreaCursorAtRegionTopLeftMapsToVideoOrigin() {
    // Region 800×600 starting at top-left of a 1728×1117 retina display.
    // backingScale = 2, region origin in pixels = (0, 0).
    // The region's top-left in global pts is (0, 1117-0/2) = (0, 1117).
    let p = CursorCoordinateMapper.mapForArea(
      cursorGlobalX: 0, cursorGlobalY: 1117,
      displayMinX: 0, displayMaxY: 1117,
      backingScale: 2,
      regionXPx: 0, regionYPx: 0)
    XCTAssertEqual(p.x, 0, accuracy: 1e-6)
    XCTAssertEqual(p.y, 0, accuracy: 1e-6)
  }

  /// Cursor at a known point inside a region, retina display.
  /// Verifies the (gx − displayMinX − regionPx/scale) * scale formula.
  func testAreaCursorInsideRegionRetina() {
    // Display 0..1728 pts × 0..1117 pts (origin at 0,0 globally).
    // Region 400×300 px starting at pixel (200, 200) on the display.
    // Region origin in pts: (100, 100) from display top-left.
    // Cursor at global (150, 1017) pts:
    //   x_in_display_pts = 150 - 0 = 150
    //   y_in_display_pts = 1117 - 1017 = 100
    //   x_px = (150 - 100) * 2 = 100
    //   y_px = (100 - 100) * 2 = 0
    let p = CursorCoordinateMapper.mapForArea(
      cursorGlobalX: 150, cursorGlobalY: 1017,
      displayMinX: 0, displayMaxY: 1117,
      backingScale: 2,
      regionXPx: 200, regionYPx: 200)
    XCTAssertEqual(p.x, 100, accuracy: 1e-6)
    XCTAssertEqual(p.y, 0, accuracy: 1e-6)
  }

  /// Area on a non-retina display: backingScale = 1, region in pixels
  /// equals region in points.
  func testAreaNonRetina() {
    let p = CursorCoordinateMapper.mapForArea(
      cursorGlobalX: 250, cursorGlobalY: 800,
      displayMinX: 0, displayMaxY: 900,
      backingScale: 1,
      regionXPx: 100, regionYPx: 50)
    // x_in_display_pts = 250
    // y_in_display_pts = 900 - 800 = 100
    // x_px = (250 - 100) * 1 = 150
    // y_px = (100 - 50) * 1 = 50
    XCTAssertEqual(p.x, 150, accuracy: 1e-6)
    XCTAssertEqual(p.y, 50, accuracy: 1e-6)
  }

  /// Multi-display area capture: region on the secondary monitor.
  /// Display offset must be subtracted before applying region offset.
  func testAreaSecondaryDisplay() {
    // Secondary display at globalMinX = 1920, height 1080 pts.
    // Region 400×300 px at pixel (200, 100), backingScale 2 → in pts: (100, 50).
    // Cursor at global (1920+150, 1080-50) = (2070, 1030):
    //   x_in_display_pts = 2070 - 1920 = 150
    //   y_in_display_pts = 1080 - 1030 = 50
    //   x_px = (150 - 100) * 2 = 100
    //   y_px = (50 - 50) * 2 = 0
    let p = CursorCoordinateMapper.mapForArea(
      cursorGlobalX: 2070, cursorGlobalY: 1030,
      displayMinX: 1920, displayMaxY: 1080,
      backingScale: 2,
      regionXPx: 200, regionYPx: 100)
    XCTAssertEqual(p.x, 100, accuracy: 1e-6)
    XCTAssertEqual(p.y, 0, accuracy: 1e-6)
  }

  // MARK: - mapForWindow

  /// Window 800×600 at Quartz (200, 100) on a 1920×1080 primary
  /// display, non-retina. Cursor at the window's top-left corner (in
  /// Cocoa coords: x=200, y=primaryHeight−windowY=980) must map to
  /// video (0, 0).
  func testWindowCursorAtTopLeftMapsToVideoOrigin() {
    let p = CursorCoordinateMapper.mapForWindow(
      cursorGlobalX: 200, cursorGlobalY: 980,
      windowQuartzX: 200, windowQuartzY: 100,
      primaryScreenHeightPts: 1080,
      pixelsPerPointX: 1.0, pixelsPerPointY: 1.0)
    XCTAssertEqual(p.x, 0, accuracy: 1e-6)
    XCTAssertEqual(p.y, 0, accuracy: 1e-6)
  }

  /// Same window, cursor at the bottom-right corner. Window's bottom-
  /// right in Quartz is (1000, 700); in Cocoa that's (1000, 380). Must
  /// land on the video's far corner (800, 600).
  func testWindowCursorAtBottomRightMapsToVideoFarCorner() {
    let p = CursorCoordinateMapper.mapForWindow(
      cursorGlobalX: 1000, cursorGlobalY: 380,
      windowQuartzX: 200, windowQuartzY: 100,
      primaryScreenHeightPts: 1080,
      pixelsPerPointX: 1.0, pixelsPerPointY: 1.0)
    XCTAssertEqual(p.x, 800, accuracy: 1e-6)
    XCTAssertEqual(p.y, 600, accuracy: 1e-6)
  }

  /// Cursor in the centre of the window — sanity for the linear
  /// interior.
  func testWindowCursorAtCenter() {
    // Center in Quartz: (200+400, 100+300) = (600, 400).
    // Center in Cocoa: (600, 1080−400) = (600, 680).
    let p = CursorCoordinateMapper.mapForWindow(
      cursorGlobalX: 600, cursorGlobalY: 680,
      windowQuartzX: 200, windowQuartzY: 100,
      primaryScreenHeightPts: 1080,
      pixelsPerPointX: 1.0, pixelsPerPointY: 1.0)
    XCTAssertEqual(p.x, 400, accuracy: 1e-6)
    XCTAssertEqual(p.y, 300, accuracy: 1e-6)
  }

  /// Retina capture: 800×600-pt window captured at 1600×1200 px (×2
  /// backing). Cursor at the window's centre → video pixel (800, 600).
  func testWindowRetinaScale() {
    let p = CursorCoordinateMapper.mapForWindow(
      cursorGlobalX: 600, cursorGlobalY: 680,
      windowQuartzX: 200, windowQuartzY: 100,
      primaryScreenHeightPts: 1080,
      pixelsPerPointX: 2.0, pixelsPerPointY: 2.0)
    XCTAssertEqual(p.x, 800, accuracy: 1e-6)
    XCTAssertEqual(p.y, 600, accuracy: 1e-6)
  }

  /// Live-tracking sanity: the window dragged from (200, 100) to
  /// (500, 50). Cursor stays at the window's top-left throughout; the
  /// mapped output must remain (0, 0) at both positions because the
  /// closure calls fetchWindowBounds on each sample (the mapper is
  /// pure — the plugin's closure is what's live).
  func testWindowDraggedKeepsTopLeftMapping() {
    // Before drag: window at (200, 100). Cursor at top-left → Cocoa
    // (200, 980).
    let beforeDrag = CursorCoordinateMapper.mapForWindow(
      cursorGlobalX: 200, cursorGlobalY: 980,
      windowQuartzX: 200, windowQuartzY: 100,
      primaryScreenHeightPts: 1080,
      pixelsPerPointX: 1.0, pixelsPerPointY: 1.0)
    XCTAssertEqual(beforeDrag.x, 0, accuracy: 1e-6)
    XCTAssertEqual(beforeDrag.y, 0, accuracy: 1e-6)

    // After drag: window at (500, 50). Cursor at top-left → Cocoa
    // (500, 1030). Same (0, 0) output.
    let afterDrag = CursorCoordinateMapper.mapForWindow(
      cursorGlobalX: 500, cursorGlobalY: 1030,
      windowQuartzX: 500, windowQuartzY: 50,
      primaryScreenHeightPts: 1080,
      pixelsPerPointX: 1.0, pixelsPerPointY: 1.0)
    XCTAssertEqual(afterDrag.x, 0, accuracy: 1e-6)
    XCTAssertEqual(afterDrag.y, 0, accuracy: 1e-6)
  }

  /// Window on a secondary display arranged ABOVE the primary. In
  /// Quartz, the secondary occupies negative Y; the Cocoa→Quartz flip
  /// must still produce the right window-relative coordinate.
  func testWindowOnSecondaryDisplayAbovePrimary() {
    // Primary: 1920×1080 at Quartz (0, 0). Secondary above primary:
    // Quartz (0, -900) to (1280, 0). Window at (100, -800), size
    // 1280×720. Cursor at window's top-left: Quartz (100, -800) →
    // Cocoa (100, 1080 − (−800)) = (100, 1880).
    let p = CursorCoordinateMapper.mapForWindow(
      cursorGlobalX: 100, cursorGlobalY: 1880,
      windowQuartzX: 100, windowQuartzY: -800,
      primaryScreenHeightPts: 1080,
      pixelsPerPointX: 1.0, pixelsPerPointY: 1.0)
    XCTAssertEqual(p.x, 0, accuracy: 1e-6)
    XCTAssertEqual(p.y, 0, accuracy: 1e-6)
  }
}
