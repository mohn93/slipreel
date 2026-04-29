import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
      // Skip Flutter view setup during XCTest runs so the host app stays
      // invisible. Without this, every test run flashes the Flutter window.
      super.awakeFromNib()
      return
    }
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
