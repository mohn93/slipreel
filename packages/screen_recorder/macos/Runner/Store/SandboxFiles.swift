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
      guard let self, call.method == "remember", let path = call.arguments as? String else { result(FlutterMethodNotImplemented); return }
      do {
        #if APP_STORE
        try self.remember(URL(fileURLWithPath:path),keyPath:path)
        #endif
        result(nil)
      } catch { result(FlutterError(code:"FOLDER_ACCESS",message:"Select the folder again to allow access.",details:nil)) }
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
