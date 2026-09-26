import AppKit
import CoreGraphics

/// One pickable target drawn on a screen overlay.
struct PickerTarget {
  let id: String            // window id or display id (as String)
  let title: String
  let appName: String?       // nil for displays
  let icon: NSImage?        // app icon for windows; nil for displays
  let localFrame: CGRect    // in this view's flipped (top-left) coords
}

/// Draws target overlays on one screen and reports hover/click. Mirrors the
/// RegionSelectorView pattern: flipped coords, mouse events drive redraw and
/// fire callbacks to the owning overlay manager.
final class SourcePickerView: NSView {
  var targets: [PickerTarget] = [] {
    didSet { hoveredIndex = nil; positionCancelButton(); needsDisplay = true }
  }
  var keyboardSelectedID: String? {
    didSet { positionCancelButton(); needsDisplay = true }
  }
  /// Called with the chosen target id when the user clicks a target.
  var onSelect: ((String) -> Void)?
  /// Called when the user clicks empty space (cancel).
  var onCancel: (() -> Void)?
  /// Called (with self) whenever this view gains a hover, so the owning
  /// manager can clear the hover on every OTHER screen overlay — guarantees a
  /// single highlight even if a cross-screen `mouseExited` is missed.
  var onHoverChanged: ((SourcePickerView) -> Void)?

  private lazy var cancelButton: NSButton = {
    let button = NSButton(title: "Cancel", target: self, action: #selector(cancelSelection))
    button.bezelStyle = .rounded
    button.toolTip = "Cancel source selection (Esc)"
    return button
  }()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    addSubview(cancelButton)
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    addSubview(cancelButton)
  }

  override func layout() {
    super.layout()
    positionCancelButton()
  }

  @objc private func cancelSelection() { onCancel?() }

  private var hoveredIndex: Int?
  private var activeTarget: PickerTarget? {
    if let keyboardSelectedID {
      return targets.first { $0.id == keyboardSelectedID }
    }
    guard let hoveredIndex, targets.indices.contains(hoveredIndex) else { return nil }
    return targets[hoveredIndex]
  }

  private func positionCancelButton() {
    cancelButton.frame = activeTarget.map(cancelButtonRect(for:))
      ?? CGRect(x: bounds.midX - 58, y: bounds.midY + 42, width: 116, height: 32)
  }

  var hoveredTargetID: String? {
    guard let hoveredIndex, targets.indices.contains(hoveredIndex) else { return nil }
    return targets[hoveredIndex].id
  }
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
    // Keep the selected window active while the pointer crosses the gap to
    // Cancel, even if its small window frame ends above the button.
    if let activeTarget,
       recordButtonRect(for: activeTarget)
         .union(cancelButtonRect(for: activeTarget))
         .insetBy(dx: -10, dy: -10).contains(p) { return }
    keyboardSelectedID = nil
    let idx = SourcePickerGeometry.topmost(at: p, frames: targets.map { $0.localFrame })
    if idx != hoveredIndex {
      hoveredIndex = idx
      positionCancelButton()
      needsDisplay = true
      if idx != nil { onHoverChanged?(self) }
    }
  }

  override func mouseExited(with event: NSEvent) {
    if hoveredIndex != nil {
      hoveredIndex = nil
      positionCancelButton()
      needsDisplay = true
    }
  }

  /// Clears any hover highlight. Called by the manager when another screen
  /// overlay takes the hover, so only one overlay is ever highlighted.
  func clearHover() {
    if hoveredIndex != nil {
      hoveredIndex = nil
      positionCancelButton()
      needsDisplay = true
    }
  }

  override func mouseDown(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    if cancelButton.frame.contains(p) { onCancel?(); return }
    if let selected = targets.first(where: { $0.id == keyboardSelectedID }),
       recordButtonRect(for: selected).contains(p) {
      onSelect?(selected.id)
      return
    }
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

    // Highlight + Record for ONLY the target under the cursor. No always-on
    // fallback: a single-target view (every display overlay has one target)
    // would otherwise stay permanently highlighted, so every display would
    // light up at once and never clear.
    let selectedIndex = keyboardSelectedID.flatMap { id in targets.firstIndex { $0.id == id } }
    guard let i = selectedIndex ?? hoveredIndex, i >= 0, i < targets.count else {
      let hint = targets.first?.appName == nil
        ? "Hover a screen, then click to record"
        : "Hover a window or press Tab to choose one"
      drawCenteredHint(hint,
                       sub: "Return to record · Esc to cancel")
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

    let labels = Self.labelLines(for: t)
    let hasSubtitle = labels.count > 1
    if let icon = t.icon {
      let size: CGFloat = 40
      let rect = CGRect(x: cx - size / 2, y: cy - (hasSubtitle ? 95 : 76),
                        width: size, height: size)
      icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: alpha,
                respectFlipped: true, hints: nil)
    }

    let labelWidth = min(max(t.localFrame.width - 20, 160), 440)
    drawCenteredLabel(labels[0], x: cx, y: cy - (hasSubtitle ? 45 : 26),
                      width: labelWidth, color: NSColor.white.withAlphaComponent(alpha))
    if hasSubtitle {
      drawCenteredLabel(labels[1], x: cx, y: cy - 20, width: labelWidth,
                        color: NSColor.white.withAlphaComponent(alpha * 0.75))
    }

    let btn = recordButtonRect(for: t)
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

  static func labelLines(for target: PickerTarget) -> [String] {
    guard let appName = target.appName?.trimmingCharacters(in: .whitespacesAndNewlines),
          !appName.isEmpty else { return [target.title] }
    let title = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.caseInsensitiveCompare(appName) == .orderedSame
      ? [appName] : [appName, title]
  }

  private func recordButtonRect(for target: PickerTarget) -> CGRect {
    CGRect(x: target.localFrame.midX - 58, y: target.localFrame.midY + 16,
           width: 116, height: 32)
  }

  private func cancelButtonRect(for target: PickerTarget) -> CGRect {
    let record = recordButtonRect(for: target)
    return CGRect(x: record.minX, y: record.maxY + 10,
                  width: record.width, height: record.height)
  }

  private func drawCenteredLabel(_ text: String, x: CGFloat, y: CGFloat,
                                 width: CGFloat, color: NSColor) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    paragraph.lineBreakMode = .byTruncatingTail
    (text as NSString).draw(
      in: CGRect(x: x - width / 2, y: y, width: width, height: 18),
      withAttributes: [
        .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
  }
}
