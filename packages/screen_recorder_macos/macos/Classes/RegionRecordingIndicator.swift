import AppKit
import CoreGraphics

/// Click-through dim overlay shown across all displays while an area
/// recording is active. Outlines the recorded rect on the recorded display
/// so the user always knows what's being captured. Non-interactive — every
/// overlay window has `ignoresMouseEvents = true` so clicks pass through to
/// whatever the user is recording.
@MainActor
final class RegionRecordingIndicator {
  static let shared = RegionRecordingIndicator()
  private init() {}

  private var windows: [NSWindow] = []

  func show(region: RegionSelection) {
    hide()
    for screen in NSScreen.screens {
      let win = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
      win.level = .screenSaver
      win.isOpaque = false
      win.backgroundColor = .clear
      win.ignoresMouseEvents = true
      win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

      let screenId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
        as? CGDirectDisplayID) ?? 0
      let recordedRect: CGRect?
      if screenId == region.displayId {
        let scale = screen.backingScaleFactor
        recordedRect = CGRect(
          x: CGFloat(region.x) / scale,
          y: CGFloat(region.y) / scale,
          width: CGFloat(region.widthPx) / scale,
          height: CGFloat(region.heightPx) / scale)
      } else {
        recordedRect = nil
      }

      let view = RegionRecordingIndicatorView(
        displayBounds: CGRect(origin: .zero, size: screen.frame.size),
        recordedRect: recordedRect)
      win.contentView = view
      win.orderFrontRegardless()
      windows.append(win)
    }
  }

  func hide() {
    for win in windows { win.orderOut(nil) }
    windows.removeAll()
  }
}

private final class RegionRecordingIndicatorView: NSView {
  private let recordedRect: CGRect?
  private static let accentColor = NSColor(
    srgbRed: 0x6c/255.0, green: 0x63/255.0, blue: 0xff/255.0, alpha: 1)

  init(displayBounds: CGRect, recordedRect: CGRect?) {
    self.recordedRect = recordedRect
    super.init(frame: NSRect(origin: .zero, size: displayBounds.size))
    wantsLayer = true
  }

  required init?(coder: NSCoder) { fatalError() }

  override var isFlipped: Bool { return true }

  override func draw(_ dirty: NSRect) {
    guard let ctx = NSGraphicsContext.current?.cgContext else { return }
    ctx.setFillColor(NSColor.black.withAlphaComponent(0.2).cgColor)
    ctx.fill(bounds)
    if let rect = recordedRect, !rect.isEmpty {
      ctx.clear(rect)
      ctx.setStrokeColor(Self.accentColor.cgColor)
      ctx.setLineWidth(2)
      ctx.stroke(rect)
    }
  }
}
