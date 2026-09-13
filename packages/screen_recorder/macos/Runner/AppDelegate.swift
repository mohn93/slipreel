import Cocoa
import UserNotifications
import Security
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  override func application(_ application: NSApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
    NotificationBridge.shared?.registered(deviceToken)
  }

  override init() {
    // This must run before plugin registration starts Sparkle. Automatic
    // scheduling stays off; Dart checks after resolving update coverage.
    UserDefaults.standard.set(false, forKey: "SUEnableAutomaticChecks")
    UserDefaults.standard.set(false, forKey: "SUAutomaticallyUpdate")
    super.init()
  }

  override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard let window = mainFlutterWindow as? MainFlutterWindow else { return .terminateNow }
    window.saveBeforeExit { allowed in sender.reply(toApplicationShouldTerminate: allowed) }
    return .terminateLater
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  // Reliably mark a clean exit for the native crash scanner (v1b).
  //
  // The diagnostics layer treats a surviving `session.json` at next launch as
  // "the previous session crashed" (the crash discriminator). It clears the
  // file on `AppLifecycleState.detached` — but that signal is not reliably
  // delivered on macOS desktop termination, so a normal Cmd+Q would leave the
  // file behind and look like a crash. `applicationWillTerminate` IS an AppKit
  // guarantee on any orderly termination (Cmd+Q, menu Quit, NSApp.terminate)
  // and is NOT called on a crash — exactly the clean-exit semantics we want —
  // so we delete the file here as the dependable backstop. Best-effort: any
  // failure is ignored, and a missing file (diagnostics off, or already
  // cleared by the Dart side) is a no-op.
  override func applicationWillTerminate(_ notification: Notification) {
    let fm = FileManager.default
    guard let appSupport = fm.urls(for: .applicationSupportDirectory,
                                   in: .userDomainMask).first else { return }
    let bundleId = Bundle.main.bundleIdentifier ?? "com.slipreel.app"
    let sessionFile = appSupport
      .appendingPathComponent(bundleId)
      .appendingPathComponent("diagnostics")
      .appendingPathComponent("session.json")
    try? fm.removeItem(at: sessionFile)
    super.applicationWillTerminate(notification)
  }
}

// Native permission/token bridge; no permission prompt occurs at launch.
final class NotificationBridge: NSObject, UNUserNotificationCenterDelegate {
  static var shared: NotificationBridge?
  private let channel: FlutterMethodChannel
  private var token: String?
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "slipreel/notifications", binaryMessenger: messenger)
    super.init()
    Self.shared = self
    UNUserNotificationCenter.current().delegate = self
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { return }
      switch call.method {
      case "status": self.status(result)
      case "requestPermission":
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
          DispatchQueue.main.async { self.status(result) }
        }
      case "openSettings":
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") { NSWorkspace.shared.open(url) }
        result(nil)
      default: result(FlutterMethodNotImplemented)
      }
    }
  }
  func registered(_ data: Data) {
    let next = data.map { String(format: "%02x", $0) }.joined()
    guard next != token else { return }
    token = next
    channel.invokeMethod("changed", arguments: nil)
  }
  private func status(_ result: @escaping FlutterResult) {
    UNUserNotificationCenter.current().getNotificationSettings { settings in
      let permission: String
      switch settings.authorizationStatus {
      case .authorized: permission = "authorized"
      case .denied: permission = "denied"
      case .provisional: permission = "provisional"
      default: permission = "notDetermined"
      }
      DispatchQueue.main.async {
        if settings.authorizationStatus == .authorized { NSApplication.shared.registerForRemoteNotifications() }
        let task = SecTaskCreateFromSelf(nil)
        let environment = task.flatMap { SecTaskCopyValueForEntitlement($0, "com.apple.developer.aps-environment" as CFString, nil) as? String }
        result(["permission": permission, "apnsToken": self.token as Any, "environment": environment ?? "production", "configured": environment != nil])
      }
    }
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
    NSApplication.shared.activate(ignoringOtherApps: true)
    channel.invokeMethod("openInbox", arguments: nil)
    completionHandler()
  }
  func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
    channel.invokeMethod("changed", arguments: nil)
    completionHandler([])
  }
}
