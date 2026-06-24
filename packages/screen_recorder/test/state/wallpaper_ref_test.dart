import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/wallpaper_ref.dart';

void main() {
  test('encode/decode round-trips a photo ref', () {
    const ref = WallpaperRef.photo('macOS', 3);
    expect(ref.encode(), 'photo:macOS:3');
    expect(WallpaperRef.decode('photo:macOS:3'), ref);
  });

  test('decode returns null for malformed tokens', () {
    expect(WallpaperRef.decode('photo:macOS'), isNull);
    expect(WallpaperRef.decode('photo:macOS:x'), isNull);
    expect(WallpaperRef.decode(''), isNull);
  });

  test('decode returns null for unknown scheme (forward-compat)', () {
    expect(WallpaperRef.decode('color:FF8800'), isNull);
  });

  test('value equality', () {
    expect(const WallpaperRef.photo('Spring', 1),
        const WallpaperRef.photo('Spring', 1));
    expect(const WallpaperRef.photo('Spring', 1),
        isNot(const WallpaperRef.photo('Spring', 2)));
  });
}
