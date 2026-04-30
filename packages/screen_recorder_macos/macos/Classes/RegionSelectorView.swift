import AppKit

final class RegionSelectorView: NSView {
  private(set) var machine: RegionSelectorMachine
  var onStateChange: ((RegionSelectionState) -> Void)?
  /// Called when the inline Cancel button is clicked. Owner should tear down.
  var onToolbarCancel: (() -> Void)?
  private let displayBounds: CGRect
  private static let accentColor = NSColor(
    srgbRed: 0x6c/255.0, green: 0x63/255.0, blue: 0xff/255.0, alpha: 1)
  private static let toolbarSize = CGSize(width: 140, height: 36)
  private static let toolbarGap: CGFloat = 8
  private static let buttonSize = CGSize(width: 60, height: 24)
  private static let buttonY: CGFloat = 6
  private static let cancelButtonX: CGFloat = 8
  private static let startButtonX: CGFloat = 72

  /// The hosting NSWindow MUST be non-opaque (`isOpaque = false`,
  /// `backgroundColor = .clear`) for `ctx.clear(rect)` in `draw(_:)` to show
  /// through to the desktop. An opaque window will composite the cleared
  /// region against the window's background instead.
  init(displayBounds: CGRect) {
    self.displayBounds = displayBounds
    self.machine = RegionSelectorMachine(displayBounds: displayBounds)
    super.init(frame: NSRect(origin: .zero, size: displayBounds.size))
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { return true }
  override var acceptsFirstResponder: Bool { return true }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)

    // Toolbar buttons are drawn inline in this view (rather than as a
    // separate NSPanel) because cross-window z-order against a
    // .screenSaver-level overlay is unreliable on macOS — clicks would fall
    // through to the overlay underneath, where mouseDown outside the
    // selected rect would reset the state machine to .drawing.
    if let btn = startBtnRect, btn.contains(p) {
      triggerStart()
      return
    }
    if let btn = cancelBtnRect, btn.contains(p) {
      onToolbarCancel?()
      return
    }
    if let bg = toolbarBgRect, bg.contains(p) {
      // Click inside the toolbar bounds but outside any button — swallow it
      // so it does not reach the state machine and reset the selection.
      return
    }

    machine.handle(.mouseDown(at: p))
    needsDisplay = true
    onStateChange?(machine.state)
    cursorFor(state: machine.state, point: p).set()
  }

  override func mouseDragged(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    machine.handle(.mouseDragged(to: p))
    needsDisplay = true
    onStateChange?(machine.state)
    cursorFor(state: machine.state, point: p).set()
  }

  override func mouseUp(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    machine.handle(.mouseUp(at: p))
    needsDisplay = true
    onStateChange?(machine.state)
    cursorFor(state: machine.state, point: p).set()
  }

  func triggerStart() {
    machine.handle(.startPressed)
    needsDisplay = true
    onStateChange?(machine.state)
  }

  func resetMachine() {
    machine = RegionSelectorMachine(displayBounds: displayBounds)
    needsDisplay = true
  }

  override func keyDown(with event: NSEvent) {
    if event.keyCode == 53 { // Esc
      machine.handle(.escapePressed)
      onStateChange?(machine.state)
      return
    }
    super.keyDown(with: event)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    addTrackingArea(area)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    addCursorRect(bounds, cursor: .crosshair)
  }

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    cursorFor(state: machine.state, point: p).set()
  }

  override func mouseEntered(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    cursorFor(state: machine.state, point: p).set()
  }

  override func mouseExited(with event: NSEvent) {
    NSCursor.crosshair.set()
  }

  private var showsToolbar: Bool {
    switch machine.state {
    case .selected, .resizing, .moving: return true
    default: return false
    }
  }

  private var toolbarBgRect: CGRect? {
    guard showsToolbar else { return nil }
    let p = RegionToolbarPosition.positionFor(
      rect: machine.currentRect,
      displayBounds: displayBounds,
      toolbarSize: Self.toolbarSize,
      gap: Self.toolbarGap)
    return CGRect(origin: p, size: Self.toolbarSize)
  }

  private var cancelBtnRect: CGRect? {
    guard let bg = toolbarBgRect else { return nil }
    return CGRect(
      x: bg.minX + Self.cancelButtonX, y: bg.minY + Self.buttonY,
      width: Self.buttonSize.width, height: Self.buttonSize.height)
  }

  private var startBtnRect: CGRect? {
    guard let bg = toolbarBgRect else { return nil }
    return CGRect(
      x: bg.minX + Self.startButtonX, y: bg.minY + Self.buttonY,
      width: Self.buttonSize.width, height: Self.buttonSize.height)
  }

  private func cursorFor(state: RegionSelectionState, point: CGPoint) -> NSCursor {
    if let btn = startBtnRect, btn.contains(point) { return .arrow }
    if let btn = cancelBtnRect, btn.contains(point) { return .arrow }
    switch state {
    case .moving:
      return .closedHand
    case .resizing(let handle, _, _):
      return cursorForHandle(handle)
    case .selected(let rect):
      if let h = ResizeHandle.hit(at: point, in: rect) {
        return cursorForHandle(h)
      }
      if rect.contains(point) {
        return .openHand
      }
      return .crosshair
    default:
      return .crosshair
    }
  }

  private func cursorForHandle(_ handle: ResizeHandle) -> NSCursor {
    switch handle {
    case .n, .s: return .resizeUpDown
    case .e, .w: return .resizeLeftRight
    case .nw, .se, .ne, .sw: return .crosshair  // macOS lacks public diagonal cursors
    }
  }

  override func draw(_ dirty: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    let rect = machine.currentRect

    // Dim everything outside the rect.
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.4).cgColor)
    if rect.isEmpty {
      ctx.fill(bounds)
    } else {
      ctx.fill(bounds)
      ctx.clear(rect)
    }

    if !rect.isEmpty {
      // Rect outline.
      ctx.setStrokeColor(Self.accentColor.cgColor)
      ctx.setLineWidth(1)
      ctx.stroke(rect)

      switch machine.state {
      case .selected, .resizing, .moving:
        drawHandles(in: rect, context: ctx)
      default:
        break
      }

      switch machine.state {
      case .drawing, .resizing:
        drawSizeReadout(at: rect, context: ctx)
      default:
        break
      }
    }

    if let bg = toolbarBgRect {
      drawToolbar(bg: bg, context: ctx)
    }
  }

  private func drawHandles(in rect: CGRect, context ctx: CGContext) {
    ctx.setFillColor(Self.accentColor.cgColor)
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
    let bgWidth = textSize.width + pad * 2
    let bgHeight = textSize.height + pad
    // Prefer above the rect; fall back below when the rect is near the top edge.
    let yAbove = rect.minY - bgHeight - pad
    let yBelow = rect.maxY + pad
    let bgY = yAbove >= 0 ? yAbove : yBelow
    let bgRect = CGRect(x: rect.minX, y: bgY, width: bgWidth, height: bgHeight)
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
    ctx.fill(bgRect)
    str.draw(at: CGPoint(x: bgRect.minX + pad, y: bgRect.minY + pad / 2))
  }

  private func drawToolbar(bg: CGRect, context ctx: CGContext) {
    let bgPath = CGPath(roundedRect: bg, cornerWidth: 8, cornerHeight: 8, transform: nil)
    ctx.setFillColor(NSColor(white: 0.16, alpha: 0.95).cgColor)
    ctx.addPath(bgPath)
    ctx.fillPath()

    if let cancel = cancelBtnRect {
      drawToolbarButton(rect: cancel, label: "Cancel", primary: false, context: ctx)
    }
    if let start = startBtnRect {
      drawToolbarButton(rect: start, label: "Start", primary: true, context: ctx)
    }
  }

  private func drawToolbarButton(rect: CGRect, label: String, primary: Bool,
                                  context ctx: CGContext) {
    let fill = primary ? Self.accentColor : NSColor(white: 0.32, alpha: 1)
    let path = CGPath(roundedRect: rect, cornerWidth: 5, cornerHeight: 5, transform: nil)
    ctx.setFillColor(fill.cgColor)
    ctx.addPath(path)
    ctx.fillPath()

    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .medium),
      .foregroundColor: NSColor.white,
    ]
    let str = NSAttributedString(string: label, attributes: attrs)
    let textSize = str.size()
    let textPoint = CGPoint(
      x: rect.midX - textSize.width / 2,
      y: rect.midY - textSize.height / 2)
    str.draw(at: textPoint)
  }
}
