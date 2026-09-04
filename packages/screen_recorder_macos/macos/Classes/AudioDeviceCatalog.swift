import Foundation
import CoreAudio

/// Enumerates audio INPUT devices via CoreAudio (lists built-in, USB, virtual
/// like VB-Cable, and continuity devices — more complete than AVCaptureDevice),
/// and resolves a stable device UID back to a live AudioDeviceID at capture time.
enum AudioDeviceCatalog {
  /// All input-capable devices as `[ "id": UID, "name": ..., "type": "microphone", "isDefault": Bool ]`.
  static func inputDevices() -> [[String: Any]] {
    let defaultID = defaultInputDeviceID()
    var result: [[String: Any]] = []
    for id in allDeviceIDs() where hasInputStreams(id) {
      guard let uid = stringProperty(id, kAudioDevicePropertyDeviceUID),
            let name = stringProperty(id, kAudioObjectPropertyName) else { continue }
      // AVAudioEngine creates process-local aggregate devices while it joins
      // the selected input to the current output (and when voice processing is
      // enabled). They are ephemeral routing details, not microphones a user
      // can meaningfully select, and disappear when this process exits.
      guard !isEngineManagedAggregate(uid: uid, name: name) else { continue }
      result.append([
        "id": uid,
        "name": name,
        "type": "microphone",
        "isDefault": id == defaultID,
      ])
    }
    return result
  }

  /// Resolve a device UID to the current AudioDeviceID, or nil if not present.
  static func deviceID(forUID uid: String) -> AudioDeviceID? {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var cfUID = uid as CFString
    var deviceID = AudioDeviceID(0)
    var outSize = UInt32(MemoryLayout<AudioDeviceID>.size)
    let inSize = UInt32(MemoryLayout<CFString>.size)
    let status = withUnsafeMutablePointer(to: &cfUID) { uidPtr in
      AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
        &address, inSize, uidPtr, &outSize, &deviceID)
    }
    return (status == noErr && deviceID != 0) ? deviceID : nil
  }

  static func isDefaultInputDevice(_ id: AudioDeviceID) -> Bool {
    return id == defaultInputDeviceID()
  }

  /// Whether [routeID] still represents [selectedID] after AVAudioEngine has
  /// started. macOS can replace the audio unit's public device ID with a
  /// process-local aggregate even though that aggregate still routes the exact
  /// physical input selected before `engine.start()`.
  static func route(_ routeID: AudioDeviceID, contains selectedID: AudioDeviceID) -> Bool {
    if routeID == selectedID { return true }
    if activeSubDeviceIDs(of: routeID).contains(selectedID) { return true }

    // The active-subdevice list can briefly be unavailable while Core Audio is
    // assembling its private wrapper. The explicit device was already resolved,
    // set, and verified before engine startup, so this wrapper is a valid route.
    guard let uid = stringProperty(routeID, kAudioDevicePropertyDeviceUID),
          let name = stringProperty(routeID, kAudioObjectPropertyName) else {
      return false
    }
    return isEngineManagedAggregate(uid: uid, name: name)
  }

  // MARK: - CoreAudio helpers

  private static func allDeviceIDs() -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDevices,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &dataSize) == noErr else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &dataSize, &ids) == noErr else { return [] }
    return ids
  }

  private static func hasInputStreams(_ id: AudioDeviceID) -> Bool {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioDevicePropertyStreams,
      mScope: kAudioObjectPropertyScopeInput,
      mElement: kAudioObjectPropertyElementMain)
    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr
    else { return false }
    return dataSize > 0
  }

  private static func activeSubDeviceIDs(of id: AudioDeviceID) -> [AudioDeviceID] {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioAggregateDevicePropertyActiveSubDeviceList,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    guard AudioObjectHasProperty(id, &address) else { return [] }

    var dataSize: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &dataSize) == noErr,
          dataSize >= UInt32(MemoryLayout<AudioDeviceID>.size) else { return [] }
    let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
    var ids = [AudioDeviceID](repeating: 0, count: count)
    guard AudioObjectGetPropertyData(id, &address, 0, nil, &dataSize, &ids) == noErr
    else { return [] }
    return ids
  }

  private static func isEngineManagedAggregate(uid: String, name: String) -> Bool {
    let prefixes = ["CADefaultDeviceAggregate-", "VPAUAggregateAudioDevice-"]
    return prefixes.contains { uid.hasPrefix($0) || name.hasPrefix($0) }
  }

  private static func defaultInputDeviceID() -> AudioDeviceID {
    var address = AudioObjectPropertyAddress(
      mSelector: kAudioHardwarePropertyDefaultInputDevice,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    _ = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
      &address, 0, nil, &size, &deviceID)
    return deviceID
  }

  private static func stringProperty(_ id: AudioDeviceID,
                                     _ selector: AudioObjectPropertySelector) -> String? {
    var address = AudioObjectPropertyAddress(
      mSelector: selector,
      mScope: kAudioObjectPropertyScopeGlobal,
      mElement: kAudioObjectPropertyElementMain)
    var unmanaged: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    let status = withUnsafeMutablePointer(to: &unmanaged) { ptr in
      AudioObjectGetPropertyData(id, &address, 0, nil, &size, ptr)
    }
    guard status == noErr, let value = unmanaged else { return nil }
    return value.takeRetainedValue() as String
  }
}
