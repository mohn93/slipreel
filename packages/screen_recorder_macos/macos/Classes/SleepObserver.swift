import AppKit

final class SleepObserver {
  enum Event: String { case willSleep, didWake }

  var onEvent: ((Event) -> Void)?

  private var sleepToken: NSObjectProtocol?
  private var wakeToken: NSObjectProtocol?

  /// Idempotent — second call is a no-op.
  func start() {
    if sleepToken != nil { return }
    let center = NSWorkspace.shared.notificationCenter
    sleepToken = center.addObserver(
      forName: NSWorkspace.willSleepNotification,
      object: nil,
      queue: .main) { [weak self] _ in self?.onEvent?(.willSleep) }
    wakeToken = center.addObserver(
      forName: NSWorkspace.didWakeNotification,
      object: nil,
      queue: .main) { [weak self] _ in self?.onEvent?(.didWake) }
  }

  func stop() {
    let center = NSWorkspace.shared.notificationCenter
    if let t = sleepToken { center.removeObserver(t); sleepToken = nil }
    if let t = wakeToken { center.removeObserver(t); wakeToken = nil }
  }
}
