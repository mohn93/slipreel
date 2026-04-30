import 'package:flutter/material.dart';
import 'package:screen_recorder/models/zoom_region.dart';

const _trackBg = Color(0xFF1B1B26);
const _clipFill = Color(0xFFE69E5A);
const _clipFillTop = Color(0xFFEBA968);
const _clipStroke = Color(0xFFC9853F);
const _zoomFill = Color(0xFF7C6BFF);
const _zoomFillTop = Color(0xFF8E7DFF);
const _zoomStroke = Color(0xFF6457E8);
const _zoomFillSelected = Color(0xFF9080FF);
const _tickColor = Color(0xFF454555);
const _labelColor = Color(0xFFAAAAB5);
const _playheadTop = Color(0xFF4FC3FF);
const _playheadMid = Color(0xFF6F5BFF);
const _playheadBottom = Color(0xFF3D26AA);

const double _rulerHeight = 26;
const double _laneHeight = 46;
const double _laneSpacing = 6;
const double _handleHitWidth = 16;
const double _zoomPillInset = 2;
const int _minZoomDurationMs = 250;

/// Vertical room reserved ABOVE each zoom pill's body for the
/// hover-revealed zoom-level badge. The zoom lane is sized to include
/// this so the pill's hit area can cover the badge zone (otherwise the
/// badge ends up outside any hit-testable region and unmounts as soon
/// as the cursor leaves the pill body).
const double _zoomBadgeAreaHeight = 32;

double _timeToX(Duration t, double width, Duration total) {
  if (total.inMicroseconds <= 0) return 0;
  return (t.inMicroseconds / total.inMicroseconds) * width;
}

Duration _xToTime(double x, double width, Duration total) {
  if (width <= 0 || total.inMicroseconds <= 0) return Duration.zero;
  final clamped = x.clamp(0.0, width);
  return Duration(
    microseconds: (clamped / width * total.inMicroseconds).round(),
  );
}

String _formatSecondsLabel(double secs) {
  final s = secs.round();
  final m = s ~/ 60;
  final sec = s % 60;
  return '$m:${sec.toString().padLeft(2, '0')}';
}

/// Stacked editor timeline: time ruler on top, clip lane in the middle,
/// optional zoom lane on the bottom. A single playhead line runs across all
/// rows. Designed to be redrawn at vsync (caller passes a smoothed
/// `position`) so the playhead glides instead of stepping.
class EditorTimeline extends StatefulWidget {
  const EditorTimeline({
    super.key,
    required this.duration,
    required this.position,
    required this.onSeek,
    this.zoomRegions = const [],
    this.selectedZoomIndex,
    this.onZoomChanged,
    this.onZoomSelected,
    this.onZoomDeleted,
    this.playbackSpeedLabel = '1x',
    this.isPlaying = false,
    this.onHoverSeek,
  });

  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  final List<ZoomRegion> zoomRegions;
  final int? selectedZoomIndex;
  final void Function(int index, ZoomRegion next)? onZoomChanged;
  final ValueChanged<int?>? onZoomSelected;
  final ValueChanged<int>? onZoomDeleted;
  final String playbackSpeedLabel;
  final bool isPlaying;
  // Live preview seek while the cursor hovers the timeline (paused only).
  // Wired separately from `onSeek` so the caller can skip side-effects
  // (zoom-marker selection, history pushes) for the high-frequency hover
  // stream.
  final ValueChanged<Duration>? onHoverSeek;

  @override
  State<EditorTimeline> createState() => _EditorTimelineState();
}

class _EditorTimelineState extends State<EditorTimeline> {
  double? _hoverProgress;

  void _updateHover(Offset local, double width) {
    if (widget.isPlaying || width <= 0) return;
    final progress = (local.dx / width).clamp(0.0, 1.0);
    if (_hoverProgress != progress) {
      setState(() => _hoverProgress = progress);
    }
    if (widget.onHoverSeek != null) {
      final hoverTime = Duration(
        microseconds: (widget.duration.inMicroseconds * progress).round(),
      );
      widget.onHoverSeek!(hoverTime);
    }
  }

  void _clearHover() {
    if (_hoverProgress != null) {
      setState(() => _hoverProgress = null);
    }
  }

  @override
  void didUpdateWidget(EditorTimeline old) {
    super.didUpdateWidget(old);
    // If playback resumes, the hover indicator should disappear.
    if (widget.isPlaying && _hoverProgress != null) {
      _hoverProgress = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hasZooms = widget.zoomRegions.isNotEmpty;
        final zoomLaneHeight = _laneHeight + _zoomBadgeAreaHeight;
        final totalHeight = _rulerHeight +
            _laneSpacing +
            _laneHeight +
            (hasZooms ? _laneSpacing + zoomLaneHeight : 0);

        return SizedBox(
          height: totalHeight,
          width: width,
          child: MouseRegion(
            // Hover-to-scrub when paused. The MouseRegion sits above the
            // gesture detectors but doesn't consume events — onHover is
            // hover-only, onTap/onPan still flow through to the lanes
            // below.
            opaque: false,
            onHover: (e) => _updateHover(e.localPosition, width),
            onExit: (_) => _clearHover(),
            child: Stack(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      height: _rulerHeight,
                      child: _TimeRuler(
                          duration: widget.duration,
                          width: width,
                          onSeek: widget.onSeek),
                    ),
                    const SizedBox(height: _laneSpacing),
                    SizedBox(
                      height: _laneHeight,
                      child: _ClipLane(
                        duration: widget.duration,
                        width: width,
                        onSeek: widget.onSeek,
                        speedLabel: widget.playbackSpeedLabel,
                      ),
                    ),
                    if (hasZooms) ...[
                      const SizedBox(height: _laneSpacing),
                      SizedBox(
                        height: zoomLaneHeight,
                        child: _ZoomLane(
                          duration: widget.duration,
                          width: width,
                          zoomRegions: widget.zoomRegions,
                          selectedIndex: widget.selectedZoomIndex,
                          onZoomChanged: widget.onZoomChanged,
                          onZoomSelected: widget.onZoomSelected,
                          onZoomDeleted: widget.onZoomDeleted,
                          onSeek: widget.onSeek,
                        ),
                      ),
                    ],
                  ],
                ),
                IgnorePointer(
                  child: CustomPaint(
                    size: Size(width, totalHeight),
                    painter: _PlayheadPainter(
                      progress: widget.duration.inMicroseconds == 0
                          ? 0
                          : (widget.position.inMicroseconds /
                                  widget.duration.inMicroseconds)
                              .clamp(0.0, 1.0),
                      hoverProgress:
                          widget.isPlaying ? null : _hoverProgress,
                      rulerHeight: _rulerHeight,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ────────────────────────────── Time ruler ──────────────────────────────

class _TimeRuler extends StatelessWidget {
  const _TimeRuler({
    required this.duration,
    required this.width,
    required this.onSeek,
  });

  final Duration duration;
  final double width;
  final ValueChanged<Duration> onSeek;

  void _seek(Offset local) =>
      onSeek(_xToTime(local.dx, width, duration));

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _seek(d.localPosition),
        onHorizontalDragStart: (d) => _seek(d.localPosition),
        onHorizontalDragUpdate: (d) => _seek(d.localPosition),
        child: CustomPaint(painter: _TimeRulerPainter(duration: duration)),
      ),
    );
  }
}

class _TimeRulerPainter extends CustomPainter {
  _TimeRulerPainter({required this.duration});

  final Duration duration;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration.inMicroseconds <= 0) return;
    final totalSec = duration.inMicroseconds / 1e6;
    final step = _chooseStep(totalSec, size.width);
    final tickPaint = Paint()..color = _tickColor;
    final labelStyle = const TextStyle(
      color: _labelColor,
      fontSize: 11,
      fontFeatures: [FontFeature.tabularFigures()],
    );

    double s = 0;
    while (s <= totalSec + 0.0001) {
      final x = (s / totalSec) * size.width;

      // Tick mark just below labels.
      canvas.drawLine(
        Offset(x, size.height - 4),
        Offset(x, size.height),
        tickPaint,
      );

      // Label centered horizontally on the tick.
      final tp = TextPainter(
        text: TextSpan(text: _formatSecondsLabel(s), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      final tx = (x - tp.width / 2)
          .clamp(0.0, size.width - tp.width);
      tp.paint(canvas, Offset(tx, 1));

      s += step;
    }
  }

  static double _chooseStep(double seconds, double width) {
    if (seconds <= 0 || width <= 0) return 1;
    const targetLabels = 7;
    final rough = seconds / targetLabels;
    const candidates = [
      0.25, 0.5, 1.0, 2.0, 5.0, 10.0, 15.0, 30.0, 60.0, 120.0, 300.0
    ];
    for (final c in candidates) {
      if (rough <= c) return c;
    }
    return 600.0;
  }

  @override
  bool shouldRepaint(_TimeRulerPainter old) => old.duration != duration;
}

// ─────────────────────────────── Clip lane ──────────────────────────────

class _ClipLane extends StatelessWidget {
  const _ClipLane({
    required this.duration,
    required this.width,
    required this.onSeek,
    required this.speedLabel,
  });

  final Duration duration;
  final double width;
  final ValueChanged<Duration> onSeek;
  final String speedLabel;

  void _seek(Offset local) =>
      onSeek(_xToTime(local.dx, width, duration));

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _seek(d.localPosition),
      onHorizontalDragStart: (d) => _seek(d.localPosition),
      onHorizontalDragUpdate: (d) => _seek(d.localPosition),
      child: CustomPaint(
        painter: _ClipLanePainter(
          duration: duration,
          speedLabel: speedLabel,
        ),
      ),
    );
  }
}

class _ClipLanePainter extends CustomPainter {
  _ClipLanePainter({required this.duration, required this.speedLabel});

  final Duration duration;
  final String speedLabel;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(8));

    // Track background underneath, in case clip width != lane width.
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(8)),
      Paint()..color = _trackBg,
    );

    // Clip pill with subtle vertical gradient to match the reference.
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_clipFillTop, _clipFill],
    );
    canvas.drawRRect(
      rrect,
      Paint()..shader = gradient.createShader(rect),
    );
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = _clipStroke,
    );

    // Centered "Clip" + duration / speed subtitle.
    final main = TextPainter(
      text: const TextSpan(
        text: 'Clip',
        style: TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 13,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final sub = TextPainter(
      text: TextSpan(
        text: '${_formatHumanDuration(duration)}  ·  $speedLabel',
        style: const TextStyle(
          color: Color(0xCCFFFFFF),
          fontSize: 11,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final totalH = main.height + sub.height + 1;
    final cy = size.height / 2 - totalH / 2;
    main.paint(canvas, Offset(size.width / 2 - main.width / 2, cy));
    sub.paint(canvas,
        Offset(size.width / 2 - sub.width / 2, cy + main.height + 1));
  }

  static String _formatHumanDuration(Duration d) {
    final ms = d.inMilliseconds;
    if (ms < 1000) return '${ms}ms';
    final secs = ms / 1000;
    if (secs < 60) {
      return secs == secs.roundToDouble()
          ? '${secs.toInt()}s'
          : '${secs.toStringAsFixed(1)}s';
    }
    final m = d.inMinutes;
    final s = d.inSeconds - m * 60;
    return '${m}m ${s}s';
  }

  @override
  bool shouldRepaint(_ClipLanePainter old) =>
      old.duration != duration || old.speedLabel != speedLabel;
}

// ─────────────────────────────── Zoom lane ──────────────────────────────

class _ZoomLane extends StatelessWidget {
  const _ZoomLane({
    required this.duration,
    required this.width,
    required this.zoomRegions,
    required this.onSeek,
    this.selectedIndex,
    this.onZoomChanged,
    this.onZoomSelected,
    this.onZoomDeleted,
  });

  final Duration duration;
  final double width;
  final List<ZoomRegion> zoomRegions;
  final ValueChanged<Duration> onSeek;
  final int? selectedIndex;
  final void Function(int, ZoomRegion)? onZoomChanged;
  final ValueChanged<int?>? onZoomSelected;
  final ValueChanged<int>? onZoomDeleted;

  @override
  Widget build(BuildContext context) {
    // Clip.none so each zoom pill can extend upward into the spacing/clip
    // lane area to host its hover-revealed zoom-level badge — without that,
    // the badge falls outside the lane's hit area and its hover detection
    // breaks (cursor moving toward it triggers onExit).
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Empty-area background that handles seek-on-tap and deselect-on-tap.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: (d) {
              onZoomSelected?.call(null);
              onSeek(_xToTime(d.localPosition.dx, width, duration));
            },
            child: const SizedBox.expand(),
          ),
        ),
        for (var i = 0; i < zoomRegions.length; i++)
          _ZoomPill(
            key: ValueKey(i),
            index: i,
            zoom: zoomRegions[i],
            isSelected: selectedIndex == i,
            duration: duration,
            laneWidth: width,
            neighbors: _neighborsOf(i),
            onChanged: onZoomChanged,
            onSelected: onZoomSelected,
            onDeleted: onZoomDeleted,
            onSeek: onSeek,
          ),
      ],
    );
  }

  ({Duration? prevEnd, Duration? nextStart}) _neighborsOf(int i) {
    Duration? prev;
    Duration? next;
    for (var j = 0; j < zoomRegions.length; j++) {
      if (j == i) continue;
      final z = zoomRegions[j];
      if (z.endTime <= zoomRegions[i].startTime) {
        if (prev == null || z.endTime > prev) prev = z.endTime;
      } else if (z.startTime >= zoomRegions[i].endTime) {
        if (next == null || z.startTime < next) next = z.startTime;
      }
    }
    return (prevEnd: prev, nextStart: next);
  }
}

enum _ZoomDragMode { none, body, leftEdge, rightEdge }

class _ZoomPill extends StatefulWidget {
  const _ZoomPill({
    super.key,
    required this.index,
    required this.zoom,
    required this.isSelected,
    required this.duration,
    required this.laneWidth,
    required this.neighbors,
    required this.onSeek,
    this.onChanged,
    this.onSelected,
    this.onDeleted,
  });

  final int index;
  final ZoomRegion zoom;
  final bool isSelected;
  final Duration duration;
  final double laneWidth;
  final ({Duration? prevEnd, Duration? nextStart}) neighbors;
  final ValueChanged<Duration> onSeek;
  final void Function(int, ZoomRegion)? onChanged;
  final ValueChanged<int?>? onSelected;
  final ValueChanged<int>? onDeleted;

  @override
  State<_ZoomPill> createState() => _ZoomPillState();
}

class _ZoomPillState extends State<_ZoomPill> {
  _ZoomDragMode _mode = _ZoomDragMode.none;
  late Duration _dragStartTime;
  late Duration _dragEndTime;
  // Cumulative dx since the drag began. We anchor the math to drag-start
  // values, not the (constantly-changing) widget.zoom, so we must track
  // the running delta ourselves — onHorizontalDragUpdate.delta.dx is
  // per-frame, not cumulative.
  double _dxAccum = 0;
  bool _hovered = false;

  // Divider drags need their own anchor + accumulator. Reading
  // widget.zoom.enterDuration each tick loses deltas when several drag
  // updates fire inside a single frame (the parent's setState batches
  // until the next rebuild) — same trap the pill body's accumulator
  // already avoids.
  Duration? _enterAnchor;
  double _enterAccum = 0;
  Duration? _exitAnchor;
  double _exitAccum = 0;

  double get _startX =>
      _timeToX(widget.zoom.startTime, widget.laneWidth, widget.duration);
  double get _endX =>
      _timeToX(widget.zoom.endTime, widget.laneWidth, widget.duration);

  Duration get _minStart =>
      widget.neighbors.prevEnd ?? Duration.zero;
  Duration get _maxEnd =>
      widget.neighbors.nextStart ?? widget.duration;
  Duration get _minDuration =>
      const Duration(milliseconds: _minZoomDurationMs);

  void _begin(Offset local) {
    _dxAccum = 0;
    _dragStartTime = widget.zoom.startTime;
    _dragEndTime = widget.zoom.endTime;
    final x = local.dx;
    final width = _endX - _startX;
    if (x <= _handleHitWidth) {
      _mode = _ZoomDragMode.leftEdge;
    } else if (x >= width - _handleHitWidth) {
      _mode = _ZoomDragMode.rightEdge;
    } else {
      _mode = _ZoomDragMode.body;
    }
    widget.onSelected?.call(widget.index);
    if (_mode == _ZoomDragMode.body) {
      widget.onSeek(widget.zoom.startTime);
    }
  }

  void _update(double dxDelta) {
    if (widget.onChanged == null) return;
    _dxAccum += dxDelta;
    final scale = widget.duration.inMicroseconds / widget.laneWidth;
    final deltaUs = (_dxAccum * scale).round();
    final delta = Duration(microseconds: deltaUs);

    var nextStart = _dragStartTime;
    var nextEnd = _dragEndTime;

    switch (_mode) {
      case _ZoomDragMode.body:
        nextStart = _dragStartTime + delta;
        nextEnd = _dragEndTime + delta;
        final span = nextEnd - nextStart;
        if (nextStart < _minStart) {
          nextStart = _minStart;
          nextEnd = nextStart + span;
        }
        if (nextEnd > _maxEnd) {
          nextEnd = _maxEnd;
          nextStart = nextEnd - span;
        }
        break;
      case _ZoomDragMode.leftEdge:
        nextStart = _dragStartTime + delta;
        if (nextStart < _minStart) nextStart = _minStart;
        if (nextEnd - nextStart < _minDuration) {
          nextStart = nextEnd - _minDuration;
        }
        break;
      case _ZoomDragMode.rightEdge:
        nextEnd = _dragEndTime + delta;
        if (nextEnd > _maxEnd) nextEnd = _maxEnd;
        if (nextEnd - nextStart < _minDuration) {
          nextEnd = nextStart + _minDuration;
        }
        break;
      case _ZoomDragMode.none:
        return;
    }

    final newDuration = nextEnd - nextStart;
    // Scale the enter / exit ramps if the new region is shorter than
    // the sum of their stored durations — otherwise the dividers visually
    // cross and the model stores impossible state. We scale proportionally
    // so the enter:exit ratio is preserved.
    Duration newEnter = widget.zoom.enterDuration;
    Duration newExit = widget.zoom.exitDuration;
    final ramps = newEnter + newExit;
    if (ramps > newDuration && ramps > Duration.zero) {
      final factor =
          newDuration.inMicroseconds / ramps.inMicroseconds;
      final scaledEnterUs =
          (newEnter.inMicroseconds * factor).round();
      newEnter = Duration(microseconds: scaledEnterUs);
      newExit = newDuration - newEnter;
    }

    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        startTime: nextStart,
        duration: newDuration,
        enterDuration: newEnter,
        exitDuration: newExit,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final left = _startX;
    final pillWidth =
        (_endX - _startX).clamp(_handleHitWidth * 2, double.infinity);
    final pillBodyHeight = _laneHeight - _zoomPillInset * 2;
    final cursor = _cursorForMode(_mode);
    final fillTop = widget.isSelected ? _zoomFillSelected : _zoomFillTop;
    final fill = widget.isSelected ? _zoomFillSelected : _zoomFill;
    final stroke = widget.isSelected ? Colors.white : _zoomStroke;

    final regionUs = widget.zoom.duration.inMicroseconds;
    final pxPerRegionUs = regionUs == 0 ? 0.0 : pillWidth / regionUs;
    final enterPx = widget.zoom.enterDuration.inMicroseconds * pxPerRegionUs;
    final exitPx =
        pillWidth - widget.zoom.exitDuration.inMicroseconds * pxPerRegionUs;

    // The zoom lane is sized to (pillBodyHeight + badgeArea + 2*inset). The
    // pill's MouseRegion fills the full vertical extent so the cursor moving
    // from the pill body up to the badge stays in the same hover region.
    return Positioned(
      left: left,
      top: _zoomPillInset,
      width: pillWidth,
      height: pillBodyHeight + _zoomBadgeAreaHeight,
      child: MouseRegion(
        cursor: cursor,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            // Pill body offset down so the top of the Stack is the badge zone.
            Positioned(
              left: 0,
              right: 0,
              top: _zoomBadgeAreaHeight,
              height: pillBodyHeight,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) {
                  widget.onSelected?.call(widget.index);
                  widget.onSeek(widget.zoom.startTime);
                },
                onHorizontalDragStart: (d) => _begin(d.localPosition),
                onHorizontalDragUpdate: (d) => _update(d.delta.dx),
                onHorizontalDragEnd: (_) {
                  _mode = _ZoomDragMode.none;
                  _dxAccum = 0;
                },
                onHorizontalDragCancel: () {
                  _mode = _ZoomDragMode.none;
                  _dxAccum = 0;
                },
                child: CustomPaint(
                  painter: _ZoomPillPainter(
                    fillTop: fillTop,
                    fill: fill,
                    stroke: stroke,
                    zoomLevel: widget.zoom.zoomLevel,
                    enterPx: enterPx,
                    exitPx: exitPx,
                    showInternalGuides: _hovered,
                    isSelected: widget.isSelected,
                  ),
                ),
              ),
            ),
            if (_hovered && pillWidth > _handleHitWidth * 4) ...[
              _RampDivider(
                centerX: enterPx,
                top: _zoomBadgeAreaHeight,
                height: pillBodyHeight,
                onDragStart: _beginEnterDrag,
                onDelta: _onEnterDividerDrag,
                onDragEnd: _endEnterDrag,
                tooltip: 'Enter ${widget.zoom.enterDuration.inMilliseconds}ms',
              ),
              _RampDivider(
                centerX: exitPx,
                top: _zoomBadgeAreaHeight,
                height: pillBodyHeight,
                onDragStart: _beginExitDrag,
                onDelta: _onExitDividerDrag,
                onDragEnd: _endExitDrag,
                tooltip: 'Exit ${widget.zoom.exitDuration.inMilliseconds}ms',
              ),
            ],
            if (_hovered)
              Positioned(
                left: pillWidth / 2 - 38,
                top: 0,
                child: _ZoomLevelBadge(
                  level: widget.zoom.zoomLevel,
                  onIncrement: () => _stepZoomLevel(0.1),
                  onDecrement: () => _stepZoomLevel(-0.1),
                ),
              ),
            if (_hovered && widget.onDeleted != null)
              Positioned(
                top: _zoomBadgeAreaHeight - 6,
                right: -6,
                child: _ZoomDeleteButton(
                  onPressed: () => widget.onDeleted!(widget.index),
                ),
              ),
          ],
        ),
      ),
    );
  }

  void _beginEnterDrag() {
    _enterAnchor = widget.zoom.enterDuration;
    _enterAccum = 0;
  }

  void _onEnterDividerDrag(double dx) {
    if (widget.onChanged == null || _enterAnchor == null) return;
    _enterAccum += dx;
    final usPerPx =
        widget.duration.inMicroseconds / widget.laneWidth;
    final deltaUs = (_enterAccum * usPerPx).round();
    final maxEnterUs = widget.zoom.duration.inMicroseconds -
        widget.zoom.exitDuration.inMicroseconds;
    final newEnterUs = (_enterAnchor!.inMicroseconds + deltaUs)
        .clamp(0, maxEnterUs);
    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        enterDuration: Duration(microseconds: newEnterUs),
      ),
    );
  }

  void _endEnterDrag() {
    _enterAnchor = null;
    _enterAccum = 0;
  }

  void _beginExitDrag() {
    _exitAnchor = widget.zoom.exitDuration;
    _exitAccum = 0;
  }

  void _onExitDividerDrag(double dx) {
    if (widget.onChanged == null || _exitAnchor == null) return;
    _exitAccum += dx;
    final usPerPx =
        widget.duration.inMicroseconds / widget.laneWidth;
    // Dragging the exit divider rightward shortens the exit ramp.
    final deltaUs = (-_exitAccum * usPerPx).round();
    final maxExitUs = widget.zoom.duration.inMicroseconds -
        widget.zoom.enterDuration.inMicroseconds;
    final newExitUs =
        (_exitAnchor!.inMicroseconds + deltaUs).clamp(0, maxExitUs);
    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        exitDuration: Duration(microseconds: newExitUs),
      ),
    );
  }

  void _endExitDrag() {
    _exitAnchor = null;
    _exitAccum = 0;
  }

  void _stepZoomLevel(double delta) {
    if (widget.onChanged == null) return;
    final next = (widget.zoom.zoomLevel + delta).clamp(1.0, 5.0);
    final rounded = (next * 10).round() / 10.0;
    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(zoomLevel: rounded),
    );
  }

  static MouseCursor _cursorForMode(_ZoomDragMode mode) {
    switch (mode) {
      case _ZoomDragMode.leftEdge:
      case _ZoomDragMode.rightEdge:
        return SystemMouseCursors.resizeLeftRight;
      case _ZoomDragMode.body:
        return SystemMouseCursors.grabbing;
      case _ZoomDragMode.none:
        return SystemMouseCursors.grab;
    }
  }
}

/// Vertical drag-handle inside a zoom pill marking the boundary between
/// ramp and hold (enter or exit). Subtle when not directly hovered;
/// expands into a clear grip when the cursor is over it.
class _RampDivider extends StatefulWidget {
  const _RampDivider({
    required this.centerX,
    required this.top,
    required this.height,
    required this.onDragStart,
    required this.onDelta,
    required this.onDragEnd,
    required this.tooltip,
  });

  final double centerX;
  final double top;
  final double height;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDelta;
  final VoidCallback onDragEnd;
  final String tooltip;

  @override
  State<_RampDivider> createState() => _RampDividerState();
}

class _RampDividerState extends State<_RampDivider> {
  bool _hover = false;
  bool _dragging = false;
  static const double _hitWidth = 14;

  @override
  Widget build(BuildContext context) {
    final emphasized = _hover || _dragging;
    final lineWidth = emphasized ? 3.0 : 1.5;
    final lineColor = emphasized
        ? Colors.white
        : Colors.white.withValues(alpha: 0.55);

    return Positioned(
      left: widget.centerX - _hitWidth / 2,
      top: widget.top,
      width: _hitWidth,
      height: widget.height,
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeLeftRight,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: Tooltip(
          message: widget.tooltip,
          waitDuration: const Duration(milliseconds: 350),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onHorizontalDragStart: (_) {
              setState(() => _dragging = true);
              widget.onDragStart();
            },
            onHorizontalDragUpdate: (d) => widget.onDelta(d.delta.dx),
            onHorizontalDragEnd: (_) {
              setState(() => _dragging = false);
              widget.onDragEnd();
            },
            onHorizontalDragCancel: () {
              setState(() => _dragging = false);
              widget.onDragEnd();
            },
            child: Center(
              child: Container(
                width: lineWidth,
                decoration: BoxDecoration(
                  color: lineColor,
                  borderRadius: BorderRadius.circular(1.5),
                  boxShadow: emphasized
                      ? const [
                          BoxShadow(
                            color: Color(0x66000000),
                            blurRadius: 4,
                            offset: Offset(0, 1),
                          ),
                        ]
                      : null,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Floating zoom-level pill above the zoom region, with chevron buttons
/// to step the zoom level by 0.1× when hovered. Each chevron has its
/// own hover state so it visibly highlights when targetable.
class _ZoomLevelBadge extends StatelessWidget {
  const _ZoomLevelBadge({
    required this.level,
    required this.onIncrement,
    required this.onDecrement,
  });

  final double level;
  final VoidCallback onIncrement;
  final VoidCallback onDecrement;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1F1F2E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white24, width: 1),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _ChevronButton(icon: Icons.remove, onPressed: onDecrement),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            // Animate the displayed value so a 1.6× → 1.7× change eases
            // through 1.61, 1.62, … instead of snapping.
            child: TweenAnimationBuilder<double>(
              tween: Tween<double>(end: level),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              builder: (context, value, _) => Text(
                '${value.toStringAsFixed(1)}×',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontFeatures: [FontFeature.tabularFigures()],
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          _ChevronButton(icon: Icons.add, onPressed: onIncrement),
        ],
      ),
    );
  }
}

class _ChevronButton extends StatefulWidget {
  const _ChevronButton({required this.icon, required this.onPressed});

  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_ChevronButton> createState() => _ChevronButtonState();
}

class _ChevronButtonState extends State<_ChevronButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        behavior: HitTestBehavior.opaque,
        child: Container(
          width: 18,
          height: 18,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _hover ? Colors.white24 : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Icon(widget.icon, size: 13, color: Colors.white),
        ),
      ),
    );
  }
}

class _ZoomDeleteButton extends StatelessWidget {
  const _ZoomDeleteButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onPressed,
        child: Container(
          width: 18,
          height: 18,
          decoration: BoxDecoration(
            color: const Color(0xFFE5484D),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 1.2),
            boxShadow: const [
              BoxShadow(
                color: Color(0x66000000),
                blurRadius: 4,
                offset: Offset(0, 1),
              ),
            ],
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.close, size: 12, color: Colors.white),
        ),
      ),
    );
  }
}

class _ZoomPillPainter extends CustomPainter {
  _ZoomPillPainter({
    required this.fillTop,
    required this.fill,
    required this.stroke,
    required this.zoomLevel,
    required this.enterPx,
    required this.exitPx,
    required this.showInternalGuides,
    required this.isSelected,
  });

  final Color fillTop;
  final Color fill;
  final Color stroke;
  final double zoomLevel;
  final double enterPx;
  final double exitPx;
  final bool showInternalGuides;
  final bool isSelected;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));

    // Three visually distinct phases — enter ramp / hold / exit ramp.
    // The hold uses the full saturated fill; enter and exit are clearly
    // de-saturated and faded on the outer edge so the user can read the
    // shape of the zoom at a glance. We clip to the rounded rect so the
    // segment seams align with the pill's outline.
    canvas.save();
    canvas.clipRRect(rrect);

    final clampedEnter = enterPx.clamp(0.0, size.width);
    final clampedExit = exitPx.clamp(clampedEnter, size.width);
    final holdColor = fill;
    // Enter ramp: horizontal gradient from the pill edge (low-alpha
    // de-saturated) into full saturated fill at the divider.
    if (clampedEnter > 0) {
      final enterRect = Rect.fromLTWH(0, 0, clampedEnter, size.height);
      canvas.drawRect(
        enterRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              holdColor.withValues(alpha: 0.45),
              holdColor,
            ],
          ).createShader(enterRect),
      );
    }
    // Hold: the bright, saturated middle.
    if (clampedExit > clampedEnter) {
      final holdRect = Rect.fromLTWH(
        clampedEnter, 0, clampedExit - clampedEnter, size.height);
      canvas.drawRect(
        holdRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [fillTop, holdColor],
          ).createShader(holdRect),
      );
    }
    // Exit ramp: mirror of enter — solid to faded on the right edge.
    if (clampedExit < size.width) {
      final exitRect = Rect.fromLTWH(
        clampedExit, 0, size.width - clampedExit, size.height);
      canvas.drawRect(
        exitRect,
        Paint()
          ..shader = LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: [
              holdColor,
              holdColor.withValues(alpha: 0.45),
            ],
          ).createShader(exitRect),
      );
    }

    canvas.restore();

    // Border on top of all segments.
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = isSelected ? 1.5 : 1
        ..color = stroke,
    );

    // Grip indicators on each end so the user knows the edges are draggable.
    final gripPaint = Paint()..color = const Color(0x55FFFFFF);
    for (final cx in [6.0, size.width - 6.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 1, size.height * 0.25, 2, size.height * 0.5),
          const Radius.circular(1),
        ),
        gripPaint,
      );
    }

    // Faint enter/exit ramp dividers, only while the pill is hovered.
    // The actual draggable handles are interactive Positioned widgets above
    // this layer; this just hints at where they live.
    if (showInternalGuides) {
      final guidePaint = Paint()..color = const Color(0x55FFFFFF);
      for (final cx in [enterPx, exitPx]) {
        if (cx > 6 && cx < size.width - 6) {
          canvas.drawLine(
            Offset(cx, size.height * 0.16),
            Offset(cx, size.height * 0.84),
            guidePaint..strokeWidth = 1,
          );
        }
      }
    }

    // Title + subtitle (only when the pill is wide enough to fit it).
    if (size.width < 60) return;
    final main = TextPainter(
      text: const TextSpan(
        text: 'Zoom',
        style: TextStyle(
          color: Color(0xFFFFFFFF),
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    final sub = TextPainter(
      text: TextSpan(
        text: '${zoomLevel.toStringAsFixed(zoomLevel == zoomLevel.roundToDouble() ? 0 : 1)}×  ·  Auto',
        style: const TextStyle(
          color: Color(0xCCFFFFFF),
          fontSize: 10,
          fontFeatures: [FontFeature.tabularFigures()],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: size.width - 16);
    final totalH = main.height + sub.height + 1;
    final cy = size.height / 2 - totalH / 2;
    main.paint(canvas, Offset(size.width / 2 - main.width / 2, cy));
    sub.paint(canvas,
        Offset(size.width / 2 - sub.width / 2, cy + main.height + 1));
  }

  @override
  bool shouldRepaint(_ZoomPillPainter old) =>
      old.fillTop != fillTop ||
      old.fill != fill ||
      old.stroke != stroke ||
      old.zoomLevel != zoomLevel ||
      old.enterPx != enterPx ||
      old.exitPx != exitPx ||
      old.showInternalGuides != showInternalGuides ||
      old.isSelected != isSelected;
}

// ──────────────────────────────── Playhead ──────────────────────────────

class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter({
    required this.progress,
    required this.hoverProgress,
    required this.rulerHeight,
  });

  final double progress;
  final double? hoverProgress;
  final double rulerHeight;

  static const _knobRadius = 6.5;
  static const _lineWidth = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    // Hover preview indicator (drawn first, so the regular playhead
    // sits on top when both end up at the same x). Only present when
    // the cursor is hovering the timeline and playback is paused.
    if (hoverProgress != null) {
      final hx = size.width * hoverProgress!;
      final hoverPaint = Paint()
        ..color = const Color(0x99FFFFFF)
        ..strokeWidth = 1;
      canvas.drawLine(
        Offset(hx, rulerHeight - 2),
        Offset(hx, size.height),
        hoverPaint,
      );
      // Small ring at the top so the ghost reads as an indicator,
      // not a stray line.
      canvas.drawCircle(
        Offset(hx, rulerHeight - 6),
        4,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = const Color(0xCCFFFFFF),
      );
    }

    final x = size.width * progress;
    final knobCenter = Offset(x, _knobRadius);
    final lineTop = _knobRadius + _knobRadius - 1;
    final lineRect = Rect.fromLTWH(
      x - _lineWidth / 2,
      lineTop,
      _lineWidth,
      size.height - lineTop,
    );

    // ── Vertical line: blue → dark purple → transparent
    final lineGradient = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        _playheadTop,
        _playheadMid,
        _playheadBottom,
        Color(0x003D26AA),
      ],
      stops: [0.0, 0.35, 0.7, 1.0],
    ).createShader(lineRect);

    // Soft outer glow for the line.
    final glowPaint = Paint()
      ..shader = lineGradient
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4)
      ..color = const Color(0xFF000000); // shader overrides; color carries alpha into mask
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        lineRect.inflate(0.5), const Radius.circular(2)),
      glowPaint,
    );

    // Solid line on top of the glow.
    canvas.drawRRect(
      RRect.fromRectAndRadius(lineRect, const Radius.circular(1.5)),
      Paint()..shader = lineGradient,
    );

    // ── Knob (button-like cap): drop shadow + outer glow + gradient fill +
    // inner highlight. Uses the same blue-to-purple palette but fully
    // opaque so it stays prominent.
    final knobRect = Rect.fromCircle(
      center: knobCenter,
      radius: _knobRadius,
    );
    final knobGradient = const LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [_playheadTop, _playheadBottom],
    ).createShader(knobRect);

    // Drop shadow underneath.
    canvas.drawCircle(
      knobCenter.translate(0, 1.5),
      _knobRadius,
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Soft outer cyan glow to tie the knob into the line.
    canvas.drawCircle(
      knobCenter,
      _knobRadius + 2,
      Paint()
        ..color = const Color(0x554FC3FF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // Gradient fill.
    canvas.drawCircle(
      knobCenter,
      _knobRadius,
      Paint()..shader = knobGradient,
    );
    // Crisp 1px ring so the knob reads against light backgrounds too.
    canvas.drawCircle(
      knobCenter,
      _knobRadius,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0x88FFFFFF),
    );
    // Specular highlight.
    canvas.drawCircle(
      knobCenter.translate(0, -1.8),
      2.2,
      Paint()..color = const Color(0x88FFFFFF),
    );
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      old.progress != progress ||
      old.hoverProgress != hoverProgress ||
      old.rulerHeight != rulerHeight;
}
