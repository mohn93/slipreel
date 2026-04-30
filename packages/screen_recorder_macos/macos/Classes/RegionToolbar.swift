import AppKit

/// Button that fires its action on the first click even when its hosting
/// window is not the key window. Required because the toolbar panel is
/// `[.borderless, .nonactivatingPanel]` and never becomes key — without this
/// override the click is absorbed by AppKit's failed window-activation
/// attempt and never reaches the button's action.
private final class FirstMouseButton: NSButton {
  override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }
}

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
    // One level above the overlay windows (which sit at `.screenSaver`) so
    // clicks always land on the toolbar, never on the overlay underneath.
    window.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
    window.isOpaque = false
    window.backgroundColor = .clear
    window.hasShadow = true
    window.isFloatingPanel = true
    window.collectionBehavior = [.canJoinAllSpaces, .stationary]

    let host = NSView(frame: rect)
    host.wantsLayer = true
    host.layer?.cornerRadius = 8
    host.layer?.backgroundColor = NSColor(white: 0.16, alpha: 0.95).cgColor

    let cancelBtn = FirstMouseButton(title: "Cancel", target: nil, action: nil)
    cancelBtn.bezelStyle = .rounded
    cancelBtn.frame = NSRect(x: 8, y: 6, width: 60, height: 24)
    cancelBtn.target = self
    cancelBtn.action = #selector(cancelTapped)
    host.addSubview(cancelBtn)

    let startBtn = FirstMouseButton(title: "Start", target: nil, action: nil)
    startBtn.bezelStyle = .rounded
    startBtn.frame = NSRect(x: 72, y: 6, width: 60, height: 24)
    startBtn.target = self
    startBtn.action = #selector(startTapped)
    startBtn.keyEquivalent = "\r"
    host.addSubview(startBtn)

    window.contentView = host
  }

  /// Anchor the toolbar near the user's rect on a specific screen.
  /// `displayBounds` and `rect` are in the screen's local top-left-origin
  /// coordinate space (matching the state machine's convention).
  /// `screenOrigin` is the screen's global frame origin in AppKit's
  /// bottom-left-origin coordinate space — needed to place the panel on the
  /// correct display in a multi-display setup.
  func show(in displayBounds: CGRect, anchoredTo rect: CGRect, screenOrigin: NSPoint) {
    let p = RegionToolbarPosition.positionFor(
      rect: rect, displayBounds: displayBounds,
      toolbarSize: Self.toolbarSize, gap: 8)
    // Convert from top-left-origin (state-machine convention) to AppKit's
    // bottom-left-origin global display coords for setFrameOrigin.
    let flippedY = displayBounds.height - p.y - Self.toolbarSize.height
    window.setFrameOrigin(NSPoint(
      x: p.x + screenOrigin.x,
      y: flippedY + screenOrigin.y))
    window.orderFrontRegardless()
  }

  func hide() {
    window.orderOut(nil)
  }

  @objc private func startTapped() { onStart?() }
  @objc private func cancelTapped() { onCancel?() }
}
