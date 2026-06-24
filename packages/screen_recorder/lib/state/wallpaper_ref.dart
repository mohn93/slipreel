/// A serializable reference to a single wallpaper in the picker.
///
/// Encoded as an extensible string token so new wallpaper kinds (e.g. a
/// custom solid color, coming with the color-picker feature) can be added
/// without migrating persisted favorites:
///   - `photo:<category>:<index>` — a bundled or procedural wallpaper.
class WallpaperRef {
  const WallpaperRef.photo(this.category, this.index);

  final String category;
  final int index;

  /// Encode to a persistence token.
  String encode() => 'photo:$category:$index';

  /// Decode a token. Returns null for malformed or unknown-scheme tokens,
  /// so an older build silently ignores a token a newer build wrote.
  static WallpaperRef? decode(String token) {
    final parts = token.split(':');
    if (parts.length != 3 || parts[0] != 'photo' || parts[1].isEmpty) {
      return null;
    }
    final index = int.tryParse(parts[2]);
    if (index == null) return null;
    return WallpaperRef.photo(parts[1], index);
  }

  @override
  bool operator ==(Object other) =>
      other is WallpaperRef &&
      other.category == category &&
      other.index == index;

  @override
  int get hashCode => Object.hash(category, index);

  @override
  String toString() => 'WallpaperRef(${encode()})';
}
