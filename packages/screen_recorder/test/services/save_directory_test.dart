import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/services/save_directory.dart';

void main() {
  test('null default falls back to the documents path', () {
    final dir = resolveSaveDirectory(
      defaultSaveLocation: null,
      documentsPath: '/docs',
      exists: (_) => true,
    );
    expect(dir, '/docs');
  });

  test('an existing default folder is used', () {
    final dir = resolveSaveDirectory(
      defaultSaveLocation: '/Users/me/Clips',
      documentsPath: '/docs',
      exists: (path) => path == '/Users/me/Clips',
    );
    expect(dir, '/Users/me/Clips');
  });

  test('a configured-but-missing folder falls back to documents', () {
    final dir = resolveSaveDirectory(
      defaultSaveLocation: '/Users/me/Deleted',
      documentsPath: '/docs',
      exists: (_) => false,
    );
    expect(dir, '/docs');
  });
}
