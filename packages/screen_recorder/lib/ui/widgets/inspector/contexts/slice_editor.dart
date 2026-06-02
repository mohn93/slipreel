import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/state/clip_slice.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';

/// Inspector context shown when a clip slice is selected. Edits one
/// slice's playback, audio, fade, and cursor settings. Initially the
/// project always has exactly one slice (covering the whole video);
/// sub-project C's cut tool introduces multi-slice projects.
class SliceEditor extends ConsumerWidget {
  const SliceEditor({
    super.key,
    required this.sliceIndex,
    required this.onClose,
  });

  final int sliceIndex;
  final VoidCallback onClose;

  static const _speedPresets = <double>[0.5, 1.0, 1.5, 2.0];

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(editorProjectControllerProvider);
    final notifier = ref.read(editorProjectControllerProvider.notifier);
    final clips = state.timeline.clips;
    if (sliceIndex < 0 || sliceIndex >= clips.length) {
      return _MissingSlice(onClose: onClose);
    }
    final clip = clips[sliceIndex];
    final canRemove = clips.length > 1;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Header(
          icon: Icons.content_cut,
          title: 'Slice',
          // Bounds only — speed is shown via the chip + slider rows
          // below. Keeping a single source of truth here prevents the
          // header from echoing the same value three times.
          subtitle: '${_fmt(clip.start)} – ${_fmt(clip.end)}',
          onClose: onClose,
        ),
        const SizedBox(height: 8),
        Expanded(
          child: SingleChildScrollView(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const InspectorSectionLabel('Speed'),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final s in _speedPresets)
                      _SpeedChip(
                        label: '${_speedLabel(s)}x',
                        isSelected: (clip.playbackSpeed - s).abs() < 0.001,
                        onTap: () => notifier.setSliceSpeed(sliceIndex, s),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
                InspectorSlider(
                  label: 'Fine-tune',
                  // Percent format so this row doesn't echo the "1.5"
                  // substring used by the preset chip labels.
                  subtitle:
                      'Final speed: ${(clip.playbackSpeed * 100).round()}%',
                  value: clip.playbackSpeed,
                  min: 0.25,
                  max: 4.0,
                  onChanged: (v) => notifier.setSliceSpeed(sliceIndex, v),
                  onReset: () => notifier.setSliceSpeed(sliceIndex, 1.0),
                  canReset: clip.playbackSpeed != 1.0,
                ),
                const InspectorSectionDivider(),
                const InspectorSectionLabel('Audio'),
                _GainRow(
                  label: 'Mic',
                  percent: clip.micGainPercent,
                  muted: clip.micMuted,
                  onPercentChanged: (v) =>
                      notifier.setSliceMicGain(sliceIndex, v),
                  onMutedChanged: (v) =>
                      notifier.setSliceMicMuted(sliceIndex, v),
                ),
                const SizedBox(height: 12),
                _GainRow(
                  label: 'System',
                  percent: clip.systemGainPercent,
                  muted: clip.systemMuted,
                  onPercentChanged: (v) =>
                      notifier.setSliceSystemGain(sliceIndex, v),
                  onMutedChanged: (v) =>
                      notifier.setSliceSystemMuted(sliceIndex, v),
                ),
                const InspectorSectionDivider(),
                const InspectorSectionLabel('Cursor'),
                InspectorToggle(
                  label: 'Hide cursor',
                  value: clip.hideCursor,
                  onChanged: (v) =>
                      notifier.setSliceHideCursor(sliceIndex, v),
                ),
                InspectorToggle(
                  label: 'Disable smooth mouse',
                  value: clip.disableSmoothMouse,
                  onChanged: (v) =>
                      notifier.setSliceDisableSmoothMouse(sliceIndex, v),
                ),
                const InspectorSectionDivider(),
                const InspectorSectionLabel('Fades'),
                InspectorSlider(
                  label: 'Fade in',
                  subtitle:
                      '${(clip.fadeIn.inMicroseconds / 1000).toInt()} ms',
                  value: clip.fadeIn.inMicroseconds / 1e6,
                  min: 0,
                  max: 2,
                  onChanged: (s) => notifier.setSliceFadeIn(
                    sliceIndex,
                    Duration(microseconds: (s * 1e6).round()),
                  ),
                  onReset: () =>
                      notifier.setSliceFadeIn(sliceIndex, Duration.zero),
                  canReset: clip.fadeIn != Duration.zero,
                ),
                const SizedBox(height: 12),
                InspectorSlider(
                  label: 'Fade out',
                  subtitle:
                      '${(clip.fadeOut.inMicroseconds / 1000).toInt()} ms',
                  value: clip.fadeOut.inMicroseconds / 1e6,
                  min: 0,
                  max: 2,
                  onChanged: (s) => notifier.setSliceFadeOut(
                    sliceIndex,
                    Duration(microseconds: (s * 1e6).round()),
                  ),
                  onReset: () =>
                      notifier.setSliceFadeOut(sliceIndex, Duration.zero),
                  canReset: clip.fadeOut != Duration.zero,
                ),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
        // Pinned footer so the destructive action stays visible no
        // matter where the user has scrolled.
        if (canRemove) ...[
          const SizedBox(height: 12),
          _RemoveSliceButton(onTap: () {
            notifier.removeSlice(sliceIndex);
            onClose();
          }),
        ],
      ],
    );
  }

  static String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  static String _speedLabel(double s) {
    // 0.5 → "0.5", 1.0 → "1", 1.5 → "1.5", 2.0 → "2"
    if (s == s.roundToDouble()) return s.toInt().toString();
    return s.toString();
  }
}

class _MissingSlice extends StatelessWidget {
  const _MissingSlice({required this.onClose});
  final VoidCallback onClose;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'No slice selected',
            style: TextStyle(color: Colors.white70),
          ),
          TextButton(onPressed: onClose, child: const Text('Close')),
        ],
      ),
    );
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
          child: Icon(icon, color: const Color(0xFFE0A050), size: 20),
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
                style: const TextStyle(color: kInspectorMuted, fontSize: 12),
              ),
            ],
          ),
        ),
        Tooltip(
          message: 'Close slice editor',
          child: InkWell(
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
              child: const Icon(Icons.close, color: Colors.white70, size: 16),
            ),
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
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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

class _GainRow extends StatelessWidget {
  const _GainRow({
    required this.label,
    required this.percent,
    required this.muted,
    required this.onPercentChanged,
    required this.onMutedChanged,
  });
  final String label;
  final int percent;
  final bool muted;
  final ValueChanged<int> onPercentChanged;
  final ValueChanged<bool> onMutedChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: const TextStyle(color: Colors.white, fontSize: 13),
          ),
        ),
        Expanded(
          child: Slider(
            value: percent.toDouble(),
            min: 0,
            max: 200,
            divisions: 200,
            onChanged: (v) => onPercentChanged(v.round()),
          ),
        ),
        const SizedBox(width: 8),
        Text(
          muted ? 'Muted' : '$percent%',
          style: const TextStyle(color: Colors.white70, fontSize: 12),
        ),
        const SizedBox(width: 8),
        Switch.adaptive(value: muted, onChanged: onMutedChanged),
      ],
    );
  }
}

class _RemoveSliceButton extends StatelessWidget {
  const _RemoveSliceButton({required this.onTap});
  final VoidCallback onTap;
  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: const Icon(Icons.delete_outline, color: Colors.redAccent),
      label: const Text(
        'Remove slice',
        style: TextStyle(color: Colors.redAccent),
      ),
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Color(0xFF5A2A2A)),
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
    );
  }
}
