import AppKit
import CoreGraphics
import ScreenCaptureKit

/// What kind of targets to show.
enum PickerKind { case window, screen }

/// Result handed back to Flutter.
struct PickedSourceResult {
  let kind: PickerKind
  let id: String
}

/// Shows borderless transparent overlay windows (one per NSScreen) painting
/// the pickable targets, and returns the chosen source. Modeled on
/// `RegionSelector`.
@MainActor
final class SourcePickerOverlay {
  static let shared = SourcePickerOverlay()
  private init() {}

  private var overlayWindows: [NSWindow] = []
  private var pickerViews: [SourcePickerView] = []
  private var continuation: CheckedContinuation<PickedSourceResult?, Never>?
  private var escMonitor: Any?
  private var kind: PickerKind = .window
  private var inFlight = false

  func pick(kind: PickerKind) async -> PickedSourceResult? {
    if inFlight { return nil }
    inFlight = true
    defer { inFlight = false }
    self.kind = kind

    let targetsByScreen = await buildTargets(kind: kind)

    return await withCheckedContinuation { cont in
      self.continuation = cont
      present(targetsByScreen: targetsByScreen)
    }
  }

  private func present(targetsByScreen: [NSScreen: [PickerTarget]]) {
    overlayWindows.removeAll()
    pickerViews.removeAll()
    for screen in NSScreen.screens {
      let win = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
      win.level = .screenSaver
      win.isOpaque = false
      win.backgroundColor = .clear
      win.ignoresMouseEvents = false
      win.acceptsMouseMovedEvents = true
      win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

      let view = SourcePickerView(frame: NSRect(origin: .zero, size: screen.frame.size))
      view.targets = targetsByScreen[screen] ?? []
      view.onSelect = { [weak self] id in self?.finish(id: id) }
      view.onCancel = { [weak self] in self?.cancel() }
      // When this view gains a hover, clear every OTHER screen overlay so only
      // one highlight is ever shown (handles missed cross-screen mouseExited).
      view.onHoverChanged = { [weak self] active in
        guard let self = self else { return }
        for v in self.pickerViews where v !== active { v.clearHover() }
      }
      win.contentView = view
      win.orderFrontRegardless()
      overlayWindows.append(win)
      pickerViews.append(view)
    }
    NSApp.activate(ignoringOtherApps: true)
    overlayWindows.first?.makeKey()

    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      if e.keyCode == 53 { self?.cancel(); return nil } // Esc
      return e
    }
  }

  /// Builds per-screen targets. For windows, maps each on-screen window's CG
  /// frame to the display it sits on. For screens, one full-screen target.
  private func buildTargets(kind: PickerKind) async -> [NSScreen: [PickerTarget]] {
    var result: [NSScreen: [PickerTarget]] = [:]
    guard let content = try? await SCShareableContent.excludingDesktopWindows(
      false, onScreenWindowsOnly: true) else { return result }

    switch kind {
    case .screen:
      for screen in NSScreen.screens {
        guard let displayId = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
        let name = screen.localizedName
        let full = CGRect(origin: .zero, size: screen.frame.size)
        result[screen] = [PickerTarget(
          id: String(displayId), title: name, icon: nil, localFrame: full)]
      }
    case .window:
      let raw = content.windows.map { SourceCatalog.rawWindow(from: $0) }
      let visible = SourceCatalog.applyStrictFilter(raw)
      for screen in NSScreen.screens {
        guard let displayId = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
        let displayBounds = CGDisplayBounds(displayId) // global, top-left origin
        var targets: [PickerTarget] = []
        for w in visible {
          guard let xi = w["x"] as? Int, let yi = w["y"] as? Int,
                let wi = w["width"] as? Int, let hi = w["height"] as? Int,
                let id = w["id"] as? String else { continue }
          let cg = CGRect(x: CGFloat(xi), y: CGFloat(yi), width: CGFloat(wi), height: CGFloat(hi))
          guard cg.intersects(displayBounds) else { continue }
          let local = SourcePickerGeometry.localFrame(window: cg, displayBounds: displayBounds)
          let title = (w["title"] as? String) ?? ""
          let owner = (w["ownerName"] as? String) ?? ""
          targets.append(PickerTarget(
            id: id,
            title: title.isEmpty ? owner : title,
            icon: appIcon(ownerName: owner),
            localFrame: local))
        }
        result[screen] = targets
      }
    }
    return result
  }

  private func appIcon(ownerName: String) -> NSImage? {
    let app = NSWorkspace.shared.runningApplications.first { $0.localizedName == ownerName }
    return app?.icon
  }

  private func finish(id: String) {
    teardown()
    continuation?.resume(returning: PickedSourceResult(kind: kind, id: id))
    continuation = nil
  }

  private func cancel() {
    teardown()
    continuation?.resume(returning: nil)
    continuation = nil
  }

  private func teardown() {
    overlayWindows.forEach { $0.orderOut(nil) }
    overlayWindows.removeAll()
    pickerViews.removeAll()
    if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil }
  }
}
