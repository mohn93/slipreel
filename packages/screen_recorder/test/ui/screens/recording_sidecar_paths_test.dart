import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/ui/screens/playback_screen.dart';

void main() {
  group('recordingSidecarPaths', () {
    const video = '/recordings/clip.mp4';
    final paths = recordingSidecarPaths(video);

    test('includes every sidecar keyed off the video path', () {
      expect(paths, containsAll(<String>[
        '$video.meta.json',
        '$video.cursor.json',
        '$video.editor.json',
        '$video.editor.json.tmp',
        '$video.camera.mov', // the big one — was orphaned before the fix
        '$video.camera.json',
        '$video.keystrokes.json',
        '$video.thumb.png',
      ]));
    });

    test('does not include the video file itself (deleted separately)', () {
      expect(paths, isNot(contains(video)));
    });

    test('every entry is a child path of the video', () {
      for (final p in paths) {
        expect(p, startsWith('$video.'),
            reason: '$p must be a <videoPath>.<suffix> sidecar');
      }
    });
  });
}
