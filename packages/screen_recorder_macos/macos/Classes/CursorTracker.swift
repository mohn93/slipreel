import Cocoa
import Foundation

/// Tracks cursor position and click events at high frequency
class CursorTracker: NSObject {
  // MARK: - Properties

  private var positionTimer: Timer?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var isTracking = false
  private var lastMouseLocation: NSPoint = .zero
  private var isMouseDown = false

  // Callback for cursor data
  var onCursorUpdate: ((Double, Double, Int64, Bool) -> Void)?
  var onError: ((Error) -> Void)?

  // MARK: - Tracking Control

  /// Start tracking cursor position and clicks
  /// - Parameter frequency: Updates per second (default: 60)
  func startTracking(frequency: Int = 60) throws {
    guard !isTracking else {
      throw CursorTrackerError.alreadyTracking
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

    // Send cursor data via callback
    onCursorUpdate?(location.x, location.y, timestamp, isMouseDown)
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
