import 'dart:io';

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
    Future<int> Function()? audioOffset,
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
        audioOffset: (video, source) async =>
            audioOffset == null ? 0 : await audioOffset(),
      );

  test('deletes the slipreel_caption_ temp dir after a successful run',
      () async {
    // Regression: the extractor mints a fresh slipreel_caption_* temp
    // dir per generation (WAV + whisper transcript) and nothing ever
    // deleted it — ~2 MB/minute of audio leaked per attempt, per retry.
    final tempDir = Directory.systemTemp.createTempSync('slipreel_caption_');
    final wav = File('${tempDir.path}/caption_audio.wav')
      ..writeAsBytesSync([0, 1, 2]);

    final c = build(extract: () async => wav.path);
    await c.generate(videoPath: '/v.mp4', source: CaptionAudioSource.mic);

    expect(c.state, isA<CaptionDone>());
    expect(tempDir.existsSync(), isFalse,
        reason: 'the caption temp dir (WAV + transcript) must be removed '
            'once its segments are extracted');
  });

  test('deletes the temp dir when transcription fails', () async {
    final tempDir = Directory.systemTemp.createTempSync('slipreel_caption_');
    final wav = File('${tempDir.path}/caption_audio.wav')
      ..writeAsBytesSync([0, 1, 2]);

    final c = build(
      extract: () async => wav.path,
      transcribe: () async => throw Exception('whisper exploded'),
    );
    await c.generate(videoPath: '/v.mp4', source: CaptionAudioSource.mic);

    expect(c.state, isA<CaptionError>());
    expect(tempDir.existsSync(), isFalse,
        reason: 'error paths leak the temp dir too — every retry minted '
            'a fresh one');
  });

  test('leaves non-slipreel directories alone (injected outPath)', () async {
    // Callers may inject an outPath outside our temp-dir convention;
    // cleanup must never delete a directory it does not own.
    final foreign = Directory.systemTemp.createTempSync('user_owned_');
    final wav = File('${foreign.path}/audio.wav')..writeAsBytesSync([1]);
    addTearDown(() {
      if (foreign.existsSync()) foreign.deleteSync(recursive: true);
    });

    final c = build(extract: () async => wav.path);
    await c.generate(videoPath: '/v.mp4', source: CaptionAudioSource.mic);

    expect(foreign.existsSync(), isTrue);
    expect(wav.existsSync(), isTrue);
  });

  test('happy path ends in CaptionDone and writes segments', () async {
    final c = build();
    await c.generate(videoPath: '/v.mov', source: CaptionAudioSource.mic);
    expect(c.state, isA<CaptionDone>());
    expect((c.state as CaptionDone).count, 1);
    expect(editor.state.captions.single.text, 'hi');
    expect(editor.state.captionSource, CaptionAudioSource.mic);
    expect(editor.state.captionStyle.enabled, isTrue);
  });

  test('shifts segment timestamps by the probed audio offset (movie-time)',
      () async {
    final c = build(
      transcribe: () async => const [
        CaptionSegment(id: 's', startMicros: 0, endMicros: 1000, text: 'hi'),
      ],
      audioOffset: () async => 240000,
    );
    await c.generate(videoPath: '/v.mov', source: CaptionAudioSource.system);
    final seg = editor.state.captions.single;
    expect(seg.startMicros, 240000, reason: 'whisper t=0 maps to the gap');
    expect(seg.endMicros, 241000);
  });

  test('offset 0 leaves caption timestamps unchanged', () async {
    final c = build(audioOffset: () async => 0);
    await c.generate(videoPath: '/v.mov', source: CaptionAudioSource.mic);
    final seg = editor.state.captions.single;
    expect(seg.startMicros, 0);
    expect(seg.endMicros, 1000);
  });

  test('threads the generate() videoPath + source to the offset resolver',
      () async {
    String? seenVideo;
    CaptionAudioSource? seenSource;
    final c = CaptionGenerationController(
      editor: editor,
      ensureModel: (_) async => '/m.bin',
      extractAudio: (_, __) async => '/a.wav',
      transcribe: (_, __, ___) async => const [
        CaptionSegment(id: 's', startMicros: 0, endMicros: 1000, text: 'hi'),
      ],
      audioOffset: (video, source) async {
        seenVideo = video;
        seenSource = source;
        return 0;
      },
    );
    await c.generate(videoPath: '/clip.mov', source: CaptionAudioSource.mixed);
    expect(seenVideo, '/clip.mov');
    expect(seenSource, CaptionAudioSource.mixed);
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
