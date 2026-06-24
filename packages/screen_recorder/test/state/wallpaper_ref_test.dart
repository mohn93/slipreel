import 'package:flutter/painting.dart';
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

  test('decode returns null for a genuinely unknown scheme', () {
    expect(WallpaperRef.decode('gradient:1'), isNull);
  });

  group('color variant', () {
    test('encode/decode round-trips a color ref', () {
      const ref = WallpaperRef.color(Color(0xFFFF8800));
      expect(ref.encode(), 'color:FF8800');
      expect(WallpaperRef.decode('color:FF8800'), ref);
      expect(ref.isColor, isTrue);
      expect(ref.color, const Color(0xFFFF8800));
    });

    test('decode rejects malformed color tokens', () {
      expect(WallpaperRef.decode('color:FFF'), isNull); // wrong length
      expect(WallpaperRef.decode('color:GGGGGG'), isNull); // not hex
    });

    test('a color ref never equals a photo ref', () {
      expect(const WallpaperRef.color(Color(0xFF000000)) ==
          const WallpaperRef.photo('Solid', 0), isFalse);
    });

    test('photo refs are not color refs', () {
      expect(const WallpaperRef.photo('macOS', 0).isColor, isFalse);
      expect(const WallpaperRef.photo('macOS', 0).color, isNull);
    });
  });

  test('value equality', () {
    expect(const WallpaperRef.photo('Spring', 1),
        const WallpaperRef.photo('Spring', 1));
    expect(const WallpaperRef.photo('Spring', 1),
        isNot(const WallpaperRef.photo('Spring', 2)));
  });
}
