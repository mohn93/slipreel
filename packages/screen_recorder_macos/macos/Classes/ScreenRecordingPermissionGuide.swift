import AppKit
import CoreGraphics

/// A lightweight, non-activating helper that follows the System Settings
/// window while the user enables Screen Recording. The permission pane is a
/// private app UI, so the guide anchors to its public WindowServer bounds
/// instead of depending on brittle internal view coordinates.
@MainActor
final class ScreenRecordingPermissionGuide {
  static let shared = ScreenRecordingPermissionGuide()

  private static let panelSize = NSSize(width: 342, height: 252)
  private var panel: NSPanel?
  private var guideView: ScreenRecordingPermissionGuideView?
  private var trackingTimer: Timer?
  private var settingsMissingTicks = 0

  private init() {}

  func show() {
    hide()

    let panel = NSPanel(
      contentRect: NSRect(origin: .zero, size: Self.panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false)
    panel.isFloatingPanel = true
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.sharingType = .none

    let view = ScreenRecordingPermissionGuideView(
      frame: NSRect(origin: .zero, size: Self.panelSize))
    view.onClose = { [weak self] in self?.hide() }
    panel.contentView = view

    self.panel = panel
    self.guideView = view
    positionAtFallback()
    panel.orderFrontRegardless()
    update()

    let timer = Timer(timeInterval: 0.75, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.update() }
    }
    trackingTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  func hide() {
    trackingTimer?.invalidate()
    trackingTimer = nil
    panel?.orderOut(nil)
    panel = nil
    guideView = nil
    settingsMissingTicks = 0
  }

  private func update() {
    guard let panel, let guideView else { return }
    guideView.permissionGranted = CGPreflightScreenCaptureAccess()

    guard let settings = settingsApplication() else {
      settingsMissingTicks += 1
      // Allow plenty of time for the deep link to launch System Settings, but
      // do not leave an orphaned guide floating forever if it gets closed.
      if settingsMissingTicks >= 12 { hide() }
      return
    }
    settingsMissingTicks = 0

    guard let quartzFrame = settingsWindowFrame(processID: settings.processIdentifier),
          let cocoaFrame = cocoaFrame(forQuartzFrame: quartzFrame),
          let screen = NSScreen.screens.first(where: { $0.frame.intersects(cocoaFrame) })
            ?? NSScreen.main else { return }

    let origin = PermissionGuideGeometry.origin(
      beside: cocoaFrame,
      panelSize: Self.panelSize,
      visibleFrame: screen.visibleFrame)
    let nextFrame = NSRect(origin: origin, size: Self.panelSize)
    guideView.settingsIsToLeft = nextFrame.midX > cocoaFrame.midX
    if abs(panel.frame.minX - nextFrame.minX) > 1 ||
       abs(panel.frame.minY - nextFrame.minY) > 1 {
      panel.setFrame(nextFrame, display: true, animate: false)
    }
    panel.orderFrontRegardless()
  }

  private func positionAtFallback() {
    guard let panel, let visible = NSScreen.main?.visibleFrame else { return }
    panel.setFrameOrigin(NSPoint(
      x: visible.maxX - Self.panelSize.width - 22,
      y: visible.maxY - Self.panelSize.height - 64))
  }

  private func settingsApplication() -> NSRunningApplication? {
    return NSWorkspace.shared.runningApplications.first { app in
      app.bundleIdentifier == "com.apple.systempreferences" ||
        app.bundleIdentifier == "com.apple.SystemSettings" ||
        app.localizedName == "System Settings" ||
        app.localizedName == "System Preferences"
    }
  }

  /// Returns the largest normal-layer on-screen window owned by System
  /// Settings. Owner PID and bounds are required WindowServer metadata and do
  /// not require us to inspect or automate the permission pane's view tree.
  private func settingsWindowFrame(processID: pid_t) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return nil }

    var best: CGRect?
    for info in list {
      let ownerPID = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
      let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
      guard ownerPID == processID, layer == 0,
            let rawBounds = info[kCGWindowBounds as String] as? NSDictionary,
            let frame = CGRect(dictionaryRepresentation: rawBounds),
            frame.width >= 400, frame.height >= 300 else { continue }
      if best == nil || frame.width * frame.height > best!.width * best!.height {
        best = frame
      }
    }
    return best
  }

  /// Quartz window coordinates use a top-left display origin; AppKit windows
  /// use bottom-left coordinates. Convert through the display that contains the
  /// largest part of the System Settings window so multi-display layouts work.
  private func cocoaFrame(forQuartzFrame frame: CGRect) -> CGRect? {
    var best: (screen: NSScreen, display: CGRect, area: CGFloat)?
    for screen in NSScreen.screens {
      guard let displayID = screen.deviceDescription[
        NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
      let display = CGDisplayBounds(displayID)
      let intersection = frame.intersection(display)
      let area = intersection.isNull ? 0 : intersection.width * intersection.height
      if best == nil || area > best!.area {
        best = (screen, display, area)
      }
    }
    guard let best else { return nil }
    let localX = frame.minX - best.display.minX
    let fromTop = frame.minY - best.display.minY
    return CGRect(
      x: best.screen.frame.minX + localX,
      y: best.screen.frame.maxY - fromTop - frame.height,
      width: frame.width,
      height: frame.height)
  }
}

enum PermissionGuideGeometry {
  /// Prefer the right side of System Settings, then the left. When neither side
  /// fits, tuck the guide just inside its upper-right edge without covering the
  /// lower permission toggles.
  static func origin(
    beside settingsFrame: CGRect,
    panelSize: NSSize,
    visibleFrame: CGRect
  ) -> NSPoint {
    let gap: CGFloat = 14
    let edge: CGFloat = 12
    let y = min(
      max(settingsFrame.maxY - panelSize.height, visibleFrame.minY + edge),
      visibleFrame.maxY - panelSize.height - edge)

    if settingsFrame.maxX + gap + panelSize.width <= visibleFrame.maxX - edge {
      return NSPoint(x: settingsFrame.maxX + gap, y: y)
    }
    if settingsFrame.minX - gap - panelSize.width >= visibleFrame.minX + edge {
      return NSPoint(x: settingsFrame.minX - gap - panelSize.width, y: y)
    }

    let insideX = min(
      max(settingsFrame.maxX - panelSize.width - 22, visibleFrame.minX + edge),
      visibleFrame.maxX - panelSize.width - edge)
    return NSPoint(x: insideX, y: y)
  }
}

private final class ScreenRecordingPermissionGuideView: NSView, NSDraggingSource {
  var onClose: (() -> Void)?
  var permissionGranted = false { didSet { needsDisplay = true } }
  var settingsIsToLeft = true { didSet { needsDisplay = true } }

  private var dragCompleted = false { didSet { needsDisplay = true } }
  private var iconHovered = false
  private var closeHovered = false
  private var motionTimer: Timer?
  private var animationStartedAt = ProcessInfo.processInfo.systemUptime
  private let appIcon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)

  private var baseIconRect: CGRect { CGRect(x: 28, y: 112, width: 68, height: 68) }
  private var iconRect: CGRect {
    guard !dragCompleted, !permissionGranted,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      return baseIconRect
    }
    let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
    let offset = sin(elapsed * .pi * 2 / 1.55) * 4
    return baseIconRect.offsetBy(dx: 0, dy: offset)
  }
  private var closeRect: CGRect { CGRect(x: bounds.width - 36, y: 14, width: 22, height: 22) }

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    motionTimer?.invalidate()
    motionTimer = nil
    guard window != nil,
          !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

    animationStartedAt = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      guard let self, !self.dragCompleted, !self.permissionGranted else { return }
      self.needsDisplay = true
    }
    motionTimer = timer
    RunLoop.main.add(timer, forMode: .common)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self,
      userInfo: nil))
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(baseIconRect.insetBy(dx: -10, dy: -10), cursor: .openHand)
    addCursorRect(closeRect, cursor: .pointingHand)
  }

  override func mouseMoved(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    let nextIcon = baseIconRect.insetBy(dx: -10, dy: -10).contains(point)
    let nextClose = closeRect.contains(point)
    if nextIcon != iconHovered || nextClose != closeHovered {
      iconHovered = nextIcon
      closeHovered = nextClose
      needsDisplay = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    iconHovered = false
    closeHovered = false
    needsDisplay = true
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    if closeRect.contains(point) {
      onClose?()
      return
    }
    guard !permissionGranted,
          baseIconRect.insetBy(dx: -10, dy: -10).contains(point) else { return }

    let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
    item.setDraggingFrame(iconRect, contents: appIcon)
    let session = beginDraggingSession(with: [item], event: event, source: self)
    session.animatesToStartingPositionsOnCancelOrFail = true
  }

  func draggingSession(
    _ session: NSDraggingSession,
    sourceOperationMaskFor context: NSDraggingContext
  ) -> NSDragOperation {
    return .copy
  }

  func draggingSession(
    _ session: NSDraggingSession,
    endedAt screenPoint: NSPoint,
    operation: NSDragOperation
  ) {
    if operation.contains(.copy) { dragCompleted = true }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 18, yRadius: 18)
    NSColor(srgbRed: 0.105, green: 0.112, blue: 0.132, alpha: 0.97).setFill()
    card.fill()
    NSColor(srgbRed: 0.25, green: 0.27, blue: 0.31, alpha: 0.9).setStroke()
    card.lineWidth = 1
    card.stroke()

    drawClose()
    if permissionGranted {
      drawGranted()
    } else {
      drawInstructions()
    }
  }

  private func drawInstructions() {
    let headline = dragCompleted ? "Now enable Slipreel" : "Add Slipreel to the list"
    let introduction = dragCompleted
      ? "Find this icon in System Settings and turn on the switch beside it."
      : "Drag the floating app icon into the Screen Recording list."
    drawText(
      headline,
      in: CGRect(x: 24, y: 20, width: 278, height: 24),
      font: .systemFont(ofSize: 18, weight: .semibold),
      color: NSColor(srgbRed: 0.96, green: 0.97, blue: 0.98, alpha: 1))
    drawText(
      introduction,
      in: CGRect(x: 24, y: 52, width: 292, height: 38),
      font: .systemFont(ofSize: 13, weight: .regular),
      color: NSColor(srgbRed: 0.70, green: 0.72, blue: 0.76, alpha: 1))

    let currentIconRect = iconRect
    let iconPlate = NSBezierPath(
      roundedRect: currentIconRect.insetBy(dx: -8, dy: -8), xRadius: 16, yRadius: 16)
    NSColor(srgbRed: 0.18, green: 0.20, blue: 0.24,
            alpha: iconHovered ? 1 : 0.78).setFill()
    iconPlate.fill()
    let accent = dragCompleted
      ? NSColor(srgbRed: 0.30, green: 0.84, blue: 0.60, alpha: 1)
      : NSColor(srgbRed: 0.36, green: 0.55, blue: 1, alpha: iconHovered ? 1 : 0.78)
    accent.setStroke()
    iconPlate.lineWidth = iconHovered ? 2 : 1
    if !dragCompleted { iconPlate.setLineDash([5, 4], count: 2, phase: 0) }
    iconPlate.stroke()

    NSGraphicsContext.saveGraphicsState()
    if !dragCompleted {
      let elapsed = ProcessInfo.processInfo.systemUptime - animationStartedAt
      let glow = 11 + (sin(elapsed * .pi * 2 / 1.55) + 1) * 3
      let shadow = NSShadow()
      shadow.shadowColor = NSColor(srgbRed: 0.30, green: 0.50, blue: 1, alpha: 0.48)
      shadow.shadowBlurRadius = iconHovered ? 19 : glow
      shadow.shadowOffset = .zero
      shadow.set()
    }
    appIcon.draw(in: currentIconRect)
    NSGraphicsContext.restoreGraphicsState()

    let title = dragCompleted ? "Turn on this app" : "Drag this icon"
    let body = dragCompleted
      ? "Enable the switch beside Slipreel in the settings list."
      : "Drop it anywhere in the app list in System Settings."
    drawText(
      title,
      in: CGRect(x: 118, y: 110, width: 196, height: 22),
      font: .systemFont(ofSize: 14, weight: .semibold),
      color: .white)
    drawText(
      body,
      in: CGRect(x: 118, y: 140, width: 194, height: 42),
      font: .systemFont(ofSize: 12.5, weight: .regular),
      color: NSColor(srgbRed: 0.70, green: 0.72, blue: 0.76, alpha: 1))

    if !dragCompleted {
      let dragCue = settingsIsToLeft ? "←  Drag into System Settings" : "Drag into System Settings  →"
      drawText(
        dragCue,
        in: CGRect(x: 24, y: 190, width: 294, height: 18),
        font: .systemFont(ofSize: 11.5, weight: .semibold),
        color: NSColor(srgbRed: 0.52, green: 0.66, blue: 1, alpha: 1),
        alignment: settingsIsToLeft ? .left : .right)
    }

    drawText(
      dragCompleted
        ? "When the switch is on, quit and reopen Slipreel."
        : "Already listed? Skip the drag and turn on its switch.",
      in: CGRect(x: 24, y: 213, width: 294, height: 22),
      font: .systemFont(ofSize: 12, weight: .medium),
      color: dragCompleted
        ? NSColor(srgbRed: 0.30, green: 0.84, blue: 0.60, alpha: 1)
        : NSColor(srgbRed: 0.70, green: 0.72, blue: 0.76, alpha: 1))
  }

  private func drawGranted() {
    let badge = NSBezierPath(ovalIn: CGRect(x: 26, y: 32, width: 54, height: 54))
    NSColor(srgbRed: 0.20, green: 0.70, blue: 0.48, alpha: 0.18).setFill()
    badge.fill()
    drawText(
      "✓",
      in: CGRect(x: 26, y: 40, width: 54, height: 38),
      font: .systemFont(ofSize: 27, weight: .bold),
      color: NSColor(srgbRed: 0.30, green: 0.84, blue: 0.60, alpha: 1),
      alignment: .center)
    drawText(
      "Screen Recording is on",
      in: CGRect(x: 98, y: 32, width: 210, height: 24),
      font: .systemFont(ofSize: 18, weight: .semibold),
      color: .white)
    drawText(
      "Quit and reopen Slipreel to load your screens and windows.",
      in: CGRect(x: 98, y: 64, width: 214, height: 52),
      font: .systemFont(ofSize: 13, weight: .regular),
      color: NSColor(srgbRed: 0.70, green: 0.72, blue: 0.76, alpha: 1))
    drawText(
      "You can close this guide now.",
      in: CGRect(x: 24, y: 188, width: 294, height: 24),
      font: .systemFont(ofSize: 13, weight: .medium),
      color: NSColor(srgbRed: 0.30, green: 0.84, blue: 0.60, alpha: 1),
      alignment: .center)
  }

  private func drawClose() {
    if closeHovered {
      NSColor.white.withAlphaComponent(0.09).setFill()
      NSBezierPath(ovalIn: closeRect).fill()
    }
    drawText(
      "×",
      in: CGRect(x: closeRect.minX, y: closeRect.minY - 2,
                 width: closeRect.width, height: closeRect.height),
      font: .systemFont(ofSize: 19, weight: .regular),
      color: NSColor.white.withAlphaComponent(0.62),
      alignment: .center)
  }

  private func drawText(
    _ text: String,
    in rect: CGRect,
    font: NSFont,
    color: NSColor,
    alignment: NSTextAlignment = .left
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = alignment
    paragraph.lineBreakMode = .byWordWrapping
    (text as NSString).draw(
      with: rect,
      options: [.usesLineFragmentOrigin, .usesFontLeading],
      attributes: [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
  }
}
