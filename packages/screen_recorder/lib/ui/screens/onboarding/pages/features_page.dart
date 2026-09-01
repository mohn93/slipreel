import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/onboarding_video.dart';

/// One entry in the onboarding feature showcase.
class _Feature {
  const _Feature(this.tab, this.title, this.blurb, this.asset, this.poster);
  final String tab;
  final String title;
  final String blurb;
  final String asset;
  final String poster;
}

const _features = <_Feature>[
  _Feature(
    'Zoom',
    'Automatic zoom',
    'Slipreel zooms into the action as you click, then eases smoothly back out.',
    'assets/onboarding/beat-zoom.mp4',
    'assets/onboarding/beat-zoom-poster.webp',
  ),
  _Feature(
    'Cursor',
    'Polished cursor',
    'A smooth, size-adjustable cursor with click highlights — no jitter.',
    'assets/onboarding/beat-cursor.mp4',
    'assets/onboarding/beat-cursor-poster.webp',
  ),
  _Feature(
    'Keystrokes',
    'Keystroke overlays',
    'Show the keys you press, styled to match your recording.',
    'assets/onboarding/beat-keystrokes.mp4',
    'assets/onboarding/beat-keystrokes-poster.webp',
  ),
  _Feature(
    'Captions',
    'Auto captions',
    'On-device transcription burns in clean, readable captions.',
    'assets/onboarding/beat-captions.mp4',
    'assets/onboarding/beat-captions-poster.webp',
  ),
  _Feature(
    'Frames',
    'Backdrops & frames',
    'Drop your recording onto gradients, wallpapers, and device frames.',
    'assets/onboarding/beat-frames.mp4',
    'assets/onboarding/beat-frames-poster.webp',
  ),
];

class FeaturesPage extends StatefulWidget {
  const FeaturesPage({super.key, required this.onNext, this.active = true});
  final VoidCallback onNext;

  /// Whether this page is the visible onboarding step. When false, the
  /// auto-advance/fill animation is paused so it isn't cycling (and
  /// repainting) off-screen while retained in the PageView cache.
  final bool active;

  @override
  State<FeaturesPage> createState() => _FeaturesPageState();
}

class _FeaturesPageState extends State<FeaturesPage> {
  int _index = 0;

  void _select(int i) {
    if (i == _index) return;
    setState(() => _index = i);
  }

  // Called by the tab strip when the active chip's border-fill (and its
  // connector line) finish: advance to the next feature, wrapping around.
  void _advance() {
    if (!mounted) return;
    setState(() => _index = (_index + 1) % _features.length);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = _features[_index];

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text('Built-in polish', style: theme.textTheme.displaySmall),
          const SizedBox(height: 8),
          Text(
            'Every recording gets these automatically.',
            style:
                theme.textTheme.titleMedium?.copyWith(color: Colors.white70),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          // Video + caption swap together: incoming fades and springs in from
          // the right; outgoing fades and slides out. iOS-style spring easing.
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 460),
              switchInCurve: Curves.linear,
              switchOutCurve: Curves.linear,
              transitionBuilder: (child, animation) {
                // Spring (over-shooting) slide on entry, gentle ease on exit;
                // a separate 0..1 curve drives opacity so it never exceeds 1.
                final slide = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOutBack,
                  reverseCurve: Curves.easeInCubic,
                );
                final fade = CurvedAnimation(
                  parent: animation,
                  curve: Curves.easeOut,
                  reverseCurve: Curves.easeIn,
                );
                return AnimatedBuilder(
                  animation: animation,
                  child: child,
                  builder: (context, child) {
                    // Incoming enters from the right; outgoing leaves to the
                    // left (opposite direction), both at a 6% offset.
                    // Only `reverse` marks the outgoing child; `dismissed` is
                    // excluded so an incoming child's first (value 0) frame
                    // isn't mistaken for a leaving one and slid the wrong way.
                    final leaving =
                        animation.status == AnimationStatus.reverse;
                    final dx = (1 - slide.value) * 0.06 * (leaving ? -1 : 1);
                    return Opacity(
                      opacity: fade.value.clamp(0.0, 1.0),
                      child: FractionalTranslation(
                        translation: Offset(dx, 0),
                        child: child,
                      ),
                    );
                  },
                );
              },
              child: Column(
                key: ValueKey(_index),
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Flexible(
                    child: Center(
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 560),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.35),
                                blurRadius: 32,
                                offset: const Offset(0, 12),
                              ),
                            ],
                          ),
                          child: OnboardingVideo(
                            assetPath: f.asset,
                            posterPath: f.poster,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),
                  Text(f.title, style: theme.textTheme.titleLarge),
                  const SizedBox(height: 6),
                  SizedBox(
                    height: 40,
                    child: Text(
                      f.blurb,
                      style: theme.textTheme.bodyMedium
                          ?.copyWith(color: Colors.white70),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          _FeatureTabs(
            labels: [for (final f in _features) f.tab],
            index: _index,
            active: widget.active,
            onSelect: _select,
            onAdvance: _advance,
          ),
          const SizedBox(height: 24),
          SizedBox(
            width: 240,
            child: FilledButton(
              onPressed: widget.onNext,
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Continue'),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// A centered strip of pill tabs with a running "trace": the active chip's
/// border draws in from the left, meets at the right, then a connector line
/// extends to the next chip — which then traces, and so on. The completed
/// trace doubles as the auto-advance timer (via [onAdvance]).
class _FeatureTabs extends StatefulWidget {
  const _FeatureTabs({
    required this.labels,
    required this.index,
    required this.active,
    required this.onSelect,
    required this.onAdvance,
  });

  final List<String> labels;
  final int index;
  final bool active;
  final ValueChanged<int> onSelect;
  final VoidCallback onAdvance;

  @override
  State<_FeatureTabs> createState() => _FeatureTabsState();
}

class _FeatureTabsState extends State<_FeatureTabs>
    with SingleTickerProviderStateMixin {
  static const _dwell = Duration(milliseconds: 5400);
  static const _gap = 14.0;

  late final AnimationController _c;
  final _stackKey = GlobalKey();
  late List<GlobalKey> _chipKeys;
  List<Rect>? _rects;
  double? _measuredWidth;

  @override
  void initState() {
    super.initState();
    _chipKeys = List.generate(widget.labels.length, (_) => GlobalKey());
    _c = AnimationController(vsync: this, duration: _dwell)
      ..addStatusListener((s) {
        if (s == AnimationStatus.completed) widget.onAdvance();
      });
    WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
    if (widget.active) _c.forward();
  }

  @override
  void didUpdateWidget(covariant _FeatureTabs old) {
    super.didUpdateWidget(old);
    if (!widget.active) {
      // Page went off-screen: freeze the trace so it isn't cycling/repainting
      // in the PageView cache.
      if (old.active) _c.stop();
    } else if (!old.active || old.index != widget.index) {
      // Arrived (restart the showcase fresh), or the active chip changed via
      // auto-advance / a manual pick: restart the trace.
      _c.forward(from: 0);
    }
  }

  void _measure() {
    final stackBox = _stackKey.currentContext?.findRenderObject() as RenderBox?;
    if (stackBox == null || !stackBox.hasSize) return;
    final rects = <Rect>[];
    for (final k in _chipKeys) {
      final rb = k.currentContext?.findRenderObject() as RenderBox?;
      if (rb == null || !rb.hasSize) return;
      final tl = rb.localToGlobal(Offset.zero, ancestor: stackBox);
      rects.add(tl & rb.size);
    }
    if (mounted) setState(() => _rects = rects);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LayoutBuilder(
      builder: (context, constraints) {
        // Re-measure if the available width changed (e.g. window resize).
        if (_measuredWidth != constraints.maxWidth) {
          _measuredWidth = constraints.maxWidth;
          WidgetsBinding.instance.addPostFrameCallback((_) => _measure());
        }
        return Stack(
          key: _stackKey,
          children: [
            // Fill sits BEHIND the chips so the label keeps full contrast.
            if (_rects != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _FillPainter(
                      anim: _c,
                      active: widget.index,
                      rects: _rects!,
                      accent: accent,
                    ),
                  ),
                ),
              ),
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < widget.labels.length; i++) ...[
                  if (i > 0) const SizedBox(width: _gap),
                  _FeatureTab(
                    key: _chipKeys[i],
                    label: widget.labels[i],
                    active: i == widget.index,
                    done: i < widget.index,
                    onTap: () => widget.onSelect(i),
                  ),
                ],
              ],
            ),
          ],
        );
      },
    );
  }
}

/// Soft-cornered chip radius, shared by the tab and its fill painter.
const double _kChipRadius = 14;

/// One chip. Transparent — the animated accent fill is painted behind it by
/// [_FillPainter]; the chip only carries a faint resting border + the label.
class _FeatureTab extends StatelessWidget {
  const _FeatureTab({
    super.key,
    required this.label,
    required this.active,
    required this.done,
    required this.onTap,
  });

  final String label;
  final bool active;
  final bool done; // already progressed this cycle
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    // Strong accent border on the progressing chip and the ones already done;
    // faint resting border on the chips still ahead. IMPORTANT: border width
    // and font weight are held CONSTANT across states — a Container reserves
    // its border thickness as padding, so changing either would resize the
    // chip, reflow the Row, and desync the fill painter's cached rects.
    final Color borderColor = active
        ? accent
        : done
            ? accent.withValues(alpha: 0.85)
            : Colors.white12;
    final highlighted = active || done;

    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(_kChipRadius),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(_kChipRadius),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(_kChipRadius),
            border: Border.all(color: borderColor, width: 1.6),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: highlighted ? Colors.white : Colors.white54,
            ),
          ),
        ),
      ),
    );
  }
}

/// Paints the running accent fill behind the chips.
///
/// The active chip fills via a circular reveal that grows from its left edge
/// and sweeps to the right (curved leading edge), clipped to the chip's
/// rounded rect. When the chip is full, a connector bar extends to the next
/// chip, which then fills — and so on. Chips already passed this cycle stay
/// fully filled with their connector.
class _FillPainter extends CustomPainter {
  _FillPainter({
    required this.anim,
    required this.active,
    required this.rects,
    required this.accent,
  }) : super(repaint: anim);

  final Animation<double> anim;
  final int active;
  final List<Rect> rects;
  final Color accent;

  // Fraction of the dwell spent filling the chip; the rest extends the
  // connector to the next chip.
  static const _fillFraction = 0.72;

  Color get _fillColor => accent.withValues(alpha: 0.22);
  Color get _connectorColor => accent.withValues(alpha: 0.55);

  @override
  void paint(Canvas canvas, Size size) {
    final isLast = active == rects.length - 1;
    final v = anim.value;
    final double pa;
    final double pb;
    if (isLast) {
      pa = v; // no next chip: spend the whole dwell filling.
      pb = 0;
    } else {
      pa = (v / _fillFraction).clamp(0.0, 1.0);
      pb = ((v - _fillFraction) / (1 - _fillFraction)).clamp(0.0, 1.0);
    }

    for (var j = 0; j < rects.length; j++) {
      if (j < active) {
        _fill(canvas, rects[j], 1);
        _connector(canvas, j, 1);
      } else if (j == active) {
        _fill(canvas, rects[j], pa);
        if (pb > 0) _connector(canvas, j, pb);
      }
    }
  }

  void _fill(Canvas canvas, Rect r, double t) {
    if (t <= 0) return;
    final paint = Paint()..color = _fillColor;
    final rrect = RRect.fromRectAndRadius(r, Radius.circular(_kChipRadius));
    canvas.save();
    canvas.clipRRect(rrect);
    if (t >= 1) {
      canvas.drawRect(r, paint);
    } else {
      // Circle grows from the left-middle; clipped to the chip it reads as a
      // curved wipe sweeping rightward. Radius reaches exactly the farthest
      // corner at t=1 so the sweep uses the whole fill duration (no early
      // finish).
      final center = Offset(r.left, r.center.dy);
      final maxR = math.sqrt(r.width * r.width + (r.height / 2) * (r.height / 2));
      canvas.drawCircle(center, maxR * t, paint);
    }
    canvas.restore();
  }

  void _connector(Canvas canvas, int j, double t) {
    if (j + 1 >= rects.length || t <= 0) return;
    final a = rects[j];
    final b = rects[j + 1];
    final y = a.center.dy;
    final x0 = a.right;
    final x1 = b.left;
    final paint = Paint()
      ..color = _connectorColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.4
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(Offset(x0, y), Offset(x0 + (x1 - x0) * t, y), paint);
  }

  @override
  bool shouldRepaint(covariant _FillPainter old) =>
      old.active != active || old.rects != rects || old.accent != accent;
}
