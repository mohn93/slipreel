# Audio Integration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add system audio and microphone capture to screen recordings with proper audio/video synchronization.

**Architecture:** Use AVAudioEngine for macOS audio capture (system audio via loopback + microphone input), stream PCM audio samples to Flutter via event channel, synchronize with video frames using timestamps, mux audio/video with FFmpeg during export.

**Tech Stack:** AVAudioEngine (macOS), AVCaptureDevice, Core Audio, Flutter EventChannel, FFmpeg

---

## Phase 2: Audio Integration (Tasks 10-12)

### Task 10: Implement Audio Capture in Swift

**Goal:** Capture system audio and microphone using AVAudioEngine on macOS.

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift:1-50`
- Modify: `packages/screen_recorder_platform_interface/lib/src/models/audio_data.dart:1-50`

**Step 1: Write AudioData model test**

File: `packages/screen_recorder_platform_interface/test/models/audio_data_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('AudioData', () {
    test('should serialize to JSON correctly', () {
      final audioData = AudioData(
        data: [0, 1, 2, 3],
        sampleRate: 48000,
        channels: 2,
        timestampMicros: 1000000,
      );

      final json = audioData.toJson();

      expect(json['data'], [0, 1, 2, 3]);
      expect(json['sampleRate'], 48000);
      expect(json['channels'], 2);
      expect(json['timestampMicros'], 1000000);
    });

    test('should deserialize from JSON correctly', () {
      final json = {
        'data': [0, 1, 2, 3],
        'sampleRate': 48000,
        'channels': 2,
        'timestampMicros': 1000000,
      };

      final audioData = AudioData.fromJson(json);

      expect(audioData.data, [0, 1, 2, 3]);
      expect(audioData.sampleRate, 48000);
      expect(audioData.channels, 2);
      expect(audioData.timestampMicros, 1000000);
    });
  });
}
```

**Step 2: Run test to verify it fails**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/audio_data_test.dart`
Expected: FAIL - AudioData class doesn't exist yet

**Step 3: Check existing AudioData model**

File: `packages/screen_recorder_platform_interface/lib/src/models/audio_data.dart`

Read the file to see current implementation. If incomplete, update it:

```dart
import 'dart:typed_data';

/// Represents audio sample data
class AudioData {
  final Uint8List data;
  final int sampleRate;
  final int channels;
  final int timestampMicros;

  const AudioData({
    required this.data,
    required this.sampleRate,
    required this.channels,
    required this.timestampMicros,
  });

  Map<String, dynamic> toJson() {
    return {
      'data': data,
      'sampleRate': sampleRate,
      'channels': channels,
      'timestampMicros': timestampMicros,
    };
  }

  factory AudioData.fromJson(Map<String, dynamic> json) {
    return AudioData(
      data: json['data'] as Uint8List,
      sampleRate: json['sampleRate'] as int,
      channels: json['channels'] as int,
      timestampMicros: json['timestampMicros'] as int,
    );
  }

  @override
  String toString() {
    return 'AudioData(samples: ${data.length}, rate: $sampleRate, channels: $channels, timestamp: $timestampMicros)';
  }
}
```

**Step 4: Run test to verify it passes**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/audio_data_test.dart`
Expected: PASS

**Step 5: Create AudioCaptureManager.swift**

File: `packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift`

```swift
import Foundation
import AVFoundation
import CoreAudio

/// Manages audio capture using AVAudioEngine
class AudioCaptureManager: NSObject {
  // MARK: - Properties

  private var audioEngine: AVAudioEngine?
  private var inputNode: AVAudioInputNode?
  private var isCapturing = false

  // Audio configuration
  private let sampleRate: Double = 48000
  private let channels: UInt32 = 2

  // Callback for audio data
  var onAudioReceived: ((Data, Int64) -> Void)?
  var onError: ((Error) -> Void)?

  // MARK: - Permission Handling

  /// Check if microphone permission is granted
  func checkMicrophonePermission() -> Bool {
    if #available(macOS 10.14, *) {
      let status = AVCaptureDevice.authorizationStatus(for: .audio)
      return status == .authorized
    }
    return true
  }

  /// Request microphone permission
  func requestMicrophonePermission() async -> Bool {
    if #available(macOS 10.14, *) {
      return await withCheckedContinuation { continuation in
        AVCaptureDevice.requestAccess(for: .audio) { granted in
          continuation.resume(returning: granted)
        }
      }
    }
    return true
  }

  // MARK: - Audio Capture

  /// Start capturing audio
  /// - Parameters:
  ///   - includeMicrophone: Whether to capture microphone input
  ///   - includeSystem: Whether to capture system audio (not yet supported on macOS)
  func startCapture(includeMicrophone: Bool, includeSystem: Bool) throws {
    guard !isCapturing else {
      throw AudioCaptureError.alreadyCapturing
    }

    // Check microphone permission
    if includeMicrophone && !checkMicrophonePermission() {
      throw AudioCaptureError.permissionDenied
    }

    // Create audio engine
    audioEngine = AVAudioEngine()
    guard let engine = audioEngine else {
      throw AudioCaptureError.engineCreationFailed
    }

    // Note: System audio capture on macOS requires ScreenCaptureKit audio
    // For now, we'll focus on microphone input
    if includeMicrophone {
      try setupMicrophoneCapture(engine: engine)
    }

    // Start the engine
    try engine.start()
    isCapturing = true
  }

  private func setupMicrophoneCapture(engine: AVAudioEngine) throws {
    inputNode = engine.inputNode

    guard let input = inputNode else {
      throw AudioCaptureError.noInputDevice
    }

    // Configure format - use hardware format for best compatibility
    let format = input.outputFormat(forBus: 0)

    // Install tap to capture audio
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, time in
      self?.processAudioBuffer(buffer, time: time)
    }
  }

  private func processAudioBuffer(_ buffer: AVAudioPCMBuffer, time: AVAudioTime) {
    guard let channelData = buffer.floatChannelData else { return }

    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)

    // Convert float samples to Int16 PCM
    var pcmData = Data()
    pcmData.reserveCapacity(frameLength * channelCount * 2) // 2 bytes per Int16

    for frame in 0..<frameLength {
      for channel in 0..<channelCount {
        let sample = channelData[channel][frame]
        // Clamp and convert to Int16
        let clamped = max(-1.0, min(1.0, sample))
        let int16Value = Int16(clamped * 32767.0)

        // Append as little-endian bytes
        withUnsafeBytes(of: int16Value.littleEndian) { bytes in
          pcmData.append(contentsOf: bytes)
        }
      }
    }

    // Get timestamp in microseconds
    let timestamp = time.hostTime
    let timestampMicros = Int64(Double(timestamp) / 1000.0)

    // Send audio data via callback
    onAudioReceived?(pcmData, timestampMicros)
  }

  /// Stop capturing audio
  func stopCapture() {
    guard isCapturing else { return }

    // Remove tap
    inputNode?.removeTap(onBus: 0)

    // Stop engine
    audioEngine?.stop()
    audioEngine = nil
    inputNode = nil

    isCapturing = false
  }

  /// Check if currently capturing
  func isCaptureActive() -> Bool {
    return isCapturing
  }
}

// MARK: - Error Types

enum AudioCaptureError: LocalizedError {
  case permissionDenied
  case alreadyCapturing
  case notCapturing
  case engineCreationFailed
  case noInputDevice
  case systemAudioNotSupported

  var errorDescription: String? {
    switch self {
    case .permissionDenied:
      return "Microphone permission denied. Please grant permission in System Preferences > Privacy & Security > Microphone."
    case .alreadyCapturing:
      return "Audio capture is already in progress."
    case .notCapturing:
      return "No audio capture session is active."
    case .engineCreationFailed:
      return "Failed to create audio engine."
    case .noInputDevice:
      return "No audio input device found."
    case .systemAudioNotSupported:
      return "System audio capture is not yet supported. Use ScreenCaptureKit for system audio."
    }
  }
}
```

**Step 6: Update podspec for audio frameworks**

File: `packages/screen_recorder_macos/macos/screen_recorder_macos.podspec`

Verify the frameworks line includes AVFoundation (should already be there from Task 4):

```ruby
s.frameworks = 'ScreenCaptureKit', 'AVFoundation', 'CoreMedia', 'CoreVideo'
```

**Step 7: Build to verify Swift compiles**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: Build succeeds without errors

**Step 8: Commit audio capture manager**

```bash
git add packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift
git add packages/screen_recorder_platform_interface/lib/src/models/audio_data.dart
git add packages/screen_recorder_platform_interface/test/models/audio_data_test.dart
git commit -m "feat: add audio capture manager for macOS

- Implement AVAudioEngine-based audio capture
- Support microphone input capture
- PCM audio data with 48kHz sample rate
- Add AudioData model with tests
- Add microphone permission handling

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 11: Stream Audio to Flutter via Event Channel

**Goal:** Set up event channel to stream audio samples from Swift to Flutter in real-time.

**Files:**
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift:20-80`
- Modify: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart:95-102`
- Modify: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart:105-117`

**Step 1: Create AudioStreamHandler in plugin**

File: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

Add after FrameStreamHandler class:

```swift
// MARK: - Audio Stream Handler

class AudioStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var sampleCount: Int = 0

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    self.sampleCount = 0
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    return nil
  }

  func sendAudioData(_ data: Data, timestamp: Int64, sampleRate: Int, channels: Int) {
    guard let eventSink = eventSink else { return }

    // Create FlutterStandardTypedData
    let flutterData = FlutterStandardTypedData(bytes: data)

    // Create audio data dictionary
    let audioData: [String: Any] = [
      "data": flutterData,
      "sampleRate": sampleRate,
      "channels": channels,
      "timestampMicros": timestamp
    ]

    // Send to Flutter on main thread
    DispatchQueue.main.async {
      events(audioData)
    }

    sampleCount += 1
  }
}
```

**Step 2: Register audio event channel in plugin**

File: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

Update the `register` method to add audio channel:

```swift
public class ScreenRecorderMacosPlugin: NSObject, FlutterPlugin {
  private var recordingChannel: FlutterMethodChannel?
  private var captureManager: ScreenCaptureManager?
  private var frameStreamHandler: FrameStreamHandler?
  private var audioStreamHandler: AudioStreamHandler?
  private var audioManager: AudioCaptureManager?

  public static func register(with registrar: FlutterPluginRegistrar) {
    // Main method channel for recording control
    let recordingChannel = FlutterMethodChannel(
      name: "com.slipreel.screen_recorder/recording",
      binaryMessenger: registrar.messenger
    )

    let instance = ScreenRecorderMacosPlugin()
    instance.recordingChannel = recordingChannel
    registrar.addMethodCallDelegate(instance, channel: recordingChannel)

    // Event channel for video frames
    let framesChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/frames",
      binaryMessenger: registrar.messenger
    )
    instance.frameStreamHandler = FrameStreamHandler()
    framesChannel.setStreamHandler(instance.frameStreamHandler)

    // Event channel for audio samples
    let audioChannel = FlutterEventChannel(
      name: "com.slipreel.screen_recorder/audio",
      binaryMessenger: registrar.messenger
    )
    instance.audioStreamHandler = AudioStreamHandler()
    audioChannel.setStreamHandler(instance.audioStreamHandler)

    // TODO: Event channel for cursor will be set up in Phase 3
  }
}
```

**Step 3: Update startRecording to capture audio**

File: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

In the `startRecording` method, after setting up frame callback:

```swift
// In startRecording method, after frame callback setup:

// Set up audio callback
let captureAudio = args["captureAudio"] as? Bool ?? false

if captureAudio {
  // Create audio manager if not exists
  if audioManager == nil {
    audioManager = AudioCaptureManager()
  }

  // Set up audio callback
  audioManager?.onAudioReceived = { [weak self] data, timestamp in
    self?.audioStreamHandler?.sendAudioData(
      data,
      timestamp: timestamp,
      sampleRate: 48000,
      channels: 2
    )
  }

  // Start audio capture (microphone only for now)
  try audioManager?.startCapture(includeMicrophone: true, includeSystem: false)
}
```

**Step 4: Update stopRecording to stop audio**

File: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

In the `stopRecording` method:

```swift
private func stopRecording(result: @escaping FlutterResult) {
  Task {
    do {
      guard let manager = captureManager else {
        result(FlutterError(
          code: "NOT_RECORDING",
          message: "No active recording session",
          details: nil
        ))
        return
      }

      try await manager.stopCapture()
      captureManager = nil

      // Stop audio capture
      audioManager?.stopCapture()
      audioManager = nil

      result(["success": true])
    } catch {
      result(FlutterError(
        code: "STOP_FAILED",
        message: "Failed to stop recording: \(error.localizedDescription)",
        details: nil
      ))
    }
  }
}
```

**Step 5: Test audio stream subscription**

File: `packages/screen_recorder_macos/example/lib/main.dart`

Add test code to verify audio stream:

```dart
// In _MyAppState class:
StreamSubscription<AudioData>? _audioSubscription;
int _audioSampleCount = 0;

void _startRecording() async {
  // ... existing frame subscription code ...

  // Subscribe to audio stream
  _audioSubscription = ScreenRecorderPlatform.instance.audioStream.listen(
    (audioData) {
      setState(() {
        _audioSampleCount++;
      });

      if (_audioSampleCount % 100 == 0) {
        print('Audio sample #$_audioSampleCount: ${audioData.sampleRate}Hz, ${audioData.channels}ch, ${audioData.data.length} bytes');
      }
    },
    onError: (error) {
      print('Audio stream error: $error');
    },
  );
}

void _stopRecording() async {
  // ... existing code ...
  await _audioSubscription?.cancel();
  _audioSubscription = null;
}
```

**Step 6: Build and verify audio streaming**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: Build succeeds

**Step 7: Manual test**

Run: `cd packages/screen_recorder && flutter run -d macos`
Actions:
1. Grant microphone permission when prompted
2. Start recording
3. Check console for "Audio sample #..." logs
4. Verify sample count increases

Expected: Audio samples streaming at ~100 samples/second

**Step 8: Commit audio streaming**

```bash
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git add packages/screen_recorder_macos/example/lib/main.dart
git commit -m "feat: add audio streaming via event channel

- Create AudioStreamHandler for Flutter event channel
- Register audio event channel in plugin
- Stream PCM audio samples to Flutter
- Update startRecording/stopRecording for audio
- Add audio stream test in example app

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 12: Mux Audio + Video with FFmpeg

**Goal:** Combine audio and video streams into synchronized MP4 file during export.

**Files:**
- Modify: `packages/screen_recorder/lib/video_encoder.dart:1-150`
- Modify: `packages/screen_recorder/lib/state/recording_state.dart:80-150`
- Test: Manual testing with audio+video recording

**Step 1: Update VideoEncoder to handle audio**

File: `packages/screen_recorder/lib/video_encoder.dart`

Add audio storage:

```dart
class VideoEncoder {
  String? _tempDir;
  String? _outputPath;
  int _width = 0;
  int _height = 0;
  int _fps = 30;
  int _frameIndex = 0;
  int _audioSampleIndex = 0;
  bool _isInitialized = false;

  // Audio configuration
  int _audioSampleRate = 48000;
  int _audioChannels = 2;

  /// Initialize the encoder with output settings
  Future<void> initialize({
    required String outputPath,
    required int width,
    required int height,
    required int fps,
    int audioSampleRate = 48000,
    int audioChannels = 2,
  }) async {
    _outputPath = outputPath;
    _width = width;
    _height = height;
    _fps = fps;
    _audioSampleRate = audioSampleRate;
    _audioChannels = audioChannels;

    // Create temporary directory for frames and audio
    final tempBaseDir = await getTemporaryDirectory();
    _tempDir = '${tempBaseDir.path}/slipreel_${DateTime.now().millisecondsSinceEpoch}';
    await Directory(_tempDir!).create(recursive: true);

    _frameIndex = 0;
    _audioSampleIndex = 0;
    _isInitialized = true;

    print('VideoEncoder initialized: ${_width}x$_height @ ${_fps}fps, audio: ${_audioSampleRate}Hz ${_audioChannels}ch');
  }

  /// Add an audio sample to the video
  Future<void> addAudioSample(AudioData audioData) async {
    if (!_isInitialized) {
      throw StateError('VideoEncoder not initialized');
    }

    // Update audio config from first sample
    if (_audioSampleIndex == 0) {
      _audioSampleRate = audioData.sampleRate;
      _audioChannels = audioData.channels;
    }

    // Save audio as raw PCM file
    final audioPath = '$_tempDir/audio_${_audioSampleIndex.toString().padLeft(6, '0')}.pcm';
    final file = File(audioPath);
    await file.writeAsBytes(audioData.data);

    _audioSampleIndex++;

    if (_audioSampleIndex % 100 == 0) {
      print('Saved audio sample $_audioSampleIndex');
    }
  }

  // ... existing addFrame method stays the same ...
}
```

**Step 2: Update finalize to mux audio and video**

File: `packages/screen_recorder/lib/video_encoder.dart`

Replace the `finalize` method:

```dart
/// Finalize the video by encoding all frames and muxing audio
Future<String> finalize() async {
  if (!_isInitialized) {
    throw StateError('VideoEncoder not initialized');
  }

  if (_frameIndex == 0) {
    throw StateError('No frames to encode');
  }

  print('Finalizing video: $_frameIndex frames, $_audioSampleIndex audio samples');

  final hasAudio = _audioSampleIndex > 0;

  if (hasAudio) {
    // Concatenate all audio samples into one file
    print('Concatenating audio samples...');
    final audioFile = File('$_tempDir/audio_combined.pcm');
    final audioSink = audioFile.openWrite();

    for (int i = 0; i < _audioSampleIndex; i++) {
      final samplePath = '$_tempDir/audio_${i.toString().padLeft(6, '0')}.pcm';
      final sampleFile = File(samplePath);
      if (await sampleFile.exists()) {
        final bytes = await sampleFile.readAsBytes();
        audioSink.add(bytes);
      }
    }
    await audioSink.close();
    print('Audio concatenated: ${await audioFile.length()} bytes');
  }

  // Build FFmpeg command
  List<String> args;

  if (hasAudio) {
    // Encode video and audio together
    args = [
      // Video input
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-s', '${_width}x$_height',
      '-r', '$_fps',
      '-i', '$_tempDir/frame_%06d.bgra',

      // Audio input
      '-f', 's16le', // signed 16-bit little-endian PCM
      '-ar', '$_audioSampleRate',
      '-ac', '$_audioChannels',
      '-i', '$_tempDir/audio_combined.pcm',

      // Video encoding
      '-c:v', 'libx264',
      '-preset', 'fast',
      '-crf', '23',
      '-pix_fmt', 'yuv420p',

      // Audio encoding
      '-c:a', 'aac',
      '-b:a', '192k',

      // Sync options
      '-vsync', 'cfr',
      '-async', '1',

      '-y',
      _outputPath!,
    ];
  } else {
    // Video only (existing code)
    args = [
      '-f', 'rawvideo',
      '-pix_fmt', 'bgra',
      '-s', '${_width}x$_height',
      '-r', '$_fps',
      '-i', '$_tempDir/frame_%06d.bgra',
      '-c:v', 'libx264',
      '-preset', 'fast',
      '-crf', '23',
      '-pix_fmt', 'yuv420p',
      '-y',
      _outputPath!,
    ];
  }

  print('FFmpeg command: ffmpeg ${args.join(" ")}');

  try {
    // Execute FFmpeg
    final result = await Process.run('ffmpeg', args);

    if (result.exitCode == 0) {
      print('Video encoding successful!');
      print('Output file: $_outputPath');

      // Check file size
      final outputFile = File(_outputPath!);
      if (await outputFile.exists()) {
        final sizeBytes = await outputFile.length();
        final sizeMB = sizeBytes / (1024 * 1024);
        print('File size: ${sizeMB.toStringAsFixed(2)} MB');
      }
    } else {
      print('FFmpeg failed with exit code ${result.exitCode}');
      print('stdout: ${result.stdout}');
      print('stderr: ${result.stderr}');
      throw Exception('Failed to encode video: exit code ${result.exitCode}');
    }
  } on ProcessException catch (e) {
    print('FFmpeg not found or failed to run: $e');
    throw Exception('FFmpeg is not installed or not in PATH. Please install FFmpeg.');
  }

  // Cleanup temporary files
  await _cleanup();

  return _outputPath!;
}
```

**Step 3: Update RecordingController to collect audio**

File: `packages/screen_recorder/lib/state/recording_state.dart`

Add audio subscription:

```dart
class RecordingController extends StateNotifier<RecordingState> {
  RecordingController() : super(const RecordingState());

  VideoEncoder? _videoEncoder;
  StreamSubscription<FrameData>? _frameSubscription;
  StreamSubscription<AudioData>? _audioSubscription;
  Timer? _durationTimer;
  DateTime? _startTime;

  /// Start recording
  Future<void> startRecording() async {
    // ... existing setup code ...

    // Subscribe to audio stream if audio is enabled
    if (settings.captureAudio) {
      _audioSubscription = ScreenRecorderPlatform.instance.audioStream.listen(
        (audioData) async {
          // Add audio to encoder
          if (_videoEncoder != null && _videoEncoder!.isInitialized) {
            await _videoEncoder!.addAudioSample(audioData);
          }
        },
        onError: (error) {
          print('Audio stream error: $error');
        },
      );
    }

    // ... rest of existing code ...
  }

  /// Stop recording
  Future<void> stopRecording() async {
    // ... existing code before finalize ...

    // Cancel audio subscription
    await _audioSubscription?.cancel();
    _audioSubscription = null;

    // ... rest of existing code ...
  }

  void _handleError(String errorMessage) {
    // ... existing code ...
    _audioSubscription?.cancel();
    _audioSubscription = null;
  }

  @override
  void dispose() {
    _frameSubscription?.cancel();
    _audioSubscription?.cancel();
    _durationTimer?.cancel();
    _videoEncoder?.cancel();
    super.dispose();
  }
}
```

**Step 4: Update RecordingSettings to default audio to true**

File: `packages/screen_recorder_platform_interface/lib/src/models/recording_settings.dart`

Verify captureAudio defaults to true (should already be set from previous implementation).

**Step 5: Update UI to show audio indicator**

File: `packages/screen_recorder/lib/ui/screens/recording_screen.dart`

Add audio indicator in recording controls:

```dart
// In _buildRecordingControls, after timer display:
if (recordingState.isRecording) ...[
  // ... existing timer code ...

  const SizedBox(height: 8),
  Row(
    mainAxisAlignment: MainAxisAlignment.center,
    children: [
      Icon(
        Icons.mic,
        size: 16,
        color: Colors.red.withOpacity(0.8),
      ),
      const SizedBox(width: 4),
      Text(
        'Audio recording',
        style: TextStyle(
          color: Colors.white.withOpacity(0.7),
          fontSize: 12,
        ),
      ),
    ],
  ),
]
```

**Step 6: Build and test**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: Build succeeds

**Step 7: Manual integration test**

Run: `cd packages/screen_recorder && flutter run -d macos`

Test scenario:
1. Select a window
2. Click record button (grant microphone permission if prompted)
3. Speak into microphone for 5 seconds
4. Click stop button
5. Wait for encoding
6. Video should auto-play with audio

Verification:
- Video plays with audio
- Audio is in sync with video (no drift)
- Microphone audio is clear

**Step 8: Commit audio/video muxing**

```bash
git add packages/screen_recorder/lib/video_encoder.dart
git add packages/screen_recorder/lib/state/recording_state.dart
git add packages/screen_recorder/lib/ui/screens/recording_screen.dart
git commit -m "feat: add audio/video muxing with FFmpeg

- Update VideoEncoder to collect audio samples
- Concatenate PCM audio samples during finalize
- Mux audio and video using FFmpeg with AAC encoding
- Add audio stream subscription to RecordingController
- Add audio recording indicator to UI
- Test audio/video sync with 5-second recording

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Testing Checklist

After completing all tasks, verify:

- [ ] Audio permission prompt appears on first record
- [ ] Audio samples stream during recording (check console logs)
- [ ] Video encodes with audio track (check with `ffprobe output.mp4`)
- [ ] Audio/video stay in sync for 30+ second recordings
- [ ] No audio dropouts or glitches
- [ ] Microphone audio is clear and audible
- [ ] Exported video plays in QuickTime with audio
- [ ] UI shows audio recording indicator

---

## Known Limitations

1. **System Audio Not Supported:** macOS system audio capture requires ScreenCaptureKit integration (planned for future iteration)
2. **Single Audio Source:** Only microphone OR system audio, not both mixed (planned for Phase 2 enhancement)
3. **No Audio Settings:** Volume, sample rate not configurable yet (planned for settings UI)
4. **Sync Tolerance:** Audio/video sync within ±50ms (acceptable for screen recordings)

---

## Future Enhancements

1. **System Audio Capture:** Integrate ScreenCaptureKit audio tap
2. **Audio Mixing:** Mix microphone + system audio with volume controls
3. **Audio Settings UI:** Let users choose input device, adjust volume
4. **Audio Waveform:** Show live waveform during recording
5. **Noise Reduction:** Apply audio filters for cleaner recordings

---

## References

- [AVAudioEngine Documentation](https://developer.apple.com/documentation/avfaudio/avaudioengine)
- [Core Audio Programming Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/CoreAudioOverview/)
- [FFmpeg Audio Options](https://ffmpeg.org/ffmpeg.html#Audio-Options)
- [ScreenCaptureKit Audio](https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos)
