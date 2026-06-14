import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/rendering/animation_config.dart';
import 'package:slipreel_engine/rendering/animation_style.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:slipreel_engine/services/curve_library.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Animation tab — screen / cursor animation styles + motion blur.
///
/// Screen and cursor styles write through to the playback render
/// pipeline. Motion blur drives directional cursor stamps + an
/// anisotropic Gaussian on the screen layer; both are speed-gated so
/// the slider only takes effect when something is actually moving.
class AnimationTab extends ConsumerStatefulWidget {
  const AnimationTab({super.key, required this.library});

  /// Persistence for the curve-editor's Library row. A service object,
  /// not editor state — passed in so saves survive tab rebuilds.
  final CurveLibrary library;

  @override
  ConsumerState<AnimationTab> createState() => _AnimationTabState();
}

class _AnimationTabState extends ConsumerState<AnimationTab> {
  EditorProjectController get _notifier =>
      ref.read(editorProjectControllerProvider.notifier);

  @override
  Widget build(BuildContext context) {
    final project = ref.watch(editorProjectControllerProvider);
    return ListView(
      // Right-side gutter keeps the curve editor's drag area clear of
      // the macOS Scrollbar's hit zone — without it, dragging a handle
      // near the right edge gets intercepted by the scrollbar.
      padding: const EdgeInsets.only(right: 12),
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
                selected: project.screenAnimationConfig.preset,
                label: s.label,
                icon: _screenIcon(s),
                previewCurve: s.previewCurve,
                previewDuration: s.previewDuration,
                onSelected: (s) => _notifier.setScreenAnimationConfig(
                  ScreenAnimationConfig.preset(s),
                ),
                size: 84,
              ),
          ],
        ),
        const SizedBox(height: 12),
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
                selected: project.cursorAnimationConfig.preset,
                label: s.label,
                icon: _cursorIcon(s),
                previewCurve: s.previewCurve,
                previewDuration: s.previewDuration,
                onSelected: (s) => _notifier.setCursorAnimationConfig(
                  CursorAnimationConfig.preset(s),
                ),
                size: 76,
              ),
          ],
        ),
        const SizedBox(height: 12),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Motion blur',
          subtitle:
              'While mouse cursor or screen is moving, cinematic motion '
              'blur effect will be applied.',
          value: project.motionBlur.clamp(0.0, 0.5),
          min: 0,
          max: 0.5,
          onChanged: _notifier.setMotionBlur,
          onReset: () => _notifier.setMotionBlur(0),
          canReset: project.motionBlur != 0,
        ),
        const SizedBox(height: 24),
        InspectorCollapsible(
          title: 'Advanced motion blur settings',
          child: Column(
            children: [
              InspectorSlider(
                label: 'Cursor movement',
                subtitle: 'Caps blur from the cursor path.',
                value: project.cursorMovementBlur.clamp(0.0, 1.0),
                min: 0,
                max: 1,
                onChanged: _notifier.setCursorMovementBlur,
                onReset: () => _notifier.setCursorMovementBlur(1),
                canReset: project.cursorMovementBlur != 1,
              ),
              const SizedBox(height: 16),
              InspectorSlider(
                label: 'Screen movement',
                subtitle: 'Caps blur from camera pan / focal movement.',
                value: project.screenMovementBlur.clamp(0.0, 1.0),
                min: 0,
                max: 1,
                onChanged: _notifier.setScreenMovementBlur,
                onReset: () => _notifier.setScreenMovementBlur(1),
                canReset: project.screenMovementBlur != 1,
              ),
              const SizedBox(height: 16),
              InspectorSlider(
                label: 'Screen zoom',
                subtitle: 'Caps radial blur from zoom ramps.',
                value: project.screenZoomBlur.clamp(0.0, 1.0),
                min: 0,
                max: 1,
                onChanged: _notifier.setScreenZoomBlur,
                onReset: () => _notifier.setScreenZoomBlur(1),
                canReset: project.screenZoomBlur != 1,
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  static IconData _screenIcon(ScreenAnimationStyle s) => switch (s) {
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
  // Nullable: when the parent's config is in custom mode, no preset is
  // selected — rendered with `==` against null so all preset tiles
  // appear unselected, which is correct.
  final T? selected;
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
  // Created eagerly in initState rather than via a `late final` field
  // initializer — a lazy field would only construct on first access,
  // and if the tile was never hovered before its parent unmounts the
  // initializer would run inside dispose(), where creating a Ticker
  // (via SingleTickerProviderStateMixin) calls
  // getInheritedWidgetOfExactType on a deactivated element and throws
  // "Looking up a deactivated widget's ancestor is unsafe."
  late final AnimationController _ctrl;
  bool _hover = false;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(vsync: this, duration: widget.previewDuration);
  }

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
    // Outer MouseRegion controls the demo-track repeat animation; the
    // inner SpringHoverButton owns the springy lean + tilt + press. They
    // coexist — each gets its own onEnter/onExit independently — and we
    // only spring-wrap the body square, not the caption below it.
    return MouseRegion(
      onEnter: (_) => _onHover(true),
      onExit: (_) => _onHover(false),
      child: SizedBox(
        width: widget.size,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SpringHoverButton(
              onTap: () => widget.onSelected(widget.value),
              borderRadius: 12,
              child: Container(
                width: widget.size,
                height: widget.size,
                decoration: BoxDecoration(
                  color: kInspectorPanel,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: isSelected ? kInspectorAccent : kInspectorBorder,
                    width: 1,
                  ),
                ),
                alignment: Alignment.center,
                child: _hover
                    ? _DemoTrack(controller: _ctrl, curve: widget.previewCurve)
                    : Icon(widget.icon, color: Colors.white, size: 22),
              ),
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
    canvas.drawCircle(Offset(dotX, y), 6, Paint()..color = kInspectorAccent);
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
