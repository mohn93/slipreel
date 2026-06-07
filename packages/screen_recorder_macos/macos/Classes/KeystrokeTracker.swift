import Cocoa
import Foundation

/// Captures global keyboard events during screen recording and converts
/// them to a human-readable label (e.g. "⌘C", "⇧⌘Z", "Space", "↩").
///
/// Requires Accessibility permission (`AXIsProcessTrusted() == true`).
/// Without it, `startTracking()` is a no-op and the event stream is empty —
/// the inspector tab shows a "Grant Accessibility to enable" notice.
///
/// Only `.keyDown` events are emitted. Modifier-only presses (.flagsChanged)
/// are suppressed because they produce no meaningful display label.
class KeystrokeTracker {
  // MARK: - Public

  /// Called on the main thread with (displayLabel) when a key is pressed.
  var onKeystroke: ((String) -> Void)?

  private var globalMonitor: Any?
  private var isTracking = false

  // MARK: - Lifecycle

  func startTracking() {
    guard !isTracking else { return }
    guard AXIsProcessTrusted() else {
      print("[KeystrokeTracker] Accessibility not trusted — keystroke capture disabled.")
      return
    }

    globalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.keyDown]
    ) { [weak self] event in
      guard let self = self else { return }
      let label = Self.makeLabel(for: event)
      guard !label.isEmpty else { return }
      DispatchQueue.main.async {
        self.onKeystroke?(label)
      }
    }

    isTracking = true
    print("[KeystrokeTracker] Started.")
  }

  func stopTracking() {
    guard isTracking else { return }
    if let m = globalMonitor {
      NSEvent.removeMonitor(m)
      globalMonitor = nil
    }
    isTracking = false
    print("[KeystrokeTracker] Stopped.")
  }

  var isCurrentlyTracking: Bool { isTracking }

  // MARK: - Label composition

  /// Builds a display label such as "⌘C", "⇧⌘Z", "Space", "F5", "↩".
  private static func makeLabel(for event: NSEvent) -> String {
    let mods = event.modifierFlags.intersection([
      .control, .option, .shift, .command,
    ])

    // Resolve the key glyph (ignoring modifiers so Shift+C → "C").
    let keyGlyph = specialKeyGlyph(keyCode: event.keyCode)
      ?? (event.charactersIgnoringModifiers ?? "").uppercased()

    guard !keyGlyph.isEmpty else { return "" }

    // Suppress bare modifier taps that slipped through (shouldn't happen
    // with .keyDown-only monitoring, but belt-and-suspenders).
    let isModifierKey: Bool
    switch event.keyCode {
    case 54, 55, 56, 57, 58, 59, 60, 61, 62, 63: isModifierKey = true
    default: isModifierKey = false
    }
    if isModifierKey { return "" }

    let prefix = modifierString(mods)
    return prefix + keyGlyph
  }

  // MARK: - Modifier string

  /// Builds "⌃⌥⇧⌘" prefix in macOS canonical order.
  private static func modifierString(_ flags: NSEvent.ModifierFlags) -> String {
    var s = ""
    if flags.contains(.control) { s += "⌃" }
    if flags.contains(.option)  { s += "⌥" }
    if flags.contains(.shift)   { s += "⇧" }
    if flags.contains(.command) { s += "⌘" }
    return s
  }

  // MARK: - Special key mapping

  private static func specialKeyGlyph(keyCode: UInt16) -> String? {
    switch keyCode {
    // Navigation
    case 36: return "↩"   // Return
    case 76: return "⌤"   // Enter (numpad)
    case 53: return "⎋"   // Escape
    case 51: return "⌫"   // Delete (backspace)
    case 117: return "⌦"  // Forward delete
    case 48: return "⇥"   // Tab
    case 49: return "Space"
    // Arrows
    case 123: return "←"
    case 124: return "→"
    case 125: return "↓"
    case 126: return "↑"
    // Page navigation
    case 116: return "⇞"  // Page up
    case 121: return "⇟"  // Page down
    case 115: return "↖"  // Home
    case 119: return "↘"  // End
    // Function keys
    case 122: return "F1"
    case 120: return "F2"
    case 99:  return "F3"
    case 118: return "F4"
    case 96:  return "F5"
    case 97:  return "F6"
    case 98:  return "F7"
    case 100: return "F8"
    case 101: return "F9"
    case 109: return "F10"
    case 103: return "F11"
    case 111: return "F12"
    default: return nil
    }
  }
}
