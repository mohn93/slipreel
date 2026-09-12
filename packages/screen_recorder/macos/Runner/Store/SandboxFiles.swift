import Cocoa
import FlutterMacOS

/// Persist access only to folders explicitly selected by the user. References
/// are restored before Dart loads recording history or preferences.
final class SandboxFiles {
  private var active: [URL] = []
  private let channel: FlutterMethodChannel
  private let key = "SlipreelSecurityBookmarks"
  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name:"slipreel/sandbox-files",binaryMessenger:messenger)
    #if APP_STORE
    let saved = UserDefaults.standard.dictionary(forKey:key) as? [String:Data] ?? [:]
    for (path,data) in saved {
      var stale = false
      if let url = try? URL(resolvingBookmarkData:data,options:[.withSecurityScope],relativeTo:nil,bookmarkDataIsStale:&stale), url.startAccessingSecurityScopedResource() {
        active.append(url)
        if stale { try? remember(url, keyPath:path) }
      }
    }
    #endif
    channel.setMethodCallHandler { [weak self] call,result in
      guard let self, let path = call.arguments as? String else {
        result(FlutterMethodNotImplemented); return
      }
      do {
        switch call.method {
        case "remember":
          #if APP_STORE
          try self.remember(URL(fileURLWithPath:path),keyPath:path)
          #endif
          result(nil)
        case "exportStagingDirectory":
          // Save-panel access covers the destination file, not its parent.
          // Ask Foundation for same-volume staging instead of creating a
          // sibling folder in a directory the user did not grant access to.
          let directory = try FileManager.default.url(
            for: .itemReplacementDirectory, in: .userDomainMask,
            appropriateFor: URL(fileURLWithPath: path), create: true)
          result(directory.path)
        default:
          result(FlutterMethodNotImplemented)
        }
      } catch {
        result(FlutterError(code: call.method == "remember" ? "FOLDER_ACCESS" : "EXPORT_STAGING",
          message: call.method == "remember" ? "Select the folder again to allow access." : "Choose the export file again to allow saving.", details:nil))
      }
    }
  }
  private func remember(_ url: URL, keyPath: String) throws {
    let data = try url.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil)
    var saved = UserDefaults.standard.dictionary(forKey:key) as? [String:Data] ?? [:]
    saved[keyPath] = data
    UserDefaults.standard.set(saved,forKey:key)
    if !active.contains(url), url.startAccessingSecurityScopedResource() { active.append(url) }
  }
  deinit { for url in active { url.stopAccessingSecurityScopedResource() } }
}
