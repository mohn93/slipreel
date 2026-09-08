import 'package:url_launcher/url_launcher.dart';
import 'package:screen_recorder/audio/music_preview.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_selector/file_selector.dart';
import 'package:slipreel_engine/audio/music_track.dart';
import 'package:slipreel_engine/timeline/edited_time.dart';
import 'package:slipreel_engine/export/audio_streams.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/audio/music_library.dart';
import 'package:screen_recorder/state/recording_audio_streams_provider.dart';
import 'package:screen_recorder/ui/widgets/inspector/inspector_widgets.dart';
import 'package:screen_recorder/ui/widgets/springy_icon_button.dart';

class AudioTab extends ConsumerStatefulWidget {
  const AudioTab({super.key});
  @override
  ConsumerState<AudioTab> createState() => _AudioTabState();
}

class _AudioTabState extends ConsumerState<AudioTab> {
  bool _busy = false;
  String? _error;
  Future<void> _load(Future<MusicTrack?> Function() load) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    // Do not attach a completed import to a different project after navigation.
    final ctl = ref.read(editorProjectControllerProvider.notifier);
    try {
      final track = await load();
      if (mounted && track != null) ctl.setMusic(track);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not add audio: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<MusicTrack?> _pick() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Audio',
          extensions: [
            'mp3',
            'wav',
            'm4a',
            'aac',
            'flac',
            'ogg',
            'aiff',
            'aif',
          ],
        ),
      ],
    );
    return file == null ? null : await importMusic(file.path);
  }

  @override
  Widget build(BuildContext context) {
    final timeline = ref.watch(editorProjectControllerProvider).timeline;
    final music = timeline.music;
    final credit = musicPresetCredits[music?.preset];
    final previewStatus = ref.watch(musicPreviewStatusProvider);
    final duration = totalEditedDuration(timeline.clips).inMicroseconds / 1e6;
    final ctl = ref.read(editorProjectControllerProvider.notifier);
    void update(MusicTrack value) => ctl.setMusic(value);
    return ListView(
      padding: EdgeInsets.zero,
      children: [
        const _RecordingAudioSection(),
        const InspectorSectionDivider(),
        const Text(
          'Background audio',
          style: TextStyle(color: kInspectorMuted, fontSize: 13),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final p in musicPresets)
              InspectorChip(
                label: p,
                selected: music?.preset == p,
                onTap: () => _load(() => loadMusicPreset(p)),
              ),
          ],
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          onPressed: _busy ? null : () => _load(_pick),
          icon: const Icon(Icons.library_music_outlined),
          label: Text(music == null ? 'Add background audio' : 'Replace audio'),
        ),
        if (_busy || previewStatus == 'Preparing audio preview…')
          const LinearProgressIndicator(),
        if (previewStatus != null)
          Text(
            previewStatus,
            style: const TextStyle(color: kInspectorMuted, fontSize: 12),
          ),
        if (_error != null)
          Text(_error!, style: const TextStyle(color: Colors.orangeAccent)),
        if (music != null) ...[
          const InspectorSectionDivider(),
          Row(
            children: [
              Expanded(
                child: Text(music.name, overflow: TextOverflow.ellipsis),
              ),
              IconButton(
                tooltip: 'Remove music',
                icon: const Icon(Icons.delete_outline),
                onPressed: () => ctl.setMusic(null),
              ),
            ],
          ),
          if (credit != null)
            TextButton.icon(
              onPressed: () async {
                final opened = await launchUrl(Uri.parse(credit.source));
                if (!opened && mounted) {
                  setState(() => _error = 'Could not open the music source.');
                }
              },
              icon: const Icon(Icons.open_in_new, size: 14),
              label: Text(
                '${credit.artist} · CC0',
                style: const TextStyle(fontSize: 12),
              ),
            ),
          if (!File(music.path).existsSync())
            const Text(
              'Audio file is missing. Replace it to restore playback and export.',
              style: TextStyle(color: Colors.orangeAccent),
            ),
          _VolumeRow(
            label: 'Music',
            percent: (music.volume * 100).round(),
            muted: music.muted,
            onChanged: (v) => update(music.copyWith(volume: v / 100)),
            onMuteToggle: () => update(music.copyWith(muted: !music.muted)),
          ),
          _seconds(
            'Start in video',
            music.start,
            duration,
            (v) => update(music.copyWith(start: v)),
          ),
          Text(
            'Use ${music.trimStart.toStringAsFixed(1)}–${music.end.toStringAsFixed(1)} s of the track',
            style: const TextStyle(color: kInspectorMuted, fontSize: 12),
          ),
          if (music.sourceDuration > 0.1)
            RangeSlider(
              values: RangeValues(music.trimStart, music.end),
              min: 0,
              max: music.sourceDuration,
              onChanged: (v) {
                if (v.end - v.start >= 0.1) {
                  update(music.copyWith(trimStart: v.start, trimEnd: v.end));
                }
              },
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Loop to video end'),
            value: music.loop,
            onChanged: (v) => update(music.copyWith(loop: v)),
          ),
          _seconds(
            'Fade in',
            music.fadeIn,
            10,
            (v) => update(music.copyWith(fadeIn: v)),
          ),
          _seconds(
            'Fade out',
            music.fadeOut,
            10,
            (v) => update(music.copyWith(fadeOut: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Lower music during speech'),
            subtitle: const Text('Follows recorded microphone audio'),
            value: music.duck,
            onChanged: (v) => update(music.copyWith(duck: v)),
          ),
          const Text(
            'Play the video to hear your mix. Music follows the edited timeline.',
            style: TextStyle(color: kInspectorMuted, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _seconds(
    String label,
    double value,
    double max,
    ValueChanged<double> change,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '$label · ${value.toStringAsFixed(1)} s',
        style: const TextStyle(color: kInspectorMuted, fontSize: 12),
      ),
      Slider(
        value: value.clamp(0, max),
        min: 0,
        max: max > 0 ? max : 1,
        onChanged: max > 0 ? change : null,
      ),
    ],
  );
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
      rows.add(
        _VolumeRow(
          label: 'Microphone',
          percent: micGain,
          muted: micMuted,
          onChanged: (v) => ctl.setAllMicGain(v),
          onMuteToggle: () => ctl.setAllMicMuted(!micMuted),
        ),
      );
    }
    if (roles.containsKey(AudioRole.system)) {
      rows.add(
        _VolumeRow(
          label: 'System audio',
          percent: systemGain,
          muted: systemMuted,
          onChanged: (v) => ctl.setAllSystemGain(v),
          onMuteToggle: () => ctl.setAllSystemMuted(!systemMuted),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Recording audio',
          style: TextStyle(
            color: kInspectorMuted,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 12),
        if (rows.isEmpty)
          const Text(
            'No audio in this recording',
            style: TextStyle(color: kInspectorMuted, fontSize: 13),
          )
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
                child: Text(
                  label,
                  style: const TextStyle(color: Colors.white, fontSize: 13),
                ),
              ),
              Text(
                '$percent%',
                style: const TextStyle(color: kInspectorMuted, fontSize: 12),
              ),
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
