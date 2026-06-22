import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/captions/whisper_resolver.dart';

void main() {
  group('WhisperResolver', () {
    test('prefers bundledPath when it exists', () {
      final r = WhisperResolver(
        bundledPath: '/app/whisper-cli',
        fileExists: (p) => p == '/app/whisper-cli',
        pathEnv: '',
      );
      expect(r.resolve(), '/app/whisper-cli');
    });

    test('falls back to a well-known Homebrew location', () {
      final r = WhisperResolver(
        fileExists: (p) => p == '/opt/homebrew/bin/whisper-cli',
        pathEnv: '',
      );
      expect(r.resolve(), '/opt/homebrew/bin/whisper-cli');
    });

    test('searches PATH for alternate exe names', () {
      final r = WhisperResolver(
        fileExists: (p) => p == '/custom/bin/whisper-cpp',
        pathEnv: '/custom/bin',
      );
      expect(r.resolve(), '/custom/bin/whisper-cpp');
    });

    test('throws WhisperNotFoundException listing searched paths', () {
      final r = WhisperResolver(fileExists: (_) => false, pathEnv: '');
      expect(
        () => r.resolve(),
        throwsA(isA<WhisperNotFoundException>()),
      );
    });
  });
}
