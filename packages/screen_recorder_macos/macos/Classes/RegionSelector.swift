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
  private var toolbar: RegionToolbar?
  private var continuation: CheckedContinuation<RegionSelection?, Never>?
  private var activeScreen: NSScreen?

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
    NSApp.hide(nil)
    overlayWindows.removeAll()
    views.removeAll()
    toolbar = RegionToolbar()

    for screen in NSScreen.screens {
      let win = NSWindow(
        contentRect: screen.frame,
        styleMask: [.borderless],
        backing: .buffered,
        defer: false,
        screen: screen)
      win.level = .screenSaver
      win.isOpaque = false
      win.backgroundColor = .clear
      win.ignoresMouseEvents = false
      win.collectionBehavior = [.canJoinAllSpaces, .stationary]

      let view = RegionSelectorView(displayBounds: CGRect(origin: .zero, size: screen.frame.size))
      view.onStateChange = { [weak self] state in
        self?.handleStateChange(state, on: screen)
      }
      win.contentView = view
      win.makeKeyAndOrderFront(nil)
      win.makeFirstResponder(view)
      overlayWindows.append(win)
      views[screen] = view
    }

    toolbar?.onStart = { [weak self] in
      guard let self = self, let screen = self.activeScreen,
            let view = self.views[screen] else { return }
      view.triggerStart()
    }
    toolbar?.onCancel = { [weak self] in
      self?.cancelAll()
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

    let displayBounds = CGRect(origin: .zero, size: screen.frame.size)
    let currentRect = views[screen]?.machine.currentRect ?? .zero
    let screenOrigin = NSPoint(x: screen.frame.minX, y: screen.frame.minY)

    switch state {
    case .idle:
      toolbar?.hide()
    case .drawing:
      toolbar?.hide()
    case .selected:
      toolbar?.show(in: displayBounds, anchoredTo: currentRect, screenOrigin: screenOrigin)
    case .resizing, .moving:
      toolbar?.show(in: displayBounds, anchoredTo: currentRect, screenOrigin: screenOrigin)
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

  /// Cancels any in-progress region selection, returning nil to the waiting caller.
  func cancel() {
    cancelAll()
  }

  private func cancelAll() {
    teardown()
    continuation?.resume(returning: nil)
    continuation = nil
  }

  private func teardown() {
    toolbar?.hide()
    toolbar = nil
    for win in overlayWindows { win.orderOut(nil) }
    overlayWindows.removeAll()
    views.removeAll()
    activeScreen = nil
    NSApp.unhide(nil)
  }
}
