import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_style.dart';

void main() {
  group('CaptionStyle', () {
    test('defaults are disabled, bottom, box, white, 1.0', () {
      const s = CaptionStyle();
      expect(s.enabled, isFalse);
      expect(s.position, CaptionPosition.bottom);
      expect(s.background, CaptionBackground.box);
      expect(s.fontScale, 1.0);
      expect(s.textColor, const Color(0xFFFFFFFF));
    });

    test('JSON round-trips (incl. color via toARGB32)', () {
      const s = CaptionStyle(
        enabled: true,
        position: CaptionPosition.top,
        fontScale: 1.5,
        textColor: Color(0xFFFFEB3B),
        background: CaptionBackground.outline,
      );
      final back = CaptionStyle.fromJson(s.toJson());
      expect(back, s);
    });

    test('fromJson fills defaults on missing/unknown fields', () {
      final s = CaptionStyle.fromJson(const {});
      expect(s, const CaptionStyle());
      final s2 = CaptionStyle.fromJson(const {'position': 'sideways'});
      expect(s2.position, CaptionPosition.bottom);
    });
  });
}
