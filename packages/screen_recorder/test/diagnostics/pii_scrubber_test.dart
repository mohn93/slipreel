import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/diagnostics/pii_scrubber.dart';

void main() {
  final s = PiiScrubber(homeDir: '/Users/alice', maxStringLength: 20);

  test('replaces home dir with ~', () {
    expect(s.scrub('/Users/alice/Movies/clip.mp4'), '~/Movies/clip.mp4');
  });

  test('replaces every occurrence in a string', () {
    expect(s.scrub('a /Users/alice b /Users/alice c'), 'a ~ b ~ c');
  });

  test('truncates to maxStringLength after scrubbing', () {
    expect(s.scrub('x' * 100).length, 20);
  });

  test('scrubAll caps list size, keeping the most recent (last) items', () {
    final out = s.scrubAll(['a', 'b', 'c', 'd'], maxItems: 2);
    expect(out, ['c', 'd']);
  });

  test('no home dir leaves the string unchanged (below cap)', () {
    expect(s.scrub('nothing private here'), 'nothing private here');
  });
}
