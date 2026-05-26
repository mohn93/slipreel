import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/state/audio_mix.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  test('mutators update audioMix and clamp gains', () {
    final c = EditorProjectController();
    expect(c.current.audioMix, const AudioMix());

    c.setMicGain(50);
    expect(c.current.audioMix.micGainPercent, 50);

    c.setSystemGain(250); // clamps to 200
    expect(c.current.audioMix.systemGainPercent, 200);

    c.setMicMuted(true);
    expect(c.current.audioMix.micMuted, isTrue);

    c.setSystemMuted(true);
    expect(c.current.audioMix.systemMuted, isTrue);
    expect(c.current.audioMix.micGainPercent, 50);
  });
}
