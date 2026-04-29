import Foundation
import CoreGraphics

enum ResizeHandle: CaseIterable {
  case nw, n, ne, e, se, s, sw, w

  func position(in rect: CGRect) -> CGPoint {
    switch self {
    case .nw: return CGPoint(x: rect.minX, y: rect.minY)
    case .n:  return CGPoint(x: rect.midX, y: rect.minY)
    case .ne: return CGPoint(x: rect.maxX, y: rect.minY)
    case .e:  return CGPoint(x: rect.maxX, y: rect.midY)
    case .se: return CGPoint(x: rect.maxX, y: rect.maxY)
    case .s:  return CGPoint(x: rect.midX, y: rect.maxY)
    case .sw: return CGPoint(x: rect.minX, y: rect.maxY)
    case .w:  return CGPoint(x: rect.minX, y: rect.midY)
    }
  }

  static func hit(at point: CGPoint, in rect: CGRect, tolerance: CGFloat = 12) -> ResizeHandle? {
    func near(_ a: CGPoint, _ b: CGPoint) -> Bool {
      return abs(a.x - b.x) <= tolerance && abs(a.y - b.y) <= tolerance
    }
    // Order corners before edges so a click at a corner gets the corner handle.
    for h in [ResizeHandle.se, .ne, .sw, .nw, .n, .s, .e, .w] {
      if near(point, h.position(in: rect)) { return h }
    }
    return nil
  }

  func apply(originalRect: CGRect, current: CGPoint) -> CGRect {
    let anchor = position(in: originalRect)
    let dx = current.x - anchor.x
    let dy = current.y - anchor.y
    var minX = originalRect.minX
    var minY = originalRect.minY
    var maxX = originalRect.maxX
    var maxY = originalRect.maxY
    switch self {
    case .nw: minX += dx; minY += dy
    case .n:               minY += dy
    case .ne: maxX += dx; minY += dy
    case .e:  maxX += dx
    case .se: maxX += dx; maxY += dy
    case .s:               maxY += dy
    case .sw: minX += dx; maxY += dy
    case .w:  minX += dx
    }
    return CGRect(x: min(minX, maxX), y: min(minY, maxY),
                  width: abs(maxX - minX), height: abs(maxY - minY))
  }
}

enum RegionSelectionState {
  case idle
  case drawing(start: CGPoint, current: CGPoint)
  case selected(rect: CGRect)
  case resizing(handle: ResizeHandle, originalRect: CGRect, current: CGPoint)
  case moving(originalRect: CGRect, dragStart: CGPoint, current: CGPoint)
  case cancelled
  case confirmed(rect: CGRect)
}

enum RegionEvent {
  case mouseDown(at: CGPoint)
  case mouseDragged(to: CGPoint)
  case mouseUp(at: CGPoint)
  case escapePressed
  case startPressed
  case cancelPressed
}

struct RegionSelectorMachine {
  static let minSize: CGFloat = 50

  private(set) var state: RegionSelectionState = .idle
  let displayBounds: CGRect

  init(displayBounds: CGRect) {
    self.displayBounds = displayBounds
  }

  var currentRect: CGRect {
    switch state {
    case .idle, .cancelled:
      return .zero
    case .drawing(let start, let current):
      return CGRect(
        x: min(start.x, current.x),
        y: min(start.y, current.y),
        width: abs(current.x - start.x),
        height: abs(current.y - start.y)
      ).intersection(displayBounds)
    case .selected(let r):
      return r
    case .confirmed(let r):
      return r
    case .resizing(let handle, let originalRect, let current):
      return handle.apply(originalRect: originalRect, current: current)
        .intersection(displayBounds)
    case .moving(let originalRect, let dragStart, let current):
      let dx = current.x - dragStart.x
      let dy = current.y - dragStart.y
      let translated = originalRect.offsetBy(dx: dx, dy: dy)
      return clampToDisplay(translated)
    }
  }

  private func clampToDisplay(_ r: CGRect) -> CGRect {
    var clamped = r
    if clamped.maxX > displayBounds.maxX {
      clamped.origin.x = displayBounds.maxX - clamped.width
    }
    if clamped.maxY > displayBounds.maxY {
      clamped.origin.y = displayBounds.maxY - clamped.height
    }
    if clamped.minX < displayBounds.minX { clamped.origin.x = displayBounds.minX }
    if clamped.minY < displayBounds.minY { clamped.origin.y = displayBounds.minY }
    return clamped
  }

  mutating func handle(_ event: RegionEvent) {
    switch event {
    case .escapePressed:
      // .confirmed is terminal; escape after confirm should not destroy the result.
      if case .confirmed = state { return }
      state = .cancelled
      return
    default:
      break
    }
    switch state {
    case .idle:
      handleFromIdle(event)
    case .drawing(let start, _):
      handleFromDrawing(event, start: start)
    case .selected(let rect):
      handleFromSelected(event, rect: rect)
    case .resizing(let handle, let originalRect, _):
      handleFromResizing(event, handle: handle, originalRect: originalRect)
    case .moving(let originalRect, let dragStart, _):
      handleFromMoving(event, originalRect: originalRect, dragStart: dragStart)
    case .cancelled, .confirmed:
      break
    }
  }

  private mutating func handleFromIdle(_ event: RegionEvent) {
    if case let .mouseDown(p) = event {
      state = .drawing(start: p, current: p)
    }
  }

  private mutating func handleFromDrawing(_ event: RegionEvent, start: CGPoint) {
    switch event {
    case .mouseDragged(let to):
      state = .drawing(start: start, current: to)
    case .mouseUp(let at):
      let raw = CGRect(
        x: min(start.x, at.x),
        y: min(start.y, at.y),
        width: abs(at.x - start.x),
        height: abs(at.y - start.y)
      )
      let clipped = raw.intersection(displayBounds)
      if clipped.width >= Self.minSize && clipped.height >= Self.minSize {
        state = .selected(rect: clipped)
      } else {
        state = .idle
      }
    default:
      break
    }
  }

  private mutating func handleFromSelected(_ event: RegionEvent, rect: CGRect) {
    switch event {
    case .mouseDown(let p):
      if let h = ResizeHandle.hit(at: p, in: rect) {
        state = .resizing(handle: h, originalRect: rect, current: p)
      } else if rect.contains(p) {
        state = .moving(originalRect: rect, dragStart: p, current: p)
      } else {
        state = .drawing(start: p, current: p)
      }
    case .startPressed:
      state = .confirmed(rect: rect)
    case .cancelPressed:
      state = .cancelled
    default:
      break
    }
  }

  private mutating func handleFromResizing(_ event: RegionEvent, handle: ResizeHandle,
                                            originalRect: CGRect) {
    switch event {
    case .mouseDragged(let to):
      state = .resizing(handle: handle, originalRect: originalRect, current: to)
    case .mouseUp(let to):
      let raw = handle.apply(originalRect: originalRect, current: to)
      let clipped = raw.intersection(displayBounds)
      if clipped.width >= Self.minSize && clipped.height >= Self.minSize {
        state = .selected(rect: clipped)
      } else {
        state = .selected(rect: originalRect)
      }
    default:
      break
    }
  }

  private mutating func handleFromMoving(_ event: RegionEvent, originalRect: CGRect,
                                          dragStart: CGPoint) {
    switch event {
    case .mouseDragged(let to):
      state = .moving(originalRect: originalRect, dragStart: dragStart, current: to)
    case .mouseUp(let to):
      let dx = to.x - dragStart.x
      let dy = to.y - dragStart.y
      let translated = originalRect.offsetBy(dx: dx, dy: dy)
      state = .selected(rect: clampToDisplay(translated))
    default:
      break
    }
  }
}

#if DEBUG
extension RegionSelectorMachine {
  mutating func setSelectedForTest(_ rect: CGRect) {
    state = .selected(rect: rect)
  }
}
#endif
