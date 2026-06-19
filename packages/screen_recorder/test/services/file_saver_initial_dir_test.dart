import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/services/destination_handlers.dart';

void main() {
  test('injected save dialog is used and returns its path', () async {
    String? seen;
    final saver = FileSaver(
      initialDirectory: '/Users/me/Clips',
      saveDialog: (name) async {
        seen = name;
        return '/Users/me/Clips/$name';
      },
    );
    final out = await saver.resolveOutputPath(suggestedFileName: 'clip.mp4');
    expect(seen, 'clip.mp4');
    expect(out, '/Users/me/Clips/clip.mp4');
  });

  test('initialDirectory is exposed for the default dialog to consume', () {
    final saver = FileSaver(initialDirectory: '/Users/me/Clips');
    expect(saver.initialDirectory, '/Users/me/Clips');
  });
}
