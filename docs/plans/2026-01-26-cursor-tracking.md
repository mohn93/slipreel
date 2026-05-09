# Cursor Tracking Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Track and render cursor movements with click detection in screen recordings.

**Architecture:** Native cursor tracking using NSEvent on macOS streams position data to Flutter via event channel. Cursor rendering happens during video finalization by drawing cursor overlay on each frame based on timestamp synchronization.

**Tech Stack:** NSEvent (macOS cursor tracking), Core Graphics (cursor images), Flutter Event Channels, Dart image manipulation

---

## Phase 3: Cursor Tracking (Tasks 13-15)

### Task 13: Native Cursor Tracking

**Goal:** Capture cursor position and click events at high frequency and stream to Flutter.

**Files:**
- Create: `packages/screen_recorder_macos/macos/Classes/CursorTracker.swift`
- Modify: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift:39-40`
- Create: `packages/screen_recorder_platform_interface/test/models/cursor_position_test.dart`

**Step 1: Write CursorPosition model test**

File: `packages/screen_recorder_platform_interface/test/models/cursor_position_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('CursorPosition', () {
    test('should serialize to JSON correctly', () {
      final cursor = CursorPosition(
        x: 100.5,
        y: 200.75,
        timestampMicros: 1000000,
        isClicked: true,
      );

      final json = cursor.toJson();

      expect(json['x'], 100.5);
      expect(json['y'], 200.75);
      expect(json['timestampMicros'], 1000000);
      expect(json['isClicked'], true);
    });

    test('should deserialize from JSON correctly', () {
      final json = {
        'x': 150.25,
        'y': 250.5,
        'timestampMicros': 2000000,
        'isClicked': false,
      };

      final cursor = CursorPosition.fromJson(json);

      expect(cursor.x, 150.25);
      expect(cursor.y, 250.5);
      expect(cursor.timestampMicros, 2000000);
      expect(cursor.isClicked, false);
    });

    test('should default isClicked to false', () {
      final json = {
        'x': 50.0,
        'y': 75.0,
        'timestampMicros': 500000,
      };

      final cursor = CursorPosition.fromJson(json);

      expect(cursor.isClicked, false);
    });
  });
}
```

**Step 2: Run test to verify CursorPosition model**

Run: `cd packages/screen_recorder_platform_interface && flutter test test/models/cursor_position_test.dart`
Expected: PASS (model already exists)

**Step 3: Create CursorTracker.swift**

File: `packages/screen_recorder_macos/macos/Classes/CursorTracker.swift`

```swift
import Cocoa
import Foundation

/// Tracks cursor position and click events at high frequency
class CursorTracker: NSObject {
  // MARK: - Properties

  private var positionTimer: Timer?
  private var globalMonitor: Any?
  private var localMonitor: Any?
  private var isTracking = false
  private var lastMouseLocation: NSPoint = .zero
  private var isMouseDown = false

  // Callback for cursor data
  var onCursorUpdate: ((Double, Double, Int64, Bool) -> Void)?
  var onError: ((Error) -> Void)?

  // MARK: - Tracking Control

  /// Start tracking cursor position and clicks
  /// - Parameter frequency: Updates per second (default: 60)
  func startTracking(frequency: Int = 60) throws {
    guard !isTracking else {
      throw CursorTrackerError.alreadyTracking
    }

    // Set up position sampling timer
    let interval = 1.0 / Double(frequency)
    positionTimer = Timer.scheduledTimer(
      withTimeInterval: interval,
      repeats: true
    ) { [weak self] _ in
      self?.captureCurrentPosition()
    }

    // Set up global event monitor for clicks (when app is not focused)
    globalMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    ) { [weak self] event in
      self?.handleMouseEvent(event)
    }

    // Set up local event monitor for clicks (when app is focused)
    localMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp]
    ) { [weak self] event in
      self?.handleMouseEvent(event)
      return event
    }

    isTracking = true
  }

  /// Stop tracking cursor
  func stopTracking() {
    guard isTracking else { return }

    // Stop timer
    positionTimer?.invalidate()
    positionTimer = nil

    // Remove event monitors
    if let monitor = globalMonitor {
      NSEvent.removeMonitor(monitor)
      globalMonitor = nil
    }

    if let monitor = localMonitor {
      NSEvent.removeMonitor(monitor)
      localMonitor = nil
    }

    isTracking = false
    isMouseDown = false
  }

  // MARK: - Private Methods

  private func captureCurrentPosition() {
    // Get current mouse location in screen coordinates
    let location = NSEvent.mouseLocation
    lastMouseLocation = location

    // Get timestamp in microseconds
    let timestamp = getTimestampMicros()

    // Send cursor data via callback
    onCursorUpdate?(location.x, location.y, timestamp, isMouseDown)
  }

  private func handleMouseEvent(_ event: NSEvent) {
    switch event.type {
    case .leftMouseDown, .rightMouseDown:
      isMouseDown = true
      // Immediately capture position with click state
      captureCurrentPosition()

    case .leftMouseUp, .rightMouseUp:
      isMouseDown = false
      // Immediately capture position with released state
      captureCurrentPosition()

    default:
      break
    }
  }

  private func getTimestampMicros() -> Int64 {
    var timebaseInfo = mach_timebase_info()
    mach_timebase_info(&timebaseInfo)
    let timestamp = mach_absolute_time()
    let nanoseconds = timestamp * UInt64(timebaseInfo.numer) / UInt64(timebaseInfo.denom)
    return Int64(nanoseconds / 1000)
  }

  /// Check if currently tracking
  func isCurrentlyTracking() -> Bool {
    return isTracking
  }
}

// MARK: - Error Types

enum CursorTrackerError: LocalizedError {
  case alreadyTracking
  case notTracking
  case permissionDenied

  var errorDescription: String? {
    switch self {
    case .alreadyTracking:
      return "Cursor tracking is already in progress."
    case .notTracking:
      return "No cursor tracking session is active."
    case .permissionDenied:
      return "Accessibility permission denied. Please grant permission in System Preferences > Privacy & Security > Accessibility."
    }
  }
}
```

**Step 4: Build to verify Swift compiles**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: Build succeeds

**Step 5: Register cursor event channel in plugin**

File: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

Add property after line 10:
```swift
private var cursorStreamHandler: CursorStreamHandler?
private var cursorTracker: CursorTracker?
```

Replace TODO comment (line 39) with cursor channel registration:
```swift
// Event channel for cursor tracking
let cursorChannel = FlutterEventChannel(
  name: "com.slipreel.screen_recorder/cursor",
  binaryMessenger: registrar.messenger
)
instance.cursorStreamHandler = CursorStreamHandler()
cursorChannel.setStreamHandler(instance.cursorStreamHandler)
```

**Step 6: Create CursorStreamHandler**

File: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

Add after AudioStreamHandler class:
```swift
// MARK: - Cursor Stream Handler

class CursorStreamHandler: NSObject, FlutterStreamHandler {
  private var eventSink: FlutterEventSink?
  private var isListening = false
  private var sampleCount: Int = 0

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    self.eventSink = events
    self.isListening = true
    self.sampleCount = 0
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    self.eventSink = nil
    self.isListening = false
    return nil
  }

  func sendCursorPosition(x: Double, y: Double, timestamp: Int64, isClicked: Bool) {
    guard isListening, let eventSink = eventSink else { return }

    // Validate data
    guard x.isFinite, y.isFinite, timestamp >= 0 else {
      print("[CursorStreamHandler] Invalid cursor data: x=\(x), y=\(y), timestamp=\(timestamp)")
      return
    }

    let cursorData: [String: Any] = [
      "x": x,
      "y": y,
      "timestampMicros": timestamp,
      "isClicked": isClicked
    ]

    DispatchQueue.main.async {
      eventSink(cursorData)
    }

    sampleCount += 1
  }
}
```

**Step 7: Integrate cursor tracking with recording lifecycle**

File: `packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift`

In `startRecording` method, after audio setup add:
```swift
// Start cursor tracking if enabled
let captureCursor = args["captureCursor"] as? Bool ?? true

if captureCursor {
  if cursorTracker == nil {
    cursorTracker = CursorTracker()
  }

  // Set up cursor callback
  cursorTracker?.onCursorUpdate = { [weak self] x, y, timestamp, isClicked in
    guard let self = self else { return }
    guard let handler = self.cursorStreamHandler else {
      print("[Plugin] Warning: Cursor data but no stream handler")
      return
    }

    handler.sendCursorPosition(x: x, y: y, timestamp: timestamp, isClicked: isClicked)
  }

  cursorTracker?.onError = { error in
    print("[Plugin] Cursor tracking error: \(error)")
  }

  // Start tracking at 60 Hz
  try cursorTracker?.startTracking(frequency: 60)
}
```

In `stopRecording` method, add cursor cleanup:
```swift
// Stop cursor tracking if active
if let tracker = cursorTracker {
  tracker.onCursorUpdate = nil
  tracker.onError = nil

  if tracker.isCurrentlyTracking() {
    tracker.stopTracking()
  }

  cursorTracker = nil
}
```

**Step 8: Add cursor stream to platform interface**

File: `packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart`

Add after audioStream:
```dart
/// Stream of cursor position events during recording
Stream<CursorPosition> get cursorStream {
  throw UnimplementedError('cursorStream has not been implemented.');
}
```

File: `packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart`

Add event channel constant:
```dart
static const EventChannel _cursorChannel = EventChannel(
  'com.slipreel.screen_recorder/cursor',
);
```

Implement cursorStream:
```dart
@override
Stream<CursorPosition> get cursorStream {
  return _cursorChannel.receiveBroadcastStream().map((event) {
    try {
      final map = event as Map;
      return CursorPosition.fromJson(Map<String, dynamic>.from(map));
    } catch (e) {
      throw Exception('Failed to parse cursor data: $e');
    }
  }).handleError((error) {
    print('[ScreenRecorder] Cursor stream error: $error');
    throw error;
  });
}
```

**Step 9: Build and verify cursor streaming**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: Build succeeds

**Step 10: Test cursor tracking in example app**

File: `packages/screen_recorder_macos/example/lib/main.dart`

Add cursor subscription:
```dart
StreamSubscription<CursorPosition>? _cursorSubscription;
int _cursorSampleCount = 0;
CursorPosition? _lastCursorPosition;

// In _startRecording:
_cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
  (cursorData) {
    setState(() {
      _cursorSampleCount++;
      _lastCursorPosition = cursorData;
    });

    if (_cursorSampleCount % 60 == 0) {
      print('Cursor sample #$_cursorSampleCount: ${cursorData.x}, ${cursorData.y}, clicked: ${cursorData.isClicked}');
    }
  },
  onError: (error) {
    print('Cursor stream error: $error');
  },
);

// In _stopRecording:
await _cursorSubscription?.cancel();
_cursorSubscription = null;
```

**Step 11: Manual test**

Run: `cd packages/screen_recorder && flutter run -d macos`

Actions:
1. Start recording
2. Move mouse around the screen
3. Click a few times
4. Check console for cursor sample logs
5. Stop recording

Expected: Console shows cursor positions at ~60 samples/second, clicks detected

**Step 12: Commit cursor tracking**

```bash
git add packages/screen_recorder_macos/macos/Classes/CursorTracker.swift
git add packages/screen_recorder_macos/macos/Classes/ScreenRecorderMacosPlugin.swift
git add packages/screen_recorder_platform_interface/test/models/cursor_position_test.dart
git add packages/screen_recorder_platform_interface/lib/src/screen_recorder_platform_interface.dart
git add packages/screen_recorder_macos/lib/screen_recorder_macos_method_channel.dart
git add packages/screen_recorder_macos/example/lib/main.dart
git commit -m "feat: add native cursor tracking

- Implement CursorTracker with NSEvent monitoring
- Track position at 60 Hz using Timer
- Detect mouse clicks via event monitors
- Stream cursor data via event channel
- Add cursor stream to platform interface
- Test cursor tracking in example app

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 14: Store Cursor Data During Recording

**Goal:** Collect cursor positions during recording and save them for video rendering.

**Files:**
- Create: `packages/screen_recorder/lib/models/cursor_recording.dart`
- Modify: `packages/screen_recorder/lib/state/recording_state.dart:128-150`
- Modify: `packages/screen_recorder/lib/video_encoder.dart:1-50`

**Step 1: Create CursorRecording model**

File: `packages/screen_recorder/lib/models/cursor_recording.dart`

```dart
import 'dart:io';
import 'dart:convert';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// Stores cursor position data for a recording session
class CursorRecording {
  final List<CursorPosition> positions = [];

  /// Add a cursor position to the recording
  void addPosition(CursorPosition position) {
    positions.add(position);
  }

  /// Get cursor position at specific timestamp (interpolated if needed)
  CursorPosition? getPositionAt(int timestampMicros) {
    if (positions.isEmpty) return null;

    // Find two positions surrounding the timestamp
    CursorPosition? before;
    CursorPosition? after;

    for (final pos in positions) {
      if (pos.timestampMicros <= timestampMicros) {
        if (before == null || pos.timestampMicros > before.timestampMicros) {
          before = pos;
        }
      }
      if (pos.timestampMicros >= timestampMicros) {
        if (after == null || pos.timestampMicros < after.timestampMicros) {
          after = pos;
        }
      }
    }

    // If exact match, return it
    if (before != null && before.timestampMicros == timestampMicros) {
      return before;
    }

    // If only one side, return that
    if (before == null) return after;
    if (after == null) return before;

    // Interpolate between before and after
    final t = (timestampMicros - before.timestampMicros) /
              (after.timestampMicros - before.timestampMicros);

    return CursorPosition(
      x: before.x + (after.x - before.x) * t,
      y: before.y + (after.y - before.y) * t,
      timestampMicros: timestampMicros,
      isClicked: before.isClicked || after.isClicked,
    );
  }

  /// Save cursor data to file
  Future<void> saveToFile(String filePath) async {
    final file = File(filePath);
    final jsonData = positions.map((p) => p.toJson()).toList();
    await file.writeAsString(jsonEncode(jsonData));
  }

  /// Load cursor data from file
  static Future<CursorRecording> loadFromFile(String filePath) async {
    final file = File(filePath);
    final content = await file.readAsString();
    final jsonData = jsonDecode(content) as List;

    final recording = CursorRecording();
    for (final item in jsonData) {
      recording.addPosition(CursorPosition.fromJson(item as Map<String, dynamic>));
    }

    return recording;
  }

  /// Get total number of positions
  int get count => positions.length;

  /// Clear all positions
  void clear() {
    positions.clear();
  }
}
```

**Step 2: Test CursorRecording model**

File: `packages/screen_recorder/test/models/cursor_recording_test.dart`

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/cursor_recording.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

void main() {
  group('CursorRecording', () {
    test('should store and retrieve cursor positions', () {
      final recording = CursorRecording();

      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 0));
      recording.addPosition(CursorPosition(x: 100, y: 100, timestampMicros: 1000));

      expect(recording.count, 2);
    });

    test('should interpolate position between two points', () {
      final recording = CursorRecording();

      recording.addPosition(CursorPosition(x: 0, y: 0, timestampMicros: 0));
      recording.addPosition(CursorPosition(x: 100, y: 100, timestampMicros: 1000));

      final pos = recording.getPositionAt(500);

      expect(pos, isNotNull);
      expect(pos!.x, closeTo(50, 0.1));
      expect(pos.y, closeTo(50, 0.1));
    });

    test('should return null for empty recording', () {
      final recording = CursorRecording();

      final pos = recording.getPositionAt(500);

      expect(pos, isNull);
    });

    test('should save and load from file', () async {
      final recording = CursorRecording();
      recording.addPosition(CursorPosition(x: 10, y: 20, timestampMicros: 100));
      recording.addPosition(CursorPosition(x: 30, y: 40, timestampMicros: 200));

      final tempFile = File('test_cursor.json');
      await recording.saveToFile(tempFile.path);

      final loaded = await CursorRecording.loadFromFile(tempFile.path);

      expect(loaded.count, 2);
      expect(loaded.positions[0].x, 10);
      expect(loaded.positions[1].y, 40);

      await tempFile.delete();
    });
  });
}
```

Run: `cd packages/screen_recorder && flutter test test/models/cursor_recording_test.dart`
Expected: PASS

**Step 3: Add cursor subscription to RecordingController**

File: `packages/screen_recorder/lib/state/recording_state.dart`

Add import:
```dart
import '../models/cursor_recording.dart';
```

Add property:
```dart
StreamSubscription<CursorPosition>? _cursorSubscription;
CursorRecording? _cursorRecording;
```

In `startRecording`, after audio subscription:
```dart
// Subscribe to cursor stream if cursor capture enabled
if (settings.captureCursor) {
  _cursorRecording = CursorRecording();

  _cursorSubscription = ScreenRecorderPlatform.instance.cursorStream.listen(
    (cursorData) {
      _cursorRecording?.addPosition(cursorData);
    },
    onError: (error) {
      print('Cursor stream error: $error');
    },
  );
}
```

In `stopRecording`, before finalize:
```dart
// Cancel cursor subscription and save data
await _cursorSubscription?.cancel();
_cursorSubscription = null;

// Save cursor data if captured
if (_cursorRecording != null && _cursorRecording!.count > 0) {
  final docsDir = await getApplicationDocumentsDirectory();
  final cursorPath = '${docsDir.path}/cursor_${DateTime.now().millisecondsSinceEpoch}.json';
  await _cursorRecording!.saveToFile(cursorPath);
  print('Cursor data saved: ${_cursorRecording!.count} positions');

  // TODO: Pass cursor data to video encoder for rendering
}
```

In `_handleError`:
```dart
_cursorSubscription?.cancel();
_cursorSubscription = null;
_cursorRecording = null;
```

In `dispose`:
```dart
_cursorSubscription?.cancel();
```

**Step 4: Build and verify**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: Build succeeds

**Step 5: Manual test cursor data collection**

Run: `cd packages/screen_recorder && flutter run -d macos`

Actions:
1. Start recording
2. Move mouse around
3. Click a few times
4. Stop recording
5. Check Documents folder for cursor JSON file

Expected: JSON file created with cursor positions

**Step 6: Commit cursor data storage**

```bash
git add packages/screen_recorder/lib/models/cursor_recording.dart
git add packages/screen_recorder/test/models/cursor_recording_test.dart
git add packages/screen_recorder/lib/state/recording_state.dart
git commit -m "feat: store cursor data during recording

- Create CursorRecording model for managing cursor positions
- Implement position interpolation for smooth rendering
- Add save/load functionality for cursor data
- Subscribe to cursor stream in RecordingController
- Save cursor data to JSON file after recording
- Add unit tests for cursor recording

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

### Task 15: Render Cursor on Video Frames

**Goal:** Draw cursor overlay on video frames during encoding based on cursor position data.

**Files:**
- Create: `packages/screen_recorder/lib/rendering/cursor_renderer.dart`
- Modify: `packages/screen_recorder/lib/video_encoder.dart:1-250`
- Add: Cursor image assets

**Step 1: Add cursor image assets**

Create directory: `packages/screen_recorder/assets/cursors/`

Download or create cursor images:
- `default_cursor.png` (32x32 white cursor with black outline)
- `click_cursor.png` (32x32 cursor with blue highlight)

Add to `pubspec.yaml`:
```yaml
flutter:
  assets:
    - assets/cursors/default_cursor.png
    - assets/cursors/click_cursor.png
```

**Step 2: Create CursorRenderer**

File: `packages/screen_recorder/lib/rendering/cursor_renderer.dart`

```dart
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/services.dart';
import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';
import '../models/cursor_recording.dart';

/// Renders cursor overlay on video frames
class CursorRenderer {
  ui.Image? _defaultCursor;
  ui.Image? _clickCursor;
  bool _isInitialized = false;

  /// Initialize cursor images
  Future<void> initialize() async {
    // Load default cursor
    final defaultData = await rootBundle.load('assets/cursors/default_cursor.png');
    _defaultCursor = await _loadImage(defaultData.buffer.asUint8List());

    // Load click cursor
    final clickData = await rootBundle.load('assets/cursors/click_cursor.png');
    _clickCursor = await _loadImage(clickData.buffer.asUint8List());

    _isInitialized = true;
  }

  Future<ui.Image> _loadImage(Uint8List bytes) async {
    final codec = await ui.instantiateImageCodec(bytes);
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Draw cursor on frame at specific timestamp
  Future<Uint8List> renderCursorOnFrame({
    required Uint8List frameData,
    required int width,
    required int height,
    required int timestampMicros,
    required CursorRecording cursorRecording,
  }) async {
    if (!_isInitialized) {
      throw StateError('CursorRenderer not initialized');
    }

    // Get cursor position at this timestamp
    final cursorPos = cursorRecording.getPositionAt(timestampMicros);
    if (cursorPos == null) {
      // No cursor data, return original frame
      return frameData;
    }

    // Convert BGRA frame data to Image
    final frameImage = await _createImageFromBGRA(frameData, width, height);

    // Create canvas to draw on
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);

    // Draw original frame
    canvas.drawImage(frameImage, ui.Offset.zero, ui.Paint());

    // Draw cursor at position
    final cursorImage = cursorPos.isClicked ? _clickCursor! : _defaultCursor!;
    final cursorOffset = ui.Offset(
      cursorPos.x - cursorImage.width / 2,
      cursorPos.y - cursorImage.height / 2,
    );
    canvas.drawImage(cursorImage, cursorOffset, ui.Paint());

    // Convert back to BGRA bytes
    final picture = recorder.endRecording();
    final img = await picture.toImage(width, height);
    final byteData = await img.toByteData(format: ui.ImageByteFormat.rawRgba);

    // Convert RGBA to BGRA
    final rgbaBytes = byteData!.buffer.asUint8List();
    final bgraBytes = Uint8List(rgbaBytes.length);

    for (int i = 0; i < rgbaBytes.length; i += 4) {
      bgraBytes[i] = rgbaBytes[i + 2];     // B
      bgraBytes[i + 1] = rgbaBytes[i + 1]; // G
      bgraBytes[i + 2] = rgbaBytes[i];     // R
      bgraBytes[i + 3] = rgbaBytes[i + 3]; // A
    }

    return bgraBytes;
  }

  Future<ui.Image> _createImageFromBGRA(Uint8List bgra, int width, int height) async {
    // Convert BGRA to RGBA for Flutter
    final rgba = Uint8List(bgra.length);
    for (int i = 0; i < bgra.length; i += 4) {
      rgba[i] = bgra[i + 2];     // R
      rgba[i + 1] = bgra[i + 1]; // G
      rgba[i + 2] = bgra[i];     // B
      rgba[i + 3] = bgra[i + 3]; // A
    }

    final codec = await ui.instantiateImageCodec(
      rgba,
      targetWidth: width,
      targetHeight: height,
    );
    final frame = await codec.getNextFrame();
    return frame.image;
  }

  /// Dispose resources
  void dispose() {
    _defaultCursor?.dispose();
    _clickCursor?.dispose();
    _isInitialized = false;
  }
}
```

**Step 3: Integrate cursor rendering in VideoEncoder**

File: `packages/screen_recorder/lib/video_encoder.dart`

Add import:
```dart
import 'rendering/cursor_renderer.dart';
import 'models/cursor_recording.dart';
```

Add properties:
```dart
CursorRecording? _cursorRecording;
CursorRenderer? _cursorRenderer;
bool _renderCursor = false;
```

Add method to set cursor data:
```dart
/// Set cursor recording data for rendering
Future<void> setCursorData(CursorRecording cursorRecording) async {
  _cursorRecording = cursorRecording;
  _renderCursor = true;

  // Initialize cursor renderer
  _cursorRenderer = CursorRenderer();
  await _cursorRenderer!.initialize();

  print('Cursor renderer initialized with ${cursorRecording.count} positions');
}
```

Modify `addFrame` to render cursor:
```dart
Future<void> addFrame(FrameData frameData) async {
  // ... existing validation code ...

  Uint8List frameBytes = frameData.data;

  // Render cursor on frame if enabled
  if (_renderCursor && _cursorRecording != null && _cursorRenderer != null) {
    frameBytes = await _cursorRenderer!.renderCursorOnFrame(
      frameData: frameData.data,
      width: frameData.width,
      height: frameData.height,
      timestampMicros: frameData.timestampMicros,
      cursorRecording: _cursorRecording!,
    );
  }

  // Save frame with cursor overlay
  final framePath = '$_tempDir/frame_${_frameIndex.toString().padLeft(6, '0')}.bgra';
  final file = File(framePath);
  await file.writeAsBytes(frameBytes);

  // ... rest of method ...
}
```

Add cleanup in `cancel`:
```dart
_cursorRenderer?.dispose();
_cursorRenderer = null;
_cursorRecording = null;
```

**Step 4: Update RecordingController to pass cursor data**

File: `packages/screen_recorder/lib/state/recording_state.dart`

In `stopRecording`, before calling finalize:
```dart
// Pass cursor data to encoder for rendering
if (_cursorRecording != null && _cursorRecording!.count > 0) {
  await _videoEncoder!.setCursorData(_cursorRecording!);
}
```

**Step 5: Build and verify**

Run: `cd packages/screen_recorder && flutter build macos --debug`
Expected: Build succeeds

**Step 6: Manual test cursor rendering**

Run: `cd packages/screen_recorder && flutter run -d macos`

Actions:
1. Start recording
2. Move mouse slowly across screen
3. Click a few times
4. Stop recording
5. Wait for encoding
6. Play video in playback screen

Expected: Video shows cursor moving and highlights clicks

**Step 7: Commit cursor rendering**

```bash
git add packages/screen_recorder/assets/cursors/
git add packages/screen_recorder/lib/rendering/cursor_renderer.dart
git add packages/screen_recorder/lib/video_encoder.dart
git add packages/screen_recorder/lib/state/recording_state.dart
git add packages/screen_recorder/pubspec.yaml
git commit -m "feat: render cursor on video frames

- Create CursorRenderer for drawing cursor overlay
- Load cursor images for default and clicked states
- Render cursor on each frame based on timestamp
- Handle BGRA/RGBA color space conversion
- Integrate cursor rendering in video encoder
- Pass cursor data from RecordingController to encoder

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Testing Checklist

After completing all tasks, verify:

- [ ] Cursor tracking starts when recording starts
- [ ] Cursor position updates at ~60 Hz
- [ ] Mouse clicks are detected correctly
- [ ] Cursor data is saved to JSON file
- [ ] Cursor data can be loaded from file
- [ ] Cursor renders on video frames
- [ ] Cursor position matches actual movement
- [ ] Click highlighting works (visual feedback)
- [ ] No performance degradation during recording
- [ ] Cursor rendering doesn't slow down encoding significantly

---

## Known Limitations

1. **macOS Only**: Cursor tracking uses NSEvent, only works on macOS
2. **Accessibility Permissions**: May require granting accessibility permissions for global event monitoring
3. **Fixed Cursor Images**: Uses static cursor images, doesn't capture actual system cursor appearance
4. **No Hotspot Adjustment**: Cursor position is centered, not accounting for actual cursor hotspot
5. **Performance**: Cursor rendering adds overhead to video encoding

---

## Future Enhancements

1. **Capture System Cursor**: Use macOS APIs to get actual cursor image
2. **Smooth Animation**: Apply Catmull-Rom spline smoothing for very smooth cursor movement
3. **Click Effects**: Add expanding circle or ripple effect on clicks
4. **Configurable Appearance**: Let users customize cursor size, color, click effect
5. **Performance Optimization**: Use GPU acceleration for cursor rendering

---

## References

- [NSEvent Documentation](https://developer.apple.com/documentation/appkit/nsevent)
- [NSEvent.addGlobalMonitorForEvents](https://developer.apple.com/documentation/appkit/nsevent/1535472-addglobalmonitorforevents)
- [Flutter Canvas Drawing](https://api.flutter.dev/flutter/dart-ui/Canvas-class.html)
- [Image Manipulation in Dart](https://api.flutter.dev/flutter/dart-ui/Image-class.html)
