import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:slipreel_engine/export/audio_streams.dart';

/// The opened recording's audio streams (probed when the editor loads).
/// Empty until populated / when the recording has no audio. Drives the
/// editor's per-track audio controls.
final recordingAudioStreamsProvider =
    StateProvider<List<AudioStreamInfo>>((ref) => const []);
