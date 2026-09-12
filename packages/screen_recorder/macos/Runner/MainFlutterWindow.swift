import Cocoa
import FlutterMacOS
import IOKit

private final class GearMenuTarget: NSObject {
  var selected: String?
  @objc func pick(_ sender: NSMenuItem) {
    selected = sender.representedObject as? String
  }
}

/// Target for the macOS app-menu items (Settings…, Manage Account). Each
/// forwards to Flutter over the `slipreel/menu` channel, which the Dart side
/// routes to the same actions as the editor's in-window menu.
private final class AppMenuTarget: NSObject {
  private let channel: FlutterMethodChannel
  init(channel: FlutterMethodChannel) { self.channel = channel }
  @objc func openSettings(_ sender: Any?) {
    channel.invokeMethod("menuAction", arguments: "settings")
  }
  @objc func manageAccount(_ sender: Any?) {
    channel.invokeMethod("menuAction", arguments: "account")
  }
}

class MainFlutterWindow: NSWindow {
  private var sandboxFiles: SandboxFiles?
  private var storeBridge: StoreBridge?
  private var projectSaveChannel: FlutterMethodChannel?
  private var closingAfterSave = false

  func saveBeforeExit(_ completion: @escaping (Bool) -> Void) {
    guard let channel = projectSaveChannel else { completion(true); return }
    var completed = false
    let finish: (Bool) -> Void = { allowed in
      guard !completed else { return }
      completed = true
      completion(allowed)
    }
    channel.invokeMethod("saveBeforeExit", arguments: nil) { result in
      finish((result as? Bool) == true)
    }
    // A stalled Flutter isolate must not leave macOS waiting indefinitely.
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) { finish(false) }
  }

  override func performClose(_ sender: Any?) {
    if closingAfterSave { super.performClose(sender); return }
    saveBeforeExit { [weak self] allowed in
      guard let self = self, allowed else { return }
      self.closingAfterSave = true
      self.performClose(sender)
      self.closingAfterSave = false
    }
  }

  // Bar/pill are borderless; borderless windows refuse key/main unless we
  // opt in, which the bar needs to receive clicks (gear menu, mode buttons).
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { true }

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController
    sandboxFiles = SandboxFiles(messenger: flutterViewController.engine.binaryMessenger)
    storeBridge = StoreBridge(messenger: flutterViewController.engine.binaryMessenger, window: self)
    projectSaveChannel = FlutterMethodChannel(name: "slipreel/project-saves",
      binaryMessenger: flutterViewController.engine.binaryMessenger)

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
      case "setBarSize":
        guard let args = call.arguments as? [String: Any],
              let width = args["width"] as? Double,
              let height = args["height"] as? Double else {
          result(FlutterMethodNotImplemented)
          return
        }
        self?.setBarSize(width: CGFloat(width), height: CGFloat(height))
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let deviceChannel = FlutterMethodChannel(
      name: "slipreel/device",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    deviceChannel.setMethodCallHandler { call, result in
      switch call.method {
      case "copyFile":
        guard let path = call.arguments as? String,
              FileManager.default.fileExists(atPath: path) else {
          result(FlutterError(code: "FILE_NOT_FOUND", message: "Export file is missing", details: nil))
          return
        }
        NSPasteboard.general.clearContents()
        if NSPasteboard.general.writeObjects([NSURL(fileURLWithPath: path)]) {
          result(nil)
        } else {
          result(FlutterError(code: "CLIPBOARD_FAILED", message: "Could not copy export", details: nil))
        }
      case "hardwareId":
        result(MainFlutterWindow.hardwareUUID())
      case "deviceName":
        // The Mac's sharing name (e.g. "Mohanned's MacBook Pro"), which by
        // default already contains the model type. Falls back to the hostname.
        result(Host.current().localizedName ?? ProcessInfo.processInfo.hostName)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    // Wire the macOS app menu (Settings… / Manage Account) to Flutter. The
    // main menu from MainMenu.xib is loaded by app launch; dispatch async so
    // it's definitely in place before we mutate it.
    let menuChannel = FlutterMethodChannel(
      name: "slipreel/menu",
      binaryMessenger: flutterViewController.engine.binaryMessenger)
    let menuTarget = AppMenuTarget(channel: menuChannel)
    self.appMenuTarget = menuTarget
    DispatchQueue.main.async { [weak self] in
      self?.installAppMenuItems(target: menuTarget)
    }

    // Start as the bar.
    applyMode("bar")

    super.awakeFromNib()
  }

  /// Strong reference so the app-menu items' target isn't deallocated.
  private var appMenuTarget: AppMenuTarget?

  /// Turn the default (dead) "Preferences…" item into a working "Settings…"
  /// (⌘,) and add "Manage Account" right below it, both in the leftmost
  /// application menu. Standard AppKit items (About, Services, Hide, Quit,
  /// and the Edit menu) are left untouched.
  private func installAppMenuItems(target: AppMenuTarget) {
    guard let appMenu = NSApp.mainMenu?.items.first?.submenu else { return }

    // Settings: reuse the existing Preferences/Settings slot if present,
    // otherwise insert one just under "About".
    let settingsItem: NSMenuItem
    if let existing = appMenu.items.first(where: {
      $0.title.contains("Preferences") || $0.title.contains("Settings")
    }) {
      settingsItem = existing
    } else {
      settingsItem = NSMenuItem(title: "Settings…", action: nil, keyEquivalent: ",")
      appMenu.insertItem(settingsItem, at: min(1, appMenu.items.count))
    }
    settingsItem.title = "Settings…"
    settingsItem.target = target
    settingsItem.action = #selector(AppMenuTarget.openSettings(_:))
    settingsItem.keyEquivalent = ","
    settingsItem.keyEquivalentModifierMask = [.command]

    // Manage Account, immediately below Settings (no duplicate on re-entry).
    if !appMenu.items.contains(where: { $0.title == "Manage Account" }) {
      let accountItem = NSMenuItem(
        title: "Manage Account",
        action: #selector(AppMenuTarget.manageAccount(_:)),
        keyEquivalent: "")
      accountItem.target = target
      appMenu.insertItem(accountItem, at: appMenu.index(of: settingsItem) + 1)
    }
  }

  /// Tracks the active mode so `setBarSize` only resizes while we're the bar.
  private var currentMode = "bar"

  private func applyMode(_ mode: String) {
    currentMode = mode
    switch mode {
    case "bar":
      // 736 is just the pre-measure default; Flutter measures the row content
      // and calls `setBarSize` to hug it (the mic/system-audio labels vary).
      configureFloating(width: 736, height: kBarHeight, cornerRadius: 18)
    case "pill":
      // Room for an explicit paused state and a labelled Finish action. The
      // prior 156-point icon-only pill was compact but undersized for its two
      // most important controls.
      configureFloating(width: 252, height: 52, cornerRadius: 26)
    case "panel":
      configurePanel(width: 1100, height: 720)
    default:
      break
    }
  }

  /// Fixed bar height; width is content-driven via `setBarSize`.
  private let kBarHeight: CGFloat = 68

  /// Resize the bar in place to width×height, anchoring the TOP-LEFT corner
  /// (in Cocoa bottom-left coords: keep origin.x; set origin.y so the top edge
  /// stays put). Grows/shrinks on the right & bottom; never re-centers / snaps
  /// to the top of the screen. Bar mode only.
  private func setBarSize(width: CGFloat, height: CGFloat) {
    guard currentMode == "bar" else { return }
    let w = max(320, min(width, 1400))
    let h = max(48, min(height, 200))
    var f = frame
    let top = f.maxY          // current top edge (screen coords)
    f.size.width = w
    f.size.height = h
    f.origin.y = top - h      // keep the top edge fixed
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

  /// The Mac's stable hardware UUID (IOPlatformUUID). Survives reinstalls and
  /// app updates; changes only with a logic-board swap. Returns nil if the
  /// registry lookup fails (the Dart side treats nil as "unavailable").
  private static func hardwareUUID() -> String? {
    let service = IOServiceGetMatchingService(
      kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    let cf = IORegistryEntryCreateCFProperty(
      service, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)
    return cf?.takeRetainedValue() as? String
  }

  private func configureFloating(width: CGFloat, height: CGFloat, cornerRadius: CGFloat) {
    styleMask = [.borderless]
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    isMovableByWindowBackground = true
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    // Clear any editor-mode floor so the small bar/pill can hug their size
    // (setBarSize resizes via setFrame, which a stale contentMinSize clamps).
    contentMinSize = NSSize(width: 1, height: 1)
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
    // Lock a usable desktop minimum — the editor UI isn't fully fluid, so
    // block the user from shrinking the window into overflow territory.
    contentMinSize = NSSize(width: 1000, height: 780)
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
