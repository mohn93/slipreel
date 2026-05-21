import 'dart:typed_data';

/// Base interface for background effects
abstract class BackgroundEffect {
  /// Apply the effect to a frame
  ///
  /// Returns a new frame with the effect applied.
  /// The input frame is in BGRA format.
  Future<Uint8List> apply({
    required Uint8List frameData,
    required int width,
    required int height,
  });

  /// Initialize the effect (load resources, etc.)
  Future<void> initialize();

  /// Dispose resources
  void dispose();
}
