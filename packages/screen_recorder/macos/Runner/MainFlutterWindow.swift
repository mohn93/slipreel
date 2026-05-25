import Cocoa
import FlutterMacOS

private final class GearMenuTarget: NSObject {
  var selected: String?
  @objc func pick(_ sender: NSMenuItem) {
    selected = sender.representedObject as? String
  }
}

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
      switch call.method {
      case "setMode":
        guard let args = call.arguments as? [String: Any],
              let mode = args["mode"] as? String else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.applyMode(mode)
        result(nil)
      case "showGearMenu":
        self?.showGearMenu(result: result)
      case "startWindowDrag":
        self?.startWindowDrag()
        result(nil)
      case "setBarWidth":
        guard let args = call.arguments as? [String: Any],
              let width = args["width"] as? Double else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.setBarWidth(CGFloat(width))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Start as the bar.
    applyMode("bar")

    super.awakeFromNib()
  }

  /// Tracks the active mode so `setBarWidth` only resizes while we're the bar.
  private var currentMode = "bar"

  private func applyMode(_ mode: String) {
    currentMode = mode
    switch mode {
    case "bar":
      // 736 is just the pre-measure default; Flutter measures the row content
      // and calls `setBarWidth` to hug it (the mic/system-audio labels vary).
      configureFloating(width: 736, height: kBarHeight, cornerRadius: 18)
    case "pill":
      configureFloating(width: 156, height: 48, cornerRadius: 24)
    case "panel":
      configurePanel(width: 1100, height: 720)
    default:
      break
    }
  }

  /// Fixed bar height; width is content-driven via `setBarWidth`.
  private let kBarHeight: CGFloat = 68

  /// Resizes the floating bar to hug its Flutter content. No-op unless we're
  /// currently the bar (so it never resizes the pill or the panel). Keeps the
  /// window top-centered. Width is clamped to a sane range.
  private func setBarWidth(_ width: CGFloat) {
    guard currentMode == "bar" else { return }
    let clamped = max(320, min(width, 1400))
    // Resize in place: keep the window's origin fixed (and thus its top-left
    // corner, since the height is constant) so the bar grows/shrinks on the
    // RIGHT and stays exactly where the user dragged it. Re-centering /
    // top-positioning here would make the whole bar jump and snap back to the
    // top of the screen on every content change. Borderless → frame size ==
    // content size, so setting frame width sets the content width directly.
    var f = frame
    f.size.width = clamped
    setFrame(f, display: true)
  }

  private func showGearMenu(result: @escaping FlutterResult) {
    let target = GearMenuTarget()
    let menu = NSMenu()
    func add(_ title: String, _ id: String) {
      let item = NSMenuItem(
        title: title, action: #selector(GearMenuTarget.pick(_:)), keyEquivalent: "")
      item.target = target
      item.representedObject = id
      menu.addItem(item)
    }
    add("Recent recordings", "recents")
    add("Settings", "settings")
    menu.addItem(.separator())
    add("Quit Slipreel", "quit")
    // view: nil → location is in screen coordinates; pop at the cursor.
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    result(target.selected)
  }

  /// Drags the window using the in-flight mouse event. Invoked from Flutter on
  /// pan-start over any non-button area of the bar.
  private func startWindowDrag() {
    if let event = NSApp.currentEvent {
      performDrag(with: event)
    }
  }

  private func configureFloating(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
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
    contentView?.layer?.cornerRadius = cornerRadius
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
