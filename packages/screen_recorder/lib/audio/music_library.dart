import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:slipreel_engine/audio/music_track.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

const musicPresets = ['Vaporware', 'Synthwave 4k', 'Contemplation'];
const musicPresetCredits = {
  'Vaporware': (
    artist: 'The Cynic Project',
    source: 'https://opengameart.org/content/calm-piano-1-vaporware',
  ),
  'Synthwave 4k': (
    artist: 'The Cynic Project',
    source: 'https://opengameart.org/content/calm-ambient-1-synthwave-4k',
  ),
  'Contemplation': (
    artist: 'Joth',
    source: 'https://opengameart.org/content/contemplation-0',
  ),
};

// The source releases include a quiet lead-in. Starting a short loop at file
// time zero would replay that silence at every boundary and sound like the
// music stopped. Keep a few milliseconds of the natural attack while skipping
// the digital-silence portion for built-in presets.
const musicPresetAudibleStarts = {
  'Vaporware': 1.70,
  'Synthwave 4k': 0.61,
  'Contemplation': 0.19,
};

MusicTrack skipPresetLeadingSilence(MusicTrack track) {
  final audibleStart = musicPresetAudibleStarts[track.preset];
  if (audibleStart == null ||
      track.trimStart > 0.01 ||
      track.end <= audibleStart) {
    return track;
  }
  return track.copyWith(trimStart: audibleStart);
}

// Exact content-addressed files from the withdrawn generated library. Only
// these preset copies are retired; user imports and other music are untouched.
const retiredGeneratedMusicFiles = {
  'b80a85540ef9f697790834bc67f1b717cdd5e80ea266eae8695c5acf9bb2614b.m4a',
  '7e4f336f6da60c2cf2de54f88939347dcc6fc78743d9fa5b5ae774a8c8a35ff3.m4a',
  '1aa86e8a8c1158d86aafdba55ed409ee8ad1ea97e102a7cceeb027333e899116.m4a',
  '219859058c9d70ae7f6aa954dbde39828a595ca0ee3fa862c3101bc326f3d305.m4a',
  'a231f2c0f009f3de98a1f4b6344a7e4cc56482cafad39415f2633ad7af95297a.m4a',
  'c0e11121e6fa42a9deb0b0cb2bd0d38eaf3b73c030b6bb31fc75b527dd1e1397.m4a',
  '69f3c3f16c0bc49bad6b9ef7fde0205a4463f89e01b958b05df4d2eed2dad317.m4a',
};
bool isRetiredGeneratedMusic(MusicTrack? track) =>
    track != null &&
    track.preset != null &&
    retiredGeneratedMusicFiles.contains(p.basename(track.path));

/// Imports immutable, content-addressed copies. Undo and other projects may
/// still refer to an older track, so replacement never deletes library files.
Future<MusicTrack> importMusic(String path, {String? preset}) async {
  final source = File(path);
  final probe = await Process.run(Ffmpeg.resolveProbe(), [
    '-v',
    'error',
    '-show_entries',
    'format=duration:stream=codec_type',
    '-of',
    'json',
    path,
  ]);
  if (probe.exitCode != 0) {
    throw const FormatException('This audio file could not be read.');
  }
  final json = jsonDecode(probe.stdout as String) as Map<String, dynamic>;
  final duration = double.tryParse('${(json['format'] as Map?)?['duration']}');
  final streams = json['streams'] as List? ?? [];
  if (!streams.any((s) => s['codec_type'] == 'audio') ||
      duration == null ||
      !duration.isFinite ||
      duration <= 0 ||
      duration > 86400) {
    throw const FormatException(
      'Choose an audio file with a valid duration (up to 24 hours).',
    );
  }
  final digest = await sha256.bind(source.openRead()).first;
  final dir = Directory(
    p.join((await getApplicationSupportDirectory()).path, 'music'),
  );
  await dir.create(recursive: true);
  final destination = File(
    p.join(dir.path, '$digest${p.extension(path).toLowerCase()}'),
  );
  if (!await destination.exists()) {
    final temp = File(
      '${destination.path}.${DateTime.now().microsecondsSinceEpoch}.tmp',
    );
    try {
      await source.copy(temp.path);
      await temp.rename(destination.path);
    } finally {
      if (await temp.exists()) await temp.delete();
    }
  }
  return MusicTrack(
    path: destination.path,
    name: preset ?? p.basenameWithoutExtension(path),
    preset: preset,
    sourceDuration: duration,
  );
}

Future<MusicTrack> loadMusicPreset(String name) async {
  if (!musicPresets.contains(name)) throw ArgumentError.value(name);
  final asset = 'assets/music/${name.toLowerCase().replaceAll(' ', '-')}.m4a';
  final bytes = await rootBundle.load(asset);
  final dir = await Directory.systemTemp.createTemp('slipreel-preset-');
  try {
    final file = File(p.join(dir.path, 'preset.m4a'));
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    final track = await importMusic(file.path, preset: name);
    return skipPresetLeadingSilence(track.copyWith(loop: false, volume: 0.2));
  } finally {
    await dir.delete(recursive: true);
  }
}
