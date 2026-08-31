import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'global_preferences_store.dart';

class GlobalPreferencesController extends StateNotifier<GlobalPreferences> {
  GlobalPreferencesController({required this.store, required GlobalPreferences initial})
      : super(initial);

  final GlobalPreferencesStore store;

  Future<void> setDefaultSaveLocation(String? path) async {
    state = (path == null || path.isEmpty)
        ? state.copyWith(clearSaveLocation: true)
        : state.copyWith(defaultSaveLocation: path);
    await store.save(state);
  }

  Future<void> setShareAnalytics(bool value) async {
    if (state.shareAnalytics == value) return;
    state = state.copyWith(shareAnalytics: value);
    await store.save(state);
  }
}

final globalPreferencesStoreProvider = Provider<GlobalPreferencesStore>(
  (ref) => throw UnimplementedError(
    'Override globalPreferencesStoreProvider in main()',
  ),
);

final globalPreferencesControllerProvider =
    StateNotifierProvider<GlobalPreferencesController, GlobalPreferences>(
  (ref) => throw UnimplementedError(
    'Override globalPreferencesControllerProvider in main()',
  ),
);
