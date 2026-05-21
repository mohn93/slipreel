import 'dart:typed_data';

/// One stock OS cursor image, extracted from the host platform's
/// system cursor set (e.g. macOS `NSCursor.pointingHand.image`) so the
/// renderer can blit the OS-accurate bitmap instead of approximating
/// each cursor with a hand-coded polygon.
///
/// `png` is encoded PNG bytes — decode with `ui.instantiateImageCodec`.
/// `hotSpot` is in the same coordinate units as `imageSize` (points,
/// not pixels — pixels live in `pixelWidth`/`pixelHeight` and only
/// matter for picking the right Retina rep when decoding).
///
/// Hot-spot anchors the cursor's "click point" to the user's recorded
/// position: for the arrow it's the very tip, for the I-beam it's the
/// centre, for the pointing hand it's the fingertip. The renderer
/// places the image so `position` lands on `hotSpot` and the image
/// extends from there.
class StockCursorImage {
  const StockCursorImage({
    required this.png,
    required this.hotSpotX,
    required this.hotSpotY,
    required this.imageWidth,
    required this.imageHeight,
    required this.pixelWidth,
    required this.pixelHeight,
  });

  final Uint8List png;
  final double hotSpotX;
  final double hotSpotY;

  /// Logical image dimensions in points. The hot-spot is expressed in
  /// these same units.
  final double imageWidth;
  final double imageHeight;

  /// Actual pixel dimensions of the PNG (typically 2× imageWidth on
  /// Retina). Decoded via `ui.instantiateImageCodec` at the native
  /// pixel size — the renderer then draws it scaled to the user's
  /// cursor diameter.
  final int pixelWidth;
  final int pixelHeight;

  factory StockCursorImage.fromMap(Map<dynamic, dynamic> map) {
    return StockCursorImage(
      png: map['png'] as Uint8List,
      hotSpotX: (map['hotX'] as num).toDouble(),
      hotSpotY: (map['hotY'] as num).toDouble(),
      imageWidth: (map['imageWidth'] as num).toDouble(),
      imageHeight: (map['imageHeight'] as num).toDouble(),
      pixelWidth: (map['pixelWidth'] as num).toInt(),
      pixelHeight: (map['pixelHeight'] as num).toInt(),
    );
  }
}
