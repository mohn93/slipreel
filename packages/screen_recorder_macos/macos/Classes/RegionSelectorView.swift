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
      ctx.fill(bounds)
      ctx.clear(rect)
    }

    if rect.isEmpty { return }

    // Rect outline.
    ctx.setStrokeColor(NSColor(srgbRed: 0x6c/255.0, green: 0x63/255.0, blue: 0xff/255.0, alpha: 1).cgColor)
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
