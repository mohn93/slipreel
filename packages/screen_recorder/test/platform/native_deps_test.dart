import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/platform/native_deps.dart';
import 'package:slipreel_engine/captions/whisper_resolver.dart';
import 'package:slipreel_engine/export/ffmpeg_resolver.dart';

void main() {
  const exe = '/Applications/Slipreel.app/Contents/MacOS/Slipreel';
  const helpers = '/Applications/Slipreel.app/Contents/Helpers';

  tearDown(() {
    Ffmpeg.resetForTesting();
    Whisper.resetForTesting();
  });

  test('wires both resolvers when all bundled binaries exist', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (_) => true,
    );
    expect(Ffmpeg.resolver.bundledPath, '$helpers/ffmpeg');
    expect(Whisper.resolver.bundledPath, '$helpers/whisper-cli');
  });

  test('does not wire ffmpeg when ffprobe is missing (atomic pair)', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (p) => !p.endsWith('/ffprobe'),
    );
    expect(Ffmpeg.resolver.bundledPath, isNull);
    expect(Whisper.resolver.bundledPath, '$helpers/whisper-cli');
  });

  test('wires whisper independently when ffmpeg pair is absent', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (p) => p.endsWith('/whisper-cli'),
    );
    expect(Ffmpeg.resolver.bundledPath, isNull);
    expect(Whisper.resolver.bundledPath, '$helpers/whisper-cli');
  });

  test('wires nothing when no bundled binaries exist', () {
    NativeDeps.wireBundledBinaries(
      executablePath: exe,
      fileExists: (_) => false,
    );
    expect(Ffmpeg.resolver.bundledPath, isNull);
    expect(Whisper.resolver.bundledPath, isNull);
  });
}
