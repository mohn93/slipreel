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

/// Borderless overlays must explicitly opt in to keyboard focus for Esc.
private final class SourcePickerWindow: NSWindow {
  override var canBecomeKey: Bool { true }
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
    // nit: with no displays (headless / CI) the loop would create no overlay
    // windows, so nothing could ever finish/cancel and the awaiting
    // continuation would hang forever. Resume with nil instead.
    guard !NSScreen.screens.isEmpty else {
      cancel()
      return
    }
    for screen in NSScreen.screens {
      let win = SourcePickerWindow(
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
        for v in self.pickerViews {
          v.keyboardSelectedID = nil
          if v !== active { v.clearHover() }
        }
      }
      win.contentView = view
      win.orderFrontRegardless()
      overlayWindows.append(win)
      pickerViews.append(view)
    }
    NSApp.activate(ignoringOtherApps: true)
    if let firstWindow = overlayWindows.first {
      firstWindow.makeKeyAndOrderFront(nil)
      if let firstView = pickerViews.first {
        firstWindow.makeFirstResponder(firstView)
      }
    }

    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
      guard let self else { return e }
      if e.keyCode == 53 { self.cancel(); return nil } // Esc
      if e.keyCode == 48, self.kind == .window { // Tab / Shift-Tab
        self.cycleWindowSelection(reverse: e.modifierFlags.contains(.shift))
        return nil
      }
      if e.keyCode == 36 || e.keyCode == 76 { // Return / Enter
        if let id = self.pickerViews.compactMap(\.keyboardSelectedID).first
          ?? self.pickerViews.compactMap(\.hoveredTargetID).first {
          self.finish(id: id)
        }
        return nil
      }
      return e
    }
  }

  /// Tab steps through windows under the pointer first, including those hidden
  /// by the frontmost window. Elsewhere, it steps through all available windows.
  private func cycleWindowSelection(reverse: Bool) {
    let mouse = NSEvent.mouseLocation
    let pointedView = zip(overlayWindows, pickerViews).first {
      $0.0.frame.contains(mouse)
    }.map { $0.1 }
    let underPointer: [PickerTarget] = pointedView.flatMap { view in
      guard let window = view.window else { return nil }
      let point = view.convert(window.convertPoint(fromScreen: mouse), from: nil)
      return view.targets.filter { $0.appName != nil && $0.localFrame.contains(point) }
    } ?? []
    let allWindows = pickerViews.flatMap { $0.targets.filter { $0.appName != nil } }
    let siblings = allWindows.filter {
      $0.appName == underPointer.first?.appName
    }
    let candidates = siblings.count > 1 ? siblings
      : underPointer.count > 1 ? underPointer : allWindows
    var seen = Set<String>()
    let ids = candidates.map(\.id).filter { seen.insert($0).inserted }
    guard !ids.isEmpty else { return }
    let current = pickerViews.compactMap(\.keyboardSelectedID).first
      ?? pointedView?.hoveredTargetID
    let currentIndex = current.flatMap { ids.firstIndex(of: $0) }
    let nextIndex = currentIndex.map { ($0 + (reverse ? ids.count - 1 : 1)) % ids.count }
      ?? (reverse ? ids.count - 1 : 0)
    let id = ids[nextIndex]
    let selectedView = (pointedView?.targets.contains { $0.id == id } == true)
      ? pointedView
      : pickerViews.first { $0.targets.contains { $0.id == id } }
    for view in pickerViews {
      view.clearHover()
      view.keyboardSelectedID = view === selectedView ? id : nil
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
          id: String(displayId), title: name, appName: nil, icon: nil, localFrame: full)]
      }
    case .window:
      let raw = content.windows.map { SourceCatalog.rawWindow(from: $0) }
      let visible = SourceCatalog.frontToBack(
        SourceCatalog.pickableWindows(raw), orderedIDs: windowStackingOrder())
      for screen in NSScreen.screens {
        guard let displayId = screen.deviceDescription[
          NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
        let displayBounds = CGDisplayBounds(displayId) // global, top-left origin
        var targets: [PickerTarget] = []
        for w in visible {
          guard w.frame.intersects(displayBounds) else { continue }
          let local = SourcePickerGeometry.localFrame(window: w.frame, displayBounds: displayBounds)
          let title = w.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
          targets.append(PickerTarget(
            id: String(w.id),
            title: title.isEmpty ? "Window \(w.id)" : title,
            appName: w.ownerName,
            icon: appIcon(bundleId: w.ownerBundleId),
            localFrame: local))
        }
        result[screen] = targets
      }
    }
    return result
  }

  private func windowStackingOrder() -> [UInt32] {
    guard let windows = CGWindowListCopyWindowInfo(
      [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
        as? [[String: Any]] else { return [] }
    return windows.compactMap {
      ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }
  }

  private func appIcon(bundleId: String) -> NSImage? {
    guard !bundleId.isEmpty else { return nil }
    if let running = NSWorkspace.shared.runningApplications.first(where: {
      $0.bundleIdentifier == bundleId
    }) {
      return running.icon
    }
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
      return nil
    }
    return NSWorkspace.shared.icon(forFile: url.path)
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
