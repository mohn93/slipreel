import 'package:flutter/painting.dart';

/// A serializable reference to a single wallpaper in the picker.
///
/// Encoded as an extensible string token:
///   - `photo:<category>:<index>` — a bundled or procedural wallpaper.
///   - `color:<RRGGBB>` — a custom solid color (opaque).
///
/// Color refs carry `category == 'Solid'`, `index == 0`, and a non-null
/// [color]; use [isColor] to discriminate.
class WallpaperRef {
  const WallpaperRef.photo(this.category, this.index) : color = null;

  const WallpaperRef.color(Color value)
      : color = value,
        category = 'Solid',
        index = 0;

  final String category;
  final int index;
  final Color? color;

  bool get isColor => color != null;

  /// Encode to a persistence token.
  String encode() => color != null
      ? 'color:${_hex6(color!)}'
      : 'photo:$category:$index';

  /// Decode a token. Returns null for malformed or unknown-scheme tokens,
  /// so an older build silently ignores a token a newer build wrote.
  static WallpaperRef? decode(String token) {
    final sep = token.indexOf(':');
    if (sep < 0) return null;
    final scheme = token.substring(0, sep);
    final rest = token.substring(sep + 1);
    switch (scheme) {
      case 'photo':
        final parts = rest.split(':');
        if (parts.length != 2 || parts[0].isEmpty) return null;
        final index = int.tryParse(parts[1]);
        if (index == null) return null;
        return WallpaperRef.photo(parts[0], index);
      case 'color':
        if (rest.length != 6) return null;
        final v = int.tryParse(rest, radix: 16);
        if (v == null) return null;
        return WallpaperRef.color(Color(0xFF000000 | v));
      default:
        return null;
    }
  }

  static String _hex6(Color c) =>
      c.toARGB32().toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();

  @override
  bool operator ==(Object other) =>
      other is WallpaperRef &&
      other.category == category &&
      other.index == index &&
      other.color == color;

  @override
  int get hashCode => Object.hash(category, index, color);

  @override
  String toString() => 'WallpaperRef(${encode()})';
}
