import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
import 'package:screen_recorder/ui/bar/spring_hover_button.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

/// Audio tab — background-music presets and "add custom" button.
///
/// Picker is fully interactive locally; nothing is mixed into the
/// recording yet. Add-button is a no-op stub.
class AudioTab extends StatefulWidget {
  const AudioTab({super.key});

  @override
  State<AudioTab> createState() => _AudioTabState();
}

class _AudioTabState extends State<AudioTab> {
  static const _presets = <String>[
    'Lo-Fi',
    'Commercial',
    'Electronic',
    'Instrumental',
    'Sunny Lo-Fi',
    'Lean Groove',
    'Bright Lounge',
  ];
  String? _selected = 'Lo-Fi';

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: EdgeInsets.zero,
      // Let hover lean/tilt overshoot paint past the panel edge.
      clipBehavior: Clip.none,
      children: [
        const _RecordingAudioSection(),
        const InspectorSectionDivider(),
        const Text(
          'Background audio',
          style: TextStyle(
            color: kInspectorMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in _presets)
              InspectorChip(
                label: p,
                selected: _selected == p,
                onTap: () => setState(() => _selected = p),
              ),
          ],
        ),
        const InspectorSectionDivider(),
        _addButton(),
      ],
    );
  }

  Widget _addButton() {
    return SpringHoverButton(
      onTap: () {
        // Stub — wire up file-picker + mixing pipeline later.
      },
      borderRadius: 12,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          color: kInspectorAccent.withValues(alpha:0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: kInspectorAccent.withValues(alpha:0.4),
          ),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.library_music_outlined,
                color: kInspectorAccent, size: 18),
            SizedBox(width: 8),
            Text(
              'Add background audio',
              style: TextStyle(
                color: kInspectorAccent,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RecordingAudioSection extends ConsumerWidget {
  const _RecordingAudioSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final streams = ref.watch(recordingAudioStreamsProvider);
    final roles = inferAudioRoles(streams);
    // This is a single GLOBAL volume/mute for the whole recording. The
    // displayed value reads clip 0 as representative; edits apply to ALL slices
    // (setAll*), so a cut recording stays uniform (m7).
    final clips = ref.watch(editorProjectControllerProvider).timeline.clips;
    final micGain = clips.isEmpty ? 100 : clips.first.micGainPercent;
    final micMuted = clips.isEmpty ? false : clips.first.micMuted;
    final systemGain = clips.isEmpty ? 100 : clips.first.systemGainPercent;
    final systemMuted = clips.isEmpty ? false : clips.first.systemMuted;
    final ctl = ref.read(editorProjectControllerProvider.notifier);

    final rows = <Widget>[];
    if (roles.containsKey(AudioRole.microphone)) {
      rows.add(_VolumeRow(
        label: 'Microphone',
        percent: micGain,
        muted: micMuted,
        onChanged: (v) => ctl.setAllMicGain(v),
        onMuteToggle: () => ctl.setAllMicMuted(!micMuted),
      ));
    }
    if (roles.containsKey(AudioRole.system)) {
      rows.add(_VolumeRow(
        label: 'System audio',
        percent: systemGain,
        muted: systemMuted,
        onChanged: (v) => ctl.setAllSystemGain(v),
        onMuteToggle: () => ctl.setAllSystemMuted(!systemMuted),
      ));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Recording audio',
            style: TextStyle(
                color: kInspectorMuted,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const Text('No audio in this recording',
              style: TextStyle(color: kInspectorMuted, fontSize: 13))
        else
          ...rows,
      ],
    );
  }
}

class _VolumeRow extends StatelessWidget {
  const _VolumeRow({
    required this.label,
    required this.percent,
    required this.muted,
    required this.onChanged,
    required this.onMuteToggle,
  });

  final String label;
  final int percent;
  final bool muted;
  final ValueChanged<int> onChanged;
  final VoidCallback onMuteToggle;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SpringyIconButton(
                icon: muted ? Icons.volume_off : Icons.volume_up,
                tooltip: muted ? 'Unmute' : 'Mute',
                isActive: false,
                onTap: onMuteToggle,
                size: 32,
                iconSize: 18,
                tooltipPlacement: SpringyTooltipPlacement.bottom,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(label,
                    style: const TextStyle(color: Colors.white, fontSize: 13)),
              ),
              Text('$percent%',
                  style: const TextStyle(color: kInspectorMuted, fontSize: 12)),
            ],
          ),
          Slider(
            value: percent.toDouble(),
            min: 0,
            max: 200,
            divisions: 40,
            onChanged: muted ? null : (v) => onChanged(v.round()),
          ),
        ],
      ),
    );
  }
}
