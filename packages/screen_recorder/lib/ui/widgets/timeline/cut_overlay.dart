import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

const Color _accent = Color(0xFF6C63FF);

/// Overlay rendered above the clip lane while cut mode is active.
/// Updates [cursorX] on mouse move (used by SliceBar's magnetic pull),
/// paints a 1px dashed accent vertical line + a small scissors glyph
/// at the cursor, commits the cut on tap, and exits on Esc.
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
        cursor: SystemMouseCursors.precise,
        // onEnter ensures the cursor x is set the moment the pointer
        // enters the overlay — onHover alone only fires on motion, so
        // a static pointer (or the first frame after add) would leave
        // SliceBar's magnetic pull blind to the cursor.
        onEnter: (e) => widget.cursorX.value = e.localPosition.dx,
        onHover: (e) => widget.cursorX.value = e.localPosition.dx,
        onExit: (_) => widget.cursorX.value = null,
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTapDown: (d) {
            widget.onCommitCut(
              _editedTimeAt(d.localPosition.dx),
              overrideSnap: HardwareKeyboard.instance.isAltPressed,
            );
          },
          child: ValueListenableBuilder<double?>(
            valueListenable: widget.cursorX,
            builder: (_, x, __) {
              if (x == null) return const SizedBox.expand();
              return Stack(
                children: [
                  Positioned(
                    key: const ValueKey('cut-overlay-dashed-indicator'),
                    left: x - 0.5,
                    top: 0,
                    bottom: 0,
                    width: 1,
                    child: const _DashedVerticalLine(color: _accent),
                  ),
                  Positioned(
                    left: x + 6,
                    top: 6,
                    child: const Icon(
                      Icons.content_cut,
                      size: 14,
                      color: _accent,
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
