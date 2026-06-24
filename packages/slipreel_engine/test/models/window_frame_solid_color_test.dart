import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/window_frame.dart';

void main() {
  test('copyWith sets solidColor; absent leaves it unchanged', () {
    final base = WindowFrame.rounded();
    final withColor = base.copyWith(solidColor: const Color(0xFF112233));
    expect(withColor.solidColor, const Color(0xFF112233));
    expect(withColor.copyWith(name: 'x').solidColor, const Color(0xFF112233));
  });

  test('toJson/fromJson round-trips solidColor', () {
    final f = WindowFrame.rounded().copyWith(solidColor: const Color(0xFFAABBCC));
    final back = WindowFrame.fromJson(f.toJson());
    expect(back.solidColor, const Color(0xFFAABBCC));
  });

  test('fromJson defaults solidColor to null when absent', () {
    final json = WindowFrame.rounded().toJson()..remove('solidColor');
    expect(WindowFrame.fromJson(json).solidColor, isNull);
  });

  test('solidColor participates in equality', () {
    final a = WindowFrame.rounded().copyWith(solidColor: const Color(0xFF010203));
    final b = WindowFrame.rounded().copyWith(solidColor: const Color(0xFF010203));
    final c = WindowFrame.rounded().copyWith(solidColor: const Color(0xFF040506));
    expect(a, b);
    expect(a == c, isFalse);
  });
}
