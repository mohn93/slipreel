import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/timeline/timeline.dart';

void main() {
  group('CaptionTrack + Timeline', () {
    const seg = CaptionSegment(
        id: 's', startMicros: 0, endMicros: 1000, text: 'hi');

    test('CaptionTrack JSON round-trips with source', () {
      final t = CaptionTrack(
          segments: [seg], source: CaptionAudioSource.mic);
      final back = CaptionTrack.fromJson(t.toJson());
      expect(back, t);
    });

    test('CaptionTrack constructor does not retain a mutable segment list', () {
      final source = [seg];
      final track = CaptionTrack(segments: source);
      source.clear();
      expect(track.segments, [seg]);
      expect(() => track.segments.clear(), throwsUnsupportedError);
    });

    test('Timeline persists caption tracks', () {
      final t = Timeline(captionTracks: [CaptionTrack(segments: [seg])]);
      final back = Timeline.fromJson(t.toJson());
      expect(back.captionTracks.length, 1);
      expect(back.activeCaptions.single.text, 'hi');
    });

    test('activeCaptions is empty when no tracks', () {
      final t = Timeline();
      expect(t.activeCaptions, isEmpty);
      expect(t.activeCaptionTrack, isNull);
    });

    test('Timeline without captionTracks key loads empty (back-compat)', () {
      final back = Timeline.fromJson(const {
        'zoomTracks': [],
        'clips': [],
        'cameraTracks': [],
      });
      expect(back.captionTracks, isEmpty);
    });
  });
}
