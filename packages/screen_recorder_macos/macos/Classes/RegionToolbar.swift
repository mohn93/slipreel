import AppKit

final class RegionToolbar {
  let window: NSPanel
  var onStart: (() -> Void)?
  var onCancel: (() -> Void)?

  static let toolbarSize = CGSize(width: 140, height: 36)

  init() {
    let rect = NSRect(origin: .zero, size: Self.toolbarSize)
    window = NSPanel(
      contentRect: rect,
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    window.level = .screenSaver
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isFloatingPanel = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]

    let host = NSView(frame: rect)
    host.wantsLayer = true
    host.layer?.cornerRadius = 8
    host.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.95).cgColor

    let cancelBtn = NSButton(title: "Cancel", target: nil, action: nil)
    cancelBtn.bezelStyle = .rounded
    cancelBtn.frame = NSRect(x: 8, y: 6, width: 60, height: 24)
    cancelBtn.target = self
    cancelBtn.action = #selector(cancelTapped)
    host.addSubview(cancelBtn)

    let startBtn = NSButton(title: "Start", target: nil, action: nil)
    startBtn.bezelStyle = .rounded
    startBtn.frame = NSRect(x: 72, y: 6, width: 60, height: 24)
    startBtn.target = self
    startBtn.action = #selector(startTapped)
    startBtn.keyEquivalent = "\r"
    host.addSubview(startBtn)

    window.contentView = host
  }

  func show(in displayBounds: CGRect, anchoredTo rect: CGRect) {
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: Self.toolbarSize, gap: 8)
    let flippedY = displayBounds.maxY - p.y - Self.toolbarSize.height
    window.setFrameOrigin(NSPoint(x: p.x + displayBounds.minX, y: flippedY + displayBounds.minY))
    window.orderFrontRegardless()
  }

  func hide() {
    window.orderOut(nil)
  }

  @objc private func startTapped() { onStart?() }
  @objc private func cancelTapped() { onCancel?() }
}
