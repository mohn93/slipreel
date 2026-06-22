import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';
import 'package:screen_recorder/state/caption_generation_controller.dart';

void main() {
  late EditorProjectController editor;
  setUp(() => editor = EditorProjectController());

  CaptionGenerationController build({
    Future<String> Function()? ensureModel,
    Future<String?> Function()? extract,
    Future<List<CaptionSegment>> Function()? transcribe,
  }) =>
      CaptionGenerationController(
        editor: editor,
        ensureModel: (onP) async {
          onP?.call(0.5);
          return ensureModel == null ? '/model.bin' : await ensureModel();
        },
        extractAudio: (video, source) async =>
            extract == null ? '/audio.wav' : await extract(),
        transcribe: (audio, model, onP) async => transcribe == null
            ? const [
                CaptionSegment(
                    id: 's', startMicros: 0, endMicros: 1000, text: 'hi'),
              ]
            : await transcribe(),
      );

  test('happy path ends in CaptionDone and writes segments', () async {
    final c = build();
    await c.generate(videoPath: '/v.mov', source: CaptionAudioSource.mic);
    expect(c.state, isA<CaptionDone>());
    expect((c.state as CaptionDone).count, 1);
    expect(editor.state.captions.single.text, 'hi');
    expect(editor.state.captionSource, CaptionAudioSource.mic);
    expect(editor.state.captionStyle.enabled, isTrue);
  });

  test('extractor returning null → CaptionError', () async {
    final c = build(extract: () async => null);
    await c.generate(videoPath: '/v.mov', source: CaptionAudioSource.mic);
    expect(c.state, isA<CaptionError>());
  });

  test('transcriber throwing → CaptionError with message', () async {
    final c = build(transcribe: () async => throw Exception('boom'));
    await c.generate(videoPath: '/v.mov', source: CaptionAudioSource.mixed);
    expect(c.state, isA<CaptionError>());
    expect((c.state as CaptionError).message, contains('boom'));
  });
}
