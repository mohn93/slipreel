# ScreenFlow Studio - Flutter Implementation Plan

## Project Information

**Project Name**: ScreenFlow Studio
**Project Path**: `/Users/mohn93/Desktop/side_projects/screenflow_studio`
**Target Platforms**: macOS, Windows, Linux (starting with macOS)

## Overview
Build a cross-platform screen recording tool (macOS, Windows, Linux) using Flutter for UI and platform-specific plugins for native screen capture. Target all 6 core features for a production-ready MVP.

**Target User**: Content creators and YouTubers who need polished, professional screen recordings with minimal effort.

**Core Philosophy**: Smart defaults that produce great results instantly, with powerful customization available for those who want it.

## Product Design & User Experience

### Core User Flow

**1. App Launch**
- Clean main window with three options:
  - "New Recording" (primary CTA, large button)
  - "Recent Recordings" (grid with thumbnails)
  - "Settings" (gear icon)
- Modern, minimal design (Spotify/Screen Studio aesthetic)
- Dark mode default, light mode available

**2. Pre-Recording Screen**
- **Window selector** (default): Grid of open windows with live thumbnails
  - Hover to highlight, click to select
  - Search/filter by app name
- Alternative modes: Full Screen, Custom Area
- **Settings panel** (collapsible):
  - Audio: System, Microphone, Both, None
  - Frame rate: 30fps / 60fps
  - Background style: Auto, Gradient, Solid, Blur, None
  - Cursor effects: Smart smooth (default), None, Custom

**3. Recording Experience**
- 3-2-1 countdown overlay
- **Floating control bar** (minimal, translucent pill):
  - [Pause] [Stop] [Timer]
  - Auto-hides after 3s, reappears on hover
  - Draggable to any edge
- Global hotkey: Cmd+Shift+2 to stop
- Background tracking: Cursor positions + click detection

**4. Post-Recording → Auto-Open Editor**
- Recording saves to temp location
- Editor opens immediately
- "Preparing your recording..." (2-3 seconds)
- **Always edit first** workflow (user preference)

### Editor Interface Design

**Layout** (Three sections):

**Top: Video Preview (60% height)**
- Large player with play/pause (spacebar)
- Frame-by-frame navigation (arrow keys)
- Zoom controls for checking details

**Middle: Timeline (25% height)**
- Three stacked tracks:
  1. Video track (thumbnails every few seconds)
  2. Effects track (zoom markers from detected clicks)
  3. Audio waveform
- **Trim handles**: Yellow brackets at start/end
- **Effect markers**: Icons showing auto-zoom points
  - Click to adjust intensity/duration
  - Drag to reposition
  - Delete to remove
  - Add button for manual placement

**Bottom: Control Panel (15% height)**
- Left: **Effect toggles** (ON/OFF switches)
  - Cursor smoothing (ON default)
  - Auto-zoom on clicks (ON default)
  - Background effect (ON default)
  - Window frame (OFF default)
- Right: **Export section**
  - Preset dropdown: YouTube | Twitter | GIF | Custom
  - "Export Video" button (primary)
  - Estimated export time

### Effect Customization

**Cursor Smoothing**
- Intensity: Low | Medium (default) | High
- Size multiplier: 0.8x - 2x
- Click animation: Ripple (default), Flash, Pulse, None
- Highlight color picker

**Auto-Zoom** (Click-detection based)
- Click sensitivity slider
- Zoom intensity: 1.5x - 3x
- Duration: Quick (0.5s) | Medium (1s) | Long (2s)
- Transition: Ease in-out (default), Snap, Bounce
- Preview in timeline

**Background Effects**
- Gradient: Two-color picker + angle
- Solid Color: Color picker
- Blur: Privacy mode (blur desktop)
- Image: Upload custom background
- None: Original recording
- Padding: 20px - 100px
- Corner radius: 0 - 40px
- Shadow: None | Subtle | Strong

**Window Frame**
- Presets: macOS style, Minimal, Modern, None
- Custom frame color
- Show/hide title bar

### Export Workflow

**Three Primary Presets**:

1. **YouTube (1080p 60fps)**
   - MP4 H.264, 8-12 Mbps
   - ~150MB/min
   - Best for: Tutorials, courses

2. **Twitter/Social (720p 30fps)**
   - MP4 H.264, 4-6 Mbps
   - ~50MB/min
   - Aspect: 16:9, 1:1, 9:16
   - Best for: Quick shares

3. **GIF (800x600 15fps)**
   - Animated GIF
   - 10 second limit (warns if longer)
   - ~5MB/sec
   - Best for: Snippets, reactions

**Export Progress**:
- Progress bar + percentage
- Frame count progress
- Time remaining estimate
- Preview of current frame
- Cancel button (saves progress)

**Post-Export**:
- Success notification
- Quick actions: Open, Copy path, Share
- "Export Another" for different preset

### First-Time Onboarding

**Welcome Flow (5 screens)**:

1. **Welcome**: Hero image + "Get Started"
2. **Permissions**: Request screen recording + microphone
3. **Quick Tour**: 3 slides showing features
4. **Choose Preset**: Tutorial Creator | Live Demo | Quick Shares
5. **Ready**: Quick reference card + "Record My First Video"

**Contextual Tips** (First 5 recordings):
- Tip 1: Adjust zoom markers
- Tip 2: Cmd+E to export
- Tip 3: Trim handles usage
- Tip 4: Toggle effects
- Tip 5: Set defaults

### Global Settings

**General**
- Launch at startup
- Menu bar presence
- Save location + auto-organize by date
- Temp file location
- Auto-delete temps after export

**Shortcuts**
- Global: Start (Cmd+Shift+1), Stop (Cmd+Shift+2), Pause
- Editor: Space (play), Arrows (frame), Z (zoom), Cmd+E (export)

**Recording Defaults**
- Frame rate, audio sources, cursor capture
- Countdown duration (0-10 seconds)
- Hardware acceleration preference

**Effects Defaults**
- Default state for new recordings
- Cursor smoothing intensity
- Auto-zoom sensitivity
- Background style preference

**Privacy**
- Permission status display
- App exclusion list (blacklist)
- Recording start notifications

**Performance**
- Max temp storage (10GB adjustable)
- Processing threads
- Memory limit (2GB adjustable)
- GPU acceleration toggle

### Error Handling

**Recording Issues**:
- Permission denied → Guide to System Preferences
- No audio device → Warn, continue video-only
- Disk space low → Warning + change location
- Window closed during recording → Auto-stop or switch to fullscreen
- Long recordings → Warnings at 30min, 60min; hard stop at 2hrs

**Processing Issues**:
- Export failed → Try again, change settings, report issue
- Out of memory → Progressive degradation (reduce quality, suggest lower res)
- Corrupted recording → Recovery attempt on next launch
- Effect failed → Continue without, don't block export

**Edge Cases**:
- Multi-monitor → Span or crop to single display
- System sleep → Auto-pause, prompt on wake
- App crash → Auto-save checkpoints every 10s, recovery modal
- High DPI → Smart downsampling for exports
- No cursor movement → Skip smoothing, no auto-zoom
- GIF too long → Auto-trim or warn about file size

### Performance Targets

**Recording**:
- 60 FPS with <10% CPU usage
- Flat memory usage (streaming to disk)
- Cursor tracked at 120fps (lightweight)
- Video at 30-60fps

**Processing**:
- Multi-threaded effect application (CPU cores - 1)
- GPU acceleration for blur/scale (5-10x faster)
- Single-pass effect pipeline per frame

**Export Speed**:
- Hardware encoding: 1-2x real-time for 1080p
- Software fallback: 0.3-0.5x real-time
- Accurate progress after first 10%

**UI Responsiveness**:
- 60fps UI during all operations
- Timeline scrubbing with cached thumbnails (1s intervals)
- All heavy work in isolates
- Non-blocking operations

## Tech Stack

### Core Framework
- **Flutter 3.x** - Cross-platform UI
- **Riverpod 3.0** - State management
- **Federated Plugin Architecture** - Platform-specific capture implementations

### Platform-Specific APIs
- **macOS**: ScreenCaptureKit (Swift 5.9+)
- **Windows**: Windows.Graphics.Capture API + Media Foundation (C++17)
- **Linux**: PipeWire/FFmpeg (C++17)

### Key Dependencies
- `ffmpeg_kit_flutter` - Video encoding and export
- `video_player` + `chewie` - Video playback
- `flutter_riverpod` - State management
- `path_provider` - File system access
- Custom platform channels for screen capture

## High-Level Architecture

```
Flutter UI Layer (Dart)
    ↓ Method Channels / Event Channels
Platform Interface Layer (Dart)
    ↓
Native Plugins (Swift/C++)
    ↓ Native APIs
Screen Capture + Audio + Cursor Tracking
    ↓ Event Streams
Video Processing Isolates (Dart)
    ↓
Export Pipeline (FFmpeg/Native Encoders)
```

## Project Structure

**Full Path**: `/Users/mohn93/Desktop/side_projects/screenflow_studio`

```
screenflow_studio/
├── packages/
│   ├── screen_recorder/                    # Main Flutter app
│   │   ├── lib/
│   │   │   ├── ui/screens/                 # Recording, editor screens
│   │   │   ├── ui/widgets/                 # Timeline, preview widgets
│   │   │   ├── state/                      # Riverpod providers
│   │   │   ├── domain/models/              # Data models
│   │   │   └── services/                   # Business logic
│   │
│   ├── screen_recorder_platform_interface/ # Abstract interface
│   │   └── lib/
│   │       ├── screen_recorder_platform_interface.dart
│   │       └── models/                     # Shared models
│   │
│   ├── screen_recorder_macos/              # macOS implementation
│   │   ├── lib/screen_recorder_macos.dart
│   │   └── macos/Classes/
│   │       ├── ScreenCaptureManager.swift
│   │       ├── AudioCaptureManager.swift
│   │       └── CursorTracker.swift
│   │
│   ├── screen_recorder_windows/            # Windows implementation
│   │   └── windows/
│   │       ├── screen_capture_manager.cpp
│   │       └── audio_capture_manager.cpp
│   │
│   ├── screen_recorder_linux/              # Linux implementation
│   │   └── linux/
│   │       ├── screen_capture_manager.cc
│   │       └── audio_capture_manager.cc
│   │
│   └── video_processing/                   # Video processing library
│       └── lib/
│           ├── isolates/                   # Background processing
│           ├── processors/                 # Effects & smoothing
│           └── encoders/                   # FFmpeg wrapper
```

## Implementation Phases

### Phase 1: Foundation & Basic Recording (Weeks 1-3)
**Goal**: Get basic screen recording working on macOS

**Tasks**:
1. Create Flutter project with federated plugin structure
2. Implement platform interface package with method channels
3. Build macOS plugin with ScreenCaptureKit wrapper
4. Create basic UI for start/stop recording
5. Implement raw video capture and save to MP4

**Critical Files**:
- `packages/screen_recorder_platform_interface/lib/screen_recorder_platform_interface.dart`
- `packages/screen_recorder_macos/macos/Classes/ScreenCaptureManager.swift`
- `packages/screen_recorder/lib/state/recording_state.dart`
- `packages/screen_recorder/lib/ui/screens/recording_screen.dart`

**Validation**: Successfully record 30 seconds of screen activity and save as MP4

---

### Phase 2: Audio Integration (Week 4)
**Goal**: Add synchronized audio capture

**Tasks**:
1. Implement audio capture in native plugin (AVFoundation for macOS)
2. Create audio Event Channel for streaming samples
3. Implement timestamp synchronization logic
4. Add AAC audio encoding
5. Mux audio + video into final MP4

**Critical Files**:
- `packages/screen_recorder_macos/macos/Classes/AudioCaptureManager.swift`
- `packages/video_processing/lib/encoders/ffmpeg_encoder.dart`

**Validation**: Recording has clear, synchronized audio from system and microphone

---

### Phase 3: Cursor Tracking & Smoothing (Weeks 5-6)
**Goal**: Implement professional cursor smoothing

**Tasks**:
1. Add cursor position tracking in native layer (60+ FPS)
2. Create cursor Event Channel
3. Implement Catmull-Rom spline smoothing algorithm
4. Store cursor track data with recording
5. Render smoothed cursor with click animations
6. Add cursor enhancement options (size, glow)

**Critical Files**:
- `packages/screen_recorder_macos/macos/Classes/CursorTracker.swift`
- `packages/video_processing/lib/processors/cursor_smoother.dart`
- `packages/video_processing/lib/processors/frame_compositor.dart`

**Algorithm**: Catmull-Rom spline interpolation for smooth cursor paths

**Validation**: Cursor movements are fluid with no jitter, clicks are highlighted

---

### Phase 4: Video Processing Pipeline (Weeks 7-9)
**Goal**: Build non-blocking processing with effects

**Tasks**:
1. Set up Dart Isolate architecture for video processing
2. Integrate FFmpeg via platform channels
3. Implement frame compositor with layering
4. Create H.264 hardware encoder wrapper
5. Implement background effects (solid colors, gradients, blur)
6. Add progress tracking for exports

**Critical Files**:
- `packages/video_processing/lib/isolates/encoder_isolate.dart`
- `packages/video_processing/lib/processors/background_processor.dart`
- `packages/video_processing/lib/encoders/h264_encoder.dart`

**Validation**: Can export 1080p video with background effects without UI freezing

---

### Phase 5: Timeline Editor (Weeks 10-12)
**Goal**: Build interactive timeline with trimming

**Tasks**:
1. Design custom timeline widget with playhead
2. Implement video playback with seek controls
3. Add trim handles for start/end cutting
4. Create effect marker system on timeline
5. Implement undo/redo for timeline operations
6. Add keyboard shortcuts (space = play/pause, arrow keys = frame step)

**Critical Files**:
- `packages/screen_recorder/lib/ui/widgets/timeline_editor.dart`
- `packages/screen_recorder/lib/state/editor_state.dart`
- `packages/screen_recorder/lib/domain/models/video_segment.dart`

**Validation**: Can trim video, scrub timeline, and see real-time preview

---

### Phase 6: Zoom & Focus Effects (Weeks 13-14)
**Goal**: Implement smooth zoom transitions

**Tasks**:
1. Design zoom effect algorithm (crop + scale with easing)
2. Add focus area selection UI (click to zoom)
3. Implement zoom effect processor in isolate
4. Create smooth transition curves (ease-in-out)
5. Add keyframe-based zoom control on timeline
6. Optimize rendering performance

**Critical Files**:
- `packages/video_processing/lib/processors/zoom_effect_processor.dart`
- `packages/screen_recorder/lib/ui/widgets/zoom_selector.dart`

**Algorithm**: Interpolated crop rect with ease-in-out cubic bezier

**Validation**: Zoom effects are smooth and professional-looking

---

### Phase 7: Window Framing & Polish (Week 15)
**Goal**: Add window decorations and UI refinement

**Tasks**:
1. Implement window frame overlay system
2. Create frame templates (rounded corners, shadows, padding)
3. Add frame customization UI (color, size, style)
4. Polish overall UI/UX
5. Add export presets (1080p 30fps, 4K 60fps, web-optimized)
6. Implement keyboard shortcuts reference

**Critical Files**:
- `packages/video_processing/lib/processors/frame_compositor.dart` (update)
- `packages/screen_recorder/lib/ui/screens/settings_screen.dart`

**Validation**: Recordings have polished window frames matching Screen Studio quality

---

### Phase 8: Cross-Platform Support (Weeks 16-18)
**Goal**: Port to Windows and Linux

**Tasks**:
1. Implement Windows plugin with Graphics Capture API
2. Implement Linux plugin with PipeWire/X11
3. Handle platform-specific cursor rendering
4. Test and fix platform-specific bugs
5. Ensure feature parity across platforms

**Critical Files**:
- `packages/screen_recorder_windows/windows/screen_capture_manager.cpp`
- `packages/screen_recorder_linux/linux/screen_capture_manager.cc`

**Validation**: All 6 features work on macOS, Windows, and Linux

---

### Phase 9: Performance Optimization (Week 19)
**Goal**: Optimize for production performance

**Tasks**:
1. Profile and optimize frame processing pipeline
2. Implement frame buffer pooling (reduce allocations)
3. Add GPU acceleration for effects (Metal/DirectX)
4. Optimize export speed with parallel processing
5. Reduce memory usage for long recordings

**Performance Targets**:
- 60 FPS recording with <10% CPU usage
- 1080p 30fps export at real-time speed
- <500MB memory for 30-minute recording

**Validation**: Can record 4K 60fps smoothly on modern hardware

---

### Phase 10: Testing & Release Prep (Week 20)
**Goal**: Prepare for production release

**Tasks**:
1. Comprehensive testing on all platforms
2. Fix critical bugs
3. Write user documentation
4. Create demo videos
5. Package for distribution (DMG, MSI, AppImage)

**Validation**: Stable, polished product ready for users

## Platform Plugin Design

### Platform Interface (Dart)

```dart
abstract class ScreenRecorderPlatform {
  // Discovery
  Future<List<ScreenInfo>> getAvailableScreens();
  Future<List<WindowInfo>> getAvailableWindows();
  Future<List<AudioDeviceInfo>> getAudioDevices();

  // Recording Control
  Future<void> startRecording(RecordingSettings settings);
  Future<void> pauseRecording();
  Future<void> resumeRecording();
  Future<String> stopRecording(); // Returns file path

  // Real-time Streams
  Stream<FrameData> get frameStream;
  Stream<AudioData> get audioStream;
  Stream<CursorPosition> get cursorStream;
}
```

### Method Channels

- `com.yourapp.screen_recorder/recording` - Recording control
- `com.yourapp.screen_recorder/capability` - Capability queries
- `com.yourapp.screen_recorder/frames` - Video frame stream (Event Channel)
- `com.yourapp.screen_recorder/audio` - Audio sample stream (Event Channel)
- `com.yourapp.screen_recorder/cursor` - Cursor position stream (Event Channel)

## Data Flow

### Recording Phase
```
User clicks "Record"
    ↓
Native plugin starts capture (ScreenCaptureKit/etc)
    ↓
Streams (60 FPS):
  - Video frames → frameStream
  - Audio samples → audioStream
  - Cursor positions → cursorStream
    ↓
Dart layer buffers and syncs by timestamp
    ↓
Write to temp files:
  - frames.raw (raw video)
  - audio.pcm (raw audio)
  - cursor_track.json (cursor data)
```

### Processing Phase
```
User clicks "Export"
    ↓
Video Processing Isolate spawned
    ↓
Load raw data from temp files
    ↓
Apply effects in order:
  1. Cursor smoothing (Bezier curves)
  2. Zoom effects (crop + scale)
  3. Background effects (compositing)
  4. Window frames (overlay)
    ↓
Encode with H.264 (hardware preferred)
    ↓
Mux audio and video → final.mp4
    ↓
Delete temp files
```

## Key Technical Decisions

### 1. Flutter UI + Native Capture
- **Why**: Best of both worlds - beautiful cross-platform UI with native performance for capture
- **Trade-off**: More complex architecture, but worth it for maintainability

### 2. Post-Processing vs Real-Time Effects
- **Why**: Post-processing allows higher quality and easier editing
- **Trade-off**: No live preview, but better final output quality

### 3. Dart Isolates for Processing
- **Why**: Keeps UI responsive during export
- **Trade-off**: Some serialization overhead, but manageable

### 4. Hardware Encoding Priority
- **Why**: 5-10x faster than software encoding
- **Trade-off**: Less quality control, but worth it for speed

### 5. Federated Plugin Architecture
- **Why**: Clean platform separation, follows Flutter best practices
- **Trade-off**: More files to manage, but better maintainability

## Critical Technical Challenges

### Challenge 1: Audio/Video Sync
- **Solution**: Use monotonic system clock for all timestamps
- **Implementation**: Drift correction algorithm with 10ms tolerance
- **File**: `packages/video_processing/lib/sync_manager.dart`

### Challenge 2: Memory for Long Recordings
- **Solution**: Stream frames to disk immediately, use memory-mapped files
- **Implementation**: Frame buffer pool with max 2GB memory cap
- **File**: `packages/video_processing/lib/frame_buffer_pool.dart`

### Challenge 3: Cross-Platform Cursors
- **Solution**: Capture cursor as texture, render in post-processing
- **Implementation**: Platform-specific cursor capture + unified renderer
- **Files**: Native `CursorTracker.*` + `cursor_smoother.dart`

### Challenge 4: Export Performance
- **Solution**: Hardware encoders + parallel frame processing
- **Implementation**: Multi-isolate pipeline with queue management
- **File**: `packages/video_processing/lib/isolates/encoder_isolate.dart`

### Challenge 5: Permissions
- **Solution**: Graceful permission flow with clear UI
- **Implementation**: Platform-specific permission handlers
- **Files**: Native plugin permission request code

## Key Algorithms

### Cursor Smoothing (Catmull-Rom Spline)
```dart
// Smooth jittery cursor movements into fluid paths
List<CursorPosition> smooth(List<CursorPosition> raw) {
  for (int i = 1; i < raw.length - 2; i++) {
    var p0 = raw[i - 1], p1 = raw[i], p2 = raw[i + 1], p3 = raw[i + 2];
    for (double t = 0; t < 1.0; t += 0.1) {
      smoothed.add(catmullRomInterpolate(p0, p1, p2, p3, t));
    }
  }
}
```

### Zoom Effect (Crop + Scale)
```dart
// Create smooth zoom transition with easing
VideoFrame applyZoom(VideoFrame frame, ZoomEffect effect, double progress) {
  final scale = lerpDouble(1.0, effect.scale, easeInOutCubic(progress));
  final cropRect = Rect.fromCenter(
    center: effect.targetArea.center,
    width: frame.width / scale,
    height: frame.height / scale,
  );
  return frame.crop(cropRect).scale(frame.width, frame.height);
}
```

## Testing Strategy

### Unit Tests
- Cursor smoothing algorithm accuracy
- Sync manager drift correction
- Effect processors (zoom, background)
- Timeline state management

### Integration Tests
- End-to-end recording flow
- Export pipeline with effects
- Timeline editing operations

### Platform Tests
- Screen capture on each OS
- Audio capture quality
- Permission flows

### Performance Tests
- 4K 60fps recording stability
- Export speed benchmarks
- Memory usage over 30+ minutes

## Success Metrics

### Phase 1-3 (MVP - Core Recording)
- ✅ Record 1080p 60fps screen + audio
- ✅ Smooth cursor movements (no jitter)
- ✅ Export to MP4 with H.264
- ✅ Window-first selection works smoothly
- ✅ Floating controls are unobtrusive

### Phase 4-6 (Full Features - Editor & Effects)
- ✅ Timeline editor with trim functionality
- ✅ Auto-zoom on click detection working
- ✅ Background effects (color, gradient, blur)
- ✅ Effect customization panel intuitive
- ✅ Export presets (YouTube, Twitter, GIF) working

### Phase 7-10 (Production Ready)
- ✅ Cross-platform (macOS, Windows, Linux)
- ✅ Professional window framing
- ✅ First-time onboarding complete
- ✅ All error cases handled gracefully
- ✅ Performance targets met:
  - 60 FPS recording with <10% CPU
  - 1-2x real-time export with hardware encoding
  - <500MB memory for 30-minute recording

### User Experience Goals
- ✅ New user can record first video within 2 minutes
- ✅ Default settings produce professional-looking output
- ✅ No manual editing needed for simple recordings
- ✅ Export process feels fast (clear progress, accurate estimates)
- ✅ App feels native and polished on each platform

## Execution Plan - Phase 1 Breakdown

### Batch 1: Project Foundation (Tasks 1-3) ✅ COMPLETED

**Task 1: Create Flutter project and workspace structure** ✅
- Create directory `/Users/mohn93/Desktop/side_projects/screenflow_studio`
- Initialize Flutter app in `packages/screen_recorder`
- Set up melos workspace configuration for multi-package project
- Configure Flutter for desktop (macOS) support
- **Verification**: `flutter doctor` passes, `flutter run` shows empty app on macOS

**Task 2: Create platform interface package** ✅
- Generate `screen_recorder_platform_interface` package
- Define abstract `ScreenRecorderPlatform` class with methods
- Create data models (`ScreenInfo`, `WindowInfo`, `RecordingSettings`, etc.)
- Set up method channel constants
- **Verification**: Package builds without errors, models have proper serialization

**Task 3: Create macOS plugin package skeleton** ✅
- Generate `screen_recorder_macos` plugin package
- Set up Swift bridging and method channel registration
- Configure macOS entitlements for screen recording
- Implement platform registration in Dart
- **Verification**: Plugin builds, method channel connects to native side

### Batch 2: Basic Screen Capture (Tasks 4-6)

**Task 4: Implement ScreenCaptureKit wrapper in Swift**
- Create `ScreenCaptureManager.swift` class
- Implement screen/window discovery methods
- Add basic screen capture session setup
- Implement frame capture callback
- **Verification**: Can list available windows, start capture session

**Task 5: Stream frames to Flutter**
- Set up Event Channel for frame data
- Implement frame data conversion (CVPixelBuffer → Uint8List)
- Add timestamp synchronization
- Handle frame buffering
- **Verification**: Flutter receives frame data at 30+ FPS

**Task 6: Save frames to MP4 file**
- Integrate `ffmpeg_kit_flutter` dependency
- Implement basic H.264 encoder
- Write frames to temporary file
- Implement stop recording and file saving
- **Verification**: Can record 10 seconds and produce valid MP4 file

### Batch 3: Basic UI (Tasks 7-9)

**Task 7: Build recording screen UI**
- Create `RecordingScreen` widget
- Add window selection grid
- Implement start/stop recording buttons
- Show recording status indicator
- **Verification**: UI displays available windows, buttons work

**Task 8: Implement recording state management**
- Create Riverpod providers for recording state
- Handle recording lifecycle (idle → recording → processing → complete)
- Add error handling
- **Verification**: State transitions work correctly, errors are caught

**Task 9: Add basic video playback**
- Integrate `video_player` package
- Create preview screen for recorded video
- Add playback controls
- **Verification**: Can play back recorded MP4 file

## Next Steps After Plan Approval

1. Execute **Batch 2** (Tasks 4-6) - Screen capture implementation
2. Review and get feedback
3. Execute **Batch 3** (Tasks 7-9) - Basic UI
4. Complete Phase 1 validation
5. Move to Phase 2 (Audio Integration)

## Resources & References

- ScreenCaptureKit: https://developer.apple.com/documentation/screencapturekit/
- Windows Graphics Capture: https://learn.microsoft.com/en-us/windows/uwp/audio-video-camera/screen-capture
- FFmpeg Flutter: https://pub.dev/packages/ffmpeg_kit_flutter
- Flutter Platform Channels: https://docs.flutter.dev/platform-integration/platform-channels
- Riverpod: https://riverpod.dev/
