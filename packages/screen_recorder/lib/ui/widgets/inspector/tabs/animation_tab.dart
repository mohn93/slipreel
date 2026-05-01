import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Animation tab — screen / cursor animation styles + motion blur.
///
/// State is local; the rendering pipeline doesn't yet read these.
/// Switching styles updates the descriptive caption beneath the
/// picker so the tab feels responsive.
class AnimationTab extends StatefulWidget {
  const AnimationTab({super.key});

  @override
  State<AnimationTab> createState() => _AnimationTabState();
}

class _AnimationTabState extends State<AnimationTab> {
  _ScreenStyle _screen = _ScreenStyle.focused;
  _CursorAnim _cursor = _CursorAnim.smooth;
  double _motionBlur = 0.6;

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
        InspectorOptionRow<_ScreenStyle>(
          items: _ScreenStyle.values,
          selected: _screen,
          onSelected: (s) => setState(() => _screen = s),
          iconOf: (s) => Icon(s.icon, color: Colors.white, size: 22),
          labelOf: (s) => s.label,
          tileSize: 80,
        ),
        const SizedBox(height: 12),
        Text(
          _screen.description,
          style: const TextStyle(
            color: kInspectorMuted,
            fontSize: 13,
            height: 1.4,
          ),
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
        InspectorOptionRow<_CursorAnim>(
          items: _CursorAnim.values,
          selected: _cursor,
          onSelected: (s) => setState(() => _cursor = s),
          iconOf: (s) => Icon(s.icon, color: Colors.white, size: 22),
          labelOf: (s) => s.label,
          tileSize: 76,
        ),
        const InspectorSectionDivider(),
        InspectorSlider(
          label: 'Motion blur',
          subtitle:
              'While mouse cursor or screen is moving, cinematic '
              'motion blur effect will be applied',
          value: _motionBlur,
          min: 0,
          max: 1,
          onChanged: (v) => setState(() => _motionBlur = v),
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
}

enum _ScreenStyle {
  focused(
    label: 'Focused',
    icon: Icons.adjust,
    description:
        'Animation stabilizes quickly making it easier to follow '
        'and read the content',
  ),
  smooth(
    label: 'Smooth',
    icon: Icons.timeline,
    description:
        'Smoother, more cinematic camera that lingers between '
        'targets for a film-like feel',
  );

  const _ScreenStyle({
    required this.label,
    required this.icon,
    required this.description,
  });
  final String label;
  final IconData icon;
  final String description;
}

enum _CursorAnim {
  smooth(label: 'Smooth', icon: Icons.touch_app_outlined),
  medium(label: 'Medium', icon: Icons.swipe),
  rapid(label: 'Rapid', icon: Icons.bolt),
  none(label: 'None', icon: Icons.near_me);

  const _CursorAnim({required this.label, required this.icon});
  final String label;
  final IconData icon;
}
