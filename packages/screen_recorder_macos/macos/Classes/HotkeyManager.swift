// packages/screen_recorder_macos/macos/Classes/HotkeyManager.swift
import AppKit
import Carbon.HIToolbox

/// Owns the Carbon hotkey registration + event handler. Wires three fixed
/// hotkeys (Cmd+Shift+1/2/P) and forwards each press through `onAction`.
final class HotkeyManager {
  enum Action: String { case start, stop, pauseToggle }

  /// Set by the plugin after the hotkeys EventChannel sink is attached.
  var onAction: ((Action) -> Void)?
  /// Set similarly for conflict reports.
  var onConflict: ((UInt32) -> Void)?

  private var hotKeyRefs: [EventHotKeyRef?] = []
  private var handlerRef: EventHandlerRef?
  private var registered = false

  func registerAll() {
    if registered { return }
    let signature: OSType = 0x736C7270 /* 'slrp' */
    let modifiers = UInt32(cmdKey | shiftKey)
    let entries: [(UInt32, UInt32, Action)] = [
      (1, UInt32(kVK_ANSI_1), .start),
      (2, UInt32(kVK_ANSI_2), .stop),
      (3, UInt32(kVK_ANSI_P), .pauseToggle),
    ]

    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                             eventKind: UInt32(kEventHotKeyPressed))
    let selfPtr = Unmanaged.passUnretained(self).toOpaque()
    InstallEventHandler(GetApplicationEventTarget(),
                        { (_, event, ctx) -> OSStatus in
                          guard let ctx = ctx, let event = event else { return noErr }
                          let manager = Unmanaged<HotkeyManager>.fromOpaque(ctx)
                            .takeUnretainedValue()
                          var hkID = EventHotKeyID()
                          let status = GetEventParameter(event,
                                                          EventParamName(kEventParamDirectObject),
                                                          EventParamType(typeEventHotKeyID),
                                                          nil,
                                                          MemoryLayout<EventHotKeyID>.size,
                                                          nil,
                                                          &hkID)
                          if status == noErr {
                            manager.dispatch(id: hkID.id)
                          }
                          return noErr
                        },
                        1,
                        &spec,
                        selfPtr,
                        &handlerRef)

    for (id, keyCode, _) in entries {
      var ref: EventHotKeyRef?
      let hkID = EventHotKeyID(signature: signature, id: id)
      let status = RegisterEventHotKey(keyCode, modifiers, hkID,
                                       GetApplicationEventTarget(), 0, &ref)
      if status == noErr {
        hotKeyRefs.append(ref)
      } else {
        onConflict?(id)
      }
    }
    // Latch the registered flag only when at least one hotkey actually
    // registered; otherwise a subsequent call should be allowed to retry
    // (e.g. the conflicting app may have released its binding).
    if !hotKeyRefs.isEmpty {
      registered = true
    }
  }

  func unregisterAll() {
    for ref in hotKeyRefs { if let ref = ref { UnregisterEventHotKey(ref) } }
    hotKeyRefs.removeAll()
    if let handler = handlerRef { RemoveEventHandler(handler); handlerRef = nil }
    registered = false
  }

  private func dispatch(id: UInt32) {
    switch id {
    case 1: onAction?(.start)
    case 2: onAction?(.stop)
    case 3: onAction?(.pauseToggle)
    default: break
    }
  }
}
