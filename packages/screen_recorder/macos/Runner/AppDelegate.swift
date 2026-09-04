import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
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
