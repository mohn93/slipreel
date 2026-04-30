import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:screen_recorder/models/window_frame.dart';

/// Manages frame customization settings with persistence.
///
/// Extends ChangeNotifier to notify listeners when frame properties change.
/// Uses SharedPreferences to persist settings between app sessions.
class FrameSettingsProvider extends ChangeNotifier {
  static const String _storageKey = 'window_frame_settings';

  WindowFrame _currentFrame = WindowFrame.rounded();

  /// The currently selected frame with all customizations
  WindowFrame get currentFrame => _currentFrame;

  /// Load frame settings from persistent storage
  Future<void> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final jsonString = prefs.getString(_storageKey);

      if (jsonString != null) {
        final json = jsonDecode(jsonString) as Map<String, dynamic>;
        _currentFrame = WindowFrame.fromJson(json);
        notifyListeners();
      } else {
        _currentFrame = WindowFrame.rounded();
      }
    } catch (e) {
      debugPrint('Error loading frame settings: $e');
      _currentFrame = WindowFrame.rounded();
    }
  }

  /// Set a complete frame (e.g., from a template or custom configuration)
  Future<void> setFrame(WindowFrame frame) async {
    _currentFrame = frame;
    await _save();
    notifyListeners();
  }

  /// Select a frame template by name
  Future<void> selectTemplate(String templateName) async {
    final template = WindowFrame.templates.firstWhere(
      (frame) => frame.name == templateName,
      orElse: () => WindowFrame.none(),
    );
    await setFrame(template);
  }

  /// Update the padding of the current frame
  Future<void> updatePadding(double padding) async {
    _currentFrame = _currentFrame.copyWith(
      padding: EdgeInsets.all(padding),
      name: 'Custom',
    );
    await _save();
    notifyListeners();
  }

  /// Update the corner radius of the current frame
  Future<void> updateCornerRadius(double radius) async {
    _currentFrame = _currentFrame.copyWith(
      cornerRadius: radius,
      name: 'Custom',
    );
    await _save();
    notifyListeners();
  }

  /// Update the shadow blur of the current frame
  Future<void> updateShadowBlur(double blur) async {
    _currentFrame = _currentFrame.copyWith(
      shadowBlur: blur,
      name: 'Custom',
    );
    await _save();
    notifyListeners();
  }

  /// Update the background color of the current frame
  Future<void> updateBackgroundColor(Color? color) async {
    _currentFrame = _currentFrame.copyWith(
      backgroundColor: color,
      name: 'Custom',
    );
    await _save();
    notifyListeners();
  }

  /// Save the current frame to persistent storage
  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = _currentFrame.toJson();
      final jsonString = jsonEncode(json);
      await prefs.setString(_storageKey, jsonString);
    } catch (e) {
      debugPrint('Error saving frame settings: $e');
    }
  }
}
