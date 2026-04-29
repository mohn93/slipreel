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

  override func applicationDidFinishLaunching(_ aNotification: Notification) {
    super.applicationDidFinishLaunching(aNotification)
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      // Hide every window during XCTest runs so the host app stays invisible.
      NSApp.windows.forEach { $0.orderOut(nil) }
    }
  }
}
