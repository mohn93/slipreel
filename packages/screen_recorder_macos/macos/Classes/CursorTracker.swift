import ApplicationServices
import Cocoa
import Foundation
import QuartzCore

/// Tracks cursor position and click events at high frequency
class CursorTracker: NSObject {
  // MARK: - Properties

  private var positionTimer: Timer?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var isTracking = false
  private var lastMouseLocation: NSPoint = .zero
  private var isMouseDown = false

  // Throttle AX-based cursor-state queries. AXUIElementCopyElementAtPosition
  // costs a few ms per call (cross-process IPC into the hovered app),
  // so running it at the 60 Hz position-sample rate would burn ~10%
  // CPU just for cursor state. We re-query at most every
  // [stateQueryIntervalSec] seconds OR when the cursor has moved more
  // than [stateQueryMoveThresholdPx] pixels since the last query —
  // whichever comes first. State changes are gated on hover transitions
  // (entering a text field, etc.) which always involve a cursor move
  // first, so this rarely misses one.
  private static let stateQueryIntervalSec: CFTimeInterval = 0.10
  private static let stateQueryMoveThresholdPx: Double = 4
  private var lastStateQueryTime: CFTimeInterval = 0
  private var lastStateQueryLocation: NSPoint = .zero
  private var lastDetectedStateName: String = "arrow"

  // Callback for cursor data: x, y, timestampMicros, isClicked, stateWireName.
  // The wire-name string matches CursorState.wireName on the Dart side
  // (e.g. "arrow", "iBeam", "pointingHand"). "arrow" is the fallback
  // for any cursor we don't recognise, so the field is always populated.
  var onCursorUpdate: ((Double, Double, Int64, Bool, String) -> Void)?
  var onError: ((Error) -> Void)?

  // MARK: - Tracking Control

  /// Start tracking cursor position and clicks
  /// - Parameter frequency: Updates per second (default: 60)
  func startTracking(frequency: Int = 60) throws {
    guard !isTracking else {
      throw CursorTrackerError.alreadyTracking
    }

    // Cursor-state detection uses the Accessibility API; without that
    // permission we can still track position/click, but every state
    // sample will fall through to "arrow". Log once at startup so the
    // user knows why their I-beam / pointing-hand transitions aren't
    // being captured, without spamming the log per frame.
    if !AXIsProcessTrusted() {
      print(
        "[CursorTracker] Accessibility permission not granted — cursor state "
          + "(I-beam, pointing hand, resize, etc.) won't be captured. "
          + "Grant access in System Settings > Privacy & Security > Accessibility.")
    }

    // Set up position sampling timer. We explicitly schedule on the main
    // runloop because startTracking can be called from a Task whose
    // executor is a background queue — Timer.scheduledTimer in that
    // context schedules on the background runloop, which never pumps,
    // and the timer fires exactly zero times. Adding to .main with
    // .common keeps it firing during scroll/drag too.
    let interval = 1.0 / Double(frequency)
    let timer = Timer(
      timeInterval: interval,
      repeats: true
    ) { [weak self] _ in
      self?.captureCurrentPosition()
    }
    RunLoop.main.add(timer, forMode: .common)
    positionTimer = timer
    // Capture an initial position immediately so the first frame of
    // recording always has a sample, regardless of when the timer fires.
    captureCurrentPosition()

    // Set up global event monitor for clicks (when app is not focused)
    globalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    ) { [weak self] event in
      self?.handleMouseEvent(event)
    }

    // Set up local event monitor for clicks (when app is focused)
    localMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    ) { [weak self] event in
      self?.handleMouseEvent(event)
      return event
    }

    isTracking = true
  }

  /// Stop tracking cursor
  func stopTracking() {
    guard isTracking else { return }

    // Stop timer
    positionTimer?.invalidate()
    positionTimer = nil

    // Remove event monitors
    if let monitor = globalMonitor {
      NSEvent.removeMonitor(monitor)
      globalMonitor = nil
    }

    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }

    isTracking = false
    isMouseDown = false
  }

  // MARK: - Private Methods

  private func captureCurrentPosition() {
    // Get current mouse location in screen coordinates
    let location = NSEvent.mouseLocation
    lastMouseLocation = location

    // Get timestamp in microseconds
    let timestamp = getTimestampMicros()

    // Identify which stock cursor the system is currently showing.
    // Must run on the main thread because NSCursor APIs are
    // main-thread-only — the timer's already on the main runloop, so
    // this is a direct call.
    let state = detectCursorStateName()

    // Send cursor data via callback
    onCursorUpdate?(location.x, location.y, timestamp, isMouseDown, state)
  }

  /// Returns the wire-name of the cursor state at [location] by
  /// asking the Accessibility API which UI element the user is
  /// hovering over and mapping its role to a cursor.
  ///
  /// Why AX and not NSCursor.currentSystem: `NSCursor.currentSystem`
  /// only reports the cursor inside the recorder's own window context.
  /// Hovering over a text field in Safari, Notes, or any other app
  /// always returns the recorder process's idle arrow — useless for
  /// a screen recorder. The system-wide AXUIElement
  /// (`AXUIElementCreateSystemWide`) plus `AXUIElementCopyElementAtPosition`
  /// works cross-app: it walks the host app's UI tree and tells us
  /// the role of the element under the cursor regardless of which
  /// app owns it.
  ///
  /// Requires the Accessibility permission. Without it AX returns
  /// `kAXErrorCannotComplete` / nil and we fall back to "arrow".
  ///
  /// Throttled internally — see [stateQueryIntervalSec].
  private func detectCursorStateName() -> String {
    let now = CACurrentMediaTime()
    let location = NSEvent.mouseLocation
    let dx = location.x - lastStateQueryLocation.x
    let dy = location.y - lastStateQueryLocation.y
    let movedDistance = (dx * dx + dy * dy).squareRoot()
    if now - lastStateQueryTime < Self.stateQueryIntervalSec
      && movedDistance < Self.stateQueryMoveThresholdPx
    {
      return lastDetectedStateName
    }
    lastStateQueryTime = now
    lastStateQueryLocation = location

    let detected = queryAccessibilityCursorStateName(at: location)
    lastDetectedStateName = detected
    return detected
  }

  /// AX-coordinates space query. NSEvent.mouseLocation gives Cocoa
  /// coordinates (origin bottom-left of the main display); AX expects
  /// CG / Quartz coordinates (origin top-left of the screen the point
  /// falls on). Flips Y using the screen the point lies in, then walks
  /// up to 3 ancestors so a hit on a child Text node still resolves
  /// to its parent text field's role.
  private func queryAccessibilityCursorStateName(at cocoaLocation: NSPoint)
    -> String
  {
    let screen = NSScreen.screens.first(where: { $0.frame.contains(cocoaLocation) })
      ?? NSScreen.main
    guard let screen = screen else { return "arrow" }
    let axX = cocoaLocation.x
    let axY = screen.frame.maxY - cocoaLocation.y

    let system = AXUIElementCreateSystemWide()
    var element: AXUIElement?
    let result = AXUIElementCopyElementAtPosition(
      system, Float(axX), Float(axY), &element)
    guard result == .success, var current = element else { return "arrow" }

    // Walk up at most 3 ancestors looking for a role that maps to a
    // non-arrow cursor. Some apps wrap text fields in nameless groups
    // and the leaf element under the cursor may be a child Text or
    // similar — its parent is the AXTextField we actually want.
    for _ in 0..<3 {
      var roleRef: CFTypeRef?
      let roleResult = AXUIElementCopyAttributeValue(
        current, kAXRoleAttribute as CFString, &roleRef)
      if roleResult == .success, let role = roleRef as? String {
        let mapped = mapAXRoleToCursorStateName(role)
        if mapped != "arrow" {
          return mapped
        }
      }

      var parentRef: CFTypeRef?
      let parentResult = AXUIElementCopyAttributeValue(
        current, kAXParentAttribute as CFString, &parentRef)
      guard parentResult == .success, let parent = parentRef else { break }
      // The AX API guarantees the parent attribute is an AXUIElement
      // when the call succeeds. Force-bridge via CFTypeID check to
      // avoid crashing on misbehaving 3rd-party AX providers.
      guard CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
      current = (parent as! AXUIElement)
    }
    return "arrow"
  }

  /// Maps an AX role string (e.g. "AXTextField") to a CursorState
  /// wire name. Conservative: anything we don't have a confident
  /// mapping for falls through to "arrow" rather than guessing.
  private func mapAXRoleToCursorStateName(_ role: String) -> String {
    switch role {
    case "AXTextField", "AXTextArea", "AXSecureTextField",
      "AXSearchField", "AXComboBox":
      return "iBeam"
    case "AXLink":
      return "pointingHand"
    case "AXSplitter":
      // AX doesn't tell us splitter orientation reliably; pick EW
      // since horizontal splitters (sidebar dividers) are most common.
      return "resizeEW"
    default:
      return "arrow"
    }
  }

  private func handleMouseEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .rightMouseDown:
      isMouseDown = true
      // Immediately capture position with click state
      captureCurrentPosition()

    case .leftMouseUp, .rightMouseUp:
      isMouseDown = false
      // Immediately capture position with released state
      captureCurrentPosition()

    default:
      break
    }
  }

  private func getTimestampMicros() -> Int64 {
    var timebaseInfo = mach_timebase_info()
    mach_timebase_info(&timebaseInfo)
    let timestamp = mach_absolute_time()
    let nanoseconds = timestamp * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    return Int64(nanoseconds / 1000)
  }

  /// Check if currently tracking
  func isCurrentlyTracking() -> Bool {
    return isTracking
  }
}

// MARK: - Error Types

enum CursorTrackerError: LocalizedError {
  case alreadyTracking
  case notTracking
  case permissionDenied

  var errorDescription: String? {
    switch self {
    case .alreadyTracking:
      return "Cursor tracking is already in progress."
    case .notTracking:
      return "No cursor tracking session is active."
    case .permissionDenied:
      return "Accessibility permission denied. Please grant permission in System Preferences > Privacy & Security > Accessibility."
    }
  }
}
