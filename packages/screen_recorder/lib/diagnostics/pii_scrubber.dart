import 'dart:io';

/// Strips personally-identifying substrings from any text that leaves the
/// machine. macOS paths embed the account name (`/Users/<realname>/…`), so we
/// collapse the home dir to `~` and cap length to bound accidental leakage.
class PiiScrubber {
  PiiScrubber({required String homeDir, this.maxStringLength = 500})
      : _homeDir = homeDir;

  factory PiiScrubber.forCurrentUser() =>
      PiiScrubber(homeDir: Platform.environment['HOME'] ?? '');

  final String _homeDir;
  final int maxStringLength;

  String scrub(String input) {
    var out = input;
    if (_homeDir.isNotEmpty) out = out.replaceAll(_homeDir, '~');
    if (out.length > maxStringLength) out = out.substring(0, maxStringLength);
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
