# Video Processing with Isolates

This directory contains the isolate-based video processing implementation for ScreenFlow Studio.

## Architecture

### VideoProcessingIsolate
The core isolate wrapper that manages background video processing:
- Spawns a background isolate for encoding
- Handles bidirectional message passing
- Manages encoder lifecycle
- Provides progress updates

### Message Types
**Commands (Main → Isolate):**
- `ConfigureEncoderMessage` - Initialize encoder with video settings
- `ProcessFrameMessage` - Send frame data for encoding
- `FinalizeMessage` - Complete encoding and write output file
- `DisposeMessage` - Clean up resources

**Responses (Isolate → Main):**
- `ConfiguredResponse` - Encoder configured successfully
- `FrameProcessedResponse` - Frame processed successfully
- `ProgressUpdate` - Progress percentage update (0.0-1.0)
- `FinalizedResponse` - Encoding complete with output path
- `ErrorResponse` - Error occurred during processing

## Usage

### High-Level API (Recommended)
```dart
import 'package:screen_recorder/video_encoder_isolate.dart';

final encoder = VideoEncoderIsolate();

// Initialize
await encoder.initialize(
  outputPath: '/path/to/output.mp4',
  width: 1920,
  height: 1080,
  fps: 30,
);

// Track progress
encoder.onProgress = (progress) {
  print('Encoding: ${(progress * 100).toStringAsFixed(1)}%');
};

// Add frames
await encoder.addFrame(frameData, timestampMicros);

// Finalize
final outputPath = await encoder.finalize();
```

### Low-Level API (Advanced)
```dart
import 'package:screen_recorder/processing/video_processing_isolate.dart';

final isolate = VideoProcessingIsolate();

// Initialize isolate
await isolate.initialize();

// Configure encoder
await isolate.configureEncoder(
  outputPath: '/path/to/output.mp4',
  width: 1920,
  height: 1080,
  fps: 30,
);

// Process frames
await isolate.processFrame(frameData, timestampMicros);

// Finalize
final outputPath = await isolate.finalize();

// Cleanup
await isolate.dispose();
```

## Platform Channel Integration

The isolate automatically initializes `BackgroundIsolateBinaryMessenger` when
`RootIsolateToken.instance` is available, enabling platform channel access
(required for `path_provider` and file I/O).

In test environments where platform channels are unavailable, the isolate
falls back to a mock mode for testing the messaging infrastructure.

## Performance Benefits

- Non-blocking UI: All encoding work happens on background isolate
- Progress tracking: Main isolate receives regular progress updates
- Memory efficient: Frame data transferred via isolate messaging
- Cancellable: Encoding can be cancelled at any time

## Thread Safety

All encoder state is isolated to the background isolate. The main isolate
communicates via message passing only, ensuring thread safety without locks.
