import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/services/destination_handlers.dart';

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

/// A fake temporary directory provider that returns [dir].
Future<Directory> Function() _fakeTmpDir(Directory dir) =>
    () async => dir;

/// A recorder that captures the last text written to the "clipboard".
class _ClipboardRecorder {
  String? lastText;

  Future<void> write(String text) async {
    lastText = text;
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('FileSaver', () {
    test('resolveOutputPath calls the save dialog with the suggested name', () async {
      String? capturedName;
      final saver = FileSaver(
        saveDialog: (name) async {
          capturedName = name;
          return '/chosen/path/recording_001.mp4';
        },
      );

      final result =
          await saver.resolveOutputPath(suggestedFileName: 'recording_001.mp4');

      expect(capturedName, 'recording_001.mp4');
      expect(result, '/chosen/path/recording_001.mp4');
    });

    test('resolveOutputPath returns null when the dialog returns null (user cancelled)',
        () async {
      final saver = FileSaver(saveDialog: (_) async => null);

      final result =
          await saver.resolveOutputPath(suggestedFileName: 'recording_001.mp4');

      expect(result, isNull);
    });

    test('deliver returns a result with revealPath set and a sane message', () async {
      final saver = FileSaver(saveDialog: (_) async => null);

      final result = await saver.deliver('/exports/recording_001.mp4');

      expect(result.revealPath, '/exports/recording_001.mp4');
      expect(result.message, contains('recording_001.mp4'));
      expect(result.copiedToClipboard, isFalse);
    });

    test('deliver message begins with "Export complete:"', () async {
      final saver = FileSaver(saveDialog: (_) async => null);

      final result = await saver.deliver('/some/dir/clip.gif');

      expect(result.message, startsWith('Export complete:'));
      expect(result.message, contains('clip.gif'));
    });
  });

  group('ClipboardCopier', () {
    late Directory tmpDir;
    late _ClipboardRecorder clipboard;

    setUp(() async {
      tmpDir = await Directory.systemTemp.createTemp('clipboard_copier_test_');
      clipboard = _ClipboardRecorder();
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('resolveOutputPath produces a path under the temp dir', () async {
      final copier = ClipboardCopier(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final path = await copier.resolveOutputPath(
        suggestedFileName: 'recording_123.mp4',
      );

      expect(path, isNotNull);
      expect(path!, startsWith(tmpDir.path));
    });

    test('resolveOutputPath uses the extension from the suggested name (.mp4)',
        () async {
      final copier = ClipboardCopier(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final path = await copier.resolveOutputPath(
        suggestedFileName: 'recording_123.mp4',
      );

      expect(path, endsWith('.mp4'));
    });

    test('resolveOutputPath uses the extension from the suggested name (.gif)',
        () async {
      final copier = ClipboardCopier(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final path = await copier.resolveOutputPath(
        suggestedFileName: 'animation.gif',
      );

      expect(path, endsWith('.gif'));
    });

    test('resolveOutputPath always returns a non-null path (no user prompt)',
        () async {
      final copier = ClipboardCopier(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final path1 = await copier.resolveOutputPath(
        suggestedFileName: 'a.mp4',
      );
      final path2 = await copier.resolveOutputPath(
        suggestedFileName: 'b.mp4',
      );

      expect(path1, isNotNull);
      expect(path2, isNotNull);
    });

    test('deliver puts the absolute path on the clipboard', () async {
      final copier = ClipboardCopier(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      const outputPath = '/tmp/screenflow_export_12345.mp4';
      await copier.deliver(outputPath);

      expect(clipboard.lastText, outputPath);
    });

    test('deliver returns copiedToClipboard: true', () async {
      final copier = ClipboardCopier(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final result = await copier.deliver('/tmp/screenflow_export_12345.mp4');

      expect(result.copiedToClipboard, isTrue);
    });

    test('deliver result message is user-facing and sane', () async {
      final copier = ClipboardCopier(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final result = await copier.deliver('/tmp/screenflow_export_12345.mp4');

      expect(result.message, isNotEmpty);
      // The message should tell the user the path was copied.
      expect(result.message.toLowerCase(), contains('copied'));
    });
  });

  group('ShareableLinkPublisher', () {
    late Directory tmpDir;
    late _ClipboardRecorder clipboard;

    setUp(() async {
      tmpDir =
          await Directory.systemTemp.createTemp('shareable_link_test_');
      clipboard = _ClipboardRecorder();
    });

    tearDown(() async {
      if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
    });

    test('resolveOutputPath produces a path under the temp dir', () async {
      final publisher = ShareableLinkPublisher(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final path = await publisher.resolveOutputPath(
        suggestedFileName: 'recording_123.mp4',
      );

      expect(path, isNotNull);
      expect(path!, startsWith(tmpDir.path));
    });

    test('resolveOutputPath always returns a non-null path', () async {
      final publisher = ShareableLinkPublisher(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final path = await publisher.resolveOutputPath(
        suggestedFileName: 'any.mp4',
      );

      expect(path, isNotNull);
    });

    test('deliver puts a file:// URL on the clipboard', () async {
      final publisher = ShareableLinkPublisher(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      const outputPath = '/tmp/screenflow_export_99999.mp4';
      await publisher.deliver(outputPath);

      expect(clipboard.lastText, 'file://$outputPath');
    });

    test('deliver returns copiedToClipboard: true', () async {
      final publisher = ShareableLinkPublisher(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final result = await publisher.deliver('/tmp/screenflow_export_99999.mp4');

      expect(result.copiedToClipboard, isTrue);
    });

    test('deliver result has revealPath set', () async {
      final publisher = ShareableLinkPublisher(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      const outputPath = '/tmp/screenflow_export_99999.mp4';
      final result = await publisher.deliver(outputPath);

      expect(result.revealPath, outputPath);
    });

    test('deliver result message mentions "coming soon" stub nature', () async {
      final publisher = ShareableLinkPublisher(
        tempDirProvider: _fakeTmpDir(tmpDir),
        clipboardWrite: clipboard.write,
      );

      final result = await publisher.deliver('/tmp/screenflow_export_99999.mp4');

      expect(result.message.toLowerCase(), contains('coming soon'));
    });
  });

  group('DestinationResult', () {
    test('defaults: revealPath is null and copiedToClipboard is false', () {
      const result = DestinationResult(message: 'Done');
      expect(result.revealPath, isNull);
      expect(result.copiedToClipboard, isFalse);
      expect(result.message, 'Done');
    });

    test('explicit values are stored', () {
      const result = DestinationResult(
        message: 'ok',
        revealPath: '/some/path',
        copiedToClipboard: true,
      );
      expect(result.revealPath, '/some/path');
      expect(result.copiedToClipboard, isTrue);
    });
  });
}
