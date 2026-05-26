import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/audio_mix.dart';

void main() {
  test('defaults are unity, unmuted', () {
    const m = AudioMix();
    expect(m.micGainPercent, 100);
    expect(m.systemGainPercent, 100);
    expect(m.micMuted, isFalse);
    expect(m.systemMuted, isFalse);
  });

  test('round-trips through JSON', () {
    const m = AudioMix(
        micGainPercent: 80, micMuted: true,
        systemGainPercent: 150, systemMuted: false);
    expect(AudioMix.fromJson(m.toJson()), m);
  });

  test('fromJson fills defaults for missing keys', () {
    expect(AudioMix.fromJson(const {}), const AudioMix());
  });

  test('copyWith replaces only named fields', () {
    const m = AudioMix();
    final n = m.copyWith(systemGainPercent: 50, micMuted: true);
    expect(n.systemGainPercent, 50);
    expect(n.micMuted, isTrue);
    expect(n.micGainPercent, 100);
  });

  test('clamps gains to 0..200', () {
    expect(const AudioMix(micGainPercent: 999).micGainPercent, 200);
    expect(const AudioMix(systemGainPercent: -5).systemGainPercent, 0);
  });
}
