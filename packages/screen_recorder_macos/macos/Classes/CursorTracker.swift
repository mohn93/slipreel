import Cocoa
import Foundation
import QuartzCore

// MARK: - Private CoreGraphics symbols
//
// These read the live cursor image directly from the WindowServer
// regardless of which app drew the cursor. They've been used by
// macOS screen recorders (OBS, Loom, CleanShot, Screen Studio…) for
// over a decade and have been stable across every shipping macOS
// release — but they're undocumented and Apple moved them between
// frameworks over the years (CoreGraphics → SkyLight on newer
// macOS). To avoid pinning ourselves to one location, we resolve
// both symbols at runtime via `dlsym`, falling back through every
// framework they've ever lived in. If a future macOS removes them
// entirely the lookup returns `nil` and `detectCursorStateName`
// degrades to holding the last detected state instead of crashing.
//
// `@convention(c)` makes the typealiases callable from Swift; the
// function-pointer cast is the same trick `os_unfair_lock` and
// other Apple-internal helpers use when they ship through dlsym.

private typealias _CGSConnectionID = Int32
private typealias _CGSMainConnectionIDFn = @convention(c) ()
  -> _CGSConnectionID
private typealias _CGSCopyCurrentCursorImageFn = @convention(c) (
  _CGSConnectionID
) -> Unmanaged<CGImage>?

/// Search RTLD_DEFAULT first (everything currently loaded — usually
/// catches CGS symbols because AppKit pulls SkyLight in at launch),
/// then fall back to explicit `dlopen` on every framework path the
/// CGS namespace has been spotted in over the years.
private func _resolveCGSPrivate(_ name: String) -> UnsafeMutableRawPointer? {
  let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
  if let sym = dlsym(rtldDefault, name) {
    return sym
  }
  let candidates = [
    "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight",
    "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics",
    "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/Frameworks/CoreGraphics.framework/CoreGraphics",
  ]
  for path in candidates {
    guard let handle = dlopen(path, RTLD_LAZY) else { continue }
    if let sym = dlsym(handle, name) { return sym }
  }
  return nil
}

private let _cgsMainConnectionID: _CGSMainConnectionIDFn? = {
  guard let sym = _resolveCGSPrivate("CGSMainConnectionID") else { return nil }
  return unsafeBitCast(sym, to: _CGSMainConnectionIDFn.self)
}()

private let _cgsCopyCurrentCursorImage: _CGSCopyCurrentCursorImageFn? = {
  guard let sym = _resolveCGSPrivate("CGSCopyCurrentCursorImage")
  else { return nil }
  return unsafeBitCast(sym, to: _CGSCopyCurrentCursorImageFn.self)
}()

/// Tracks cursor position and click events at high frequency.
///
/// Cursor *type* (arrow vs hand vs I-beam vs resize…) is classified
/// by sampling the live system cursor image via the private
/// `CGSCopyCurrentCursorImage` API and matching it against a library
/// of pre-fingerprinted `NSCursor` reference images. This works for
/// any cursor the OS is drawing — Flutter / Electron / web apps,
/// custom `pointingHandCursor` calls, Safari links — without needing
/// the Accessibility permission and without caring about the recorded
/// app's AX semantics.
class CursorTracker: NSObject {
  // MARK: - Properties

  private var positionTimer: Timer?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var isTracking = false
  private var lastMouseLocation: NSPoint = .zero
  private var isMouseDown = false

  // Throttle cursor-image classification. Each call is cheap
  // (~tens of microseconds for `CGSCopyCurrentCursorImage` plus the
  // 8×8 grayscale resample) but there's no value in re-classifying
  // every 60 Hz position sample — the cursor type only changes when
  // the user moves into a new element. We re-query at most every
  // [stateQueryIntervalSec] seconds OR when the cursor has moved more
  // than [stateQueryMoveThresholdPx] pixels since the last query —
  // whichever fires first.
  private static let stateQueryIntervalSec: CFTimeInterval = 0.10
  private static let stateQueryMoveThresholdPx: Double = 4
  private var lastStateQueryTime: CFTimeInterval = 0
  private var lastStateQueryLocation: NSPoint = .zero
  private var lastDetectedStateName: String = "arrow"
  // Count of diagnostic samples printed so far. Caps the log spam at
  // ~60 queries (≈6 s at the 10 Hz throttle) so we can diagnose what
  // the classifier is seeing without flooding the console.
  private var diagnosticSampleCount: Int = 0

  // Pre-computed perceptual fingerprints for every stock NSCursor we
  // recognise. Each entry is a 64-bit "average hash": the cursor
  // image is resized to 8×8 grayscale, the average pixel value is
  // computed, and every pixel becomes one bit (1 if brighter than the
  // average, 0 otherwise). Live cursor images are hashed the same way
  // and matched by Hamming distance. The stock cursors differ by far
  // more than 8 bits from each other, so a Hamming threshold of 8
  // cleanly separates "recognised" from "unknown custom cursor".
  //
  // `static let` is thread-safe (dispatch_once underneath) so every
  // tracker instance shares the same library.
  private static let cursorLibrary: [(String, UInt64)] = buildCursorLibrary()

  private static func buildCursorLibrary() -> [(String, UInt64)] {
    // CursorState wire names — must match `CursorState.wireName` on
    // the Dart side (see screen_recorder_platform_interface).
    var entries: [(String, NSCursor)] = [
      ("arrow", .arrow),
      ("iBeam", .iBeam),
      ("pointingHand", .pointingHand),
      ("crosshair", .crosshair),
      ("resizeNS", .resizeUpDown),
      ("resizeEW", .resizeLeftRight),
      ("openHand", .openHand),
      ("closedHand", .closedHand),
      ("notAllowed", .operationNotAllowed),
    ]
    // Diagonal resize cursors have no public NSCursor accessor — Apple
    // ships them through private selectors that have existed since
    // 10.7. We pick them up via respondsToSelector + performSelector
    // so a future macOS that removes them just gracefully falls back
    // to the existing polygon glyph on the Dart side. No crash, no
    // App-Store rejection risk because we don't link against private
    // symbols; we just message-send by name at runtime.
    if let nesw = privateResizeCursor(selector: "_windowResizeNorthEastSouthWestCursor") {
      entries.append(("resizeNESW", nesw))
    }
    if let nwse = privateResizeCursor(selector: "_windowResizeNorthWestSouthEastCursor") {
      entries.append(("resizeNWSE", nwse))
    }
    return entries.compactMap { (name, cursor) in
      guard let cg = cursor.image.cgImage(
        forProposedRect: nil, context: nil, hints: nil)
      else { return nil }
      return (name, averageHash(of: cg))
    }
  }

  /// Resolve a private NSCursor class selector by name. Returns nil
  /// when the selector isn't present on the running macOS, so callers
  /// can just `if let` the result and skip the entry. We dispatch via
  /// `AnyObject` because perform(_:) is an NSObjectProtocol instance
  /// method — sending it to `NSCursor.self` (the class metaobject)
  /// invokes the class method living on the metaclass, which is what
  /// `_windowResizeNorthEastSouthWestCursor` and friends are.
  static func privateResizeCursor(selector name: String) -> NSCursor? {
    let cursorClass: AnyObject = NSCursor.self
    let sel = Selector(name)
    guard cursorClass.responds(to: sel) else { return nil }
    return cursorClass.perform(sel)?.takeUnretainedValue() as? NSCursor
  }

  /// 8×8 average-hash of a CGImage in grayscale. Resilient to size,
  /// retina scaling, and minor anti-aliasing differences between the
  /// live WindowServer cursor and the NSCursor reference image — both
  /// inputs collapse into the same 64-bit fingerprint regardless of
  /// original dimensions.
  private static func averageHash(of cgImage: CGImage) -> UInt64 {
    let w = 8
    let h = 8
    var pixels = [UInt8](repeating: 0, count: w * h)
    let cs = CGColorSpaceCreateDeviceGray()
    guard
      let ctx = CGContext(
        data: &pixels,
        width: w,
        height: h,
        bitsPerComponent: 8,
        bytesPerRow: w,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.none.rawValue
      )
    else { return 0 }
    ctx.interpolationQuality = .medium
    ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
    let avg = pixels.reduce(0) { $0 + Int($1) } / pixels.count
    var hash: UInt64 = 0
    for (i, p) in pixels.enumerated() {
      if Int(p) > avg { hash |= UInt64(1) &<< UInt64(i) }
    }
    return hash
  }

  /// Hamming distance — count of differing bits between two hashes.
  /// Smaller = more visually similar. The `^.nonzeroBitCount` trick
  /// is O(1) on every modern CPU (POPCNT instruction).
  private static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
    return (a ^ b).nonzeroBitCount
  }

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

    // Force lazy init of the cursor fingerprint library on the main
    // thread. The underlying NSCursor → CGImage extraction is safest
    // here (Cocoa drawing); touching it now means the first cursor
    // sample doesn't pay the build cost.
    let libSize = Self.cursorLibrary.count
    diagnosticSampleCount = 0
    print(
      "[CursorState] init: libSize=\(libSize) "
        + "cgsCidResolved=\(_cgsMainConnectionID != nil) "
        + "cgsCopyResolved=\(_cgsCopyCurrentCursorImage != nil)")

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
    let state = detectCursorStateName()

    // Send cursor data via callback
    onCursorUpdate?(location.x, location.y, timestamp, isMouseDown, state)
  }

  /// Reads the live cursor image from the WindowServer via the
  /// private `CGSCopyCurrentCursorImage` API and classifies it
  /// against [cursorLibrary]. Works for every cursor the OS is
  /// drawing — Flutter / Electron / web apps, plain native apps,
  /// Safari links, custom `pointingHandCursor` calls — because the
  /// classification works on the visual rendering, not on AX
  /// semantics.
  ///
  /// Returns the last detected state on failure (private API removed,
  /// permission revoked) so the recording doesn't suddenly snap to
  /// arrow if a frame fails.
  ///
  /// Throttled — see [stateQueryIntervalSec] / [stateQueryMoveThresholdPx].
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

    // Try sources in order of preference:
    //   1. NSCursor.currentSystem — public API. On macOS 11+ Apple
    //      documents this as the system-wide cursor "regardless of
    //      whether your app set it." Historical builds returned the
    //      caller's process cursor instead, which is why this code
    //      previously fell through to AX; modern macOS appears to
    //      honour the documented behaviour.
    //   2. CGSCopyCurrentCursorImage (private, dlsym-resolved) —
    //      fallback for older macOS / sandboxed configs where
    //      currentSystem returns the wrong cursor.
    var sourceUsed = "none"
    var cgImage: CGImage?
    if let sys = NSCursor.currentSystem,
      let cg = sys.image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    {
      cgImage = cg
      sourceUsed = "NSCursor.currentSystem"
    } else if let cidFn = _cgsMainConnectionID,
      let copyFn = _cgsCopyCurrentCursorImage,
      let unmanaged = copyFn(cidFn())
    {
      cgImage = unmanaged.takeRetainedValue()
      sourceUsed = "CGSCopyCurrentCursorImage"
    }

    guard let liveImage = cgImage else {
      // Neither source produced anything. Hold the last state to
      // avoid visible flicker.
      return lastDetectedStateName
    }
    let liveHash = Self.averageHash(of: liveImage)

    // Find the closest library entry by Hamming distance. Below
    // [acceptanceThreshold] the cursor is one of our recognised
    // shapes; above it the cursor is something custom (a game cursor,
    // an animated spinner mid-frame, …) and we fall through to "arrow"
    // so the rendered overlay defaults to the user's chosen arrow style.
    var bestName = "arrow"
    var bestDistance = Int.max
    for (name, hash) in Self.cursorLibrary {
      let d = Self.hammingDistance(hash, liveHash)
      if d < bestDistance {
        bestDistance = d
        bestName = name
      }
    }
    let acceptanceThreshold = 8  // out of 64 bits
    let detected = bestDistance <= acceptanceThreshold ? bestName : "arrow"

    if diagnosticSampleCount < 60 {
      print(
        "[CursorState] sample #\(diagnosticSampleCount) "
          + "src=\(sourceUsed) "
          + "dims=\(liveImage.width)×\(liveImage.height) "
          + "best=\(bestName) distance=\(bestDistance) "
          + "detected=\(detected)")
      diagnosticSampleCount += 1
    } else if detected != lastDetectedStateName {
      // After the initial dump, only log transitions.
      print(
        "[CursorState] changed → \(detected) "
          + "(best=\(bestName), distance=\(bestDistance), src=\(sourceUsed))")
    }
    lastDetectedStateName = detected
    return detected
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
  // Kept for source-compat with external callers. The new cursor-image
  // classification path doesn't require any extra permission beyond
  // the Screen Recording entitlement that the recorder already needs,
  // so nothing in this file throws this case anymore.
  case permissionDenied

  var errorDescription: String? {
    switch self {
    case .alreadyTracking:
      return "Cursor tracking is already in progress."
    case .notTracking:
      return "No cursor tracking session is active."
    case .permissionDenied:
      return "Cursor tracking permission denied."
    }
  }
}
