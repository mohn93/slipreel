import 'package:flutter/material.dart';
import 'package:screen_recorder/rendering/animation_style.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Animation tab — screen / cursor animation styles + motion blur.
///
/// Screen and cursor styles write through to the playback render
/// pipeline. Motion blur is still state-only (proper motion blur
/// needs a separate cursor-trail or shader pass).
class AnimationTab extends StatefulWidget {
  const AnimationTab({
    super.key,
    required this.screenStyle,
    required this.onScreenStyleChanged,
    required this.cursorStyle,
    required this.onCursorStyleChanged,
    required this.motionBlur,
    required this.onMotionBlurChanged,
  });

  final ScreenAnimationStyle screenStyle;
  final ValueChanged<ScreenAnimationStyle> onScreenStyleChanged;
  final CursorAnimationStyle cursorStyle;
  final ValueChanged<CursorAnimationStyle> onCursorStyleChanged;
  final double motionBlur;
  final ValueChanged<double> onMotionBlurChanged;

  @override
  State<AnimationTab> createState() => _AnimationTabState();
}

class _AnimationTabState extends State<AnimationTab> {
  static const _screenDefault = ScreenAnimationStyle.smooth;
  static const _cursorDefault = CursorAnimationStyle.smooth;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const Text(
          'Screen animation style',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in ScreenAnimationStyle.values)
              _AnimationOptionTile<ScreenAnimationStyle>(
                value: s,
                selected: widget.screenStyle,
                label: s.label,
                icon: _screenIcon(s),
                previewCurve: s.previewCurve,
                previewDuration: s.previewDuration,
                onSelected: widget.onScreenStyleChanged,
                size: 84,
              ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          widget.screenStyle.description,
          style: const TextStyle(
            color: kInspectorMuted,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 12),
        if (widget.screenStyle != _screenDefault)
          _ResetButton(
            onTap: () => widget.onScreenStyleChanged(_screenDefault),
          ),
        const InspectorSectionDivider(),
        const Text(
          'Cursor animation style',
          style: TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            for (final s in CursorAnimationStyle.values)
              _AnimationOptionTile<CursorAnimationStyle>(
                value: s,
                selected: widget.cursorStyle,
                label: s.label,
                icon: _cursorIcon(s),
                previewCurve: s.previewCurve,
                previewDuration: s.previewDuration,
                onSelected: widget.onCursorStyleChanged,
                size: 76,
              ),
          ],
        ),
        if (widget.cursorStyle != _cursorDefault) ...[
          const SizedBox(height: 12),
          _ResetButton(
            onTap: () => widget.onCursorStyleChanged(_cursorDefault),
          ),
        ],
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Motion blur',
          subtitle:
              'While mouse cursor or screen is moving, cinematic '
              'motion blur effect will be applied. (Coming soon — '
              'value is captured but not yet rendered.)',
          value: widget.motionBlur,
          min: 0,
          max: 1,
          onChanged: widget.onMotionBlurChanged,
          onReset: () => widget.onMotionBlurChanged(0),
          canReset: widget.motionBlur != 0,
        ),
        const SizedBox(height: 24),
        const InspectorCollapsible(
          title: 'Advanced motion blur settings',
          child: Text(
            'Per-component blur tuning. Coming soon.',
            style: TextStyle(
              color: Colors.white60,
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static IconData _screenIcon(ScreenAnimationStyle s) =>
      switch (s) {
        ScreenAnimationStyle.focused => Icons.adjust,
        ScreenAnimationStyle.smooth => Icons.timeline,
      };

  static IconData _cursorIcon(CursorAnimationStyle s) => switch (s) {
        CursorAnimationStyle.smooth => Icons.touch_app_outlined,
        CursorAnimationStyle.medium => Icons.swipe,
        CursorAnimationStyle.rapid => Icons.bolt,
        CursorAnimationStyle.none => Icons.near_me,
      };
}

/// Tile that defaults to icon + label, but on hover swaps the icon
/// for an animated horizontal track previewing the option's curve.
/// One [AnimationController] per tile, only ticking while hovered.
class _AnimationOptionTile<T> extends StatefulWidget {
  const _AnimationOptionTile({
    super.key,
    required this.value,
    required this.selected,
    required this.label,
    required this.icon,
    required this.previewCurve,
    required this.previewDuration,
    required this.onSelected,
    required this.size,
  });

  final T value;
  final T selected;
  final String label;
  final IconData icon;
  final Curve previewCurve;
  final Duration previewDuration;
  final ValueChanged<T> onSelected;
  final double size;

  @override
  State<_AnimationOptionTile<T>> createState() =>
      _AnimationOptionTileState<T>();
}

class _AnimationOptionTileState<T> extends State<_AnimationOptionTile<T>>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl = AnimationController(
    vsync: this,
    duration: widget.previewDuration,
  );
  bool _hover = false;

  @override
  void didUpdateWidget(_AnimationOptionTile<T> old) {
    super.didUpdateWidget(old);
    if (old.previewDuration != widget.previewDuration) {
      _ctrl.duration = widget.previewDuration;
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onHover(bool hovered) {
    if (hovered == _hover) return;
    setState(() => _hover = hovered);
    if (hovered) {
      _ctrl.repeat(reverse: true);
    } else {
      _ctrl.stop();
      _ctrl.value = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    final isSelected = widget.value == widget.selected;
    return MouseRegion(
      onEnter: (_) => _onHover(true),
      onExit: (_) => _onHover(false),
      child: InkWell(
        onTap: () => widget.onSelected(widget.value),
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: widget.size,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                height: widget.size,
                decoration: BoxDecoration(
                  color: kInspectorPanel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected
                        ? kInspectorAccent
                        : kInspectorBorder,
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: _hover
                    ? _DemoTrack(
                        controller: _ctrl,
                        curve: widget.previewCurve,
                      )
                    : Icon(widget.icon,
                        color: Colors.white, size: 22),
              ),
              const SizedBox(height: 6),
              Text(
                widget.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DemoTrack extends StatelessWidget {
  const _DemoTrack({required this.controller, required this.curve});
  final AnimationController controller;
  final Curve curve;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = curve.transform(controller.value);
        return CustomPaint(
          painter: _DemoTrackPainter(progress: t),
          size: const Size(double.infinity, double.infinity),
        );
      },
    );
  }
}

class _DemoTrackPainter extends CustomPainter {
  _DemoTrackPainter({required this.progress});
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = 12.0;
    final y = size.height / 2;
    final left = Offset(inset, y);
    final right = Offset(size.width - inset, y);

    canvas.drawLine(
      left,
      right,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    final dotX = left.dx + (right.dx - left.dx) * progress.clamp(0.0, 1.0);
    canvas.drawCircle(
      Offset(dotX, y),
      6,
      Paint()..color = kInspectorAccent,
    );
    canvas.drawCircle(
      Offset(dotX, y),
      6,
      Paint()
        ..style = PaintingStyle.stroke
        ..color = Colors.white.withValues(alpha: 0.7)
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _DemoTrackPainter old) =>
      old.progress != progress;
}

class _ResetButton extends StatelessWidget {
  const _ResetButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: kInspectorBorder),
        ),
        alignment: Alignment.center,
        child: const Text(
          'Reset',
          style: TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
