// packages/screen_recorder_macos/macos/Classes/PerfSampler.swift
import Foundation
import Darwin

/// Samples this process's CPU% (across all threads) and resident memory at
/// 1 Hz on a background queue. Call `start()` when the recording begins and
/// `stop()` when it ends — `stop()` returns the aggregate stats.
class PerfSampler {
  struct Stats {
    let cpuPctSamples: [Double]
    let memBytesSamples: [UInt64]

    var cpuPctAvg: Double {
      guard !cpuPctSamples.isEmpty else { return 0 }
      return cpuPctSamples.reduce(0, +) / Double(cpuPctSamples.count)
    }
    var cpuPctP95: Double {
      guard !cpuPctSamples.isEmpty else { return 0 }
      let sorted = cpuPctSamples.sorted()
      let idx = Int((Double(sorted.count - 1) * 0.95).rounded())
      return sorted[idx]
    }
    var memBytesPeak: UInt64 { memBytesSamples.max() ?? 0 }
  }

  private var timer: DispatchSourceTimer?
  private var samples = Stats(cpuPctSamples: [], memBytesSamples: [])
  private let queue = DispatchQueue(label: "com.screenflow_studio.perf_sampler")
  private let lock = NSLock()
  private var cpuPctAccum: [Double] = []
  private var memBytesAccum: [UInt64] = []

  private var lastTotalUserTime: TimeInterval = 0
  private var lastTotalSystemTime: TimeInterval = 0
  private var lastSampleAt: Date = Date()

  func start() {
    lock.lock()
    cpuPctAccum.removeAll()
    memBytesAccum.removeAll()
    (lastTotalUserTime, lastTotalSystemTime) = currentCpuTimes()
    lastSampleAt = Date()
    lock.unlock()

    let t = DispatchSource.makeTimerSource(queue: queue)
    t.schedule(deadline: .now() + 1.0, repeating: 1.0)
    t.setEventHandler { [weak self] in self?.takeSample() }
    timer = t
    t.resume()
  }

  func stop() -> Stats {
    timer?.cancel()
    timer = nil
    lock.lock()
    let s = Stats(cpuPctSamples: cpuPctAccum, memBytesSamples: memBytesAccum)
    lock.unlock()
    return s
  }

  // MARK: - Sampling

  private func takeSample() {
    let (user, system) = currentCpuTimes()
    let cpuTime = (user - lastTotalUserTime) + (system - lastTotalSystemTime)
    let now = Date()
    let wall = now.timeIntervalSince(lastSampleAt)
    let pct = wall > 0 ? (cpuTime / wall) * 100.0 : 0
    let mem = currentResidentMemoryBytes()

    lock.lock()
    cpuPctAccum.append(pct)
    memBytesAccum.append(mem)
    lock.unlock()

    lastTotalUserTime = user
    lastTotalSystemTime = system
    lastSampleAt = now
  }

  private func currentCpuTimes() -> (user: TimeInterval, system: TimeInterval) {
    var info = task_thread_times_info()
    var count = mach_msg_type_number_t(MemoryLayout<task_thread_times_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(TASK_THREAD_TIMES_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return (0, 0) }
    let user = TimeInterval(info.user_time.seconds) + TimeInterval(info.user_time.microseconds) / 1_000_000.0
    let system = TimeInterval(info.system_time.seconds) + TimeInterval(info.system_time.microseconds) / 1_000_000.0
    return (user, system)
  }

  private func currentResidentMemoryBytes() -> UInt64 {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
    let kr = withUnsafeMutablePointer(to: &info) {
      $0.withMemoryRebound(to: integer_t.self, capacity: 1) {
        task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
      }
    }
    guard kr == KERN_SUCCESS else { return 0 }
    return info.resident_size
  }
}
