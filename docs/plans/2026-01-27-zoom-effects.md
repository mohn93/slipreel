# Phase 6: Zoom Effects Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add smooth zoom effects to highlight specific areas during video playback, with click-based region selection and animated transitions.

**Architecture:** Matrix transformation pipeline for zoom calculations, gesture detection for region selection, interpolated animation curves for smooth zoom transitions. Zoom markers on timeline with visual feedback. Integration with video_player transform for real-time zoom during playback.

**Tech Stack:** Flutter Transform widget, Matrix4 transformations, AnimationController with Curves, CustomPainter for zoom markers, GestureDetector for region selection

---

## Overview

Phase 6 adds professional zoom effects with:
- **Task 22**: Zoom region model and transformation algorithm
- **Task 23**: Click-based region selector UI
- **Task 24**: Smooth zoom animations with timeline integration

---

## Task 22: Zoom Region Model & Algorithm

**Goal:** Create zoom region model with transformation matrix calculations for smooth, frame-accurate zoom effects.

**Files:**
- Create: `packages/screen_recorder/lib/models/zoom_region.dart`
- Create: `packages/screen_recorder/test/models/zoom_region_test.dart`
- Create: `packages/screen_recorder/lib/effects/zoom_transformer.dart`
- Create: `packages/screen_recorder/test/effects/zoom_transformer_test.dart`

### Step 1: Write failing test for ZoomRegion model

**File:** `packages/screen_recorder/test/models/zoom_region_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/zoom_region.dart';

void main() {
  group('ZoomRegion', () {
    test('should create zoom region with valid rect and timing', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 3),
        zoomLevel: 2.0,
      );

      expect(region.rect, const Rect.fromLTWH(100, 100, 200, 150));
      expect(region.startTime, const Duration(seconds: 2));
      expect(region.duration, const Duration(seconds: 3));
      expect(region.endTime, const Duration(seconds: 5));
      expect(region.zoomLevel, 2.0);
    });

    test('should check if position is within zoom region', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 3),
        zoomLevel: 2.0,
      );

      expect(region.isActive(const Duration(seconds: 1)), false);
      expect(region.isActive(const Duration(seconds: 3)), true);
      expect(region.isActive(const Duration(seconds: 6)), false);
    });

    test('should calculate progress within zoom region', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 4),
        zoomLevel: 2.0,
      );

      expect(region.getProgress(const Duration(seconds: 2)), 0.0);
      expect(region.getProgress(const Duration(seconds: 4)), 0.5);
      expect(region.getProgress(const Duration(seconds: 6)), 1.0);
    });

    test('should constrain to video bounds', () {
      final region = ZoomRegion(
        rect: const Rect.fromLTWH(-10, -10, 1000, 1000),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 3),
        zoomLevel: 2.0,
        videoBounds: const Size(800, 600),
      );

      expect(region.rect.left, greaterThanOrEqualTo(0));
      expect(region.rect.top, greaterThanOrEqualTo(0));
      expect(region.rect.right, lessThanOrEqualTo(800));
      expect(region.rect.bottom, lessThanOrEqualTo(600));
    });

    test('should clamp zoom level between 1.0 and 5.0', () {
      final region1 = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 0.5, // Too low
      );

      final region2 = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 10.0, // Too high
      );

      expect(region1.zoomLevel, 1.0);
      expect(region2.zoomLevel, 5.0);
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/models/zoom_region_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist"

### Step 2: Implement ZoomRegion model

**File:** `packages/screen_recorder/lib/models/zoom_region.dart`

```dart
import 'package:flutter/material.dart';

/// Represents a zoom region with timing and transformation parameters
class ZoomRegion {
  final Rect rect;
  final Duration startTime;
  final Duration duration;
  final double zoomLevel;

  ZoomRegion({
    required Rect rect,
    required this.startTime,
    required this.duration,
    required double zoomLevel,
    Size? videoBounds,
  })  : rect = videoBounds != null ? _constrainRect(rect, videoBounds) : rect,
        zoomLevel = zoomLevel.clamp(1.0, 5.0);

  /// End time of zoom effect
  Duration get endTime => startTime + duration;

  /// Check if position is within zoom region
  bool isActive(Duration position) {
    return position >= startTime && position <= endTime;
  }

  /// Get progress within zoom region (0.0 to 1.0)
  double getProgress(Duration position) {
    if (position < startTime) return 0.0;
    if (position > endTime) return 1.0;

    final elapsed = position - startTime;
    return (elapsed.inMicroseconds / duration.inMicroseconds).clamp(0.0, 1.0);
  }

  /// Create copy with updated values
  ZoomRegion copyWith({
    Rect? rect,
    Duration? startTime,
    Duration? duration,
    double? zoomLevel,
    Size? videoBounds,
  }) {
    return ZoomRegion(
      rect: rect ?? this.rect,
      startTime: startTime ?? this.startTime,
      duration: duration ?? this.duration,
      zoomLevel: zoomLevel ?? this.zoomLevel,
      videoBounds: videoBounds,
    );
  }

  static Rect _constrainRect(Rect rect, Size bounds) {
    final left = rect.left.clamp(0.0, bounds.width);
    final top = rect.top.clamp(0.0, bounds.height);
    final right = rect.right.clamp(0.0, bounds.width);
    final bottom = rect.bottom.clamp(0.0, bounds.height);

    return Rect.fromLTRB(left, top, right, bottom);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZoomRegion &&
          runtimeType == other.runtimeType &&
          rect == other.rect &&
          startTime == other.startTime &&
          duration == other.duration &&
          zoomLevel == other.zoomLevel;

  @override
  int get hashCode =>
      rect.hashCode ^
      startTime.hashCode ^
      duration.hashCode ^
      zoomLevel.hashCode;
}
```

**Run:** `cd packages/screen_recorder && flutter test test/models/zoom_region_test.dart`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/models/zoom_region.dart \
  packages/screen_recorder/test/models/zoom_region_test.dart
git commit -m "feat: add ZoomRegion model for zoom effects

- Create ZoomRegion with rect, timing, and zoom level
- Calculate progress within zoom duration
- Constrain region to video bounds
- Clamp zoom level between 1.0 and 5.0
- Check if position is within zoom region
- Test boundary conditions and constraints"
```

### Step 3: Write failing test for ZoomTransformer

**File:** `packages/screen_recorder/test/effects/zoom_transformer_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/effects/zoom_transformer.dart';
import 'package:screen_recorder/models/zoom_region.dart';

void main() {
  group('ZoomTransformer', () {
    test('should return identity matrix when no zoom is active', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(100, 100, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 1), // Before zoom starts
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      expect(matrix, Matrix4.identity());
    });

    test('should calculate zoom transform at peak', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(200, 150, 200, 150),
        startTime: const Duration(seconds: 2),
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 3), // At 0.5 progress (peak)
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // At peak, should have maximum zoom
      expect(matrix, isNot(Matrix4.identity()));

      // Scale component should reflect zoom level
      final scale = matrix.getMaxScaleOnAxis();
      expect(scale, greaterThan(1.0));
    });

    test('should apply ease-in-out curve', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(200, 150, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrixStart = transformer.getTransform(
        position: const Duration(milliseconds: 100),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      final matrixMid = transformer.getTransform(
        position: const Duration(seconds: 1),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // Scale should be less at start than at middle (ease-in-out)
      expect(
        matrixStart.getMaxScaleOnAxis(),
        lessThan(matrixMid.getMaxScaleOnAxis()),
      );
    });

    test('should center zoom on rect center', () {
      final transformer = ZoomTransformer();
      final zoomRegion = ZoomRegion(
        rect: const Rect.fromLTWH(300, 200, 200, 150),
        startTime: Duration.zero,
        duration: const Duration(seconds: 2),
        zoomLevel: 2.0,
      );

      final matrix = transformer.getTransform(
        position: const Duration(seconds: 1),
        zoomRegion: zoomRegion,
        videoSize: const Size(800, 600),
      );

      // Translation should be non-zero (centering the zoom)
      expect(matrix.getTranslation().x, isNot(0.0));
      expect(matrix.getTranslation().y, isNot(0.0));
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/effects/zoom_transformer_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist"

### Step 4: Implement ZoomTransformer

**File:** `packages/screen_recorder/lib/effects/zoom_transformer.dart`

```dart
import 'package:flutter/material.dart';
import 'package:screen_recorder/models/zoom_region.dart';

/// Calculates transformation matrices for zoom effects
class ZoomTransformer {
  /// Get transformation matrix for given position and zoom region
  Matrix4 getTransform({
    required Duration position,
    required ZoomRegion zoomRegion,
    required Size videoSize,
  }) {
    // Return identity if zoom is not active
    if (!zoomRegion.isActive(position)) {
      return Matrix4.identity();
    }

    // Get progress within zoom region (0.0 to 1.0)
    final rawProgress = zoomRegion.getProgress(position);

    // Apply ease-in-out curve for smooth animation
    // Zoom in during first half, zoom out during second half
    final curvedProgress = _easeInOutCurve(rawProgress);

    // Calculate zoom factor (1.0 to zoomLevel and back to 1.0)
    final zoomFactor = _calculateZoomFactor(
      curvedProgress,
      zoomRegion.zoomLevel,
    );

    // Calculate center of zoom region
    final zoomCenter = zoomRegion.rect.center;

    // Calculate video center
    final videoCenter = Offset(videoSize.width / 2, videoSize.height / 2);

    // Calculate translation to center zoom region
    final translation = _calculateTranslation(
      zoomCenter: zoomCenter,
      videoCenter: videoCenter,
      zoomFactor: zoomFactor,
    );

    // Build transformation matrix
    final matrix = Matrix4.identity()
      ..translate(translation.dx, translation.dy)
      ..scale(zoomFactor, zoomFactor, 1.0)
      ..translate(-translation.dx, -translation.dy);

    return matrix;
  }

  /// Apply ease-in-out curve
  double _easeInOutCurve(double t) {
    if (t < 0.5) {
      return 2 * t * t;
    } else {
      return 1 - 2 * (1 - t) * (1 - t);
    }
  }

  /// Calculate zoom factor for given progress
  /// Zooms in during first half, zooms out during second half
  double _calculateZoomFactor(double progress, double maxZoom) {
    // Use sine wave for smooth zoom in/out
    // Progress 0.0 -> 1.0, sine gives smooth curve
    final sineProgress = (1 - (progress * 2 - 1).abs());
    return 1.0 + (maxZoom - 1.0) * sineProgress;
  }

  /// Calculate translation to center zoom on target region
  Offset _calculateTranslation({
    required Offset zoomCenter,
    required Offset videoCenter,
    required double zoomFactor,
  }) {
    // Calculate offset from video center to zoom center
    final offset = zoomCenter - videoCenter;

    // Scale offset by zoom factor to keep region centered
    return Offset(
      videoCenter.dx - offset.dx * zoomFactor,
      videoCenter.dy - offset.dy * zoomFactor,
    );
  }
}
```

**Run:** `cd packages/screen_recorder && flutter test test/effects/zoom_transformer_test.dart`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/effects/zoom_transformer.dart \
  packages/screen_recorder/test/effects/zoom_transformer_test.dart
git commit -m "feat: add ZoomTransformer for smooth zoom calculations

- Calculate Matrix4 transform for zoom effects
- Apply ease-in-out curve for smooth animation
- Center zoom on target region
- Zoom in during first half, zoom out during second half
- Test transform calculations and centering"
```

---

## Task 23: Click-Based Region Selector

**Goal:** Add UI for selecting zoom regions by clicking on video, with visual rectangle overlay.

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/zoom/zoom_selector.dart`
- Create: `packages/screen_recorder/test/ui/widgets/zoom/zoom_selector_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

### Step 1: Write failing test for ZoomSelector widget

**File:** `packages/screen_recorder/test/ui/widgets/zoom/zoom_selector_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_selector.dart';

void main() {
  group('ZoomSelector', () {
    testWidgets('should render overlay when enabled', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomSelector(
              enabled: true,
              videoSize: const Size(800, 600),
              onRegionSelected: (rect) {},
              child: Container(
                width: 800,
                height: 600,
                color: Colors.black,
              ),
            ),
          ),
        ),
      );

      expect(find.byType(ZoomSelector), findsOneWidget);
    });

    testWidgets('should detect tap and create region', (tester) async {
      Rect? selectedRect;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomSelector(
              enabled: true,
              videoSize: const Size(800, 600),
              onRegionSelected: (rect) {
                selectedRect = rect;
              },
              child: Container(
                width: 800,
                height: 600,
                color: Colors.black,
              ),
            ),
          ),
        ),
      );

      // Tap to create zoom region
      await tester.tapAt(const Offset(400, 300));
      await tester.pump();

      expect(selectedRect, isNotNull);
      expect(selectedRect!.center, const Offset(400, 300));
    });

    testWidgets('should allow dragging to resize region', (tester) async {
      Rect? selectedRect;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ZoomSelector(
              enabled: true,
              videoSize: const Size(800, 600),
              onRegionSelected: (rect) {
                selectedRect = rect;
              },
              child: Container(
                width: 800,
                height: 600,
                color: Colors.black,
              ),
            ),
          ),
        ),
      );

      // Drag to create region
      await tester.dragFrom(
        const Offset(300, 250),
        const Offset(200, 150),
      );
      await tester.pump();

      expect(selectedRect, isNotNull);
      expect(selectedRect!.width, greaterThan(0));
      expect(selectedRect!.height, greaterThan(0));
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/zoom_selector_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist"

### Step 2: Implement ZoomSelector widget

**File:** `packages/screen_recorder/lib/ui/widgets/zoom/zoom_selector.dart`

```dart
import 'package:flutter/material.dart';

/// Widget for selecting zoom regions via tap or drag
class ZoomSelector extends StatefulWidget {
  final bool enabled;
  final Size videoSize;
  final ValueChanged<Rect> onRegionSelected;
  final Widget child;
  final double defaultRegionSize;

  const ZoomSelector({
    super.key,
    required this.enabled,
    required this.videoSize,
    required this.onRegionSelected,
    required this.child,
    this.defaultRegionSize = 200.0,
  });

  @override
  State<ZoomSelector> createState() => _ZoomSelectorState();
}

class _ZoomSelectorState extends State<ZoomSelector> {
  Rect? _currentRect;
  Offset? _dragStart;
  bool _isDragging = false;

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return widget.child;
    }

    return GestureDetector(
      onTapDown: (details) {
        if (!_isDragging) {
          _handleTap(details.localPosition);
        }
      },
      onPanStart: (details) {
        _dragStart = details.localPosition;
        _isDragging = true;
        setState(() {
          _currentRect = Rect.fromLTWH(
            details.localPosition.dx,
            details.localPosition.dy,
            0,
            0,
          );
        });
      },
      onPanUpdate: (details) {
        if (_dragStart != null) {
          final start = _dragStart!;
          final current = details.localPosition;

          setState(() {
            _currentRect = Rect.fromPoints(start, current);
          });
        }
      },
      onPanEnd: (details) {
        if (_currentRect != null && _currentRect!.width > 10 && _currentRect!.height > 10) {
          widget.onRegionSelected(_normalizeRect(_currentRect!));
        }
        setState(() {
          _currentRect = null;
          _dragStart = null;
          _isDragging = false;
        });
      },
      child: Stack(
        children: [
          widget.child,
          if (_currentRect != null)
            CustomPaint(
              size: widget.videoSize,
              painter: _ZoomSelectorPainter(_currentRect!),
            ),
        ],
      ),
    );
  }

  void _handleTap(Offset position) {
    // Create default sized region centered on tap
    final halfSize = widget.defaultRegionSize / 2;
    final rect = Rect.fromLTWH(
      (position.dx - halfSize).clamp(0, widget.videoSize.width - widget.defaultRegionSize),
      (position.dy - halfSize).clamp(0, widget.videoSize.height - widget.defaultRegionSize),
      widget.defaultRegionSize,
      widget.defaultRegionSize,
    );

    widget.onRegionSelected(rect);
  }

  Rect _normalizeRect(Rect rect) {
    // Ensure rect has positive width/height
    final left = rect.left < rect.right ? rect.left : rect.right;
    final top = rect.top < rect.bottom ? rect.top : rect.bottom;
    final right = rect.left < rect.right ? rect.right : rect.left;
    final bottom = rect.top < rect.bottom ? rect.bottom : rect.top;

    return Rect.fromLTRB(
      left.clamp(0, widget.videoSize.width),
      top.clamp(0, widget.videoSize.height),
      right.clamp(0, widget.videoSize.width),
      bottom.clamp(0, widget.videoSize.height),
    );
  }
}

class _ZoomSelectorPainter extends CustomPainter {
  final Rect rect;

  _ZoomSelectorPainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    // Draw semi-transparent overlay
    final overlayPaint = Paint()
      ..color = const Color(0xFF6C63FF).withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;

    canvas.drawRect(rect, overlayPaint);

    // Draw border
    final borderPaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2;

    canvas.drawRect(rect, borderPaint);

    // Draw corner handles
    final handlePaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    const handleSize = 8.0;
    final corners = [
      rect.topLeft,
      rect.topRight,
      rect.bottomLeft,
      rect.bottomRight,
    ];

    for (final corner in corners) {
      canvas.drawCircle(corner, handleSize, handlePaint);
    }
  }

  @override
  bool shouldRepaint(_ZoomSelectorPainter oldDelegate) {
    return oldDelegate.rect != rect;
  }
}
```

**Run:** `cd packages/screen_recorder && flutter test test/ui/widgets/zoom/zoom_selector_test.dart`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/widgets/zoom/zoom_selector.dart \
  packages/screen_recorder/test/ui/widgets/zoom/zoom_selector_test.dart
git commit -m "feat: add ZoomSelector widget for region selection

- Create ZoomSelector with tap and drag support
- Draw semi-transparent overlay with border
- Show corner handles for visual feedback
- Normalize rect to ensure positive dimensions
- Create default sized region on tap
- Test tap and drag interactions"
```

### Step 3: Integrate ZoomSelector into PlaybackScreen

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add zoom state and selector:

```dart
// Add imports at top:
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/ui/widgets/zoom/zoom_selector.dart';

// Add state variables after _undoRedo:
  List<ZoomRegion> _zoomRegions = [];
  bool _isSelectingZoom = false;

// Add method after _handleRedo():
  void _handleZoomRegionSelected(Rect rect) {
    if (!_isInitialized) return;

    // Create zoom region at current playback position
    final currentPosition = _controller.value.position;
    final zoomRegion = ZoomRegion(
      rect: rect,
      startTime: currentPosition,
      duration: const Duration(seconds: 2), // Default 2 second zoom
      zoomLevel: 2.0,
      videoBounds: Size(
        _controller.value.size.width,
        _controller.value.size.height,
      ),
    );

    setState(() {
      _zoomRegions = [..._zoomRegions, zoomRegion];
      _isSelectingZoom = false;
    });
  }

  void _toggleZoomSelector() {
    setState(() {
      _isSelectingZoom = !_isSelectingZoom;
    });
  }

// In _buildVideo(), wrap VideoPlayer with ZoomSelector:
  Widget _buildVideo() {
    return AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: ZoomSelector(
        enabled: _isSelectingZoom,
        videoSize: _controller.value.size,
        onRegionSelected: _handleZoomRegionSelected,
        child: VideoPlayer(_controller),
      ),
    );
  }

// Add zoom button to controls (after undo/redo buttons):
  IconButton(
    onPressed: _toggleZoomSelector,
    icon: Icon(_isSelectingZoom ? Icons.zoom_in : Icons.zoom_out_map),
    color: _isSelectingZoom ? const Color(0xFF6C63FF) : Colors.white70,
    tooltip: 'Add Zoom Effect',
  ),

// Add zoom count display:
  if (_zoomRegions.isNotEmpty) ...[
    const SizedBox(height: 8),
    Text(
      'Zoom effects: ${_zoomRegions.length}',
      style: const TextStyle(
        color: Colors.white70,
        fontSize: 12,
      ),
    ),
  ],
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:** Can toggle zoom selector, click/drag to create zoom regions

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: integrate zoom selector into playback screen

- Add zoom region state list
- Add toggle button for zoom selector mode
- Create zoom region at current playback position
- Display zoom effect count
- Wrap video player with ZoomSelector"
```

---

## Task 24: Zoom Animations & Timeline Markers

**Goal:** Apply zoom transforms during playback and show zoom markers on timeline.

**Files:**
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart`
- Create: `packages/screen_recorder/test/ui/widgets/timeline/timeline_painter_zoom_test.dart`

### Step 1: Write failing test for timeline zoom markers

**File:** `packages/screen_recorder/test/ui/widgets/timeline/timeline_painter_zoom_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/zoom_region.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_painter.dart';

void main() {
  group('TimelinePainter zoom markers', () {
    test('should repaint when zoom regions change', () {
      final painter1 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: [],
      );

      final painter2 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: [
          ZoomRegion(
            rect: const Rect.fromLTWH(100, 100, 200, 150),
            startTime: const Duration(seconds: 2),
            duration: const Duration(seconds: 2),
            zoomLevel: 2.0,
          ),
        ],
      );

      expect(painter1.shouldRepaint(painter2), true);
    });

    test('should not repaint when zoom regions unchanged', () {
      final zoomRegions = [
        ZoomRegion(
          rect: const Rect.fromLTWH(100, 100, 200, 150),
          startTime: const Duration(seconds: 2),
          duration: const Duration(seconds: 2),
          zoomLevel: 2.0,
        ),
      ];

      final painter1 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: zoomRegions,
      );

      final painter2 = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
        zoomRegions: zoomRegions,
      );

      expect(painter1.shouldRepaint(painter2), false);
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/timeline_painter_zoom_test.dart`

**Expected:** FAIL - TimelinePainter doesn't have zoomRegions parameter

### Step 2: Add zoom markers to TimelinePainter

**File:** `packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart`

```dart
// Add import at top:
import 'package:screen_recorder/models/zoom_region.dart';

// Add zoomRegions parameter to class:
class TimelinePainter extends CustomPainter {
  final Duration duration;
  final Duration position;
  final TrimSelection? trimSelection;
  final List<ZoomRegion> zoomRegions; // Add this

  TimelinePainter({
    required this.duration,
    required this.position,
    this.trimSelection,
    this.zoomRegions = const [], // Add this with default
  });

  // In paint method, after drawing trim selection/handles, add:
  @override
  void paint(Canvas canvas, Size size) {
    // ... existing code for trim selection, track, playhead ...

    // Draw zoom region markers
    if (zoomRegions.isNotEmpty && duration.inMicroseconds > 0) {
      for (final zoom in zoomRegions) {
        _drawZoomMarker(canvas, size, zoom);
      }
    }
  }

  void _drawZoomMarker(Canvas canvas, Size size, ZoomRegion zoom) {
    final startX = (zoom.startTime.inMicroseconds / duration.inMicroseconds) * size.width;
    final endX = (zoom.endTime.inMicroseconds / duration.inMicroseconds) * size.width;

    // Draw zoom region background
    final zoomPaint = Paint()
      ..color = const Color(0xFFFFAB00).withValues(alpha: 0.3)
      ..style = PaintingStyle.fill;

    canvas.drawRect(
      Rect.fromLTRB(startX, 0, endX, size.height),
      zoomPaint,
    );

    // Draw zoom icon at start
    final iconPaint = Paint()
      ..color = const Color(0xFFFFAB00)
      ..style = PaintingStyle.fill;

    // Draw simple zoom icon (magnifying glass)
    canvas.drawCircle(
      Offset(startX + 10, size.height / 2),
      6,
      iconPaint,
    );

    // Draw handle at start
    final handlePaint = Paint()
      ..color = const Color(0xFFFFAB00)
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(startX - 2, 0, 4, size.height),
        const Radius.circular(2),
      ),
      handlePaint,
    );
  }

  // Update shouldRepaint to include zoomRegions:
  @override
  bool shouldRepaint(TimelinePainter oldDelegate) {
    return oldDelegate.duration != duration ||
        oldDelegate.position != position ||
        oldDelegate.trimSelection != trimSelection ||
        oldDelegate.zoomRegions != zoomRegions; // Add this
  }
}
```

**Run:** `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/timeline_painter_zoom_test.dart`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart \
  packages/screen_recorder/test/ui/widgets/timeline/timeline_painter_zoom_test.dart
git commit -m "feat: add zoom markers to timeline painter

- Add zoomRegions parameter to TimelinePainter
- Draw zoom region background with orange color
- Draw zoom icon and handle at region start
- Update shouldRepaint to include zoomRegions
- Test repaint behavior with zoom regions"
```

### Step 3: Apply zoom transform during playback

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

```dart
// Add import at top:
import 'package:screen_recorder/effects/zoom_transformer.dart';

// Add field after _isSelectingZoom:
  final _zoomTransformer = ZoomTransformer();

// Update _buildVideo() to apply zoom transform:
  Widget _buildVideo() {
    // Get current zoom region if any
    ZoomRegion? activeZoom;
    if (_isInitialized) {
      final currentPosition = _controller.value.position;
      activeZoom = _zoomRegions.firstWhere(
        (zoom) => zoom.isActive(currentPosition),
        orElse: () => null as ZoomRegion,
      );
    }

    Widget videoWidget = VideoPlayer(_controller);

    // Apply zoom transform if active
    if (activeZoom != null) {
      final transform = _zoomTransformer.getTransform(
        position: _controller.value.position,
        zoomRegion: activeZoom,
        videoSize: _controller.value.size,
      );

      videoWidget = Transform(
        transform: transform,
        alignment: Alignment.center,
        child: videoWidget,
      );
    }

    return AspectRatio(
      aspectRatio: _controller.value.aspectRatio,
      child: ZoomSelector(
        enabled: _isSelectingZoom,
        videoSize: _controller.value.size,
        onRegionSelected: _handleZoomRegionSelected,
        child: videoWidget,
      ),
    );
  }

// Update TimelineWidget to pass zoom regions:
  TimelineWidget(
    duration: value.duration,
    position: value.position,
    onPositionChanged: (newPosition) {
      _controller.seekTo(newPosition);
    },
    trimSelection: _trimSelection,
    onTrimChanged: _handleTrimChanged,
    zoomRegions: _zoomRegions, // Add this
  ),

// Add listener to rebuild during playback (in initState after _controller.initialize()):
  _controller.addListener(() {
    if (_controller.value.isPlaying) {
      setState(() {}); // Force rebuild to update zoom transform
    }
  });
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:**
- Video zooms smoothly when playback reaches zoom region
- Zoom markers visible on timeline
- Zoom transform applies during playback

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: apply zoom transform during video playback

- Add ZoomTransformer instance
- Find active zoom region for current position
- Apply Transform widget with zoom matrix
- Add controller listener to rebuild during playback
- Pass zoom regions to TimelineWidget
- Test smooth zoom during playback"
```

### Step 4: Add zoom region management

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add delete button and click to select zoom regions:

```dart
// Add state variable for selected zoom:
  int? _selectedZoomIndex;

// Add method to delete zoom region:
  void _deleteSelectedZoom() {
    if (_selectedZoomIndex != null) {
      setState(() {
        _zoomRegions = List.from(_zoomRegions)..removeAt(_selectedZoomIndex!);
        _selectedZoomIndex = null;
      });
    }
  }

// Update zoom count display to show delete button:
  if (_zoomRegions.isNotEmpty) ...[
    const SizedBox(height: 8),
    Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'Zoom effects: ${_zoomRegions.length}',
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 12,
          ),
        ),
        if (_selectedZoomIndex != null) ...[
          const SizedBox(width: 16),
          IconButton(
            onPressed: _deleteSelectedZoom,
            icon: const Icon(Icons.delete),
            color: Colors.red,
            iconSize: 20,
            tooltip: 'Delete Zoom Effect',
          ),
        ],
      ],
    ),
  ],

// Add method to handle timeline zoom marker clicks (detect via position):
  void _checkZoomMarkerClick(Duration position) {
    // Find zoom region near clicked position (within 0.5 seconds)
    final tolerance = const Duration(milliseconds: 500);
    for (var i = 0; i < _zoomRegions.length; i++) {
      final zoom = _zoomRegions[i];
      if ((position - zoom.startTime).abs() < tolerance) {
        setState(() {
          _selectedZoomIndex = i;
        });
        return;
      }
    }
    setState(() {
      _selectedZoomIndex = null;
    });
  }

// Update timeline onPositionChanged to also check for zoom clicks:
  onPositionChanged: (newPosition) {
    _controller.seekTo(newPosition);
    _checkZoomMarkerClick(newPosition);
  },
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:**
- Can click near zoom marker on timeline to select it
- Delete button appears when zoom selected
- Can delete selected zoom region

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: add zoom region management and deletion

- Add selected zoom index state
- Detect zoom marker clicks on timeline
- Show delete button when zoom selected
- Delete zoom region on button click
- Test zoom selection and deletion"
```

---

## Success Criteria

Phase 6 is complete when:

✅ **Task 22**: ZoomRegion model and ZoomTransformer working
- Model stores rect, timing, and zoom level
- Transformer calculates smooth Matrix4 transforms
- All tests passing

✅ **Task 23**: ZoomSelector UI integrated
- Can click/drag on video to select region
- Visual overlay with border and handles
- Creates zoom regions at current playback position

✅ **Task 24**: Zoom effects applied during playback
- Video zooms smoothly when reaching zoom region
- Timeline shows zoom markers
- Can select and delete zoom regions

**Manual Testing:**
1. Record or load a video
2. Play video and pause at desired moment
3. Click "Add Zoom Effect" button
4. Click or drag on video to select region
5. Resume playback - video should zoom into selected region
6. Timeline should show orange zoom marker
7. Click near zoom marker to select it
8. Click delete button to remove zoom

---

## Phase 6 Notes

**Architecture Decisions:**
- Matrix4 transformations for zoom (instead of video cropping) - more performant
- Ease-in-out curve for natural zoom motion
- Orange color for zoom markers (distinct from purple trim)
- Default 2-second zoom duration (can be made configurable later)

**Performance Considerations:**
- Zoom calculations are lightweight (just matrix math)
- Transform widget is hardware-accelerated
- Listener rebuilds only during playback, not continuously

**Future Enhancements** (not in this phase):
- Adjustable zoom duration with timeline handles
- Multiple zoom levels (beyond 1.0-5.0 range)
- Zoom presets (2x, 3x, 5x quick buttons)
- Keyframe-based zoom with custom curves
- Export with zoom effects baked into video

---

**Plan complete!** Ready for execution via subagent-driven development.
