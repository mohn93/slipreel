import 'dart:ui' as ui;

import 'package:screen_recorder_platform_interface/screen_recorder_platform_interface.dart';

/// One stock cursor image plus the metadata the painter needs to
/// align it to the recorded cursor position.
///
/// `image` is the decoded bitmap (typically Retina-resolution PNG).
/// `imageWidth`/`imageHeight` are the *logical* dimensions in points
/// — the painter scales the bitmap to the user's cursor diameter
/// using `imageHeight` as the reference axis. `hotSpotX`/`hotSpotY`
/// is the "click point" of the cursor in the same point space; the
/// painter places the bitmap so that `(hotSpotX, hotSpotY)` lands on
/// the recorded cursor position.
class CachedCursorImage {
  const CachedCursorImage({
    required this.image,
    required this.hotSpotX,
    required this.hotSpotY,
    required this.imageWidth,
    required this.imageHeight,
  });

  final ui.Image image;
  final double hotSpotX;
  final double hotSpotY;
  final double imageWidth;
  final double imageHeight;
}

/// Process-wide cache of the host platform's stock cursor bitmaps
/// (arrow, pointing hand, I-beam, resize, …). Populated once at app
/// startup via [load]; the painter reads it synchronously per frame.
///
/// When the cache is empty (platform doesn't implement the bridge,
/// load failed, etc.) the painter falls back to its built-in polygon
/// rendering — non-arrow cursors still draw, they just don't look
/// pixel-identical to the OS.
class CursorImageCache {
  CursorImageCache._();

  static final Map<CursorState, CachedCursorImage> _cache = {};
  static Future<void>? _loading;

  /// Kick off the load (idempotent). Awaiting the returned Future
  /// guarantees the cache is populated before the next paint, but
  /// callers can fire-and-forget — the polygon fallback bridges the
  /// gap until the bitmaps arrive.
  static Future<void> load() {
    return _loading ??= _loadInner();
  }

  static Future<void> _loadInner() async {
    final Map<String, StockCursorImage> raw;
    try {
      raw = await ScreenRecorderPlatform.instance.getStockCursorImages();
    } catch (_) {
      // Platform doesn't support this bridge. Polygon path will be
      // used for everything — same as before this feature landed.
      return;
    }
    for (final entry in raw.entries) {
      final state = CursorStateWire.fromWireName(entry.key);
      if (state == CursorState.arrow && entry.key != 'arrow') {
        // fromWireName returns `arrow` as the fallback for unknown
        // names, so a non-arrow wire name colliding with the arrow
        // bucket means the platform sent something we don't know how
        // to map. Skip rather than overwrite the real arrow.
        continue;
      }
      try {
        final codec = await ui.instantiateImageCodec(entry.value.png);
        try {
          final frame = await codec.getNextFrame();
          _cache[state] = CachedCursorImage(
            image: frame.image,
            hotSpotX: entry.value.hotSpotX,
            hotSpotY: entry.value.hotSpotY,
            imageWidth: entry.value.imageWidth,
            imageHeight: entry.value.imageHeight,
          );
        } finally {
          codec.dispose();
        }
      } catch (_) {
        // Single-image decode failure (corrupt PNG, etc.) shouldn't
        // disable the whole cache.
        continue;
      }
    }
  }

  /// Synchronous lookup for the painter. Returns null when the cache
  /// hasn't been populated yet (or the platform didn't ship an image
  /// for [state]) — callers fall back to polygon rendering.
  static CachedCursorImage? imageFor(CursorState state) => _cache[state];
}
