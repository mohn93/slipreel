import 'package:flutter_test/flutter_test.dart';
import 'package:screen_recorder/state/app_palette_controller.dart';
import 'package:screen_recorder/state/app_palette_store.dart';
import 'package:screen_recorder/ui/theme/app_palette.dart';

/// Records save() calls without touching the filesystem.
class _RecordingStore implements AppPaletteStore {
  final List<PaletteId> saved = [];

  @override
  String get path => '<fake>';

  @override
  Future<PaletteId?> load() async => null;

  @override
  Future<void> save(PaletteId id) async {
    saved.add(id);
  }
}

void main() {
  group('AppPaletteController', () {
    test('initial state matches the constructor arg', () {
      final c = AppPaletteController(
        store: _RecordingStore(),
        initial: PaletteId.carbon,
      );
      expect(c.state, PaletteId.carbon);
    });

    test('select publishes the new id', () {
      final c = AppPaletteController(
        store: _RecordingStore(),
        initial: PaletteId.midnight,
      );
      c.select(PaletteId.obsidian);
      expect(c.state, PaletteId.obsidian);
    });

    test('select fires store.save with the chosen id', () async {
      final store = _RecordingStore();
      final c = AppPaletteController(
        store: store,
        initial: PaletteId.midnight,
      );
      c.select(PaletteId.carbon);
      await Future<void>.delayed(Duration.zero);
      expect(store.saved, [PaletteId.carbon]);
    });
  });
}
