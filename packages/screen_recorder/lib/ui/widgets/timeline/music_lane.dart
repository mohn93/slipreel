import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/audio/music_track.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

import 'package:screen_recorder/ui/widgets/timeline/timeline_constants.dart';

/// Pointer kinds that count as a real "grab and drag" on the music bar and its
/// edge handles. Trackpad pan is excluded on purpose so a two-finger scroll
/// over the bar pans the timeline instead of sliding the bar — matching the
/// zoom pill's gesture policy.
const Set<PointerDeviceKind> _kBarDragDevices = {
  PointerDeviceKind.mouse,
  PointerDeviceKind.touch,
  PointerDeviceKind.stylus,
  PointerDeviceKind.invertedStylus,
};

/// Shortest bed the bar can be dragged to, in edited seconds.
const double _kMinMusicLength = 0.2;

enum _MusicDragMode { none, body, leftEdge, rightEdge }

/// Music uses edited seconds: cuts and clip speed never stretch the music.
///
/// The bar behaves like the other timeline bars — selectable, hover-lit, and
/// resizable from either edge. Body drag moves the whole bed, the left handle
/// sets where it starts, and the right handle sets an explicit end (stored as
/// [MusicTrack.endOverride]) so a looping bed can stop before the video ends.
class MusicLane extends ConsumerStatefulWidget {
  const MusicLane({
    super.key,
    required this.pixelsPerSecond,
    required this.duration,
    this.selected = false,
    this.onSelected,
  });
  final double pixelsPerSecond, duration;
  final bool selected;
  final VoidCallback? onSelected;

  @override
  ConsumerState<MusicLane> createState() => _MusicLaneState();
}

class _MusicLaneState extends ConsumerState<MusicLane> {
  _MusicDragMode _mode = _MusicDragMode.none;
  bool _hovered = false;
  double _dxAccum = 0;
  double _dragStartStart = 0;
  double _dragStartEnd = 0;
  MusicTrack? _preview;

  double get _pps => widget.pixelsPerSecond;
  double get _duration => widget.duration;

  double _effectiveEnd(MusicTrack t) => t.start + t.length(_duration);

  void _beginMode(_MusicDragMode mode, MusicTrack track) {
    _dxAccum = 0;
    _dragStartStart = track.start;
    _dragStartEnd = _effectiveEnd(track);
    _mode = mode;
    widget.onSelected?.call();
  }

  void _update(double dxDelta, MusicTrack track) {
    if (_pps <= 0) return;
    _dxAccum += dxDelta;
    final delta = _dxAccum / _pps;
    final segment = track.segmentDuration;
    // Non-loop beds can never be longer than the trimmed audio they hold, so
    // their span is capped at the segment length; looping beds may run to the
    // video end.
    final maxSpan = track.loop ? _duration : segment;

    var start = _dragStartStart;
    var end = _dragStartEnd;
    switch (_mode) {
      case _MusicDragMode.body:
        if (track.loop && track.endOverride == null) {
          // A looping bed with no explicit end already fills to the video
          // end, so there is no whole-bar span to slide — dragging the body
          // just moves where it starts and the right edge stays pinned to the
          // end. (Sliding a fixed-length bar is handled below.)
          start = (_dragStartStart + delta).clamp(
            0.0,
            (_duration - _kMinMusicLength).clamp(0.0, _duration),
          );
          end = _duration;
        } else {
          final span = _dragStartEnd - _dragStartStart;
          start = (_dragStartStart + delta).clamp(
            0.0,
            (_duration - span).clamp(0.0, _duration),
          );
          end = start + span;
        }
        break;
      case _MusicDragMode.leftEdge:
        final minStart = (end - maxSpan).clamp(0.0, double.infinity);
        start = (_dragStartStart + delta).clamp(minStart, end - _kMinMusicLength);
        break;
      case _MusicDragMode.rightEdge:
        final maxEnd = (start + maxSpan).clamp(0.0, _duration);
        end = (_dragStartEnd + delta).clamp(start + _kMinMusicLength, maxEnd);
        break;
      case _MusicDragMode.none:
        return;
    }

    // The bed's natural end (no override) is the video end when looping, else
    // the end of its one segment. Only store an override when the drag pulls
    // the end short of that, so the loop-fills-to-end default is preserved and
    // survives later changes to the video duration.
    final naturalEnd = track.loop ? _duration : start + segment;
    final double? endOverride = end >= naturalEnd - 1e-3 ? null : end;
    setState(() {
      _preview = track.copyWith(start: start, endOverride: endOverride);
    });
  }

  void _endDrag() {
    final committed = _preview;
    final ctl = ref.read(editorProjectControllerProvider.notifier);
    final current = ctl.current.timeline.music;
    setState(() {
      _mode = _MusicDragMode.none;
      _dxAccum = 0;
      _preview = null;
    });
    if (committed != null && current != null && committed != current) {
      ctl.setMusic(committed);
    }
  }

  @override
  Widget build(BuildContext context) {
    final music = ref.watch(editorProjectControllerProvider).timeline.music;
    if (music == null) return const SizedBox.shrink();
    final render = _preview ?? music;
    final length = render.length(_duration);

    return ClipRect(
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // No lane background of its own — like the other lanes, it shows the
          // timeline's own backdrop so the row blends in.
          const Positioned.fill(child: SizedBox.expand()),
          if (length > 0)
            AnimatedPositioned(
              duration: _mode == _MusicDragMode.none
                  ? const Duration(milliseconds: 180)
                  : Duration.zero,
              curve: Curves.easeOutCubic,
              left: render.start * _pps,
              width: (length * _pps).clamp(handleHitWidth * 2, double.infinity),
              top: 2,
              bottom: 2,
              child: MouseRegion(
                onEnter: (_) => setState(() => _hovered = true),
                onExit: (_) => setState(() => _hovered = false),
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Positioned.fill(child: _MusicBody(track: render, selected: widget.selected, muted: music.muted, onDragStart: () => _beginMode(_MusicDragMode.body, music), onDragUpdate: (d) => _update(d, music), onDragEnd: _endDrag, onTap: () => widget.onSelected?.call())),
                    Positioned(
                      left: 0,
                      top: 0,
                      bottom: 0,
                      width: handleHitWidth,
                      child: _MusicEdgeHandle(
                        alignment: Alignment.centerLeft,
                        showHandle: _hovered,
                        onDragStart: () =>
                            _beginMode(_MusicDragMode.leftEdge, music),
                        onDragUpdate: (d) => _update(d, music),
                        onDragEnd: _endDrag,
                        onTap: () => widget.onSelected?.call(),
                      ),
                    ),
                    Positioned(
                      right: 0,
                      top: 0,
                      bottom: 0,
                      width: handleHitWidth,
                      child: _MusicEdgeHandle(
                        alignment: Alignment.centerRight,
                        showHandle: _hovered,
                        onDragStart: () =>
                            _beginMode(_MusicDragMode.rightEdge, music),
                        onDragUpdate: (d) => _update(d, music),
                        onDragEnd: _endDrag,
                        onTap: () => widget.onSelected?.call(),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The bar body: fill, border, centered label. Translates on drag, selects on
/// tap. Uses a raw horizontal-drag recognizer so trackpad pan pans the
/// timeline rather than dragging the bar.
class _MusicBody extends StatelessWidget {
  const _MusicBody({
    required this.track,
    required this.selected,
    required this.muted,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  final MusicTrack track;
  final bool selected;
  final bool muted;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final base = muted ? const Color(0xFF393946) : const Color(0xFF275E51);
    final fill = selected
        ? (muted ? const Color(0xFF4A4A5C) : const Color(0xFF2F7565))
        : base;
    final stroke = selected ? Colors.white : const Color(0xFF58BA94);
    return MouseRegion(
      cursor: SystemMouseCursors.grab,
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (instance) => instance.onTapDown = (_) => onTap(),
              ),
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(
                () => HorizontalDragGestureRecognizer(
                  supportedDevices: _kBarDragDevices,
                ),
                (instance) {
                  instance
                    ..onStart = ((_) => onDragStart())
                    ..onUpdate = ((d) => onDragUpdate(d.delta.dx))
                    ..onEnd = ((_) => onDragEnd())
                    ..onCancel = onDragEnd;
                },
              ),
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOutCubic,
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: fill,
            border: Border.all(color: stroke, width: selected ? 1.5 : 1),
            borderRadius: BorderRadius.circular(7),
            boxShadow: selected
                ? const [
                    BoxShadow(
                      color: Color(0x5558BA94),
                      blurRadius: 8,
                      spreadRadius: 0.5,
                    ),
                  ]
                : null,
          ),
          child: Text(
            '♫ ${track.name}${track.loop ? ' · Loop' : ''}',
            textAlign: TextAlign.center,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Color(0xFFDCF8EA),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

/// Resize handle anchored to one edge of the music bar. Invisible until the
/// bar is hovered, then fades in dim and brightens on direct hover — the same
/// affordance the zoom pill uses.
class _MusicEdgeHandle extends StatefulWidget {
  const _MusicEdgeHandle({
    required this.alignment,
    required this.showHandle,
    required this.onDragStart,
    required this.onDragUpdate,
    required this.onDragEnd,
    required this.onTap,
  });

  final Alignment alignment;
  final bool showHandle;
  final VoidCallback onDragStart;
  final ValueChanged<double> onDragUpdate;
  final VoidCallback onDragEnd;
  final VoidCallback onTap;

  @override
  State<_MusicEdgeHandle> createState() => _MusicEdgeHandleState();
}

class _MusicEdgeHandleState extends State<_MusicEdgeHandle> {
  bool _hover = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final emphasized = _hover || _dragging;
    final visible = widget.showHandle || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeLeftRight,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: RawGestureDetector(
        behavior: HitTestBehavior.opaque,
        gestures: <Type, GestureRecognizerFactory>{
          TapGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                () => TapGestureRecognizer(),
                (instance) => instance.onTapDown = (_) => widget.onTap(),
              ),
          HorizontalDragGestureRecognizer:
              GestureRecognizerFactoryWithHandlers<
                HorizontalDragGestureRecognizer
              >(
                () => HorizontalDragGestureRecognizer(
                  supportedDevices: _kBarDragDevices,
                ),
                (instance) {
                  instance
                    ..onStart = ((_) {
                      setState(() => _dragging = true);
                      widget.onDragStart();
                    })
                    ..onUpdate = ((d) => widget.onDragUpdate(d.delta.dx))
                    ..onEnd = ((_) {
                      setState(() => _dragging = false);
                      widget.onDragEnd();
                    })
                    ..onCancel = (() {
                      setState(() => _dragging = false);
                      widget.onDragEnd();
                    });
                },
              ),
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
          child: Align(
            alignment: widget.alignment,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: emphasized ? 4 : 3,
              decoration: BoxDecoration(
                color: !visible
                    ? Colors.transparent
                    : (emphasized
                          ? Colors.white
                          : Colors.white.withValues(alpha: 0.30)),
                borderRadius: BorderRadius.circular(4),
                boxShadow: emphasized && visible
                    ? const [
                        BoxShadow(
                          color: Color(0xCC000000),
                          blurRadius: 6,
                          offset: Offset(0, 1),
                        ),
                        BoxShadow(
                          color: Color(0x8058BA94),
                          blurRadius: 8,
                          spreadRadius: 0.5,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
