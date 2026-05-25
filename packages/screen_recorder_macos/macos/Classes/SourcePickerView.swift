import AppKit
import CoreGraphics

/// One pickable target drawn on a screen overlay.
struct PickerTarget {
  let id: String            // window id or display id (as String)
  let title: String
  let icon: NSImage?        // app icon for windows; nil for displays
  let localFrame: CGRect    // in this view's flipped (top-left) coords
}

/// Draws target overlays on one screen and reports hover/click. Mirrors the
/// RegionSelectorView pattern: flipped coords, mouse events drive redraw and
/// fire callbacks to the owning overlay manager.
final class SourcePickerView: NSView {
  var targets: [PickerTarget] = [] { didSet { needsDisplay = true } }
  /// Called with the chosen target id when the user clicks a target.
  var onSelect: ((String) -> Void)?
  /// Called when the user clicks empty space (cancel).
  var onCancel: (() -> Void)?

  private var hoveredIndex: Int?
  private static let blue = NSColor(srgbRed: 0.16, green: 0.43, blue: 1.0, alpha: 0.34)
  private static let scrim = NSColor(srgbRed: 0.06, green: 0.07, blue: 0.10, alpha: 0.46)
  private static let blueBorder = NSColor(srgbRed: 0.29, green: 0.55, blue: 1.0, alpha: 0.9)

  override var isFlipped: Bool { true }
  override var acceptsFirstResponder: Bool { true }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: bounds,
      options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
      owner: self, userInfo: nil))
  }

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    let idx = SourcePickerGeometry.topmost(at: p, frames: targets.map { $0.localFrame })
    if idx != hoveredIndex {
      hoveredIndex = idx
      needsDisplay = true
    }
  }

  override func mouseExited(with event: NSEvent) {
    if hoveredIndex != nil { hoveredIndex = nil; needsDisplay = true }
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if let idx = SourcePickerGeometry.topmost(at: p, frames: targets.map { $0.localFrame }) {
      onSelect?(targets[idx].id)
    } else {
      onCancel?()
    }
  }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }

    // One uniform dim over the whole screen so the picker reads as a modal
    // layer. (A per-window scrim would stack alpha where windows overlap.)
    ctx.setFillColor(Self.scrim.cgColor)
    ctx.fill(bounds)

    if targets.isEmpty {
      drawCenteredHint("No windows to record — open one and try again",
                       sub: "Press Esc to cancel")
      return
    }

    // Highlight + Record for ONLY ONE target at a time — the window under the
    // cursor — so overlapping windows don't pile their Record buttons on top
    // of each other. A single target (e.g. a whole display) is active by
    // default so the user doesn't have to hover to see Record.
    let active = hoveredIndex ?? (targets.count == 1 ? 0 : nil)
    guard let i = active, i >= 0, i < targets.count else {
      drawCenteredHint("Hover a window, then click it to record",
                       sub: "Press Esc to cancel")
      return
    }

    let t = targets[i]
    ctx.setFillColor(Self.blue.cgColor)
    ctx.fill(t.localFrame)
    ctx.setStrokeColor(Self.blueBorder.cgColor)
    ctx.setLineWidth(3)
    ctx.stroke(t.localFrame.insetBy(dx: 1.5, dy: 1.5))
    drawCenteredControls(for: t, hovered: true)
  }

  private func drawCenteredHint(_ text: String, sub: String) {
    let cx = bounds.midX, cy = bounds.midY
    let attrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 16, weight: .semibold),
      .foregroundColor: NSColor.white.withAlphaComponent(0.9),
    ]
    let s = NSAttributedString(string: text, attributes: attrs)
    let sz = s.size()
    s.draw(at: CGPoint(x: cx - sz.width / 2, y: cy - 14))
    let subAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 12, weight: .regular),
      .foregroundColor: NSColor.white.withAlphaComponent(0.6),
    ]
    let ss = NSAttributedString(string: sub, attributes: subAttrs)
    let ssz = ss.size()
    ss.draw(at: CGPoint(x: cx - ssz.width / 2, y: cy + 10))
  }

  private func drawCenteredControls(for t: PickerTarget, hovered: Bool) {
    let cx = t.localFrame.midX
    let cy = t.localFrame.midY
    let alpha: CGFloat = hovered ? 1.0 : 0.85

    if let icon = t.icon {
      let size: CGFloat = 40
      let rect = CGRect(x: cx - size / 2, y: cy - size - 36, width: size, height: size)
      icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha)
    }

    let labelAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.white.withAlphaComponent(alpha),
    ]
    let label = NSAttributedString(string: t.title, attributes: labelAttrs)
    let labelSize = label.size()
    label.draw(at: CGPoint(x: cx - labelSize.width / 2, y: cy - 24))

    let btnW: CGFloat = 116, btnH: CGFloat = 32
    let btn = CGRect(x: cx - btnW / 2, y: cy + 6, width: btnW, height: btnH)
    let path = NSBezierPath(roundedRect: btn, xRadius: 9, yRadius: 9)
    NSColor(srgbRed: 0.90, green: 0.28, blue: 0.30, alpha: hovered ? 1.0 : 0.85).setFill()
    path.fill()
    let btnAttrs: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
      .foregroundColor: NSColor.white,
    ]
    let rec = NSAttributedString(string: "● Record", attributes: btnAttrs)
    let recSize = rec.size()
    rec.draw(at: CGPoint(x: btn.midX - recSize.width / 2, y: btn.midY - recSize.height / 2))
  }
}
