import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  // Bar/pill are borderless; borderless windows refuse key/main unless we
  // opt in, which the bar needs to receive clicks (gear menu, mode buttons).
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // Transparent so the Flutter-drawn rounded bar shows without black
    // corners. Flutter paints its own background.
    flutterViewController.backgroundColor = .clear

    let channel = FlutterMethodChannel(
      name: "slipreel/window",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "setMode",
            let args = call.arguments as? [String: Any],
            let mode = args["mode"] as? String else {
        result(FlutterMethodNotImplemented)
        return
      }
      self?.applyMode(mode)
      result(nil)
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Start as the bar.
    applyMode("bar")

    super.awakeFromNib()
  }

  private func applyMode(_ mode: String) {
    switch mode {
    case "bar":
      configureFloating(width: 760, height: 76)
    case "pill":
      configureFloating(width: 168, height: 48)
    case "panel":
      configurePanel(width: 1100, height: 720)
    default:
      break
    }
  }

  private func configureFloating(width: CGFloat, height: CGFloat) {
    styleMask = [.borderless]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    setContentSize(NSSize(width: width, height: height))
    // Round the bar by masking the content-view layer. Combined with
    // isOpaque=false this clips the corners to the desktop, so the bar reads
    // as a floating rounded pill without relying on Flutter-layer alpha.
    contentView?.wantsLayer = true
    contentView?.layer?.cornerRadius = 18
    contentView?.layer?.masksToBounds = true
    positionTopCenter(width: width, height: height)
    makeKeyAndOrderFront(nil)
  }

  private func configurePanel(width: CGFloat, height: CGFloat) {
    styleMask = [.titled, .closable, .miniaturizable, .resizable]
    isOpaque = true
    backgroundColor = .windowBackgroundColor
    hasShadow = true
    level = .normal
    isMovableByWindowBackground = false
    collectionBehavior = [.fullScreenPrimary]
    // Square, unmasked corners for the normal titled panel.
    contentView?.layer?.cornerRadius = 0
    contentView?.layer?.masksToBounds = false
    setContentSize(NSSize(width: width, height: height))
    center()
    makeKeyAndOrderFront(nil)
  }

  private func positionTopCenter(width: CGFloat, height: CGFloat) {
    guard let screen = NSScreen.main else { return }
    let vf = screen.visibleFrame
    let x = vf.midX - width / 2
    let y = vf.maxY - height - 24 // 24px below the menu bar
    setFrameOrigin(NSPoint(x: x, y: y))
  }
}
