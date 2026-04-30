import AppKit
import CoreGraphics

struct RegionSelection {
  let displayId: CGDirectDisplayID
  let x: Int
  let y: Int
  let widthPx: Int
  let heightPx: Int
}

@MainActor
final class RegionSelector {
  static let shared = RegionSelector()
  private init() {}

  private var inFlight: Task<RegionSelection?, Never>?
  private var overlayWindows: [NSWindow] = []
  private var views: [NSScreen: RegionSelectorView] = [:]
  private var continuation: CheckedContinuation<RegionSelection?, Never>?
  private var activeScreen: NSScreen?
  private var escMonitor: Any?

  func selectRegion() async -> RegionSelection? {
    if let inFlight = inFlight { return await inFlight.value }
    let task = Task<RegionSelection?, Never> { [weak self] in
      guard let self = self else { return nil }
      return await self.runSelection()
    }
    inFlight = task
    defer { inFlight = nil }
    return await task.value
  }

  @MainActor
  private func runSelection() async -> RegionSelection? {
    overlayWindows.removeAll()
    views.removeAll()

    for screen in NSScreen.screens {
      // contentRect is in GLOBAL screen coordinates. We intentionally do NOT
      // pass `screen:` — when that parameter is non-nil, AppKit interprets
      // contentRect as relative to that screen's origin, which on a secondary
      // display (origin e.g. (1920, 0)) double-shifts the window off-screen.
      let win = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false)
      win.level = .screenSaver
      win.isOpaque = false
      win.backgroundColor = .clear
      win.ignoresMouseEvents = false
      win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]

      let view = RegionSelectorView(displayBounds: CGRect(origin: .zero, size: screen.frame.size))
      view.onStateChange = { [weak self] state in
        self?.handleStateChange(state, on: screen)
      }
      view.onToolbarCancel = { [weak self] in
        self?.cancelAll()
      }
      win.contentView = view
      win.orderFrontRegardless()
      overlayWindows.append(win)
      views[screen] = view
    }

    // Ensure overlays receive input. We do NOT call NSApp.hide here — hiding
    // the app would suppress these new overlays until the user clicks the
    // Dock icon. The screen-saver-level dim covers the Flutter window for us.
    NSApp.activate(ignoringOtherApps: true)
    if let firstWin = overlayWindows.first { firstWin.makeKey() }

    escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      if event.keyCode == 53 {  // Esc
        self?.cancelAll()
        return nil
      }
      return event
    }

    return await withCheckedContinuation { cont in
      self.continuation = cont
    }
  }

  private func handleStateChange(_ state: RegionSelectionState, on screen: NSScreen) {
    let isActiveDuringSelection: Bool
    switch state {
    case .drawing, .selected, .resizing, .moving:
      isActiveDuringSelection = true
    default:
      isActiveDuringSelection = false
    }
    if isActiveDuringSelection {
      activeScreen = screen
      for (_, v) in views.filter({ $0.key != screen }) {
        v.resetMachine()
      }
    }

    switch state {
    case .idle, .drawing, .selected, .resizing, .moving:
      break
    case .confirmed(let rect):
      finish(with: rect, on: screen)
    case .cancelled:
      cancelAll()
    }
  }

  private func finish(with rect: CGRect, on screen: NSScreen) {
    let scale = screen.backingScaleFactor
    let displayId = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) ?? 0
    let selection = RegionSelection(
      displayId: displayId,
      x: Int(rect.minX * scale),
      y: Int(rect.minY * scale),
      widthPx: Int(rect.width * scale),
      heightPx: Int(rect.height * scale)
    )
    teardown()
    continuation?.resume(returning: selection)
    continuation = nil
  }

  private func cancelAll() {
    teardown()
    continuation?.resume(returning: nil)
    continuation = nil
  }

  private func teardown() {
    for win in overlayWindows { win.orderOut(nil) }
    overlayWindows.removeAll()
    views.removeAll()
    activeScreen = nil
    if let m = escMonitor {
      NSEvent.removeMonitor(m)
      escMonitor = nil
    }
  }
}
