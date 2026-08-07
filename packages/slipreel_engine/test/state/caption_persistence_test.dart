import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/state/editor_project_state.dart';

void main() {
  const dur = Duration(seconds: 10);

  test('schema version is current', () {
    expect(EditorProjectState.currentSchemaVersion, 12);
  });

  test('captionStyle + segments round-trip through JSON', () {
    final state = EditorProjectState.defaults().copyWith(
      captionStyle: const CaptionStyle(enabled: true),
      captionSegments: const [
        CaptionSegment(id: 'a', startMicros: 0, endMicros: 1000, text: 'hi'),
      ],
      captionSource: CaptionAudioSource.mic,
    );
    final back = EditorProjectState.fromJson(
      state.toJson(),
      videoDuration: dur,
    );
    expect(back.captionStyle.enabled, isTrue);
    expect(back.captions.single.text, 'hi');
    expect(back.captionSource, CaptionAudioSource.mic);
  });

  test('a v9 project (no caption keys) loads with defaults', () {
    final v9 = EditorProjectState.defaults().toJson()
      ..['schemaVersion'] = 9
      ..remove('captionStyle');
    // also strip captionTracks the v10 toJson would have written
    (v9['timeline'] as Map<String, dynamic>).remove('captionTracks');
    final back = EditorProjectState.fromJson(v9, videoDuration: dur);
    expect(back.captionStyle, const CaptionStyle());
    expect(back.captions, isEmpty);
  });
}
