import 'package:flutter_test/flutter_test.dart';
import 'package:slipreel_engine/models/caption_segment.dart';
import 'package:slipreel_engine/models/caption_style.dart';
import 'package:slipreel_engine/state/editor_project_controller.dart';

void main() {
  late EditorProjectController c;
  setUp(() => c = EditorProjectController());

  const a = CaptionSegment(id: 'a', startMicros: 0, endMicros: 1000, text: 'a');
  const b =
      CaptionSegment(id: 'b', startMicros: 1000, endMicros: 2000, text: 'b');

  test('replace + read back via captions accessor', () {
    c.replaceCaptionSegments(const [a, b]);
    expect(c.state.captions.map((s) => s.text), ['a', 'b']);
  });

  test('updateCaptionTextAt edits one segment', () {
    c.replaceCaptionSegments(const [a, b]);
    c.updateCaptionTextAt(1, 'edited');
    expect(c.state.captions[1].text, 'edited');
    expect(c.state.captions[0].text, 'a');
  });

  test('removeCaptionAt drops the segment', () {
    c.replaceCaptionSegments(const [a, b]);
    c.removeCaptionAt(0);
    expect(c.state.captions.single.text, 'b');
  });

  test('splitCaptionAt splits one into two at the given time', () {
    c.replaceCaptionSegments(const [a]);
    c.splitCaptionAt(0, 400);
    expect(c.state.captions.length, 2);
    expect(c.state.captions[0].endMicros, 400);
    expect(c.state.captions[1].startMicros, 400);
    expect(c.state.captions[0].text, 'a');
    expect(c.state.captions[1].text, '');
  });

  test('mergeCaptionWithNext joins ranges and text', () {
    c.replaceCaptionSegments(const [a, b]);
    c.mergeCaptionWithNext(0);
    expect(c.state.captions.length, 1);
    expect(c.state.captions.single.startMicros, 0);
    expect(c.state.captions.single.endMicros, 2000);
    expect(c.state.captions.single.text, 'a b');
  });

  test('setCaptionStyle updates style', () {
    c.setCaptionStyle(const CaptionStyle(enabled: true));
    expect(c.state.captionStyle.enabled, isTrue);
  });
}
