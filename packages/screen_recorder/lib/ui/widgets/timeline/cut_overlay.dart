import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color _accent = Color(0xFF6C63FF);

/// Overlay rendered above the clip lane while cut mode is active.
/// Updates [cursorX] on mouse move (used by the parent timeline to
/// paint the dashed indicator and route cut commits). Paints a 1px
/// dashed accent vertical line + a small scissors glyph at the cursor,
/// commits the cut on tap, exits on Esc.
class CutOverlay extends StatefulWidget {
  const CutOverlay({
    super.key,
    required this.pixelsPerSecond,
    required this.totalEditedDuration,
    required this.cursorX,
    required this.onCommitCut,
    required this.onExitMode,
  });

  final double pixelsPerSecond;
  final Duration totalEditedDuration;
  final ValueNotifier<double?> cursorX;
  final void Function(Duration editedTime, {required bool overrideSnap}) onCommitCut;
  final VoidCallback onExitMode;

  @override
  State<CutOverlay> createState() => _CutOverlayState();
}

class _CutOverlayState extends State<CutOverlay> {
  late final FocusNode _focus;

  // Full pointer position within the overlay. widget.cursorX is the 1-D
  // public notifier (used by ClipLane's magnetic pull); we additionally
  // track the Y locally so the painted scissors glyph can sit AT the
  // cursor rather than at a fixed offset — that's what makes it read
  // as "the cursor IS a scissor" once the system cursor is hidden.
  final ValueNotifier<Offset?> _local = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _focus = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _local.dispose();
    _focus.dispose();
    super.dispose();
  }

  Duration _editedTimeAt(double x) {
    final ms = (x / widget.pixelsPerSecond * 1000.0).round();
    return Duration(milliseconds: ms);
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focus,
      onKeyEvent: (_, e) {
        if (e is KeyDownEvent && e.logicalKey == LogicalKeyboardKey.escape) {
          widget.onExitMode();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: MouseRegion(
        // Hide the OS cursor so the painted scissors below reads as the
        // cursor itself. Without this the user would see the precise
        // crosshair AND a tiny glyph next to it — two cursors.
        cursor: SystemMouseCursors.none,
        // onEnter ensures the cursor x is set the moment the pointer
        // enters the overlay — onHover alone only fires on motion, so
        // a static pointer (or the first frame after add) would leave
        // SliceBar's magnetic pull blind to the cursor.
        onEnter: (e) {
          widget.cursorX.value = e.localPosition.dx;
          _local.value = e.localPosition;
        },
        onHover: (e) {
          widget.cursorX.value = e.localPosition.dx;
          _local.value = e.localPosition;
        },
        onExit: (_) {
          widget.cursorX.value = null;
          _local.value = null;
        },
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (d) {
            widget.onCommitCut(
              _editedTimeAt(d.localPosition.dx),
              overrideSnap: HardwareKeyboard.instance.isAltPressed,
            );
          },
          child: ValueListenableBuilder<Offset?>(
            valueListenable: _local,
            builder: (_, pos, __) {
              if (pos == null) return const SizedBox.expand();
              // Clip.none so the 22-px scissors glyph doesn't get
              // hard-clipped when the cursor is near the top or
              // bottom edge of the lane (it would otherwise lose a
              // few pixels off the icon as it slid in/out of the
              // overlay's bounds).
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    key: const ValueKey('cut-overlay-dashed-indicator'),
                    left: pos.dx - 0.5,
                    top: 0,
                    bottom: 0,
                    width: 1,
                    child: const _DashedVerticalLine(color: _accent),
                  ),
                  // 22-px glyph centered at the cursor so the icon
                  // itself acts as the cursor. White with a soft
                  // drop-shadow so it stays legible on top of the
                  // orange clip body AND the dark track background.
                  Positioned(
                    left: pos.dx - 11,
                    top: pos.dy - 11,
                    child: const IgnorePointer(
                      child: Icon(
                        Icons.content_cut,
                        size: 22,
                        color: Colors.white,
                        shadows: [
                          Shadow(
                            color: Color(0x99000000),
                            blurRadius: 6,
                            offset: Offset(0, 2),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

class _DashedVerticalLine extends StatelessWidget {
  const _DashedVerticalLine({required this.color});
  final Color color;
  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DashedPainter(color: color),
      size: const Size(1, double.infinity),
    );
  }
}

class _DashedPainter extends CustomPainter {
  _DashedPainter({required this.color});
  final Color color;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    const dash = 4.0;
    const gap = 3.0;
    var y = 0.0;
    while (y < size.height) {
      canvas.drawLine(
        Offset(0, y),
        Offset(0, (y + dash).clamp(0, size.height)),
        paint,
      );
      y += dash + gap;
    }
  }

  @override
  bool shouldRepaint(_DashedPainter old) => old.color != color;
}
