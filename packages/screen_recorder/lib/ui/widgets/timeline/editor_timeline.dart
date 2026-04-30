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
const _playheadColor = Color(0xFFFF4D6D);

const double _rulerHeight = 26;
const double _laneHeight = 46;
const double _laneSpacing = 6;
const double _handleHitWidth = 16;
const double _zoomPillInset = 2;
const int _minZoomDurationMs = 250;

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
class EditorTimeline extends StatelessWidget {
  const EditorTimeline({
    super.key,
    required this.duration,
    required this.position,
    required this.onSeek,
    this.zoomRegions = const [],
    this.selectedZoomIndex,
    this.onZoomChanged,
    this.onZoomSelected,
    this.playbackSpeedLabel = '1x',
  });

  final Duration duration;
  final Duration position;
  final ValueChanged<Duration> onSeek;
  final List<ZoomRegion> zoomRegions;
  final int? selectedZoomIndex;
  final void Function(int index, ZoomRegion next)? onZoomChanged;
  final ValueChanged<int?>? onZoomSelected;
  final String playbackSpeedLabel;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final hasZooms = zoomRegions.isNotEmpty;
        final totalHeight = _rulerHeight +
            _laneSpacing +
            _laneHeight +
            (hasZooms ? _laneSpacing + _laneHeight : 0);

        return SizedBox(
          height: totalHeight,
          width: width,
          child: Stack(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SizedBox(
                    height: _rulerHeight,
                    child: _TimeRuler(
                        duration: duration, width: width, onSeek: onSeek),
                  ),
                  const SizedBox(height: _laneSpacing),
                  SizedBox(
                    height: _laneHeight,
                    child: _ClipLane(
                      duration: duration,
                      width: width,
                      onSeek: onSeek,
                      speedLabel: playbackSpeedLabel,
                    ),
                  ),
                  if (hasZooms) ...[
                    const SizedBox(height: _laneSpacing),
                    SizedBox(
                      height: _laneHeight,
                      child: _ZoomLane(
                        duration: duration,
                        width: width,
                        zoomRegions: zoomRegions,
                        selectedIndex: selectedZoomIndex,
                        onZoomChanged: onZoomChanged,
                        onZoomSelected: onZoomSelected,
                        onSeek: onSeek,
                      ),
                    ),
                  ],
                ],
              ),
              IgnorePointer(
                child: CustomPaint(
                  size: Size(width, totalHeight),
                  painter: _PlayheadPainter(
                    progress: duration.inMicroseconds == 0
                        ? 0
                        : (position.inMicroseconds / duration.inMicroseconds)
                            .clamp(0.0, 1.0),
                    rulerHeight: _rulerHeight,
                  ),
                ),
              ),
            ],
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
  });

  final Duration duration;
  final double width;
  final List<ZoomRegion> zoomRegions;
  final ValueChanged<Duration> onSeek;
  final int? selectedIndex;
  final void Function(int, ZoomRegion)? onZoomChanged;
  final ValueChanged<int?>? onZoomSelected;

  @override
  Widget build(BuildContext context) {
    return Stack(
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

    widget.onChanged!(
      widget.index,
      widget.zoom.copyWith(
        startTime: nextStart,
        duration: nextEnd - nextStart,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final left = _startX;
    final width = (_endX - _startX).clamp(_handleHitWidth * 2, double.infinity);
    final cursor = _cursorForMode(_mode);
    final fillTop = widget.isSelected ? _zoomFillSelected : _zoomFillTop;
    final fill = widget.isSelected ? _zoomFillSelected : _zoomFill;
    final stroke = widget.isSelected ? Colors.white : _zoomStroke;

    return Positioned(
      left: left,
      top: _zoomPillInset,
      width: width,
      height: _laneHeight - _zoomPillInset * 2,
      child: MouseRegion(
        cursor: cursor,
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
              isSelected: widget.isSelected,
            ),
          ),
        ),
      ),
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

class _ZoomPillPainter extends CustomPainter {
  _ZoomPillPainter({
    required this.fillTop,
    required this.fill,
    required this.stroke,
    required this.zoomLevel,
    required this.isSelected,
  });

  final Color fillTop;
  final Color fill;
  final Color stroke;
  final double zoomLevel;
  final bool isSelected;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(7));
    final gradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [fillTop, fill],
    );
    canvas.drawRRect(rrect, Paint()..shader = gradient.createShader(rect));
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
      old.isSelected != isSelected;
}

// ──────────────────────────────── Playhead ──────────────────────────────

class _PlayheadPainter extends CustomPainter {
  _PlayheadPainter({required this.progress, required this.rulerHeight});

  final double progress;
  final double rulerHeight;

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width * progress;

    final linePaint = Paint()
      ..color = _playheadColor
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(x, rulerHeight - 4), Offset(x, size.height), linePaint);

    // Top-of-ruler caret so the playhead reads from the timecode strip.
    final caretPaint = Paint()..color = _playheadColor;
    final caret = Path()
      ..moveTo(x - 4, 0)
      ..lineTo(x + 4, 0)
      ..lineTo(x, 6)
      ..close();
    canvas.drawPath(caret, caretPaint);
  }

  @override
  bool shouldRepaint(_PlayheadPainter old) =>
      old.progress != progress || old.rulerHeight != rulerHeight;
}
