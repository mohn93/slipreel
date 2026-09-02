import 'dart:io';

/// Strips personally-identifying substrings from any text that leaves the
/// machine. Two layers:
///
///  1. The current user's home dir is collapsed to `~` (macOS paths embed the
///     account name, e.g. `/Users/<realname>/…`).
///  2. Any remaining file path is redacted to `<path>`, so filenames (a
///     recording named after a client), other users' home dirs, and
///     locations outside `$HOME` (external volumes, temp dirs) never ship.
///
/// A path is anything rooted at `~/` or an absolute `/…` with at least one
/// segment. Three passes cover the shapes that actually occur in error
/// messages and logs:
///   - quoted paths (`path = '/Volumes/EXT/My Clip.mov'`) — the form Dart's
///     `FileSystemException`/`PathNotFoundException` use; spaces included,
///     bounded by the closing quote;
///   - extension-anchored unquoted paths (`~/Movies/My Clip.mov`) — tolerates
///     spaces in the basename, bounded by a following delimiter;
///   - structural unquoted paths (`/Volumes/EXT/dir`) — no-extension paths,
///     segments up to whitespace.
///
/// Redaction favors over-scrubbing: it may clip a little surrounding text
/// rather than risk leaking a path. Space-free paths of any root (other users'
/// homes, external volumes, temp dirs) and paths ending in a file extension
/// (up to 20 chars, followed by whitespace or punctuation) are fully redacted.
///
/// Known residuals (regex cannot disambiguate these from ordinary prose without
/// destroying the surrounding error text, which is the whole point of a report):
///   - an UNQUOTED path whose basename contains a space AND has no usable file
///     extension keeps the post-space fragment (e.g. `/Volumes/John Smith/clip`
///     → `<path> Smith/clip`). The username under `/Users/<name>/` is always
///     safe (home-collapsed or space-free-redacted); this only exposes a
///     space-containing volume/folder/basename word. The main real-world source
///     of such strings — ffmpeg command-line logs — is filtered out of release
///     builds by the logger, so it never ships to users.
///   - a path glued directly to a preceding word character with no separator
///     (`at/Users/bob/x`); contrived, since real errors use a space/quote/`=`.
///   - Windows-style backslash paths (`C:\…`); N/A on this macOS-only app.
class PiiScrubber {
  PiiScrubber({required String homeDir, this.maxStringLength = 500})
      : _homeDir = homeDir;

  factory PiiScrubber.forCurrentUser() =>
      PiiScrubber(homeDir: Platform.environment['HOME'] ?? '');

  final String _homeDir;
  final int maxStringLength;

  static const String _redaction = '<path>';

  // A quoted run that starts with a path root, captured with its quote char so
  // the (possibly space-containing) content between the quotes is redacted
  // wholesale while the surrounding message keeps its shape.
  static final RegExp _quotedPath =
      RegExp(r'''(['"])((?:~/|/)[^'"\n]*)\1''');

  // A path rooted at `~/` or `/`, non-greedy up to a file extension, bounded by
  // a delimiter. `(?<![\w~'"/])` stops it starting mid-word (so `a/b/c.d` and
  // `package:foo/bar.dart` are left alone). Allows spaces in the basename. The
  // lazy run is length-bounded and the input is capped before these run, so
  // there is no super-linear backtracking. Extensions up to 20 chars cover
  // bundle types (`.photoslibrary`, `.screenflow`); the wide delimiter set
  // catches paths trailed by `:`/`>`/etc. as well as whitespace.
  static final RegExp _extensionPath = RegExp(
      r'''(?<![\w~'"/])(?:~/|/)[^"'\n]{0,1024}?\.[A-Za-z0-9]{1,20}(?=[\s"')\]},;:<>|?!=#]|$)''');

  // A whitespace-bounded absolute/home path with one or more segments and no
  // extension (e.g. `/Volumes/EXT/dir`). Same boundary guard as above.
  static final RegExp _structuralPath =
      RegExp(r'''(?<![\w~'"/])(?:~/|/)[^\s/"']+(?:/[^\s/"']+)*''');

  String scrub(String input) {
    var out = input;
    if (_homeDir.isNotEmpty) out = out.replaceAll(_homeDir, '~');
    // Cap BEFORE the regex passes: bounds their work on adversarially large
    // input (feedback is free text), then again after in case redaction of many
    // short paths grew the string.
    if (out.length > maxStringLength) out = out.substring(0, maxStringLength);
    out = _redactPaths(out);
    if (out.length > maxStringLength) out = out.substring(0, maxStringLength);
    return out;
  }

  String _redactPaths(String s) {
    var out = s.replaceAllMapped(
        _quotedPath, (m) => '${m[1]}$_redaction${m[1]}');
    out = out.replaceAll(_extensionPath, _redaction);
    out = out.replaceAll(_structuralPath, _redaction);
    return out;
  }

  List<String> scrubAll(Iterable<String> inputs, {int maxItems = 40}) {
    final list = inputs.toList();
    final tail = list.length > maxItems
        ? list.sublist(list.length - maxItems)
        : list;
    return tail.map(scrub).toList();
  }
}
