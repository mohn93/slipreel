# Phase 7: Window Framing Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add professional window decorations with customizable frames, shadows, and export presets to match Screen Studio quality.

**Architecture:** Layered frame rendering system using CustomPainter for frame overlays, model-based frame templates with configurable properties, integration with video export pipeline for baked-in frames. Settings UI with live preview for frame customization.

**Tech Stack:** Flutter CustomPainter, BoxShadow/BoxDecoration, BorderRadius/RRect, Riverpod for settings state, SharedPreferences for persistence

---

## Overview

Phase 7 adds professional window framing with:
- **Task 25**: Frame model and frame templates (rounded, modern, minimal)
- **Task 26**: Frame renderer with live preview on video
- **Task 27**: Frame customization UI with settings screen
- **Task 28**: Export presets (1080p/4K, frame rates, quality)

This brings the app to Screen Studio-level polish with professional-looking recordings.

---

## Task 25: Frame Model & Templates

**Goal:** Create frame model with properties for padding, corner radius, shadow, colors. Implement 3 frame templates: Rounded, Modern, Minimal.

**Files:**
- Create: `packages/screen_recorder/lib/models/window_frame.dart`
- Create: `packages/screen_recorder/test/models/window_frame_test.dart`

### Step 1: Write failing test for WindowFrame model

**File:** `packages/screen_recorder/test/models/window_frame_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/window_frame.dart';

void main() {
  group('WindowFrame', () {
    test('should create frame with all properties', () {
      final frame = WindowFrame(
        name: 'Test Frame',
        padding: const EdgeInsets.all(20),
        cornerRadius: 12.0,
        shadowBlur: 40.0,
        shadowOffset: const Offset(0, 10),
        shadowColor: Colors.black.withValues(alpha: 0.3),
        backgroundColor: Colors.white,
        borderWidth: 0,
        borderColor: Colors.transparent,
      );

      expect(frame.name, 'Test Frame');
      expect(frame.padding, const EdgeInsets.all(20));
      expect(frame.cornerRadius, 12.0);
      expect(frame.shadowBlur, 40.0);
      expect(frame.shadowOffset, const Offset(0, 10));
      expect(frame.shadowColor.alpha, closeTo(0.3, 0.01));
      expect(frame.backgroundColor, Colors.white);
      expect(frame.borderWidth, 0);
    });

    test('should create rounded template', () {
      final frame = WindowFrame.rounded();

      expect(frame.name, 'Rounded');
      expect(frame.cornerRadius, 16.0);
      expect(frame.shadowBlur, greaterThan(0));
      expect(frame.padding, const EdgeInsets.all(40));
    });

    test('should create modern template', () {
      final frame = WindowFrame.modern();

      expect(frame.name, 'Modern');
      expect(frame.cornerRadius, 8.0);
      expect(frame.borderWidth, greaterThan(0));
      expect(frame.padding, const EdgeInsets.all(24));
    });

    test('should create minimal template', () {
      final frame = WindowFrame.minimal();

      expect(frame.name, 'Minimal');
      expect(frame.cornerRadius, 0);
      expect(frame.shadowBlur, 0);
      expect(frame.padding, const EdgeInsets.all(16));
    });

    test('should support copyWith for customization', () {
      final original = WindowFrame.rounded();
      final modified = original.copyWith(
        cornerRadius: 24.0,
        backgroundColor: Colors.blue,
      );

      expect(modified.cornerRadius, 24.0);
      expect(modified.backgroundColor, Colors.blue);
      expect(modified.name, original.name); // Unchanged
      expect(modified.padding, original.padding); // Unchanged
    });

    test('should serialize to and from JSON', () {
      final frame = WindowFrame(
        name: 'Custom',
        padding: const EdgeInsets.all(20),
        cornerRadius: 12.0,
        shadowBlur: 30.0,
        shadowOffset: const Offset(0, 5),
        shadowColor: Colors.black.withValues(alpha: 0.2),
        backgroundColor: Colors.white,
        borderWidth: 2,
        borderColor: Colors.grey,
      );

      final json = frame.toJson();
      final restored = WindowFrame.fromJson(json);

      expect(restored.name, frame.name);
      expect(restored.padding, frame.padding);
      expect(restored.cornerRadius, frame.cornerRadius);
      expect(restored.shadowBlur, frame.shadowBlur);
      expect(restored.shadowOffset, frame.shadowOffset);
      expect(restored.backgroundColor, frame.backgroundColor);
    });

    test('should have none template with no decorations', () {
      final frame = WindowFrame.none();

      expect(frame.name, 'None');
      expect(frame.padding, EdgeInsets.zero);
      expect(frame.cornerRadius, 0);
      expect(frame.shadowBlur, 0);
      expect(frame.borderWidth, 0);
    });
  });
}
```

### Step 2: Run test to verify it fails

```bash
cd packages/screen_recorder
flutter test test/models/window_frame_test.dart
```

**Expected:** FAIL with "Target of URI doesn't exist: 'package:screen_recorder/models/window_frame.dart'"

### Step 3: Implement WindowFrame model

**File:** `packages/screen_recorder/lib/models/window_frame.dart`

```dart
import 'package:flutter/material.dart';

/// Defines the visual styling for window frames in recordings
class WindowFrame {
  final String name;
  final EdgeInsets padding;
  final double cornerRadius;
  final double shadowBlur;
  final Offset shadowOffset;
  final Color shadowColor;
  final Color backgroundColor;
  final double borderWidth;
  final Color borderColor;

  const WindowFrame({
    required this.name,
    required this.padding,
    required this.cornerRadius,
    required this.shadowBlur,
    required this.shadowOffset,
    required this.shadowColor,
    required this.backgroundColor,
    required this.borderWidth,
    required this.borderColor,
  });

  /// No frame decoration
  factory WindowFrame.none() {
    return const WindowFrame(
      name: 'None',
      padding: EdgeInsets.zero,
      cornerRadius: 0,
      shadowBlur: 0,
      shadowOffset: Offset.zero,
      shadowColor: Colors.transparent,
      backgroundColor: Colors.transparent,
      borderWidth: 0,
      borderColor: Colors.transparent,
    );
  }

  /// Rounded corners with soft shadow - Screen Studio style
  factory WindowFrame.rounded() {
    return WindowFrame(
      name: 'Rounded',
      padding: const EdgeInsets.all(40),
      cornerRadius: 16.0,
      shadowBlur: 40.0,
      shadowOffset: const Offset(0, 10),
      shadowColor: Colors.black.withValues(alpha: 0.3),
      backgroundColor: Colors.white,
      borderWidth: 0,
      borderColor: Colors.transparent,
    );
  }

  /// Modern flat design with border
  factory WindowFrame.modern() {
    return WindowFrame(
      name: 'Modern',
      padding: const EdgeInsets.all(24),
      cornerRadius: 8.0,
      shadowBlur: 20.0,
      shadowOffset: const Offset(0, 4),
      shadowColor: Colors.black.withValues(alpha: 0.15),
      backgroundColor: Colors.white,
      borderWidth: 1.5,
      borderColor: Colors.grey.shade300,
    );
  }

  /// Minimal padding and subtle shadow
  factory WindowFrame.minimal() {
    return WindowFrame(
      name: 'Minimal',
      padding: const EdgeInsets.all(16),
      cornerRadius: 0,
      shadowBlur: 0,
      shadowOffset: Offset.zero,
      shadowColor: Colors.transparent,
      backgroundColor: Colors.transparent,
      borderWidth: 0,
      borderColor: Colors.transparent,
    );
  }

  /// Create a modified copy of this frame
  WindowFrame copyWith({
    String? name,
    EdgeInsets? padding,
    double? cornerRadius,
    double? shadowBlur,
    Offset? shadowOffset,
    Color? shadowColor,
    Color? backgroundColor,
    double? borderWidth,
    Color? borderColor,
  }) {
    return WindowFrame(
      name: name ?? this.name,
      padding: padding ?? this.padding,
      cornerRadius: cornerRadius ?? this.cornerRadius,
      shadowBlur: shadowBlur ?? this.shadowBlur,
      shadowOffset: shadowOffset ?? this.shadowOffset,
      shadowColor: shadowColor ?? this.shadowColor,
      backgroundColor: backgroundColor ?? this.backgroundColor,
      borderWidth: borderWidth ?? this.borderWidth,
      borderColor: borderColor ?? this.borderColor,
    );
  }

  /// Convert to JSON for persistence
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'padding': {
        'left': padding.left,
        'top': padding.top,
        'right': padding.right,
        'bottom': padding.bottom,
      },
      'cornerRadius': cornerRadius,
      'shadowBlur': shadowBlur,
      'shadowOffset': {'dx': shadowOffset.dx, 'dy': shadowOffset.dy},
      'shadowColor': shadowColor.value,
      'backgroundColor': backgroundColor.value,
      'borderWidth': borderWidth,
      'borderColor': borderColor.value,
    };
  }

  /// Create from JSON
  factory WindowFrame.fromJson(Map<String, dynamic> json) {
    final paddingMap = json['padding'] as Map<String, dynamic>;
    final shadowOffsetMap = json['shadowOffset'] as Map<String, dynamic>;

    return WindowFrame(
      name: json['name'] as String,
      padding: EdgeInsets.only(
        left: paddingMap['left'] as double,
        top: paddingMap['top'] as double,
        right: paddingMap['right'] as double,
        bottom: paddingMap['bottom'] as double,
      ),
      cornerRadius: json['cornerRadius'] as double,
      shadowBlur: json['shadowBlur'] as double,
      shadowOffset: Offset(
        shadowOffsetMap['dx'] as double,
        shadowOffsetMap['dy'] as double,
      ),
      shadowColor: Color(json['shadowColor'] as int),
      backgroundColor: Color(json['backgroundColor'] as int),
      borderWidth: json['borderWidth'] as double,
      borderColor: Color(json['borderColor'] as int),
    );
  }

  /// Get all built-in templates
  static List<WindowFrame> get templates => [
        WindowFrame.none(),
        WindowFrame.rounded(),
        WindowFrame.modern(),
        WindowFrame.minimal(),
      ];

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WindowFrame &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          padding == other.padding &&
          cornerRadius == other.cornerRadius &&
          shadowBlur == other.shadowBlur &&
          shadowOffset == other.shadowOffset &&
          shadowColor == other.shadowColor &&
          backgroundColor == other.backgroundColor &&
          borderWidth == other.borderWidth &&
          borderColor == other.borderColor;

  @override
  int get hashCode =>
      name.hashCode ^
      padding.hashCode ^
      cornerRadius.hashCode ^
      shadowBlur.hashCode ^
      shadowOffset.hashCode ^
      shadowColor.hashCode ^
      backgroundColor.hashCode ^
      borderWidth.hashCode ^
      borderColor.hashCode;
}
```

### Step 4: Run test to verify it passes

```bash
cd packages/screen_recorder
flutter test test/models/window_frame_test.dart
```

**Expected:** All 8 tests PASS

### Step 5: Commit

```bash
git add lib/models/window_frame.dart test/models/window_frame_test.dart
git commit -m "feat: add WindowFrame model with templates"
```

---

## Task 26: Frame Renderer with Live Preview

**Goal:** Create FramePainter to render frames around video content with shadows, borders, and rounded corners. Integrate into PlaybackScreen for live preview.

**Files:**
- Create: `packages/screen_recorder/lib/rendering/frame_painter.dart`
- Create: `packages/screen_recorder/test/rendering/frame_painter_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

### Step 1: Write failing test for FramePainter

**File:** `packages/screen_recorder/test/rendering/frame_painter_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/rendering/frame_painter.dart';

void main() {
  group('FramePainter', () {
    test('should create with frame and video size', () {
      final frame = WindowFrame.rounded();
      final painter = FramePainter(
        frame: frame,
        videoSize: const Size(1920, 1080),
      );

      expect(painter.frame, frame);
      expect(painter.videoSize, const Size(1920, 1080));
    });

    test('should repaint when frame changes', () {
      final frame1 = WindowFrame.rounded();
      final frame2 = WindowFrame.modern();
      final painter1 = FramePainter(
        frame: frame1,
        videoSize: const Size(1920, 1080),
      );
      final painter2 = FramePainter(
        frame: frame2,
        videoSize: const Size(1920, 1080),
      );

      expect(painter1.shouldRepaint(painter2), true);
    });

    test('should not repaint when frame is same', () {
      final frame = WindowFrame.rounded();
      final painter1 = FramePainter(
        frame: frame,
        videoSize: const Size(1920, 1080),
      );
      final painter2 = FramePainter(
        frame: frame,
        videoSize: const Size(1920, 1080),
      );

      expect(painter1.shouldRepaint(painter2), false);
    });

    test('should repaint when video size changes', () {
      final frame = WindowFrame.rounded();
      final painter1 = FramePainter(
        frame: frame,
        videoSize: const Size(1920, 1080),
      );
      final painter2 = FramePainter(
        frame: frame,
        videoSize: const Size(1280, 720),
      );

      expect(painter1.shouldRepaint(painter2), true);
    });

    test('should calculate total size including padding', () {
      final frame = WindowFrame(
        name: 'Test',
        padding: const EdgeInsets.all(40),
        cornerRadius: 16.0,
        shadowBlur: 40.0,
        shadowOffset: const Offset(0, 10),
        shadowColor: Colors.black.withValues(alpha: 0.3),
        backgroundColor: Colors.white,
        borderWidth: 0,
        borderColor: Colors.transparent,
      );

      final totalSize = FramePainter.calculateTotalSize(
        videoSize: const Size(1920, 1080),
        frame: frame,
      );

      // 1920 + 40*2 = 2000, 1080 + 40*2 = 1160
      expect(totalSize.width, 2000);
      expect(totalSize.height, 1160);
    });

    test('should return video size when frame is none', () {
      final frame = WindowFrame.none();
      final totalSize = FramePainter.calculateTotalSize(
        videoSize: const Size(1920, 1080),
        frame: frame,
      );

      expect(totalSize.width, 1920);
      expect(totalSize.height, 1080);
    });
  });
}
```

### Step 2: Run test to verify it fails

```bash
cd packages/screen_recorder
flutter test test/rendering/frame_painter_test.dart
```

**Expected:** FAIL with "Target of URI doesn't exist: 'package:screen_recorder/rendering/frame_painter.dart'"

### Step 3: Implement FramePainter

**File:** `packages/screen_recorder/lib/rendering/frame_painter.dart`

```dart
import 'package:flutter/material.dart';
import 'package:screen_recorder/models/window_frame.dart';

/// Paints window frames around video content
class FramePainter extends CustomPainter {
  final WindowFrame frame;
  final Size videoSize;

  FramePainter({
    required this.frame,
    required this.videoSize,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // Skip painting if no frame
    if (frame.name == 'None') {
      return;
    }

    // Calculate video rect with padding
    final videoRect = Rect.fromLTWH(
      frame.padding.left,
      frame.padding.top,
      videoSize.width,
      videoSize.height,
    );

    // Draw shadow
    if (frame.shadowBlur > 0) {
      final shadowPaint = Paint()
        ..color = frame.shadowColor
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, frame.shadowBlur / 2);

      final shadowRect = videoRect.shift(frame.shadowOffset);
      final shadowRRect = RRect.fromRectAndRadius(
        shadowRect,
        Radius.circular(frame.cornerRadius),
      );

      canvas.drawRRect(shadowRRect, shadowPaint);
    }

    // Draw background
    if (frame.backgroundColor.alpha > 0) {
      final backgroundPaint = Paint()
        ..color = frame.backgroundColor
        ..style = PaintingStyle.fill;

      final backgroundRRect = RRect.fromRectAndRadius(
        videoRect,
        Radius.circular(frame.cornerRadius),
      );

      canvas.drawRRect(backgroundRRect, backgroundPaint);
    }

    // Draw border
    if (frame.borderWidth > 0) {
      final borderPaint = Paint()
        ..color = frame.borderColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = frame.borderWidth;

      final borderRRect = RRect.fromRectAndRadius(
        videoRect,
        Radius.circular(frame.cornerRadius),
      );

      canvas.drawRRect(borderRRect, borderPaint);
    }
  }

  @override
  bool shouldRepaint(FramePainter oldDelegate) {
    return oldDelegate.frame != frame || oldDelegate.videoSize != videoSize;
  }

  /// Calculate total canvas size including frame padding
  static Size calculateTotalSize({
    required Size videoSize,
    required WindowFrame frame,
  }) {
    return Size(
      videoSize.width + frame.padding.left + frame.padding.right,
      videoSize.height + frame.padding.top + frame.padding.bottom,
    );
  }
}
```

### Step 4: Run test to verify it passes

```bash
cd packages/screen_recorder
flutter test test/rendering/frame_painter_test.dart
```

**Expected:** All 6 tests PASS

### Step 5: Integrate frame preview into PlaybackScreen

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add import:
```dart
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/rendering/frame_painter.dart';
```

Add state variable in `_PlaybackScreenState`:
```dart
WindowFrame _selectedFrame = WindowFrame.none();
```

Modify `_buildVideoPlayer()` method to wrap video in frame painter:

```dart
Widget _buildVideoPlayer() {
  // ... existing code to get activeZoom and videoWidget ...

  return AspectRatio(
    aspectRatio: _controller.value.aspectRatio,
    child: Stack(
      children: [
        // Frame background and shadow (behind video)
        if (_selectedFrame.name != 'None')
          CustomPaint(
            painter: FramePainter(
              frame: _selectedFrame,
              videoSize: _controller.value.size,
            ),
            size: FramePainter.calculateTotalSize(
              videoSize: _controller.value.size,
              frame: _selectedFrame,
            ),
          ),
        // Video content with zoom selector
        Padding(
          padding: _selectedFrame.padding,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(_selectedFrame.cornerRadius),
            child: ZoomSelector(
              enabled: _isSelectingZoom,
              videoSize: _controller.value.size,
              onRegionSelected: _handleZoomRegionSelected,
              child: videoWidget,
            ),
          ),
        ),
      ],
    ),
  );
}
```

Add frame selector button to controls (in `_buildControls` after zoom button):

```dart
// Frame button
IconButton(
  onPressed: _toggleFrameSelector,
  icon: const Icon(Icons.border_outer),
  color: Colors.white70,
  tooltip: 'Change Frame',
),
```

Add frame toggle method:
```dart
void _toggleFrameSelector() {
  // Cycle through frames
  final currentIndex = WindowFrame.templates.indexOf(_selectedFrame);
  final nextIndex = (currentIndex + 1) % WindowFrame.templates.length;
  setState(() {
    _selectedFrame = WindowFrame.templates[nextIndex];
  });
}
```

### Step 6: Run app and verify frame preview

```bash
cd packages/screen_recorder
flutter run -d macos
```

**Expected:**
- App launches successfully
- Click frame button to cycle through templates
- Video shows rounded corners, shadows, and padding when frame is selected
- Frame changes are visible immediately

### Step 7: Commit

```bash
git add lib/rendering/frame_painter.dart test/rendering/frame_painter_test.dart lib/ui/screens/playback_screen.dart
git commit -m "feat: add frame renderer with live preview"
```

---

## Task 27: Frame Customization UI

**Goal:** Create settings screen with frame customization controls (template picker, padding slider, corner radius, shadow intensity). Persist settings with SharedPreferences.

**Files:**
- Create: `packages/screen_recorder/lib/ui/screens/settings_screen.dart`
- Create: `packages/screen_recorder/lib/state/frame_settings_provider.dart`
- Create: `packages/screen_recorder/test/state/frame_settings_provider_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Modify: `packages/screen_recorder/pubspec.yaml`

### Step 1: Add shared_preferences dependency

**File:** `packages/screen_recorder/pubspec.yaml`

Add to dependencies:
```yaml
dependencies:
  # ... existing dependencies ...
  shared_preferences: ^2.2.0
```

Run:
```bash
cd packages/screen_recorder
flutter pub get
```

### Step 2: Write failing test for FrameSettingsProvider

**File:** `packages/screen_recorder/test/state/frame_settings_provider_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('FrameSettingsProvider', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
    });

    test('should load default frame on init', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      expect(provider.currentFrame, isNotNull);
      expect(provider.currentFrame.name, 'None');
    });

    test('should save and load custom frame', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      final customFrame = WindowFrame.rounded().copyWith(
        cornerRadius: 24.0,
        padding: const EdgeInsets.all(50),
      );

      await provider.setFrame(customFrame);

      // Create new provider to test persistence
      final provider2 = FrameSettingsProvider();
      await provider2.load();

      expect(provider2.currentFrame.cornerRadius, 24.0);
      expect(provider2.currentFrame.padding, const EdgeInsets.all(50));
    });

    test('should update frame properties individually', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      await provider.setFrame(WindowFrame.rounded());

      await provider.updatePadding(const EdgeInsets.all(60));
      expect(provider.currentFrame.padding, const EdgeInsets.all(60));

      await provider.updateCornerRadius(20.0);
      expect(provider.currentFrame.cornerRadius, 20.0);

      await provider.updateShadowBlur(50.0);
      expect(provider.currentFrame.shadowBlur, 50.0);
    });

    test('should select from templates', () async {
      final provider = FrameSettingsProvider();
      await provider.load();

      await provider.selectTemplate(WindowFrame.modern());
      expect(provider.currentFrame.name, 'Modern');

      await provider.selectTemplate(WindowFrame.minimal());
      expect(provider.currentFrame.name, 'Minimal');
    });
  });
}
```

### Step 3: Run test to verify it fails

```bash
cd packages/screen_recorder
flutter test test/state/frame_settings_provider_test.dart
```

**Expected:** FAIL with "Target of URI doesn't exist"

### Step 4: Implement FrameSettingsProvider

**File:** `packages/screen_recorder/lib/state/frame_settings_provider.dart`

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/models/window_frame.dart';

/// Manages window frame settings with persistence
class FrameSettingsProvider extends ChangeNotifier {
  static const String _storageKey = 'window_frame_settings';

  WindowFrame _currentFrame = WindowFrame.none();

  WindowFrame get currentFrame => _currentFrame;

  /// Load saved settings from SharedPreferences
  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = prefs.getString(_storageKey);

    if (jsonString != null) {
      try {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        _currentFrame = WindowFrame.fromJson(json);
      } catch (e) {
        // Fallback to default if parsing fails
        _currentFrame = WindowFrame.none();
      }
    }

    notifyListeners();
  }

  /// Set complete frame and save
  Future<void> setFrame(WindowFrame frame) async {
    _currentFrame = frame;
    await _save();
    notifyListeners();
  }

  /// Select a template
  Future<void> selectTemplate(WindowFrame template) async {
    await setFrame(template);
  }

  /// Update padding only
  Future<void> updatePadding(EdgeInsets padding) async {
    _currentFrame = _currentFrame.copyWith(padding: padding);
    await _save();
    notifyListeners();
  }

  /// Update corner radius only
  Future<void> updateCornerRadius(double radius) async {
    _currentFrame = _currentFrame.copyWith(cornerRadius: radius);
    await _save();
    notifyListeners();
  }

  /// Update shadow blur only
  Future<void> updateShadowBlur(double blur) async {
    _currentFrame = _currentFrame.copyWith(shadowBlur: blur);
    await _save();
    notifyListeners();
  }

  /// Update background color
  Future<void> updateBackgroundColor(Color color) async {
    _currentFrame = _currentFrame.copyWith(backgroundColor: color);
    await _save();
    notifyListeners();
  }

  /// Save to SharedPreferences
  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonString = jsonEncode(_currentFrame.toJson());
    await prefs.setString(_storageKey, jsonString);
  }
}
```

### Step 5: Run test to verify it passes

```bash
cd packages/screen_recorder
flutter test test/state/frame_settings_provider_test.dart
```

**Expected:** All 4 tests PASS

### Step 6: Create SettingsScreen

**File:** `packages/screen_recorder/lib/ui/screens/settings_screen.dart`

```dart
import 'package:flutter/material.dart';
import 'package:screen_recorder/models/window_frame.dart';
import 'package:screen_recorder/state/frame_settings_provider.dart';

class SettingsScreen extends StatefulWidget {
  final FrameSettingsProvider settingsProvider;

  const SettingsScreen({
    super.key,
    required this.settingsProvider,
  });

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1E1E2E),
      appBar: AppBar(
        title: const Text('Frame Settings'),
        backgroundColor: const Color(0xFF2B2B3D),
        elevation: 0,
      ),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          _buildTemplateSelector(),
          const SizedBox(height: 32),
          _buildPaddingSlider(),
          const SizedBox(height: 24),
          _buildCornerRadiusSlider(),
          const SizedBox(height: 24),
          _buildShadowBlurSlider(),
          const SizedBox(height: 24),
          _buildColorPicker(),
        ],
      ),
    );
  }

  Widget _buildTemplateSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Frame Template',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: WindowFrame.templates.map((template) {
            final isSelected =
                widget.settingsProvider.currentFrame.name == template.name;

            return ChoiceChip(
              label: Text(template.name),
              selected: isSelected,
              onSelected: (selected) {
                if (selected) {
                  widget.settingsProvider.selectTemplate(template);
                  setState(() {});
                }
              },
              selectedColor: const Color(0xFF6C63FF),
              backgroundColor: const Color(0xFF2B2B3D),
              labelStyle: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }

  Widget _buildPaddingSlider() {
    final currentPadding =
        widget.settingsProvider.currentFrame.padding.left; // Assuming uniform

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Padding: ${currentPadding.toInt()}px',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Slider(
          value: currentPadding,
          min: 0,
          max: 100,
          divisions: 20,
          activeColor: const Color(0xFF6C63FF),
          onChanged: (value) {
            widget.settingsProvider.updatePadding(EdgeInsets.all(value));
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildCornerRadiusSlider() {
    final currentRadius = widget.settingsProvider.currentFrame.cornerRadius;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Corner Radius: ${currentRadius.toInt()}px',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Slider(
          value: currentRadius,
          min: 0,
          max: 32,
          divisions: 16,
          activeColor: const Color(0xFF6C63FF),
          onChanged: (value) {
            widget.settingsProvider.updateCornerRadius(value);
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildShadowBlurSlider() {
    final currentBlur = widget.settingsProvider.currentFrame.shadowBlur;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Shadow Blur: ${currentBlur.toInt()}px',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Slider(
          value: currentBlur,
          min: 0,
          max: 80,
          divisions: 16,
          activeColor: const Color(0xFF6C63FF),
          onChanged: (value) {
            widget.settingsProvider.updateShadowBlur(value);
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _buildColorPicker() {
    final currentColor = widget.settingsProvider.currentFrame.backgroundColor;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Background Color',
          style: TextStyle(
            color: Colors.white,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            Colors.white,
            Colors.grey.shade100,
            Colors.black,
            Colors.blue.shade100,
            Colors.purple.shade100,
            Colors.transparent,
          ].map((color) {
            final isSelected = currentColor == color;

            return GestureDetector(
              onTap: () {
                widget.settingsProvider.updateBackgroundColor(color);
                setState(() {});
              },
              child: Container(
                width: 48,
                height: 48,
                decoration: BoxDecoration(
                  color: color == Colors.transparent
                      ? Colors.grey.shade800
                      : color,
                  border: Border.all(
                    color: isSelected
                        ? const Color(0xFF6C63FF)
                        : Colors.white24,
                    width: isSelected ? 3 : 1,
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: color == Colors.transparent
                    ? const Icon(Icons.block, color: Colors.white54, size: 24)
                    : null,
              ),
            );
          }).toList(),
        ),
      ],
    );
  }
}
```

### Step 7: Update PlaybackScreen to use FrameSettingsProvider

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add to class:
```dart
import 'package:screen_recorder/state/frame_settings_provider.dart';
import 'package:screen_recorder/ui/screens/settings_screen.dart';

class _PlaybackScreenState extends State<PlaybackScreen> {
  // ... existing state ...
  late FrameSettingsProvider _frameSettings;

  @override
  void initState() {
    super.initState();
    _undoRedo = UndoRedoController<TrimSelection>();
    _frameSettings = FrameSettingsProvider();
    _frameSettings.load();
    _frameSettings.addListener(() {
      setState(() {}); // Rebuild when frame settings change
    });
    _initializeVideo();
  }

  @override
  void dispose() {
    _controller.dispose();
    _frameSettings.dispose();
    super.dispose();
  }
}
```

Replace `_toggleFrameSelector()` with navigation to settings:
```dart
void _openFrameSettings() {
  Navigator.of(context).push(
    MaterialPageRoute(
      builder: (_) => SettingsScreen(settingsProvider: _frameSettings),
    ),
  );
}
```

Update button:
```dart
IconButton(
  onPressed: _openFrameSettings,
  icon: const Icon(Icons.settings),
  color: Colors.white70,
  tooltip: 'Frame Settings',
),
```

Update `_buildVideoPlayer` to use `_frameSettings.currentFrame` instead of `_selectedFrame`.

### Step 8: Run app and verify settings screen

```bash
cd packages/screen_recorder
flutter run -d macos
```

**Expected:**
- Click settings button to open frame settings
- Select different templates
- Adjust padding, corner radius, shadow sliders
- Changes appear immediately in video preview
- Settings persist after app restart

### Step 9: Commit

```bash
git add lib/ui/screens/settings_screen.dart lib/state/frame_settings_provider.dart test/state/frame_settings_provider_test.dart lib/ui/screens/playback_screen.dart pubspec.yaml
git commit -m "feat: add frame customization UI with settings"
```

---

## Task 28: Export Presets

**Goal:** Create export preset model (resolution, framerate, quality). Add preset selector to export dialog. Implement preset persistence.

**Files:**
- Create: `packages/screen_recorder/lib/models/export_preset.dart`
- Create: `packages/screen_recorder/test/models/export_preset_test.dart`
- Create: `packages/screen_recorder/lib/ui/widgets/export_dialog.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

### Step 1: Write failing test for ExportPreset model

**File:** `packages/screen_recorder/test/models/export_preset_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/export_preset.dart';

void main() {
  group('ExportPreset', () {
    test('should create preset with all properties', () {
      final preset = ExportPreset(
        name: 'Custom',
        width: 1920,
        height: 1080,
        fps: 60,
        quality: 0.85,
      );

      expect(preset.name, 'Custom');
      expect(preset.width, 1920);
      expect(preset.height, 1080);
      expect(preset.fps, 60);
      expect(preset.quality, 0.85);
    });

    test('should create 1080p 30fps preset', () {
      final preset = ExportPreset.hd1080p30();

      expect(preset.name, '1080p 30fps');
      expect(preset.width, 1920);
      expect(preset.height, 1080);
      expect(preset.fps, 30);
      expect(preset.quality, greaterThan(0.7));
    });

    test('should create 1080p 60fps preset', () {
      final preset = ExportPreset.hd1080p60();

      expect(preset.name, '1080p 60fps');
      expect(preset.width, 1920);
      expect(preset.height, 1080);
      expect(preset.fps, 60);
    });

    test('should create 4K 30fps preset', () {
      final preset = ExportPreset.uhd4k30();

      expect(preset.name, '4K 30fps');
      expect(preset.width, 3840);
      expect(preset.height, 2160);
      expect(preset.fps, 30);
    });

    test('should create 4K 60fps preset', () {
      final preset = ExportPreset.uhd4k60();

      expect(preset.name, '4K 60fps');
      expect(preset.width, 3840);
      expect(preset.height, 2160);
      expect(preset.fps, 60);
    });

    test('should create web optimized preset', () {
      final preset = ExportPreset.webOptimized();

      expect(preset.name, 'Web (720p)');
      expect(preset.width, 1280);
      expect(preset.height, 720);
      expect(preset.fps, 30);
      expect(preset.quality, lessThan(0.8)); // Lower quality for web
    });

    test('should serialize to and from JSON', () {
      final preset = ExportPreset(
        name: 'Test',
        width: 2560,
        height: 1440,
        fps: 60,
        quality: 0.9,
      );

      final json = preset.toJson();
      final restored = ExportPreset.fromJson(json);

      expect(restored.name, preset.name);
      expect(restored.width, preset.width);
      expect(restored.height, preset.height);
      expect(restored.fps, preset.fps);
      expect(restored.quality, preset.quality);
    });

    test('should provide all built-in presets', () {
      final presets = ExportPreset.presets;

      expect(presets.length, greaterThanOrEqualTo(5));
      expect(presets.any((p) => p.name.contains('1080p')), true);
      expect(presets.any((p) => p.name.contains('4K')), true);
      expect(presets.any((p) => p.name.contains('Web')), true);
    });
  });
}
```

### Step 2: Run test to verify it fails

```bash
cd packages/screen_recorder
flutter test test/models/export_preset_test.dart
```

**Expected:** FAIL with "Target of URI doesn't exist"

### Step 3: Implement ExportPreset model

**File:** `packages/screen_recorder/lib/models/export_preset.dart`

```dart
/// Export preset defining resolution, framerate, and quality
class ExportPreset {
  final String name;
  final int width;
  final int height;
  final int fps;
  final double quality; // 0.0 to 1.0

  const ExportPreset({
    required this.name,
    required this.width,
    required this.height,
    required this.fps,
    required this.quality,
  });

  /// 1080p 30fps - Standard quality
  factory ExportPreset.hd1080p30() {
    return const ExportPreset(
      name: '1080p 30fps',
      width: 1920,
      height: 1080,
      fps: 30,
      quality: 0.85,
    );
  }

  /// 1080p 60fps - High quality
  factory ExportPreset.hd1080p60() {
    return const ExportPreset(
      name: '1080p 60fps',
      width: 1920,
      height: 1080,
      fps: 60,
      quality: 0.90,
    );
  }

  /// 4K 30fps - Ultra quality
  factory ExportPreset.uhd4k30() {
    return const ExportPreset(
      name: '4K 30fps',
      width: 3840,
      height: 2160,
      fps: 30,
      quality: 0.90,
    );
  }

  /// 4K 60fps - Maximum quality
  factory ExportPreset.uhd4k60() {
    return const ExportPreset(
      name: '4K 60fps',
      width: 3840,
      height: 2160,
      fps: 60,
      quality: 0.95,
    );
  }

  /// 720p 30fps - Web optimized
  factory ExportPreset.webOptimized() {
    return const ExportPreset(
      name: 'Web (720p)',
      width: 1280,
      height: 720,
      fps: 30,
      quality: 0.75,
    );
  }

  /// Get all built-in presets
  static List<ExportPreset> get presets => [
        ExportPreset.webOptimized(),
        ExportPreset.hd1080p30(),
        ExportPreset.hd1080p60(),
        ExportPreset.uhd4k30(),
        ExportPreset.uhd4k60(),
      ];

  /// Convert to JSON for persistence
  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'width': width,
      'height': height,
      'fps': fps,
      'quality': quality,
    };
  }

  /// Create from JSON
  factory ExportPreset.fromJson(Map<String, dynamic> json) {
    return ExportPreset(
      name: json['name'] as String,
      width: json['width'] as int,
      height: json['height'] as int,
      fps: json['fps'] as int,
      quality: json['quality'] as double,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ExportPreset &&
          runtimeType == other.runtimeType &&
          name == other.name &&
          width == other.width &&
          height == other.height &&
          fps == other.fps &&
          quality == other.quality;

  @override
  int get hashCode =>
      name.hashCode ^
      width.hashCode ^
      height.hashCode ^
      fps.hashCode ^
      quality.hashCode;
}
```

### Step 4: Run test to verify it passes

```bash
cd packages/screen_recorder
flutter test test/models/export_preset_test.dart
```

**Expected:** All 8 tests PASS

### Step 5: Create ExportDialog widget

**File:** `packages/screen_recorder/lib/ui/widgets/export_dialog.dart`

```dart
import 'package:flutter/material.dart';
import 'package:screen_recorder/models/export_preset.dart';

class ExportDialog extends StatefulWidget {
  const ExportDialog({super.key});

  @override
  State<ExportDialog> createState() => _ExportDialogState();
}

class _ExportDialogState extends State<ExportDialog> {
  ExportPreset _selectedPreset = ExportPreset.hd1080p30();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF2B2B3D),
      title: const Text(
        'Export Video',
        style: TextStyle(color: Colors.white),
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Select Export Quality',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 16),
            ...ExportPreset.presets.map((preset) {
              return RadioListTile<ExportPreset>(
                title: Text(
                  preset.name,
                  style: const TextStyle(color: Colors.white),
                ),
                subtitle: Text(
                  '${preset.width}x${preset.height} @ ${preset.fps}fps',
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
                ),
                value: preset,
                groupValue: _selectedPreset,
                activeColor: const Color(0xFF6C63FF),
                onChanged: (value) {
                  setState(() {
                    _selectedPreset = value!;
                  });
                },
              );
            }),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text(
            'Cancel',
            style: TextStyle(color: Colors.white70),
          ),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(context).pop(_selectedPreset),
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xFF6C63FF),
          ),
          child: const Text('Export'),
        ),
      ],
    );
  }
}
```

### Step 6: Add export button to PlaybackScreen

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add import:
```dart
import 'package:screen_recorder/models/export_preset.dart';
import 'package:screen_recorder/ui/widgets/export_dialog.dart';
```

Add export button to controls (after Record Another button):

```dart
ElevatedButton.icon(
  onPressed: _showExportDialog,
  icon: const Icon(Icons.file_download),
  label: const Text('Export'),
  style: ElevatedButton.styleFrom(
    backgroundColor: const Color(0xFF4CAF50),
    padding: const EdgeInsets.symmetric(
      horizontal: 24,
      vertical: 16,
    ),
  ),
),
```

Add export dialog method:
```dart
Future<void> _showExportDialog() async {
  final preset = await showDialog<ExportPreset>(
    context: context,
    builder: (context) => const ExportDialog(),
  );

  if (preset != null && mounted) {
    // TODO: Implement actual export with preset
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Exporting with ${preset.name}...'),
        backgroundColor: const Color(0xFF4CAF50),
      ),
    );
  }
}
```

### Step 7: Run app and verify export dialog

```bash
cd packages/screen_recorder
flutter run -d macos
```

**Expected:**
- Click Export button
- Dialog shows 5 preset options
- Selecting preset and clicking Export shows snackbar
- Can cancel dialog

### Step 8: Commit

```bash
git add lib/models/export_preset.dart test/models/export_preset_test.dart lib/ui/widgets/export_dialog.dart lib/ui/screens/playback_screen.dart
git commit -m "feat: add export presets with quality selector"
```

---

## Completion Checklist

After completing all tasks:

- [ ] All 22 tests passing (8 frame model + 6 frame painter + 4 settings provider + 8 export preset)
- [ ] Frame templates render correctly (rounded, modern, minimal, none)
- [ ] Live preview shows frames during playback
- [ ] Settings screen allows frame customization
- [ ] Settings persist across app restarts
- [ ] Export dialog shows quality presets
- [ ] All UI elements match design (dark theme, purple accents)

**Validation Command:**
```bash
cd packages/screen_recorder
flutter test
flutter run -d macos
```

**Expected Results:**
- All tests pass
- App launches without errors
- Can customize frames and see changes in real-time
- Settings persist after restart
- Export dialog functional

---

## Notes for Implementation

**Design Decisions:**
- Frame padding is uniform (all sides equal) for simplicity
- Shadow rendering uses MaskFilter blur instead of multiple layers for performance
- Settings persist to SharedPreferences (simple key-value storage)
- Frame rendering happens on main thread (acceptable for 60fps with CustomPainter)

**Future Enhancements (Not in Phase 7):**
- Export with baked-in frames (requires frame compositor integration)
- Custom frame templates (user-created)
- Gradient backgrounds
- Frame animations (fade in/out)
- Per-side padding controls

**Performance Considerations:**
- CustomPainter is hardware-accelerated
- Frame settings updates trigger rebuild but not full repaint
- SharedPreferences saves are async (non-blocking)
- Export presets are immutable (no unnecessary copies)

**Testing Strategy:**
- Unit tests for all models (WindowFrame, ExportPreset)
- Widget tests for CustomPainter (FramePainter)
- Integration tests for settings persistence (FrameSettingsProvider)
- Manual testing for visual appearance (frame rendering)

---

## Success Criteria

Phase 7 is complete when:
1. All 22 tests passing
2. Can select from 4 frame templates
3. Can customize padding, corner radius, shadow, and colors
4. Changes appear immediately in video preview
5. Settings persist across app restarts
6. Export dialog shows 5 quality presets
7. UI is polished and matches design system
