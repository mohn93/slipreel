import 'package:shared_preferences/shared_preferences.dart';

/// SharedPreferences-backed persistence for the snap-on-cut toggle.
/// Per-user (not per-project) — the toggle persists across recordings.
class SnapPreferenceStore {
  SnapPreferenceStore(this._prefs);

  static const _key = 'slipreel.snap_enabled';

  final SharedPreferences _prefs;

  /// Construct from a freshly-loaded SharedPreferences instance. Used
  /// by the main.dart bootstrap to mirror [AppPaletteStore.resolveDefault].
  static Future<SnapPreferenceStore> resolveDefault() async {
    final prefs = await SharedPreferences.getInstance();
    return SnapPreferenceStore(prefs);
  }

  /// Defaults to true when no value is stored.
  bool load() => _prefs.getBool(_key) ?? true;

  Future<void> save(bool enabled) => _prefs.setBool(_key, enabled);
}
