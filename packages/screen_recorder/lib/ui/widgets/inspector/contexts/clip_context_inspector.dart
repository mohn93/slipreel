import 'package:flutter/material.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Properties view shown when the main video clip bar is selected.
///
/// All controls are placeholders today — there's no per-clip speed
/// or fade model yet. Local state keeps the UI feeling live.
class ClipContextInspector extends StatelessWidget {
  const ClipContextInspector({
    super.key,
    required this.clipDuration,
    required this.playbackSpeed,
    required this.onPlaybackSpeedChanged,
    required this.fadeIn,
    required this.fadeOut,
    required this.onFadeInChanged,
    required this.onFadeOutChanged,
    required this.onClose,
  });

  final Duration clipDuration;
  final double playbackSpeed;
  final ValueChanged<double> onPlaybackSpeedChanged;
  final double fadeIn;
  final double fadeOut;
  final ValueChanged<double> onFadeInChanged;
  final ValueChanged<double> onFadeOutChanged;
  final VoidCallback onClose;

  static const _speedPresets = <double>[0.5, 1.0, 1.5, 2.0];

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          icon: Icons.movie_outlined,
          title: 'Clip',
          subtitle:
              '${_fmt(clipDuration)} · ${playbackSpeed.toStringAsFixed(2)}×',
          onClose: onClose,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: [
              const Text(
                'Playback speed',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final s in _speedPresets)
                    _SpeedChip(
                      label: '${s == 1.0 ? '1' : s}×',
                      isSelected:
                          (playbackSpeed - s).abs() < 0.001,
                      onTap: () => onPlaybackSpeedChanged(s),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              InspectorSlider(
                label: 'Fine-tune',
                subtitle:
                    'Final speed: ${playbackSpeed.toStringAsFixed(2)}×',
                value: playbackSpeed,
                min: 0.25,
                max: 4.0,
                onChanged: onPlaybackSpeedChanged,
                onReset: () => onPlaybackSpeedChanged(1.0),
                canReset: playbackSpeed != 1.0,
              ),
              const InspectorSectionDivider(),
              InspectorSlider(
                label: 'Fade in',
                subtitle: '${(fadeIn * 1000).toInt()} ms',
                value: fadeIn,
                min: 0,
                max: 2,
                onChanged: onFadeInChanged,
                onReset: () => onFadeInChanged(0),
                canReset: fadeIn != 0,
              ),
              const SizedBox(height: 24),
              InspectorSlider(
                label: 'Fade out',
                subtitle: '${(fadeOut * 1000).toInt()} ms',
                value: fadeOut,
                min: 0,
                max: 2,
                onChanged: onFadeOutChanged,
                onReset: () => onFadeOutChanged(0),
                canReset: fadeOut != 0,
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ],
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }
}

class _Header extends StatelessWidget {
  const _Header({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onClose,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: const Color(0xFFB07020).withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(10),
          ),
          alignment: Alignment.center,
          child: const Icon(Icons.movie_outlined,
              color: Color(0xFFE0A050), size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: kInspectorMuted,
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        InkWell(
          onTap: onClose,
          borderRadius: BorderRadius.circular(8),
          child: Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: kInspectorPanel,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: kInspectorBorder),
            ),
            child: const Icon(Icons.close,
                color: Colors.white70, size: 16),
          ),
        ),
      ],
    );
  }
}

class _SpeedChip extends StatelessWidget {
  const _SpeedChip({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: kInspectorPanel,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? kInspectorAccent : kInspectorBorder,
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
