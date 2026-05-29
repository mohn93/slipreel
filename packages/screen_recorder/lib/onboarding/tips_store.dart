import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class TipsStore {
  static const _key = 'slipreel.tips_seen';

  Future<Set<String>> load() async {
    final prefs = await SharedPreferences.getInstance();
    return (prefs.getStringList(_key) ?? const <String>[]).toSet();
  }

  Future<void> markSeen(String id) async {
    final prefs = await SharedPreferences.getInstance();
    final current = (prefs.getStringList(_key) ?? const <String>[]).toSet()
      ..add(id);
    await prefs.setStringList(_key, current.toList(growable: false));
  }

  Future<void> clearAll() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_key);
  }
}

final tipsStoreProvider = Provider<TipsStore>(
  (ref) => throw UnimplementedError(
    'Override tipsStoreProvider in main() with a real instance',
  ),
);
