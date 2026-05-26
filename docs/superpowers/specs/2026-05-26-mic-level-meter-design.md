# Live Microphone Level Meter (Design)

**Date:** 2026-05-26
**Status:** Approved — ready for implementation plan
**Follows:** the microphone-capture feature (sub-project 1), merged to main as
`65d1d22`. See `2026-05-25-audio-capture-microphone-design.md`.

---

## 1. Goal

When a microphone is selected on the recording bar, show a **live level meter
directly under the mic control** that visualizes the real-time intensity of
sound coming from that mic — so the user can confirm the mic works and is
picking up audio *before* recording. The meter is driven by genuine live mic
monitoring (a tap on the selected device), not a placeholder.

### Out of scope
- No meter in the recording **pill** (during recording) — bar only. Possible
  later follow-up.
- No system-audio meter (system audio is a future sub-project).
- No input-gain control / no changing the mic from the meter.

---

## 2. Behavior

### When the monitor runs
A **mic-monitor session** is active exactly when **both**:
- the window is in **bar mode** (`WindowMode.bar`), and
- a microphone is selected (`microphoneControllerProvider != null`).

It **stops** when any of those stops being true:
- mic set to "Don't record microphone" (selection → null),
- a recording starts (window morphs to the **pill**),
- the window opens a **panel** (Recents/Settings/editor).

It **resumes** when the bar returns with a mic still selected.

### Privacy / "mic in use"
Because the mic is genuinely live whenever a device is selected and the bar is
showing, macOS displays its "microphone in use" (orange dot) indicator for that
whole time — not only while recording. This is inherent to a live meter and is
accepted.

### Recording handoff
`AudioCaptureManager` (the recorder) allows only one capture at a time, and the
monitor also taps the mic, so they must not run simultaneously. The monitor is
stopped **before** `startLiveRecording` claims the device:
- Flutter stops the monitor on the bar→pill transition (driven by the same
  `(barMode && micSelected)` logic — pill is not bar mode, so the monitor stops).
- Native defensively stops the monitor at the top of `startLiveRecording` as a
  belt-and-suspenders guard.

No new permission is needed: selecting a device already granted mic access.

---

## 3. Architecture & data flow

```
MicrophoneController (mic selected?) + WindowModeController (bar?)
        │  RecordingBarScreen watches both
        ▼
  start when (bar && micSelected), stop otherwise
        │  WindowChrome-style control via the recording channel:
        │  ScreenRecorderPlatform.startMicMonitor(MicrophoneConfig) / stopMicMonitor()
        ▼
  MicLevelMonitor (native): AVAudioEngine tap on the chosen device
        │  RMS per buffer → dB→0..1 → attack/decay smoothing → throttle ~20 Hz
        ▼
  micLevel EventChannel → MicLevelStreamHandler → Stream<double> (0..1)
        ▼
  MicLevelMeter widget (under the mic chip) paints a fill ∝ level
```

---

## 4. Native (Swift, `screen_recorder_macos`)

### 4.1 New `MicLevelMonitor.swift`
A dedicated, lightweight monitor — separate from `AudioCaptureManager` so the
recording lifecycle stays untangled.
- `start(deviceUid: String?, reduceNoise: Bool, disableAgc: Bool)` — builds its
  own `AVAudioEngine`, selects the device by UID (reuse
  `AudioDeviceCatalog.deviceID(forUID:)`), optionally enables voice processing
  (same as the recorder, for a representative level), installs a tap, starts.
  Mirror the recorder's commit-after-success + catch-teardown pattern.
- In the tap: compute **RMS** over the buffer's float samples
  (`buffer.floatChannelData`), convert to dBFS, map to 0..1
  (`level = clamp((db + 60) / 60, 0, 1)`), apply **attack/decay smoothing**
  (fast attack, slower decay), and **throttle** emissions to ~20 Hz
  (≤ every 50 ms). Emit the smoothed 0..1 value via the level callback.
- `stop()` — remove tap, stop engine, reset state. Idempotent.
- Holds an `onLevel: ((Double) -> Void)?` callback.

### 4.2 Plugin wiring (`ScreenRecorderMacosPlugin.swift`)
- New `micLevel` **FlutterEventChannel** + `MicLevelStreamHandler`
  (`onListen`/`onCancel` storing an `eventSink`), registered alongside the
  existing frames/audio/cursor channels. `MicLevelStreamHandler.send(_ level: Double)`
  forwards to the sink on the main thread.
- Own a `MicLevelMonitor` instance; wire `monitor.onLevel = { [weak self] in
  self?.micLevelStreamHandler?.send($0) }`.
- New method-channel methods:
  - `startMicMonitor` (args: the `microphone` map `{deviceUid, reduceNoise,
    disableAgc}`) → `monitor.start(...)`.
  - `stopMicMonitor` → `monitor.stop()`.
- At the top of `startLiveRecording`, call `monitor.stop()` defensively before
  the recorder captures.
- Channel name + method-name constants added in the platform interface
  `constants.dart` (`ScreenRecorderChannels.micLevel`,
  `ScreenRecorderMethods.startMicMonitor` / `stopMicMonitor`).

### 4.3 Window sizing — generalize `setBarWidth` → `setBarSize` (`MainFlutterWindow.swift`)
The meter makes the bar taller only when a mic is selected. Generalize the
existing width-only auto-size to **width + height**:
- Replace `setBarWidth(_ width:)` with `setBarSize(width:height:)`. Keep the
  same in-place, top-left-anchored resize (preserve the top edge: in Cocoa
  bottom-left coords, set `origin.y = frame.maxY - newHeight` so the top stays
  fixed; keep `origin.x`). Clamp both dims to sane ranges.
- The `"setBarWidth"` method channel case becomes `"setBarSize"` taking
  `{width, height}`. (Rename the Dart `WindowChrome.setBarWidth` →
  `setBarSize(width, height)` accordingly.)
- `applyMode("bar")` initial default becomes a width×height (e.g. 736×68); the
  measured size corrects it on the first frame.

---

## 5. Platform interface (`screen_recorder_platform_interface`)

- `Stream<double> get micLevelStream` — broadcast stream of 0..1 levels
  (default throws `UnimplementedError`, like other streams).
- `Future<void> startMicMonitor(MicrophoneConfig config)` and
  `Future<void> stopMicMonitor()` (default `UnsupportedError`, like
  `pickSource`).
- Constants: `ScreenRecorderChannels.micLevel = 'com.slipreel.screen_recorder/micLevel'`;
  `ScreenRecorderMethods.startMicMonitor = 'startMicMonitor'`,
  `stopMicMonitor = 'stopMicMonitor'`.
- `MethodChannelScreenRecorderMacos`: implement the two methods (invoke channel
  with `config.toJson()` / no args) and `micLevelStream` (map the event channel
  to `(event as num).toDouble()`).

---

## 6. Flutter (`screen_recorder` app)

### 6.1 `MicLevelMeter` widget (`lib/ui/bar/mic_level_meter.dart`)
- Inputs: a `Stream<double> levelStream` and a fixed `width` (the mic chip's
  width). Internally a `StatefulWidget` subscribing to the stream, holding the
  latest 0..1 level.
- Paints a thin rounded **track** (height ≈ 4–5 pt) with a **fill** of
  `width * level`. Color: the bar's light accent (`0xFFE9E9EC`) for normal,
  shifting to **amber** (≳ 0.85) and **red** (≳ 0.97) near clip.
- Optional short decay animation handled natively (the stream is already
  smoothed); the widget just renders the latest value (a brief `AnimatedContainer`
  is acceptable for visual smoothness but not required).

### 6.2 Mic control + bar layout (`recording_bar.dart`)
- The mic control becomes a **Column**: the existing chip row on top, and — when
  a mic is selected — the `MicLevelMeter` (width = chip width) beneath it. When
  off, no meter row (so the column is just the chip and the bar stays short).
- The bar passes the `micLevelStream` (or a builder) down to the mic control.
  Keep `RecordingBar` a pure widget: add a `micLevelStream` parameter
  (nullable; non-null only while monitoring).

### 6.3 Monitor lifecycle + wiring (`recording_bar_screen.dart`)
- Watch `microphoneControllerProvider` and `windowModeControllerProvider`.
  Maintain a derived `shouldMonitor = (mode == bar && mic != null)`.
- On `shouldMonitor` becoming true → `startMicMonitor(mic)`; becoming false →
  `stopMicMonitor()`. Also call `startMicMonitor` again if the selected device
  changes while monitoring (stop+start with the new config).
- Provide the `micLevelStream` to the bar only while monitoring.
- Dispose: stop the monitor.
- The auto-size already re-measures on rebuilds; with the meter row added/removed
  the content height changes → `setBarSize` grows/shrinks the window.

---

## 7. Edge cases
- **Device unplugged mid-monitor:** the monitor's engine errors / goes silent;
  catch and stop, leaving the meter at zero. (Selecting a new device restarts it.)
- **Permission revoked:** monitor start fails → meter stays empty; no crash.
- **Rapid toggles** (mic on/off quickly): start/stop are idempotent; dedupe on
  the `shouldMonitor`/device-id transition so we don't thrash the engine.
- **Recording start while monitoring:** monitor stopped first (both sides) — no
  double mic-in-use, no capture contention.
- **No meter in pill/panel:** monitor stops; meter not shown.

---

## 8. Testing

**Dart / unit + widget**
- `micLevelStream` decode: event channel `double` events → `Stream<double>`.
- `startMicMonitor`/`stopMicMonitor` channel encoding (mock `MethodChannel`).
- `MicLevelMeter`: fill width ∝ level (0 → empty, 1 → full); clip color past the
  amber/red thresholds; updates on new stream values.
- `RecordingBarScreen`: monitor **starts** when (bar + mic selected), **stops**
  on mic→off, on recording (pill), and on panel; restarts on device change
  (fake platform records start/stop calls + last config).
- Bar layout: mic control shows the meter row only when a mic is selected; the
  off state has no meter (height unchanged).
- `setBarSize`: the auto-size test extends to assert a height is requested and
  that selecting a mic (meter appears) requests a taller size.

**Native (manual, flutter-qa + real mic)**
- Select a mic → meter under the chip moves with sound; silence → near zero;
  loud → fill approaches full with amber/red near clip.
- Start recording → meter disappears (pill), mic handed to recorder, recording
  still gets audio; stop → bar returns, meter resumes.
- "Don't record" → meter gone, mic-in-use indicator clears.

---

## 9. File map

**Created**
- `packages/screen_recorder_macos/macos/Classes/MicLevelMonitor.swift`
- `packages/screen_recorder/lib/ui/bar/mic_level_meter.dart`
- tests for the above + the changes below.

**Modified**
- `screen_recorder_platform_interface`: `constants.dart` (channel + methods),
  `screen_recorder_platform_interface.dart` (micLevelStream, startMicMonitor,
  stopMicMonitor), method-channel impl.
- `screen_recorder_macos`: `ScreenRecorderMacosPlugin.swift` (micLevel channel +
  handler, monitor wiring, startMicMonitor/stopMicMonitor, stop-on-record),
  `MainFlutterWindow.swift` (`setBarWidth` → `setBarSize`).
- `screen_recorder`: `recording_bar.dart` (meter row in the mic control,
  `micLevelStream` param), `recording_bar_screen.dart` (monitor lifecycle +
  setBarSize via the generalized auto-size), `window_mode.dart` +
  `window_chrome_channel.dart` (`setBarWidth` → `setBarSize`), and the
  `WindowChrome` test fakes.

---

## 10. Notes / debt carried over
- `RecordingSettings.copyWith(microphone: null)` still can't clear (unused).
- The `setBarWidth → setBarSize` rename touches the auto-size tests added in the
  mic feature; update them in the same task.
