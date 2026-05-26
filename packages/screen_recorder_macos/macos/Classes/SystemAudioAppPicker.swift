import AppKit
import ScreenCaptureKit

/// A small native multi-select panel of running apps, modeled on
/// SourcePickerOverlay's async-continuation pattern. Returns the chosen bundle
/// ids, or nil if cancelled. macOS 13+.
@available(macOS 13.0, *)
final class SystemAudioAppPicker: NSObject {
  private var window: NSWindow?
  private var continuation: CheckedContinuation<[String]?, Never>?
  private var rows: [(bundleId: String, checkbox: NSButton)] = []
  private weak var doneButton: NSButton?

  /// Present the picker with `preselected` bundle ids checked. Awaits the user.
  func pick(preselected: [String]) async -> [String]? {
    let content = try? await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: false)
    var seen = Set<String>()
    let apps = (content?.applications ?? [])
      .filter { !$0.bundleIdentifier.isEmpty && seen.insert($0.bundleIdentifier).inserted }
      .sorted { $0.applicationName.localizedCaseInsensitiveCompare($1.applicationName) == .orderedAscending }

    return await withCheckedContinuation { cont in
      self.continuation = cont
      DispatchQueue.main.async { self.present(apps: apps, preselected: Set(preselected)) }
    }
  }

  private func present(apps: [SCRunningApplication], preselected: Set<String>) {
    let rowH: CGFloat = 28, pad: CGFloat = 16, w: CGFloat = 340
    let listH = CGFloat(max(1, apps.count)) * rowH
    let h = listH + pad * 2 + 44

    let win = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: w, height: h),
      styleMask: [.titled, .closable], backing: .buffered, defer: false)
    win.title = "System audio — select apps"
    win.center()
    win.isReleasedWhenClosed = false

    let content = NSView(frame: win.contentView!.bounds)
    var y = h - pad - rowH
    for app in apps {
      let cb = NSButton(checkboxWithTitle: "  \(app.applicationName)",
                        target: self, action: #selector(toggleChanged))
      cb.frame = NSRect(x: pad, y: y, width: w - pad * 2, height: rowH)
      cb.state = preselected.contains(app.bundleIdentifier) ? .on : .off
      content.addSubview(cb)
      rows.append((app.bundleIdentifier, cb))
      y -= rowH
    }

    let cancel = NSButton(title: "Cancel", target: self, action: #selector(onCancel))
    cancel.frame = NSRect(x: w - 180, y: pad, width: 80, height: 28)
    cancel.bezelStyle = .rounded
    content.addSubview(cancel)

    let done = NSButton(title: "Done", target: self, action: #selector(onDone))
    done.frame = NSRect(x: w - 92, y: pad, width: 80, height: 28)
    done.bezelStyle = .rounded
    done.keyEquivalent = "\r"
    self.doneButton = done
    content.addSubview(done)

    win.contentView = content
    self.window = win
    updateDoneEnabled()
    NSApp.activate(ignoringOtherApps: true)
    win.makeKeyAndOrderFront(nil)
  }

  @objc private func toggleChanged() { updateDoneEnabled() }

  private func updateDoneEnabled() {
    doneButton?.isEnabled = rows.contains { $0.checkbox.state == .on }
  }

  @objc private func onDone() {
    let chosen = rows.filter { $0.checkbox.state == .on }.map { $0.bundleId }
    finish(chosen)
  }

  @objc private func onCancel() { finish(nil) }

  private func finish(_ value: [String]?) {
    window?.orderOut(nil)
    window = nil
    rows = []
    continuation?.resume(returning: value)
    continuation = nil
  }
}
