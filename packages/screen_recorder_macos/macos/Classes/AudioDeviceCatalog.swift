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
