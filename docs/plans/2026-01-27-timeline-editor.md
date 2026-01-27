# Phase 5: Timeline Editor Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a professional timeline editor for video trimming, effect placement, and precise playback control.

**Architecture:** Flutter custom painter for timeline visualization, Riverpod for state management with undo/redo stack, keyboard shortcuts via Focus/RawKeyboard, frame-accurate seeking via VideoPlayerController.

**Tech Stack:** Flutter CustomPainter, Riverpod StateNotifier, video_player package, Dart Duration/Position math

---

## Overview

Phase 5 builds a timeline editor with:
- **Task 19**: Timeline widget with visual representation
- **Task 20**: Trim handles for start/end selection
- **Task 21**: Undo/redo system with keyboard shortcuts

---

## Task 19: Timeline Widget

**Goal:** Create a visual timeline widget showing video duration with playback scrubber.

**Files:**
- Create: `packages/screen_recorder/lib/ui/widgets/timeline/timeline_widget.dart`
- Create: `packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart`
- Create: `packages/screen_recorder/test/ui/widgets/timeline/timeline_widget_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

### Step 1: Write failing test for TimelineWidget

**File:** `packages/screen_recorder/test/ui/widgets/timeline/timeline_widget_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_widget.dart';

void main() {
  group('TimelineWidget', () {
    testWidgets('should render timeline with duration', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimelineWidget(
              duration: const Duration(seconds: 10),
              position: const Duration(seconds: 5),
              onPositionChanged: (_) {},
            ),
          ),
        ),
      );

      expect(find.byType(TimelineWidget), findsOneWidget);
    });

    testWidgets('should call onPositionChanged when tapped', (tester) async {
      Duration? newPosition;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: TimelineWidget(
              duration: const Duration(seconds: 10),
              position: const Duration(seconds: 5),
              onPositionChanged: (pos) {
                newPosition = pos;
              },
            ),
          ),
        ),
      );

      // Tap at the center (should be around 5 seconds for 10 second duration)
      await tester.tapAt(tester.getCenter(find.byType(TimelineWidget)));
      await tester.pump();

      expect(newPosition, isNotNull);
      expect(newPosition!.inSeconds, greaterThan(0));
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/timeline_widget_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist"

### Step 2: Create TimelineWidget

**File:** `packages/screen_recorder/lib/ui/widgets/timeline/timeline_widget.dart`

```dart
import 'package:flutter/material.dart';
import 'timeline_painter.dart';

/// Timeline widget for video playback control
class TimelineWidget extends StatelessWidget {
  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onPositionChanged;
  final double height;

  const TimelineWidget({
    super.key,
    required this.duration,
    required this.position,
    required this.onPositionChanged,
    this.height = 80,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (details) {
        _handleTap(details.localPosition);
      },
      onHorizontalDragUpdate: (details) {
        _handleTap(details.localPosition);
      },
      child: Container(
        height: height,
        decoration: BoxDecoration(
          color: const Color(0xFF2B2B3D),
          borderRadius: BorderRadius.circular(8),
        ),
        child: CustomPaint(
          painter: TimelinePainter(
            duration: duration,
            position: position,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  void _handleTap(Offset localPosition) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final width = box.size.width;
    final progress = (localPosition.dx / width).clamp(0.0, 1.0);
    final newPosition = Duration(
      microseconds: (duration.inMicroseconds * progress).round(),
    );
    onPositionChanged(newPosition);
  }
}
```

**Run:** `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/timeline_widget_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist: 'timeline_painter.dart'"

### Step 3: Write failing test for TimelinePainter

**File:** `packages/screen_recorder/test/ui/widgets/timeline/timeline_painter_test.dart`

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/widgets/timeline/timeline_painter.dart';

void main() {
  group('TimelinePainter', () {
    test('should calculate progress correctly', () {
      final painter = TimelinePainter(
        duration: const Duration(seconds: 10),
        position: const Duration(seconds: 5),
      );

      expect(painter.progress, 0.5);
    });

    test('should handle zero duration', () {
      final painter = TimelinePainter(
        duration: Duration.zero,
        position: Duration.zero,
      );

      expect(painter.progress, 0.0);
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/ui/widgets/timeline/timeline_painter_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist"

### Step 4: Create TimelinePainter

**File:** `packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart`

```dart
import 'package:flutter/material.dart';

/// Custom painter for timeline visualization
class TimelinePainter extends CustomPainter {
  final Duration duration;
  final Duration position;

  TimelinePainter({
    required this.duration,
    required this.position,
  });

  double get progress {
    if (duration.inMicroseconds == 0) return 0.0;
    return position.inMicroseconds / duration.inMicroseconds;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final progressValue = progress.clamp(0.0, 1.0);

    // Draw background track
    final backgroundPaint = Paint()
      ..color = const Color(0xFF1E1E2E)
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height / 2 - 2, size.width, 4),
        const Radius.circular(2),
      ),
      backgroundPaint,
    );

    // Draw progress track
    final progressPaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.fill;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, size.height / 2 - 2, size.width * progressValue, 4),
        const Radius.circular(2),
      ),
      progressPaint,
    );

    // Draw playhead
    final playheadX = size.width * progressValue;
    final playheadPaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.fill;

    canvas.drawCircle(
      Offset(playheadX, size.height / 2),
      8,
      playheadPaint,
    );

    // Draw playhead line
    final linePaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 2;

    canvas.drawLine(
      Offset(playheadX, 0),
      Offset(playheadX, size.height),
      linePaint,
    );
  }

  @override
  bool shouldRepaint(TimelinePainter oldDelegate) {
    return oldDelegate.duration != duration ||
        oldDelegate.position != position;
  }
}
```

**Run:** `cd packages/screen_recorder && flutter test`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/timeline_widget.dart \
  packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart \
  packages/screen_recorder/test/ui/widgets/timeline/timeline_widget_test.dart \
  packages/screen_recorder/test/ui/widgets/timeline/timeline_painter_test.dart
git commit -m "feat: add timeline widget with visual playback scrubber

- Create TimelineWidget with tap/drag support
- Implement TimelinePainter with CustomPaint
- Draw progress track, playhead circle, and line
- Calculate position from tap/drag coordinates
- Test timeline rendering and interaction"
```

### Step 5: Integrate timeline into PlaybackScreen

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Replace the simple Slider (lines 177-195) with TimelineWidget:

```dart
// OLD CODE (remove lines 177-195):
// SliderTheme(
//   data: SliderThemeData(...),
//   child: Slider(...),
// )

// NEW CODE:
import 'package:screen_recorder/ui/widgets/timeline/timeline_widget.dart';

// In _buildControls(), replace slider with:
TimelineWidget(
  duration: value.duration,
  position: value.position,
  onPositionChanged: (newPosition) {
    _controller.seekTo(newPosition);
  },
),
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:** Timeline shows instead of slider, dragging scrubs video

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: integrate timeline widget into playback screen

- Replace Slider with TimelineWidget
- Wire up onPositionChanged to controller.seekTo
- Maintain existing time labels above timeline"
```

---

## Task 20: Trim Handles

**Goal:** Add draggable start/end handles to timeline for trim selection.

**Files:**
- Create: `packages/screen_recorder/lib/models/trim_selection.dart`
- Create: `packages/screen_recorder/test/models/trim_selection_test.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/timeline_widget.dart`
- Modify: `packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

### Step 1: Write failing test for TrimSelection model

**File:** `packages/screen_recorder/test/models/trim_selection_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/models/trim_selection.dart';

void main() {
  group('TrimSelection', () {
    test('should create trim selection with valid start and end', () {
      final selection = TrimSelection(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 8),
      );

      expect(selection.start, const Duration(seconds: 2));
      expect(selection.end, const Duration(seconds: 8));
      expect(selection.duration.inSeconds, 6);
    });

    test('should swap start and end if start > end', () {
      final selection = TrimSelection(
        start: const Duration(seconds: 8),
        end: const Duration(seconds: 2),
      );

      expect(selection.start, const Duration(seconds: 2));
      expect(selection.end, const Duration(seconds: 8));
    });

    test('should constrain to video duration', () {
      final selection = TrimSelection(
        start: const Duration(seconds: -1),
        end: const Duration(seconds: 20),
        videoDuration: const Duration(seconds: 10),
      );

      expect(selection.start, Duration.zero);
      expect(selection.end, const Duration(seconds: 10));
    });

    test('should check if position is within trim', () {
      final selection = TrimSelection(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 8),
      );

      expect(selection.contains(const Duration(seconds: 1)), false);
      expect(selection.contains(const Duration(seconds: 5)), true);
      expect(selection.contains(const Duration(seconds: 9)), false);
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/models/trim_selection_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist"

### Step 2: Implement TrimSelection model

**File:** `packages/screen_recorder/lib/models/trim_selection.dart`

```dart
/// Represents a trim selection on the timeline
class TrimSelection {
  final Duration start;
  final Duration end;

  TrimSelection({
    required Duration start,
    required Duration end,
    Duration? videoDuration,
  })  : start = _constrain(
          start < end ? start : end,
          videoDuration,
        ),
        end = _constrain(
          start < end ? end : start,
          videoDuration,
        );

  /// Duration of trimmed selection
  Duration get duration => end - start;

  /// Check if position is within trim selection
  bool contains(Duration position) {
    return position >= start && position <= end;
  }

  /// Create copy with updated values
  TrimSelection copyWith({
    Duration? start,
    Duration? end,
    Duration? videoDuration,
  }) {
    return TrimSelection(
      start: start ?? this.start,
      end: end ?? this.end,
      videoDuration: videoDuration,
    );
  }

  static Duration _constrain(Duration duration, Duration? maxDuration) {
    if (duration < Duration.zero) return Duration.zero;
    if (maxDuration != null && duration > maxDuration) return maxDuration;
    return duration;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is TrimSelection &&
          runtimeType == other.runtimeType &&
          start == other.start &&
          end == other.end;

  @override
  int get hashCode => start.hashCode ^ end.hashCode;
}
```

**Run:** `cd packages/screen_recorder && flutter test test/models/trim_selection_test.dart`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/models/trim_selection.dart \
  packages/screen_recorder/test/models/trim_selection_test.dart
git commit -m "feat: add TrimSelection model for timeline trimming

- Create TrimSelection with start/end Duration
- Auto-swap if start > end
- Constrain to video duration
- Check if position is within trim
- Implement copyWith, equality operators
- Test boundary conditions and constraints"
```

### Step 3: Add trim handles to TimelinePainter

**File:** `packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart`

Add TrimSelection parameter and paint trim handles:

```dart
import 'package:screen_recorder/models/trim_selection.dart';

class TimelinePainter extends CustomPainter {
  final Duration duration;
  final Duration position;
  final TrimSelection? trimSelection;  // Add this

  TimelinePainter({
    required this.duration,
    required this.position,
    this.trimSelection,  // Add this
  });

  // ... existing progress getter ...

  @override
  void paint(Canvas canvas, Size size) {
    final progressValue = progress.clamp(0.0, 1.0);

    // Draw trim selection if present
    if (trimSelection != null && duration.inMicroseconds > 0) {
      final startX = (trimSelection!.start.inMicroseconds / duration.inMicroseconds) * size.width;
      final endX = (trimSelection!.end.inMicroseconds / duration.inMicroseconds) * size.width;

      // Draw trim selection background
      final trimPaint = Paint()
        ..color = const Color(0xFF6C63FF).withOpacity(0.2)
        ..style = PaintingStyle.fill;

      canvas.drawRect(
        Rect.fromLTRB(startX, 0, endX, size.height),
        trimPaint,
      );

      // Draw start handle
      _drawTrimHandle(canvas, size, startX);

      // Draw end handle
      _drawTrimHandle(canvas, size, endX);
    }

    // ... existing track and playhead drawing code ...
  }

  void _drawTrimHandle(Canvas canvas, Size size, double x) {
    final handlePaint = Paint()
      ..color = const Color(0xFF6C63FF)
      ..style = PaintingStyle.fill;

    final handleRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(x - 4, 0, 8, size.height),
      const Radius.circular(4),
    );

    canvas.drawRRect(handleRect, handlePaint);

    // Draw grip lines
    final gripPaint = Paint()
      ..color = Colors.white
      ..strokeWidth = 1;

    canvas.drawLine(
      Offset(x - 1, size.height * 0.3),
      Offset(x - 1, size.height * 0.7),
      gripPaint,
    );

    canvas.drawLine(
      Offset(x + 1, size.height * 0.3),
      Offset(x + 1, size.height * 0.7),
      gripPaint,
    );
  }

  @override
  bool shouldRepaint(TimelinePainter oldDelegate) {
    return oldDelegate.duration != duration ||
        oldDelegate.position != position ||
        oldDelegate.trimSelection != trimSelection;
  }
}
```

**Run:** `cd packages/screen_recorder && flutter test`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/timeline_painter.dart
git commit -m "feat: add trim handle visualization to timeline

- Add trimSelection parameter to TimelinePainter
- Draw trim selection background with opacity
- Draw start/end handles with grip lines
- Update shouldRepaint to include trimSelection"
```

### Step 4: Add trim handle interaction to TimelineWidget

**File:** `packages/screen_recorder/lib/ui/widgets/timeline/timeline_widget.dart`

Add trim selection support and handle dragging:

```dart
import 'package:screen_recorder/models/trim_selection.dart';

class TimelineWidget extends StatefulWidget {  // Change to StatefulWidget
  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onPositionChanged;
  final TrimSelection? trimSelection;
  final ValueChanged<TrimSelection>? onTrimChanged;
  final double height;

  const TimelineWidget({
    super.key,
    required this.duration,
    required this.position,
    required this.onPositionChanged,
    this.trimSelection,
    this.onTrimChanged,
    this.height = 80,
  });

  @override
  State<TimelineWidget> createState() => _TimelineWidgetState();
}

class _TimelineWidgetState extends State<TimelineWidget> {
  enum DragTarget { none, playhead, startHandle, endHandle }
  DragTarget _dragTarget = DragTarget.none;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: (details) {
        _handleInteraction(details.localPosition, isInitial: true);
      },
      onHorizontalDragStart: (details) {
        _handleInteraction(details.localPosition, isInitial: true);
      },
      onHorizontalDragUpdate: (details) {
        _handleInteraction(details.localPosition, isInitial: false);
      },
      onHorizontalDragEnd: (_) {
        setState(() {
          _dragTarget = DragTarget.none;
        });
      },
      child: Container(
        height: widget.height,
        decoration: BoxDecoration(
          color: const Color(0xFF2B2B3D),
          borderRadius: BorderRadius.circular(8),
        ),
        child: CustomPaint(
          painter: TimelinePainter(
            duration: widget.duration,
            position: widget.position,
            trimSelection: widget.trimSelection,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }

  void _handleInteraction(Offset localPosition, {required bool isInitial}) {
    final RenderBox box = context.findRenderObject() as RenderBox;
    final width = box.size.width;

    if (isInitial && widget.trimSelection != null && widget.onTrimChanged != null) {
      // Determine if user tapped near a handle
      final startX = (widget.trimSelection!.start.inMicroseconds / widget.duration.inMicroseconds) * width;
      final endX = (widget.trimSelection!.end.inMicroseconds / widget.duration.inMicroseconds) * width;

      const hitRadius = 20.0;

      if ((localPosition.dx - startX).abs() < hitRadius) {
        _dragTarget = DragTarget.startHandle;
      } else if ((localPosition.dx - endX).abs() < hitRadius) {
        _dragTarget = DragTarget.endHandle;
      } else {
        _dragTarget = DragTarget.playhead;
      }
    }

    final progress = (localPosition.dx / width).clamp(0.0, 1.0);
    final newPosition = Duration(
      microseconds: (widget.duration.inMicroseconds * progress).round(),
    );

    switch (_dragTarget) {
      case DragTarget.startHandle:
        if (widget.onTrimChanged != null && widget.trimSelection != null) {
          widget.onTrimChanged!(widget.trimSelection!.copyWith(
            start: newPosition,
            videoDuration: widget.duration,
          ));
        }
        break;

      case DragTarget.endHandle:
        if (widget.onTrimChanged != null && widget.trimSelection != null) {
          widget.onTrimChanged!(widget.trimSelection!.copyWith(
            end: newPosition,
            videoDuration: widget.duration,
          ));
        }
        break;

      case DragTarget.playhead:
      case DragTarget.none:
        widget.onPositionChanged(newPosition);
        break;
    }
  }
}
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:** Can drag trim handles independently

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/widgets/timeline/timeline_widget.dart
git commit -m "feat: add trim handle dragging interaction

- Change TimelineWidget to StatefulWidget
- Add trimSelection and onTrimChanged parameters
- Detect which element user is dragging (playhead/start/end)
- Handle trim handle dragging independently
- Update trim selection via callback"
```

### Step 5: Integrate trim into PlaybackScreen

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add trim state and wire up trim handles:

```dart
// Add state variables:
TrimSelection? _trimSelection;

// In initState(), initialize trim to full duration:
@override
void initState() {
  super.initState();
  _initializeVideo();
}

Future<void> _initializeVideo() async {
  try {
    _controller = VideoPlayerController.file(File(widget.videoPath));
    await _controller.initialize();
    setState(() {
      _isInitialized = true;
      _trimSelection = TrimSelection(
        start: Duration.zero,
        end: _controller.value.duration,
      );
    });
    _controller.play();
  } catch (e) {
    setState(() {
      _error = 'Failed to load video: $e';
    });
  }
}

// Update TimelineWidget:
TimelineWidget(
  duration: value.duration,
  position: value.position,
  onPositionChanged: (newPosition) {
    _controller.seekTo(newPosition);
  },
  trimSelection: _trimSelection,
  onTrimChanged: (newTrim) {
    setState(() {
      _trimSelection = newTrim;
    });
  },
),

// Add trim info display:
if (_trimSelection != null) ...[
  const SizedBox(height: 8),
  Text(
    'Trim: ${_formatDuration(_trimSelection!.start)} - ${_formatDuration(_trimSelection!.end)} (${_formatDuration(_trimSelection!.duration)})',
    style: const TextStyle(
      color: Colors.white70,
      fontSize: 12,
    ),
  ),
],
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:** Trim handles appear, can be dragged, info shows selection

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: integrate trim selection into playback screen

- Add _trimSelection state variable
- Initialize trim to full video duration
- Wire up onTrimChanged callback
- Display trim info (start - end, duration)
- Import TrimSelection model"
```

---

## Task 21: Undo/Redo System

**Goal:** Add undo/redo for trim operations with keyboard shortcuts.

**Files:**
- Create: `packages/screen_recorder/lib/state/undo_redo_controller.dart`
- Create: `packages/screen_recorder/test/state/undo_redo_controller_test.dart`
- Modify: `packages/screen_recorder/lib/ui/screens/playback_screen.dart`
- Modify: `packages/screen_recorder/pubspec.yaml`

### Step 1: Write failing test for UndoRedoController

**File:** `packages/screen_recorder/test/state/undo_redo_controller_test.dart`

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/undo_redo_controller.dart';
import 'package:screen_recorder/models/trim_selection.dart';

void main() {
  group('UndoRedoController', () {
    test('should push and undo states', () {
      final controller = UndoRedoController<TrimSelection>();

      final state1 = TrimSelection(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      final state2 = TrimSelection(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 8),
      );

      controller.push(state1);
      controller.push(state2);

      expect(controller.canUndo, true);
      expect(controller.canRedo, false);

      final undone = controller.undo();
      expect(undone, state1);
      expect(controller.canUndo, false);
      expect(controller.canRedo, true);
    });

    test('should redo after undo', () {
      final controller = UndoRedoController<TrimSelection>();

      final state1 = TrimSelection(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      final state2 = TrimSelection(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 8),
      );

      controller.push(state1);
      controller.push(state2);
      controller.undo();

      final redone = controller.redo();
      expect(redone, state2);
      expect(controller.canRedo, false);
    });

    test('should clear redo stack on new push after undo', () {
      final controller = UndoRedoController<TrimSelection>();

      final state1 = TrimSelection(
        start: Duration.zero,
        end: const Duration(seconds: 10),
      );
      final state2 = TrimSelection(
        start: const Duration(seconds: 2),
        end: const Duration(seconds: 8),
      );
      final state3 = TrimSelection(
        start: const Duration(seconds: 1),
        end: const Duration(seconds: 9),
      );

      controller.push(state1);
      controller.push(state2);
      controller.undo();

      // Push new state should clear redo stack
      controller.push(state3);

      expect(controller.canRedo, false);
    });

    test('should limit undo stack size', () {
      final controller = UndoRedoController<int>(maxSize: 3);

      controller.push(1);
      controller.push(2);
      controller.push(3);
      controller.push(4);

      // Should only remember last 3 states
      controller.undo();
      controller.undo();
      controller.undo();

      expect(controller.canUndo, false);
      expect(controller.redo(), 3);
    });
  });
}
```

**Run:** `cd packages/screen_recorder && flutter test test/state/undo_redo_controller_test.dart`

**Expected:** FAIL - "Target of URI doesn't exist"

### Step 2: Implement UndoRedoController

**File:** `packages/screen_recorder/lib/state/undo_redo_controller.dart`

```dart
/// Generic undo/redo controller for any state type
class UndoRedoController<T> {
  final int maxSize;
  final List<T> _undoStack = [];
  final List<T> _redoStack = [];

  UndoRedoController({this.maxSize = 50});

  /// Whether undo is available
  bool get canUndo => _undoStack.length > 1;

  /// Whether redo is available
  bool get canRedo => _redoStack.isNotEmpty;

  /// Current state (top of undo stack)
  T? get current => _undoStack.isEmpty ? null : _undoStack.last;

  /// Push new state onto undo stack
  void push(T state) {
    _undoStack.add(state);

    // Clear redo stack on new action
    _redoStack.clear();

    // Limit stack size
    if (_undoStack.length > maxSize) {
      _undoStack.removeAt(0);
    }
  }

  /// Undo to previous state
  T? undo() {
    if (!canUndo) return null;

    // Move current state to redo stack
    _redoStack.add(_undoStack.removeLast());

    // Return previous state
    return _undoStack.last;
  }

  /// Redo to next state
  T? redo() {
    if (!canRedo) return null;

    // Move state back to undo stack
    final state = _redoStack.removeLast();
    _undoStack.add(state);

    return state;
  }

  /// Clear all history
  void clear() {
    _undoStack.clear();
    _redoStack.clear();
  }
}
```

**Run:** `cd packages/screen_recorder && flutter test test/state/undo_redo_controller_test.dart`

**Expected:** PASS

**Commit:**
```bash
git add packages/screen_recorder/lib/state/undo_redo_controller.dart \
  packages/screen_recorder/test/state/undo_redo_controller_test.dart
git commit -m "feat: add undo/redo controller for timeline edits

- Create generic UndoRedoController<T>
- Implement undo/redo stacks with size limit
- Clear redo stack on new push after undo
- Test stack behavior and size limits"
```

### Step 3: Integrate undo/redo into PlaybackScreen

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add undo/redo controller and wire up trim changes:

```dart
import 'package:screen_recorder/state/undo_redo_controller.dart';

class _PlaybackScreenState extends State<PlaybackScreen> {
  // ... existing state ...
  late UndoRedoController<TrimSelection> _undoRedo;

  @override
  void initState() {
    super.initState();
    _undoRedo = UndoRedoController<TrimSelection>();
    _initializeVideo();
  }

  Future<void> _initializeVideo() async {
    try {
      _controller = VideoPlayerController.file(File(widget.videoPath));
      await _controller.initialize();
      setState(() {
        _isInitialized = true;
        _trimSelection = TrimSelection(
          start: Duration.zero,
          end: _controller.value.duration,
        );
        // Push initial state
        _undoRedo.push(_trimSelection!);
      });
      _controller.play();
    } catch (e) {
      setState(() {
        _error = 'Failed to load video: $e';
      });
    }
  }

  void _handleTrimChanged(TrimSelection newTrim) {
    setState(() {
      _trimSelection = newTrim;
      _undoRedo.push(newTrim);
    });
  }

  void _handleUndo() {
    final previousTrim = _undoRedo.undo();
    if (previousTrim != null) {
      setState(() {
        _trimSelection = previousTrim;
      });
    }
  }

  void _handleRedo() {
    final nextTrim = _undoRedo.redo();
    if (nextTrim != null) {
      setState(() {
        _trimSelection = nextTrim;
      });
    }
  }

  // Update TimelineWidget callback:
  onTrimChanged: _handleTrimChanged,
}
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:** Trim changes tracked (not yet undoable via UI)

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: integrate undo/redo controller with trim changes

- Create UndoRedoController instance in PlaybackScreen
- Push initial trim state
- Push new state on every trim change
- Add handleUndo and handleRedo methods
- Wire up trim changed callback"
```

### Step 4: Add undo/redo buttons to UI

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Add undo/redo buttons to the controls:

```dart
// In _buildControls(), after trim info display:
Row(
  mainAxisAlignment: MainAxisAlignment.center,
  children: [
    // Undo button
    IconButton(
      onPressed: _undoRedo.canUndo ? _handleUndo : null,
      icon: const Icon(Icons.undo),
      color: const Color(0xFF6C63FF),
      disabledColor: Colors.white24,
      tooltip: 'Undo (Cmd+Z)',
    ),

    // Redo button
    IconButton(
      onPressed: _undoRedo.canRedo ? _handleRedo : null,
      icon: const Icon(Icons.redo),
      color: const Color(0xFF6C63FF),
      disabledColor: Colors.white24,
      tooltip: 'Redo (Cmd+Shift+Z)',
    ),
  ],
),
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:** Undo/redo buttons appear, work when clicked

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: add undo/redo buttons to playback controls

- Add undo button with icon and tooltip
- Add redo button with icon and tooltip
- Disable buttons when no undo/redo available
- Use purple theme color (#6C63FF)"
```

### Step 5: Add keyboard shortcuts

**File:** `packages/screen_recorder/lib/ui/screens/playback_screen.dart`

Wrap Scaffold with Focus and RawKeyboardListener:

```dart
import 'package:flutter/services.dart';

@override
Widget build(BuildContext context) {
  return Focus(
    autofocus: true,
    onKeyEvent: (node, event) {
      if (event is KeyDownEvent) {
        // Cmd+Z or Ctrl+Z for undo
        if ((event.logicalKey == LogicalKeyboardKey.keyZ) &&
            (event.isMetaPressed || event.isControlPressed) &&
            !event.isShiftPressed) {
          if (_undoRedo.canUndo) {
            _handleUndo();
            return KeyEventResult.handled;
          }
        }

        // Cmd+Shift+Z or Ctrl+Shift+Z for redo
        if ((event.logicalKey == LogicalKeyboardKey.keyZ) &&
            (event.isMetaPressed || event.isControlPressed) &&
            event.isShiftPressed) {
          if (_undoRedo.canRedo) {
            _handleRedo();
            return KeyEventResult.handled;
          }
        }

        // Space for play/pause
        if (event.logicalKey == LogicalKeyboardKey.space) {
          if (_isInitialized) {
            setState(() {
              if (_controller.value.isPlaying) {
                _controller.pause();
              } else {
                _controller.play();
              }
            });
            return KeyEventResult.handled;
          }
        }
      }

      return KeyEventResult.ignored;
    },
    child: Scaffold(
      // ... existing scaffold code ...
    ),
  );
}
```

**Run:** `cd packages/screen_recorder && flutter run`

**Expected:** Cmd+Z/Ctrl+Z undoes, Cmd+Shift+Z redoes, Space plays/pauses

**Commit:**
```bash
git add packages/screen_recorder/lib/ui/screens/playback_screen.dart
git commit -m "feat: add keyboard shortcuts for undo/redo and playback

- Wrap Scaffold with Focus for keyboard events
- Handle Cmd+Z / Ctrl+Z for undo
- Handle Cmd+Shift+Z / Ctrl+Shift+Z for redo
- Handle Space for play/pause toggle
- Return KeyEventResult.handled to prevent propagation"
```

---

## Phase 5 Complete

### Summary

**Task 19: Timeline Widget** ✅
- Custom timeline visualization with CustomPaint
- Draggable playhead scrubber
- Visual progress track
- Integration with PlaybackScreen

**Task 20: Trim Handles** ✅
- TrimSelection model with constraints
- Visual trim handles on timeline
- Independent handle dragging
- Trim info display

**Task 21: Undo/Redo System** ✅
- Generic undo/redo controller
- Stack-based state management
- Undo/redo buttons in UI
- Keyboard shortcuts (Cmd+Z, Cmd+Shift+Z, Space)

### What Works Now

1. **Timeline visualization**: Professional-looking timeline with playhead
2. **Trim selection**: Drag start/end handles to select region
3. **Undo/redo**: Full undo/redo support for trim edits
4. **Keyboard shortcuts**: Standard shortcuts for undo/redo/playback
5. **Frame-accurate seeking**: Drag playhead for precise positioning

### Testing Checklist

#### Manual Testing

- [ ] Timeline shows video duration correctly
- [ ] Dragging playhead scrubs video smoothly
- [ ] Trim handles appear and are draggable
- [ ] Trim info displays correct times
- [ ] Undo button undoes trim changes
- [ ] Redo button redoes after undo
- [ ] Cmd+Z / Ctrl+Z triggers undo
- [ ] Cmd+Shift+Z triggers redo
- [ ] Space bar plays/pauses video
- [ ] Buttons disable when no undo/redo available

#### Automated Tests

```bash
cd packages/screen_recorder
flutter test
```

Expected: All tests pass (30+ tests including timeline and undo/redo)

### Success Metrics

- ✅ Timeline UI renders correctly
- ✅ Trim handles work independently
- ✅ Undo/redo preserves trim state
- ✅ Keyboard shortcuts work as expected
- ✅ Tests cover all new functionality

---

## What's Next?

**Phase 6: Zoom Effects** (from master plan)
- Zoom algorithm for focus areas
- Click detection for auto-zoom
- Smooth zoom transitions

**Future Enhancements:**
- Export trimmed video
- Multiple trim regions
- Effect markers on timeline
- Thumbnail preview on timeline
- Snap-to-frame for precise edits
