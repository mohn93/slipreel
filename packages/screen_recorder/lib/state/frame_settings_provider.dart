import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:screen_recorder/models/window_frame.dart';

/// In-memory frame state for the active recording.
///
/// Mutator methods bump the held [WindowFrame] and call
/// [notifyListeners] so the inspector and the playback canvas redraw.
/// Persistence is the owner's responsibility — the playback screen
/// loads the frame from the recording's `<videoPath>.editor.json`
/// sidecar on init and saves any changes back through
/// `EditorProjectStore`.
class FrameSettingsProvider extends ChangeNotifier {
  WindowFrame _currentFrame = WindowFrame.rounded();

  /// The currently selected frame with all customizations
  WindowFrame get currentFrame => _currentFrame;

  /// Set a complete frame (e.g., from a template, the persistence
  /// layer, or a custom configuration). Notifies listeners only when
  /// the frame actually changes — important during init so a
  /// no-op restore from a sidecar doesn't trigger a save loop.
  void setFrame(WindowFrame frame) {
    if (_currentFrame == frame) return;
    _currentFrame = frame;
    notifyListeners();
  }

  /// Select a frame template by name
  void selectTemplate(String templateName) {
    final template = WindowFrame.templates.firstWhere(
      (frame) => frame.name == templateName,
      orElse: () => WindowFrame.none(),
    );
    setFrame(template);
  }

  /// Update the padding of the current frame
  void updatePadding(double padding) {
    setFrame(_currentFrame.copyWith(
      padding: EdgeInsets.all(padding),
      name: 'Custom',
    ));
  }

  /// Update the corner radius of the current frame
  void updateCornerRadius(double radius) {
    setFrame(_currentFrame.copyWith(
      cornerRadius: radius,
      name: 'Custom',
    ));
  }

  /// Update the shadow blur of the current frame
  void updateShadowBlur(double blur) {
    setFrame(_currentFrame.copyWith(
      shadowBlur: blur,
      name: 'Custom',
    ));
  }

  /// Update the background color of the current frame
  void updateBackgroundColor(Color? color) {
    setFrame(_currentFrame.copyWith(
      backgroundColor: color,
      name: 'Custom',
    ));
  }

  /// Pick a wallpaper from the wallpaper catalog. Pass `null` for
  /// [category] to drop the wallpaper layer entirely.
  void updateWallpaper({
    required String? category,
    int index = 0,
  }) {
    if (category == null) {
      setFrame(_currentFrame.copyWith(
        clearWallpaper: true,
        name: 'Custom',
      ));
    } else {
      setFrame(_currentFrame.copyWith(
        wallpaperCategory: category,
        wallpaperIndex: index,
        name: 'Custom',
      ));
    }
  }

  /// Update the wallpaper Gaussian-blur sigma (canvas pixels).
  void updateBackgroundBlur(double sigma) {
    setFrame(_currentFrame.copyWith(
      backgroundBlur: sigma,
      name: 'Custom',
    ));
  }

  /// Update the inset-ring width (canvas pixels). 0 disables the ring.
  void updateInset(double inset) {
    setFrame(_currentFrame.copyWith(
      inset: inset,
      name: 'Custom',
    ));
  }
}
